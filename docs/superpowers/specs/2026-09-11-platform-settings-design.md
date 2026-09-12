# Settings › Platforms — desenho

> Primeira de duas entregas. Esta desenha a página de Settings, o registo de
> plataformas activadas (`config/platforms.json`) e o que os editores passam a
> oferecer. A segunda — **o motor OpenCode** — começa por uma fase de medição
> do CLI (não está instalado nesta máquina) e acrescenta o terceiro ramo à
> tabela de plataformas que esta entrega deixa preparada.
>
> Assenta em [`2026-09-06-platforms-anthropic-openai-design.md`](2026-09-06-platforms-anthropic-openai-design.md)
> (a tabela de plataformas, o catálogo por plataforma, `/api/models`), já
> implementada e instalada.
>
> Estado: desenho aprovado em brainstorming a 2026-09-11; por implementar.

---

## Contexto

O agentloop lança um agente headless por job em uma de duas plataformas —
Claude Code (`anthropic`) ou Codex CLI (`openai`). A tabela de plataformas no
engine sabe encontrar cada binário, perguntar se há sessão e ler o catálogo de
modelos; o servidor espelha tudo em `/api/models`; o editor de jobs tem um
combo *Platform* → *Model*. O que **não** existe é a noção de plataforma
**configurada**: qualquer job pode nomear qualquer uma das duas, com qualquer
modelo do catálogo, e só descobre no lançamento (uma linha no `tick.log`) que
o `codex` não tem sessão ou que o modelo é o mais caro do catálogo. O botão
*Settings* da barra lateral existe mas está escondido, com uma página "Not
built yet".

O operador pediu: em Settings, escolher **que plataformas quer usar**; ver e
poder corrigir **onde está o binário** de cada uma; **testar se a sessão está
autenticada**; só depois **carregar os modelos** e escolher, um a um, os que
ficam disponíveis; nos jobs, escolher **apenas** entre plataformas e modelos
configurados; ser **avisado** de que sem uma plataforma configurada não
consegue configurar nenhum job; e abrir caminho ao **OpenCode**, com os
modelos que o operador lá tiver configurado. Pediu ainda que saia a escolha,
por projecto, de uma conta Claude alternativa (`claude_config_dir`), que
considera desnecessária.

### O que ficou medido a 2026-09-11

| Facto | Consequência para o desenho |
|---|---|
| `claude auth status --json` (Claude Code 2.1.258): `rc 0` com sessão e JSON com `loggedIn`, `email`, `subscriptionType`, `authMethod`; `rc 1` e `loggedIn:false` sem sessão; honra `CLAUDE_CONFIG_DIR`; 0,14 s | a sonda Anthropic passa a dizer **quem** está autenticado, não só que o binário existe |
| `codex login status` (codex-cli 0.153.4): `rc 0` + "Logged in using ChatGPT" com sessão; `rc 1` + "Not logged in" sem sessão (medido com um `CODEX_HOME` vazio — a medição em falta da spec anterior); 0,04 s | a regra "qualquer rc ≠ 0 é sem sessão" fica confirmada |
| `claude --version` 0,00 s; `codex --version` 0,03 s | as sondas podem correr ao vivo sempre que a página abre; nada precisa de ser guardado |
| `opencode` não está instalado; `brew info opencode` → 1.18.30; `npm view opencode-ai` → 1.18.30 | o cartão OpenCode desta entrega mostra a instrução de instalação; o stream e os formatos de `opencode auth list` / `opencode models` só se medem na entrega 2 |
| `resolve_family` (Anthropic) corre `claude -p` por família e sonda ids candidatos: chamadas reais à API | o refresh completo Anthropic **não** pode correr dentro de um pedido; fica na passagem diária do tick, como hoje |
| a lista Anthropic de `/api/models` vem de uma leitura instantânea (ids no binário + famílias em cache + ids em uso) | "carregar modelos" no cartão Anthropic é essa leitura |

## Objectivo e âmbito

Uma plataforma passa a ter três estados que o operador controla — encontrada,
verificada, **activada** — e um conjunto de modelos activados. O editor de
jobs, o de projectos e o bloco `security` oferecem só o que está activado; o
engine recusa no lançamento o que deixou de estar. A dashboard avisa enquanto
nada estiver configurado. O `claude_config_dir` por projecto e por bloco de
segurança sai; a conta é a da plataforma, visível no seu cartão.

