# Bloco 4.1 — Candidatos: requisito de fronteira, campos estruturados e guias de caça — design

> **Origem:** a 2026-09-21 o operador apontou a
> [`cloudflare/security-audit-skill`](https://github.com/cloudflare/security-audit-skill)
> (MIT) e perguntou se valia como item do módulo de segurança. Foi comparada com
> o que o módulo já faz e a resposta foi: não como "instalar a skill", mas como
> **cinco ideias a roubar**, divididas em três sub-projectos sequenciais. Este
> documento é o primeiro. Os outros dois — **4.2 Veredictos** (verificação
> adversarial por subagentes, coluna `verdict`, guarda no fecho) e **4.3
> Cobertura** (coverage ledger de unidades superfície × classe de ataque) — têm
> spec própria e constroem sobre o que aqui se define.

**Objectivo:** que um achado `sast` do agente seja uma afirmação verificável —
com a fronteira que atravessa, a cadeia de código que a prova, a confiança de
quem a fez e as pré-condições de que depende — em vez de um parágrafo; e que o
agente cace com o material de referência da Cloudflare, escolhido pela stack do
repositório e não pelo humor do modelo.

---

## O que foi comparado

**O que o módulo já tem e a skill da Cloudflare não:** ledger com diff entre
análises (oito estados, `regressed`, `pending` a manter o `fixed` honesto), fase
determinística (segredos no histórico git em cada run, CVEs, SBOM, hygiene, IaC,
pré-passagem Semgrep), decisões humanas ao nível do projecto, orçamentos, e um
`done` que o ledger verifica em vez de acreditar. A skill deles é *one-shot* por
run e o próprio README diz que um run apanha ~50% do total — é o argumento do
nosso modelo de postura ao longo do tempo, não contra ele.

**O que a skill deles tem e nós não** — os cinco itens, e onde cada um entra:

| # | ideia | sub-projecto |
|---|---|---|
| 1 | **Requisito de fronteira** — um achado nomeia o principal de menor confiança, o input, o controlo que devia ter segurado, a fronteira atravessada, o recurso afectado e o resultado observável; defesa em profundidade em falta é *hardening note*, não vulnerabilidade | **4.1** (este) |
| 2 | **Campos estruturados** — `trace` (entrypoint → propagation → sink), `confidence` com razão, `likelihood` × `impact` com razão, `conditions` | **4.1** (este) |
| 5 | **Guias de caça por classe de ataque** — `ATTACK-CLASSES.md` e dez guias de domínio | **4.1** (este) |
| 3 | **Verificação adversarial independente** — um verificador que não descobriu o candidato tenta desmenti-lo; `confirmed` / `needs_validation` / `rejected` | 4.2 |
| 4 | **Coverage ledger** — unidades verificadas/não verificadas; o `capped` diz *quais* ficaram por ver | 4.3 |

**O que fica de fora de propósito:** execução de payloads em sandbox (não
provisionamos nada e não executamos nada — decisão da spec original), artefactos
Markdown por run (já renderizamos do ledger), ondas paralelas de "hunters".

**Medido antes de desenhar:** os onze guias somam ~130 KB ≈ 35k tokens. Lê-los
todos num `quick` com tecto de $2–5 é impagável, por isso a escolha é
selectiva e determinística. Os guias de domínio são auto-contidos — zero
referências a hunters, `findings.json` ou subagentes; a única ligação é "use
this with ATTACK-CLASSES.md" — por isso vendorizam-se byte a byte.

---

## Decisões

| Decisão | Porquê |
|---|---|
| **Três sub-projectos, não um** | cinco itens tocam skill, ledger, CLI, engine, report e UI — mais do que um plano aguenta. Cada um é uma branch/PR como os blocos anteriores; este sozinho já melhora a precisão, e o 4.2 escreve os campos que este define. |
| **Um documento JSON por achado (`candidate`), não colunas e tabelas próprias** | uma coluna aditiva, uma migração, um validador — a mesma forma que o verificador do 4.2 vai ler e reescrever, e o mesmo padrão da coluna `coverage`. Ninguém hoje faz perguntas do tipo "todos os sinks em `db.py`" que justificassem uma tabela `trace_step`. |
| **`severity` continua a ser um valor único escolhido pelo agente** | é o que a floor, os contadores e o donut lêem; derivar de uma matriz likelihood × impact seria uma política nova a discutir com o modelo. As âncoras da Cloudflare definem o valor; `likelihood`/`impact` justificam-no e a única regra de coerência é o tecto: `severity` nunca acima de `impact`. |
| **`execution` (payloads, instruções, resultado observado) fica fora** | pressupõe correr payloads em sandbox. Não executamos nada, e o agente inventaria payloads que nunca correu. `evidence` também fica fora — é redundante com `occurrences`. |
| **`prepare` escolhe os guias, não o agente** | é determinístico, barato (o `prepare` já percorre a árvore e lê o inventário), fica registado, e o perfil põe o tecto de custo. |
| **O que foi lido sai do stream, nunca da palavra do agente** | é a regra do módulo: verificado, não acreditado. O engine já guarda o stream por run e já o lê no fecho. |
| **Não vendorizar o processo da Cloudflare** | `SKILL.md`, `HUNTING.md`, `RECONNAISSANCE.md` e `VALIDATION-AND-REPORTING.md` descrevem hunters, `findings.json` e verifiers; competiriam com a nossa skill. Só `ATTACK-CLASSES.md` e os dez guias de domínio. |
| **Hardening notes vão para `info`** | `info` já é "conselho, não exposição" — é exactamente o que uma defesa em profundidade em falta é. |
| **O Job 1 (eco de linha `pending` determinística) não leva `candidate`** | ecoar uma linha que ninguém re-verificou com uma `confidence` seria a afirmação de verificação que o Job 1 proíbe. |

---

## Desenho

### 1. A skill: requisito de fronteira e âncoras de severidade

`skills/security-analysis/SKILL.md` ganha uma secção **"What qualifies as a
finding"**, antes do Job 3, com a regra da Cloudflare adaptada:

- Um candidato `sast` a `medium` ou acima tem de nomear **o principal de menor
  confiança, o input ou acção que ele controla, o controlo que devia ter
  segurado, a fronteira atravessada, o recurso ou principal afectado, e o
  resultado observável**. Um crash genérico, uma *best practice* em falta ou uma
  defesa em profundidade ausente não é vulnerabilidade — é uma *hardening note*
  e vai para `info`.
- Cinco âncoras de severidade substituem o critério implícito de hoje:
  `critical` — execução de código, acesso total a dados ou *account takeover*
  sem autenticação; `high` — um controlo explícito totalmente derrotado, com
  consequência real; `medium` — fronteira real atravessada, raio de acção
  limitado; `low` — divulgação ou ganho mínimo; `info` — confirmado, sem
  impacto.
- A regra "an unsure finding is a finding, at the severity it would have if it
  were real, with your doubt in the rationale" mantém-se, mas a dúvida passa a
  ter um campo: `confidence`.
- A mesma régua aplica-se ao Job 2: o MD5 em chave de cache do Semgrep falha o
  requisito de fronteira e desce a `info` com a razão escrita — o que já
  acontece na prática, agora com critério nomeado.
- **Proibido baixar a severidade para escapar à porta**: "a medium+ weakness
  without a trace is one you have not read — go read it". A porta não vê esta
  rota (ver Falhas e limites); a skill diz-o e o 4.2 apanha-a.

O Job 3 passa a começar pela leitura dos guias (secção 3) e o exemplo de
`report-finding` passa a incluir um `candidate`. O Job 2 diz que toda a
re-report de triagem leva `confidence`. O Job 1 diz que o eco de uma linha
`pending` determinística não leva `candidate`, e que uma linha `pending` de
`sast` re-reportada como *still present* leva o documento completo — o agente
leu o código para o dizer.

### 2. O documento `candidate` e a porta

`report-finding` aceita um objecto opcional `candidate` ao lado dos campos de
hoje:

```json
"candidate": {
  "trace": [
    {"kind": "entrypoint", "file": "app/api.py", "line": 42,
     "scope": "handle_upload", "description": "multipart filename read from the request"},
    {"kind": "propagation", "file": "app/storage.py", "line": 17,
     "scope": "save", "description": "joined onto the upload root without normalisation"},
    {"kind": "sink", "file": "app/storage.py", "line": 19,
     "scope": "save", "description": "open() on the joined path"}
  ],
  "intended_control": "uploads must stay under the per-tenant upload root",
  "confidence": {"score": "high", "reason": "the join is unconditional and no middleware rewrites the filename"},
  "likelihood": {"score": "high", "reason": "any authenticated tenant can upload"},
  "impact": {"score": "high", "reason": "arbitrary file write inside the container, no code execution path found"},
  "conditions": [
    {"kind": "authentication_level", "description": "requires a tenant session"}
  ]
}
```

**Vocabulários (fechados):**

- `trace[].kind`: `entrypoint` · `propagation` · `sink`
- `confidence.score`: `low` · `medium` · `high`
- `likelihood.score`, `impact.score`: `info` · `low` · `medium` · `high` ·
  `critical` — o mesmo vocabulário de `severity`
- `conditions[].kind`: `authentication_level` · `authorization_role` ·
  `user_interaction` · `system_configuration` · `network_routing` ·
  `environmental_dependency` · `data_state` · `timing_dependency` ·
  `third_party_dependency`

**Validação**, em Python puro no `cli.py` (sem dependência `jsonschema` — o
install continua a ser jq + python3 + curl). Toda a recusa nomeia o caminho do
campo (`candidate.trace[2].description`) e a regra, sai com erro e não escreve
nada — recusa, nunca trunca, como hoje:

- `trace`: lista de 1 a 50 passos, **ordem preservada** (a ordem enviada é a
  ordem do fluxo), passos únicos (o objecto inteiro); cada passo com os cinco
  campos, `file` relativo (sem `/` inicial, sem segmento `..`, não vazio),
  `line` inteiro ≥ 1, `scope` e `description` não vazios.
- `intended_control`, `confidence.reason`, `likelihood.reason`,
  `impact.reason`, `conditions[].description`, `trace[].description`,
  `trace[].scope`: texto ≤ 10.000 caracteres cada, o mesmo tecto de `TEXT_KEYS`.
- Documento inteiro ≤ 64 KB depois da codificação canónica.
- Chaves desconhecidas dentro de `candidate` são recusadas — um campo que o
  ledger não conhece é um campo que ninguém vai ler.
- **Coerência:** quando `impact` está presente, `severity` não pode ser mais
  alta do que `impact.score`. É a única regra de coerência: o tecto de uma
  severidade é o seu impacto.
- **Credenciais:** todo o texto livre do documento passa pelo mesmo
  `_refuse_if_secret` que já protege `title`/`rationale`/`remediation`/
  `partial_note`. Uma descrição de passo que cite uma chave é recusada com o
  nome do campo e a regra que casou — nunca com o texto.

**O que é obrigatório depende da situação, e a porta distingue-as com dados que
o ledger já tem.** Seja `existing` a linha deste fingerprint nesta análise,
quando existe — se foi cunhada por um scanner (`producer != 'agent'`) a
re-report é triagem (Job 2); se não há linha nenhuma, é um achado novo (Job 3)
ou o eco de uma linha `pending` (Job 1). A severidade que conta é a da própria
re-report.

| situação | `trace` | `intended_control` | `confidence` | `likelihood` + `impact` |
|---|---|---|---|---|
| `sast` a `medium`/`high`/`critical` — novo por `--snippet`, pré-passagem triada, ou `pending` *still present* | **obrigatório** (≥1 passo) | **obrigatório** | **obrigatório** | **obrigatórios** a `high`/`critical`; opcionais a `medium` |
| `sast` a `low`/`info` | opcional | opcional | **obrigatório** | opcional |
| `dependency` com `existing` de scanner (triagem) | opcional — é a alcançabilidade do CVE, o item 17 da spec de paridade sem schema extra | opcional | **obrigatório** | opcional |
| `secret` / `hygiene` / `iac` com `existing` de scanner (triagem) | **recusado** — um trace num segredo é um campo mal etiquetado | opcional | **obrigatório** | opcional |
| eco verbatim de linha `pending` determinística (sem `existing`) | `dependency`: opcional; restantes: recusado | opcional | opcional | opcional |

`conditions` é sempre opcional; tudo o que é opcional é validado quando
presente. `candidate` pode estar totalmente ausente apenas na última linha da
tabela.

**Armazenamento.** Coluna aditiva `finding.candidate TEXT NOT NULL DEFAULT ''`,
pelo padrão `PRAGMA table_info` + `ALTER TABLE ADD COLUMN` que `ledger.py` já
tem. O documento é guardado canónico —
`json.dumps(doc, sort_keys=True, ensure_ascii=False, separators=(",", ":"))` —
para que dois relatórios do mesmo achado sejam idênticos byte a byte. `prepare`
escreve sempre `''`. Uma re-report **substitui** o documento inteiro, como já
substitui a linha (uma re-report sem `candidate`, onde a porta o permite,
escreve `''`). **Nada disto entra no fingerprint nem no `diff`** — é descrição,
não identidade, e não muda nenhum dos oito estados.

**Saída.** `findings`, `checklist` e `findings-page` devolvem `candidate`
descodificado — objecto, ou `null` para `''` — em cada achado. É o que o
verificador do 4.2 vai ler.

### 3. Os guias: vendorizar, escolher, registar o que foi lido

**Vendorizar.** `skills/security-analysis/references/` recebe, byte a byte:

```
ATTACK-CLASSES.md
AI-AND-LLM.md
CLIENT-SIDE.md
CLOUD-AND-DEPLOYMENT.md
DATA-ISOLATION-AND-LIFECYCLE.md
DESKTOP-MOBILE-AND-LOCAL-IPC.md
MEMORY-SAFETY-AND-BINARY.md
PROTOCOLS-RPC-AND-MESSAGING.md
RESOURCE-EXHAUSTION-AND-AVAILABILITY.md
SUPPLY-CHAIN-AND-RELEASE.md
WEB-PROTOCOL-AND-AUTH.md
UPSTREAM.md
```

`UPSTREAM.md` regista o repositório, o SHA do commit de origem, a data, a
licença MIT com a atribuição exigida, e a regra: **nunca editar no sítio —
re-vendorizar** a partir de um SHA novo e actualizar este ficheiro. A skill
diz ao agente: "os guias são material de caça, não processo — onde um guia
fala de reportar ou validar, este ficheiro ganha".

**Escolher — `prepare` decide.** Um módulo novo `bin/security/guides.py` com
uma tabela `GUIDES` (nome → sinais) e uma função
`select(signals, profile) -> list[str]`. Os sinais vêm do que o `prepare` já
tem em mãos: os nomes normalizados do inventário de dependências, os caminhos
relativos que o scan de segredos percorre (sujeitos aos mesmos `ignore_paths`),
e o que a fase IaC encontrou.

| guia | sinais |
|---|---|
| ATTACK-CLASSES | sempre |
| WEB-PROTOCOL-AND-AUTH | deps: `express`, `koa`, `fastify`, `hapi`, `@nestjs/core`, `next`, `nuxt`, `flask`, `django`, `fastapi`, `starlette`, `tornado`, `rails`, `sinatra`, `laravel/framework`, `symfony/symfony`, `slim/slim`, `spring-boot`, `github.com/gin-gonic/gin`, `github.com/labstack/echo`, `github.com/go-chi/chi`, `github.com/gofiber/fiber`, `actix-web`, `axum`, `rocket` |
| CLIENT-SIDE | caminhos `*.html`, `*.jsx`, `*.tsx`, `*.vue`, `*.svelte`; deps `react`, `vue`, `svelte`, `@angular/core`, `jquery` |
| CLOUD-AND-DEPLOYMENT | a fase IaC encontrou Dockerfile/Terraform/Kubernetes/Helm/CloudFormation; caminhos `.github/workflows/*`, `serverless.yml`, `wrangler.toml`, `fly.toml`, `Procfile` |
| SUPPLY-CHAIN-AND-RELEASE | inventário não vazio, **ou** caminhos `.github/workflows/*`, `.gitlab-ci.yml`, `bitbucket-pipelines.yml`, `Jenkinsfile`, `.circleci/*` |
| AI-AND-LLM | deps `openai`, `anthropic`, `@anthropic-ai/sdk`, `langchain*`, `@langchain/*`, `llamaindex`, `llama-index*`, `mcp`, `@modelcontextprotocol/*`, `ai`, `transformers`; caminhos `CLAUDE.md`, `AGENTS.md`, `.claude/*`, `SKILL.md`, `*/SKILL.md`, `.mcp.json`, `mcp.json`, `.cursorrules` |
| MEMORY-SAFETY-AND-BINARY | caminhos `*.c`, `*.cc`, `*.cpp`, `*.h`, `*.hpp`, `*.rs`, `*.zig`, `Cargo.lock` |
| PROTOCOLS-RPC-AND-MESSAGING | caminhos `*.proto`; deps `grpc*`, `@grpc/*`, `grpcio`, `amqplib`, `pika`, `kafkajs`, `kafka-python`, `confluent-kafka`, `paho-mqtt`, `mqtt`, `ws`, `socket.io`, `websockets`, `nats` |
| DATA-ISOLATION-AND-LIFECYCLE | deps `sqlalchemy`, `prisma`, `@prisma/client`, `sequelize`, `typeorm`, `knex`, `drizzle-orm`, `gorm.io/gorm`, `diesel`, `mongoose`, `pg`, `mysql2`, `psycopg2*`, `psycopg`, `asyncpg`, `pymongo`; caminhos `*migrations/*`, `*db/migrate/*`, `*alembic/*` |
| DESKTOP-MOBILE-AND-LOCAL-IPC | deps `electron`, `@tauri-apps/api`, `react-native`, `expo`; caminhos `*.swift`, `*.kt`, `*.m`, `android/*`, `ios/*`, `*.xcodeproj/*` |
| RESOURCE-EXHAUSTION-AND-AVAILABILITY | sempre que WEB-PROTOCOL-AND-AUTH ou PROTOCOLS-RPC-AND-MESSAGING casa |

Nomes de dependência comparam-se em minúsculas, exactos ou por prefixo onde a
tabela diz `*`; os caminhos por `fnmatch` sobre o caminho relativo — e em
`fnmatch` o `*` atravessa `/`, por isso `.claude/*` apanha
`.claude/agents/x.md` e `*migrations/*` apanha `app/migrations/0001.py`, e é
por isso que a tabela escreve os padrões assim e não com `**`. Um guia
"casa" com ≥1 sinal; os casados ordenam-se por **número de sinais** (desempate
pela ordem da tabela). **O perfil põe o tecto:**

| perfil | lê |
|---|---|
| `quick` | ATTACK-CLASSES + o primeiro casado |
| `standard` | ATTACK-CLASSES + todos os casados |
| `deep` | todos os onze, casem ou não |

`prepare` lê o perfil da linha da análise, aplica o tecto, imprime
`"guides": {"recommended": [...]}` no seu JSON (ao lado de `coverage_note` e
`findings`) e grava a lista numa coluna aditiva
`analysis.guides TEXT NOT NULL DEFAULT ''` —
`{"recommended": [...], "read": [...]}`, nomes sem `.md`. `checklist` imprime
o mesmo objecto, que é por onde o agente o lê no Codex e no OpenCode (o
`prepare` corre engine-side nessas plataformas). A skill manda ler
`references/ATTACK-CLASSES.md` e depois cada guia da lista, pela ordem, antes
do Job 3; os parágrafos por plataforma de `security_prompt` passam a nomear o
directório (`$SKILLS_DIR/security-analysis/references/`) onde a skill é nomeada
por caminho.

**A selecção nunca faz o `prepare` falhar.** Uma excepção em `guides.py` é
registada, `recommended` fica `["ATTACK-CLASSES"]` e a nota de cobertura diz que
a selecção não correu. Guias são conselho; a fase determinística não cai por
causa dele.

**Registar o que foi lido — do stream.** No fecho engine-side
(`security_close_analysis` em `bin/agentloop`), um `jq` sobre o
`.stream.ndjson` do run recolhe os blocos `tool_use` cujo `input`
**serializado** contém `security-analysis/references/<NOME>.md` — apanha `Read`
no Claude Code e no OpenCode e o `cat`/`sed` via `Bash` no Codex, sem mapa por
plataforma — e passa os nomes a `finish --guides-read a,b`. Semântica do flag:
**ausente** → desconhecido; **presente e vazio** → nenhum lido. `finish` grava
`read` na coluna e acrescenta à nota da linha `sast` da tabela de cobertura, e
ao parágrafo `coverage_note`, uma frase de três formas:

- `Guides read: A, B. Recommended but not read: C.`
- `Guides read: none of the 3 recommended.`
- `Guides read: unknown (run stream unavailable).`

A frase é nota, não gate: não ler um guia é sinal de qualidade, não falha de
âmbito, e o `done` não desce por isso. O `finish` do próprio agente não leva o
flag — o segundo fecho, o do engine, é que o sabe.

### 4. Render e UI

**Relatórios** (`report.py`: `as_markdown`, `as_html`, `as_json` e os
`consolidated_*`): sob cada achado, depois das ocorrências, **só quando
`candidate` existe**, um bloco fixo —

- **Trace:** uma linha por passo, `kind · file:line · scope — description`,
  pela ordem guardada;
- **Intended control:** a frase;
- **Conditions:** `kind: description`, uma por linha;
- **Confidence:** `score — reason`; e na mesma linha **Likelihood** e
  **Impact** quando presentes, cada um `score — reason`.

Um achado sem documento — todos os antigos, todas as linhas determinísticas —
renderiza exactamente como hoje. No JSON o achado leva `candidate` como objecto
ou `null`. O `|` é escapado nas células de Markdown e o texto passa pelo escape
de HTML que o formato já usa: tudo isto é texto do agente, e o relatório não
pode ser um sink novo.

**Dashboard.** O ecrã Findings ganha:

- uma coluna **Confidence** — chip `low`/`medium`/`high`, vazia sem documento —
  ordenável;
- um filtro multi-selecção `confidence` ao lado do de severidade; os filtros
  guardados ganham a chave (uma chave ausente num filtro antigo é "sem filtro");
- o `q` de texto livre passa a cobrir o texto do documento — um `LIKE` sobre a
  coluna, sem parser.

Onde quer que um achado se mostre por inteiro — hoje `findings-screen.js`,
`analysis.js` e `index-screen.js` são os módulos que desenham `rationale` — o
bloco acima aparece sob o rationale, desenhado por **um módulo só**,
`ui/security/candidate.js`, montado nos três sítios, pela mesma regra que já
impede o Findings de existir como duas tabelas. Os números de postura (índice,
donut, Branches, Overview) não mexem: confiança não é exposição.

**API/CLI.** `/api/security/findings` e `findings-page` aceitam
`confidence=<lista>`; em `queries.py` é um ramo do `WHERE` com
`json_extract(candidate, '$.confidence.score')` — o único sítio que lê dentro
do JSON; `sort=confidence` ordena pela mesma expressão, com `''` no fim.

**Cobertura.** A frase dos guias vive na nota da linha `sast` da tabela de
cobertura, que os três relatórios e o ecrã da análise já desenham — nada novo
para renderizar.

`bash build/build-ui.sh` na mesma alteração; o selftest já recusa o artefacto
desactualizado.

### 5. O que muda, ficheiro a ficheiro

| ficheiro | mudança |
|---|---|
| `skills/security-analysis/SKILL.md` | secção "What qualifies as a finding"; guias no Job 3; `confidence` no Job 2; regras do Job 1; exemplo com `candidate` |
| `skills/security-analysis/references/*` | onze guias vendorizados + `UPSTREAM.md` |
| `bin/security/guides.py` (novo) | `GUIDES`, `select(signals, profile)` |
| `bin/security/cli.py` | validação de `candidate` em `report-finding`; `guides` em `prepare` e `checklist`; `--guides-read` em `finish`; `candidate` na saída de `findings`/`checklist`/`findings-page`; `confidence` como filtro e ordenação de `findings-page` |
| `bin/security/ledger.py` | colunas `finding.candidate`, `analysis.guides`; `record_finding` grava o documento canónico |
| `bin/security/queries.py` | filtro e ordenação por `confidence`; `q` sobre a coluna |
| `bin/security/report.py` | o bloco nos três formatos e no consolidado |
| `bin/agentloop` | `security_close_analysis` lê o stream e passa `--guides-read`; `security_prompt` nomeia `references/` nas plataformas que nomeiam a skill por caminho; `selftest` verifica que o SQLite do `python3` responde a `json_extract` |
| `bin/agentloop-server` | `confidence` em `/api/security/findings` |
| `ui/security/candidate.js` (novo), `findings-screen.js`, `analysis.js`, `index-screen.js`, `vocabulary.js` | o bloco, a coluna, o filtro |
| `bin/static/security.js` | reconstruído |
| `README.md` | a secção *Security analysis* ganha o documento, os guias e a frase de cobertura |
| `CHANGELOG.md` | por commit, como sempre |

---

## Âmbito

**Entra:** tudo o que está em *Desenho* — os itens 1, 2 e 5 da comparação.

**Fica de fora, para os sub-projectos seguintes:** a coluna `verdict`, os
verificadores por subagente e a abertura controlada do `Agent` (4.2); as
unidades de cobertura e o `capped` que as nomeia (4.3). `analysis.guides` e a
leitura do stream no fecho são as sementes de ambos.

**Fica de fora, de vez:** `execution`, `evidence`, sandbox, artefactos por run.

---

## Falhas e limites

- **Uma rota de evasão que a porta não vê:** baixar um `medium` para `low`
  escapa ao `trace` obrigatório. A skill proíbe-o por escrito; `confidence` é
  obrigatório a todas as severidades, por isso a dúvida fica pelo menos
  registada; e é o verificador do 4.2 que a apanha (um `low` com `impact` alto
  é um candidato a re-verificar). Fica registado como risco, não resolvido
  aqui.
- **Recusa à porta** — nomeia campo e regra, sai com erro, não escreve nada; o
  achado não desaparece em silêncio, e a skill diz para corrigir e reenviar.
- **Ledger antigo** — as duas colunas entram com `''`; tudo o que renderiza
  desenha nada para `''`. Uma linha `pending` de `sast` anterior ao schema,
  re-reportada *still present*, tem de vir agora com documento — o agente leu o
  código de qualquer forma.
- **Sinais filtrados por `ignore_paths`** — um `.github/**` ignorado esconde o
  sinal de CI; o guia não é recomendado e a nota diz o que foi recomendado. É
  o comportamento coerente com "o que foi ignorado não foi olhado".
- **Stream em falta no fecho** — o flag é omitido e a frase diz `unknown`;
  nunca afirma que nenhum guia foi lido.
- **Codex/OpenCode** — o `prepare` corre engine-side; a lista chega pelo
  `checklist`, e o parágrafo do prompt diz-o.
- **Custo** — `quick` lê dois ficheiros (~6k tokens); `deep` lê onze (~35k). O
  tecto por perfil é a decisão; a primeira análise depois do bloco mede.

---

## Testes e aceitação

Na disposição que `tests/security/` já tem:

- **`test_cli.py` — a porta**, parametrizada pela matriz da secção 2: cada
  obrigatório em falta, por situação; `trace` num `secret` recusado; caminho
  com `..` ou `/` inicial; 51 passos; passo duplicado; `severity` acima de
  `impact`; chave desconhecida; documento acima de 64 KB; recusa nomeia o
  caminho do campo. **O teste adversarial existente estendido ao documento:** a
  credencial injectada numa descrição de passo é recusada com o nome do campo
  e não aparece em ledger, relatório ou log. **Não é opcional**, como no bloco
  3.
- **`test_ledger.py`** — migração sobre uma base de antes das colunas; a
  re-report substitui o documento; uma re-report sem `candidate` escreve `''`;
  codificação canónica estável (duas gravações do mesmo objecto por ordens de
  chaves diferentes dão o mesmo texto).
- **`test_report.py`** — os três formatos e o consolidado, com e sem documento;
  **golden:** uma análise sem documentos renderiza byte a byte como antes do
  bloco; `|` e `<` no texto do agente não quebram tabela nem página.
- **`test_queries.py`** — filtro `confidence` (um valor, vários, nenhum);
  ordenação com `''` no fim; `q` apanha texto do documento.
- **`test_guides.py` (novo)** — tabela: sinais de fixture → lista esperada por
  perfil; ordenação por número de sinais e desempate; a regra
  RESOURCE-EXHAUSTION; **todo o guia que `GUIDES` nomeia existe em
  `references/`** e `UPSTREAM.md` nomeia um SHA de 40 hex — para a tabela e os
  ficheiros não divergirem; `select` a lançar não derruba o `prepare`.
- **fecho** — fixture de stream com `Read` (chave `file_path`), `read`
  (`filePath`, OpenCode) e `Bash` com `cat` a nomear referências → lista lida,
  sem duplicados; stream ausente → flag omitido → `unknown`; flag vazio →
  `none of the N recommended`.
- **`tests/test_page_contract.py`** — o parâmetro `confidence`, a coluna e o
  campo do filtro guardado ficam pinados; build + `node --check` + selftest.
- **Aceitação real:** uma análise `quick` deste repositório — guias
  recomendados (AI-AND-LLM, SUPPLY-CHAIN-AND-RELEASE e CLIENT-SIDE, pelo
  menos), lidos segundo o stream, pelo menos um `sast` com trace, o bloco nos
  três relatórios e no ecrã. No Codex, sonda de ambiente primeiro.

---

## Riscos

1. **O modelo pode escrever traces plausíveis sem ler o código.** O documento
   torna a mentira verificável — ficheiro e linha — mas não a impede. É o
   trabalho do 4.2.
2. **A tabela de sinais é um palpite informado.** Um projecto em Elixir ou PHP
   sem Laravel casa pouco. A tabela é dados, cresce por PR, e a nota de
   cobertura diz sempre o que foi recomendado.
3. **`json_extract` exige SQLite com JSON1** (incluído de série desde o
   3.38; antes disso só se compilado com a extensão). O `python3` das
   instalações que temos traz um SQLite recente, mas isso não é garantido em
   todo o lado: o `selftest` passa a executar `json_extract('{}', '$.a')` e a
   dizer a versão do SQLite se falhar, para que a falha seja um erro nomeado
   no arranque e não uma página Findings que rebenta ao filtrar.
4. **Os guias envelhecem.** `UPSTREAM.md` com SHA é o que permite re-vendorizar
   com diff legível; sem disciplina, divergem em silêncio.

---

## Ordem de execução

Uma branch, um PR: **`feat/security-candidates`**, com testes a passar no fim
de cada passo. A ordem que o plano deve seguir: schema e porta (ledger, CLI)
→ relatórios → guias (`guides.py`, `prepare`, `checklist`, referências) →
fecho e stream (`bin/agentloop`, `finish`) → UI → skill e README → aceitação
real.
