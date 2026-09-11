# Settings › Platforms — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Uma plataforma passa a ter três estados que o operador controla — encontrada, verificada, activada — e um conjunto de modelos activados, em `config/platforms.json`; os editores oferecem só o que está activado, o engine recusa no lançamento o que deixou de estar, a dashboard avisa enquanto nada estiver configurado, e o `claude_config_dir` por projecto sai.

**Architecture:** O engine (`bin/agentloop`, bash 3.2 + jq) é dono do ficheiro: semeia-o do que está em uso, lê-o em todas as portas (lançamento, `set-field`, `create`, `project-set`, derivação de segurança) e expõe comandos `agentloop platform …` que a dashboard chama por baixo. O servidor (`bin/agentloop-server`, python stdlib) espelha o ficheiro em `/api/models` sem correr nenhuma sonda e retransmite os comandos como acções. A página (`bin/dashboard.html` + módulos ES em `ui/app/`, empacotados para `bin/static/`) ganha a página Settings › Platforms, filtra os editores pelo activado e mostra o aviso.

**Tech Stack:** bash 3.2 (sem arrays associativos), jq, python3 stdlib, esbuild só no build (`build/build-ui.sh`), pytest em `python3.13`, selftest e e2e em bash.

**Spec:** [`docs/superpowers/specs/2026-09-11-platform-settings-design.md`](../specs/2026-09-11-platform-settings-design.md). Ecrãs aprovados: [`docs/superpowers/mockups/2026-09-11-platform-settings/`](../mockups/2026-09-11-platform-settings/).

## Global Constraints

- **Idioma dos artefactos:** código, comentários, docstrings, mensagens de commit, README e CHANGELOG em inglês. Só este plano e a spec estão em português.
- **Ficheiro:** `config/platforms.json`, forma `{"platforms": {"anthropic": {"enabled": bool, "bin": "", "models": ["id", …]}, "openai": {…}, "opencode": {…}}}`. Entra no `.gitignore` (é pessoal, como `jobs.json`).
- **Registo:** `PLATFORMS="anthropic openai"` (correm) e `PLATFORMS_PLANNED="opencode"` (listado, nunca corre nesta entrega). `platform_known` continua a aceitar só os dois primeiros.
- **Precedência do binário:** variável de ambiente (`AGENTLOOP_CLAUDE_BIN`, `AGENTLOOP_CODEX_BIN`, `AGENTLOOP_OPENCODE_BIN`) → `bin` do ficheiro → detecção (`~/.local/bin/claude` se executável, senão `command -v claude`; `command -v codex` senão `/opt/homebrew/bin/codex`; `command -v opencode`, senão `~/.opencode/bin/opencode` se executável, senão `/opt/homebrew/bin/opencode`). O servidor replica a regra em python e um teste pinta as duas.
- **Sondas ao vivo, nunca guardadas:** `claude auth status --json` (com `CLAUDE_CONFIG_DIR` = pin da instalação quando existe), `codex login status`, `<cli> --version`. Nunca dentro de `/api/models`.
- **Frases exactas** (os testes fixam-nas):
  - `<cli> not found at <bin> — set the path in Settings (or AGENTLOOP_<CLI>_BIN); install: <hint>` com hints `npm i -g @anthropic-ai/claude-code` · `npm i -g @openai/codex, then codex login` · `brew install opencode`;
  - `claude is not signed in (run: claude auth login)` — com pin: `claude is not signed in in <dir> (run: CLAUDE_CONFIG_DIR=<dir> claude auth login)`;
  - `codex is not signed in (run: codex login)` (inalterada);
  - `runs on OpenCode arrive with the OpenCode engine`;
  - lançamento, por esta ordem (decidida na revisão da Task 4): planned (`<id>: opencode is not supported yet — it arrives with the OpenCode engine, skipped`) → desconhecida → desligada (`<id>: <p> is disabled in Settings (agentloop platform enable <p>), skipped`) → **nenhum modelo activado** (`<id>: no model is enabled for <p> in Settings, skipped`, antes de qualquer sonda ao CLI) → não pronta → (openai: interactive, catálogo, permissão) → modelo não activado (`<id>: model '<m>' is not enabled in Settings — <p> enables: <lista>, skipped`);
  - `<p> is not enabled in Settings — enable it there, or: agentloop platform enable <p>` (escrita);
  - `<file> is not a valid platforms file (not JSON, or no .platforms object) — no platform is enabled until it is fixed`.
- **`platform_default_model <p>`** passa a ser o primeiro id da lista `models` do ficheiro (vazio sem nenhum). O `opus` fixo de hoje desaparece.
- **Testes:** `bash bin/agentloop selftest` (no worktree, copiar antes `config/jobs.example.json` para `config/jobs.json` — git-ignored — ou um teste falha por falta do ficheiro); `python3.13 -m pytest tests/<file> -p no:cacheprovider -q`; `bash test/e2e.test.sh`. O selftest embute o e2e e ambos usam `test/sandbox`: **nunca correr os dois em paralelo**. Testes sempre em primeiro plano, `timeout` 600000.
- **Isolamento:** todo o teste que lança runs aponta `PLATFORMS_FILE`, `AGENTLOOP_CLAUDE_BIN=test/fake-claude`, `AGENTLOOP_CODEX_BIN=test/fake-codex`, `CODEX_HOME`, `AGENTLOOP_CONFIG`/`AGENTLOOP_DATA` para pastas de rascunho; nunca o `config/`, `data/` ou `~/.codex` reais.
- **UI:** qualquer edição em `ui/` obriga a `bash build/build-ui.sh` no mesmo commit (o selftest recusa a árvore sem isso). Ícones só do conjunto `I` da página; nada de emoji.
- **CHANGELOG:** o selftest exige que `CHANGELOG.md` seja pelo menos tão recente como o último commit de código, por isso **cada commit de código toca o CHANGELOG**: até à Task 10, cada tarefa acrescenta um ponto ao entry interino que a Task 1 abriu em `## [Unreleased]` → `### Added` ("**`config/platforms.json`'s seed and readers…**"), dizendo o que essa tarefa entregou; a Task 10 substitui o entry interino pelo entry final da funcionalidade. Formato: "o que mudou e o que custava não ter".
- **Commits:** frequentes, uma tarefa por commit no mínimo; terminar a mensagem com `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## Mapa de ficheiros

| Ficheiro | Responsabilidade nesta entrega |
|---|---|
| `bin/agentloop` | globais (`PLATFORMS_FILE`, `PLATFORMS_PLANNED`, `OPENCODE_BIN`); bloco `config/platforms.json` (semente, leitura, escrita guardada); `platform_bin` com override; `platform_check`; `cmd_platform`; `cmd_platforms` alargado; recusas em `run_job`; validação em `set-field`/`create`/`project-set`/`security_derived_jobs`; `status`; `cmd_tick`; saída do `claude_config_dir`; selftest |
| `test/fake-claude` | ganha `--version` e `auth status --json` (guiado por `FAKE_CLAUDE_LOGGED_OUT`) |
| `test/e2e.test.sh` | fixture `platforms.json` + três cenários (26–28) |
| `install.sh` | a frase final quando nada está `usable` |
| `bin/agentloop-server` | `PLATFORMS_FILE`, `platforms_config`, `platform_bin`, `platform_entry`, `jobs_using`, `list_models` alargado, `platform_action`, `config_sig` |
| `tests/test_platforms_api.py` | forma nova de `/api/models`, semente via engine, precedência do binário pintada ao engine, `jobs_using` pintado, as seis acções, `config_sig` |
| `ui/app/editor-domain.js` | `PLATFORM_LABELS`, `platformOptions`, `modelOptionsFor` filtrado com valor marcado, `platformOf` alargado |
| `ui/app/jobs-domain.js` | `platformState`, `platformChip` |
| `ui/app/settings.js` (novo) | `renderSettingsPage`, `settingsSummary`, `platformStatus`, `setupBanner` |
| `ui/app/overview.js`, `ui/app/jobs-table.js` | o chip no cartão e na linha |
| `ui/app/index.js` | exports novos em `window.ALApp` |
| `ui/css/pages.css` | `.platcard*`, `.setup-banner*`, `.navitem .attn`, `.summary`, `.mrow*` |
| `bin/dashboard.html` | página Settings (markup, `VIEWS`, tabs, pintura), editores sem `PLATFORM_OPTS`, `validateStep`, faixa, desvio do New job, ponto na barra, aterragem, `MODELS_CONFIGURED`, saída de `pj-ccd`/`sec-cfgdir` |
| `tests/test_page_contract.py` | contrato da página e dos módulos |
| `README.md`, `CHANGELOG.md` | documentação |

---

### Task 1: O ficheiro `config/platforms.json` — semente, leitura e guarda de escrita

**Files:**
- Modify: `bin/agentloop` (globais junto a `PRICING_FILE=`; o bloco `# --- platforms ---` logo a seguir a `job_platform()`; `cmd_selftest`)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `JOBS_FILE`, `PROJECTS_FILE`, `MODELS_FILE`, `JQ`, `die`, `num`.
- Produces (todas em `bin/agentloop`): `PLATFORMS_FILE`; `PLATFORMS_PLANNED`; `platform_planned <p>`; `platform_listed <p>`; `PLATFORMS_JQ` (defs jq partilhadas); `platforms_jq <filter> [jq-opts…]`; `platforms_seed`; `platforms_ensure`; `platforms_error`; `platforms_json`; `write_platforms <filter> [jq-args…]`; `platforms_field <p> <key>`; `platform_enabled <p>` (rc); `platform_models_enabled <p>` (um id por linha); `family_cached_id <family>`; `platform_model_enabled <p> <model>` (rc); `platform_usable <p>` (rc); `platform_jobs_on <p> [model]` (um `who` por linha: id do job, ou `security:<projecto>`).
- Nesta tarefa **nada muda de comportamento**: só se acrescentam leitores. `platform_default_model` muda na Task 4.

- [ ] **Step 1: Escrever as asserções do selftest (falham: funções inexistentes)**

Em `bin/agentloop`, dentro de `cmd_selftest`, imediatamente antes da linha `  # The catalog readers, over a models.json of this test's own.`, inserir:

```bash
  echo "config/platforms.json — seeded from what is in use, read by every gate"
  local pf="$tmp/pf"; mkdir -p "$pf"
  pf_env() { PLATFORMS_FILE="$pf/platforms.json"; JOBS_FILE="$pf/jobs.json"; PROJECTS_FILE="$pf/projects.json"; MODELS_FILE="$pf/models.json"; }
  cat > "$pf/jobs.json" <<'JSON'
{"jobs":[{"id":"a1","model":"claude-opus-5","prompt":"x"},
         {"id":"a2","model":"opus","prompt":"x"},
         {"id":"off","enabled":false,"model":"claude-sonnet-5","prompt":"x"},
         {"id":"o1","platform":"openai","model":"gpt-5.6-luna","prompt":"x"},
         {"id":"p1","project":"P","prompt":"x"}]}
JSON
  cat > "$pf/projects.json" <<'JSON'
{"projects":[{"name":"P","platform":"openai","model":"gpt-5.6-sol",
              "security":{"enabled":true,"platform":"anthropic","model":"claude-fable-5-1"}}]}
JSON
  printf '{"resolved":{"opus":{"id":"claude-opus-5","at":1}}}\n' > "$pf/models.json"
  type platforms_ensure >/dev/null 2>&1 && ok "the platforms file reader is defined" || bad "platforms_ensure does not exist"
  ( pf_env; platforms_ensure )
  [ -f "$pf/platforms.json" ] && ok "a missing platforms file is written on first use" || bad "platforms_ensure wrote nothing"
  ( pf_env; platform_enabled anthropic ); want "anthropic is enabled: enabled jobs run on it" 0 $?
  ( pf_env; platform_enabled openai );    want "openai is enabled: an enabled job and a project's jobs run on it" 0 $?
  ( pf_env; platform_enabled opencode );  want "opencode is never enabled by the seed" 1 $?
  got="$( pf_env; platform_models_enabled anthropic | tr '\n' ' ' )"
  [ "$got" = "claude-opus-5 claude-fable-5-1 " ] \
    && ok "anthropic's models: the ids in use, a family resolved through the cache, the disabled job's model left out, no repeats" \
    || bad "anthropic models: '$got'"
  got="$( pf_env; platform_models_enabled openai | tr '\n' ' ' )"
  [ "$got" = "gpt-5.6-luna gpt-5.6-sol " ] && ok "openai's models: the job's own and the one inherited from the project" || bad "openai models: '$got'"
  ( pf_env; platform_model_enabled anthropic opus );            want "a family counts as enabled when its cached id is" 0 $?
  ( pf_env; platform_model_enabled anthropic claude-sonnet-5 ); want "a model no enabled job uses is not enabled" 1 $?
  ( pf_env; platform_usable anthropic ); want "usable: enabled with a model" 0 $?
  [ "$( pf_env; platform_jobs_on openai | tr '\n' ' ' )" = "o1 p1 " ] \
    && ok "platform_jobs_on lists the enabled jobs of a platform" || bad "jobs on openai: $( pf_env; platform_jobs_on openai | tr '\n' ' ' )"
  [ "$( pf_env; platform_jobs_on anthropic claude-fable-5-1 )" = "security:P" ] \
    && ok "and an enabled security block, by its project" || bad "block: $( pf_env; platform_jobs_on anthropic claude-fable-5-1 )"
  # a fresh install: only the two disabled example jobs -> nothing enabled, and the file still lists the three platforms
  local pf2="$tmp/pf2"; mkdir -p "$pf2"; cp "$BASE_DIR/config/jobs.example.json" "$pf2/jobs.json"
  ( PLATFORMS_FILE="$pf2/platforms.json"; JOBS_FILE="$pf2/jobs.json"; PROJECTS_FILE="$pf2/projects.json"; MODELS_FILE="$pf2/models.json"
    platforms_ensure; platform_usable anthropic ); want "a fresh install enables nothing" 1 $?
  "$JQ" -e '.platforms | keys == ["anthropic","openai","opencode"]' "$pf2/platforms.json" >/dev/null 2>&1 \
    && ok "and still lists the three platforms" || bad "seed keys: $("$JQ" -c '.platforms | keys' "$pf2/platforms.json" 2>/dev/null)"
  # an invalid file: nothing enabled, a reason, and never rewritten
  printf '{oops' > "$pf2/platforms.json"
  ( PLATFORMS_FILE="$pf2/platforms.json"; platform_enabled anthropic ); want "an invalid file enables nothing" 1 $?
  [ -n "$( PLATFORMS_FILE="$pf2/platforms.json"; platforms_error )" ] && ok "and platforms_error names it" || bad "no error for an invalid file"
  ( PLATFORMS_FILE="$pf2/platforms.json"; write_platforms '.platforms.anthropic.enabled = true' ) >/dev/null 2>&1; want "write_platforms refuses to write over an invalid file" 1 $?
  [ "$(cat "$pf2/platforms.json")" = "{oops" ] && ok "and left it exactly as it was" || bad "the invalid file was rewritten"
  ( pf_env; write_platforms '.platforms = "nope"' ) >/dev/null 2>&1; want "a filter that drops .platforms is discarded" 1 $?
  ( pf_env; write_platforms '.platforms.openai.enabled = false' ) >/dev/null 2>&1; want "a good filter writes" 0 $?
  ( pf_env; platform_enabled openai ); want "and the write is read back" 1 $?
```

- [ ] **Step 2: Correr o selftest e ver o bloco falhar**

```bash
cp -n config/jobs.example.json config/jobs.json 2>/dev/null; bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed" | head -30
```
Esperado: `FAIL  platforms_ensure does not exist` e as linhas seguintes do bloco a falhar; o resto verde.

- [ ] **Step 3: Escrever a implementação**

(a) Junto a `PRICING_FILE=` (linha ~85):

```bash
PLATFORMS_FILE="$CONFIG_DIR/platforms.json"   # what the operator enabled: platforms, their binary, their models (seeded by the engine)
```

(b) Substituir a linha `PLATFORMS="anthropic openai"` e a função `platform_known` por:

```bash
PLATFORMS="anthropic openai"          # the platforms that run
PLATFORMS_PLANNED="opencode"          # listed and checked for a binary, never run: the engine for it is a later release

platform_known() { case "${1:-}" in anthropic|openai) return 0 ;; *) return 1 ;; esac; }
platform_planned() { case "${1:-}" in opencode) return 0 ;; *) return 1 ;; esac; }
platform_listed() { platform_known "${1:-}" || platform_planned "${1:-}"; }
```

(c) Logo a seguir a `job_platform()` (antes de `platform_bin()`), o bloco novo:

```bash
# --- config/platforms.json: what the operator enabled ---------------------------
# One object per listed platform: `enabled`, `bin` ("" = detect) and `models`,
# the exact ids a job may pick, in the order they were switched on. The
# catalog in config/models.json is a CACHE the daily refresh rewrites; this
# file is the operator's intent, and a refresh never touches it. Missing, it
# is seeded from what is already in use, so an install that upgrades keeps
# every enabled job running; on a fresh install nothing is enabled until
# someone decides so in Settings. Read the two config files RAW here, never
# through jobs_json: that one derives the security jobs, which ask this file
# for their default model -- a loop.
PLATFORMS_JQ='
  def known: if . == "openai" then "openai" else "anthropic" end;
  def project($name): ([ ($projects.projects // [])[] | select(.name == $name) ] | first // {});
  def sec($p): (($p.security | objects) // {});
  def job_platform($j): (if (($j.platform // "") != "") then $j.platform
                         elif ((project($j.project // "") | .platform // "") != "") then (project($j.project // "") | .platform)
                         else "anthropic" end) | known;
  def job_model($j): (if (($j.model // "") != "") then $j.model else (project($j.project // "") | .model // "") end);
  def sec_platform($p): (if ((sec($p).platform // "") != "") then sec($p).platform
                         elif (($p.platform // "") != "") then $p.platform else "anthropic" end) | known;
  def sec_on($p): ((sec($p).enabled == true) or (sec($p).enabled == "true"));
  def resolved($m): (if ($m != "") and ((($resolved[$m] // {}) | .id // "") != "") then $resolved[$m].id else $m end);
  def uses: ([ ($jobs.jobs // [])[] | select(.enabled != false) | {who: .id, p: job_platform(.), m: resolved(job_model(.))} ]
           + [ ($projects.projects // [])[] | select(sec_on(.)) | {who: ("security:" + .name), p: sec_platform(.), m: resolved((sec(.).model // ""))} ]);
'

platforms_jq() { # platforms_jq <jq-filter> [jq options…] -- runs the filter with $jobs, $projects, $resolved bound and PLATFORMS_JQ's defs in scope
  local filter="$1"; shift
  local jobs='{"jobs":[]}' projects='{"projects":[]}' resolved='{}'
  if [ -f "$JOBS_FILE" ] && "$JQ" -e . "$JOBS_FILE" >/dev/null 2>&1; then jobs="$(cat "$JOBS_FILE")"; fi
  if [ -f "$PROJECTS_FILE" ] && "$JQ" -e . "$PROJECTS_FILE" >/dev/null 2>&1; then projects="$(cat "$PROJECTS_FILE")"; fi
  if [ -f "$MODELS_FILE" ]; then resolved="$("$JQ" -c '.resolved // {}' "$MODELS_FILE" 2>/dev/null || echo '{}')"; fi
  "$JQ" -n "$@" --argjson jobs "$jobs" --argjson projects "$projects" --argjson resolved "$resolved" "${PLATFORMS_JQ}${filter}"
}

platforms_seed() { # the file's first contents: a platform is enabled when an enabled job or an enabled security block runs on it, with the models they use
  platforms_jq '
    def entry($p): {enabled: ([uses[] | select(.p == $p)] | length > 0), bin: "",
                    models: ([uses[] | select(.p == $p) | .m | select(. != "")] | reduce .[] as $m ([]; if index($m) then . else . + [$m] end))};
    {platforms: {anthropic: entry("anthropic"), openai: entry("openai"), opencode: {enabled: false, bin: "", models: []}}}' -c
}

platforms_ensure() { # write the seed when the file does not exist; an existing file, valid or not, is left alone
  [ -f "$PLATFORMS_FILE" ] && return 0
  local seed; seed="$(platforms_seed)" || return 1
  mkdir -p "$(dirname "$PLATFORMS_FILE")"
  printf '%s\n' "$seed" > "$PLATFORMS_FILE"
}

platforms_error() { # one sentence when the file exists and is not JSON, else nothing
  [ -f "$PLATFORMS_FILE" ] || return 0
  "$JQ" -e . "$PLATFORMS_FILE" >/dev/null 2>&1 || printf '%s is not valid JSON — no platform is enabled until it is fixed' "$PLATFORMS_FILE"
}

platforms_json() { # the file, seeded when missing; an unreadable one reads as nothing enabled (platforms_error says why)
  platforms_ensure
  if "$JQ" -e '.platforms | type == "object"' "$PLATFORMS_FILE" >/dev/null 2>&1; then cat "$PLATFORMS_FILE"; else echo '{"platforms":{}}'; fi
}

write_platforms() { # write_platforms <jq-filter> [jq-args...] -- write_jobs's guard: never replace the file with a broken document
  local tmp
  platforms_ensure
  "$JQ" -e . "$PLATFORMS_FILE" >/dev/null 2>&1 || die "refusing to write $PLATFORMS_FILE: it is not valid JSON — fix it by hand first"
  tmp="$(mktemp "$(dirname "$PLATFORMS_FILE")/.platforms.XXXXXX")"
  if "$JQ" "$@" "$PLATFORMS_FILE" > "$tmp" 2>/dev/null \
     && "$JQ" -e 'type == "object" and (.platforms | type) == "object"' "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$PLATFORMS_FILE"
  else
    rm -f "$tmp"; die "refusing to write a malformed platforms file (change discarded)"
  fi
}

platforms_field() { # platforms_field <platform> <key> -> the value as text ("" when absent; a list joined by commas)
  platforms_json | "$JQ" -r --arg p "$1" --arg k "$2" \
    '.platforms[$p][$k] // "" | if type == "array" then join(",") else tostring end'
}
platform_enabled() { [ "$(platforms_field "$1" enabled)" = "true" ]; }
platform_models_enabled() { # the enabled ids, one per line, in the file's own order
  platforms_json | "$JQ" -r --arg p "$1" '.platforms[$p].models // [] | .[] | select(type == "string" and . != "")'
}
family_cached_id() { # family_cached_id <family> -> the id the cache holds for it, TTL ignored; nothing for an id or an unknown family. Never a probe.
  case "${1:-}" in opus|sonnet|haiku|fable) ;; *) return 0 ;; esac
  [ -f "$MODELS_FILE" ] || return 0
  "$JQ" -r --arg f "$1" '.resolved[$f].id // empty' "$MODELS_FILE" 2>/dev/null
}
platform_model_enabled() { # platform_model_enabled <platform> <model> -> 0 when the list carries the value itself, or the id a family resolves to
  local list id
  list="$(platform_models_enabled "$1")"
  [ -n "$list" ] || return 1
  printf '%s\n' "$list" | grep -qxF -- "$2" && return 0
  id="$(family_cached_id "$2")"
  [ -n "$id" ] && printf '%s\n' "$list" | grep -qxF -- "$id"
}
platform_usable() { # enabled AND at least one model enabled: what the editors and the dashboard's warning read
  platform_enabled "$1" && [ -n "$(platform_models_enabled "$1" | head -1)" ]
}
platform_jobs_on() { # platform_jobs_on <platform> [model] -> one line per enabled job (its id) or enabled security block ("security:<project>") running there
  platforms_jq 'uses[] | select(.p == $p) | select($m == "" or .m == $m) | .who' -r --arg p "$1" --arg m "${2:-}"
}
```

(d) No topo de `cmd_selftest`, logo a seguir a `local WORKTREES_DIR="$DATA_DIR/worktrees" RUNS_FILE="$DATA_DIR/runs.ndjson"`, a sombra e a guarda de fuga:

```bash
  # The platforms file is read by every gate below through PLATFORMS_FILE,
  # which was computed from the REAL config dir at load time. Shadowed here
  # so a scenario that redirects JOBS_FILE alone can never seed or read the
  # operator's own config/platforms.json; the guard at the end proves it.
  local _real_pf="$PLATFORMS_FILE" _pf0
  _pf0="$(stat -f %m "$PLATFORMS_FILE" 2>/dev/null || echo none)"
  local PLATFORMS_FILE="$tmp/platforms.json"
  # Permissive on purpose: the scenarios below launch runs on every model
  # their fixtures name, and Settings is not what any of them is testing. A
  # block that IS testing Settings writes a file of its own (pf_env, pc_al,
  # dplat, sec_env below).
  "$JQ" -n '{platforms:{
    anthropic:{enabled:true, bin:"", models:["opus","sonnet","haiku","fable","claude-opus-5","claude-sonnet-5","claude-opus-4-8","claude-fable-5-1","claude-haiku-4-5-20251001"]},
    openai:{enabled:true, bin:"", models:["gpt-5.6-sol","gpt-5.6-terra","gpt-5.6-luna","gpt-5.5","gpt-a","gpt-b"]},
    opencode:{enabled:false, bin:"", models:[]}}}' > "$PLATFORMS_FILE"
```

E junto ao teste que prova que o `tick.log` real não cresceu (procurar `the suite appended to the real exec.log`), acrescentar:

```bash
  [ "$(stat -f %m "$_real_pf" 2>/dev/null || echo none)" = "$_pf0" ] \
    && ok "the suite never touched the real config/platforms.json" \
    || bad "the suite created or rewrote $_real_pf"
```

(e) `.gitignore`: na secção `# Secrets and personal configuration`, depois de `config/pricing.json`, a linha `config/platforms.json`.

- [ ] **Step 4: Correr o selftest e ver o bloco passar**

```bash
bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed"
```
Esperado: `0 failed` (a contagem de `passed` sobe em 24) e nenhuma linha `FAIL`.

- [ ] **Step 5: Commit**

```bash
/usr/bin/git add bin/agentloop .gitignore
/usr/bin/git commit -m "feat(engine): config/platforms.json, seeded from what is in use, with its readers

The file that will decide what a job may pick and what a run may use.
Missing, it is seeded from the enabled jobs and security blocks so an
upgrade keeps everything running; nothing reads it for a decision yet.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

> **Task 1 entregue** (09e42dc, 338287c, 8c39421). A revisão mudou três coisas que as tarefas seguintes herdam: `platforms_jq` tem agora dois argumentos posicionais à cabeça — `platforms_jq <default-anthropic> <default-openai> <filtro> [opções jq]` — e o `uses` regista o modelo **efectivo** de cada job (`resolved(effective(p; m))`: o próprio quando é válido na plataforma, senão o default recebido); `platforms_seed` passa os defaults legados (`opus`, primeiro slug visível) e `platform_jobs_on` passa `platform_default_model`; o predicado `platforms_valid` é partilhado por `platforms_error`, `platforms_json` e `write_platforms`, e a frase de erro é a das *Global Constraints*. Sem catálogo OpenAI a semente mantém o slug configurado. O selftest ficou em 647 asserções.

### Task 2: O binário com override e a verificação ao vivo (`platform_bin`, `platform_check`, `platform_ready`)

**Files:**
- Modify: `bin/agentloop` (globais `CLAUDE_BIN`/`CODEX_BIN`/`OPENCODE_BIN`; `platform_bin`; `platform_ready`; `resolve_models_openai`; `openai_catalog_ensure`; `model_alias_baseline`; `cmd_selftest`)
- Modify: `test/fake-claude`

**Interfaces:**
- Consumes: `platforms_field`, `platform_listed`, `platform_planned`, `installed_config_dir`, `expand_home`, `JQ`.
- Produces: `OPENCODE_BIN`; `platform_cli_name <p>` → `claude|codex|opencode`; `platform_install_hint <p>`; `platform_bin_env <p>` → o override de ambiente ou ""; `platform_bin_source <p>` → `env|file|auto`; `platform_bin <p>` (precedência nova); `platform_check <p>` → JSON `{platform, supported, ready, bin, bin_found, bin_source, version, account, reason}`, sempre rc 0; `platform_ready <p>` (mesma assinatura de hoje, agora sobre `platform_check`). `test/fake-claude` responde a `--version` e a `auth status --json` (`FAKE_CLAUDE_LOGGED_OUT=1` → rc 1).

- [ ] **Step 1: Escrever as asserções (falham)**

Em `cmd_selftest`, imediatamente a seguir ao bloco da Task 1 (depois da asserção `and the write is read back`), inserir:

```bash
  echo "platform_bin() / platform_check() — where the CLI is, and whether it is signed in"
  local pb="$tmp/pb"; mkdir -p "$pb/bin"
  printf '#!/bin/sh\necho "codex-cli 9.9.9"\n' > "$pb/bin/codex"; chmod +x "$pb/bin/codex"
  printf '{"platforms":{"openai":{"enabled":true,"bin":"%s","models":[]}}}\n' "$pb/bin/codex" > "$pb/platforms.json"
  type platform_check >/dev/null 2>&1 && ok "platform_check is defined" || bad "platform_check does not exist"
  [ "$( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=/env/codex; platform_bin openai )" = "/env/codex" ] \
    && ok "platform_bin: the environment override wins" || bad "env: $( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=/env/codex; platform_bin openai )"
  [ "$( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=""; platform_bin openai )" = "$pb/bin/codex" ] \
    && ok "platform_bin: then the file's bin" || bad "file: $( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=""; platform_bin openai )"
  [ "$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_BIN=/detected/codex; platform_bin openai )" = "/detected/codex" ] \
    && ok "platform_bin: then the detected default" || bad "auto: $( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_BIN=/detected/codex; platform_bin openai )"
  [ "$( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=""; platform_bin_source openai )" = "file" ] \
    && [ "$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; platform_bin_source openai )" = "auto" ] \
    && [ "$( AGENTLOOP_CODEX_BIN=/env/codex; platform_bin_source openai )" = "env" ] \
    && ok "platform_bin_source names the layer that answered" || bad "bin_source"
  _pc="$( PLATFORMS_FILE="$pb/platforms.json"; AGENTLOOP_CODEX_BIN=""; platform_check openai )"
  printf '%s' "$_pc" | "$JQ" -e --arg b "$pb/bin/codex" \
    '.platform == "openai" and .supported == true and .ready == true and .bin == $b and .bin_found == true and .bin_source == "file" and .version == "codex-cli 9.9.9"' >/dev/null 2>&1 \
    && ok "platform_check openai: found, version read, signed in through the stand-in" || bad "check openai: $_pc"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_BIN="$BASE_DIR/test/fake-codex"; FAKE_CODEX_LOGGED_OUT=1 platform_check openai )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .reason' | tr '\n' '|')" = "false|codex is not signed in (run: codex login)|" ] \
    && ok "platform_check openai: signed out, with today's sentence" || bad "signed out: $_pc"
  [ "$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_BIN=/nonexistent; platform_ready openai )" = "codex not found at /nonexistent — set the path in Settings (or AGENTLOOP_CODEX_BIN); install: npm i -g @openai/codex, then codex login" ] \
    && ok "platform_ready: a missing binary names the path, the setting and the install command" || bad "not found: $( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_BIN=/nonexistent; platform_ready openai )"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CLAUDE_BIN=""; CLAUDE_BIN="$BASE_DIR/test/fake-claude"; AGENTLOOP_CLAUDE_CONFIG_DIR=""; PLIST_PATH=/nonexistent; platform_check anthropic )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .account, .version' | tr '\n' '|')" = "true|fake@example.org · max plan|2.1.258 (Claude Code)|" ] \
    && ok "platform_check anthropic: the account and plan come from claude auth status" || bad "check anthropic: $_pc"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CLAUDE_BIN=""; CLAUDE_BIN="$BASE_DIR/test/fake-claude"; AGENTLOOP_CLAUDE_CONFIG_DIR=""; PLIST_PATH=/nonexistent; FAKE_CLAUDE_LOGGED_OUT=1 platform_check anthropic )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .reason' | tr '\n' '|')" = "false|claude is not signed in (run: claude auth login)|" ] \
    && ok "platform_check anthropic: signed out says how to sign in" || bad "anthropic signed out: $_pc"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CLAUDE_BIN=""; CLAUDE_BIN="$BASE_DIR/test/fake-claude"; AGENTLOOP_CLAUDE_CONFIG_DIR=/pinned/home; PLIST_PATH=/nonexistent; FAKE_CLAUDE_LOGGED_OUT=1 platform_check anthropic )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.reason')" = "claude is not signed in in /pinned/home (run: CLAUDE_CONFIG_DIR=/pinned/home claude auth login)" ] \
    && ok "and names the pinned account directory when there is one" || bad "pinned signed out: $_pc"
  printf '#!/bin/sh\necho "2.0.0 (Claude Code)"\n' > "$pb/bin/oldclaude"; chmod +x "$pb/bin/oldclaude"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CLAUDE_BIN=""; CLAUDE_BIN="$pb/bin/oldclaude"; AGENTLOOP_CLAUDE_CONFIG_DIR=""; PLIST_PATH=/nonexistent; platform_check anthropic )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .account' | tr '\n' '|')" = "true|unknown — claude auth status needs Claude Code 2.1+|" ] \
    && ok "a CLI without `auth status` counts as ready, and says the account is unknown" || bad "old cli: $_pc"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN=""; OPENCODE_BIN=/nonexistent; platform_check opencode )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.supported, .ready, .bin_found, .reason' | tr '\n' '|')" = "false|false|false|opencode not found at /nonexistent — set the path in Settings (or AGENTLOOP_OPENCODE_BIN); install: brew install opencode|" ] \
    && ok "platform_check opencode: planned, and not found says how to install it" || bad "opencode missing: $_pc"
  printf '#!/bin/sh\necho "1.18.30"\n' > "$pb/bin/opencode"; chmod +x "$pb/bin/opencode"
  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_OPENCODE_BIN=""; OPENCODE_BIN="$pb/bin/opencode"; platform_check opencode )"
  [ "$(printf '%s' "$_pc" | "$JQ" -r '.ready, .bin_found, .version, .reason' | tr '\n' '|')" = "false|true|1.18.30|runs on OpenCode arrive with the OpenCode engine|" ] \
    && ok "platform_check opencode: found and versioned, still not ready, with the reason" || bad "opencode found: $_pc"
  [ "$(platform_check martian | "$JQ" -r .reason)" = "unknown platform martian" ] && ok "an unlisted platform is answered, never a crash" || bad "unlisted"
```

E no bloco `status_platforms_block()` já existente, substituir a asserção

```bash
    printf '%s\n' "$_b" | grep -q '^openai    : codex not found at /nonexistent (set AGENTLOOP_CODEX_BIN)$' \
```
por
```bash
    printf '%s\n' "$_b" | grep -q '^openai    : codex not found at /nonexistent — set the path in Settings (or AGENTLOOP_CODEX_BIN); install: npm i -g @openai/codex, then codex login$' \
```

- [ ] **Step 2: Correr e ver falhar**

```bash
bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed"
```
Esperado: `FAIL  platform_check does not exist` e o resto do bloco novo a falhar.

- [ ] **Step 3: Implementar**

(a) `test/fake-claude` — logo a seguir a `set -u`, antes do bloco `FAKE_ACCOUNT_OUT`:

```bash
# The two probes platform_check makes BEFORE a launch. Answered here, before
# any recording below, so a FAKE_ARGV_OUT/FAKE_ACCOUNT_OUT set for the launch
# never captures the probe instead of the run.
#   FAKE_CLAUDE_LOGGED_OUT  set to play a CLI with no session: `auth status` exits 1
case "${1:-}" in
  --version) echo "2.1.258 (Claude Code)"; exit 0 ;;
  auth)
    if [ -n "${FAKE_CLAUDE_LOGGED_OUT:-}" ]; then
      printf '{"loggedIn":false,"authMethod":"none"}\n'; exit 1
    fi
    printf '{"loggedIn":true,"authMethod":"claude.ai","email":"fake@example.org","subscriptionType":"max"}\n'; exit 0 ;;
esac
```
Acrescentar `FAKE_CLAUDE_LOGGED_OUT` à lista de variáveis no comentário de cabeçalho do ficheiro.

(b) Em `bin/agentloop`, substituir as linhas `CLAUDE_BIN=…` e `CODEX_BIN=…` (com o seu comentário) por:

```bash
# Where each CLI is, before config/platforms.json has a say: the AGENTLOOP_*_BIN
# variable (tests, stand-ins, a second install), else detection. platform_bin
# below puts the file's own `bin` between the two.
if [ -x "$HOME/.local/bin/claude" ]; then _claude_default="$HOME/.local/bin/claude"
else _claude_default="$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")"; fi
CLAUDE_BIN="${AGENTLOOP_CLAUDE_BIN:-$_claude_default}"
# The Codex CLI, for runs on the openai platform. On PATH from Homebrew
# (/opt/homebrew/bin, which the launchd plists already carry). Its account and
# its rollouts live under CODEX_HOME (the CLI's own variable, honoured as-is:
# `--help` says auth still uses it); platform_finish reads the rollout from
# there after every run.
CODEX_BIN="${AGENTLOOP_CODEX_BIN:-$(command -v codex 2>/dev/null || echo /opt/homebrew/bin/codex)}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
# OpenCode: listed and detected, never launched in this release (PLATFORMS_PLANNED).
if command -v opencode >/dev/null 2>&1; then _opencode_default="$(command -v opencode)"
elif [ -x "$HOME/.opencode/bin/opencode" ]; then _opencode_default="$HOME/.opencode/bin/opencode"
else _opencode_default="/opt/homebrew/bin/opencode"; fi
OPENCODE_BIN="${AGENTLOOP_OPENCODE_BIN:-$_opencode_default}"
```
(Manter a linha `CODEX_HOME_DIR=` que já existe; não a duplicar.)

(c) Substituir `platform_bin()` e `platform_ready()` por:

```bash
platform_cli_name() { case "$1" in anthropic) printf 'claude' ;; openai) printf 'codex' ;; opencode) printf 'opencode' ;; esac; }
platform_install_hint() {
  case "$1" in
    anthropic) printf 'npm i -g @anthropic-ai/claude-code' ;;
    openai)    printf 'npm i -g @openai/codex, then codex login' ;;
    opencode)  printf 'brew install opencode' ;;
  esac
}
platform_bin_env() { # the AGENTLOOP_*_BIN override for a platform, or nothing
  case "$1" in
    anthropic) printf '%s' "${AGENTLOOP_CLAUDE_BIN:-}" ;;
    openai)    printf '%s' "${AGENTLOOP_CODEX_BIN:-}" ;;
    opencode)  printf '%s' "${AGENTLOOP_OPENCODE_BIN:-}" ;;
  esac
}
platform_bin_source() { # env | file | auto -- which layer platform_bin's answer came from
  if [ -n "$(platform_bin_env "$1")" ]; then printf 'env'
  elif [ -n "$(platforms_field "$1" bin)" ]; then printf 'file'
  else printf 'auto'; fi
}
platform_bin() { # platform_bin <platform> -> the CLI's path: the environment override, else config/platforms.json's bin, else the detected default
  local v
  if [ -z "$(platform_bin_env "$1")" ]; then
    v="$(platforms_field "$1" bin)"
    if [ -n "$v" ]; then expand_home "$v"; return; fi
  fi
  case "$1" in anthropic) printf '%s' "$CLAUDE_BIN" ;; openai) printf '%s' "$CODEX_BIN" ;; opencode) printf '%s' "$OPENCODE_BIN" ;; esac
}

# The live check behind every readiness answer: is the binary there, which
# version, is there a session, as whom. Never stored -- it costs 0.04-0.14 s
# (`codex login status`, `claude auth status --json`, `--version`), so the
# Settings page, `status` and every launch simply ask again.
platform_check() { # platform_check <platform> -> one JSON object; always exits 0
  local p="$1" bin src found=false ver="" acct="" reason="" ready=false supported=true
  if ! platform_listed "$p"; then
    "$JQ" -nc --arg p "$p" '{platform:$p, supported:false, ready:false, bin:"", bin_found:false, bin_source:"", version:"", account:"", reason:("unknown platform " + $p)}'
    return 0
  fi
  platform_planned "$p" && supported=false
  bin="$(platform_bin "$p")"; src="$(platform_bin_source "$p")"
  if [ -x "$bin" ]; then found=true; ver="$("$bin" --version 2>/dev/null | head -1)"; fi
  if [ "$found" = false ]; then
    reason="$(platform_cli_name "$p") not found at $bin — set the path in Settings (or AGENTLOOP_$(platform_cli_name "$p" | tr '[:lower:]' '[:upper:]')_BIN); install: $(platform_install_hint "$p")"
  elif [ "$supported" = false ]; then
    reason="runs on OpenCode arrive with the OpenCode engine"
  else
    case "$p" in
      anthropic)
        local out cfgdir rc; cfgdir="$(installed_config_dir)"
        if [ -n "$cfgdir" ]; then out="$(CLAUDE_CONFIG_DIR="$cfgdir" "$bin" auth status --json 2>/dev/null)"; rc=$?
        else out="$("$bin" auth status --json 2>/dev/null)"; rc=$?; fi
        if [ "$rc" -eq 0 ] && printf '%s' "$out" | "$JQ" -e '.loggedIn == true' >/dev/null 2>&1; then
          ready=true
          acct="$(printf '%s' "$out" | "$JQ" -r '[(.email // ""), ((.subscriptionType // "") | if . == "" then "" else . + " plan" end)] | map(select(. != "")) | join(" · ")' 2>/dev/null)"
          [ -n "$acct" ] || acct="signed in"
        else
          case "$out" in
            *loggedIn*)
              if [ -n "$cfgdir" ]; then reason="claude is not signed in in $cfgdir (run: CLAUDE_CONFIG_DIR=$cfgdir claude auth login)"
              else reason="claude is not signed in (run: claude auth login)"; fi ;;
            *) # no `auth status` on this CLI (pre-2.1): the binary counts as ready, as it always did
               ready=true; acct="unknown — claude auth status needs Claude Code 2.1+" ;;
          esac
        fi ;;
      openai)
        local line
        if line="$("$bin" login status 2>&1)"; then ready=true; acct="$(printf '%s\n' "$line" | head -1)"
        else reason="codex is not signed in (run: codex login)"; fi ;;
    esac
  fi
  "$JQ" -nc --arg p "$p" --argjson supported "$supported" --argjson ready "$ready" --arg bin "$bin" \
    --argjson found "$found" --arg src "$src" --arg ver "$ver" --arg acct "$acct" --arg reason "$reason" \
    '{platform:$p, supported:$supported, ready:$ready, bin:$bin, bin_found:$found, bin_source:$src, version:$ver, account:$acct, reason:$reason}'
}

platform_ready() { # platform_ready <platform> -> 0; or 1 with the reason on stdout (platform_check decides)
  local j; j="$(platform_check "$1")"
  [ "$(printf '%s' "$j" | "$JQ" -r '.ready')" = "true" ] && return 0
  printf '%s' "$(printf '%s' "$j" | "$JQ" -r '.reason')"
  return 1
}
```
(d) Os leitores directos das variáveis passam pela tabela: em `resolve_models_openai` (`[ ! -x "$CODEX_BIN" ]` e `raw="$("$CODEX_BIN" debug models …)"`, duas ocorrências), em `openai_catalog_ensure` (`[ -x "$CODEX_BIN" ]`) e em `model_alias_baseline` (`"$CLAUDE_BIN" -p …`), substituir `"$CODEX_BIN"` por `"$(platform_bin openai)"` e `"$CLAUDE_BIN"` por `"$(platform_bin anthropic)"`. Depois `grep -n '\$CODEX_BIN\|\$CLAUDE_BIN' bin/agentloop` só deve mostrar as definições, `platform_bin` e linhas dentro de `cmd_selftest`/`run_job`-fakes que ATRIBUEM as variáveis; qualquer outra leitura fora do selftest passa também a `platform_bin`.

- [ ] **Step 4: Correr e ver passar**

```bash
bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed"
```
Esperado: `0 failed`.

- [ ] **Step 5: Commit**

```bash
/usr/bin/git add bin/agentloop test/fake-claude
/usr/bin/git commit -m "feat(engine): platform_check -- binary, version and session, live; the file's bin between env and detection

platform_ready now answers from one probe that also says as whom the CLI
is signed in (claude auth status --json, codex login status); a missing
binary names the path, the setting and the install command; OpenCode is
listed and detected, never launched.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 3: Os comandos `agentloop platform …` e o `platforms` alargado

**Files:**
- Modify: `bin/agentloop` (funções novas a seguir a `platform_check`; `cmd_platforms`; o `case` de despacho no fim do ficheiro; `usage()`; `cmd_selftest`)

**Interfaces:**
- Consumes: Task 1 e Task 2; `openai_catalog_slugs`, `openai_catalog_available`, `resolve_models_openai`, `pricing_unpriced`, `PRICING_FILE`, `PYTHON`.
- Produces: `anthropic_catalog_ids` (um id por linha, família mais capaz e geração mais recente primeiro); `platform_catalog_ids <p>`; `platform_models_json <p> <stale> <reason>` → JSON `{platform, stale, reason, catalog_at, models:[{v,label,desc,efforts,deprecated_by,price,enabled}]}`; `platform_affected_note <p> [model]` (uma frase com os jobs afectados, ou nada); `cmd_platform <verb> <p> [arg]` com verbos `check|enable|disable|set-bin|models|set-models`; `cmd_platforms` com as chaves novas `supported, enabled, usable, bin, bin_source, bin_found, models_enabled, jobs_on_platform, jobs_using` em cada plataforma (as três) e `_error` no topo quando o ficheiro é inválido; despacho `platform)` e texto de `usage`.

- [ ] **Step 1: Escrever as asserções (falham)**

Em `cmd_selftest`, a seguir ao bloco da Task 2, inserir:

```bash
  echo "agentloop platform … — the commands the Settings page is made of"
  local pc="$tmp/pc"; mkdir -p "$pc/config" "$pc/data"
  printf '{"jobs":[{"id":"u1","model":"claude-opus-5","prompt":"x"},{"id":"u2","platform":"openai","model":"gpt-a","prompt":"x"}]}\n' > "$pc/config/jobs.json"
  printf '{"projects":[]}\n' > "$pc/config/projects.json"
  "$JQ" -n '{resolved:{opus:{id:"claude-opus-5",at:1}}, openai:{at:1, source:"fixture", models:[
      {slug:"gpt-a", display_name:"A", description:"da", visibility:"list", priority:6, efforts:["low","high"], default_effort:"low", deprecated_by:"", retires_at:""},
      {slug:"gpt-b", display_name:"B", description:"db", visibility:"list", priority:7, efforts:["low"], default_effort:"low", deprecated_by:"", retires_at:""}]}}' \
    > "$pc/config/models.json"
  printf '{"openai":{"gpt-a":{"input":4,"cached_input":0.4,"output":20,"source":"manual"}}}\n' > "$pc/config/pricing.json"
  pc_al() { AGENTLOOP_CONFIG="$pc/config" AGENTLOOP_DATA="$pc/data" AGENTLOOP_CLAUDE_BIN="$BASE_DIR/test/fake-claude" \
            AGENTLOOP_CODEX_BIN="$BASE_DIR/test/fake-codex" AGENTLOOP_CLAUDE_CONFIG_DIR="" CODEX_HOME="$pc/codex-home" "$BIN_DIR/agentloop" "$@"; }
  pc_al platform check openai | "$JQ" -e '.ready == true' >/dev/null 2>&1; want "platform check prints platform_check's JSON" 0 $?
  pc_al platform check martian >/dev/null 2>&1; want "platform check refuses an unlisted platform" 1 $?
  # the seed happened on that first read: both platforms in use are enabled with their models
  "$JQ" -e '.platforms.anthropic.enabled == true and .platforms.anthropic.models == ["claude-opus-5"] and .platforms.openai.models == ["gpt-a"]' "$pc/config/platforms.json" >/dev/null 2>&1 \
    && ok "the first command seeded config/platforms.json from the jobs in use" || bad "seed: $(cat "$pc/config/platforms.json")"
  out="$(pc_al platform disable openai 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && "$JQ" -e '.platforms.openai.enabled == false' "$pc/config/platforms.json" >/dev/null 2>&1 \
    && ok "platform disable writes enabled:false" || bad "disable: rc=$rc $out"
  case "$out" in *"1 enabled job (u2) runs on openai and will be skipped until it is enabled again"*) ok "and says which enabled jobs will be skipped" ;; *) bad "disable note: $out" ;; esac
  out="$(FAKE_CODEX_LOGGED_OUT=1 pc_al platform enable openai 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && "$JQ" -e '.platforms.openai.enabled == false' "$pc/config/platforms.json" >/dev/null 2>&1 \
    && ok "platform enable refuses while the check fails, and writes nothing" || bad "enable while signed out: rc=$rc $out"
  case "$out" in *"cannot enable openai: codex is not signed in (run: codex login)"*) ok "and says why" ;; *) bad "enable refusal: $out" ;; esac
  pc_al platform enable openai >/dev/null 2>&1; want "platform enable writes once the check passes" 0 $?
  "$JQ" -e '.platforms.openai.enabled == true' "$pc/config/platforms.json" >/dev/null 2>&1 && ok "and the file says so" || bad "enable not written"
  pc_al platform enable opencode >/dev/null 2>&1; want "platform enable refuses a planned platform" 1 $?
  pc_al platform set-bin openai /nonexistent/codex >/dev/null 2>&1; want "set-bin refuses a path that is not executable" 1 $?
  pc_al platform set-bin openai "$BASE_DIR/test/fake-codex" >/dev/null 2>&1; want "set-bin accepts an executable" 0 $?
  [ "$("$JQ" -r '.platforms.openai.bin' "$pc/config/platforms.json")" = "$BASE_DIR/test/fake-codex" ] && ok "and writes it" || bad "bin not written"
  pc_al platform set-bin openai "" >/dev/null 2>&1
  [ "$("$JQ" -r '.platforms.openai.bin' "$pc/config/platforms.json")" = "" ] && ok "set-bin with nothing goes back to detection" || bad "bin not cleared"
  _pm="$(pc_al platform models openai 2>/dev/null)"
  printf '%s' "$_pm" | "$JQ" -e '.platform == "openai" and .stale == false and (.models | map(.v)) == ["gpt-a","gpt-b"] and .models[0].enabled == true and .models[1].enabled == false and .models[0].price.input == 4 and .models[1].price == null and .models[0].efforts == ["low","high"]' >/dev/null 2>&1 \
    && ok "platform models: the catalog in priority order, each slug with enabled, efforts and price" || bad "models openai: $_pm"
  _pm="$(pc_al platform models anthropic 2>/dev/null)"
  printf '%s' "$_pm" | "$JQ" -e '.platform == "anthropic" and (.models | map(.v) | index("claude-opus-5")) != null and (.models[] | select(.v == "claude-opus-5") | .enabled) == true' >/dev/null 2>&1 \
    && ok "platform models anthropic: the ids in use are listed and flagged" || bad "models anthropic: $_pm"
  pc_al platform models opencode | "$JQ" -e '.models == [] and (.reason | length) > 0' >/dev/null 2>&1; want "platform models opencode: an empty list with the reason" 0 $?
  printf '["gpt-zzz"]' | pc_al platform set-models openai >/dev/null 2>&1; want "set-models refuses an id outside the catalog" 1 $?
  printf 'not json' | pc_al platform set-models openai >/dev/null 2>&1; want "set-models refuses anything but a JSON list" 1 $?
  out="$(printf '["gpt-b"]' | pc_al platform set-models openai 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$("$JQ" -c '.platforms.openai.models' "$pc/config/platforms.json")" = '["gpt-b"]' ] \
    && ok "set-models writes the list it was given" || bad "set-models: rc=$rc $out"
  case "$out" in *"1 enabled job (u2) runs on openai with gpt-a and will be skipped until it is enabled again"*) ok "and names the jobs whose model was switched off" ;; *) bad "set-models note: $out" ;; esac
  # an id already enabled may stay even when the catalog no longer carries it
  "$JQ" '.platforms.openai.models = ["gpt-gone","gpt-b"]' "$pc/config/platforms.json" > "$pc/pf.next"; mv "$pc/pf.next" "$pc/config/platforms.json"
  printf '["gpt-gone","gpt-a"]' | pc_al platform set-models openai >/dev/null 2>&1; want "set-models keeps an already-enabled id the catalog dropped" 0 $?
  _pl="$(pc_al platforms 2>/dev/null)"
  printf '%s' "$_pl" | "$JQ" -e '(keys | sort) == ["anthropic","openai","opencode"] and .opencode.supported == false and .openai.supported == true
      and .openai.enabled == true and .openai.usable == true and .openai.models_enabled == ["gpt-gone","gpt-a"] and .openai.bin_source == "env"
      and .openai.jobs_on_platform == 1 and .openai.jobs_using == {"gpt-a": 1} and .anthropic.jobs_using == {"claude-opus-5": 1}
      and .opencode.usable == false and (.opencode.models_enabled == [])' >/dev/null 2>&1 \
    && ok "platforms: the three platforms, each with enabled, usable, bin_source, models_enabled and the jobs using them" || bad "platforms: $_pl"
  printf '{oops' > "$pc/config/platforms.json"
  pc_al platforms 2>/dev/null | "$JQ" -e '._error | test("not a valid platforms file")' >/dev/null 2>&1; want "platforms carries _error when the file is unreadable" 0 $?
  pc_al platform enable openai >/dev/null 2>&1; want "and enable refuses to write over it" 1 $?
```

- [ ] **Step 2: Correr e ver falhar**

```bash
bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed"
```
Esperado: `FAIL  platform check prints platform_check's JSON` (comando desconhecido) e os seguintes.

- [ ] **Step 3: Implementar**

(a) A seguir a `platform_ready()`:

```bash
# --- the catalogs a platform can enable from --------------------------------------
anthropic_catalog_ids() { # every claude-* id this install can name, most capable family and newest generation first
  local bin real
  bin="$(platform_bin anthropic)"
  real="$("$PYTHON" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$bin" 2>/dev/null || printf '%s' "$bin")"
  {
    # the CLI's own list: the ids compiled into the binary (what the server's picker has always scanned)
    [ -r "$real" ] && LC_ALL=C grep -aoE 'claude-(opus|sonnet|haiku|fable)-[0-9]+(-[0-9]+)*' "$real" 2>/dev/null
    [ -f "$MODELS_FILE" ] && "$JQ" -r '.resolved[]?.id // empty' "$MODELS_FILE" 2>/dev/null
    [ -f "$JOBS_FILE" ] && "$JQ" -r '.jobs[]? | .model // empty | select(startswith("claude-"))' "$JOBS_FILE" 2>/dev/null
    [ -f "$PROJECTS_FILE" ] && "$JQ" -r '.projects[]? | ((.security | objects) // {}).model // empty | select(startswith("claude-"))' "$PROJECTS_FILE" 2>/dev/null
  } | "$JQ" -R . | "$JQ" -rs '
    def fam: (capture("^claude-(?<f>[a-z]+)") | .f) // "";
    def nums: [scan("[0-9]+") | tonumber | -.];
    unique | sort_by([((["opus","sonnet","haiku","fable"] | index(fam)) // 9), nums]) | .[]' 2>/dev/null
}
platform_catalog_ids() { # platform_catalog_ids <platform> -> what set-models may enable, one id per line: the VISIBLE catalog, what the Settings page lists
  case "$1" in anthropic) anthropic_catalog_ids ;; openai) openai_catalog_visible ;; *) : ;; esac
}

platform_models_json() { # platform_models_json <platform> <stale true|false> <reason> -> the catalog with `enabled` per model
  local p="$1" stale="${2:-false}" reason="${3:-}" enabled cat_at arr pricing='{}'
  enabled="$(platform_models_enabled "$p" | "$JQ" -R . | "$JQ" -sc .)"
  case "$p" in
    anthropic)
      cat_at="$(num "$("$JQ" -r '[.resolved[]?.at // 0] | max // 0' "$MODELS_FILE" 2>/dev/null)")"
      arr="$(anthropic_catalog_ids | "$JQ" -R . | "$JQ" -sc .)"; [ -n "$arr" ] || arr='[]'
      printf '%s' "$arr" | "$JQ" -c --arg p "$p" --argjson stale "$stale" --arg reason "$reason" --argjson enabled "$enabled" --argjson at "$cat_at" \
        '{platform:$p, stale:$stale, reason:$reason, catalog_at:$at,
          models: map({v:., label:., desc:"", efforts:["low","medium","high","xhigh","max"], deprecated_by:"", price:null,
                       enabled: (. as $x | ($enabled | index($x)) != null)})}' ;;
    openai)
      cat_at="$(num "$("$JQ" -r '.openai.at // 0' "$MODELS_FILE" 2>/dev/null)")"
      [ -f "$PRICING_FILE" ] && pricing="$("$JQ" -c '.openai // {}' "$PRICING_FILE" 2>/dev/null || echo '{}')"
      arr=""; openai_catalog_available && arr="$("$JQ" -c '[.openai.models[] | select(.visibility == "list")] | sort_by(.priority)' "$MODELS_FILE" 2>/dev/null)"
      [ -n "$arr" ] || arr='[]'
      printf '%s' "$arr" | "$JQ" -c --arg p "$p" --argjson stale "$stale" --arg reason "$reason" --argjson enabled "$enabled" --argjson at "$cat_at" --argjson pricing "$pricing" \
        '{platform:$p, stale:$stale, reason:$reason, catalog_at:$at,
          models: map({v:.slug, label:(.display_name // .slug), desc:(.description // ""), efforts:(.efforts // []), deprecated_by:(.deprecated_by // ""),
                       price: (($pricing[.slug] // null) | if . != null and (.input | type) == "number" and (.output | type) == "number" then {input:.input, output:.output} else null end),
                       enabled: (.slug as $x | ($enabled | index($x)) != null)})}' ;;
    *)
      "$JQ" -nc --arg p "$p" '{platform:$p, stale:false, reason:"the model list arrives with the OpenCode engine", catalog_at:0, models:[]}' ;;
  esac
}

platform_affected_note() { # platform_affected_note <platform> [model] -> the enabled jobs and blocks that lose their platform or model, as one sentence; nothing when none
  local who n names
  who="$(platform_jobs_on "$1" "${2:-}")"
  n="$(num "$(printf '%s\n' "$who" | grep -c . 2>/dev/null)")"
  [ "$n" -gt 0 ] || return 0
  names="$(printf '%s\n' "$who" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  if [ -n "${2:-}" ]; then
    printf '%s enabled job%s (%s) run%s on %s with %s and will be skipped until it is enabled again\n' "$n" "$([ "$n" -eq 1 ] || printf s)" "$names" "$([ "$n" -eq 1 ] && printf s)" "$1" "$2"
  else
    printf '%s enabled job%s (%s) run%s on %s and will be skipped until it is enabled again\n' "$n" "$([ "$n" -eq 1 ] || printf s)" "$names" "$([ "$n" -eq 1 ] && printf s)" "$1"
  fi
}

cmd_platform() { # agentloop platform <check|enable|disable|set-bin|models|set-models> <platform> [path]
  local verb="${1:-}" p="${2:-}" j out rc list cur added removed id catalog
  case "$verb" in check|enable|disable|set-bin|models|set-models) ;;
    *) die "usage: agentloop platform <check|enable|disable|set-bin|models|set-models> <platform>" ;; esac
  platform_listed "$p" || die "platform: unknown platform '$p' (one of: $PLATFORMS $PLATFORMS_PLANNED)"
  case "$verb" in
    check) platform_check "$p" ;;
    enable)
      j="$(platform_check "$p")"
      [ "$(printf '%s' "$j" | "$JQ" -r .ready)" = "true" ] || die "cannot enable $p: $(printf '%s' "$j" | "$JQ" -r .reason)"
      write_platforms --arg p "$p" '.platforms[$p] = ((.platforms[$p] // {bin:"", models:[]}) + {enabled:true})'
      echo "$p enabled" ;;
    disable)
      write_platforms --arg p "$p" '.platforms[$p] = ((.platforms[$p] // {bin:"", models:[]}) + {enabled:false})'
      echo "$p disabled"
      platform_affected_note "$p" ;;
    set-bin)
      local path="${3:-}"
      if [ -n "$path" ]; then
        [ -x "$(expand_home "$path")" ] || die "set-bin: not executable: $path"
      fi
      write_platforms --arg p "$p" --arg b "$path" '.platforms[$p] = ((.platforms[$p] // {enabled:false, models:[]}) + {bin:$b})'
      if [ -n "$path" ]; then echo "$p binary: $path"; else echo "$p binary: detected ($(platform_bin "$p"))"; fi ;;
    models)
      local stale=false reason=""
      if [ "$p" = "openai" ]; then
        out="$(resolve_models_openai 2>&1)"; rc=$?
        if [ "$rc" -ne 0 ] || ! openai_catalog_available; then stale=true; reason="refresh failed: $(printf '%s' "$out" | tail -1)"; fi
      fi
      platform_models_json "$p" "$stale" "$reason" ;;
    set-models)
      list="$(cat | "$JQ" -c 'if type == "array" and all(.[]; type == "string") then . else error("not a list") end' 2>/dev/null)" \
        || die "set-models: expected a JSON list of model ids on stdin"
      cur="$(platform_models_enabled "$p" | "$JQ" -R . | "$JQ" -sc .)"
      catalog="$(platform_catalog_ids "$p" | "$JQ" -R . | "$JQ" -sc .)"; [ -n "$catalog" ] || catalog='[]'
      # every NEW id has to be in the catalog; one already enabled may stay even when a refresh dropped it
      added="$(printf '%s' "$list" | "$JQ" -r --argjson cur "$cur" '.[] | select(. as $x | ($cur | index($x)) == null)')"
      for id in $added; do
        printf '%s' "$catalog" | "$JQ" -e --arg x "$id" 'index($x) != null' >/dev/null 2>&1 \
          || die "set-models: '$id' is not in the $p catalog (refresh with: agentloop platform models $p)"
      done
      removed="$(printf '%s' "$cur" | "$JQ" -r --argjson new "$list" '.[] | select(. as $x | ($new | index($x)) == null)')"
      write_platforms --arg p "$p" --argjson m "$list" '.platforms[$p] = ((.platforms[$p] // {enabled:false, bin:""}) + {models:$m})'
      echo "$p models: $(printf '%s' "$list" | "$JQ" -r 'join(" ")')"
      for id in $removed; do platform_affected_note "$p" "$id"; done ;;
  esac
}
```

(b) `cmd_platforms` — substituir a função inteira por:

```bash
cmd_platforms() { # one JSON object: what each listed platform offers, whether it is ready, and what the operator enabled
  local p j ready reason perms efforts dm dp cat_at cat_ok pr_at pr_ck pr_src unpriced supported enabled usable bin src found men jon jus err
  for p in $PLATFORMS $PLATFORMS_PLANNED; do
    j="$(platform_check "$p")"
    ready="$(printf '%s' "$j" | "$JQ" -r .ready)"; reason="$(printf '%s' "$j" | "$JQ" -r .reason)"
    supported="$(printf '%s' "$j" | "$JQ" -r .supported)"; bin="$(printf '%s' "$j" | "$JQ" -r .bin)"
    src="$(printf '%s' "$j" | "$JQ" -r .bin_source)"; found="$(printf '%s' "$j" | "$JQ" -r .bin_found)"
    [ "$ready" = "true" ] && reason=""
    if platform_known "$p"; then
      perms="$(platform_permissions "$p" | "$JQ" -R . | "$JQ" -sc .)"
      if [ "$p" = "openai" ]; then efforts="$(openai_catalog_all_efforts | "$JQ" -R . | "$JQ" -sc .)"; else efforts="$(platform_efforts "$p" | "$JQ" -R . | "$JQ" -sc .)"; fi
      dm="$(platform_default_model "$p")"; dp="$(platform_default_permission "$p" job)"
    else
      perms='[]'; efforts='[]'; dm=""; dp=""
    fi
    if platform_enabled "$p"; then enabled=true; else enabled=false; fi
    if platform_usable "$p"; then usable=true; else usable=false; fi
    men="$(platform_models_enabled "$p" | "$JQ" -R . | "$JQ" -sc .)"
    jon="$(num "$(platform_jobs_on "$p" | grep -c . 2>/dev/null)")"
    jus="$(platforms_jq "$(platform_default_model anthropic)" "$(platform_default_model openai)" \
             '[uses[] | select(.p == $p) | select(.m != "")] | group_by(.m) | map({key: .[0].m, value: length}) | from_entries' -c --arg p "$p")"
    cat_at=0; cat_ok=false; pr_at=0; pr_ck=0; pr_src=""; unpriced="[]"
    if [ "$p" = "openai" ]; then
      cat_at="$(num "$("$JQ" -r '.openai.at // 0' "$MODELS_FILE" 2>/dev/null)")"
      openai_catalog_available && cat_ok=true
      pr_at="$(num "$("$JQ" -r '._refreshed_at // 0' "$PRICING_FILE" 2>/dev/null)")"
      # When the last refresh CHECKED, as against when it last changed
      # anything: a source that answers 304 stamps only this one, and without
      # it a table that is current looks stale for as long as the etag holds.
      pr_ck="$(num "$("$JQ" -r '._checked_at // 0' "$PRICING_FILE" 2>/dev/null)")"
      pr_src="$("$JQ" -r '._source_url | if type == "string" then . else "" end' "$PRICING_FILE" 2>/dev/null)"
      unpriced="$(pricing_unpriced | "$JQ" -R . | "$JQ" -sc .)"
    fi
    "$JQ" -nc --arg p "$p" --argjson ready "$ready" --arg reason "$reason" \
      --argjson perms "$perms" --argjson efforts "$efforts" --arg dm "$dm" --arg dp "$dp" \
      --argjson supported "$supported" --argjson enabled "$enabled" --argjson usable "$usable" \
      --arg bin "$bin" --arg src "$src" --argjson found "$found" --argjson men "$men" --argjson jon "$jon" --argjson jus "$jus" \
      --argjson cat_at "$cat_at" --argjson cat_ok "$cat_ok" \
      --argjson pr_at "$pr_at" --argjson pr_ck "$pr_ck" --arg pr_src "$pr_src" --argjson unpriced "$unpriced" \
      '{($p): ({ready:$ready, reason:$reason, permissions:$perms, efforts:$efforts,
                default_model:$dm, default_permission:$dp,
                supported:$supported, enabled:$enabled, usable:$usable, bin:$bin, bin_source:$src, bin_found:$found,
                models_enabled:$men, jobs_on_platform:$jon, jobs_using:$jus}
               + (if $p == "openai" then {catalog_at:$cat_at, catalog_available:$cat_ok,
                                          pricing_at:$pr_at, pricing_checked_at:$pr_ck,
                                          pricing_source:$pr_src, unpriced:$unpriced} else {} end))}'
  done | "$JQ" -sc 'add' | {
    err="$(platforms_error)"
    if [ -n "$err" ]; then "$JQ" -c --arg e "$err" '. + {_error: $e}'; else cat; fi
  }
}
```

(c) No `case "${1:-}" in` final, a seguir à linha `  platforms) cmd_platforms ;;`:

```bash
  platform)  shift; cmd_platform "$@" ;;
```

(d) Em `usage()`, a seguir à linha que descreve `agentloop platforms`:

```
  agentloop platform check|enable|disable|set-bin|models|set-models <platform> [path]
                            what Settings › Platforms does: probe a CLI, switch a platform on or off,
                            point at its binary, refresh its catalog, choose its models (JSON list on stdin)
```

- [ ] **Step 4: Correr e ver passar**

```bash
bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed"
```
Esperado: `0 failed`.

- [ ] **Step 5: Commit**

```bash
/usr/bin/git add bin/agentloop
/usr/bin/git commit -m "feat(engine): agentloop platform check|enable|disable|set-bin|models|set-models, and platforms says what is enabled

The commands the Settings page is made of. enable refuses while the
check fails; disable and set-models say which enabled jobs will be
skipped; set-models only admits ids the catalog carries, and keeps one
a refresh dropped. platforms lists the planned OpenCode too, and _error
when the file cannot be read.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 4: As portas — recusas no lançamento, validação na escrita, `status`, o tick, `install.sh`, e2e

**Files:**
- Modify: `bin/agentloop` (`platform_default_model`; `run_job`; `cmd_set_field`; `cmd_create`; `cmd_project_set`; `security_derived_jobs`; `status_platforms_block`; `cmd_tick`; `cmd_selftest` — blocos `cfg_al`, `dplat`, `dnocat`, `sec_env`, `status_platforms_block`, `cmd_project_set`)
- Modify: `install.sh`
- Modify: `test/e2e.test.sh`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `platform_default_model <p>` = primeiro id de `models` (vazio sem nenhum); `platform_models_enabled_line <p>` (ids separados por espaço, sem espaço final); as recusas e mensagens fixadas em *Global Constraints*; `status_platforms_block` no formato novo (uma linha por plataforma listada: `<p> : enabled|disabled — <versão>, <conta>[ (in <dir>)]; N of M models enabled[; catalog …]` ou `<p> : enabled|disabled — <razão>` ou `opencode  : planned — <razão>`); `cmd_tick` regista `config: <erro>` quando o ficheiro é inválido; `install.sh` termina com a frase quando nada é `usable`.

- [ ] **Step 1: Os fixtures que os blocos existentes passam a precisar (o selftest falha sem eles)**

Cada bloco do selftest que lança runs ou escreve jobs em config de rascunho passa a declarar o seu ficheiro de plataformas — como já declara `jobs.json` e `projects.json`:

(a) No bloco `cfg_al` (procurar `cfg_al()  { AGENTLOOP_CONFIG="$tmp/cfg/config"`), logo depois da escrita de `$tmp/cfg/config/jobs.json`:

```bash
  "$JQ" -n '{platforms:{anthropic:{enabled:true,bin:"",models:["opus"]},
                        openai:{enabled:true,bin:"",models:["gpt-a","gpt-b"]},
                        opencode:{enabled:false,bin:"",models:[]}}}' > "$tmp/cfg/config/platforms.json"
```

(b) No bloco `security_derived_jobs()` (procurar `dplat() {`): acrescentar `PLATFORMS_FILE="$tmp/dplat/platforms.json";` dentro do subshell de `dplat()` (ao lado de `JOBS_FILE=`) e, antes da definição, escrever o mesmo JSON de (a) para `$tmp/dplat/platforms.json`. Em `dnocat()`, `PLATFORMS_FILE="$tmp/dnocat/platforms.json";` e o ficheiro `{"platforms":{"openai":{"enabled":true,"bin":"","models":[]}}}` (openai ligado, sem modelos: o modelo derivado tem de continuar vazio).

(c) Em `sec_env()` (procurar `  sec_env() {`), acrescentar `PLATFORMS_FILE="$sec/cfg/platforms.json"` à lista de atribuições e, no fixture logo acima (a seguir a `printf '{"jobs":[]}\n' > "$sec/cfg/jobs.json"`):

```bash
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},"openai":{"enabled":false,"bin":"","models":[]},"opencode":{"enabled":false,"bin":"","models":[]}}}\n' > "$sec/cfg/platforms.json"
```

(d) No bloco `cmd_project_set()` (procurar `echo "cmd_project_set() — a settings save files settings_changed`), o mesmo ficheiro de (c) na pasta de config que o bloco usa, e `PLATFORMS_FILE` apontado para ele no mesmo sítio onde o bloco aponta `PROJECTS_FILE` — o `project-set` passa a recusar um projecto cuja plataforma não está `usable`.