Decisões tomadas pelo operador em brainstorming e não reabertas aqui:

- **Modelo a modelo.** Cada modelo carregado tem um interruptor; só os ligados
  aparecem nos jobs. (Alternativas recusadas: todo o catálogo de uma
  plataforma activada; escolher também um modelo por omissão.)
- **Duas entregas.** Settings agora, com o OpenCode como cartão *planned*; o
  motor OpenCode depois de medido.
- **`config/platforms.json` como fonte única** (abordagem A). Recusadas: as
  `prefs` do `app.db` (o engine não lê o `app.db`, e a regra da casa é o
  inverso — o engine é dono da configuração, o servidor espelha) e flags
  `enabled` dentro de `config/models.json` (é uma cache reescrita pelo
  refresh diário; a intenção do operador não pode viver numa cache).
- **Sai o `claude_config_dir` de projecto e de bloco de segurança.** Fica o
  pin de instalação `AGENTLOOP_CLAUDE_CONFIG_DIR`.

## Configuração e dados

### `config/platforms.json`

Ficheiro novo, pessoal (entra no `.gitignore` ao lado de `jobs.json` e
`pricing.json`), lido pelo engine com `jq` e espelhado pelo servidor:

```json
{
  "platforms": {
    "anthropic": { "enabled": true,  "bin": "", "models": ["claude-opus-5", "claude-sonnet-5"] },
    "openai":    { "enabled": true,  "bin": "", "models": ["gpt-5.6-luna"] },
    "opencode":  { "enabled": false, "bin": "", "models": [] }
  }
}
```

- **`enabled`** só passa a `true` por `agentloop platform enable`, que corre a
  verificação e recusa quando ela falha. A página só desbloqueia o interruptor
  depois do teste passar.
- **`bin`** é o caminho do binário; vazio significa detecção automática.
  Precedência em `platform_bin`: a variável de ambiente de hoje
  (`AGENTLOOP_CLAUDE_BIN`, `AGENTLOOP_CODEX_BIN`; `AGENTLOOP_OPENCODE_BIN` na
  entrega 2 — testes e stand-ins) → `bin` do ficheiro → detecção: `command -v <cli>`,
  depois os caminhos conhecidos (`~/.local/bin/claude`;
  `/opt/homebrew/bin/codex`; `/opt/homebrew/bin/opencode`,
  `~/.opencode/bin/opencode`). O caminho que a página mostra é o que o
  **launchd** vê, que é o que conta para os runs agendados — um `claude` que
  só existe no PATH da shell interactiva aparece como não encontrado, e o
  campo `bin` é a correcção.
- **`models`** são ids exactos activados, na ordem em que foram ligados. A semente
  guarda o id em que o valor do job resolve (uma família como `opus` fica
  como está se a cache ainda não a conhece); `platform_model_enabled` aceita
  um valor quando a lista contém o próprio valor ou o id em que ele resolve.
- **A verificação não é guardada.** Versão, conta, pronto ou razão são
  produzidos ao vivo: quando a página de Settings abre, quando o operador
  carrega em *Test*, e antes de cada run, como hoje.
- **`config/models.json` continua a ser só cache.** "Carregar modelos" no
  cartão é o refresh do catálogo dessa plataforma seguido da leitura; a
  escolha vive no ficheiro novo, e um refresh nunca a toca. Um modelo activado
  que desapareça do catálogo fica marcado "no longer in the catalog" na
  página e continua na lista até ser desligado.

### Semente e migração

Ficheiro ausente → `platforms_ensure` cria-o na primeira leitura:

- para cada plataforma do registo, `in_use` = jobs com `enabled != false`
  cuja `job_platform` é essa plataforma, mais projectos com
  `security.enabled == true` cuja plataforma efectiva de segurança é essa;
- `enabled` = `in_use` não vazio; `models` = os modelos desses jobs e blocos,
  resolvidos pela cache de famílias, sem repetições, na ordem em que aparecem
  (jobs primeiro, blocos de segurança depois) — a ordem do catálogo não
  precisa de ser conhecida para semear; a página lista-os na ordem do
  catálogo seja qual for a do ficheiro.

