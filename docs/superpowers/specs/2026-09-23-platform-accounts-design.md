# Contas por plataforma — desenho

> Assenta em [`2026-09-11-platform-settings-design.md`](2026-09-11-platform-settings-design.md)
> (Settings › Platforms, `config/platforms.json`, os cartões por plataforma) e
> em [`2026-09-06-platforms-anthropic-openai-design.md`](2026-09-06-platforms-anthropic-openai-design.md)
> (a tabela de plataformas, o rollout do Codex, os limites por plataforma).
> Ambas implementadas e instaladas.
>
> Estado: desenho aprovado em brainstorming a 2026-09-23; por implementar.

---

## Contexto

Um cliente usa mais de uma conta do Claude e mais de uma do Codex, cada uma na
sua pasta de configuração (`CLAUDE_CONFIG_DIR` e `CODEX_HOME` são as variáveis
com que os dois CLIs escolhem a conta). O agentloop já teve uma parte disto: um
campo `claude_config_dir` por projecto e por bloco de segurança, que exportava
`CLAUDE_CONFIG_DIR` para o run. Saiu no PR #45 (`dc5851d`, 2026-09-11), por
decisão do operador na altura: a conta passou a ser só a da instalação (o pin
`AGENTLOOP_CLAUDE_CONFIG_DIR`). Um `projects.json` que ainda traga o campo é
ignorado, com um aviso em `status` e `install`. Do lado do Codex nunca existiu:
a spec das plataformas deixou a conta Codex por projecto fora da versão.

O operador pediu para a reactivar, e em brainstorming propôs uma forma melhor
do que a antiga: **as contas registam-se em Settings**, N por plataforma, e
**onde se escolhe a plataforma escolhe-se a conta e depois o modelo**
(Plataforma → Conta → Modelo) — no job, no projecto e no bloco de segurança.

Repor só a variável de ambiente não chegaria. Cinco sítios do motor assumem
hoje uma conta por plataforma:

1. **A porta de prontidão** (`run_refusals` → `platform_ready`) verifica a
   sessão da conta da instalação, não a do run: um run numa conta sem sessão
   passa a porta e morre no login.
2. **O travão dos limites de utilização** (`rl_gate`, `data/rate-limits.json`)
   tem uma leitura por plataforma: a janela de 5 h esgotada da conta B trava a
   conta A, e a leitura de A apaga a de B.
3. **O rollout do Codex** (modelo real e limites) é procurado em
   `${CODEX_HOME:-~/.codex}/sessions` do processo do motor: um run com outro
   `CODEX_HOME` perde-os.
4. **As skills** do agentloop estão ligadas em `~/.claude/skills` e
   `~/.codex/skills`, e o Claude Code lê as skills do utilizador de
   `$CLAUDE_CONFIG_DIR/skills` (medido, abaixo): numa outra conta os prompts
   citam skills obrigatórias — `security-analysis` incluída — que não existem.
   É também um defeito de hoje com o pin da instalação.
5. **O resume** procura a sessão na conta que o projecto tem *agora*; se a conta
   mudou desde o run, a sessão está noutra pasta e não é encontrada.

### O que ficou medido a 2026-09-23

| Facto | Consequência para o desenho |
|---|---|
| Claude Code 2.1.280, no próprio binário: as skills do utilizador vêm de `join(CLAUDE_CONFIG_DIR ?? ~/.claude, "skills")` | as skills do agentloop têm de ser ligadas na pasta de cada conta Claude, não só em `~/.claude/skills` |
| Claude Code 2.1.280: `CLAUDE_CONFIG_DIR=$HOME/.claude claude auth status` responde **sem sessão** (a entrada do Keychain ganha um sufixo com o hash da pasta sempre que a variável está definida, e o `.claude.json` passa a ser procurado dentro de `~/.claude/`); com barra final, também sem sessão | uma conta cuja pasta seja `~/.claude` corre **com a variável não definida**; a pasta é normalizada (sem barra final) antes de ser exportada ou comparada |
| Claude Code 2.1.280: `auth status` numa pasta vazia responde `loggedIn:false` e escreve lá `.claude.json`, um lock e `backups/` | verificar uma conta escreve na pasta dela; nunca se verifica `~/.claude` com a variável definida |
| codex-cli 0.153.4: `CODEX_HOME=<pasta vazia> codex login status` → "Not logged in", rc 1 | a regra de hoje (rc ≠ 0 é sem sessão) serve por conta |
| codex-cli 0.153.4: `CODEX_HOME=<pasta inexistente>` → "Error loading configuration: CODEX_HOME points to … but that path does not exist", rc 1 | a pasta de uma conta tem de existir; a porta recusa antes do lançamento, com a razão |