(e) Em `test/e2e.test.sh`, logo a seguir ao `cat > "$ROOT/config/projects.json" <<JSON … JSON`:

```bash
# What the operator would have switched on in Settings. Explicit rather than
# seeded: the seed is scenario 28's own subject.
cat > "$ROOT/config/platforms.json" <<'JSON'
{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},
              "openai":{"enabled":true,"bin":"","models":["gpt-5.6-sol"]},
              "opencode":{"enabled":false,"bin":"","models":[]}}}
JSON
```

- [ ] **Step 2: Escrever as asserções novas (falham)**

(a) No bloco `cfg_al`, depois da última asserção existente (`create refuses an effort the model does not offer`):

```bash
  # the operator's own choice, on top of the CLI's (cj is back on anthropic
  # after the round trip above: put it on openai first, or the CLI's own
  # "not an openai model" refusal fires before Settings gets a say)
  printf 'openai' | cfg_al set-field cj platform >/dev/null 2>&1
  printf '["gpt-b"]' | cfg_al platform set-models openai >/dev/null 2>&1
  out="$(printf 'gpt-a' | cfg_al set-field cj model 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && case "$out" in *"model 'gpt-a' is not enabled in Settings — openai enables: gpt-b"*) ok "set-field model refuses a catalog slug switched off in Settings, naming what is on" ;; *) bad "refusal: $out" ;; esac
  [ "$rc" -eq 0 ] && bad "a switched-off model was accepted"
  printf '["gpt-a","gpt-b"]' | cfg_al platform set-models openai >/dev/null 2>&1
  "$JQ" '.platforms.openai.enabled = false' "$tmp/cfg/config/platforms.json" > "$tmp/cfg/pf.next"; mv "$tmp/cfg/pf.next" "$tmp/cfg/config/platforms.json"
  out="$(printf 'openai' | cfg_al set-field cj platform 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && case "$out" in *"openai is not enabled in Settings — enable it there, or: agentloop platform enable openai"*) ok "set-field platform refuses a platform disabled in Settings" ;; *) bad "refusal: $out" ;; esac
  printf 'opencode' | cfg_al set-field cj platform >/dev/null 2>&1; want "set-field platform refuses the planned platform" 1 $?
  printf '{"id":"dj","platform":"openai","prompt":"p"}' | cfg_al create >/dev/null 2>&1; want "create refuses a disabled platform" 1 $?
  "$JQ" '.platforms.openai.enabled = true' "$tmp/cfg/config/platforms.json" > "$tmp/cfg/pf.next"; mv "$tmp/cfg/pf.next" "$tmp/cfg/config/platforms.json"
  printf '{"id":"dj","platform":"openai","model":"gpt-b","prompt":"p"}' | cfg_al create >/dev/null 2>&1; want "create accepts an enabled model on an enabled platform" 0 $?
  printf '["gpt-a"]' | cfg_al platform set-models openai >/dev/null 2>&1
  printf '{"id":"ej2","platform":"openai","model":"gpt-b","prompt":"p"}' | cfg_al create >/dev/null 2>&1; want "create refuses a model switched off in Settings" 1 $?
  printf '["gpt-a","gpt-b"]' | cfg_al platform set-models openai >/dev/null 2>&1
  printf '{"name":"np","platform":"openai","security":{"enabled":true,"model":"gpt-zzz"}}' | cfg_al project-set >/dev/null 2>&1; want "project-set refuses a security model that is not enabled" 1 $?
  printf '{"name":"np","platform":"openai","security":{"enabled":true,"platform":"anthropic","model":"opus"}}' | cfg_al project-set >/dev/null 2>&1; want "project-set accepts an enabled security model on the block's own platform" 0 $?
  "$JQ" '.platforms.anthropic.models = []' "$tmp/cfg/config/platforms.json" > "$tmp/cfg/pf.next"; mv "$tmp/cfg/pf.next" "$tmp/cfg/config/platforms.json"
  printf '{"name":"np2","platform":"anthropic"}' | cfg_al project-set >/dev/null 2>&1; want "project-set refuses a platform that is enabled but has no model switched on" 1 $?
  "$JQ" '.platforms.anthropic.models = ["opus"]' "$tmp/cfg/config/platforms.json" > "$tmp/cfg/pf.next"; mv "$tmp/cfg/pf.next" "$tmp/cfg/config/platforms.json"
  [ "$( PLATFORMS_FILE="$tmp/cfg/config/platforms.json"; platform_default_model openai )" = "gpt-a" ] \
    && ok "platform_default_model is the first model switched on" || bad "default: $( PLATFORMS_FILE="$tmp/cfg/config/platforms.json"; platform_default_model openai )"
  [ -z "$( PLATFORMS_FILE="$tmp/cfg/config/platforms.json"; platform_default_model opencode )" ] && ok "and nothing for a platform with none" || bad "opencode default not empty"
```

(b) No bloco `security_derived_jobs()`, acrescentar ao fixture `projects.json` de `dplat` um quarto projecto `{"name":"Oe","cwd":"/tmp/oe","security":{"enabled":true,"model":"claude-sonnet-5"}}` e, depois das asserções de `Oc`:

```bash
  [ "$(dplat security-oe .model)" = "opus" ] && ok "a model switched off in Settings falls back to the first one switched on" || bad "Oe model $(dplat security-oe .model)"
  grep -q "not enabled in Settings ('claude-sonnet-5' on anthropic) -- using opus" "$tmp/dplat/data/security/derivation-warnings.txt" 2>/dev/null \
    && ok "and the derivation warning says so" || bad "no warning for Oe: $(cat "$tmp/dplat/data/security/derivation-warnings.txt" 2>/dev/null)"
```

(c) No bloco `status_platforms_block()`, dentro do subshell `_spout="$( … )"`: acrescentar às atribuições iniciais `AGENTLOOP_CLAUDE_BIN=""`, `AGENTLOOP_CODEX_BIN=""` (as variáveis de ambiente do harness nunca podem vencer os stand-ins do bloco), `OPENCODE_BIN=/nonexistent`, `AGENTLOOP_OPENCODE_BIN=""`, `PLATFORMS_FILE="$tmp/sp/platforms.json"`, `JOBS_FILE="$tmp/sp/jobs.json"`, `PROJECTS_FILE="$tmp/sp/projects.json"`, e escrever `printf '{"jobs":[]}\n' > "$tmp/sp/jobs.json"`, `printf '{"projects":[]}\n' > "$tmp/sp/projects.json"` e `printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},"openai":{"enabled":true,"bin":"","models":["gpt-5.6-sol"]},"opencode":{"enabled":false,"bin":"","models":[]}}}\n' > "$tmp/sp/platforms.json"`. Substituir as sete asserções `printf '%s\n' "$_b" | grep -q …` por estas nove (mantendo o `resolve_models_openai >/dev/null` e o `"$JQ" 'del(.openai["gpt-5.4-mini"]) …'` onde estão):

```bash
    _b="$(status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '^anthropic : enabled — 2.1.0 (Claude Code), unknown — claude auth status needs Claude Code 2.1+; 1 of 1 models enabled$' \
      && ok "status_platforms_block: the Claude line carries enabled, version, account and the model count" \
      || bad "anthropic line: $(printf '%s\n' "$_b" | sed -n 1p)"
    printf '%s\n' "$_b" | grep -q '^openai    : enabled — codex-cli 0.148.0, Logged in using ChatGPT; 1 of 5 models enabled; catalog [0-9]*m ago (5 models); prices [0-9]*[mhd] ago; unpriced: none$' \
      && ok "status_platforms_block: the Codex line adds catalog age and size, price age, unpriced" \
      || bad "openai line: $(printf '%s\n' "$_b" | sed -n 2p)"
    printf '%s\n' "$_b" | grep -q '^opencode  : planned — opencode not found at /nonexistent — set the path in Settings (or AGENTLOOP_OPENCODE_BIN); install: brew install opencode$' \
      && ok "status_platforms_block: the planned platform says it is planned, and how to install it" \
      || bad "opencode line: $(printf '%s\n' "$_b" | sed -n 3p)"
    _b="$(AGENTLOOP_CLAUDE_CONFIG_DIR=/pinned/home status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '^anthropic : enabled — 2.1.0 (Claude Code), unknown — claude auth status needs Claude Code 2.1+ (in /pinned/home); 1 of 1 models enabled$' \
      && ok "status_platforms_block: a pinned account directory is named" \
      || bad "pinned anthropic line: $(printf '%s\n' "$_b" | sed -n 1p)"
    _b="$(PLIST_PATH="$tmp/sp/tick.plist" status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '(in /plist/home); 1 of 1 models enabled$' \
      && ok "status_platforms_block: the account a previous install wrote into the plist is named" \
      || bad "plist-pinned anthropic line: $(printf '%s\n' "$_b" | sed -n 1p)"
    status_platforms_block | grep -q 'prices never refreshed; unpriced: gpt-5.4-mini$' \
      && ok "status_platforms_block: an unstamped table says so, and an unpriced visible slug is named" \
      || bad "after the edit: $(status_platforms_block | sed -n 2p)"
    _b="$(FAKE_CODEX_LOGGED_OUT=1 status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '^openai    : enabled — codex is not signed in (run: codex login)$' \
      && ok "status_platforms_block: signed out reads as platform_ready's own sentence" \
      || bad "signed-out line: $(printf '%s\n' "$_b" | sed -n 2p)"
    CODEX_BIN=/nonexistent
    _b="$(status_platforms_block)"
    printf '%s\n' "$_b" | grep -q '^openai    : enabled — codex not found at /nonexistent — set the path in Settings (or AGENTLOOP_CODEX_BIN); install: npm i -g @openai/codex, then codex login$' \
      && ok "status_platforms_block: no codex reads as not found, never a crash" \
      || bad "no-codex line: $(printf '%s\n' "$_b" | sed -n 2p)"
    write_platforms '.platforms.anthropic.enabled = false' >/dev/null 2>&1
    status_platforms_block | grep -q '^anthropic : disabled — ' \
      && ok "status_platforms_block: a platform switched off says disabled" || bad "disabled line: $(status_platforms_block | sed -n 1p)"
```
E a asserção do pai passa a `grep -qx 'RESULT ok=9 bad=0'` com o texto `all 9 assertions reach the gate`. (O `tick.plist` de `/plist/home` já é escrito pelo bloco; manter.)

(d) Em `test/e2e.test.sh`, antes das três linhas finais (`echo`, `printf '\n  %s passed…'`, `[ "$fail" -eq 0 ]`):

```bash
echo
echo "26. a job on a platform switched off in Settings is skipped before it costs a slot"
mkjob j26
"$AL" platform disable anthropic >/dev/null 2>&1
FAKE_MODE=complete FAKE_SESSION=sess-26 "$AL" run j26 >/dev/null 2>&1
grep -q "j26: anthropic is disabled in Settings (agentloop platform enable anthropic), skipped" "$ROOT/data/tick.log" \
  && ok "the refusal is one line in tick.log" || bad "no refusal line: $(tail -3 "$ROOT/data/tick.log")"
[ -z "$(dirs j26)" ] && ok "and no run directory was cut" || bad "a worktree was cut for a refused run"
"$AL" platform enable anthropic >/dev/null 2>&1 || bad "platform enable anthropic failed over the stand-in"
FAKE_MODE=complete FAKE_SESSION=sess-26b "$AL" run j26 >/dev/null 2>&1
sleep 2
[ "$(lastrun | jq -r .session)" = "sess-26b" ] && ok "enabled again, the same job runs" || bad "no run after enable: $(lastrun)"

echo
echo "27. a model switched off in Settings is refused, and the line names what is enabled"
mkjob_openai j27
printf '["gpt-5.6-luna"]' | "$AL" platform set-models openai >/dev/null 2>&1
FAKE_MODE=complete FAKE_SESSION=thr-27 "$AL" run j27 >/dev/null 2>&1
grep -q "j27: model 'gpt-5.6-sol' is not enabled in Settings — openai enables: gpt-5.6-luna, skipped" "$ROOT/data/tick.log" \
  && ok "the refusal names the model and the enabled list" || bad "no model refusal: $(tail -3 "$ROOT/data/tick.log")"
printf '["gpt-5.6-sol"]' | "$AL" platform set-models openai >/dev/null 2>&1

echo
echo "28. upgrade path: no platforms file and an enabled job -> seeded from it, and the run is unchanged"
mkjob j28
jq '.jobs[0].enabled = true | .jobs[0].model = "claude-opus-5"' "$ROOT/config/jobs.json" > "$ROOT/config/jobs.next" && mv "$ROOT/config/jobs.next" "$ROOT/config/jobs.json"
rm -f "$ROOT/config/platforms.json"
FAKE_MODE=complete FAKE_SESSION=sess-28 "$AL" run j28 >/dev/null 2>&1
sleep 2
jq -e '.platforms.anthropic.enabled == true and (.platforms.anthropic.models | index("claude-opus-5")) != null' "$ROOT/config/platforms.json" >/dev/null 2>&1 \
  && ok "the file was seeded with the enabled job's platform and model" || bad "seed: $(cat "$ROOT/config/platforms.json" 2>/dev/null)"
[ "$(lastrun | jq -r .session)" = "sess-28" ] && ok "and the job ran as before" || bad "no run: $(lastrun)"
```

- [ ] **Step 3: Correr e ver falhar**

```bash
bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed"
```
Esperado: as asserções novas de (a)–(c) a falhar (as recusas ainda não existem; `platform_default_model` ainda responde `opus`).

- [ ] **Step 4: Implementar**

(a0) `platform_model_enabled` — a revisão da Task 1 notou a assimetria: a semente pode escrever uma família nua (`opus`) quando a cache ainda não a resolveu, e um job que depois nomeie o id explícito (`claude-opus-5`) não contaria como activado. Acrescentar, ao lado de `family_cached_id`:

```bash
family_of_cached_id() { # family_of_cached_id <id> -> the family whose cached resolution is this id, or nothing
  [ -f "$MODELS_FILE" ] || return 0
  "$JQ" -r --arg id "$1" '.resolved | to_entries[] | select(.value.id == $id) | .key' "$MODELS_FILE" 2>/dev/null | head -1
}
```
e em `platform_model_enabled`, depois da comparação pelo id resolvido, a comparação inversa: `fam="$(family_of_cached_id "$2")"; [ -n "$fam" ] && printf '%s\n' "$list" | grep -qxF -- "$fam"`. Uma asserção no bloco `pf` da Task 1 (junto às de `platform_model_enabled`): com a lista `["opus"]` e a cache a resolver `opus` para `claude-opus-5`, `platform_model_enabled anthropic claude-opus-5` responde 0.

(a) `platform_default_model` — substituir por:

```bash
platform_default_model() { # platform_default_model <platform> -> the first model switched on in Settings; nothing when none is
  platform_models_enabled "$1" | head -1
}
platform_models_enabled_line() { # the enabled ids on one line, space-separated, no trailing space -- for messages
  platform_models_enabled "$1" | tr '\n' ' ' | sed 's/ *$//'
}
```

(b) `run_job` — substituir as duas linhas

```bash
  platform_known "$platform" || { log_tick "$id: unknown platform '$platform', skipped"; return 1; }
  if ! not_ready="$(platform_ready "$platform")"; then
```
por
```bash
  # The operator's own gates, before the CLI's: a planned platform, a
  # platform switched off in Settings. Each is one line before a slot is
  # spent, the treatment `cwd missing` gets.
  if platform_planned "$platform"; then
    log_tick "$id: $platform is not supported yet — it arrives with the OpenCode engine, skipped"; return 1
  fi
  platform_known "$platform" || { log_tick "$id: unknown platform '$platform', skipped"; return 1; }
  platform_enabled "$platform" || { log_tick "$id: $platform is disabled in Settings (agentloop platform enable $platform), skipped"; return 1; }
  if ! not_ready="$(platform_ready "$platform")"; then
```
e, logo a seguir ao `fi` que fecha o bloco `if [ "$platform" = "openai" ]; then … fi` das recusas OpenAI:

```bash
  # After the catalog: a model the CLI knows but nobody switched on in Settings.
  if [ -z "$model" ]; then
    log_tick "$id: no model is enabled for $platform in Settings, skipped"; return 1
  fi
  if ! platform_model_enabled "$platform" "$model"; then
    log_tick "$id: model '$model' is not enabled in Settings — $platform enables: $(platform_models_enabled_line "$platform"), skipped"; return 1
  fi
```

(c) `cmd_set_field` — no ramo `model)`, entre o bloco `if ! platform_model_ok …; fi` e o `write_jobs`:

```bash
      platform_model_enabled "$p" "$value" \
        || die "model '$value' is not enabled in Settings — $p enables: $(platform_models_enabled_line "$p") (switch it on there, or: agentloop platform set-models $p)"
```
No ramo `platform)`, substituir `anthropic|openai) eff="$value" ;;` por:

```bash
        anthropic|openai)
          eff="$value"
          platform_usable "$value" || die "$value is not enabled in Settings — enable it there, or: agentloop platform enable $value" ;;
        opencode) die "opencode is not supported yet — it arrives with the OpenCode engine" ;;
```

(d) `cmd_create` — no `case "$cplat"`, antes de `*) die "create: platform must be anthropic or openai" ;;`, a linha `opencode) die "create: opencode is not supported yet — it arrives with the OpenCode engine" ;;`. Depois do bloco `if [ "$cplat" = "openai" ] && ! openai_catalog_ensure; then … fi`:

```bash
  platform_usable "$cplat" || die "create: $cplat is not enabled in Settings — enable it there, or: agentloop platform enable $cplat"
```
E logo a seguir a `platform_model_ok "$cplat" "$cm" || die "create: model '$cm' is not a $cplat model"`:

```bash
  platform_model_enabled "$cplat" "$cm" || die "create: model '$cm' is not enabled in Settings — $cplat enables: $(platform_models_enabled_line "$cplat")"
```

(e) `cmd_project_set` — a seguir ao `case "$plat" in … esac` existente:

```bash
  case "$plat" in
    anthropic|openai) platform_usable "$plat" || die "project-set: $plat is not enabled in Settings — enable it there, or: agentloop platform enable $plat" ;;
  esac
  # The security block's own platform and model, under the same rules. The
  # platform its model is judged against: the block's, else the project's as
  # sent, else the project's as stored, else anthropic.
  local sp sm eff_sp
  sp="$(echo "$partial" | "$JQ" -r '((.security | objects) // {}).platform // ""')"
  sm="$(echo "$partial" | "$JQ" -r '((.security | objects) // {}).model // ""')"
  case "$sp" in
    ''|null|anthropic|openai) : ;;
    *) die "project-set: security.platform must be anthropic or openai (or empty, to inherit the project's)" ;;
  esac
  if [ -n "$sp" ] && [ "$sp" != "null" ]; then
    platform_usable "$sp" || die "project-set: security.platform $sp is not enabled in Settings — enable it there, or: agentloop platform enable $sp"
  fi
  if [ -n "$sm" ] && [ "$sm" != "null" ]; then
    eff_sp="$sp"
    { [ -n "$eff_sp" ] && [ "$eff_sp" != "null" ]; } || eff_sp="$plat"
    { [ -n "$eff_sp" ] && [ "$eff_sp" != "null" ]; } || eff_sp="$(project_get "$name" '.platform' 'anthropic')"
    platform_known "$eff_sp" || eff_sp="anthropic"
    platform_model_enabled "$eff_sp" "$sm" \
      || die "project-set: security.model '$sm' is not enabled in Settings — $eff_sp enables: $(platform_models_enabled_line "$eff_sp")"
  fi
```

(f) `security_derived_jobs` — logo a seguir ao bloco `if ! platform_model_ok "$splat" "$smodel"; then … fi`:

```bash
    # The operator's own choice, on top of the CLI's: a model switched off in
    # Settings falls back to the first one switched on, with a warning; with
    # none switched on, the launch refuses and the warning says so now.
    if [ -n "$smodel" ] && platform_model_ok "$splat" "$smodel" && ! platform_model_enabled "$splat" "$smodel"; then
      local sfirst; sfirst="$(platform_default_model "$splat")"
      if [ -n "$sfirst" ]; then
        security_warn "security: project '$project' names a model that is not enabled in Settings ('$smodel' on $splat) -- using $sfirst"
        smodel="$sfirst"
      else
        security_warn "security: project '$project' runs on $splat but no model is enabled for it in Settings -- the analysis will be refused at launch"
      fi
    fi
```

(g) `status_platforms_block` — substituir a função inteira por:

```bash
status_platforms_block() { # one line per listed platform: enabled or not, version, account, models switched on; the Codex facts a refused run needs
  local p j ready ver acct reason state n_on n_all cfg
  for p in $PLATFORMS $PLATFORMS_PLANNED; do
    j="$(platform_check "$p")"
    ready="$(printf '%s' "$j" | "$JQ" -r .ready)"; ver="$(printf '%s' "$j" | "$JQ" -r .version)"
    acct="$(printf '%s' "$j" | "$JQ" -r .account)"; reason="$(printf '%s' "$j" | "$JQ" -r .reason)"
    if platform_planned "$p"; then printf '%-9s : planned — %s\n' "$p" "$reason"; continue; fi
    if platform_enabled "$p"; then state=enabled; else state=disabled; fi
    if [ "$ready" != "true" ]; then printf '%-9s : %s — %s\n' "$p" "$state" "$reason"; continue; fi
    n_on="$(num "$(platform_models_enabled "$p" | grep -c . 2>/dev/null)")"
    n_all="$(num "$({ platform_catalog_ids "$p"; platform_models_enabled "$p"; } | sort -u | grep -c . 2>/dev/null)")"
    # The pin the INSTALL carries (the variable, then the plist), not this
    # process's CLAUDE_CONFIG_DIR: `agentloop status` typed in a plain shell
    # has none, and would call a pinned install the CLI default.
    if [ "$p" = "anthropic" ]; then cfg="$(installed_config_dir)"; [ -z "$cfg" ] || acct="$acct (in $cfg)"; fi
    printf '%-9s : %s — %s, %s; %s of %s models enabled' "$p" "$state" "${ver:-$(platform_cli_name "$p")}" "$acct" "$n_on" "$n_all"
    if [ "$p" = "openai" ]; then
      local n u
      n="$(openai_catalog_visible 2>/dev/null | grep -c . || true)"
      # Empty when every visible slug is priced -- sed sees no line at all then,
      # so the "none" is the parameter expansion's, not a substitution's.
      u="$(pricing_unpriced | tr '\n' ' ' | sed 's/ *$//')"
      printf '; catalog %s (%s models); prices %s; unpriced: %s' \
        "$(age_label "$("$JQ" -r '.openai.at // 0' "$MODELS_FILE" 2>/dev/null)")" "${n:-0}" \
        "$(age_label "$("$JQ" -r '._checked_at // ._refreshed_at // 0' "$PRICING_FILE" 2>/dev/null)" 'never refreshed')" \
        "${u:-none}"
    fi
    printf '\n'
  done
}
```
Em `cmd_status`, a seguir a `status_platforms_block | sed 's/^/  /'`, acrescentar `local _perr; _perr="$(platforms_error)"; [ -z "$_perr" ] || echo "  WARNING: $_perr"`.

(h) `cmd_tick` — logo a seguir às primeiras linhas executáveis da função (a tomada do lock do tick e o seu `trap … EXIT`):

```bash
  # An unreadable platforms file switches every platform off (platforms_json);
  # say so once per tick rather than once per job, in the words the dashboard shows.
  local _perr; _perr="$(platforms_error)"
  [ -z "$_perr" ] || log_tick "config: $_perr"
```

(i) `install.sh` — a seguir a `"$HERE/bin/agentloop" install` (antes do `echo` que precede `Done.`):