Numa instalação em uso os jobs continuam a correr sem uma visita aos
Settings (nesta: anthropic com `claude-opus-5`, `claude-opus-4-8`,
`claude-sonnet-5`; openai com `gpt-5.6-luna`). Numa instalação nova os jobs
de exemplo estão desligados, logo nada fica activado e a dashboard avisa —
activar é uma decisão do operador, não uma inferência.

### O que sai

`claude_config_dir` do projecto e do bloco `security`: dos dois editores
(`pj-ccd`, `sec-cfgdir`), de `security_derived_jobs` (deixa de copiar
`cfgdir` para o job derivado), de `run_job` (deixa de resolver
`claude_config_dir` pelo job/projecto) e do README. Fica o pin de instalação
`AGENTLOOP_CLAUDE_CONFIG_DIR`, que é a conta que o cartão Anthropic mostra e
com que a sonda corre. Um `projects.json` que ainda traga o campo recebe uma
linha em `agentloop status` e no `install` — "projects.json: claude_config_dir
on <Project> is ignored since this version — the account is the platform's,
see Settings" — não um erro, e o campo não é apagado.

## Engine (`bin/agentloop`)

### Registo

`PLATFORMS="anthropic openai"` continua a ser o conjunto que corre. Entra
`PLATFORMS_PLANNED="opencode"`: plataformas que o registo conhece e lista
(para a página ter o cartão) mas que ainda não correm. `platform_known` fica
como está, por isso nenhum job pode nomear `opencode` antes da entrega 2. Um
job editado à mão que o nomeie é **recusado** no lançamento ("opencode is not
supported yet — it arrives with the OpenCode engine"), em vez de normalizado
para `anthropic` como `job_platform` faz a uma palavra desconhecida — o
operador escreveu uma plataforma real, e a resposta honesta é "ainda não".

### Leitura e escrita do ficheiro

- `platforms_json` lê o ficheiro, chamando `platforms_ensure` quando falta.
  Um ficheiro que não é JSON válido é lido como "nada activado", com a razão.
- `write_platforms <filtro jq>` escreve com a guarda de `write_jobs`: um
  filtro que falha, ou um resultado sem `.platforms` objecto, é descartado; um
  ficheiro inválido nunca é reescrito por cima (a mensagem nomeia-o).

### Funções novas na tabela

Uma linha de `case` por plataforma, como as outras:

| Função | O que responde |
|---|---|
| `platform_enabled <p>` | rc 0 quando `enabled` |
| `platform_models_enabled <p>` | os ids activados, um por linha |
| `platform_model_enabled <p> <model>` | rc 0 quando a lista contém o valor ou o id em que resolve (`effective_model`) |
| `platform_usable <p>` | rc 0 quando activada **e** com pelo menos um modelo activado — é isto que o editor e o aviso lêem |
| `platform_bin <p>` | a precedência acima; `platform_bin_source <p>` diz `env` · `file` · `auto` |
| `platform_check <p>` | JSON `{ready, bin, bin_found, version, account, reason}`, ao vivo |
| `platform_ready <p>` | passa a ser o `ready`/`reason` de `platform_check` — um só sítio decide |
| `platform_default_model <p>` | o **primeiro modelo activado** na ordem do catálogo; vazio quando não há nenhum |

`platform_check`:

- **anthropic:** binário → `--version` → `claude auth status --json`, com
  `CLAUDE_CONFIG_DIR` = `installed_config_dir` quando há pin. `account` =
  "`<email>` · `<subscriptionType>` plan". Sem sessão: `reason` = "not signed
  in — run: claude auth login" (com o `CLAUDE_CONFIG_DIR=… ` à frente quando há
  pin). Um CLI sem o subcomando `auth status`: binário encontrado conta como
  pronto (a regra de hoje) e `account` = "unknown — claude auth status needs
  Claude Code 2.1+".
- **openai:** binário → `--version` → `codex login status`; `account` = a
  linha que o CLI imprime ("Logged in using ChatGPT"); sem sessão: "not signed
  in — run: codex login".
- **opencode (nesta entrega):** binário e `--version`; `ready: false`,
  `reason` = "runs on OpenCode arrive with the OpenCode engine"; sem binário,
  `reason` = "opencode not found — brew install opencode".

### Comandos