## Objectivo e âmbito

Uma plataforma passa a ter **contas**: a **Default** (a de hoje, sempre
presente) e as que o operador regista em Settings, cada uma com um nome e uma
pasta. Um job, um projecto e um bloco de segurança escolhem a conta como
escolhem a plataforma; o motor lança o CLI nessa conta e fica consciente dela
nos cinco sítios acima.

Decisões do operador em brainstorming (não reabrir):

- **Registo em Settings, escolha por lista** — não um caminho escrito à mão em
  cada projecto (a forma antiga).
- **Ordem Plataforma → Conta → Modelo** nos três editores; o selector de conta
  só aparece quando a plataforma tem contas registadas além da Default.
- **A conta vai para o job, o projecto e o bloco de segurança** — os mesmos
  níveis onde se escolhe a plataforma; um projecto escolhe a conta uma vez e os
  seus jobs herdam-na.
- **Anthropic e OpenAI**. OpenCode fica fora (ver *Fora desta versão*).

Decisões tomadas no desenho (o autor da spec decide):

- **Os modelos continuam por plataforma**, activados em Settings como hoje. O
  catálogo é do CLI; um plano sem acesso a um modelo falha no CLI com o erro
  dele, que o classificador mostra.
- **As sondas de modelos e os refreshes de catálogo correm na conta Default**,
  como hoje.
- **`platform enable` continua a exigir a Default com sessão** (é ela que as
  sondas usam). A mensagem de recusa diz como: iniciar sessão na pasta por
  omissão, ou fixar a instalação noutra conta Claude
  (`AGENTLOOP_CLAUDE_CONFIG_DIR`).
- **Remover uma conta em uso é recusado**, com a lista de quem a usa.
- **Os `claude_config_dir` antigos migram** no `install` para contas
  registadas.

## Configuração e dados

### `config/platforms.json`: a lista `accounts`

Cada plataforma Anthropic e OpenAI ganha uma lista opcional `accounts`. A
Default não está na lista.

```json
{"platforms": {
  "anthropic": {"enabled": true, "bin": "", "models": ["claude-opus-5-5"],
                "accounts": [{"id": "cliente-a", "name": "Cliente A", "dir": "~/.claude-cliente-a"}]},
  "openai":    {"enabled": true, "bin": "", "models": ["gpt-6-astra"],
                "accounts": [{"id": "cliente-a", "name": "Cliente A", "dir": "~/.codex-cliente-a"}]}
}}
```

- `id` — gerado do nome no registo (minúsculas, `[a-z0-9-]`, sem hífens nas
  pontas, até 40 caracteres; vazio passa a `account`; um repetido ganha `-2`,
  `-3`…). **Nunca muda**: renomear muda só o `name`. `default` é reservado.
  Único dentro da plataforma — o mesmo id em Anthropic e OpenAI são duas contas.
- `name` — texto livre, não vazio, único dentro da plataforma sem distinguir
  maiúsculas.
- `dir` — guardado como foi escrito, sem barra final (`~/…` fica com `~`, como
  o `bin`). Tem de ser absoluto depois de expandir o `~`.
- Uma lista ausente é uma lista vazia. Um elemento malformado (sem `id`, `name`
  ou `dir` em texto) é ignorado na leitura e nunca escrito.

### A conta Default

Id `default`, nome "Default", sempre presente, não editável nem removível. É a
conta de hoje:

- **Anthropic:** o pin da instalação (`installed_config_dir`: a variável, senão
  o plist) quando existe, senão a pasta do CLI (`~/.claude`).
- **OpenAI:** o `CODEX_HOME` do processo do motor quando existe, senão
  `~/.codex` (o launchd não o define, por isso os runs agendados usam
  `~/.codex`, como hoje).

### O campo `account` em job, projecto e bloco `security`

Um texto: vazio ou ausente (herda), `default` (a Default, explicitamente), ou o
`id` de uma conta registada **na plataforma efectiva** desse nível.

A regra de resolução — **a conta do projecto aplica-se ao que corre na
plataforma do projecto**:

- **Job:** o `account` do próprio job, se não for vazio. Senão, o do projecto,
  se o job tiver projecto e a sua plataforma efectiva for a do projecto
  (`project.platform`, senão `anthropic`). Senão, `default`.
- **Bloco `security`:** o `account` do bloco, se não for vazio. Senão, o do
  projecto, se a plataforma efectiva do bloco for a do projecto. Senão,
  `default`.
- **Projecto:** o seu `account`, senão `default`.

Um job cujo editor grava sempre a plataforma herda na mesma a conta do
projecto: a regra compara plataformas efectivas, não a presença do campo.

### A pasta normalizada e o valor exportado

Duas funções que todo o resto usa:

- `account_norm_dir <texto>` — expande o `~` (`expand_home`), tira as barras
  finais e exige um caminho absoluto. Um texto que não passe é recusado por
  quem o recebe.
- **O valor exportado** (`account_dir` daqui em diante) — a pasta normalizada,
  **ou vazio quando é a pasta por omissão do próprio CLI** (`$HOME/.claude`
  para o Claude, `$HOME/.codex` para o Codex). Vazio quer dizer "a variável
  não definida". No Claude é obrigatório (o Keychain, medido); no Codex é
  equivalente, e fica igual para as duas plataformas.

O `account_dir` da Default: Anthropic — o pin normalizado (vazio sem pin ou com
um pin em `~/.claude`, o que corrige hoje uma armadilha do pin); OpenAI — o
`CODEX_HOME` do processo normalizado (vazio sem ele).

### Journal: `account` e `account_dir`

Cada registo de run ganha `account` (o id, `default` incluído) e `account_dir`
(o valor exportado, vazio quando a variável não foi definida). Um registo
anterior a esta versão não tem as chaves.

### `data/rate-limits.json`: uma leitura por conta

As chaves de hoje (`anthropic`, `openai`) passam a ser as leituras das contas
cujo `account_dir` é vazio (a pasta por omissão do CLI). Qualquer outra conta
lê e escreve na chave `<plataforma>@<account_dir>`, ao lado:

```json
{"anthropic": {"five_hour": {…}, "seven_day": {…}},
 "anthropic@/Users/me/.claude-cliente-a": {"five_hour": {…}},
 "openai": {…}}
```

Chave pela **pasta**, não pelo id: o statusline, que corre dentro de uma sessão
interactiva, sabe a sua pasta (`CLAUDE_CONFIG_DIR`) e não conhece o registo.
Uma instalação com uma só conta e sem pin não vê nada mudar. Com pin, os runs
Default passam a usar `anthropic@<pin>`: as leituras antigas em `anthropic`
deixam de os travar até à próxima leitura (dito no CHANGELOG).

### Migração do `claude_config_dir`

`agentloop install` converte, antes de imprimir os avisos, o que encontrar em
`projects.json`:

- Um `claude_config_dir` com a mesma pasta normalizada que a Default é a
  Default: o campo sai e nada é escrito no seu lugar. Uma pasta que já seja de
  uma conta registada usa essa conta. Qualquer outra regista uma conta
  Anthropic nova, com o nome tirado do nome da pasta sem o ponto inicial
  (`~/.claude-work` → `claude-work`).
- **No projecto:** se a plataforma do projecto for Anthropic, o projecto ganha
  `account` (quando ainda não tem um) e perde o campo antigo.