```bash
# Nothing runs until a platform and at least one of its models are switched
# on -- a fresh install has none, an upgraded one keeps what its jobs use.
if ! "$HERE/bin/agentloop" platforms 2>/dev/null | jq -e '[.[] | objects | select(.usable == true)] | length > 0' >/dev/null 2>&1; then
  echo
  say "No platform is enabled yet. Open the dashboard and enable one in Settings › Platforms"
  say "(and switch on at least one model) before creating jobs."
fi
```

- [ ] **Step 5: Correr o selftest e o e2e e ver passar**

```bash
bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed"
bash test/e2e.test.sh 2>&1 | tail -20
```
Esperado: `0 failed` em ambos; o e2e termina com `… passed, 0 failed` e os cenários 26–28 verdes. Um bloco do selftest que falhe só com `is not enabled in Settings` é um bloco que ficou sem o fixture do Step 1: dar-lhe o ficheiro e o `PLATFORMS_FILE` como aos outros, nunca relaxar a recusa.

- [ ] **Step 6: Commit**

```bash
/usr/bin/git add bin/agentloop install.sh test/e2e.test.sh
/usr/bin/git commit -m "feat(engine): a run, a job and a project may only use what Settings switched on

Launch refuses a platform switched off or planned, and a model nobody
enabled, one line each in tick.log before a slot is spent; set-field,
create and project-set refuse the same at write time; a security block's
switched-off model falls back with a warning. status names enabled,
account and model counts per platform; install.sh says when nothing is
enabled yet. What it cost: a job on the most expensive model in the
catalog was one click away, and a job on a CLI nobody signed in to
found out at its first launch.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

> **Tasks 2–4 entregues** (006c03f..c99a90c, 47a5655..0d176de, a46c4e3..7a41f6b). O que as revisões mudaram e as tarefas seguintes herdam: `run_job` lança `"$cli_bin"` resolvido depois da porta de prontidão; `platform_check` exige `-f && -x`; `cmd_platform models openai` repõe o catálogo anterior quando o refresh falha (`stale:true`); `set-models` deduplica, recusa stdin vazio e guarda caminhos absolutos; `test/fake-codex` aceita `FAKE_CODEX_MODELS_JSON`; a porta "no model enabled" corre antes das sondas ao CLI; `cmd_create` verifica `platform_usable` antes de `openai_catalog_ensure`. Selftest 712, e2e 99.

### Task 5: Sai o `claude_config_dir` por projecto e por bloco de segurança

**Files:**
- Modify: `bin/agentloop` (`run_job`; `security_derived_jobs`; `cmd_project_set`; nova `legacy_config_dir_warning`; `cmd_status`; `cmd_install`; `cmd_selftest` — o bloco `claude_config_dir — an analysis signs in as the account its security block names`)
- Modify: `bin/dashboard.html` (markup e JS de `pj-ccd` e `sec-cfgdir`)
- Modify: `tests/test_page_contract.py`

**Interfaces:**
- Consumes: `installed_config_dir`, `write_projects`, `security_job_id`, `PROJECTS_FILE`.
- Produces: `legacy_config_dir_warning` (uma linha `WARNING: projects.json: claude_config_dir on <Project> is ignored since this version — the account is the platform's, see Settings` por projecto ou bloco que ainda traga o campo); `cmd_project_set` imprime `note: claude_config_dir is ignored since this version — the account is the platform's, see Settings` e grava o projecto sem o campo (nos dois níveis); o job derivado deixa de carregar `claude_config_dir`; `run_job` só conhece o pin da instalação (a variável exportada no arranque). O que fica: `AGENTLOOP_CLAUDE_CONFIG_DIR` no install e o cenário e2e 25, intactos.

- [ ] **Step 1: Substituir o bloco de selftest (as asserções novas falham)**

Substituir todo o bloco que começa em `  echo "claude_config_dir — an analysis signs in as the account its security block names"` e acaba na linha `  esac` a seguir a `bad "run_job no longer resolves claude_config_dir through resolve() — a derived job's value is inert again" ;;` por:

```bash
  echo "claude_config_dir — no longer a project's or a block's to set: ignored, and said"
  local ccd="$tmp/ccd" ccdjid ccdbody
  mkdir -p "$ccd/cfg" "$ccd/data" "$ccd/proj-account" "$ccd/sec-account"
  cat > "$ccd/cfg/projects.json" <<JSON
{"projects":[{"name":"Ccd App","cwd":"$ccd","claude_config_dir":"$ccd/proj-account",
              "security":{"enabled":true,"model":"claude-opus-5","claude_config_dir":"$ccd/sec-account"}}]}
JSON
  cat > "$ccd/cfg/jobs.json" <<JSON
{"jobs":[{"id":"ccd-plain","project":"Ccd App","prompt":"x","enabled":false}]}
JSON
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]}}}\n' > "$ccd/cfg/platforms.json"
  ccd_env() {
    PROJECTS_FILE="$ccd/cfg/projects.json"; JOBS_FILE="$ccd/cfg/jobs.json"; PLATFORMS_FILE="$ccd/cfg/platforms.json"
    DATA_DIR="$ccd/data"
  }
  ccdjid="$(security_job_id "Ccd App")"
  [ -z "$( ( ccd_env; job_get "$ccdjid" '.claude_config_dir' '' ) )" ] \
    && ok "the derived security job no longer carries the block's claude_config_dir" \
    || bad "derived job carries '$( ( ccd_env; job_get "$ccdjid" '.claude_config_dir' '' ) )'"
  ccdbody="$(sed -n '/^run_job() { # run_job <id>/,/^}/p' "$BIN_DIR/agentloop")"
  case "$ccdbody" in
    *'resolve "$id" claude_config_dir'*) bad "run_job still resolves claude_config_dir from the job or the project" ;;
    *) ok "run_job no longer reads a per-project account: the install's pin is the only one" ;;
  esac
  got="$( ( ccd_env; legacy_config_dir_warning ) )"
  case "$got" in
    *"WARNING: projects.json: claude_config_dir on Ccd App is ignored since this version — the account is the platform's, see Settings"*)
      ok "status and install warn about a projects.json that still carries the field" ;;
    *) bad "warning: '$got'" ;;
  esac
  got="$( printf '{"name":"Ccd App","claude_config_dir":"/x","security":{"enabled":true,"claude_config_dir":"/y"}}' | ( ccd_env; cmd_project_set ) 2>&1 )"
  case "$got" in *"note: claude_config_dir is ignored since this version"*) ok "project-set drops the field and says so" ;; *) bad "project-set: $got" ;; esac
  "$JQ" -e '.projects[0] | (has("claude_config_dir") | not) and ((.security | has("claude_config_dir")) | not)' "$ccd/cfg/projects.json" >/dev/null 2>&1 \
    && ok "and the saved project carries the field at neither level" || bad "saved: $("$JQ" -c '.projects[0]' "$ccd/cfg/projects.json")"
```

- [ ] **Step 2: Correr e ver falhar**

```bash
bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed"
```
Esperado: `FAIL  derived job carries '…/sec-account'`, `FAIL  run_job still resolves…`, `FAIL  warning: ''` e `FAIL  project-set: …`.

- [ ] **Step 3: Implementar no engine**

(a) `security_derived_jobs`: apagar a linha `      --arg cfgdir "$(security_get "$project" '.claude_config_dir' '')" \` e a linha `       + (if $cfgdir == "" then {} else {claude_config_dir:$cfgdir} end)' 2>/dev/null)" || elem=""` passa a `       ' 2>/dev/null)" || elem=""` (ou seja, a expressão jq termina na linha do `daily`). Apagar também o parágrafo de comentário acima de `run_cfgdir=` em `run_job` que explica o valor do job derivado.

(b) `run_job`: substituir as três linhas

```bash
  run_cfgdir="$(resolve "$id" claude_config_dir '')"
  case "$run_cfgdir" in null) run_cfgdir="" ;; esac
  run_cfgdir="$(expand_home "$run_cfgdir")"
```
por
```bash
  # Which account this run signs in as: the install's pin, exported as
  # CLAUDE_CONFIG_DIR at load time, and nothing else -- a project's or a
  # security block's own claude_config_dir was removed in this version; the
  # account is the platform's, shown in Settings. Empty here: the two readers
  # below (the precheck's env, run_env) then leave the exported variable alone.
  run_cfgdir=""
```
e apagar o guard `[ -z "$run_cfgdir" ] || [ -d "$run_cfgdir" ] || { log_tick "$id: claude_config_dir missing ($run_cfgdir), skipped"; return 1; }` com o seu comentário.

(c) Nova função, logo a seguir a `legacy_scripts_warnings()`:

```bash
legacy_config_dir_warning() { # one line per project or security block still naming an account: the field is ignored since this version
  [ -f "$PROJECTS_FILE" ] || return 0
  "$JQ" -r '
    .projects[]? | select(type == "object")
    | (.claude_config_dir // "") as $a | (((.security | objects) // {}).claude_config_dir // "") as $b
    | select($a != "" or $b != "") | .name' "$PROJECTS_FILE" 2>/dev/null \
  | while IFS= read -r n; do
      printf "WARNING: projects.json: claude_config_dir on %s is ignored since this version — the account is the platform's, see Settings\n" "$n"
    done
}
```
Chamá-la no fim de `cmd_status` (a seguir a `statusline_path_warning`) e no fim de `cmd_install` (antes do `echo` final que diz que os agentes ficaram instalados).

(d) `cmd_project_set`: logo depois da validação do bloco de segurança (Task 4, alínea (e)) e antes do `if projects_json | "$JQ" -e --arg n "$name" …`:

```bash
  # The account is the platform's now (see Settings): a claude_config_dir sent
  # at either level is dropped from the partial AND from the stored project, and said.
  if echo "$partial" | "$JQ" -e '((.claude_config_dir // "") != "") or ((((.security | objects) // {}).claude_config_dir // "") != "")' >/dev/null 2>&1; then
    echo "note: claude_config_dir is ignored since this version — the account is the platform's, see Settings"
  fi
  partial="$(echo "$partial" | "$JQ" -c 'del(.claude_config_dir) | if (.security | type) == "object" then .security |= del(.claude_config_dir) else . end')"
```
e no ramo de merge de um projecto existente, o filtro passa a
```bash
      '.projects = [.projects[] | if .name==$n then ((. * $p) | del(.claude_config_dir) | if (.security | type) == "object" then .security |= del(.claude_config_dir) else . end) else . end]'
```

- [ ] **Step 4: Correr e ver passar**

```bash
bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed"
```
Esperado: `0 failed`.

- [ ] **Step 5: A página e o seu contrato**

(a) `bin/dashboard.html`: apagar o grupo de markup do campo `pj-ccd` (o `<label>`, o `<input id="pj-ccd" …>` e o `<p class="fieldhelp">` que o segue — `grep -n pj-ccd`), e o grupo de `sec-cfgdir`; apagar `$("pj-ccd").value=(p&&p.claude_config_dir)||"";`, `$("sec-cfgdir").value = sec.claude_config_dir||"";`, as linhas `proj.claude_config_dir=$("pj-ccd").value.trim();` com o seu comentário (o comentário de `proj.platform` que diz "Always sent, like claude_config_dir" passa a "Always sent: project-set merges, and a project going back to Anthropic has to be able to say so."), e a linha `claude_config_dir: $("sec-cfgdir").value.trim(),` do bloco `proj.security`.

(b) `tests/test_page_contract.py`: no harness `_run_save` retirar `"pj-ccd":""` e `"sec-cfgdir":""` de `vals`; em `test_the_project_editor_has_a_security_pane` retirar `"sec-cfgdir"` da lista; na asserção `set(sec) == {…}` retirar `"claude_config_dir"`; a mensagem `"the project's platform is always sent, like claude_config_dir"` passa a `"the project's platform is always sent"`. Acrescentar:

```python
def test_the_project_editor_no_longer_offers_an_account_of_its_own(srv):
    """The account is the platform's, shown in Settings › Platforms; a per-project
    or per-block claude_config_dir was removed with the Settings page."""
    page = srv.render_page("boot-authed")
    assert 'id="pj-ccd"' not in page
    assert 'id="sec-cfgdir"' not in page
    assert "claude_config_dir" not in _js(srv)
```

- [ ] **Step 6: Correr o contrato da página**

```bash
python3.13 -m pytest tests/test_page_contract.py -p no:cacheprovider -q -k "project_editor or account or security_pane or run_save"
```
Esperado: tudo verde.

- [ ] **Step 7: Commit**

```bash
/usr/bin/git add bin/agentloop bin/dashboard.html tests/test_page_contract.py
/usr/bin/git commit -m "feat: the account is the platform's -- the per-project claude_config_dir goes

A project and a security block no longer choose a Claude account of their
own; the install's pin is the only one, and the Anthropic card in Settings
shows whom it is signed in as. A projects.json still carrying the field is
warned about by status and install, and cleaned by the next save.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 6: Servidor — `/api/models` com o registo, `platform_action`, `config_sig`

**Files:**
- Modify: `bin/agentloop-server` (globais junto a `PROJECTS_FILE =`; funções novas antes de `list_models`; `list_models`; `do_POST`; `config_sig`)
- Modify: `tests/test_platforms_api.py`

**Interfaces:**
- Consumes: `al(args, stdin=None)`, `_env`, `read_json`, `_job_platform`, `PLATFORM_PERMISSIONS`, `ANTHROPIC_EFFORTS`, `_openai_platform`.
- Produces (módulo `al_server`): `PLATFORMS_FILE`; `PLATFORM_REGISTRY = ("anthropic", "openai", "opencode")`; `PLATFORMS_PLANNED = ("opencode",)`; `platforms_config() -> (dict, error)`; `platform_bin(p, entry) -> (path, source)`; `jobs_using(p, jobs, projects) -> {model: n}`; `platform_entry(p, cfg, jobs, projects) -> dict` com `supported, enabled, usable, bin, bin_source, bin_found, models_enabled, jobs_on_platform, jobs_using`; `list_models()` com as chaves de hoje mais, por plataforma, as de `platform_entry`, a entrada `opencode`, `catalog_at` no Anthropic, e no topo `configured` e `error`; `platform_action(op, body) -> (code, payload)` para as seis ops; `config_sig` inclui `platforms.json`.

- [ ] **Step 1: Escrever os testes (falham)**

Acrescentar a `tests/test_platforms_api.py`:

```python
def _write_platforms(srv, platforms):
    srv.PLATFORMS_FILE.write_text(json.dumps({"platforms": platforms}))


@pytest.fixture(autouse=True)
def _isolated_registry(srv, tmp_path, monkeypatch):
    """Every test in this file reads a platforms file of its own (missing until
    the test writes one: list_models then reads nothing enabled), and the
    engine behind al() -- the seed, `platform check` -- only ever sees the
    stand-in CLIs, never the operator's."""
    monkeypatch.setattr(srv, "PLATFORMS_FILE", tmp_path / "platforms.json")
    monkeypatch.setenv("AGENTLOOP_CLAUDE_BIN", str(REPO / "test" / "fake-claude"))
    monkeypatch.setenv("AGENTLOOP_CODEX_BIN", str(FAKE_CODEX))
    monkeypatch.setenv("AGENTLOOP_OPENCODE_BIN", "/nonexistent/opencode")
    monkeypatch.setenv("CODEX_HOME", str(tmp_path / "codex-home"))
    monkeypatch.setenv("AGENTLOOP_CLAUDE_CONFIG_DIR", "")


def test_the_registry_rides_on_api_models(srv, tmp_path, monkeypatch):
    monkeypatch.setattr(srv, "JOBS_FILE", tmp_path / "jobs.json")
    monkeypatch.setattr(srv, "PROJECTS_FILE", tmp_path / "projects.json")
    _write_models(srv, openai=_catalog_block())
    srv.JOBS_FILE.write_text(json.dumps({"jobs": [
        {"id": "a", "model": "claude-opus-5"},
        {"id": "b", "model": "claude-opus-5"},
        {"id": "off", "enabled": False, "model": "claude-sonnet-5"},
        {"id": "o", "platform": "openai", "model": "gpt-5.6-luna"}]}))
    srv.PROJECTS_FILE.write_text(json.dumps({"projects": [
        {"name": "P", "security": {"enabled": True, "model": "claude-fable-5-1"}}]}))
    _write_platforms(srv, {
        "anthropic": {"enabled": True, "bin": "", "models": ["claude-opus-5", "claude-fable-5-1"]},
        "openai": {"enabled": True, "bin": "", "models": []},
        "opencode": {"enabled": False, "bin": "", "models": []}})
    out = srv.list_models()
    p = out["platforms"]
    assert set(p) == {"anthropic", "openai", "opencode"}
    a, o, c = p["anthropic"], p["openai"], p["opencode"]
    assert a["supported"] is True and a["enabled"] is True and a["usable"] is True
    assert a["models_enabled"] == ["claude-opus-5", "claude-fable-5-1"]
    assert a["jobs_using"] == {"claude-opus-5": 2, "claude-fable-5-1": 1} and a["jobs_on_platform"] == 3
    assert o["enabled"] is True and o["usable"] is False, "enabled with no model is not usable"
    assert o["jobs_using"] == {"gpt-5.6-luna": 1}
    assert c["supported"] is False and c["usable"] is False and c["available"] is False
    assert c["reason"] == "runs on OpenCode arrive with the OpenCode engine"
    assert out["configured"] is True and out["error"] == ""
    assert a["bin_source"] == "env" and a["bin"].endswith("test/fake-claude")
    # the keys the page reads today are still there, unchanged in shape
    assert out["models"] == a["models"] and isinstance(a["models"][0], str)
    assert a["catalog_at"] == 1788585387


def test_nothing_usable_reads_as_not_configured_and_an_unreadable_file_says_why(srv):
    _write_platforms(srv, {"anthropic": {"enabled": False, "bin": "", "models": []}})
    assert srv.list_models()["configured"] is False
    srv.PLATFORMS_FILE.write_text("{oops")
    out = srv.list_models()
    assert out["configured"] is False
    assert out["error"].endswith("is not a valid platforms file (not JSON, or no .platforms object) — no platform is enabled until it is fixed")
    srv.PLATFORMS_FILE.write_text(json.dumps({"platform": {"anthropic": {"enabled": True}}}))   # a typo by hand: no .platforms object
    assert srv.list_models()["error"].endswith("no platform is enabled until it is fixed")
    assert out["platforms"]["anthropic"]["enabled"] is False


def test_a_missing_platforms_file_is_seeded_by_the_engine(srv, tmp_path, monkeypatch):
    """The server never invents the seed: it asks the engine once (`agentloop
    platforms` runs platforms_ensure) and reads what it wrote."""
    cfg = tmp_path / "config"; cfg.mkdir()
    monkeypatch.setattr(srv, "PLATFORMS_FILE", cfg / "platforms.json")
    monkeypatch.setenv("AGENTLOOP_CONFIG", str(cfg))
    (cfg / "jobs.json").write_text(json.dumps({"jobs": [{"id": "a", "model": "claude-opus-5"}]}))
    cfg_, err = srv.platforms_config()
    assert err == "" and (cfg / "platforms.json").exists()
    assert cfg_["anthropic"]["enabled"] is True and cfg_["anthropic"]["models"] == ["claude-opus-5"]


def test_the_bin_precedence_matches_the_engine(srv, tmp_path, monkeypatch):
    """env override, then the file's bin, then detection -- pinned to
    `agentloop platform check`, which is what a launch actually obeys."""
    cfg = tmp_path / "config"; cfg.mkdir()
    fake = tmp_path / "mycodex"; fake.write_text("#!/bin/sh\necho codex-cli 1.0\n"); fake.chmod(0o755)
    env = dict(os.environ, AGENTLOOP_CONFIG=str(cfg), AGENTLOOP_DATA=str(tmp_path / "data"),
               AGENTLOOP_CLAUDE_BIN=str(REPO / "test" / "fake-claude"), AGENTLOOP_CLAUDE_CONFIG_DIR="",
               CODEX_HOME=str(tmp_path / "codex-home"))
    env.pop("AGENTLOOP_CODEX_BIN", None)

    def engine_bin():
        out = subprocess.run(["/bin/bash", str(ENGINE), "platform", "check", "openai"],
                             capture_output=True, text=True, env=env, check=True).stdout
        j = json.loads(out)
        return j["bin"], j["bin_source"]

    monkeypatch.setattr(srv, "PLATFORMS_FILE", cfg / "platforms.json")
    monkeypatch.delenv("AGENTLOOP_CODEX_BIN", raising=False)
    (cfg / "platforms.json").write_text(json.dumps({"platforms": {"openai": {"enabled": True, "bin": str(fake), "models": []}}}))
    assert srv.platform_bin("openai", {"bin": str(fake)}) == (str(fake), "file") == engine_bin()
    (cfg / "platforms.json").write_text(json.dumps({"platforms": {"openai": {"enabled": True, "bin": "", "models": []}}}))
    assert srv.platform_bin("openai", {"bin": ""}) == engine_bin()
    assert srv.platform_bin("openai", {"bin": ""})[1] == "auto"
    env["AGENTLOOP_CODEX_BIN"] = str(fake)
    monkeypatch.setenv("AGENTLOOP_CODEX_BIN", str(fake))
    assert srv.platform_bin("openai", {"bin": "/elsewhere"}) == (str(fake), "env") == engine_bin()


def test_platform_actions_call_the_engine_and_relay_what_it_says(srv, monkeypatch):
    seen = []

    def fake(args, stdin=None):
        seen.append((args, stdin))
        if args[1] == "check":
            return True, '{"platform":"openai","ready":true}'
        if args[1] == "models":
            return True, '{"platform":"openai","stale":false,"models":[]}'
        if args[1] == "enable":
            return False, "cannot enable openai: codex is not signed in (run: codex login)"
        return True, "openai disabled\n1 enabled job (o) runs on openai and will be skipped until it is enabled again"
    monkeypatch.setattr(srv, "al", fake)
    assert srv.platform_action("platform_check", {"platform": "openai"}) == (200, {"ok": True, "check": {"platform": "openai", "ready": True}})
    assert srv.platform_action("platform_models", {"platform": "openai"})[1]["catalog"]["models"] == []
    code, payload = srv.platform_action("platform_enable", {"platform": "openai"})
    assert code == 500 and payload["ok"] is False and "codex is not signed in" in payload["output"]
    code, payload = srv.platform_action("platform_disable", {"platform": "openai"})
    assert code == 200 and "will be skipped" in payload["output"]
    srv.platform_action("platform_set_bin", {"platform": "openai", "bin": "/opt/x/codex"})
    srv.platform_action("platform_set_models", {"platform": "openai", "models": ["gpt-5.6-luna"]})
    assert [a for a, _ in seen] == [["platform", "check", "openai"], ["platform", "models", "openai"],
                                    ["platform", "enable", "openai"], ["platform", "disable", "openai"],
                                    ["platform", "set-bin", "openai", "/opt/x/codex"],
                                    ["platform", "set-models", "openai"]]
    assert json.loads(seen[-1][1]) == ["gpt-5.6-luna"]
    assert srv.platform_action("platform_check", {"platform": "martian"})[0] == 400
    assert srv.platform_action("platform_set_models", {"platform": "openai", "models": "gpt"})[0] == 400


def test_config_sig_moves_when_platforms_json_does(srv, tmp_path, monkeypatch):
    monkeypatch.setattr(srv, "PLATFORMS_FILE", tmp_path / "platforms.json")
    before = srv.config_sig()
    _write_platforms(srv, {"anthropic": {"enabled": True, "bin": "", "models": ["claude-opus-5"]}})
    assert srv.config_sig() != before