Cada um é uma acção da dashboard por baixo (ver [Servidor](#servidor)):

```
agentloop platform check <p>            # o JSON de platform_check
agentloop platform enable <p>           # corre o check; recusa se não estiver pronto, com a razão
agentloop platform disable <p>          # escreve; diz quantos jobs activos ficam a ser saltados
agentloop platform set-bin <p> [path]   # vazio = detecção automática; um caminho tem de ser executável
agentloop platform models <p>           # refresca o catálogo e imprime-o com `enabled` por modelo
agentloop platform set-models <p>       # lista JSON no stdin: um id novo tem de estar no catálogo;
                                        #   um id já activado pode ficar mesmo que o catálogo já não o traga
agentloop platforms                     # o de hoje, também para as plataformas *planned*, mais: supported,
                                        #   enabled, usable, bin, bin_source, bin_found, models_enabled,
                                        #   jobs_on_platform, jobs_using
```

- `platform models anthropic` é a leitura instantânea de hoje (ids no
  binário, famílias em cache, ids em uso); o `resolve-models anthropic`
  completo, que chama a API, fica na passagem diária do tick. `platform
  models openai` corre `resolve-models openai` (`codex debug models`, 0 s).
  Quando o refresh falha, o catálogo anterior fica e a resposta traz
  `stale: true` e a razão.
- `platform disable` e `set-models` (ao retirar um id) imprimem os jobs
  activos e blocos de segurança afectados: "openai disabled — 1 enabled job
  (minerva-promote-agent) runs on it and will be skipped until it is enabled
  again". Nunca recusam: desligar é uma decisão do operador, e a página diz o
  que vai acontecer antes do clique.
- `platforms` continua a ser um só objecto JSON; as chaves de hoje não mudam.
  `jobs_using` é `{id do modelo: n}` e `jobs_on_platform` um inteiro, ambos a
  contar jobs com `enabled != false` e blocos de segurança activos.

### Recusas no lançamento

Em `run_job`, pela ordem que já existe, duas linhas novas a negrito:

plataforma desconhecida → **plataforma *planned*** ("opencode is not supported
yet") → **desligada nos Settings** ("openai is disabled in Settings, skipped")
→ não pronta → modelo fora do catálogo → **modelo não activado** ("model
'gpt-6-astra' is not enabled in Settings — openai enables: gpt-5.6-luna,
skipped") → permissão. Cada uma é uma linha no `tick.log` antes de gastar um
slot, o tratamento que `cwd missing` tem. A análise de segurança é um run e
passa pelas mesmas.

### Validação na escrita

- `set-field platform`: além dos valores conhecidos, recusa uma plataforma que
  não esteja `usable` ("openai is not enabled — enable it in Settings, or:
  agentloop platform enable openai"). O valor vazio (herdar a do projecto)
  passa sempre, como hoje: a plataforma efectiva é julgada no lançamento e
  pelo chip do job. A reescrita dos outros três campos ao mudar de plataforma
  usa o `platform_default_model` novo (primeiro activado).
- `set-field model`: recusa um modelo não activado, nomeando os que estão
  ("model 'gpt-6-astra' is not enabled in Settings — openai enables:
  gpt-5.6-luna").
- `create`: as duas regras; um `create` sem `model` recebe o primeiro
  activado da plataforma.
- `project-set`: o `platform` do projecto e o `platform`/`model` do bloco
  `security` com as mesmas regras; `claude_config_dir` deixa de ser copiado
  para o bloco (um valor enviado é ignorado com a linha de aviso).
- `security_derived_jobs`: `model` validado também contra os activados, com o
  fallback-e-aviso que a permissão já tem.

### `status`, `install` e o tick

- O bloco de plataformas de `status` passa a uma linha por plataforma do
  registo: `anthropic : enabled — 2.1.258 (Claude Code), luiz.moura@… · max
  plan; 3 of 9 models enabled`; `openai : enabled — codex-cli 0.153.4, Logged
  in using ChatGPT; 1 of 6 models enabled; catalog 2 h ago; prices 2 h ago`;
  `opencode : planned — not installed (brew install opencode)`. Depois, o
  aviso de `claude_config_dir` em `projects.json` quando existir.
- `install.sh` corre `agentloop platforms` no fim e, com nenhuma plataforma
  `usable`, termina com "Open the dashboard and enable a platform in
  Settings › Platforms before creating jobs".
- O tick não muda além das recusas; a passagem diária `_resolve_models`
  continua a refrescar os dois catálogos.

## Servidor (`bin/agentloop-server`)

### `/api/models`

Mantém as chaves de hoje (o teste que as fixa continua a passar). Cada
`platforms[p]` ganha `supported`, `enabled`, `usable`, `bin`, `bin_source`,
`bin_found`, `models_enabled` (lista de ids, ao lado do `models` de hoje, que
não muda de forma — o Anthropic serve strings e o OpenAI objectos, e mudar
isso partiria os leitores por nada), `jobs_on_platform`, `jobs_using` e, no
Anthropic, `catalog_at` (o `at` mais recente das famílias resolvidas). O
registo ganha a entrada `opencode` com `supported: false`. No topo,
`configured`: verdadeiro quando alguma plataforma é `usable`; e `error` quando
`platforms.json` é inválido, com a frase do engine.

O servidor lê `config/platforms.json` directamente; se faltar, chama
`agentloop platforms` uma vez (que semeia) e volta a ler — o padrão de
`_openai_platform` para o catálogo. **Nenhuma sonda corre dentro de
`/api/models`**: continua a ser leitura de ficheiros.

### Acções

Em `/api/action`, atrás da sessão como todas, cada uma um comando por baixo
(`al([...])`) com o contrato de `project_set` — `{ok, output}`, a frase do
`die` do engine devolvida tal e qual para a página mostrar no cartão:

| op | comando | resposta |
|---|---|---|
| `platform_check {platform}` | `platform check <p>` | `{ok, check}` — a única que corre um CLI, dentro do timeout de 30 s de `al()` |
| `platform_enable {platform}` | `platform enable <p>` | `{ok, output}` |
| `platform_disable {platform}` | `platform disable <p>` | `{ok, output}` |
| `platform_set_bin {platform, bin}` | `platform set-bin <p> <bin>` | `{ok, output}` |
| `platform_models {platform}` | `platform models <p>` | `{ok, catalog}` — o catálogo refrescado com `enabled` por modelo, `stale` e `reason` |
| `platform_set_models {platform, models}` | `platform set-models <p>` (lista no stdin) | `{ok, output}` |

`platform` tem de ser uma entrada do registo (as três), senão 400. As acções
existentes (`set_field platform|model`, `create`, `project_set`) não mudam no
servidor: o engine recusa e o servidor retransmite, como hoje.

### `config_sig`

Passa a incluir `mtime` e tamanho de `platforms.json`. A página, ao ver o
`sig` de `/api/data` mudar, já recarrega `/api/config`; passa a pedir também
`/api/models` — assim uma alteração feita pela CLI aparece na dashboard no
ciclo seguinte de 5 s, e a página de Settings aberta noutro separador
repinta-se.

## UI

### A página Settings

Sai do esconderijo: `nav-settings` perde o `hidden`, `settings` volta a
`VIEWS`, e a página usa a mobília que existe — `pageHeader` (engrenagem,
"Settings", "Which agent CLIs this scheduler may run, and which of their
models a job may pick") e a barra `.viewtabs`/`.pane` com dois separadores:
**Platforms** (esta entrega) e **Profile** (o aviso "Not built yet" de hoje,
movido para lá). Código novo em `ui/app/settings.js`, exposto como
`ALApp.renderSettingsPage()` e `ALApp.paintPlatformCard()`, empacotado por
`build/build-ui.sh` como os outros módulos; a página só liga os eventos.

### Um cartão por plataforma

Anthropic — Claude Code · OpenAI — Codex CLI · OpenCode, na ordem do registo.
Cada cartão tem quatro zonas de cima para baixo, que são os passos que o
operador descreveu:

1. **Cabeçalho:** nome, chip de estado (*Enabled* · *Disabled* · *Not
   installed* · *Not signed in* · *Coming soon*) e o interruptor `.switch` de
   ligar, trancado até o teste passar (o `title` diz porquê).
2. **Binary:** o caminho detectado ou definido, com a origem ("found on PATH"
   · "set here" · "from AGENTLOOP_CODEX_BIN") e a versão; um campo para
   escrever outro caminho, gravado ao sair do campo, e um botão *Detect* que
   volta à detecção automática. Não encontrado: a instrução de instalação
   ("`npm i -g @openai/codex`, then `codex login`"; "`brew install
   opencode`").
3. **Session:** o resultado de `platform_check` — "Signed in as
   luiz.moura@… · Max plan" ou "Not signed in — run: `codex login`" — o botão
   *Test*, e "checked 12 s ago". Os três cartões são verificados quando a
   página abre.
4. **Models:** *Load models* (depois *Refresh*), a idade do catálogo ("from
   codex debug models, 2 h ago"), e a lista com um `.switch` por modelo:
   nome, id, descrição, níveis de esforço, preço por 1M no OpenAI (ou "no
   price"), marca de descontinuado com o sucessor, e "3 jobs" quando está em
   uso. Antes do teste passar: "Test the session first, then load the
   models". Um id activado que o catálogo já não traz aparece no fim com "no
   longer in the catalog".

Cada alteração grava na hora (interruptores; o caminho ao sair do campo) com
o `toast()` da casa — não há botão *Save*. Uma recusa do engine aparece no
próprio cartão, com a frase dele. Desligar uma plataforma ou um modelo em uso
mostra o que o comando devolve ("1 enabled job runs on it and will be skipped
until it is enabled again"). Por cima dos cartões, uma linha-resumo: "2 of 3
platforms enabled · 4 models available to jobs". O cartão OpenCode mostra
binário e versão e o resto desligado, com "runs on OpenCode arrive with the
next release".

### Editores

- *Platform* (job, projecto, segurança) lista só plataformas `usable`, lido de
  `/api/models` em vez do `PLATFORM_OPTS` fixo da página; *Model* lista só
  `models_enabled`. O rótulo "— Default (opus) —" do bloco de segurança passa
  a nomear o primeiro activado.
- Um job cujo valor actual deixou de estar activado vê-o marcado "(disabled in
  Settings)" no combo; o editor **não reescreve nada sozinho**. O passo
  *Agent* só bloqueia ao criar, ou quando esses campos mudaram; editar o
  prompt de um job cujo modelo foi desligado continua a ser possível, e a
  recusa fica no lançamento.
- O modelo em texto livre do bloco de segurança (`allowCustom`) sai: a lista
  de activados é a autoridade. `pj-ccd` e `sec-cfgdir` saem com o
  `claude_config_dir`.

### O aviso

Com `configured` falso:

- faixa no topo de *Overview* e de *Jobs* — "No platform is enabled yet.
  Enable one in Settings › Platforms and switch on at least one model; until
  then no job can be created" — com o botão *Open Settings*;
- os dois *New job* (`ov-new-job`, `new-job`) abrem os Settings em vez do
  editor;
- um ponto de atenção no item *Settings* da barra lateral, como o pulso do
  contador de *Runs*;
- numa instalação nova, a página aterra em Settings › Platforms logo a seguir
  ao perfil do operador.

Com `error` (ficheiro inválido), a mesma faixa nomeia `config/platforms.json`
e a frase do engine.

Cartão e linha de job ganham um chip "platform disabled" · "model disabled" ·
"platform not supported yet" quando o valor deixou de estar activado
(`jobs-domain.js` calcula-o a partir de `/api/models`), para a recusa no
`tick.log` não ser a única pista.

## OpenCode: o ponto de extensão

Nesta entrega o OpenCode é *planned*: cartão, detecção do binário e versão,
resto desligado. A entrega 2 começa, como a do Codex, por uma fase de medição
com o CLI real, guardada numa pasta de evidência ao lado da sua spec, como
`2026-09-06-codex-measurements/` está ao lado da spec das plataformas:

1. `opencode --version`; `opencode auth list` (formato; é daqui que vem "os
   providers com credenciais"); `opencode models` e `opencode models
   --verbose` (formato `provider/model`; custos por modelo, que podem
   alimentar a estimativa como a tabela de preços faz para o Codex).
2. `opencode run --format json`: os eventos (id de sessão, mensagens,
   ferramentas, tokens, custo), o evento final, o código de saída, o que sai
   em stderr, e se precisa de `</dev/null`.
3. `--dir` como `cwd`; `--session <id>` como resume e se mantém o id;
   `--auto` e o bloco `permission` (allow · ask · deny) como vocabulário de
   permissões, possivelmente via `OPENCODE_CONFIG_CONTENT`;
   `OPENCODE_CONFIG_DIR` para a conta; `opencode export <session>` como o
   análogo do rollout.

Depois disso o OpenCode é um ramo a mais em cada função da tabela, um
`bin/platforms/opencode_stream.py`, `test/fake-opencode`, e a passagem de
`PLATFORMS_PLANNED` para `PLATFORMS`. Nada desta entrega precisa de mudar de
forma para isso: `platform_check`, `platform models` e os cartões já têm o
ramo `opencode`, só que a responder "ainda não".

## Erros

| Situação | O que acontece |
|---|---|
| ligar sem binário, ou sem sessão | recusado com a razão e a instrução ("codex not found at … — set the path, or: npm i -g @openai/codex"; "codex is not signed in (run: codex login)") |
| desligar uma plataforma, ou um modelo, em uso | permitido; o comando diz quantos jobs activos e blocos de segurança ficam a ser saltados; chip no cartão e na linha do job; run recusado no lançamento com a razão no `tick.log` |
| `set-models` com um id novo fora do catálogo | recusado, nomeando o id; a página nunca oferece esse interruptor (um id já activado que o catálogo deixou de trazer pode ficar, e sai por omissão na lista seguinte) |
| `set-bin` com um caminho que não é executável | recusado: "not executable: <path>" |
| refresh do catálogo falha | o catálogo anterior fica; `platform models` devolve-o com `stale: true` e a razão; o cartão diz "catalog from 2 d ago — refresh failed: …" |
| `platforms.json` inválido | nada fica ligado; uma linha no `tick.log` por tick e em `status`; faixa na dashboard a nomear o ficheiro; o engine nunca o reescreve |
| `claude auth status` não existe (CLI antigo) | binário encontrado conta como pronto; `account` = "unknown — claude auth status needs Claude Code 2.1+" |
| pin de instalação sem sessão | o cartão Anthropic diz "Not signed in in ~/.claude-work — run: CLAUDE_CONFIG_DIR=~/.claude-work claude auth login" |
| job editado à mão em `opencode` | recusado no lançamento ("opencode is not supported yet"); chip "platform not supported yet" |
| `projects.json` com `claude_config_dir` | ignorado; aviso em `status` e `install`; o campo fica no ficheiro |
| `platform_check` demora mais do que o `al()` permite (30 s) | `{ok:false}` com "check timed out"; o cartão mostra-o e o *Test* fica disponível |
| Run now num job cuja plataforma está desligada | o `run` do engine recusa com a frase do lançamento; a página mostra-a no `toast`, como qualquer recusa de `run` |

## Testes

- **Selftest** (`bin/agentloop selftest`): a semente (instalação nova → nada
  activado; jobs em uso → ligado com esses modelos, famílias resolvidas pela
  cache); precedência de `platform_bin` (env → file → auto) e
  `platform_bin_source`; `platform_check` sobre `test/fake-claude` — que ganha
  o subcomando `auth status --json` guiado por `FAKE_CLAUDE_LOGGED_OUT`, ao
  lado do `FAKE_CODEX_LOGGED_OUT` que o `fake-codex` já tem — e sobre
  `test/fake-codex`; `enable` recusa sem sessão e sem binário; `disable` conta
  os jobs; `set-models` valida contra o catálogo; `set-bin` valida; as
  recusas no lançamento (planned, desligada, modelo não activado);
  `platform_default_model` = primeiro activado, vazio sem nenhum;
  `platform_usable`; recusas em `set-field`, `create`, `project-set` e o
  fallback em `security_derived_jobs`; o bloco de `status`; o aviso de
  `claude_config_dir`; ficheiro inválido lido como nada activado e nunca
  reescrito; `platforms` com as chaves novas.
- **pytest do servidor** (`tests/test_platforms_api.py`,
  `tests/test_page_contract.py`): forma nova de `/api/models`, `usable`,
  `configured` e `error`; o servidor semeia via `agentloop platforms` quando
  o ficheiro falta; cada acção chama o argv certo (o `al` observado) e
  retransmite o `die`; `platform` fora do registo → 400; `config_sig` mexe
  com `platforms.json`; contrato da página: item *Settings* visível,
  `settings` em `VIEWS`, `PLATFORM_OPTS` desaparecido e os combos a lerem
  `/api/models`, combos só com activados, a marca "(disabled in Settings)",
  faixa e desvio do *New job*, o ponto na barra lateral, chips na linha e no
  cartão, `pj-ccd`/`sec-cfgdir` ausentes, `allowCustom` fora do `sec-model`,
  os exports de `settings.js`.
- **e2e** (`test/e2e.test.sh`): um job numa plataforma desligada é saltado
  com a linha; `platform enable` → corre; `set-models` sem o seu modelo →
  saltado com a linha; caminho de upgrade: `jobs.json` existente sem
  `platforms.json` → semente → os runs não mudam.
- **Aceitação com os CLIs reais**, em config/data de rascunho: abrir os
  Settings, ver as duas plataformas verificadas ao vivo com a conta certa,
  carregar os modelos, desligar e ligar um, criar um job e vê-lo oferecer só
  o que está activado — lido, não só verde.

## Documentação

README: secção *Settings* nova (o que cada zona do cartão faz; o ficheiro; os
comandos `platform …`); *Platforms* actualizada (o que um run precisa passa a
incluir "enabled in Settings"); *Which Claude account a run signs in as*
reduzida ao pin de instalação; *CLI* com os comandos novos; *Layout* com o
ficheiro novo. `install.sh` com a frase final. CHANGELOG na mesma alteração
que o código, entrada por comportamento — "a job can no longer be created on
a platform nobody enabled; what it cost: a job on `gpt-6-astra` at $10/50
per 1M was one click away in a picker that showed the whole catalog".

## Ecrãs

Os cinco artboards aprovados vivem em
[`../mockups/2026-09-11-platform-settings/`](../mockups/2026-09-11-platform-settings/)
(`Main.dc.html`, `OverviewBanner.dc.html`, `CardStates.dc.html`,
`JobEditorAgent.dc.html`, `JobEditorFlag.dc.html`, e o `canvas.json` que os
dispõe) e no canvas
<https://claude.ai/code/artifact/b259a209-09bb-447d-9010-3e5a736aac48>. Foram
desenhados com os valores da própria aplicação (`ui/css/tokens.css`,
`components.css`, `pages.css`, a barra lateral e os ícones de
`bin/dashboard.html`), por isso o plano pode citar deles medidas e classes:

1. **Settings › Platforms** (`Main`): a página como esta instalação a abre
   depois do upgrade — Anthropic e OpenAI ligadas pela semente, Anthropic com
   quatro modelos em cinco, OpenAI só com Luna, OpenCode como *planned*.
2. **Overview sem nada configurado** (`OverviewBanner`): a faixa, o *New
   job* a apontar para os Settings e o ponto de atenção na barra lateral.
3. **Estados de falha do cartão** (`CardStates`): binário encontrado sem
   sessão, com o interruptor trancado; e binário ausente, com o campo do
   caminho.
4. **Editor de jobs, passo *The agent*** (`JobEditorAgent`): Platform só com
   as ligadas, Model só com os activados e a contagem dos que o catálogo
   ainda esconde.
5. **Editor de jobs com um modelo desligado** (`JobEditorFlag`): o valor
   marcado "(disabled in Settings)" e a caixa que diz o que acontece.

## Fora desta versão

- Runs em OpenCode (entrega 2) e a listagem real dos seus modelos.
- Mais do que uma conta por plataforma; o pin de instalação
  `AGENTLOOP_CLAUDE_CONFIG_DIR` continua a ser o único mecanismo, e não
  ganha campo na página.
- Esforço ou modo de permissão por omissão configuráveis em Settings; um
  modelo por omissão escolhido pelo operador (é o primeiro activado).
- Activar automaticamente uma plataforma pronta numa instalação nova.
- O separador *Profile* (continua "Not built yet").
- Tectos de custo por modelo.

## Ordem de implementação, para o plano

1. Engine, leitura: `platforms.json`, `platforms_ensure` e a semente,
   `write_platforms`, as funções da tabela, `platform_check` (com
   `fake-claude auth status`), `platform_ready` sobre ele; selftest.
2. Engine, escrita e recusas: os comandos `platform …`, `platforms` alargado,
   validação em `set-field`/`create`/`project-set`/`security_derived_jobs`,
   recusas no lançamento, `status` e `install.sh`; selftest e e2e.
3. Saída do `claude_config_dir` por projecto e bloco de segurança: engine,
   editores, README, o aviso; selftest.
4. Servidor: `/api/models`, as seis acções, `config_sig`; pytest.
5. UI: `ui/app/settings.js`, a página e o CSS, os editores, a faixa e o
   desvio do *New job*, o ponto na barra lateral, os chips; contrato da
   página; `build/build-ui.sh` e os bundles recommitados.
6. README, CHANGELOG; aceitação com os CLIs reais.