- **No bloco:** o mesmo, se a plataforma efectiva do bloco for Anthropic.
- Quando a plataforma não é Anthropic, o campo fica no ficheiro com um aviso a
  dizer porquê (a conta nova só se aplica à plataforma do nível). Uma linha por
  conversão.

O aviso de `legacy_config_dir_warning` muda de texto: o campo já não é lido, e
`agentloop install` converte-o.

## Engine (`bin/agentloop`)

### Registo

| Função | Faz |
|---|---|
| `accounts_json <p>` | a lista `accounts` da plataforma, só os elementos válidos (`[]` para OpenCode) |
| `account_known <p> <id>` | 0 para `default` e para um id registado em `p` |
| `account_field <p> <id> <name\|dir>` | o campo; para `default`, o nome "Default" e a pasta de visualização (o pin ou `~/.claude`; o `CODEX_HOME` ou `~/.codex`) |
| `account_norm_dir <texto>` | acima |
| `account_env_dir <p> <id>` | o `account_dir` da conta (acima) |
| `job_account <id>` | a conta efectiva de um job, pela regra de resolução |
| `account_users <p> <id>` | quem usa a conta, uma linha por job (`<id>`), projecto (`project:<nome>`) e bloco (`security:<nome>`) — configuração, ligados ou não, como `platform_jobs_on` |
| `account_slug <nome>` | o id gerado (sem sufixo) |

`PLATFORMS_JQ` ganha as defs para a resolução em jq (`job_account($j)`,
`sec_account($p)`), para `account_users` e para o servidor seguir a mesma regra.

### Comandos