```
Acrescentar `import subprocess` e `import os` ao topo do ficheiro se ainda faltarem. Em `test_platforms_carry_the_catalog_visible_models_in_priority_order`: `assert set(p) == {"anthropic", "openai", "opencode"}`; escrever, antes de `p = srv.list_models()["platforms"]`, `_write_platforms(srv, {"anthropic": {"enabled": True, "bin": "", "models": ["claude-opus-5"]}, "openai": {"enabled": True, "bin": "", "models": ["gpt-5.6-sol"]}})`; e as duas asserções de `default_model` passam a `a["default_model"] == "claude-opus-5"` e `o["default_model"] == "gpt-5.6-sol"` — o default é agora o primeiro modelo activado (Task 4), não `opus` nem o primeiro slug visível. `test_an_unavailable_catalog_says_why` fica como está: sem ficheiro, nada está activado e `default_model` é `""`.

- [ ] **Step 2: Correr e ver falhar**

```bash
python3.13 -m pytest tests/test_platforms_api.py -p no:cacheprovider -q
```
Esperado: `AttributeError: … has no attribute 'PLATFORMS_FILE'` nos testes novos.

- [ ] **Step 3: Implementar**

(a) Junto a `PROJECTS_FILE = CONFIG_DIR / "projects.json"`:

```python
PLATFORMS_FILE = CONFIG_DIR / "platforms.json"
# The registry the page draws: the two platforms that run, and the one that is
# listed and detected but not launched yet. Mirrors PLATFORMS/PLATFORMS_PLANNED
# in the engine; tests/test_platforms_api.py pins the two together through
# `agentloop platforms`.
PLATFORM_REGISTRY = ("anthropic", "openai", "opencode")
PLATFORMS_PLANNED = ("opencode",)
PLATFORM_BIN_ENV = {"anthropic": "CLAUDE_BIN", "openai": "CODEX_BIN", "opencode": "OPENCODE_BIN"}
```

(b) Antes de `def list_models():`:

```python
def platforms_config():
    """config/platforms.json as (platforms dict, error sentence).

    The server never invents the seed: a missing file is written by the engine
    (`agentloop platforms` runs platforms_ensure) and read back. An unreadable
    file reads as nothing enabled, with the engine's own sentence as `error`.
    """
    if not PLATFORMS_FILE.exists():
        al(["platforms"])
    try:
        text = PLATFORMS_FILE.read_text()
    except OSError:
        return {}, ""
    bad = f"{PLATFORMS_FILE} is not a valid platforms file (not JSON, or no .platforms object) — no platform is enabled until it is fixed"
    try:
        data = json.loads(text)
    except ValueError:
        return {}, bad
    p = data.get("platforms") if isinstance(data, dict) else None
    if not isinstance(p, dict):
        return {}, bad                     # the engine's platforms_valid, mirrored
    return p, ""


def _bin_detect(p):
    """The engine's detection, mirrored: platform_bin's last resort."""
    home = Path.home()
    if p == "anthropic":
        local = home / ".local/bin/claude"
        if os.access(local, os.X_OK):
            return str(local)
        return shutil.which("claude") or str(local)
    if p == "openai":
        return shutil.which("codex") or "/opt/homebrew/bin/codex"
    found = shutil.which("opencode")
    if found:
        return found
    alt = home / ".opencode/bin/opencode"
    return str(alt) if os.access(alt, os.X_OK) else "/opt/homebrew/bin/opencode"


def platform_bin(p, entry):
    """(path, source): the environment override, else the file's bin, else detection --
    exactly platform_bin/platform_bin_source in the engine."""
    env = _env(PLATFORM_BIN_ENV[p]) or ""
    if env:
        return os.path.expanduser(env), "env"
    file_bin = (entry or {}).get("bin")
    if isinstance(file_bin, str) and file_bin:
        return os.path.expanduser(file_bin), "file"
    return _bin_detect(p), "auto"


def jobs_using(p, jobs, projects):
    """{model id: n} over the enabled jobs and enabled security blocks whose
    effective platform is `p` -- the engine's `uses` (PLATFORMS_JQ), in python."""
    try:
        resolved = (json.loads((CONFIG_DIR / "models.json").read_text()) or {}).get("resolved") or {}
    except Exception:  # noqa: BLE001
        resolved = {}
    if not isinstance(resolved, dict):
        resolved = {}

    def rid(m):
        r = resolved.get(m)
        return (r.get("id") or m) if isinstance(r, dict) else m
    by_name = {e.get("name"): e for e in projects if isinstance(e, dict)}
    out = {}
    for j in jobs:
        if not isinstance(j, dict) or j.get("enabled") is False or _job_platform(j, projects) != p:
            continue
        proj = by_name.get(j.get("project") or "") or {}
        m = j.get("model") or proj.get("model") or ""
        if m:
            out[rid(m)] = out.get(rid(m), 0) + 1
    for e in projects:
        sec = e.get("security") if isinstance(e, dict) else None
        if not isinstance(sec, dict) or sec.get("enabled") not in (True, "true"):
            continue
        sp = sec.get("platform") or e.get("platform") or "anthropic"
        if (sp if sp in PLATFORM_PERMISSIONS else "anthropic") != p:
            continue
        m = sec.get("model") or ""
        if m:
            out[rid(m)] = out.get(rid(m), 0) + 1
    return out


def platform_entry(p, cfg, jobs, projects):
    """What Settings switched on for one platform, as /api/models carries it."""
    entry = cfg.get(p) if isinstance(cfg.get(p), dict) else {}
    enabled = entry.get("enabled") is True
    models = [m for m in (entry.get("models") or []) if isinstance(m, str) and m]
    b, src = platform_bin(p, entry)
    using = jobs_using(p, jobs, projects)
    return {"supported": p not in PLATFORMS_PLANNED, "enabled": enabled,
            "usable": enabled and bool(models), "bin": b, "bin_source": src,
            "bin_found": os.access(b, os.X_OK), "models_enabled": models,
            "jobs_on_platform": sum(using.values()), "jobs_using": using}
```

(c) Em `list_models()`: logo no início, `cfg, err = platforms_config()`; depois de `ids -= {f[0] for f in MODEL_FAMILIES}`, ler `jobs = read_json(JOBS_FILE, {}).get("jobs", [])` e `projects = read_json(PROJECTS_FILE, {}).get("projects", [])` (uma leitura, reutilizada pelo `for j in …` já existente acima — mover essa leitura para cima e usar as duas variáveis), e substituir o `return` final por:

```python
    anthropic = {"available": True, "reason": "", "models": models,
                 "efforts": list(ANTHROPIC_EFFORTS),
                 "permissions": PLATFORM_PERMISSIONS["anthropic"],
                 "default_model": (cfg.get("anthropic") or {}).get("models", [""])[0] if (cfg.get("anthropic") or {}).get("models") else "",
                 "catalog_at": max([int(r.get("at") or 0) for r in resolved.values() if isinstance(r, dict)] or [0])}
    anthropic.update(platform_entry("anthropic", cfg, jobs, projects))
    openai = _openai_platform()
    openai.update(platform_entry("openai", cfg, jobs, projects))
    openai["default_model"] = (cfg.get("openai") or {}).get("models", [""])[0] if (cfg.get("openai") or {}).get("models") else ""
    opencode = {"available": False, "reason": "runs on OpenCode arrive with the OpenCode engine",
                "models": [], "efforts": [], "permissions": [], "default_model": "", "catalog_at": 0}
    opencode.update(platform_entry("opencode", cfg, jobs, projects))
    platforms = {"anthropic": anthropic, "openai": openai, "opencode": opencode}
    return {"models": models, "efforts": list(ANTHROPIC_EFFORTS), "platforms": platforms,
            "configured": any(v["usable"] for v in platforms.values()), "error": err}
```
`default_model` passa a ser o primeiro modelo activado — o que `platform_default_model` responde agora no engine (Task 4) — em vez do `opus` fixo e do primeiro slug visível.

(d) A acção, como função de módulo antes da classe do handler:

```python
def platform_action(op, body):
    """The six Settings ops, each one `agentloop platform <verb> <platform>` -- the
    engine validates and refuses; this only shapes the request and relays the answer."""
    platform = str(body.get("platform", "") or "").strip()
    if platform not in PLATFORM_REGISTRY:
        return 400, {"error": "unknown platform"}
    verb = op[len("platform_"):].replace("_", "-")     # check enable disable set-bin models set-models
    args = ["platform", verb, platform]
    stdin = None
    if op == "platform_set_bin":
        args.append(str(body.get("bin", "") or ""))
    elif op == "platform_set_models":
        models = body.get("models")
        if not isinstance(models, list) or not all(isinstance(m, str) for m in models):
            return 400, {"error": "models must be a list of ids"}
        stdin = json.dumps(models)
    ok, out = al(args, stdin=stdin)
    if ok and op in ("platform_check", "platform_models"):
        try:
            payload = json.loads(out)
        except ValueError:
            return 500, {"ok": False, "output": out}
        return 200, {"ok": True, ("check" if op == "platform_check" else "catalog"): payload}
    return (200 if ok else 500), {"ok": ok, "output": out}
```
E em `do_POST`, atrás da gate (a seguir ao bloco `if op == "prefs_set":`):

```python
        if op in ("platform_check", "platform_enable", "platform_disable",
                  "platform_set_bin", "platform_models", "platform_set_models"):
            code, payload = platform_action(op, body)
            return self._send(code, payload)
```

(e) `config_sig`: `for p in (JOBS_FILE, PROJECTS_FILE, PLATFORMS_FILE):`.

- [ ] **Step 4: Correr e ver passar**

```bash
python3.13 -m pytest tests/test_platforms_api.py tests/test_page_contract.py -p no:cacheprovider -q
```
Esperado: tudo verde. Se `test_page_contract.py` tiver um teste que fixe `default_model == "opus"` de `/api/models`, actualizá-lo para o primeiro activado do fixture desse teste.

- [ ] **Step 5: Commit**

```bash
/usr/bin/git add bin/agentloop-server tests/test_platforms_api.py
/usr/bin/git commit -m "feat(server): /api/models carries what Settings switched on; the six platform actions

Each platform now says enabled, usable, where its binary is and by which
rule, the models switched on and the jobs using them; the page reads
configured and error at the top. No probe runs inside /api/models -- the
file is read, and the engine seeds it when missing. platform_action shapes
the six ops into agentloop platform commands and relays the refusal.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 7: UI — os helpers de domínio (`editor-domain.js`, `jobs-domain.js`) e os chips

**Files:**
- Modify: `ui/app/editor-domain.js`, `ui/app/jobs-domain.js`, `ui/app/overview.js`, `ui/app/jobs-table.js`, `ui/app/index.js`
- Modify: `bin/dashboard.html` (só o objecto passado a `ALApp.init(...)`: ganha `get PLATFORMS(){ return PLATFORMS; }`)
- Modify: `tests/test_page_contract.py`
- Build: `bash build/build-ui.sh` → `bin/static/app.js` (commitado)

**Interfaces:**
- Consumes: `platformOf`, `eff`, `projById`, `AL`, `el`, `icon`; o `PLATFORMS` da página (o `platforms` de `/api/models`, com as chaves da Task 6).
- Produces (exportadas em `window.ALApp`): `PLATFORM_LABELS`; `registryKnown(platforms)`; `platformOptions(platforms, current)` → `[{v,label[,flagged]}]`; `modelOptionsFor(platform, platforms, groupFn, current)` (filtrado por `models_enabled`; o valor actual fora da lista entra no fim marcado `(disabled in Settings)`); `hiddenModelCount(platform, platforms)`; `platformState(job, project, platforms)` → `"ok"|"planned"|"platform_disabled"|"model_disabled"`; `platformChip(state)` → elemento `.pill.idle` ou `null`. O cartão (`jobCard`) e a linha (`jobRow`) mostram o chip a seguir ao pill de estado.

- [ ] **Step 1: Escrever os testes de contrato (falham)**

Acrescentar a `tests/test_page_contract.py`:

```python
@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_platform_options_offer_only_what_settings_switched_on(srv, tmp_path):
    """Until /api/models answers with the registry, both platforms (the page as
    it was); once it does, only the usable ones -- and the job's current one
    flagged rather than silently swapped."""
    js = _app_js(srv)
    deps = "\n".join(_plainfn(js, n) for n in ("registryKnown", "platformOptions"))
    script = tmp_path / "platform-options.js"
    script.write_text("""
    const PLATFORM_LABELS = {anthropic: "Anthropic", openai: "OpenAI", opencode: "OpenCode"};
    """ + deps + """
    const before = platformOptions({}, "anthropic");
    const p = {anthropic: {enabled: true, usable: true}, openai: {enabled: true, usable: false}};
    const after = platformOptions(p, "anthropic");
    const flagged = platformOptions(p, "openai");
    console.log(JSON.stringify({before, after, flagged}));
    """)
    out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
    assert [o["v"] for o in out["before"]] == ["anthropic", "openai"]
    assert [o["v"] for o in out["after"]] == ["anthropic"]
    assert out["flagged"][-1] == {"v": "openai", "label": "OpenAI (disabled in Settings)", "flagged": True}


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_model_options_are_filtered_by_the_enabled_list_and_flag_the_current(srv, tmp_path):
    js = _app_js(srv)
    script = tmp_path / "model-options.js"
    script.write_text(_plainfn(js, "modelOptionsFor") + """
    const P = {anthropic: {models: ["claude-opus-5", "claude-sonnet-5"], models_enabled: ["claude-opus-5"]},
               openai: {models: [{v: "gpt-a", label: "A", desc: "da"}, {v: "gpt-b", label: "B"}], models_enabled: ["gpt-b"]}};
    const a = modelOptionsFor("anthropic", P, null, "claude-sonnet-5");
    const o = modelOptionsFor("openai", P, null, "gpt-b");
    const legacy = modelOptionsFor("anthropic", {anthropic: {models: ["claude-opus-5", "claude-sonnet-5"]}}, null, "");
    console.log(JSON.stringify({a, o, legacy}));
    """)
    out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
    assert out["a"] == [{"v": "claude-opus-5", "label": "claude-opus-5"},
                        {"v": "claude-sonnet-5", "label": "claude-sonnet-5 (disabled in Settings)", "flagged": True}]
    assert out["o"] == [{"v": "gpt-b", "label": "B"}]
    assert [x["v"] for x in out["legacy"]] == ["claude-opus-5", "claude-sonnet-5"], "no models_enabled: nothing is filtered"


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_platform_state_names_a_platform_or_model_switched_off(srv, tmp_path):
    js = _app_js(srv)
    script = tmp_path / "platform-state.js"
    script.write_text("\n".join(_plainfn(js, n) for n in ("platformOf", "platformState")) + """
    function eff(j, f, d){ return (j && j[f] != null && j[f] !== "") ? j[f] : d; }
    const P = {anthropic: {enabled: true, usable: true, models_enabled: ["claude-opus-5"], default_model: "claude-opus-5"},
               openai: {enabled: false, usable: false, models_enabled: []}};
    console.log(JSON.stringify({
      ok: platformState({model: "claude-opus-5"}, null, P),
      fam: platformState({model: "opus"}, null, P),
      model: platformState({model: "claude-sonnet-5"}, null, P),
      plat: platformState({platform: "openai", model: "gpt-a"}, null, P),
      planned: platformState({platform: "opencode"}, null, P),
      blind: platformState({model: "claude-sonnet-5"}, null, {}),
    }));
    """)
    out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
    assert out == {"ok": "ok", "fam": "ok", "model": "model_disabled", "plat": "platform_disabled",
                   "planned": "planned", "blind": "ok"}


def test_the_card_and_the_row_show_the_platform_chip(srv):
    js = _app_js(srv)
    assert "platformChip(platformState(j, projById(j.project || \"\"), AL.PLATFORMS))" in _plainfn(js, "jobCard")
    assert "platformChip(platformState(j, projById(j.project || \"\"), AL.PLATFORMS))" in _plainfn(js, "jobRow")
    for name in ("platformOptions", "registryKnown", "hiddenModelCount", "platformState", "platformChip", "PLATFORM_LABELS"):
        assert name in js.split("window.ALApp = {", 1)[1], f"{name} is not on window.ALApp"
    assert "get PLATFORMS(){ return PLATFORMS; }" in _js(srv)
```

- [ ] **Step 2: Correr e ver falhar**

```bash
python3.13 -m pytest tests/test_page_contract.py -p no:cacheprovider -q -k "platform_options or model_options or platform_state or platform_chip"
```
Esperado: `ValueError: substring not found` (as funções não existem).

- [ ] **Step 3: Implementar**

(a) `ui/app/editor-domain.js` — a seguir a `platformLabel`:

```js
export const PLATFORM_LABELS = {anthropic: "Anthropic", openai: "OpenAI", opencode: "OpenCode"};

// Whether /api/models has told this page what Settings switched on: the
// registry rides on every platform entry as `enabled`. A payload without it
// (or none yet) leaves every editor as it was before Settings existed.
export function registryKnown(platforms){
  const a = platforms && platforms.anthropic;
  return !!(a && a.enabled !== undefined);
}

// The Platform combo's options: the platforms switched on in Settings (both,
// until the registry arrives), plus the job's current one flagged when it is
// not among them -- the editor never rewrites a job on its own.
export function platformOptions(platforms, current){
  const known = ["anthropic", "openai"];
  const have = registryKnown(platforms);
  const out = known.filter(p => !have || ((platforms[p] || {}).usable === true))
                   .map(p => ({v: p, label: PLATFORM_LABELS[p]}));
  if(current && !out.some(o => o.v === current)){
    out.push({v: current, label: (PLATFORM_LABELS[current] || current) + " (disabled in Settings)", flagged: true});
  }
  return out;
}

// How many models the catalog carries that Settings keeps off the list.
export function hiddenModelCount(platform, platforms){
  const key = platform === "openai" ? "openai" : "anthropic";
  const p = (platforms || {})[key];
  if(!p || !Array.isArray(p.models_enabled) || !Array.isArray(p.models)) return 0;
  const ids = p.models.map(m => typeof m === "string" ? m : m.v);
  return ids.filter(v => !p.models_enabled.includes(v)).length;
}
```
E substituir `modelOptionsFor` inteira por:

```js
// The model combo's option list for one platform, filtered by what Settings
// switched on (`models_enabled`; a payload without it filters nothing).
// Anthropic keeps the family/generation grouping the page already draws
// (groupFn is the page's groupModels); OpenAI is flat, in the catalog's own
// order, each slug with its description, a deprecated slug at the end
// pointing at its successor, and " · no price" on a slug config/pricing.json
// does not price. `current` -- the job's own value -- joins the end, flagged,
// when it is no longer on the list: the editor shows the truth, never rewrites.
export function modelOptionsFor(platform, platforms, groupFn, current){
  const key = platform === "openai" ? "openai" : "anthropic";
  const p = (platforms || {})[key];
  const enabledList = (p && Array.isArray(p.models_enabled)) ? p.models_enabled : null;
  const keep = (v) => !enabledList || enabledList.includes(v);
  let opts;
  if(key === "anthropic"){
    const ids = ((p && Array.isArray(p.models)) ? p.models : []).filter(keep);
    opts = groupFn ? groupFn(ids) : ids.map(v => ({v, label: v}));
  }else{
    const list = ((p && Array.isArray(p.models)) ? p.models : []).filter(m => keep(m.v));
    const noPrice = (m) => m.priced === false ? " · no price" : "";
    const live = list.filter(m => !m.deprecated_by).map(m => ({
      v: m.v, label: (m.label || m.v) + (m.desc ? " — " + m.desc : "") + noPrice(m)}));
    const old = list.filter(m => m.deprecated_by).map(m => ({
      v: m.v, label: (m.label || m.v) + " — → " + m.deprecated_by
        + (m.retires_at ? ", retires " + String(m.retires_at).slice(0, 10) : "") + noPrice(m)}));
    opts = live.concat(old);
  }
  if(current && !opts.some(o => !o.sec && o.v === current)){
    opts.push({v: current, label: current + " (disabled in Settings)", flagged: true});
  }
  return opts;
}
```

(b) `ui/app/jobs-domain.js` — acrescentar aos imports `import { platformOf } from "./editor-domain.js";` e `import { el } from "./chrome.js";`, e no fim do ficheiro:

```js
// What Settings says about a job's platform and model, for the chip on its
// card and its row: ok, a planned platform (never runs yet), a platform
// switched off, a model switched off. No verdict until the registry arrives.
export function platformState(j, project, platforms){
  if(j && j.platform === "opencode") return "planned";
  const p = platformOf(j, project);
  const entry = (platforms || {})[p];
  if(!entry || entry.enabled === undefined) return "ok";
  if(!entry.usable) return "platform_disabled";
  const model = eff(j, "model", "") || entry.default_model || "";
  const enabled = entry.models_enabled || [];
  // A family value (opus) is fine when an id of that family is switched on.
  const famOk = /^(opus|sonnet|haiku|fable)$/.test(model) && enabled.some(id => id.startsWith("claude-" + model + "-"));
  if(model && !enabled.includes(model) && !famOk) return "model_disabled";
  return "ok";
}

export function platformChip(st){
  if(st === "ok") return null;
  const c = el("span", "pill idle");
  c.textContent = st === "planned" ? "platform not supported yet"
                : st === "platform_disabled" ? "platform disabled" : "model disabled";
  c.title = st === "planned" ? "This platform arrives with a later release — runs are refused until then"
          : "Switched off in Settings › Platforms — runs are refused until it is switched on again, or the job picks another";
  return c;
}
```

(c) `ui/app/overview.js` — no import de `./jobs-domain.js` acrescentar `platformState, platformChip`; em `jobCard`, logo a seguir a `h2.appendChild(pill);`:

```js
  // A job whose platform or model was switched off in Settings says so on
  // the card, so the refusal in tick.log is not the only place it shows.
  const pchip = platformChip(platformState(j, projById(j.project || ""), AL.PLATFORMS));
  if(pchip) h2.appendChild(pchip);
```

(d) `ui/app/jobs-table.js` — acrescentar `platformState, platformChip` ao import de `./jobs-domain.js` e `projById, AL` ao import de `./page.js` (se ainda não estiverem); em `jobRow`, a seguir ao `if(F.running){ … }else{ … }` que preenche `tdState` e antes de `tr.appendChild(tdState);`:

```js
  const pchip = platformChip(platformState(j, projById(j.project || ""), AL.PLATFORMS));
  if(pchip) tdState.appendChild(pchip);
```

(e) `ui/app/index.js` — acrescentar `PLATFORM_LABELS, registryKnown, platformOptions, hiddenModelCount` ao import de `./editor-domain.js`, `platformState, platformChip` ao de `./jobs-domain.js`, e os seis nomes ao objecto `window.ALApp = { … }` (junto a `modelOptionsFor, platformOf, platformLabel`).

(f) `bin/dashboard.html` — no objecto passado a `ALApp.init({ … })`, a seguir a `get currentView(){ return currentView; }`, acrescentar `get PLATFORMS(){ return PLATFORMS; },` (o `PLATFORMS` é a `let` da página que `loadModels` preenche).

(g) `bash build/build-ui.sh`.

- [ ] **Step 4: Correr e ver passar**

```bash
bash build/build-ui.sh && python3.13 -m pytest tests/test_page_contract.py -p no:cacheprovider -q
```
Esperado: verde. Os testes existentes que chamam `modelOptionsFor` com três argumentos continuam a passar (o quarto é opcional).

- [ ] **Step 5: Commit**

```bash
/usr/bin/git add ui/app tests/test_page_contract.py bin/dashboard.html bin/static/app.js bin/static/app.css bin/static/security.js
/usr/bin/git commit -m "feat(ui): the platform and model lists know what Settings switched on; a chip on a job that lost its own

platformOptions and modelOptionsFor read the registry off /api/models and
offer only what is usable, flagging a job's current value instead of
rewriting it; platformState/platformChip put the same verdict on the card
and the row, so a refused run is not only a line in tick.log.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 8: UI — a página Settings › Platforms (`ui/app/settings.js`, CSS, markup, ligação)

**Files:**
- Create: `ui/app/settings.js`
- Modify: `ui/css/pages.css` (regras novas no fim), `ui/app/index.js`, `bin/dashboard.html` (markup de `#view-settings`; `nav-settings`; `VIEWS`; `setView`; `loadModels`; boot), `tests/test_page_contract.py`
- Build: `bash build/build-ui.sh`

**Interfaces:**
- Consumes: `el`, `pageHeader`, `$`, `icon`, `toast`, `TOKEN` (page.js); as seis acções da Task 6; o `platforms`/`configured`/`error` de `/api/models`.
- Produces (`window.ALApp`): `renderSettingsPage({platforms, configured, error, onChange})` — pinta `#st-head` e `#st-platforms`; `settingsSummary(platforms)` → `"2 of 3 platforms enabled · 5 models available to jobs"`; `platformStatus(entry, check)` → `{cls, label}` com `label` em `Enabled · Disabled · Not installed · Not signed in · Coming soon`; `setupBanner(configured, error)` → elemento ou `null` (usado na Task 9). Na página: `MODELS_CONFIGURED` (`undefined` até `/api/models` responder, depois boolean), `MODELS_ERROR`, `paintSettings()`, o separador Settings visível, `"settings"` em `VIEWS`.

- [ ] **Step 1: Escrever os testes de contrato (falham)**

Acrescentar a `tests/test_page_contract.py`:

```python
def test_the_settings_page_is_reachable_and_has_its_two_panes(srv):
    page = srv.render_page("boot-authed")
    assert '<button class="navitem" data-view="settings" id="nav-settings"></button>' in page, "the Settings item is hidden"
    for part in ("st-head", "st-tabs", "sttab-platforms", "sttab-profile", "st-platforms", "st-profile", "soon-settings"):
        assert f'id="{part}"' in page, f"missing {part}"
    js = _js(srv)
    assert 'const VIEWS = ["overview","jobs","runs","projects","security","settings"];' in js
    assert 'if(currentView === "settings") paintSettings();' in _plainfn(js, "setView")
    assert "MODELS_CONFIGURED=" in _fn(js, "loadModels") and "MODELS_ERROR=" in _fn(js, "loadModels")
    assert "ALApp.renderSettingsPage(" in _plainfn(js, "paintSettings")
    assert "renderSettingsPage" in _app_js(srv).split("window.ALApp = {", 1)[1]


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_the_settings_summary_and_the_status_chip(srv, tmp_path):
    js = _app_js(srv)
    script = tmp_path / "settings-words.js"
    script.write_text("""
    const REGISTRY = [{id: "anthropic"}, {id: "openai"}, {id: "opencode"}];
    """ + "\n".join(_plainfn(js, n) for n in ("settingsSummary", "platformStatus")) + """
    const P = {anthropic: {enabled: true, models_enabled: ["a", "b"]}, openai: {enabled: true, models_enabled: ["c"]}, opencode: {enabled: false, models_enabled: []}};
    console.log(JSON.stringify({
      summary: settingsSummary(P),
      one: settingsSummary({anthropic: {enabled: true, models_enabled: ["a"]}}),
      on: platformStatus({supported: true, enabled: true}, {ready: true, bin_found: true}),
      off: platformStatus({supported: true, enabled: false}, {ready: true, bin_found: true}),
      nobin: platformStatus({supported: true, enabled: false}, {ready: false, bin_found: false}),
      nosession: platformStatus({supported: true, enabled: false}, {ready: false, bin_found: true}),
      planned: platformStatus({supported: false, enabled: false}, {ready: false, bin_found: false}),
      unchecked: platformStatus({supported: true, enabled: true}, null),
    }));
    """)
    out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
    assert out["summary"] == "2 of 3 platforms enabled · 3 models available to jobs"
    assert out["one"] == "1 of 3 platforms enabled · 1 model available to jobs"
    assert [out[k]["label"] for k in ("on", "off", "nobin", "nosession", "planned", "unchecked")] == \
        ["Enabled", "Disabled", "Not installed", "Not signed in", "Coming soon", "Enabled"]
    assert out["nobin"]["cls"] == "off" and out["nosession"]["cls"] == "idle" and out["planned"]["cls"] == "disabled"


def test_the_settings_module_speaks_the_six_actions(srv):
    src = (REPO / "ui" / "app" / "settings.js").read_text()
    for op in ("platform_check", "platform_enable", "platform_disable", "platform_set_bin", "platform_models", "platform_set_models"):
        assert f'"{op}"' in src, f"settings.js never calls {op}"
    assert "Test the session first, then load the models" in src
    assert "no longer in the catalog" in src
```

- [ ] **Step 2: Correr e ver falhar**

```bash
python3.13 -m pytest tests/test_page_contract.py -p no:cacheprovider -q -k "settings"
```
Esperado: os três a falhar (item escondido, ficheiro inexistente).

- [ ] **Step 3: Escrever `ui/app/settings.js`**

```js
/* Settings › Platforms: one card per listed platform -- found, checked,
   enabled -- and the models switched on for it, in the four steps the
   operator described: the binary, the session, the models, the switch.

   Everything drawn here is read off /api/models (the registry -- no probe
   runs there) plus two calls this page makes on demand: platform_check (the
   live session probe, run for every card when the page opens and on Test)
   and platform_models (the catalog, loaded once a check passes and on
   Refresh). Every change saves at once through a platform_* action; the
   page then re-reads /api/models (ctx.onChange, the page's own loadModels)
   and repaints this page from the fresh payload, so a change made by the
   CLI in the meantime shows up too. Live results stay at module level
   across repaints -- they are this page's, not the payload's. */
import { el, pageHeader } from "./chrome.js";
import { $, icon, toast, TOKEN } from "./page.js";

export const REGISTRY = [
  {id: "anthropic", name: "Anthropic", cli: "claude", sub: "Claude Code — claude -p", mark: "A"},
  {id: "openai", name: "OpenAI", cli: "codex", sub: "Codex CLI — codex exec --json", mark: "O"},
  {id: "opencode", name: "OpenCode", cli: "opencode", sub: "opencode run — arrives with the next release", mark: "OC"},
];

const live = {checks: {}, checkedAt: {}, catalogs: {}, busy: {}};
let ctx = null;   // {platforms, configured, error, onChange}

async function post(op, extra){
  const r = await fetch("/api/action", {method: "POST",
    headers: {"Content-Type": "text/plain", "X-AL-Token": TOKEN},
    body: JSON.stringify(Object.assign({op}, extra))});
  const j = await r.json().catch(() => ({}));
  if(!r.ok || j.ok === false){ toast(j.output || j.error || ("HTTP " + r.status), true); return null; }
  return j;
}

export function settingsSummary(platforms){
  const entries = REGISTRY.map(r => (platforms || {})[r.id] || {});
  const enabled = entries.filter(p => p.enabled === true).length;
  const models = entries.reduce((n, p) => n + ((p.models_enabled || []).length), 0);
  return enabled + " of " + REGISTRY.length + " platforms enabled · " + models + " model" + (models === 1 ? "" : "s") + " available to jobs";
}

// The chip's word, from the registry entry and the last live check.
export function platformStatus(entry, check){
  if(entry && entry.supported === false) return {cls: "disabled", label: "Coming soon"};
  if(check && check.bin_found === false) return {cls: "off", label: "Not installed"};
  if(check && check.ready === false) return {cls: "idle", label: "Not signed in"};
  return (entry && entry.enabled) ? {cls: "on", label: "Enabled"} : {cls: "disabled", label: "Disabled"};
}

// The strip Overview and Jobs show while nothing is configured (Task 9 mounts it).
export function setupBanner(configured, error){
  if(configured !== false && !error) return null;
  const b = el("div", "setup-banner");
  const bic = el("div", "bic"); bic.appendChild(icon("alert")); b.appendChild(bic);
  const t = el("div", "btxt");
  t.appendChild(el("b", null, error ? "The platform settings cannot be read." : "No platform is enabled yet."));
  t.appendChild(el("span", null, error ? error
    : "Enable one in Settings › Platforms and switch on at least one model; until then no job can be created. New job takes you there."));
  b.appendChild(t);
  const btn = el("button", "btn primary"); btn.type = "button"; btn.id = "open-settings";
  btn.appendChild(icon("gear")); btn.appendChild(document.createTextNode("Open Settings"));
  b.appendChild(btn);
  return b;
}

function ago(ms){
  if(!ms) return "";
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  return s < 60 ? "checked " + s + " s ago" : "checked " + Math.round(s / 60) + " min ago";
}

function switchEl(on, disabled, title, onToggle){
  const lab = el("label", "switch"); if(title) lab.title = title;
  const inp = el("input"); inp.type = "checkbox"; inp.checked = !!on; inp.disabled = !!disabled;
  inp.addEventListener("change", () => onToggle(inp.checked));
  lab.appendChild(inp); lab.appendChild(el("span", "track")); lab.appendChild(el("span", "knob"));
  return lab;
}

function button(label, iconName, onClick, disabled){
  const b = el("button", "btn"); b.type = "button"; b.disabled = !!disabled;
  if(iconName) b.appendChild(icon(iconName));
  b.appendChild(document.createTextNode(label));
  b.addEventListener("click", onClick);
  return b;
}

async function runCheck(id){
  live.busy[id] = true; paint();
  const j = await post("platform_check", {platform: id});
  if(j && j.check){ live.checks[id] = j.check; live.checkedAt[id] = Date.now(); }
  live.busy[id] = false; paint();
  if(j && j.check && j.check.ready && !live.catalogs[id]) await loadCatalog(id);
}

async function loadCatalog(id){
  live.busy[id] = true; paint();
  const j = await post("platform_models", {platform: id});
  if(j && j.catalog) live.catalogs[id] = j.catalog;
  live.busy[id] = false; paint();
}

async function change(op, extra){
  const j = await post(op, extra);
  if(j && j.output) toast(j.output.split("\n")[0], false, "check");
  if(ctx && ctx.onChange) await ctx.onChange();   // the page re-reads /api/models and repaints this page
}

function binaryBlock(r, entry, check){
  const box = el("div");
  box.appendChild(el("h3", null, "Binary"));
  const val = el("div", "val" + (check ? (check.bin_found ? "" : " err") : " mute"));
  if(check && !check.bin_found){ val.appendChild(icon("xcircle")); val.appendChild(document.createTextNode("Not found on the launchd PATH")); }
  else { const c = el("code", null, (check && check.bin) || entry.bin || "…"); val.appendChild(c); }
  box.appendChild(val);
  const src = {env: "from AGENTLOOP_" + r.cli.toUpperCase() + "_BIN", file: "set here", auto: "found on PATH"}[(check || entry).bin_source] || "";
  const sub = el("div", "sub");
  sub.textContent = check
    ? (check.bin_found ? [src, check.version].filter(Boolean).join(" · ") + " · this is the path launchd sees, the one scheduled runs use"
                       : "looked at " + check.bin + " — type the path if it lives elsewhere, or install it: " + check.reason.split("install: ")[1])
    : "checking…";
  box.appendChild(sub);
  const ctrl = el("div", "ctrl");
  const inp = el("input"); inp.type = "text"; inp.value = entry.bin || ""; inp.placeholder = "Use another binary… (leave empty to detect)";
  inp.disabled = !!live.busy[r.id] || entry.supported === false;
  inp.addEventListener("change", async () => { await change("platform_set_bin", {platform: r.id, bin: inp.value.trim()}); await runCheck(r.id); });
  ctrl.appendChild(inp);
  ctrl.appendChild(button("Detect", "radar", async () => { await change("platform_set_bin", {platform: r.id, bin: ""}); await runCheck(r.id); },
                          live.busy[r.id] || entry.supported === false));
  box.appendChild(ctrl);
  return box;
}

function sessionBlock(r, entry, check){
  const box = el("div");
  box.appendChild(el("h3", null, "Session"));
  const val = el("div", "val" + (check ? (check.ready ? " ok" : (check.bin_found ? " err" : " mute")) : " mute"));
  if(!check){ val.textContent = live.busy[r.id] ? "checking…" : "— not checked"; }
  else if(check.ready){ val.appendChild(icon("check")); val.appendChild(document.createTextNode("Signed in as " + (check.account || "unknown"))); }
  else if(!check.bin_found){ val.textContent = "— waiting for a binary"; }
  else { val.appendChild(icon("xcircle")); val.appendChild(document.createTextNode(check.reason)); }
  box.appendChild(val);
  const sub = el("div", "sub");
  sub.textContent = entry.supported === false
    ? "the session test and the model list arrive with the OpenCode engine"
    : (check ? ago(live.checkedAt[r.id]) + " with " + (r.id === "anthropic" ? "claude auth status" : "codex login status") : "");
  box.appendChild(sub);
  const ctrl = el("div", "ctrl");
  ctrl.appendChild(button("Test", "refresh", () => runCheck(r.id), live.busy[r.id] || entry.supported === false || (check && !check.bin_found)));
  ctrl.appendChild(el("span", "muted", "re-runs the sign-in check and the version probe"));
  box.appendChild(ctrl);
  return box;
}

function modelRow(r, entry, m, using, gone){
  const enabledNow = (entry.models_enabled || []).includes(m.v);
  const row = el("div", "mrow" + (enabledNow ? "" : " offrow"));
  const name = el("div", "mname");
  name.appendChild(el("b", null, m.label || m.v));
  name.appendChild(el("span", null, m.v + (m.desc ? " — " + m.desc : "") + (gone ? " — no longer in the catalog" : "")
    + (m.deprecated_by ? " — deprecated, → " + m.deprecated_by : "")));
  row.appendChild(name);
  const meta = el("div", "mmeta");
  if(m.price) meta.appendChild(el("span", "price", "$" + m.price.input + " / $" + m.price.output));
  else if(r.id === "openai" && !gone) meta.appendChild(el("span", null, "no price"));
  if(m.efforts && m.efforts.length) meta.appendChild(el("span", null, m.efforts[0] + " → " + m.efforts[m.efforts.length - 1]));
  const n = using[m.v] || 0;
  if(n) meta.appendChild(el("span", "jobs", n + " job" + (n === 1 ? "" : "s")));
  row.appendChild(meta);
  row.appendChild(switchEl(enabledNow, live.busy[r.id], n ? n + " enabled job(s) use this model" : "", async (on) => {
    const cur = (entry.models_enabled || []).slice();
    const next = on ? (cur.includes(m.v) ? cur : cur.concat([m.v])) : cur.filter(v => v !== m.v);
    await change("platform_set_models", {platform: r.id, models: next});
  }));
  return row;
}

function modelsSection(r, entry, check, catalog){
  const frag = document.createDocumentFragment();
  const head = el("div", "models-h");
  head.appendChild(el("h3", null, "Models"));
  const age = el("span", "age");
  if(catalog){
    const from = r.id === "openai" ? "from codex debug models" : "from the installed CLI";
    age.textContent = from + (catalog.stale ? " — " + catalog.reason : "") + (r.id === "anthropic" ? " · every Claude model takes effort low → max" : "");
  }else if(entry.supported === false){
    age.textContent = "the providers you sign in to, listed by opencode models";
  }
  head.appendChild(age);
  head.appendChild(el("span", "sp"));
  const ready = !!(check && check.ready);
  head.appendChild(button(catalog ? "Refresh" : "Load models", "refresh", () => loadCatalog(r.id), !ready || live.busy[r.id]));
  frag.appendChild(head);
  if(entry.supported === false){
    frag.appendChild(el("div", "mempty", "Nothing to switch on yet — OpenCode jobs, and this list, come with the next release. The card is here so the binary is found and named before that day."));
    return frag;
  }
  if(!catalog){
    frag.appendChild(el("div", "mempty", ready ? "Loading the models…" : "Test the session first, then load the models."));
    return frag;
  }
  const using = entry.jobs_using || {};
  const seen = new Set();
  catalog.models.forEach(m => { seen.add(m.v); frag.appendChild(modelRow(r, entry, m, using, false)); });
  (entry.models_enabled || []).filter(v => !seen.has(v)).forEach(v => frag.appendChild(modelRow(r, entry, {v, label: v}, using, true)));
  if(!catalog.models.length && !(entry.models_enabled || []).length) frag.appendChild(el("div", "mempty", "The catalog came back empty" + (catalog.reason ? " — " + catalog.reason : "") + "."));
  return frag;
}

function platformCard(r, entry, check, catalog){
  const card = el("section", "platcard"); card.id = "platcard-" + r.id;
  const h = el("div", "platcard-h");
  h.appendChild(el("div", "platcard-ic" + (entry.supported === false ? " off" : ""), r.mark));
  const t = el("div", "platcard-t"); t.appendChild(el("b", null, r.name)); t.appendChild(el("span", null, r.sub)); h.appendChild(t);
  const right = el("div", "platcard-r");
  const st = platformStatus(entry, check);
  const pill = el("span", "pill " + st.cls, st.label); right.appendChild(pill);
  const sw = el("div", "swlabel");
  const row = el("div", "swrow"); row.appendChild(document.createTextNode(entry.enabled ? "Enabled " : "Disabled "));
  const canToggle = entry.supported !== false && !live.busy[r.id] && (entry.enabled || (check && check.ready));
  row.appendChild(switchEl(!!entry.enabled, !canToggle,
    entry.supported === false ? "runs on OpenCode arrive with the next release" : (canToggle ? "" : "unlocks when the session test passes"),
    async (on) => { await change(on ? "platform_enable" : "platform_disable", {platform: r.id}); }));
  sw.appendChild(row);
  const n = entry.jobs_on_platform || 0;
  sw.appendChild(el("span", null, entry.supported === false ? "runs on OpenCode are not supported yet"
    : (n ? n + " enabled job" + (n === 1 ? "" : "s") + " run" + (n === 1 ? "s" : "") + " here" : (entry.enabled ? "jobs may pick this platform" : "unlocks when the session test passes"))));
  right.appendChild(sw); h.appendChild(right); card.appendChild(h);
  const g = el("div", "platcard-g"); g.appendChild(binaryBlock(r, entry, check)); g.appendChild(sessionBlock(r, entry, check)); card.appendChild(g);
  card.appendChild(modelsSection(r, entry, check, catalog));
  return card;
}

function paint(){
  if(!ctx) return;
  const head = $("st-head"), host = $("st-platforms");
  if(!head || !host) return;
  head.textContent = "";
  head.appendChild(pageHeader({icon: "gear", title: "Settings",
    subtitle: "Which agent CLIs this scheduler may run, and which of their models a job may pick."}));
  host.textContent = "";
  if(ctx.error){
    const b = setupBanner(false, ctx.error); if(b) host.appendChild(b);
  }
  host.appendChild(el("div", "summary", settingsSummary(ctx.platforms)));
  REGISTRY.forEach(r => host.appendChild(platformCard(r, (ctx.platforms || {})[r.id] || {}, live.checks[r.id] || null, live.catalogs[r.id] || null)));
}

// The page calls this on entering the view and after every /api/models
// re-read. The first paint also fires the three live checks, in parallel.
export function renderSettingsPage(c){
  const first = !ctx;
  ctx = c;
  paint();
  if(first) REGISTRY.forEach(r => { if(!live.checks[r.id] && !live.busy[r.id]) runCheck(r.id); });
}
```

- [ ] **Step 4: CSS, markup e ligação na página**

(a) No fim de `ui/css/pages.css`:

```css
/* ------------------------------------------------ Settings › Platforms
   One card per listed platform (ui/app/settings.js). Header with the mark,
   the status pill and the enable switch; two blocks (Binary, Session); the
   model rows, one switch each. Measures follow the approved artboards in
   docs/superpowers/mockups/2026-09-11-platform-settings/. */
.summary{display:flex;align-items:center;gap:10px;font-size:12.5px;color:var(--muted);margin:0 0 14px}
.platcard{background:var(--panel);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);margin:0 0 16px;overflow:hidden}
.platcard-h{display:flex;align-items:center;gap:12px;padding:16px 20px;border-bottom:1px solid var(--line2)}
.platcard-ic{display:flex;align-items:center;justify-content:center;width:36px;height:36px;border-radius:10px;
  background:var(--accent-soft);color:var(--accent);flex:none;font-size:13px;font-weight:700;letter-spacing:-.02em}
.platcard-ic.off{background:var(--panel2);color:var(--muted);border:1px solid var(--line)}
.platcard-t{flex:1 1 auto;min-width:0}
.platcard-t b{display:block;font-size:14.5px;font-weight:640;letter-spacing:-.01em}
.platcard-t span{display:block;font-size:12px;color:var(--muted)}
.platcard-r{display:flex;align-items:center;gap:14px;flex:none}
.swlabel{display:flex;flex-direction:column;align-items:flex-end;gap:3px;font-size:11.5px;color:var(--muted);text-align:right}
.swrow{display:flex;align-items:center;gap:8px;font-size:12.5px;font-weight:600;color:var(--ink)}
.platcard-g{display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:0}
.platcard-g > div{padding:14px 20px 16px}
.platcard-g > div + div{border-left:1px solid var(--line2)}
.platcard-g h3{margin:0 0 9px}
.val{display:flex;align-items:center;gap:8px;font-size:13px;font-weight:600;min-height:20px}
.val .ic{width:15px;height:15px}
.val.ok .ic{color:var(--ok)} .val.err .ic{color:var(--err)} .val.mute{color:var(--muted);font-weight:500}
.val code{background:var(--panel2);border:1px solid var(--line);border-radius:6px;padding:1px 6px;font-weight:500;font-size:12.5px}
.platcard .sub{font-size:12px;color:var(--muted);margin-top:4px;line-height:1.5}
.ctrl{display:flex;gap:8px;align-items:center;margin-top:10px}
.ctrl input{flex:1 1 auto;min-width:0;font:inherit;font-size:13px;height:34px;padding:0 11px;border:1px solid var(--line);border-radius:8px;background:var(--panel2);color:var(--ink)}
.ctrl input:focus{outline:none;border-color:var(--accent)}
.models-h{display:flex;align-items:center;gap:10px;padding:12px 20px;border-top:1px solid var(--line2);background:var(--panel2)}
.models-h .sp{flex:1 1 auto}
.models-h .age{font-size:12px;color:var(--muted)}
.mrow{display:flex;align-items:center;gap:14px;padding:10px 20px;border-top:1px solid var(--line2)}
.mname{flex:1 1 auto;min-width:0}
.mname b{display:block;font-size:13px;font-weight:600}
.mname span{display:block;font-size:12px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mrow.offrow .mname b{color:var(--muted);font-weight:500}
.mmeta{display:flex;align-items:center;gap:10px;font-size:11.5px;color:var(--muted);font-variant-numeric:tabular-nums;white-space:nowrap}
.mmeta .price{font-weight:600;color:var(--ink)}
.mrow.offrow .mmeta .price{color:var(--muted);font-weight:500}
.mmeta .jobs{display:inline-flex;align-items:center;font-size:11px;font-weight:600;color:var(--accent);background:var(--accent-soft);border-radius:20px;padding:0 8px;line-height:18px}
.mempty{padding:16px 20px 18px;border-top:1px solid var(--line2);font-size:12.5px;color:var(--muted)}
/* the strip Overview and Jobs show while nothing is configured */
.setup-banner{display:flex;align-items:center;gap:14px;padding:14px 18px;margin:0 0 20px;
  background:var(--warn-soft);border:1px solid color-mix(in srgb,var(--warn) 35%,var(--line));border-radius:13px}
.setup-banner .bic{display:flex;align-items:center;justify-content:center;width:34px;height:34px;border-radius:10px;
  background:color-mix(in srgb,var(--warn) 14%,transparent);color:var(--warn);flex:none}
.setup-banner .bic .ic{width:17px;height:17px}
.setup-banner .btxt{flex:1 1 auto;min-width:0;line-height:1.45}
.setup-banner .btxt b{display:block;font-size:13.5px;font-weight:640}
.setup-banner .btxt span{display:block;font-size:12.5px;color:var(--muted)}
/* the attention dot on the Settings item while nothing is configured -- the Runs counter's pulse, still */
.navitem .attn{width:8px;height:8px;border-radius:50%;background:var(--warn);flex:none;margin-right:4px}
@media (max-width: 900px){ .platcard-g{grid-template-columns:1fr} .platcard-g > div + div{border-left:0;border-top:1px solid var(--line2)} }
```