`agentloop platform` ganha quatro verbos, só para `anthropic` e `openai`
(OpenCode responde "OpenCode has no accounts — its credentials are the
providers you configure in opencode itself"):

- `platform accounts <p>` — JSON, uma entrada por conta, a Default primeiro:
  `{id, name, dir, account_dir, builtin, check: {ready, account, reason},
  used_by: {jobs, projects, security}}`, com a verificação ao vivo de cada uma.
- `platform account-add <p> <nome> <pasta>` — valida, gera o id, grava, liga
  as skills na pasta e responde `account '<nome>' added (id <id>) — <verificação>`.
- `platform account-edit <p> <id> <nome> <pasta>` — os mesmos testes (a conta
  pode manter o seu nome e a sua pasta); uma pasta nova liga as skills lá.
- `platform account-remove <p> <id>` — recusa enquanto `account_users` não
  vier vazio.

`platform check <p> [<id>]` verifica uma conta (a Default sem id). O JSON
ganha `account_id` e `account_dir`. As razões passam a nomear a pasta quando
ela não é a por omissão:

- Anthropic: `claude is not signed in in <pasta> (run: CLAUDE_CONFIG_DIR=<pasta> claude auth login)`.
- OpenAI: `codex is not signed in in <pasta> (run: CODEX_HOME=<pasta> codex login)`.

Validação no registo e na edição (uma frase por recusa):

- nome vazio, ou já usado nesta plataforma;
- pasta vazia, relativa, ou com `~utilizador`;
- pasta que não existe. Para Claude: "`<pasta>` does not exist — create it by
  signing in: `CLAUDE_CONFIG_DIR=<pasta> claude auth login`". Para Codex:
  "`mkdir -p <pasta> && CODEX_HOME=<pasta> codex login`";
- pasta igual à da Default ou à de outra conta registada nesta plataforma
  (comparadas normalizadas);
- o registo **não** exige sessão: responde com o estado dela.

### Validação na escrita dos níveis

- `set-field <job> account` — vazio limpa (herda), `default`, ou um id de
  `accounts_json` da plataforma efectiva do job; qualquer outro valor é
  recusado com a lista das contas dessa plataforma.
- `set-field <job> platform` — um `account` próprio do job que não exista na
  plataforma nova é limpo e dito ("account 'x' is not an openai account —
  cleared, the job inherits"), como já acontece ao modelo, ao esforço e ao
  modo.
- `create` — aceita `account`, com a mesma validação.
- `project-set` — `account` e `security.account` enviados têm de existir na
  plataforma efectiva desse nível (o projecto: a enviada, senão a guardada,
  senão `anthropic`; o bloco: a sua, senão a do projecto). Um `account`
  **guardado** que deixa de valer porque a plataforma mudou é limpo e dito. O
  código que hoje apaga `claude_config_dir` e diz "is ignored since this
  version" sai.

### Lançamento

`run_job` resolve a conta a seguir à plataforma:

- **Run novo:** `job_account` e `account_env_dir`.
- **Resume:** o `account` e o `account_dir` do registo do run retomado (lidos
  como `journal_platform_of_session` lê a plataforma). Sem as chaves (um
  registo antigo), a resolução de um run novo.

`run_refusals` recebe a conta e acrescenta, depois das portas do operador e
antes da prontidão:

- conta que não existe na plataforma: "account '<id>' is not an account of
  <p> in Settings, skipped";
- OpenCode com uma conta que não é a Default: "OpenCode has no accounts,
  skipped";
- pasta da conta em falta: "account '<nome>' is missing its directory
  (<pasta>), skipped".

A porta de prontidão passa a `platform_ready <p> <conta>`. A ordem das portas
fica: planned → unknown → disabled → no model enabled → **conta** → not ready
(da conta) → openai → opencode → model not enabled.

O ambiente do CLI leva exactamente o `account_dir`. `run_env` começa por
`-u CLAUDE_CONFIG_DIR` (Anthropic) ou `-u CODEX_HOME` (OpenAI), seguido de
`VAR=<account_dir>` quando não é vazio; as três linhas de lançamento já passam
`run_env` a `env`, que aplica o `-u` antes das atribuições. O precheck (dentro
de `run_job`, e também `agentloop precheck` e `agentloop check`) corre com o
mesmo ambiente: `unset` e depois `export` quando não é vazio. As sondas de
modelos e os refreshes de catálogo não mudam (Default).

`record_run` grava `account` e `account_dir`. `platform_finish` e
`openai_rollout_for` recebem a pasta do Codex do run (o `account_dir`, senão
`$HOME/.codex`) e procuram lá o rollout. A linha de `tick.log` quando não o
encontram nomeia essa pasta.

`rl_capture`, `rl_capture_openai` e `rl_gate` recebem a chave da conta
(`rl_key <p> <account_dir>`). A frase do travão acrescenta a conta quando não
é a Default ("the anthropic five_hour window of Cliente A is 96% used …"); o
resto da linha de `tick.log` ("usage limit reached — … — skipping") não muda,
porque é o que o servidor classifica.

### Os jobs de segurança derivados

`security_derived_jobs` resolve a conta do bloco pela regra acima e põe-na no
job derivado (`account`) quando não é `default`. Uma conta do bloco que não
exista na plataforma efectiva do bloco cai para a Default, com um aviso
(`security_warn`), como hoje cai um modelo desconhecido.

### Skills

As skills passam a ser ligadas em todas as pastas de conta:

- **Anthropic:**
  - `~/.claude/skills`, sempre (o OpenCode e as sessões interactivas do
    operador lêem-na);
  - a pasta da Default quando o `account_dir` dela não é vazio (o pin);
  - a pasta de cada conta registada cujo `account_dir` não é vazio.
- **OpenAI:**
  - a pasta da Default (a de hoje);
  - a de cada conta registada.
- **Nunca se cria uma pasta de conta:** se não existir, fica de fora, como
  hoje com o `~/.codex`.

`cmd_skills` percorre essa lista. `install` e `skills install` ligam. Registar
ou mudar a pasta de uma conta liga as skills nessa pasta, e `status` diz quantas
faltam por conta.

### `status`, `install` e `usage`

- `status_platforms_block` acrescenta, a seguir à linha de cada plataforma, uma
  linha por conta registada: nome, pasta, estado ("signed in as …" ou a razão),
  quem a usa e as skills em falta. A linha da plataforma continua a ser a da
  Default.
- `install` corre a migração antes dos avisos e imprime as contas no bloco
  "Platforms".
- `agentloop usage` lista as leituras por conta (a chave nua é a Default ou a
  conta cuja pasta é a do CLI; `@pasta` é mostrada com o nome da conta
  registada com essa pasta, ou "no longer an account" quando nenhuma a tem). A
  verificação do statusline passa a ser por conta Anthropic: o `settings.json`
  de cada pasta (`~/.claude/settings.json` para a pasta por omissão).

## Statusline (`bin/statusline-rate-limits.sh`)

- **Chave:** a leitura vai para `anthropic` quando o `CLAUDE_CONFIG_DIR` da
  sessão está vazio ou normalizado é `$HOME/.claude`; senão, para
  `anthropic@<pasta normalizada>`.
- **Intervalo mínimo entre escritas:** conta dentro dessa chave.
- **Migração do formato antigo (janelas no topo do ficheiro):** fica como está,
  só para `anthropic`.
- Para alimentar o travão de uma conta, o `statusLine` tem de estar no
  `settings.json` dessa conta (o `usage` diz qual falta).

## Servidor (`bin/agentloop-server`)

- **`/api/models`:** cada entrada `anthropic` e `openai` de `platforms` ganha
  `accounts: [{id, name, dir}]`, lida do ficheiro sem verificação (os editores
  só precisam da lista). OpenCode não tem a chave.
- **Acções**, no mesmo encaminhamento (`platform_action`):
  - `platform_accounts {platform}` → `{ok, accounts}`, com as verificações ao
    vivo que o engine devolve;
  - `platform_account_add {platform, name, dir}`;
  - `platform_account_edit {platform, id, name, dir}`;
  - `platform_account_remove {platform, id}`;
  - `platform_check {platform, account?}`.
  O engine valida e recusa; o servidor só dá forma ao pedido e devolve a
  resposta.
- **`set_field` do job:** aceita `account` na lista de campos que já encaminha.
- **Índice de runs:** colunas `account TEXT` e `account_dir TEXT`, com
  `SCHEMA_VERSION` a passar para `"7"`; a mudança de versão já provoca a
  releitura completa do journal. O detalhe de um run (`/api/run…` e o
  resultado da pesquisa) passa a levar os dois campos.
- **A regra de resolução em Python** (`_job_account`), espelho de
  `job_account`, para contar e para o detalhe mostrar a conta de um run vivo
  (que ainda não está no journal), como já se faz com `_job_platform`.

## UI

### Settings › Platforms: o bloco Accounts

Nos cartões Anthropic e OpenAI, o bloco *Session* passa a *Accounts*:

- **Linhas:** uma por conta, a Default primeiro.
- **Cada linha:** o nome, a pasta (em `code`) e o estado ("Signed in as …",
  ou a razão com o comando para iniciar sessão), com os mesmos ícones e classes
  do bloco de hoje.
- **Default:** não tem acções; as outras linhas têm *Edit* e *Remove*.
- **Test:** re-verifica todas as contas (`platform_accounts`).
- **"+ Add account":** abre um formulário na própria linha (nome, pasta com
  *Browse…* pelo selector de pastas que o editor de projectos já usa,
  *Save* e *Cancel*). A resposta do engine fica no cartão (`.platnote`), tal
  como o campo *Binary* já faz.
- **Remove numa conta em uso:** a recusa lista quem a usa.
- **Estado do cartão:** o chip e o "Not signed in" continuam a ser os da
  Default.
- **OpenCode:** mantém o bloco *Session*.

### Editores

- **Os três editores** (job, projecto e o separador Security do projecto)
  ganham um combo *Account* logo a seguir ao combo *Platform* e antes do
  *Model*: `ed-account`, `pj-account` e `sec-account`.
- **Visibilidade:** o combo só aparece quando a plataforma efectiva do editor
  tem contas registadas. Sem nenhuma, fica escondido e o valor enviado é vazio.
- **Opções:**
  - a linha vazia, que diz o que ela resolve pela regra de resolução:
    - "— Project's account (Cliente A) —" quando resolve na conta registada do
      projecto (um job ou bloco na plataforma do projecto, com o projecto
      numa conta que não é a Default);
    - "— Default —" em todos os outros casos, e sempre no projecto;
  - "Default — <pasta>";
  - uma linha "Nome — pasta" por conta.
- **Mudar a plataforma:**
  - reconstrói a lista;
  - uma conta que não exista na plataforma nova volta a vazio;
  - no job, a ordem de gravação continua a ser a plataforma primeiro.
- **Gravação:**
  - job: `set_field account`;
  - projecto: `account` sempre enviado (vazio limpa), como `platform`;
  - Security: `security.account` sempre enviado, como os outros campos do
    bloco.
- **Uma conta que já não esteja na lista** (removida à mão no ficheiro)
  aparece assinalada, como um modelo desligado, em vez de ser reescrita em
  silêncio.

### Detalhe de um run

- **Linha *Account*:**
  - mostra o nome da conta (o id quando já não está em Settings, com "no
    longer in Settings") e a pasta;
  - aparece quando `account` não é `default` ou quando `account_dir` não é
    vazio; uma instalação com uma só conta e sem pin não vê nada novo.
- **Comando de reabrir:** leva o prefixo quando `account_dir` não é vazio:
  - `CLAUDE_CONFIG_DIR=<pasta> claude --resume <sid>`;
  - `CODEX_HOME=<pasta> codex exec resume <thread>`.

## Erros

| Situação | Resposta |
|---|---|
| job com uma conta removida à mão do ficheiro | recusado no lançamento ("… is not an account of …"); o editor mostra-a assinalada |
| conta sem sessão | recusado no lançamento com a razão e o comando de login; o cartão mostra a mesma razão |
| pasta da conta apagada | recusado no lançamento ("… is missing its directory …") |
| conta do bloco de segurança inválida | o job derivado cai na Default, com aviso |
| `account-remove` numa conta em uso | recusado, com a lista |
| resume de um run cuja conta foi removida ou mudou de pasta | corre na pasta que o run usou (o registo manda); a porta de prontidão verifica essa pasta |
| `claude_config_dir` num projecto que não corre em Anthropic | fica no ficheiro, com aviso no `status` e no `install` |
| a Default sem sessão e uma conta registada com sessão | `platform enable` recusa (a Default é a das sondas); os jobs já activados na conta registada correm |

## Testes

- **Fakes:**
  - `test/fake-claude` responde a `auth status` sem sessão quando existe
    `$CLAUDE_CONFIG_DIR/.fake-logged-out`, além do `FAKE_CLAUDE_LOGGED_OUT`
    de hoje;
  - `test/fake-codex` faz o mesmo em `login status` com
    `$CODEX_HOME/.fake-logged-out`, e grava o `CODEX_HOME` com que foi lançado
    em `FAKE_ACCOUNT_OUT` (vazio quando não o tem), como já faz o fake-claude.
- **selftest (verificações dirigidas):**
  - registo: id, sufixos, nomes e pastas repetidos, pasta relativa ou
    inexistente, igual à Default;
  - edição e remoção em uso;
  - normalização (barra final, `~`, `$HOME/.claude` e `$HOME/.codex` →
    vazio);
  - `job_account` nos casos da regra;
  - `set-field account` e `set-field platform` a limpar;
  - `project-set`;
  - derivados;
  - migração do `claude_config_dir`;
  - chaves e travão por conta, e o statusline com e sem `CLAUDE_CONFIG_DIR`;
  - skills por conta;
  - `status` e `usage`;
  - OpenCode recusa contas;
  - a ordem das portas.
- **e2e (cenários novos a seguir aos que o `main` tiver):**
  - um job numa conta Claude registada lança com `CLAUDE_CONFIG_DIR`, o que
    o fake grava;
  - um job numa conta Codex registada lança com `CODEX_HOME`, e o `model_id`
    vem do rollout escrito nessa pasta;
  - uma conta cuja pasta é a do CLI lança sem a variável;
  - uma conta sem sessão é recusada e a Default não;
  - o resume corre na conta do registo depois de o projecto ter mudado de
    conta;
  - o travão de uma conta não trava a outra.
- **pytest:**
  - as quatro acções novas e o `platform_check` com `account`;
  - `/api/models` com `accounts`;
  - a migração do índice (schema 7) e os dois campos no detalhe;
  - contrato da página: os três combos, o bloco Accounts, o prefixo do
    comando de reabrir e os payloads de gravação.

## Aceitação real

Numa configuração de rascunho (`AGENTLOOP_CONFIG`/`AGENTLOOP_DATA` numa pasta
temporária, servidor numa porta ≠ 8787, nunca a instalação viva), com os CLIs
reais e o modelo mais barato de cada plataforma:

1. **Claude.**
   - Montagem:
     - o pin da instalação de rascunho aponta para uma pasta vazia (a Default
       fica sem sessão; o `platforms.json` de rascunho é escrito à mão com a
       plataforma activada, porque o `enable` recusaria);
     - regista-se a conta "Home" com a pasta `~/.claude`.
   - Resultados esperados:
     - um job na Default é recusado ("not signed in in <pasta>");
     - um job em "Home" corre e termina `success`, o que só acontece porque o
       run sai com `CLAUDE_CONFIG_DIR` por definir. Prova a escolha da conta e
       o caso do Keychain.
2. **Codex.** O mesmo, com o `CODEX_HOME` do processo a apontar para uma pasta
   vazia e a conta "Home" em `~/.codex`. O run corre, e o `model_id` e os
   limites vêm do rollout em `~/.codex/sessions`.
3. **Página.** No browser, com o servidor de rascunho:
   - o bloco Accounts com as duas contas e os seus estados;
   - o combo Account nos três editores;
   - a linha Account e o comando de reabrir no detalhe dos dois runs.

## Documentação

- **README:** uma secção "Accounts" com:
  - Settings › Platforms e os comandos `platform account-*`;
  - a regra de resolução;
  - a pasta por omissão e o `~/.claude`;
  - os limites por conta e o statusline por conta;
  - as skills;
  - o que corre sempre na Default.

  As secções que hoje dizem que a conta é só a da instalação são corrigidas.
- **CHANGELOG:** entradas em *Added* (contas por plataforma) e *Changed* (a
  chave dos limites com pin, o aviso do `claude_config_dir`, as skills também
  na pasta do pin). Cada commit de código toca o CHANGELOG (regra do
  selftest).

## Fora desta versão

- **OpenCode.** A conta dele é a pasta de configuração e de dados
  (`XDG_CONFIG_HOME` + `XDG_DATA_HOME`), que também muda a configuração do git
  e do gh dentro do run, e o CLI não está nesta máquina para medir. Quando
  entrar, entra como uma conta desta lista, com a mesma regra.
- Modelos por conta, e sondas ou catálogos numa conta que não a Default.
- Um pin de instalação para o Codex (`AGENTLOOP_CODEX_HOME`). A Default do
  Codex continua a ser o `CODEX_HOME` do processo, ou `~/.codex`.
- Mostrar a conta na tabela de runs e no Overview.

## Ordem de implementação, para o plano

1. **Registo.**
   - `accounts` em `platforms.json`, as funções, os quatro verbos e
     `platform check <p> [<id>]`;
   - as skills por conta;
   - selftest.
2. **Resolução e escrita.**
   - `job_account` e as defs em jq;
   - a validação de `set-field`, `create` e `project-set`;
   - os derivados;
   - a migração no `install` e o aviso novo;
   - selftest.
3. **Lançamento.**
   - a porta da conta e a prontidão por conta;
   - o ambiente do agente e do precheck;
   - o journal, o resume e o rollout;
   - fakes;
   - selftest e e2e.
4. **Limites.**
   - `rl_key` e o travão por conta;
   - o statusline;
   - `usage` e `status`;
   - selftest.
5. **Servidor.**
   - `/api/models`, as acções e `set_field`;
   - o índice (schema 7) e o detalhe;
   - pytest.
6. **Página.**
   - o bloco Accounts;
   - os três combos;
   - o detalhe do run;
   - os bundles (`bash build/build-ui.sh`);
   - o contrato da página.
7. **Fecho.**
   - README e CHANGELOG consolidados;
   - aceitação real.