(b) `bin/dashboard.html`:
- No `<nav class="sidenav">`, o item passa a `<button class="navitem" data-view="settings" id="nav-settings"></button>` (sem `hidden`; apagar o comentário de duas linhas acima dele).
- Substituir o bloco `<div class="view" id="view-settings" hidden> … </div><!-- /view-settings -->` por:

```html
  <div class="view" id="view-settings" hidden>
  <!-- Settings › Platforms is drawn by ALApp.renderSettingsPage() (ui/app/settings.js)
       into the two hosts below; the Profile tab keeps the "not built yet" note. -->
  <div id="st-head"></div>
  <nav class="viewtabs" id="st-tabs">
    <button class="viewtab active" data-sttab="platforms" id="sttab-platforms"></button>
    <button class="viewtab" data-sttab="profile" id="sttab-profile"></button>
  </nav>
  <div class="pane" id="st-platforms"></div>
  <div class="pane" id="st-profile" hidden><div class="soon" id="soon-settings"></div></div>
  </div><!-- /view-settings -->
```
- `const VIEWS = ["overview","jobs","runs","projects","security","settings"];` e apagar as três linhas de comentário que explicavam a ausência.
- Em `setView`, logo a seguir a `render();`: `if(currentView === "settings") paintSettings();`.
- Junto a `let PLATFORMS={};`: `let MODELS_CONFIGURED, MODELS_ERROR="";   // /api/models' configured and error, undefined until it answers`.
- Em `loadModels()`, a seguir a `PLATFORMS=d.platforms||{};`: `MODELS_CONFIGURED=d.configured; MODELS_ERROR=d.error||"";` e, a seguir a `refillPlatformBound();`: `if(currentView==="settings") paintSettings();`.
- Nova função, a seguir a `refillPlatformBound()`:

```js
// The Settings page repaints only on entering the view and when /api/models
// answers -- never on the five-second poll, which would reset what the
// operator is typing into a card.
function paintSettings(){
  ALApp.renderSettingsPage({platforms: PLATFORMS, configured: MODELS_CONFIGURED, error: MODELS_ERROR,
    onChange: loadModels});
}
```
- No boot (junto a `$("soon-settings").innerHTML=soon(…)`): apagar `$("h-settings").innerHTML=I.gear+"Settings";`; acrescentar
```js
$("sttab-platforms").innerHTML=I.layers+"Platforms";
$("sttab-profile").innerHTML=I.user+"Profile";
$("st-tabs").addEventListener("click",(e)=>{
  const b=e.target.closest(".viewtab"); if(!b) return;
  document.querySelectorAll("#st-tabs .viewtab").forEach(x=>x.classList.toggle("active", x===b));
  $("st-platforms").hidden=(b.dataset.sttab!=="platforms");
  $("st-profile").hidden=(b.dataset.sttab!=="profile");
});
```

(c) `ui/app/index.js`: `import { renderSettingsPage, settingsSummary, platformStatus, setupBanner } from "./settings.js";` e os quatro nomes no objecto `window.ALApp`.

(d) `bash build/build-ui.sh`.

- [ ] **Step 5: Correr e ver passar**

```bash
bash build/build-ui.sh && python3.13 -m pytest tests/test_page_contract.py -p no:cacheprovider -q
```
Esperado: verde.

- [ ] **Step 6: Ver a página a sério (config e data de rascunho, nunca a instalação viva)**

```bash
mkdir -p /tmp/al-settings/config /tmp/al-settings/data && cp config/jobs.example.json /tmp/al-settings/config/jobs.json
AGENTLOOP_CONFIG=/tmp/al-settings/config AGENTLOOP_DATA=/tmp/al-settings/data AGENTLOOP_PORT=8799 bin/agentloop-server &
```
Abrir `http://127.0.0.1:8799/`, criar o perfil, ir a Settings: os três cartões verificam ao vivo; Anthropic e OpenAI mostram a conta real; *Load models* lista o catálogo; ligar um modelo escreve `/tmp/al-settings/config/platforms.json`. Parar o servidor (`kill %1`) e apagar `/tmp/al-settings`.

- [ ] **Step 7: Commit**

```bash
/usr/bin/git add ui/app/settings.js ui/app/index.js ui/css/pages.css bin/dashboard.html tests/test_page_contract.py bin/static/app.js bin/static/app.css bin/static/security.js
/usr/bin/git commit -m "feat(ui): Settings › Platforms -- one card per platform: binary, session, models, switch

The Settings item comes out of hiding. Each card finds the CLI, tests the
session live, loads the catalog once the test passes and switches models
on one by one; every change saves at once and the page re-reads what the
engine now allows. OpenCode is listed, detected and otherwise waiting for
its engine.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 9: UI — editores só com o activado, a faixa, o desvio do *New job*, o ponto, a aterragem

**Files:**
- Modify: `bin/dashboard.html` (`PLATFORM_OPTS` e os seus sete usos; `modelOptions`; `applyPlatformToJobEditor`; `applyPlatformToSecurity`; `secModelCfg`; `openCreator`; `validateStep`; `refillPlatformBound`; `render`; `paintNav`; o listener delegado de cliques; `submitSetup`; markup: `ed-platform-note`, `ed-model-help`, `ov-setup`, `jobs-setup`)
- Modify: `tests/test_page_contract.py`
- Build: `bash build/build-ui.sh` (só se `ui/` mudar; esta tarefa não deve precisar)

**Interfaces:**
- Consumes: `ALApp.platformOptions`, `ALApp.modelOptionsFor` (4 args), `ALApp.hiddenModelCount`, `ALApp.setupBanner`, `ALApp.defaultModelFor`, `MODELS_CONFIGURED`, `MODELS_ERROR`, `paintSettings`.
- Produces: nenhuma função nova para outros; a página deixa de ter `PLATFORM_OPTS`; `modelOptions(p, current)`; `paintSetupBanners()`; o passo *The agent* de `validateStep` recusa ao criar, ou quando plataforma/modelo mudaram, uma plataforma não `usable` ou um modelo fora de `models_enabled`.

- [ ] **Step 1: Escrever os testes de contrato (falham)**

```python
def test_the_editors_read_the_platform_list_from_the_registry(srv):
    js = _js(srv)
    assert "PLATFORM_OPTS" not in js, "the fixed two-platform list is gone: the registry decides"
    assert js.count("ALApp.platformOptions(PLATFORMS") >= 7
    assert "function modelOptions(p, current){ return ALApp.modelOptionsFor(p, PLATFORMS, groupModels, current); }" in js
    assert "allowCustom:false" in js.split("const secModelCfg=", 1)[1].split("\n", 1)[0], "the enabled list is the authority: no typed-in model"
    page = srv.render_page("boot-authed")
    for part in ("ov-setup", "jobs-setup", "ed-model-help"):
        assert f'id="{part}"' in page, f"missing {part}"
    assert "Only platforms enabled in Settings › Platforms are offered" in page


def test_new_job_is_diverted_to_settings_while_nothing_is_configured(srv):
    js = _js(srv)
    for hook in ("#new-job", "#ov-new-job"):
        assert f'if(e.target.closest("{hook}")){{ if(MODELS_CONFIGURED===false){{ setView("settings");' in js, hook
    assert 'if(e.target.closest("#open-settings")){ setView("settings"); return; }' in js
    assert 'MODELS_CONFIGURED===false ? \'<span class="attn" title="No platform is enabled yet"></span>\' : ""' in _plainfn(js, "paintNav")
    assert 'if(MODELS_CONFIGURED===false) setView("settings");' in _plainfn(js, "submitSetup")
    assert "paintSetupBanners();" in _plainfn(js, "render")


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_the_agent_step_refuses_what_settings_switched_off(srv, tmp_path):
    """Creating, or changing platform/model: a platform that is not usable or a
    model not switched on is refused with the sentence that says where to fix
    it; editing another field of a job whose model was switched off later is
    still allowed (the refusal is the launch's)."""
    js = _js(srv)
    script = tmp_path / "validate-agent.js"
    script.write_text("""
    const vals = {"ed-id": "j", "ed-cwd": "/x", "ed-prompt": "p", "ed-hours-start": "", "ed-hours-end": "",
                  "ed-platform": "openai", "ed-model": "gpt-a"};
    const $ = (id) => ({ get value(){ return vals[id] || ""; } });
    const getDays = () => [1];
    const DATA = {jobs: []};
    const projById = () => null;
    const ALApp = { platformOf: (j) => (j && j.platform) || "anthropic" };
    let PLATFORMS = {anthropic: {enabled: true, usable: true, models_enabled: ["claude-opus-5"]},
                     openai: {enabled: true, usable: false, models_enabled: []}};
    let creating = true, editingJob = null;
    """ + _plainfn(js, "validateStep") + """
    const out = {};
    out.platformOff = validateStep("agent");
    PLATFORMS.openai = {enabled: true, usable: true, models_enabled: ["gpt-b"]};
    out.modelOff = validateStep("agent");
    vals["ed-model"] = "gpt-b";
    out.ok = validateStep("agent");
    creating = false; editingJob = {id: "j", platform: "openai", model: "gpt-a"}; vals["ed-model"] = "gpt-a";
    out.unchangedEdit = validateStep("agent");
    vals["ed-model"] = "gpt-zzz";
    out.changedEdit = validateStep("agent");
    PLATFORMS = {};
    out.blind = validateStep("agent");
    console.log(JSON.stringify(out));
    """)
    out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
    assert out["platformOff"] == "This platform is not enabled in Settings › Platforms — enable it there, or pick another."
    assert out["modelOff"] == "This model is switched off in Settings › Platforms — switch it on there, or pick another."
    assert out["ok"] is None and out["unchangedEdit"] is None and out["blind"] is None
    assert out["changedEdit"].startswith("This model is switched off")
```

- [ ] **Step 2: Correr e ver falhar**

```bash
python3.13 -m pytest tests/test_page_contract.py -p no:cacheprovider -q -k "registry or diverted or agent_step"
```

- [ ] **Step 3: Implementar em `bin/dashboard.html`**

(a) Apagar `const PLATFORM_OPTS=[…];`. Os sete usos passam a `ALApp.platformOptions(PLATFORMS, <valor actual>)`:
- `platformCombo.set("anthropic", PLATFORM_OPTS)` → `platformCombo.set("anthropic", ALApp.platformOptions(PLATFORMS, "anthropic"))`;
- `pjPlatformCombo.set("anthropic", PLATFORM_OPTS)` → `pjPlatformCombo.set("anthropic", ALApp.platformOptions(PLATFORMS, "anthropic"))`;
- `secPlatformCombo.set("", PLATFORM_OPTS)` → `secPlatformCombo.set("", ALApp.platformOptions(PLATFORMS, ""))`;
- no `openProject`: `const pjp=(p&&p.platform==="openai")?"openai":"anthropic"; pjPlatformCombo.set(pjp, ALApp.platformOptions(PLATFORMS, pjp));` e `const sp=(sec.platform==="openai"||sec.platform==="anthropic")?sec.platform:""; secPlatformCombo.set(sp, ALApp.platformOptions(PLATFORMS, sp));`;
- as duas `platformCombo.set(plat, PLATFORM_OPTS)` → `platformCombo.set(plat, ALApp.platformOptions(PLATFORMS, plat))`.

(b) `function modelOptions(p){ … }` passa a `function modelOptions(p, current){ return ALApp.modelOptionsFor(p, PLATFORMS, groupModels, current); }`. Em `applyPlatformToJobEditor`, `const opts=modelOptions(p);` → `const opts=modelOptions(p, keep ? $("ed-model").value : "");` e no fim da função, antes de `edPlatApplied=p;`:

```js
  const hid=ALApp.hiddenModelCount(p, PLATFORMS);
  $("ed-model-help").textContent="The model the agent uses to execute this job — one of the models switched on in Settings."
    +(hid ? " "+hid+" more in the catalog "+(hid===1?"is":"are")+" switched off there." : "");
```
Em `applyPlatformToSecurity`, `const opts=modelOptions(p);` → `const opts=modelOptions(p, keep ? $("sec-model").value : "");` e `secModelCfg.allowCustom=(p!=="openai");` → `secModelCfg.allowCustom=false;`. Em `const secModelCfg={…}`, `allowCustom:true` → `allowCustom:false` (e o comentário acima passa a dizer que a lista de activados é a autoridade).

(c) `refillPlatformBound()` passa a:

```js
function refillPlatformBound(){
  const edp=$("ed-platform").value||"anthropic", pjp=$("pj-platform").value||"anthropic", sp=$("sec-platform").value||"";
  if(platformCombo) platformCombo.set(edp, ALApp.platformOptions(PLATFORMS, edp));
  if(pjPlatformCombo) pjPlatformCombo.set(pjp, ALApp.platformOptions(PLATFORMS, pjp));
  if(secPlatformCombo) secPlatformCombo.set(sp, ALApp.platformOptions(PLATFORMS, sp));
  if(platformCombo) applyPlatformToJobEditor(edp, true);
  if(secPlatformCombo) applyPlatformToSecurity(secEffectivePlatform(), true);
}
```

(d) `openCreator`: o `fill({…, platform:"anthropic", model:"opus", …})` passa a usar a primeira plataforma `usable` e o seu primeiro modelo:

```js
  const firstPlat=(ALApp.platformOptions(PLATFORMS, "")[0]||{}).v||"anthropic";
  fill({_precheck:DEFAULT_PRECHECK, interval_seconds:300, platform:firstPlat,
        model:ALApp.defaultModelFor(firstPlat, PLATFORMS)||"",
        active_hours:"08:00-20:00", active_days:[1,2,3,4,5],
        max_budget_usd:2, stall_timeout_seconds:1200,
        permission_mode:ALApp.defaultPermissionFor(firstPlat, "job")});
```

(e) `validateStep`: antes do `return null;` final:

```js
  if(k==="agent"){
    const p=$("ed-platform").value||"anthropic", m=$("ed-model").value;
    const was=editingJob&&editingJob.id ? {p: ALApp.platformOf(editingJob, projById(editingJob.project||"")), m: editingJob.model||""} : null;
    const changed=creating || !was || p!==was.p || m!==was.m;
    const entry=(PLATFORMS||{})[p];
    if(changed && entry && entry.enabled!==undefined){
      if(!entry.usable) return "This platform is not enabled in Settings › Platforms — enable it there, or pick another.";
      if(m && !(entry.models_enabled||[]).includes(m)) return "This model is switched off in Settings › Platforms — switch it on there, or pick another.";
    }
  }
```

(f) Markup: a seguir a `<div id="ov-head"></div>` inserir `<div id="ov-setup"></div>`; a seguir a `<div id="jobs-head"></div>` inserir `<div id="jobs-setup"></div>`; o `<p class="fieldhelp">The model the agent uses to execute this job.</p>` do editor de jobs ganha `id="ed-model-help"`; o texto de `ed-platform-note` passa a: `Which CLI runs this job. Only platforms enabled in Settings › Platforms are offered; changing it resets the model, effort and permission mode to that platform's defaults. Moving the job to a project on the other platform keeps this choice and sets it on the job. A job being created takes its project's.`

(g) A faixa e o desvio:

```js
// Overview and Jobs carry the same strip while nothing is configured; the
// Settings page itself says it in its own summary.
function paintSetupBanners(){
  ["ov-setup","jobs-setup"].forEach(id=>{
    const h=$(id); if(!h) return;
    h.textContent="";
    const b=ALApp.setupBanner(MODELS_CONFIGURED, MODELS_ERROR);
    if(b) h.appendChild(b);
  });
}
```
Chamada em `render()` logo a seguir a `paintNav();` e em `loadModels()` a seguir a `refillPlatformBound();`. No listener delegado, as duas linhas do *New job* passam a:

```js
  if(e.target.closest("#new-job")){ if(MODELS_CONFIGURED===false){ setView("settings"); toast("Enable a platform and at least one model first", true, "alert"); return; } openCreator(); return; }
```
e
```js
  if(e.target.closest("#ov-new-job")){ if(MODELS_CONFIGURED===false){ setView("settings"); toast("Enable a platform and at least one model first", true, "alert"); return; } openCreator(); return; }
```
mais, ao lado, `if(e.target.closest("#open-settings")){ setView("settings"); return; }`.

(h) `paintNav`: `item("nav-settings", I.gear, "Settings", null);` → `item("nav-settings", I.gear, "Settings", null, MODELS_CONFIGURED===false ? '<span class="attn" title="No platform is enabled yet"></span>' : "");`.

(i) `submitSetup`: a seguir a `await enterDashboard(j.user);`: `await loadModels(); if(MODELS_CONFIGURED===false) setView("settings");`.

- [ ] **Step 4: Correr tudo**

```bash
python3.13 -m pytest tests/test_page_contract.py tests/test_platforms_api.py -p no:cacheprovider -q
bash bin/agentloop selftest 2>&1 | grep -E "FAIL|passed"
```
Esperado: verde; o selftest continua `0 failed` (o `check_ui_artifact` confirma que os bundles estão actuais).

- [ ] **Step 5: Commit**

```bash
/usr/bin/git add bin/dashboard.html tests/test_page_contract.py
/usr/bin/git commit -m "feat(ui): editors offer only what Settings switched on; a strip and a diverted New job while nothing is

Platform and Model combos read the registry; a job's own switched-off
value is shown flagged, never rewritten, and the Agent step refuses it
only when creating or changing it. Overview and Jobs carry the strip, New
job opens Settings, the sidebar item carries a dot, and a fresh install
lands on Settings right after the operator profile.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

### Task 10: README, CHANGELOG e aceitação com os CLIs reais

**Files:**
- Modify: `README.md`, `CHANGELOG.md`

- [ ] **Step 1: README**

- Secção nova `## Settings` antes de `## Dashboard`: o que cada zona do cartão faz (Binary → Session → Models → o interruptor), o ficheiro `config/platforms.json` (forma, semente, "a refresh never touches it", um ficheiro inválido desliga tudo e é nomeado em `status` e na dashboard), os comandos `agentloop platform …` (um exemplo por verbo), e o que o OpenCode é nesta versão.
- `## Platforms`, parágrafo **What a run needs**: acrescentar "the platform switched on in Settings, and the model switched on for it — a run on either that is off is skipped before it costs a slot, with the reason in `tick.log`".
- `### Which Claude account a run signs in as`: retirar a linha `per project` da tabela e o parágrafo "Three things to know before splitting jobs across accounts" com os seus três pontos; dizer que a conta é a da instalação (`AGENTLOOP_CLAUDE_CONFIG_DIR` no install) e que Settings › Platforms mostra quem está autenticado. Em `### The security block on a project`, retirar `claude_config_dir` da lista de campos e a frase que o descreve.
- `### Try it in one minute`: antes de ligar o job de exemplo, o passo "enable Anthropic and one of its models in Settings › Platforms — or `agentloop platform enable anthropic` and `printf '["claude-haiku-4-5-20251001"]' | agentloop platform set-models anthropic`".
- `## Dashboard`: um ponto **Settings** (a página) e, no ponto **Jobs**, "the editor offers only the platforms and models switched on in Settings".
- `## CLI`: a linha `agentloop platform check|enable|disable|set-bin|models|set-models <platform> [path]` a seguir a `agentloop platforms`, e `AGENTLOOP_OPENCODE_BIN` nas variáveis de ambiente.
- `## Layout`: `config/platforms.json  # which platforms and models are switched on (seeded on first use)`.

- [ ] **Step 2: CHANGELOG**

Em `## [Unreleased]` → `### Added`, no topo:

```markdown
- **Settings › Platforms, and `config/platforms.json`: a job may only pick a
  platform and a model somebody switched on.** The Settings item comes out of
  hiding with one card per platform — find the binary (or point at it), test
  the session live (`claude auth status`, `codex login status`), load the
  catalog, switch models on one by one. The engine keeps the file
  (`agentloop platform …`), seeds it from the jobs already in use on an
  upgrade, and refuses at launch — one line in `tick.log`, before a slot is
  spent — a run on a platform or a model that is off; `set-field`, `create`
  and `project-set` refuse the same at write time. Overview and Jobs carry a
  strip while nothing is configured, and *New job* opens Settings. OpenCode
  is listed and detected; its engine is a later release. What it cost to
  not have it: the model picker offered the whole catalog, so a job on the
  most expensive OpenAI model was one click away, and a job on a CLI nobody
  had signed in to found out at its first launch, hours later.
```
A secção `### Removed` sob `[Unreleased]` **já existe** desde a Task 5, com este mesmo entry — não o repetir; só mover a secção para entre `### Changed` e `### Fixed` (a ordem de Keep a Changelog) e confirmar o texto:

```markdown
- **The per-project and per-block `claude_config_dir`.** The account a run
  signs in as is the platform's — the install's pin — and Settings › Platforms
  shows whom it is signed in as. A `projects.json` still carrying the field
  is warned about by `status` and `install`, and cleaned by the next save.
```

- [ ] **Step 3: As suites completas, em primeiro plano**

```bash
cp -n config/jobs.example.json config/jobs.json 2>/dev/null; bash bin/agentloop selftest 2>&1 | tail -3
python3.13 -m pytest tests -p no:cacheprovider -q --deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on
bash test/e2e.test.sh 2>&1 | tail -3
```
Com `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true` no ambiente para `tests/security`. Esperado: `0 failed` nas três.

- [ ] **Step 4: Aceitação com os CLIs reais (config e data de rascunho)**

```bash
mkdir -p /tmp/al-accept/config /tmp/al-accept/data && cp config/jobs.example.json /tmp/al-accept/config/jobs.json
AGENTLOOP_CONFIG=/tmp/al-accept/config AGENTLOOP_DATA=/tmp/al-accept/data bin/agentloop platforms | jq '.[] | {enabled, usable, bin_source, bin_found}'
AGENTLOOP_CONFIG=/tmp/al-accept/config AGENTLOOP_DATA=/tmp/al-accept/data bin/agentloop platform check anthropic
AGENTLOOP_CONFIG=/tmp/al-accept/config AGENTLOOP_DATA=/tmp/al-accept/data bin/agentloop platform enable openai
AGENTLOOP_CONFIG=/tmp/al-accept/config AGENTLOOP_DATA=/tmp/al-accept/data bin/agentloop platform models openai | jq '.models[] | {v, enabled, price}'
printf '["gpt-5.6-luna"]' | AGENTLOOP_CONFIG=/tmp/al-accept/config AGENTLOOP_DATA=/tmp/al-accept/data bin/agentloop platform set-models openai
AGENTLOOP_CONFIG=/tmp/al-accept/config AGENTLOOP_DATA=/tmp/al-accept/data bin/agentloop status | sed -n '/platforms :/,/^$/p'
```
Ler, não só ver verde: `check anthropic` traz o e-mail e o plano reais; `status` mostra `openai    : enabled — codex-cli …, Logged in using ChatGPT; 1 of N models enabled`. Depois, com o servidor de rascunho da Task 8 Step 6, abrir a dashboard: a faixa aparece enquanto nada está `usable`, *New job* leva aos Settings, ligar Anthropic e um modelo faz a faixa desaparecer, e o editor de jobs lista só esse modelo. Apagar `/tmp/al-accept` no fim.

- [ ] **Step 5: Commit e entrega**

```bash
/usr/bin/git add README.md CHANGELOG.md
/usr/bin/git commit -m "docs: Settings › Platforms, the platform commands, and the account that is the platform's

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
Depois, a skill `finishing-a-development-branch`: PR de `feat/platform-settings` para `main`; o pós-merge é o de sempre ([memória `claude-cron-post-merge`]: `git pull` no checkout principal, `bash install.sh`, uma instância do servidor), e a primeira abertura dos Settings na instalação viva confirma a semente: `2 of 3 platforms enabled` com os modelos dos oito jobs.
