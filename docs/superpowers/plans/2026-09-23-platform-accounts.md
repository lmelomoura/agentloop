# Contas por plataforma — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settings regista N contas Claude e Codex por plataforma, ao lado da conta Default da instalação; o job, o projecto e o bloco de segurança escolhem Plataforma → Conta → Modelo; o motor lança o CLI nessa conta e fica consciente dela na prontidão, nos limites de utilização, no rollout do Codex, nas skills e no resume.

**Architecture:** O motor (`bin/agentloop`, bash 3.2 + jq) guarda as contas em `config/platforms.json` (`platforms.<p>.accounts`), resolve a conta de cada run (`job_account`), exporta `CLAUDE_CONFIG_DIR`/`CODEX_HOME` com `env -u` + atribuição, e grava a conta no journal. O servidor (`bin/agentloop-server`, python stdlib) espelha a lista em `/api/models`, retransmite as quatro acções novas e indexa a conta de cada run. A página (`bin/dashboard.html` + `ui/app/*.js`, empacotados para `bin/static/`) ganha a secção Accounts em Settings, o combo Account nos três editores e a linha Account no detalhe do run.

**Tech Stack:** bash 3.2 (sem arrays associativos, sem `case` dentro de `$( )`), jq, python3 stdlib, esbuild só no build (`build/build-ui.sh`), pytest em `python3.13`, selftest e e2e em bash.

**Spec:** [`docs/superpowers/specs/2026-09-23-platform-accounts-design.md`](../specs/2026-09-23-platform-accounts-design.md).

## Global Constraints

- **Idioma dos artefactos:** código, comentários, docstrings, mensagens de commit, README e CHANGELOG em inglês. Só este plano e a spec estão em português.
- **Ficheiro:** `config/platforms.json` ganha, só em `anthropic` e `openai`, `"accounts": [{"id": "...", "name": "...", "dir": "..."}]`. A Default (`id` `default`, nome "Default") nunca é gravada.
- **Id:** gerado do nome por `account_slug` (minúsculas; cada sequência fora de `[a-z0-9]` passa a um `-`; sem `-` nas pontas; até 40 caracteres; vazio → `account`), com `-2`, `-3`… quando já existe; `default` é reservado. Nunca muda.
- **Pasta:** guardada como escrita, sem barras finais. Normalizada (`account_norm_dir`: `~` expandido, sem barras finais, absoluta) para comparar e exportar.
- **Valor exportado (`account_dir`):** a pasta normalizada, **ou vazio quando é a pasta por omissão do CLI** (`$HOME/.claude`, `$HOME/.codex`). Vazio = variável por definir. No lançamento, `run_env` começa por `-u CLAUDE_CONFIG_DIR` (Anthropic) ou `-u CODEX_HOME` (OpenAI) e só depois `VAR=<account_dir>` quando não é vazio.
- **Regra de resolução:** job → o seu `account`; senão o do projecto, se o job tiver projecto e a mesma plataforma efectiva que ele; senão `default`. Bloco `security` → o seu; senão o do projecto se a plataforma do bloco for a do projecto; senão `default`. Projecto → o seu, senão `default`.
- **Chave dos limites:** `rl_key <p> <account_dir>` → `<p>` quando vazio, `<p>@<account_dir>` quando não.
- **Frases exactas** (os testes fixam-nas):
  - `account '<name>' added on <p> (id <id>) — <estado>` e `account '<name>' saved on <p> — <estado>`, com `<estado>` = `signed in as <conta>` (Anthropic) ou a própria resposta do Codex, ou a razão de não estar pronta; `account '<id>' removed from <p>`;
  - recusas de registo: `an account needs a name` · `Default is the install's own account — choose another name` · `an account named '<n>' already exists on <p>` · `an account needs a directory` · `the directory must be absolute or start with ~/ (got '<d>')` · `<d> does not exist — create it by signing in: CLAUDE_CONFIG_DIR=<d> claude auth login` · `<d> does not exist — create it and sign in: mkdir -p <d> && CODEX_HOME=<d> codex login` · `<d> is the Default account's directory` · `<d> is already the directory of the account '<n>'`;
  - `the Default account is the install's own — it is not edited here` · `the Default account is the install's own — it cannot be removed` · `no account '<id>' on <p>` · `'<n>' is used by <quem> — move them to another account first`;
  - `OpenCode has no accounts — its credentials are the providers configured in opencode itself`;
  - verificação: `claude is not signed in in <d> (run: CLAUDE_CONFIG_DIR=<d> claude auth login)` · `codex is not signed in in <d> (run: CODEX_HOME=<d> codex login)` · `codex is not signed in in <d> (run: mkdir -p <d> && CODEX_HOME=<d> codex login)` (pasta de uma conta registada em falta) · `account '<id>' is not an account of <p> in Settings`;
  - lançamento (`tick.log`): `<job>: OpenCode has no accounts (account '<id>'), skipped` · `<job>: account '<id>' is not an account of <p> in Settings, skipped` · `<job>: account '<nome>' is missing its directory (<d>), skipped`;
  - escrita: `account '<v>' is not an account of <p> — <p> has: default, <ids>` (set-field) · `create: account '<v>' is not an account of <p> — <p> has: …` · `project-set: account '<v>' is not an account of <p> — <p> has: …` · `project-set: security.account '<v>' is not an account of <p> — <p> has: …` · `account '<v>' is not an account of <p> — cleared, the job inherits` · `account '<v>' is not an account of <p> — cleared, the project runs on the Default account` · `security.account '<v>' is not an account of <p> — cleared, the analysis inherits`;
  - travão: `the <p> <janela> window of <nome> is <n>% used -- it resets in <m> min` (a Default não leva ` of <nome>`).
- **bash 3.2:** nada de `case` dentro de `$( )`; nenhum comentário dentro de `$( )` com apóstrofo ou parêntese solto; heredocs com o terminador na coluna 0. Validar a correr, não só com `bash -n`.
- **Testes locais só os rápidos** (preferência do utilizador): os blocos do selftest que a tarefa toca, pelo arnês de blocos; os cenários e2e que a tarefa toca, pelo arnês de cenários; `python3.13 -m pytest tests --ignore=tests/security -p no:cacheprovider -q` quando a tarefa toca no servidor ou na página. O selftest completo fica para a CI. Sempre em primeiro plano, `timeout` 600000.
- **Isolamento:** nenhum teste toca `config/`, `data/`, `~/.claude*`, `~/.codex*` ou o plist reais: `HOME`, `PLIST_PATH`, `AGENTLOOP_CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `PLATFORMS_FILE`, `PROJECTS_FILE`, `JOBS_FILE`, `CONFIG_DIR`, `MODELS_FILE` apontam para rascunho sempre que o bloco os lê.
- **Home dirs em ficheiros versionados:** só `/Users/me`, `~/…` ou variáveis (o selftest recusa outros).
- **UI:** qualquer edição em `ui/` obriga a `bash build/build-ui.sh` no mesmo commit. Ícones só do conjunto `I` da página (`pencil`, `trash`, `plus`, `check`, `refresh`, `xcircle`, `alert` existem).
- **CHANGELOG:** o selftest exige que `CHANGELOG.md` seja pelo menos tão recente como o último commit que toca `bin/`, `skills/` ou `test/`: cada commit de código toca o CHANGELOG. A Task 1 abre o entry em `## [Unreleased]` → `### Added`; cada tarefa acrescenta-lhe uma frase; a Task 7 consolida.
- **Commits:** um por tarefa no mínimo, mensagem em inglês, a terminar em `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Git com `/usr/bin/git`, um comando por chamada.

## Verificação: os dois arneses (guardar no scratchpad, fora do repositório)

`run-block.sh` corre um troço do `test/selftest.sh` contra o motor do worktree:

```bash
#!/bin/bash
# run-block.sh <worktree> "<first header>" "<next header>"
# Runs the stretch of test/selftest.sh from the line `  echo "<first header>`
# up to (not including) `  echo "<next header>`, against the worktree's own
# engine, in a scratch config/data. Both markers must exist or nothing runs.
set -u
WT="$1"; FROM="$2"; TO="$3"
S="$(mktemp -d "${TMPDIR:-/tmp}/alblock.XXXXXX")"
mkdir -p "$S/config" "$S/data"
sed '/^case "${1:-}" in$/,$d' "$WT/bin/agentloop" > "$S/engine-lib.sh"
sed '/^cmd_selftest() {/,$d' "$WT/test/selftest.sh" > "$S/prelude.sh"
awk -v a="$FROM" -v b="$TO" '
  index($0, "  echo \"" a) == 1 { on = 1; found = 1 }
  on && index($0, "  echo \"" b) == 1 { on = 0; closed = 1 }
  on { print }
  END { exit (found && closed) ? 0 : 3 }' "$WT/test/selftest.sh" > "$S/block.sh" \
  || { echo "run-block: a marker was not found -- nothing ran" >&2; exit 3; }
{
  echo 'blk() {'
  awk '/^cmd_selftest\(\) \{/ { on = 1; next }
       on && index($0, "  echo \"num() ") == 1 { exit }
       on { print }' "$WT/test/selftest.sh"
  cat "$S/block.sh"
  echo '  echo "RESULT pass=$pass fail=$fail"'
  echo '}'
} > "$S/run.sh"
AGENTLOOP_CONFIG="$S/config" AGENTLOOP_DATA="$S/data" \
  /bin/bash -c '. "$1"; . "$2"; . "$3"; blk' "$WT/bin/agentloop" "$S/engine-lib.sh" "$S/prelude.sh" "$S/run.sh"
```

`e2e-one.sh` corre cenários do `test/e2e.test.sh`, por ordem, numa sandbox nova:

```bash
#!/bin/bash
# e2e-one.sh <worktree> <sandbox-root> <scenario ids...>
set -u
WT="$1"; ROOT="$2"; shift 2
S="$(mktemp -d "${TMPDIR:-/tmp}/ale2e.XXXXXX")"
sed '/^E2E_WORKERS="${E2E_WORKERS:-4}"$/,$d' "$WT/test/e2e.test.sh" > "$S/e2e-lib.sh"
/bin/bash -c '. "$1"; shift; e2e_run_list "$@"; echo "RESULT pass=$pass fail=$fail"' \
  "$WT/test/e2e.test.sh" "$S/e2e-lib.sh" "$ROOT" "$@"
```

Nos passos abaixo, `$BLOCK` é `bash <scratchpad>/run-block.sh <worktree>`, `$E2E1` é `bash <scratchpad>/e2e-one.sh <worktree> <scratchpad>/e2e-root` e `$WT` é o worktree. Um passo "deve falhar" espera `FAIL` ou `RESULT … fail=N` com N > 0; um passo "deve passar" espera `fail=0`.

## Mapa de ficheiros

| Ficheiro | Responsabilidade nesta entrega |
|---|---|
| `bin/agentloop` | bloco de contas (registo, normalização, verificação por conta, verbos `platform accounts|account-add|account-edit|account-remove`), skills por conta, `job_account`, validação em `set-field`/`create`/`project-set`, derivados, migração do `claude_config_dir`, lançamento (portas, ambiente, precheck, journal, resume, rollout), limites por conta, `usage`, `status` |
| `bin/statusline-rate-limits.sh` | a leitura vai para a chave da conta da sessão |
| `test/fake-claude`, `test/fake-codex` | sessão por pasta (`.fake-logged-out`), email por pasta (`.fake-email`), `FAKE_ACCOUNT_OUT` no Codex |
| `test/selftest.sh` | blocos novos e ajustes aos que as mudanças tocam |
| `test/e2e.test.sh` | `mkjob_acct`, cenários 47–52, chaves `openai@…` nos 13 e 18 |
| `bin/agentloop-server` | `accounts` em `/api/models`, as acções novas, `set_field account`, colunas `account`/`account_dir` (schema 7), detalhe e run vivo |
| `tests/test_platforms_api.py`, `tests/test_run_accounts.py` (novo) | servidor |
| `ui/app/editor-domain.js`, `ui/app/index.js` | regras das contas para os editores |
| `ui/app/settings.js`, `ui/css/pages.css` | secção Accounts |
| `bin/dashboard.html` | três combos Account, gravação, detalhe do run e comando de reabrir |
| `bin/static/*` | bundles reconstruídos |
| `tests/test_page_contract.py` | contrato da página |
| `README.md`, `CHANGELOG.md` | documentação |

---

### Task 1: O registo de contas, a verificação por conta e as skills em cada conta

**Files:**
- Modify: `bin/agentloop` (bloco novo a seguir a `platform_jobs_on()`; `PLATFORMS_JQ`; `platform_check`; `platform_ready`; `cmd_platform`; skills; `usage()`; texto das skills em `cmd_install`)
- Modify: `test/fake-claude`, `test/fake-codex`
- Modify: `test/selftest.sh`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `platforms_json`, `write_platforms`, `platforms_jq`, `expand_home`, `installed_config_dir`, `CODEX_HOME_DIR`, `skills_link_into`, `SKILLS_DIR`, `USER_SKILLS`, `CODEX_SKILLS`.
- Produces: `ACCOUNTS_NONE_OPENCODE`; `account_platform <p>` (rc); `account_var <p>`; `account_cli_default <p>`; `account_norm_dir <text>` (rc 1 sem saída quando não é absoluta); `account_env_value <p> <dir>`; `accounts_json <p>` (lista JSON); `account_known <p> <id>` (rc); `account_ids_line <p>`; `account_default_dir <p>`; `account_field <p> <id> <name|dir>`; `account_env_dir <p> <id>`; `account_slug <nome>`; `account_users <p> <id>` (uma linha por `<job>`, `project:<n>`, `security:<n>`); `account_refusal <p> <own-id> <nome> <pasta>`; `account_add <p> <nome> <pasta>` (imprime o id; rc 1 com a recusa); `account_edit <p> <id> <nome> <pasta>`; `account_remove <p> <id>`; `account_check_sentence <p> <id>`; `platform_accounts_json <p>`; `platform_check <p> [id [pasta-exportada]]` (JSON ganha `account_id`, `account_dir`); `platform_ready <p> [id [pasta]]`; `skills_roots`; `skills_missing <root>`; defs jq `dflt`, `project_platform($p)`, `job_account($j)`, `sec_account($p)`, `account_uses`.

- [ ] **Step 1: Os fakes respondem por pasta**

Em `test/fake-claude`, substituir o ramo `auth)` do primeiro `case` (as linhas de `auth)` até ao `exit 0 ;;` que imprime `fake@example.org`) por:

```bash
  auth)
    # One session per config directory, the way the real CLI keeps them: a
    # directory holding .fake-logged-out has none, and .fake-email names the
    # account signed in there.
    if [ -n "${FAKE_CLAUDE_LOGGED_OUT:-}" ] || { [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$CLAUDE_CONFIG_DIR/.fake-logged-out" ]; }; then
      printf '{"loggedIn":false,"authMethod":"none"}\n'; exit 1
    fi
    email="fake@example.org"
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$CLAUDE_CONFIG_DIR/.fake-email" ]; then email="$(cat "$CLAUDE_CONFIG_DIR/.fake-email")"; fi
    printf '{"loggedIn":true,"authMethod":"claude.ai","email":"%s","subscriptionType":"max"}\n' "$email"; exit 0 ;;
```

Na lista de variáveis do cabeçalho do mesmo ficheiro, a seguir à linha de `FAKE_CLAUDE_LOGGED_OUT`, acrescentar:

```bash
#   $CLAUDE_CONFIG_DIR/.fake-logged-out  that one directory has no session (an account signed out)
#   $CLAUDE_CONFIG_DIR/.fake-email       the email `auth status` names for that directory
```

Em `test/fake-codex`, substituir a linha `  login)     [ -z "${FAKE_CODEX_LOGGED_OUT:-}" ] || exit 1` e a seguinte por:

```bash
  login)     [ -z "${FAKE_CODEX_LOGGED_OUT:-}" ] || exit 1
             { [ -n "${CODEX_HOME:-}" ] && [ -f "$CODEX_HOME/.fake-logged-out" ]; } && exit 1
             echo "Logged in using ChatGPT"; exit 0 ;;
```

e, no cabeçalho, a seguir a `FAKE_CODEX_LOGGED_OUT`:

```bash
#   $CODEX_HOME/.fake-logged-out  that one home has no session (an account signed out)
```

- [ ] **Step 2: Escrever o bloco do selftest (falha: os verbos não existem)**

Em `test/selftest.sh`, imediatamente antes da linha que começa por `  echo "resolve_pricing_openai() — the price table refreshes itself`, inserir:

```bash
  echo "accounts — the sign-ins Settings registers beside each platform's Default"
  local ac="$tmp/ac" _aj
  mkdir -p "$ac/config" "$ac/data" "$ac/fakehome/.claude" "$ac/fakehome/.claude-a" "$ac/fakehome/.claude-b" "$ac/fakehome/.codex-a" "$ac/codex-home"
  printf '{"jobs":[{"id":"ja","project":"P","prompt":"x","model":"claude-opus-5"},{"id":"jo","platform":"openai","model":"gpt-a","prompt":"x"}]}\n' > "$ac/config/jobs.json"
  printf '{"projects":[{"name":"P","cwd":"%s"}]}\n' "$ac" > "$ac/config/projects.json"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},"openai":{"enabled":true,"bin":"","models":["gpt-a"]},"opencode":{"enabled":false,"bin":"","models":[]}}}\n' > "$ac/config/platforms.json"
  # A home of its own: `~` in a directory, the Default's ~/.claude, the plist
  # the pin is read back from and ~/.claude/skills all hang off HOME, and
  # none of them may be the operator's.
  ac_al() { HOME="$ac/fakehome" AGENTLOOP_CONFIG="$ac/config" AGENTLOOP_DATA="$ac/data" \
            AGENTLOOP_CLAUDE_BIN="$BASE_DIR/test/fake-claude" AGENTLOOP_CODEX_BIN="$BASE_DIR/test/fake-codex" \
            AGENTLOOP_CLAUDE_CONFIG_DIR="" CODEX_HOME="$ac/codex-home" AGENTLOOP_OPENCODE_BIN=/nonexistent/opencode \
            "$BIN_DIR/agentloop" "$@"; }
  ac_refused() { # ac_refused <label> <expected substring> <platform args...>
    local _l="$1" _w="$2" _o _r; shift 2
    _o="$(ac_al platform "$@" 2>&1)"; _r=$?
    case "$_o" in *"$_w"*) [ "$_r" -ne 0 ] && ok "$_l" || bad "$_l: rc=$_r" ;; *) bad "$_l: $_o" ;; esac
  }
  _aj="$(ac_al platform accounts anthropic 2>/dev/null)"
  printf '%s' "$_aj" | "$JQ" -e --arg h "$ac/fakehome/.claude" 'length == 1 and .[0].id == "default" and .[0].name == "Default"
      and .[0].builtin == true and .[0].dir == $h and .[0].account_dir == "" and .[0].check.ready == true
      and .[0].used_by == {jobs: ["ja"], projects: ["P"], security: []}' >/dev/null 2>&1 \
    && ok "platform accounts: the Default alone, on the CLI's own directory, with who runs on it" || bad "accounts before any: $_aj"
  out="$(ac_al platform account-add anthropic "Cliente A" "~/.claude-a" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "account 'Cliente A' added on anthropic (id cliente-a) — signed in as fake@example.org · max plan" ] \
    && ok "account-add registers it, names its id and whom it is signed in as" || bad "account-add: rc=$rc $out"
  [ "$("$JQ" -c '.platforms.anthropic.accounts' "$ac/config/platforms.json")" = '[{"id":"cliente-a","name":"Cliente A","dir":"~/.claude-a"}]' ] \
    && ok "and the file keeps the directory as it was typed" || bad "file: $(cat "$ac/config/platforms.json")"
  [ "$(readlink "$ac/fakehome/.claude-a/skills/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
    && ok "and the skills are linked into that account's own skills directory" || bad "skills in the account: $(ls "$ac/fakehome/.claude-a" 2>&1)"
  ac_refused "a name already used is refused, whatever its case" "an account named 'cliente a' already exists on anthropic" account-add anthropic "cliente a" "~/.claude-b"
  ac_refused "a directory another account has is refused, trailing slash or not" "$ac/fakehome/.claude-a is already the directory of the account 'Cliente A'" account-add anthropic "Other" "$ac/fakehome/.claude-a/"
  ac_refused "a relative directory is refused" "the directory must be absolute or start with ~/ (got 'relative/dir')" account-add anthropic "Rel" "relative/dir"
  ac_refused "a directory that does not exist says how to create it" "$ac/fakehome/.claude-none does not exist — create it by signing in: CLAUDE_CONFIG_DIR=$ac/fakehome/.claude-none claude auth login" account-add anthropic "None" "~/.claude-none"
  ac_refused "the Default's own directory is refused" "$ac/fakehome/.claude is the Default account's directory" account-add anthropic "Home" "~/.claude"
  ac_refused "Default is not a name an account can take" "Default is the install's own account — choose another name" account-add anthropic "default" "~/.claude-b"
  ac_refused "OpenCode has no accounts" "OpenCode has no accounts — its credentials are the providers configured in opencode itself" account-add opencode "X" "~/.claude-b"
  out="$(ac_al platform account-add anthropic "Cliente-A" "~/.claude-b" 2>&1)"
  case "$out" in *"(id cliente-a-2)"*) ok "an id already taken gets a numbered suffix" ;; *) bad "suffix: $out" ;; esac
  : > "$ac/fakehome/.claude-b/.fake-logged-out"
  _aj="$(ac_al platform check anthropic cliente-a-2 2>/dev/null)"
  printf '%s' "$_aj" | "$JQ" -e --arg d "$ac/fakehome/.claude-b" '.ready == false and .account_id == "cliente-a-2" and .account_dir == $d
      and .reason == ("claude is not signed in in " + $d + " (run: CLAUDE_CONFIG_DIR=" + $d + " claude auth login)")' >/dev/null 2>&1 \
    && ok "platform check <p> <id> checks that account's own directory" || bad "check cliente-a-2: $_aj"
  printf 'a@example.org' > "$ac/fakehome/.claude-a/.fake-email"
  [ "$(ac_al platform check anthropic cliente-a 2>/dev/null | "$JQ" -r .account)" = "a@example.org · max plan" ] \
    && ok "and says whom that directory is signed in as" || bad "check cliente-a: $(ac_al platform check anthropic cliente-a 2>&1)"
  [ "$(ac_al platform check anthropic nope 2>/dev/null | "$JQ" -r '.ready, .reason' | tr '\n' '|')" = "false|account 'nope' is not an account of anthropic in Settings|" ] \
    && ok "an id Settings does not have is not ready, and says so" || bad "check nope: $(ac_al platform check anthropic nope 2>&1)"
  out="$(ac_al platform account-edit anthropic cliente-a "Cliente Alfa" "~/.claude-a" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "account 'Cliente Alfa' saved on anthropic — signed in as a@example.org · max plan" ] \
    && [ "$("$JQ" -r '.platforms.anthropic.accounts[0] | "\(.id) \(.name)"' "$ac/config/platforms.json")" = "cliente-a Cliente Alfa" ] \
    && ok "account-edit renames it and keeps its id" || bad "edit: rc=$rc $out"
  ac_refused "the Default is not edited here" "the Default account is the install's own — it is not edited here" account-edit anthropic default "X" "~/.claude-b"
  "$JQ" '.jobs[0].account = "cliente-a"' "$ac/config/jobs.json" > "$ac/jobs.next" && mv "$ac/jobs.next" "$ac/config/jobs.json"
  ac_refused "an account in use is not removed, and the refusal names who uses it" "'Cliente Alfa' is used by ja — move them to another account first" account-remove anthropic cliente-a
  "$JQ" 'del(.jobs[0].account)' "$ac/config/jobs.json" > "$ac/jobs.next" && mv "$ac/jobs.next" "$ac/config/jobs.json"
  out="$(ac_al platform account-remove anthropic cliente-a 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "account 'cliente-a' removed from anthropic" ] \
    && [ "$("$JQ" -c '[.platforms.anthropic.accounts[].id]' "$ac/config/platforms.json")" = '["cliente-a-2"]' ] \
    && ok "once nobody uses it, it is removed, and only it leaves the file" || bad "remove: rc=$rc $out $(cat "$ac/config/platforms.json")"
  ac_refused "the Default is never removed" "the Default account is the install's own — it cannot be removed" account-remove anthropic default
  out="$(ac_al platform account-add openai "Cliente A" "~/.codex-a" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "account 'Cliente A' added on openai (id cliente-a) — Logged in using ChatGPT" ] \
    && ok "an OpenAI account has its own list: the same name and id are free there" || bad "openai add: rc=$rc $out"
  : > "$ac/fakehome/.codex-a/.fake-logged-out"
  [ "$(ac_al platform check openai cliente-a 2>/dev/null | "$JQ" -r .reason)" = "codex is not signed in in $ac/fakehome/.codex-a (run: CODEX_HOME=$ac/fakehome/.codex-a codex login)" ] \
    && ok "and its check runs codex login status in that CODEX_HOME" || bad "openai check: $(ac_al platform check openai cliente-a 2>&1)"
  [ "$(readlink "$ac/fakehome/.codex-a/skills/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
    && ok "and the skills are linked into its home too" || bad "codex account skills: $(ls "$ac/fakehome/.codex-a" 2>&1)"
  ac_refused "a Codex home that does not exist says how to create it" "$ac/fakehome/.codex-none does not exist — create it and sign in: mkdir -p $ac/fakehome/.codex-none && CODEX_HOME=$ac/fakehome/.codex-none codex login" account-add openai "N" "~/.codex-none"
  [ "$( HOME=/Users/me; account_env_value anthropic "/Users/me/.claude/" )" = "" ] \
    && [ "$( HOME=/Users/me; account_env_value anthropic "~/.claude-x///" )" = "/Users/me/.claude-x" ] \
    && [ "$( HOME=/Users/me; account_env_value openai "~/.codex" )" = "" ] \
    && [ "$( HOME=/Users/me; account_env_value openai "" )" = "" ] \
    && ok "account_env_value: the CLI's own directory (and nothing) is no value at all; any other is normalized" || bad "account_env_value"
  ( account_norm_dir "rel/dir" >/dev/null ); want "account_norm_dir refuses a relative path" 1 $?
  ( account_norm_dir "/" >/dev/null ); want "and the root" 1 $?
  [ "$(account_slug "  Cliente Á / Nº 2 ")" = "cliente-n-2" ] && [ "$(account_slug "!!!")" = "account" ] \
    && ok "account_slug: lower case, dashes, nothing at the ends, a fallback for nothing" || bad "slug: $(account_slug "  Cliente Á / Nº 2 ") / $(account_slug "!!!")"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":[],"accounts":[{"id":"ok","name":"Ok","dir":"/x"},{"id":"","name":"n","dir":"/y"},"junk",{"id":"default","name":"D","dir":"/z"},{"id":"n","name":"N"}]}}}\n' > "$ac/malformed.json"
  [ "$( PLATFORMS_FILE="$ac/malformed.json"; accounts_json anthropic )" = '[{"id":"ok","name":"Ok","dir":"/x"}]' ] \
    && [ "$( PLATFORMS_FILE="$ac/malformed.json"; accounts_json opencode )" = '[]' ] \
    && ok "accounts_json keeps only well-formed entries, never one called default, and OpenCode has none" || bad "malformed: $( PLATFORMS_FILE="$ac/malformed.json"; accounts_json anthropic )"
```

O `account_slug` do caso "Cliente Á / Nº 2": `tr` passa a minúsculas o que conhece, e o `sed` transforma cada sequência fora de `[a-z0-9]` (o `Á` e o `º` incluídos) num só `-`, dando `cliente-n-2`. Se a máquina der outro resultado para os caracteres acentuados, trocar o caso por `"  Cliente A / No 2 "` → `cliente-a-no-2`: o que se testa é a regra, não o locale.

- [ ] **Step 3: Ajustar os testes existentes que as mudanças tocam**

(a) Em `test/selftest.sh`, na linha que começa `  _pc="$( PLATFORMS_FILE="$pb/none.json"; AGENTLOOP_CODEX_BIN=""; CODEX_BIN="$BASE_DIR/test/fake-codex"; FAKE_CODEX_LOGGED_OUT=1 platform_check openai )"`, acrescentar `CODEX_HOME_DIR="$HOME/.codex"; ` logo a seguir a `AGENTLOOP_CODEX_BIN=""; ` — a frase sem pasta é a da Codex home por omissão, e o teste não pode depender do `CODEX_HOME` de quem o corre.

(b) Substituir a linha

```bash
  case "$out" in *"cannot enable openai: codex is not signed in (run: codex login)"*) ok "and says why" ;; *) bad "enable refusal: $out" ;; esac
```

por

```bash
  # pc_al runs the engine with CODEX_HOME pointed at a scratch home: the
  # Default IS that home, and the sentence names it.
  case "$out" in *"cannot enable openai: codex is not signed in in $pc/codex-home (run: CODEX_HOME=$pc/codex-home codex login)"*) ok "and says why, naming the home it checked" ;; *) bad "enable refusal: $out" ;; esac
```

(c) No bloco `cmd_skills() — links into the Claude skills root, …`, dentro do subshell, logo a seguir à linha `    CODEX_SKILLS="$CODEX_HOME_DIR/skills"` (a primeira), inserir:

```bash
    # No pin and no plist: the Default is ~/.claude, whose root is USER_SKILLS.
    # One registered account whose directory exists, one whose does not.
    PLIST_PATH=/nonexistent; AGENTLOOP_CLAUDE_CONFIG_DIR=""
    PLATFORMS_FILE="$tmp/skl/platforms.json"
    mkdir -p "$tmp/skl/acct-a"
    printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":[],"accounts":[{"id":"a","name":"A","dir":"%s"},{"id":"gone","name":"Gone","dir":"%s"}]}}}\n' \
      "$tmp/skl/acct-a" "$tmp/skl/acct-gone" > "$PLATFORMS_FILE"
```

e, a seguir à asserção `cmd_skills install: no Codex home, so no Codex skills directory is invented`, inserir:

```bash
    [ "$(readlink "$tmp/skl/acct-a/skills/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
      && ok "cmd_skills install: every registered account's directory gets the links too" \
      || bad "account link: '$(readlink "$tmp/skl/acct-a/skills/security-analysis" 2>/dev/null)'"
    [ ! -e "$tmp/skl/acct-gone" ] \
      && ok "cmd_skills install: an account directory that does not exist is not invented" \
      || bad "created $tmp/skl/acct-gone"
```

e trocar, no fim do bloco, `RESULT ok=7 bad=0` por `RESULT ok=9 bad=0` e `all 7 assertions` por `all 9 assertions`.

(d) No bloco `cmd_install() — the account it pins is the one the engine reads back`: trocar todas as ocorrências de `/tmp/al-pinned` por `$tmp/inst/al-pinned` (são seis); acrescentar `"$tmp/inst/al-pinned"` ao `mkdir -p` do início do subshell; a seguir à asserção `and so does the server's`, inserir:

```bash
    [ "$(readlink "$tmp/inst/al-pinned/skills/security-analysis")" = "$SKILLS_DIR/security-analysis" ] \
      && ok "and the pinned account's own skills directory gets the links: runs there read it, not ~/.claude/skills" \
      || bad "pin skills: '$(readlink "$tmp/inst/al-pinned/skills/security-analysis" 2>/dev/null)'"
```

e trocar `RESULT ok=5 bad=0` por `RESULT ok=6 bad=0` e `all 5 assertions` por `all 6 assertions`.

(e) No bloco `status_platforms_block() — one line per platform …`, dentro do subshell, logo a seguir à linha `    CODEX_BIN="$BASE_DIR/test/fake-codex"`, inserir `    CODEX_HOME_DIR="$HOME/.codex"                 # the Codex Default on the CLI's own home: its sentences name no directory`.

- [ ] **Step 4: Correr os blocos — devem falhar**

```bash
$BLOCK "accounts — the sign-ins Settings registers" "resolve_pricing_openai() — the price table refreshes itself"
$BLOCK "cmd_skills() — links into the Claude skills root" "status_platforms_block() — one line per platform"
$BLOCK "cmd_install() — the account it pins" "spent_today() — today's spend is summed"
```

Esperado: FAIL nas asserções novas (`account-add` desconhecido, links em falta).

- [ ] **Step 5: O bloco de contas no motor**

Em `bin/agentloop`, logo a seguir ao fim da função `platform_jobs_on()` (a linha `}` que a fecha, antes de `platform_cli_name()`), inserir:

```bash
# --- accounts: which sign-in a run of a platform uses ---------------------------
# Claude Code and the Codex CLI keep one signed-in account per config
# directory; CLAUDE_CONFIG_DIR and CODEX_HOME are how each CLI is told which.
# A platform's accounts are the install's own -- `default`, never stored: the
# pin or ~/.claude, the engine's CODEX_HOME or ~/.codex -- plus the ones
# Settings registers in config/platforms.json under `accounts`, each
# {id, name, dir}. OpenCode has none: its credentials are the providers the
# operator configured in opencode itself.
ACCOUNTS_NONE_OPENCODE="OpenCode has no accounts — its credentials are the providers configured in opencode itself"

account_platform() { case "${1:-}" in anthropic|openai) return 0 ;; *) return 1 ;; esac; }
account_var() { case "${1:-}" in anthropic) printf 'CLAUDE_CONFIG_DIR' ;; openai) printf 'CODEX_HOME' ;; esac; }
account_cli_default() { case "${1:-}" in anthropic) printf '%s/.claude\n' "$HOME" ;; openai) printf '%s/.codex\n' "$HOME" ;; esac; }

account_norm_dir() { # account_norm_dir <text> -> the directory with ~ expanded and no trailing slash; rc 1 and nothing printed unless that is an absolute path
  local d
  d="$(expand_home "${1:-}")"
  while [ "${#d}" -gt 1 ] && [ "${d%/}" != "$d" ]; do d="${d%/}"; done
  case "$d" in /?*) printf '%s\n' "$d" ;; *) return 1 ;; esac
}

# The value the platform's variable carries for a directory. NOTHING is the
# CLI's own default directory, and means the variable is left unset: Claude
# Code names the Keychain entry it reads credentials from after a hash of the
# directory whenever CLAUDE_CONFIG_DIR is set at all, so an explicit
# CLAUDE_CONFIG_DIR=$HOME/.claude answers "not signed in" (measured, 2.1.280).
# Codex treats the two the same; one rule serves both.
account_env_value() { # account_env_value <platform> <dir> -> the normalized directory, or nothing for the CLI's own default directory (and for nothing given)
  local d
  d="$(account_norm_dir "${2:-}")" || return 0
  [ "$d" = "$(account_cli_default "$1")" ] && return 0
  printf '%s\n' "$d"
}

accounts_json() { # accounts_json <platform> -> the registered accounts as a JSON list: only well-formed {id,name,dir}, never one called default; [] for a platform that has none
  account_platform "${1:-}" || { printf '[]\n'; return 0; }
  platforms_json | "$JQ" -c --arg p "$1" '
    [ ((.platforms[$p].accounts // []) | if type == "array" then .[] else empty end)
      | objects
      | select((.id | type) == "string" and (.name | type) == "string" and (.dir | type) == "string")
      | select(.id != "" and .id != "default" and .name != "" and .dir != "")
      | {id, name, dir} ]'
}

account_known() { # account_known <platform> <id> -> 0 for `default`, and for an id registered on that platform
  [ "${2:-}" = "default" ] && return 0
  account_platform "${1:-}" || return 1
  accounts_json "$1" | "$JQ" -e --arg id "${2:-}" 'any(.[]; .id == $id)' >/dev/null 2>&1
}

account_ids_line() { # account_ids_line <platform> -> default and every registered id, comma-separated, for messages
  { printf 'default\n'; accounts_json "$1" | "$JQ" -r '.[].id'; } | tr '\n' ',' | sed 's/,$//; s/,/, /g'
}

account_default_dir() { # account_default_dir <platform> -> the Default account's directory: the install's pin or ~/.claude; the engine's own Codex home (CODEX_HOME, else ~/.codex)
  local d=""
  case "${1:-}" in
    anthropic) d="$(installed_config_dir)" ;;
    openai)    d="$CODEX_HOME_DIR" ;;
  esac
  if [ -n "$d" ]; then d="$(account_norm_dir "$d")" || d=""; fi
  [ -n "$d" ] || d="$(account_cli_default "${1:-}")"
  printf '%s\n' "$d"
}

account_field() { # account_field <platform> <id> <name|dir> -> that field; the Default is named Default, and its directory is account_default_dir
  if [ "${2:-}" = "default" ]; then
    case "${3:-}" in name) printf 'Default\n' ;; dir) account_default_dir "$1" ;; esac
    return 0
  fi
  accounts_json "$1" | "$JQ" -r --arg id "${2:-}" --arg f "${3:-}" 'first(.[] | select(.id == $id) | .[$f]) // empty'
}

account_env_dir() { # account_env_dir <platform> <id> -> what the platform's variable carries for a run on that account: nothing for the CLI's own directory
  account_env_value "$1" "$(account_field "$1" "$2" dir)"
}

account_slug() { # account_slug <name> -> the id a new account is given: lower case, each run outside [a-z0-9] one dash, no dash at either end, at most 40 characters; account when nothing is left
  local s
  s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' | cut -c1-40 | sed 's/-$//')"
  [ -n "$s" ] || s="account"
  printf '%s\n' "$s"
}

account_users() { # account_users <platform> <id> -> who is configured on that account, one per line: a job id, project:<name>, security:<name> -- switched on or not
  platforms_jq "" "" "" 'account_uses[] | select(.p == $p and .a == $a) | .who' -r --arg p "$1" --arg a "$2"
}

account_refusal() { # account_refusal <platform> <own-id> <name> <dir> -> one sentence when the account cannot be saved as given, nothing when it can; <own-id> is the account being edited ("" for a new one), whose name and directory do not count as taken
  local p="$1" own="$2" name="$3" dir="$4" nd taken
  [ -n "$name" ] || { printf 'an account needs a name'; return 0; }
  if [ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" = "default" ]; then
    printf "Default is the install's own account — choose another name"; return 0
  fi
  if accounts_json "$p" | "$JQ" -e --arg n "$name" --arg own "$own" \
       'any(.[]; .id != $own and (.name | ascii_downcase) == ($n | ascii_downcase))' >/dev/null 2>&1; then
    printf "an account named '%s' already exists on %s" "$name" "$p"; return 0
  fi
  [ -n "$dir" ] || { printf 'an account needs a directory'; return 0; }
  if ! nd="$(account_norm_dir "$dir")"; then
    printf "the directory must be absolute or start with ~/ (got '%s')" "$dir"; return 0
  fi
  if [ ! -d "$nd" ]; then
    if [ "$p" = "anthropic" ]; then
      printf '%s does not exist — create it by signing in: CLAUDE_CONFIG_DIR=%s claude auth login' "$nd" "$nd"
    else
      printf '%s does not exist — create it and sign in: mkdir -p %s && CODEX_HOME=%s codex login' "$nd" "$nd" "$nd"
    fi
    return 0
  fi
  if [ "$nd" = "$(account_default_dir "$p")" ]; then
    printf "%s is the Default account's directory" "$nd"; return 0
  fi
  taken="$(accounts_json "$p" | "$JQ" -r --arg own "$own" '.[] | select(.id != $own) | [.name, .dir] | @tsv' \
    | while IFS="$(printf '\t')" read -r tname tdir; do
        if [ "$(account_norm_dir "$tdir")" = "$nd" ]; then printf '%s' "$tname"; break; fi
      done)"
  if [ -n "$taken" ]; then
    printf "%s is already the directory of the account '%s'" "$nd" "$taken"; return 0
  fi
  return 0
}

account_add() { # account_add <platform> <name> <dir> -> the new account's id; rc 1 with the refusal on stdout
  local p="$1" name="$2" dir="$3" why id base n sdir
  why="$(account_refusal "$p" "" "$name" "$dir")"
  [ -z "$why" ] || { printf '%s\n' "$why"; return 1; }
  base="$(account_slug "$name")"; id="$base"; n=2
  while [ "$id" = "default" ] || account_known "$p" "$id"; do id="$base-$n"; n=$(( n + 1 )); done
  sdir="$dir"
  while [ "${#sdir}" -gt 1 ] && [ "${sdir%/}" != "$sdir" ]; do sdir="${sdir%/}"; done
  write_platforms --arg p "$p" --arg id "$id" --arg n "$name" --arg d "$sdir" '
    .platforms[$p] = ((.platforms[$p] // {enabled:false, bin:"", models:[]})
      | .accounts = ((if (.accounts | type) == "array" then .accounts else [] end) + [{id:$id, name:$n, dir:$d}]))'
  skills_link_into "$(account_norm_dir "$dir")/skills" install >/dev/null 2>&1 || true
  printf '%s\n' "$id"
}

account_edit() { # account_edit <platform> <id> <name> <dir> -> rc 1 with the refusal on stdout
  local p="$1" aid="$2" name="$3" dir="$4" why old sdir
  if [ "$aid" = "default" ]; then printf "the Default account is the install's own — it is not edited here\n"; return 1; fi
  account_known "$p" "$aid" || { printf "no account '%s' on %s\n" "$aid" "$p"; return 1; }
  why="$(account_refusal "$p" "$aid" "$name" "$dir")"
  [ -z "$why" ] || { printf '%s\n' "$why"; return 1; }
  old="$(account_norm_dir "$(account_field "$p" "$aid" dir)")"
  sdir="$dir"
  while [ "${#sdir}" -gt 1 ] && [ "${sdir%/}" != "$sdir" ]; do sdir="${sdir%/}"; done
  write_platforms --arg p "$p" --arg id "$aid" --arg n "$name" --arg d "$sdir" '
    .platforms[$p].accounts = [ .platforms[$p].accounts[] | if (type == "object" and .id == $id) then (. + {name:$n, dir:$d}) else . end ]'
  if [ "$old" != "$(account_norm_dir "$dir")" ]; then
    skills_link_into "$(account_norm_dir "$dir")/skills" install >/dev/null 2>&1 || true
  fi
  return 0
}

account_remove() { # account_remove <platform> <id> -> rc 1 with the refusal on stdout
  local p="$1" aid="$2" users
  if [ "$aid" = "default" ]; then printf "the Default account is the install's own — it cannot be removed\n"; return 1; fi
  account_known "$p" "$aid" || { printf "no account '%s' on %s\n" "$aid" "$p"; return 1; }
  users="$(account_users "$p" "$aid" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  if [ -n "$users" ]; then
    printf "'%s' is used by %s — move them to another account first\n" "$(account_field "$p" "$aid" name)" "$users"; return 1
  fi
  write_platforms --arg p "$p" --arg id "$aid" '
    .platforms[$p].accounts = [ .platforms[$p].accounts[] | select((type == "object" and .id == $id) | not) ]'
  return 0
}

account_check_sentence() { # account_check_sentence <platform> <id> -> signed in as <who> on anthropic, the CLI's own words on openai, else the reason it is not ready
  local j; j="$(platform_check "$1" "$2")"
  if [ "$(printf '%s' "$j" | "$JQ" -r .ready)" = "true" ]; then
    if [ "$1" = "anthropic" ]; then printf 'signed in as %s' "$(printf '%s' "$j" | "$JQ" -r .account)"
    else printf '%s' "$(printf '%s' "$j" | "$JQ" -r .account)"; fi
  else
    printf '%s' "$(printf '%s' "$j" | "$JQ" -r .reason)"
  fi
}

# Every account of a platform, the Default first, each with its live check and
# who is configured on it -- what Settings draws. The ids are collected before
# the loop: a CLI asked for its session inside a `while read` could eat the
# rest of the list from stdin.
platform_accounts_json() { # platform_accounts_json <platform> -> a JSON list
  local aid ids
  ids="default $(accounts_json "$1" | "$JQ" -r '.[].id' | tr '\n' ' ')"
  for aid in $ids; do
    "$JQ" -nc --arg id "$aid" --arg name "$(account_field "$1" "$aid" name)" \
      --arg dir "$(account_field "$1" "$aid" dir)" --arg adir "$(account_env_dir "$1" "$aid")" \
      --argjson check "$(platform_check "$1" "$aid" </dev/null)" \
      --argjson users "$(account_users "$1" "$aid" | "$JQ" -R . | "$JQ" -sc .)" '
      {id:$id, name:$name, dir:$dir, account_dir:$adir, builtin:($id == "default"),
       check:{ready:$check.ready, account:$check.account, reason:$check.reason},
       used_by:{jobs:[$users[] | select((startswith("project:") or startswith("security:")) | not)],
                projects:[$users[] | select(startswith("project:")) | ltrimstr("project:")],
                security:[$users[] | select(startswith("security:")) | ltrimstr("security:")]}}'
  done | "$JQ" -sc .
}
```

- [ ] **Step 6: A regra de resolução em jq**

Em `PLATFORMS_JQ`, imediatamente antes da aspa simples que fecha a string (a linha `'` a seguir à def `uses`), inserir:

```
  # The account a job, a project and a security block run under: their own,
  # else -- for a job or a block on the project's platform -- the project's,
  # else the Default. job_account (bash) is the same rule for one job.
  def dflt: if . == null or . == "" then "default" else . end;
  def project_platform($p): ((($p.platform // "") | if . == "" then "anthropic" else . end) | known);
  def job_account($j): if (($j.account // "") != "") then $j.account
                       elif ((($j.project // "") != "") and (job_platform($j) == project_platform(project($j.project))))
                       then (project($j.project).account | dflt)
                       else "default" end;
  def sec_account($p): if ((sec($p).account // "") != "") then sec($p).account
                       elif (sec_platform($p) == project_platform($p)) then ($p.account | dflt)
                       else "default" end;
  def account_uses: ([ ($jobs.jobs // [])[] | {who: .id, p: job_platform(.), a: job_account(.)} ]
                   + [ ($projects.projects // [])[] | select(type == "object") | {who: ("project:" + (.name // "")), p: project_platform(.), a: (.account | dflt)} ]
                   + [ ($projects.projects // [])[] | select(type == "object" and (.security | type) == "object") | {who: ("security:" + (.name // "")), p: sec_platform(.), a: sec_account(.)} ]);
```

- [ ] **Step 7: A verificação por conta**

Substituir a função `platform_check` inteira por:

```bash
platform_check() { # platform_check <platform> [account-id [account-dir]] -> one JSON object; always exits 0. The session checked is that account's -- the Default when none is named; a third argument is the directory to check exactly as given, empty for the CLI's own (what a resume passes, off the run it continues)
  local p="$1" bin src found=false ver="" vrc=0 acct="" reason="" ready=false supported=true
  local aid="${2:-default}" adir="" arefusal=""
  if ! platform_listed "$p"; then
    "$JQ" -nc --arg p "$p" '{platform:$p, supported:false, ready:false, bin:"", bin_found:false, bin_source:"", version:"", account:"", reason:("unknown platform " + $p)}'
    return 0
  fi
  # Whose session is asked for: the directory given (a resume), else the
  # account's (account_env_dir: empty is the CLI's own). An id Settings does
  # not have is not asked about at all -- the answer is that it is not one.
  if [ "$#" -ge 3 ]; then adir="${3:-}"
  elif account_platform "$p"; then
    if [ "$aid" = "default" ] || account_known "$p" "$aid"; then adir="$(account_env_dir "$p" "$aid")"
    else arefusal="account '$aid' is not an account of $p in Settings"; fi
  fi
  platform_planned "$p" && supported=false
  bin="$(platform_bin "$p")"; src="$(platform_bin_source "$p")"
  if [ -f "$bin" ] && [ -x "$bin" ]; then
    found=true
    # Bounded like every other CLI call here: a `--version` that never
    # answers (measured 34b: an OpenCode process can wait for ever) must not
    # hang the Settings page or a launch. The rc is read before `head`, which
    # would otherwise hide it behind its own.
    ver="$(run_bounded "$OPENCODE_DEADLINE" "$bin" --version 2>/dev/null)"; vrc=$?
    ver="$(printf '%s\n' "$ver" | head -1)"
  fi
  if [ "$found" = false ]; then
    reason="$(platform_cli_name "$p") not found at $bin — set the path in Settings (or AGENTLOOP_$(platform_cli_name "$p" | tr '[:lower:]' '[:upper:]')_BIN); install: $(platform_install_hint "$p")"
  elif [ "$vrc" -eq 124 ]; then
    ver=""
    reason="$(platform_cli_name "$p") --version timed out after ${OPENCODE_DEADLINE} s (the CLI hung)"
  elif [ -n "$arefusal" ]; then
    reason="$arefusal"
  else
    case "$p" in
      anthropic)
        local out rc
        if [ "$aid" != "default" ] && [ -n "$adir" ] && [ ! -d "$adir" ]; then
          # A registered account whose directory is gone has no session; the
          # login creates the directory again.
          reason="claude is not signed in in $adir (run: CLAUDE_CONFIG_DIR=$adir claude auth login)"
        else
          # The variable exactly as a run gets it: set to the account's own
          # directory, or GONE for the CLI's -- never pointed at ~/.claude,
          # which would read another Keychain entry (see account_env_value).
          if [ -n "$adir" ]; then out="$(CLAUDE_CONFIG_DIR="$adir" "$bin" auth status --json 2>/dev/null)"; rc=$?
          else out="$(env -u CLAUDE_CONFIG_DIR "$bin" auth status --json 2>/dev/null)"; rc=$?; fi
          if [ "$rc" -eq 0 ] && printf '%s' "$out" | "$JQ" -e '.loggedIn == true' >/dev/null 2>&1; then
            ready=true
            acct="$(printf '%s' "$out" | "$JQ" -r '[(.email // ""), ((.subscriptionType // "") | if . == "" then "" else . + " plan" end)] | map(select(. != "")) | join(" · ")' 2>/dev/null)"
            [ -n "$acct" ] || acct="signed in"
          else
            case "$out" in
              *loggedIn*)
                if [ -n "$adir" ]; then reason="claude is not signed in in $adir (run: CLAUDE_CONFIG_DIR=$adir claude auth login)"
                else reason="claude is not signed in (run: claude auth login)"; fi ;;
              *) # no `auth status` on this CLI (pre-2.1): the binary counts as ready, as it always did
                 ready=true; acct="unknown — claude auth status needs Claude Code 2.1+" ;;
            esac
          fi
        fi ;;
      openai)
        local line
        if [ "$aid" != "default" ] && [ -n "$adir" ] && [ ! -d "$adir" ]; then
          # The CLI refuses a CODEX_HOME that does not exist (measured, 0.153.4).
          reason="codex is not signed in in $adir (run: mkdir -p $adir && CODEX_HOME=$adir codex login)"
        elif [ -n "$adir" ] && line="$(CODEX_HOME="$adir" "$bin" login status 2>&1)"; then
          ready=true; acct="$(printf '%s\n' "$line" | head -1)"
        elif [ -z "$adir" ] && line="$(env -u CODEX_HOME "$bin" login status 2>&1)"; then
          ready=true; acct="$(printf '%s\n' "$line" | head -1)"
        elif [ -n "$adir" ]; then reason="codex is not signed in in $adir (run: CODEX_HOME=$adir codex login)"
        else reason="codex is not signed in (run: codex login)"; fi ;;
      opencode)
        # (the opencode branch exactly as it is today -- copy it unchanged)
        ;;
    esac
  fi
  "$JQ" -nc --arg p "$p" --argjson supported "$supported" --argjson ready "$ready" --arg bin "$bin" \
    --argjson found "$found" --arg src "$src" --arg ver "$ver" --arg acct "$acct" --arg reason "$reason" \
    --arg aid "$aid" --arg adisp "${adir:-$(account_cli_default "$p")}" \
    '{platform:$p, supported:$supported, ready:$ready, bin:$bin, bin_found:$found, bin_source:$src, version:$ver, account:$acct, reason:$reason, account_id:$aid, account_dir:$adisp}'
}
```

O ramo `opencode)` fica **exactamente** como está hoje (as linhas desde `      opencode)` até ao `fi ;;` que o fecha, com todos os comentários): o marcador acima só assinala o sítio. Não há `case` dentro de `$( )` nesta função.

Substituir `platform_ready`:

```bash
platform_ready() { # platform_ready <platform> [account-id [account-dir]] -> 0; or 1 with the reason on stdout (platform_check decides)
  local j; j="$(platform_check "$@")"
  [ "$(printf '%s' "$j" | "$JQ" -r '.ready')" = "true" ] && return 0
  printf '%s' "$(printf '%s' "$j" | "$JQ" -r '.reason')"
  return 1
}
```

- [ ] **Step 8: Os verbos**

Em `cmd_platform`, trocar a linha de assinatura e o `case "$verb"` de validação por:

```bash
cmd_platform() { # agentloop platform <check|enable|disable|set-bin|models|set-models|accounts|account-add|account-edit|account-remove> <platform> [...]
  local verb="${1:-}" p="${2:-}" j out rc list cur added removed id catalog
  case "$verb" in check|enable|disable|set-bin|models|set-models|accounts|account-add|account-edit|account-remove) ;;
    *) die "usage: agentloop platform <check|enable|disable|set-bin|models|set-models|accounts|account-add|account-edit|account-remove> <platform> [...]" ;; esac
```

trocar `    check) platform_check "$p" ;;` por `    check) platform_check "$p" ${3:+"$3"} ;;` e acrescentar, antes do `esac` final do `case "$verb"`, estes quatro ramos:

```bash
    accounts)
      account_platform "$p" || die "platform accounts: $ACCOUNTS_NONE_OPENCODE"
      platform_accounts_json "$p" ;;
    account-add)
      account_platform "$p" || die "platform account-add: $ACCOUNTS_NONE_OPENCODE"
      out="$(account_add "$p" "${3:-}" "${4:-}")" || die "platform account-add: $out"
      echo "account '${3:-}' added on $p (id $out) — $(account_check_sentence "$p" "$out")" ;;
    account-edit)
      account_platform "$p" || die "platform account-edit: $ACCOUNTS_NONE_OPENCODE"
      out="$(account_edit "$p" "${3:-}" "${4:-}" "${5:-}")" || die "platform account-edit: $out"
      echo "account '${4:-}' saved on $p — $(account_check_sentence "$p" "${3:-}")" ;;
    account-remove)
      account_platform "$p" || die "platform account-remove: $ACCOUNTS_NONE_OPENCODE"
      out="$(account_remove "$p" "${3:-}")" || die "platform account-remove: $out"
      echo "account '${3:-}' removed from $p" ;;
```

Em `usage()`, substituir as três linhas de `agentloop platform check|enable|…` por:

```
  agentloop platform check|enable|disable|set-bin|models|set-models <platform> [path]
                            what Settings › Platforms does: probe a CLI, switch a platform on or off,
                            point at its binary, refresh its catalog, choose its models (JSON list on stdin)
  agentloop platform accounts|account-add|account-edit|account-remove <platform> [id] [name] [dir]
                            the sign-ins a platform runs under, beside the install's Default:
                            list them with their sessions, register one (name, directory), rename
                            or move one, remove one nothing uses; `platform check <platform> <id>`
                            checks one account's session
```

- [ ] **Step 9: As skills em cada conta**

Em `bin/agentloop`, logo a seguir à linha `CODEX_SKILLS="$CODEX_HOME_DIR/skills"`, inserir:

```bash
# Claude Code reads the user skills of the config directory it runs with
# (join(CLAUDE_CONFIG_DIR ?? ~/.claude, "skills"), read off the 2.1.280
# binary), and Codex those of its CODEX_HOME. So the skills are linked into
# every account directory as well: a run on another account otherwise reads
# prompts that make skills mandatory which that directory does not have.
skills_roots() { # skills_roots -> one directory per line: the Claude root, the Codex root when its home exists, then the skills directory of every other account directory that exists -- never one this tool would have to create
  local p aid d
  {
    printf '%s\n' "$USER_SKILLS"
    [ -d "$CODEX_HOME_DIR" ] && printf '%s\n' "$CODEX_SKILLS"
    for p in anthropic openai; do
      for aid in default $(accounts_json "$p" | "$JQ" -r '.[].id' 2>/dev/null); do
        d="$(account_env_dir "$p" "$aid")"
        [ -n "$d" ] && [ -d "$d" ] || continue
        printf '%s/skills\n' "$d"
      done
    done
  } | awk '!seen[$0]++'
}

skills_missing() { # skills_missing <root> -> how many of this repo's skills are not linked there; reads only, creates nothing
  local n=0 target name link
  for target in "$SKILLS_DIR"/*/; do
    [ -d "$target" ] || continue
    name="$(basename "$target")"; link="$1/$name"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "${target%/}" ]; then continue; fi
    n=$(( n + 1 ))
  done
  printf '%s\n' "$n"
}
```

Substituir o corpo de `cmd_skills` por:

```bash
cmd_skills() { # agentloop skills [install]
  local action="${1:-status}" _skills_pending=0 _n root roots
  [ -d "$SKILLS_DIR" ] || die "no skills/ directory in $BASE_DIR"
  roots="$(skills_roots)"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    printf '  %s\n' "$root"
    _n=0; skills_link_into "$root" "$action" || _n=$?
    _skills_pending=$(( _skills_pending + _n ))
    if [ "$root" = "$USER_SKILLS" ]; then
      echo "  OpenCode reads ~/.claude/skills too (measured), so the same link serves both CLIs"
    fi
  done <<EOF
$roots
EOF
  # Only nag when something is actually out of place; a clean status that still
  # tells you to run install is noise that trains you to ignore the output.
  if [ "$action" != "install" ] && [ "$_skills_pending" -gt 0 ]; then
    echo "  (run \`agentloop skills install\` to link them)"
  fi
}
```

Em `cmd_install`, trocar a linha `  echo "Skills (linked into ~/.claude/skills — and into ~/.codex/skills when the Codex CLI has a home):"` por `  echo "Skills (linked into ~/.claude/skills, into ~/.codex/skills when the Codex CLI has a home, and into every account directory Settings registers):"`.

- [ ] **Step 10: Correr os blocos — devem passar**

Os três comandos do Step 4. Esperado: `fail=0` em todos. Correr também, porque tocam em `platform_check`:

```bash
$BLOCK "platform_bin() / platform_check()" "the OpenCode catalog — resolve_models_opencode"
$BLOCK "agentloop platform … — the commands the Settings page is made of" "resolve_pricing_openai() — the price table refreshes itself"
$BLOCK "status_platforms_block() — one line per platform" "cmd_resolve_pricing() — will not race"
```

Esperado: `fail=0`.

- [ ] **Step 11: CHANGELOG**

Em `CHANGELOG.md`, logo a seguir a `## [Unreleased]` e à linha `### Added` que se lhe segue, inserir como primeiro ponto:

```markdown
- **Accounts per platform.** A client who signs in to several Claude and
  Codex accounts — one config directory each — registers them in Settings ›
  Platforms beside the install's own Default: `agentloop platform
  accounts|account-add|account-edit|account-remove <platform>`, and `platform
  check <platform> <id>` checks that account's own directory. The agentloop
  skills are linked into every account directory too, the pinned one
  included: Claude Code reads the `skills/` of the config directory it runs
  with, so a run on any other account read prompts naming mandatory skills it
  could not load.
```

- [ ] **Step 12: Commit**

```bash
/usr/bin/git add bin/agentloop test/fake-claude test/fake-codex test/selftest.sh CHANGELOG.md
/usr/bin/git commit -m "feat(engine): Settings registers the accounts a platform can run under, beside its Default

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: A conta escolhida em job, projecto e bloco — resolução, escrita e migração

**Files:**
- Modify: `bin/agentloop` (`job_account` a seguir a `job_platform`; `cmd_set_field`; `cmd_create`; `cmd_project_set`; `security_derived_jobs`; `accounts_migrate_legacy`; `legacy_config_dir_warning`; `cmd_install`; `usage()`)
- Modify: `test/selftest.sh`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: tudo o que a Task 1 produz.
- Produces: `job_account <id>` (imprime `default` ou um id); `set-field <job> account` (vazio limpa); `create` e `project-set` aceitam `account` / `security.account`; os jobs derivados levam sempre `account`; `accounts_migrate_legacy` (uma linha por conversão ou por campo deixado); a frase nova de `legacy_config_dir_warning`.

- [ ] **Step 1: Escrever os testes (falham)**

Em `test/selftest.sh`, **apagar** o bloco inteiro que começa em `  echo "claude_config_dir — no longer a project's or a block's to set: ignored, and said"` e acaba na linha `    && ok "and the saved project carries the field at neither level" || bad "saved: $("$JQ" -c '.projects[0]' "$ccd/cfg/projects.json")"` (o que vem a seguir, `# The close used to overwrite the row unconditionally…`, fica onde está e passa a pertencer ao bloco `security_close_analysis()` acima dele).

Depois, imediatamente antes da linha que começa por `  echo "resolve_pricing_openai() — the price table refreshes itself` (a seguir ao bloco da Task 1), inserir estes três blocos, por esta ordem:

```bash
  echo "claude_config_dir — install turns what is left of it into accounts"
  local ccd="$tmp/ccd" _mig
  mkdir -p "$ccd/cfg" "$ccd/data" "$ccd/fakehome/.claude" "$ccd/old-acct"
  cat > "$ccd/cfg/projects.json" <<JSON
{"projects":[{"name":"Old1","cwd":"$ccd","claude_config_dir":"$ccd/old-acct/"},
             {"name":"Old2","cwd":"$ccd","security":{"enabled":false,"claude_config_dir":"$ccd/old-acct"}},
             {"name":"Old3","cwd":"$ccd","claude_config_dir":"~/.claude"},
             {"name":"Old4","cwd":"$ccd","platform":"openai","claude_config_dir":"$ccd/old-acct"},
             {"name":"Old5","cwd":"$ccd","claude_config_dir":"$ccd/missing"}]}
JSON
  printf '{"jobs":[]}\n' > "$ccd/cfg/jobs.json"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"]},"openai":{"enabled":true,"bin":"","models":["gpt-a"]}}}\n' > "$ccd/cfg/platforms.json"
  ccd_env() {
    HOME="$ccd/fakehome"; PLIST_PATH=/nonexistent; AGENTLOOP_CLAUDE_CONFIG_DIR=""
    CONFIG_DIR="$ccd/cfg"; PROJECTS_FILE="$ccd/cfg/projects.json"; JOBS_FILE="$ccd/cfg/jobs.json"
    PLATFORMS_FILE="$ccd/cfg/platforms.json"; DATA_DIR="$ccd/data"
  }
  _mig="$( ( ccd_env; accounts_migrate_legacy ) 2>&1 )"
  case "$_mig" in *"registered the Claude account 'old-acct' ($ccd/old-acct) from projects.json"*) ok "a directory no account has becomes one, named after the directory" ;; *) bad "migration: $_mig" ;; esac
  [ "$("$JQ" -c '[.projects[] | {n: .name, a: (.account // null), s: ((.security // {}).account // null), c: (has("claude_config_dir") or ((.security // {}) | has("claude_config_dir")))}]' "$ccd/cfg/projects.json")" \
      = '[{"n":"Old1","a":"old-acct","s":null,"c":false},{"n":"Old2","a":null,"s":"old-acct","c":false},{"n":"Old3","a":null,"s":null,"c":false},{"n":"Old4","a":null,"s":null,"c":true},{"n":"Old5","a":null,"s":null,"c":true}]' ] \
    && ok "each level takes the account (the Default's own directory takes nothing), and the old field goes" \
    || bad "migrated: $("$JQ" -c '.projects' "$ccd/cfg/projects.json")"
  case "$_mig" in *"claude_config_dir on Old4 (project) left in place — that level runs on openai"*) ok "a level that does not run on Anthropic keeps the field, and says why" ;; *) bad "Old4: $_mig" ;; esac
  case "$_mig" in *"claude_config_dir on Old5 (project) left in place — $ccd/missing does not exist"*) ok "and so does a directory that is gone" ;; *) bad "Old5: $_mig" ;; esac
  got="$( ( ccd_env; legacy_config_dir_warning ) )"
  case "$got" in
    *"WARNING: projects.json: claude_config_dir on Old4 is not read — accounts live in Settings › Platforms; pick one in the project editor"*)
      ok "status and install still name what the migration could not convert" ;;
    *) bad "warning: '$got'" ;;
  esac
  [ -z "$( ( ccd_env; accounts_migrate_legacy ) 2>&1 | grep -v 'left in place' )" ] \
    && ok "a second pass converts nothing twice" || bad "second pass: $( ( ccd_env; accounts_migrate_legacy ) 2>&1 )"
```

```bash
  echo "job_account() — its own, else its project's on the same platform, else the Default"
  local ja="$tmp/jacct"; mkdir -p "$ja/a" "$ja/b" "$ja/c" "$ja/prechecks"
  cat > "$ja/platforms.json" <<JSON
{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-opus-5"],"accounts":[{"id":"a","name":"A","dir":"$ja/a"},{"id":"b","name":"B","dir":"$ja/b"}]},
              "openai":{"enabled":true,"bin":"","models":["gpt-5.6-sol"],"accounts":[{"id":"c","name":"C","dir":"$ja/c"}]}}}
JSON
  cat > "$ja/projects.json" <<'JSON'
{"projects":[{"name":"PA","account":"a","security":{"enabled":false,"account":"b"}},
             {"name":"PN"},
             {"name":"PO","platform":"openai","account":"c"},
             {"name":"PS","account":"a","security":{"enabled":true,"model":"claude-opus-5"}},
             {"name":"PX","account":"a","security":{"enabled":true,"platform":"openai","model":"gpt-5.6-sol"}},
             {"name":"PZ","security":{"enabled":true,"model":"claude-opus-5","account":"zz"}}]}
JSON
  cat > "$ja/jobs.json" <<'JSON'
{"jobs":[{"id":"own","project":"PA","account":"b","prompt":"x"},
         {"id":"inherits","project":"PA","prompt":"x"},
         {"id":"explicit-same","project":"PA","platform":"anthropic","prompt":"x"},
         {"id":"other-platform","project":"PA","platform":"openai","prompt":"x"},
         {"id":"none","project":"PN","prompt":"x"},
         {"id":"loose","prompt":"x"},
         {"id":"codex-inherits","project":"PO","prompt":"x"}]}
JSON
  printf '{"resolved":{},"openai":{"at":1,"source":"fixture","models":[{"slug":"gpt-5.6-sol","visibility":"list","priority":1,"efforts":["low"],"default_effort":"low","deprecated_by":"","retires_at":""}]}}\n' > "$ja/models.json"
  ja_env() { PLATFORMS_FILE="$ja/platforms.json"; PROJECTS_FILE="$ja/projects.json"; JOBS_FILE="$ja/jobs.json"
             MODELS_FILE="$ja/models.json"; CONFIG_DIR="$ja"; HOME="$ja"; PLIST_PATH=/nonexistent; AGENTLOOP_CLAUDE_CONFIG_DIR=""; }
  got="$( ja_env; for j in own inherits explicit-same other-platform none loose codex-inherits; do printf '%s=%s ' "$j" "$(job_account "$j")"; done )"
  [ "$got" = "own=b inherits=a explicit-same=a other-platform=default none=default loose=default codex-inherits=c " ] \
    && ok "job_account: its own; the project's on the same platform, whether or not the job names it; else default" || bad "job_account: $got"
  # PX's own platform is unset (anthropic) and its account is a; PS's block
  # inherits a (same platform); PX's block runs on openai, so it does not.
  [ "$( ja_env; account_users anthropic a | tr '\n' ' ' )" = "inherits explicit-same project:PA project:PS project:PX security:PS " ] \
    && ok "account_users follows the same rule: the jobs, then the projects, then the blocks" || bad "users of a: $( ja_env; account_users anthropic a | tr '\n' ' ' )"
  [ "$( ja_env; account_users anthropic b | tr '\n' ' ' )" = "own security:PA " ] \
    && ok "and counts a security block by the account it resolves to" || bad "users of b: $( ja_env; account_users anthropic b | tr '\n' ' ' )"
  [ "$( ja_env; job_get "$(security_job_id PS)" '.account' '' )" = "a" ] \
    && ok "an analysis on the project's platform inherits the project's account" || bad "derived PS: $( ja_env; job_get "$(security_job_id PS)" '.account' '' )"
  [ "$( ja_env; job_get "$(security_job_id PX)" '.account' '' )" = "default" ] \
    && ok "one on another platform runs on that platform's Default" || bad "derived PX: $( ja_env; job_get "$(security_job_id PX)" '.account' '' )"
  [ "$( ja_env; job_get "$(security_job_id PZ)" '.account' '' 2>/dev/null )" = "default" ] \
    && ok "an account the platform does not have falls back to the Default" || bad "derived PZ: $( ja_env; job_get "$(security_job_id PZ)" '.account' '' 2>&1 )"

  echo "set-field, create and project-set — the account is one of the level's own platform"
  out="$( (ja_env; printf 'b' | cmd_set_field inherits account) 2>&1 )"; rc=$?
  [ "$rc" -eq 0 ] && [ "$( ja_env; job_get inherits '.account' '' )" = "b" ] \
    && ok "set-field account takes an id of the job's platform" || bad "set-field b: rc=$rc $out"
  out="$( (ja_env; printf 'c' | cmd_set_field inherits account) 2>&1 )"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "account 'c' is not an account of anthropic — anthropic has: default, a, b" ] \
    && ok "and refuses one of another platform, naming what this one has" || bad "set-field c: rc=$rc $out"
  ( ja_env; printf '' | cmd_set_field inherits account ) >/dev/null 2>&1
  [ -z "$( ja_env; job_get inherits '.account' '' )" ] && ok "empty clears it: the job inherits again" || bad "not cleared"
  out="$( (ja_env; printf 'openai' | cmd_set_field own platform) 2>&1 )"; rc=$?
  case "$out" in *"account 'b' is not an account of openai — cleared, the job inherits"*)
      [ -z "$( ja_env; job_get own '.account' '' )" ] && ok "a platform change clears an account the new platform does not have, and says so" || bad "account survived" ;;
    *) bad "platform change: rc=$rc $out" ;; esac
  out="$( (ja_env; printf '{"id":"made","project":"PA","account":"c","prompt":"x"}' | cmd_create) 2>&1 )"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "create: account 'c' is not an account of anthropic — anthropic has: default, a, b" ] \
    && ok "create refuses an account of another platform" || bad "create c: rc=$rc $out"
  out="$( (ja_env; printf '{"id":"made","project":"PA","account":"b","prompt":"x"}' | cmd_create) 2>&1 )"; rc=$?
  [ "$rc" -eq 0 ] && [ "$( ja_env; job_get made '.account' '' )" = "b" ] \
    && ok "and keeps one of its own" || bad "create b: rc=$rc $out"
  out="$( (ja_env; printf '{"name":"PA","account":"zz"}' | cmd_project_set) 2>&1 )"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "project-set: account 'zz' is not an account of anthropic — anthropic has: default, a, b" ] \
    && ok "project-set refuses an account the platform does not have" || bad "project-set zz: rc=$rc $out"
  out="$( (ja_env; printf '{"name":"PA","security":{"account":"c"}}' | cmd_project_set) 2>&1 )"; rc=$?
  [ "$rc" -ne 0 ] && [ "$out" = "project-set: security.account 'c' is not an account of anthropic — anthropic has: default, a, b" ] \
    && ok "and a block account the block's platform does not have" || bad "project-set sec c: rc=$rc $out"
  out="$( (ja_env; printf '{"name":"PA","platform":"openai"}' | cmd_project_set) 2>&1 )"; rc=$?
  case "$out" in *"account 'a' is not an account of openai — cleared, the project runs on the Default account"*"security.account 'b' is not an account of openai — cleared, the analysis inherits"*)
      "$JQ" -e '.projects[] | select(.name == "PA") | (has("account") | not) and ((.security | has("account")) | not)' "$ja/projects.json" >/dev/null 2>&1 \
        && ok "a platform change clears the stored accounts it leaves behind, at both levels, and says so" || bad "stale accounts kept: $("$JQ" -c '.projects[0]' "$ja/projects.json")" ;;
    *) bad "project platform change: rc=$rc $out" ;; esac
  out="$( (ja_env; printf '{"name":"PO","security":{"account":"c"}}' | cmd_project_set) 2>&1 )"; rc=$?
  [ "$rc" -eq 0 ] && [ "$( ja_env; security_get PO '.account' '' )" = "c" ] \
    && ok "a block that inherits the project's openai takes an openai account" || bad "PO block: rc=$rc $out"
```

Ajustar ainda o bloco `cmd_install() — the account it pins …` (a subshell que chama `cmd_install`): a seguir à linha `    TICK_LOG="$tmp/inst/data/tick.log"`, inserir

```bash
    # install now converts projects.json's claude_config_dir: never the real file.
    PROJECTS_FILE="$tmp/inst/config/projects.json"; JOBS_FILE="$tmp/inst/config/jobs.json"
    printf '{"projects":[]}\n' > "$PROJECTS_FILE"; printf '{"jobs":[]}\n' > "$JOBS_FILE"
```

- [ ] **Step 2: Correr — devem falhar**

```bash
$BLOCK "claude_config_dir — install turns what is left" "resolve_pricing_openai() — the price table refreshes itself"
```

(corre os três blocos novos, que são autónomos). Esperado: FAIL — `job_account` e `accounts_migrate_legacy` não existem, `set-field account` é desconhecido.

- [ ] **Step 3: `job_account`**

Em `bin/agentloop`, logo a seguir à função `job_platform()`, inserir:

```bash
# job_account <id> -> the account a run of the job signs in as (see the
# accounts block): its own `account`, else its project's when the job runs on
# the project's platform -- whether or not the job names that platform itself
# -- else default. PLATFORMS_JQ's job_account is the same rule, for counting.
job_account() { # job_account <id>
  local a proj pp
  a="$(job_get "$1" '.account' '')"
  case "$a" in ''|null) ;; *) printf '%s\n' "$a"; return 0 ;; esac
  proj="$(job_get "$1" '.project' '')"
  case "$proj" in ''|null) printf 'default\n'; return 0 ;; esac
  pp="$(project_get "$proj" '.platform' 'anthropic')"
  case "$pp" in ''|null) pp="anthropic" ;; esac
  platform_known "$pp" || pp="anthropic"
  if [ "$(job_platform "$1")" = "$pp" ]; then
    a="$(project_get "$proj" '.account' '')"
    case "$a" in ''|null) a="default" ;; esac
    printf '%s\n' "$a"; return 0
  fi
  printf 'default\n'
}
```

- [ ] **Step 4: `set-field`**

Em `cmd_set_field`, no ramo `platform)`, substituir o `fi ;;` que fecha o último `if` (o da reescrita de `permission_mode`) por:

```bash
      fi
      # The account is one of a platform's too: an own account the new
      # platform does not have is cleared, and the job inherits.
      cur="$(job_get "$id" '.account' '')"
      if [ -n "$cur" ] && [ "$cur" != "null" ] && ! account_known "$eff" "$cur"; then
        write_jobs --arg id "$id" '.jobs = [.jobs[] | if .id == $id then del(.account) else . end]'
        echo "account '$cur' is not an account of $eff — cleared, the job inherits"
      fi ;;
```

e, a seguir ao ramo `platform)`, acrescentar:

```bash
    account)
      # Which of the platform's accounts the job signs in as. Empty clears it:
      # the job then inherits its project's when it runs on the project's
      # platform, else the Default (job_account).
      local p
      p="$(job_platform "$id")"
      if [ -z "$value" ]; then
        write_jobs --arg id "$id" '.jobs = [.jobs[] | if .id == $id then del(.account) else . end]'
      else
        account_known "$p" "$value" || die "account '$value' is not an account of $p — $p has: $(account_ids_line "$p")"
        write_jobs --arg id "$id" --arg v "$value" '.jobs = [.jobs[] | if .id == $id then .account = $v else . end]'
      fi ;;
```

Em `usage()`, trocar `platform|model|max_budget_usd|timeout_seconds|` por `platform|account|model|max_budget_usd|timeout_seconds|`.

- [ ] **Step 5: `create`**

Em `cmd_create`, logo a seguir à linha `  platform_usable "$cplat" || die "create: $cplat is not enabled in Settings — enable it there, or: agentloop platform enable $cplat"`, inserir:

```bash
  local cacct
  cacct="$(echo "$partial" | "$JQ" -r '.account // ""')"
  if [ -n "$cacct" ] && ! account_known "$cplat" "$cacct"; then
    die "create: account '$cacct' is not an account of $cplat — $cplat has: $(account_ids_line "$cplat")"
  fi
```

- [ ] **Step 6: `project-set`**

Em `cmd_project_set`, substituir as linhas desde `  # The account is the platform's now (see Settings): a claude_config_dir sent` até ao `fi` que fecha o `if projects_json … any(.projects[]; .name==$n)` (inclusive) por:

```bash
  # The account each level signs in as has to be one of that level's own
  # platform -- judged on the project as it will be once this save merges
  # (jq `. * $p`). A value SENT that is not one is refused; one only STORED
  # that a platform change leaves behind is cleared after the save, and said.
  local merged mp msp ma msa drop=""
  merged="$(projects_json | "$JQ" -c --arg n "$name" --argjson p "$partial" '([.projects[] | select(.name == $n)] | first // {}) * $p')"
  mp="$(echo "$merged" | "$JQ" -r '.platform // ""')"; [ -n "$mp" ] || mp="anthropic"; platform_known "$mp" || mp="anthropic"
  msp="$(echo "$merged" | "$JQ" -r '((.security | objects) // {}).platform // ""')"; [ -n "$msp" ] || msp="$mp"; platform_known "$msp" || msp="anthropic"
  ma="$(echo "$merged" | "$JQ" -r '.account // ""')"
  msa="$(echo "$merged" | "$JQ" -r '((.security | objects) // {}).account // ""')"
  if [ -n "$ma" ] && ! account_known "$mp" "$ma"; then
    if echo "$partial" | "$JQ" -e 'has("account")' >/dev/null 2>&1; then
      die "project-set: account '$ma' is not an account of $mp — $mp has: $(account_ids_line "$mp")"
    fi
    drop="$drop project"
  fi
  if [ -n "$msa" ] && ! account_known "$msp" "$msa"; then
    if echo "$partial" | "$JQ" -e '((.security | objects) // {}) | has("account")' >/dev/null 2>&1; then
      die "project-set: security.account '$msa' is not an account of $msp — $msp has: $(account_ids_line "$msp")"
    fi
    drop="$drop security"
  fi
  if projects_json | "$JQ" -e --arg n "$name" 'any(.projects[]; .name==$n)' >/dev/null 2>&1; then
    write_projects --arg n "$name" --argjson p "$partial" \
      '.projects = [.projects[] | if .name==$n then (. * $p) else . end]'
  else
    write_projects --argjson p "$partial" '.projects += [$p]'
  fi
  case "$drop" in *project*)
    write_projects --arg n "$name" '.projects = [.projects[] | if .name == $n then del(.account) else . end]'
    echo "account '$ma' is not an account of $mp — cleared, the project runs on the Default account" ;;
  esac
  case "$drop" in *security*)
    write_projects --arg n "$name" '.projects = [.projects[] | if .name == $n and (.security | type) == "object" then .security |= del(.account) else . end]'
    echo "security.account '$msa' is not an account of $msp — cleared, the analysis inherits" ;;
  esac
```

- [ ] **Step 7: os jobs derivados**

Em `security_derived_jobs`, logo a seguir ao `fi` que fecha o `if ! platform_permission_ok "$splat" "$perm"; then … fi`, inserir:

```bash
    # The account the analysis signs in as: the block's own, else the
    # project's when the analysis runs on the project's platform, else the
    # Default -- job_account's rule, settled here because the derived job is
    # the only place it can travel, and always written ON the job, so the job
    # never re-inherits the project's when the block said Default. One the
    # platform does not have falls back to the Default, with the warning the
    # other fallbacks give.
    local sacct pplat
    sacct="$(security_get "$project" '.account' '')"
    if [ -z "$sacct" ]; then
      pplat="$(project_get "$project" '.platform' 'anthropic')"
      case "$pplat" in ''|null) pplat="anthropic" ;; esac
      platform_known "$pplat" || pplat="anthropic"
      if [ "$splat" = "$pplat" ]; then
        sacct="$(project_get "$project" '.account' '')"
        case "$sacct" in null) sacct="" ;; esac
      fi
    fi
    [ -n "$sacct" ] || sacct="default"
    if ! account_known "$splat" "$sacct"; then
      security_warn "security: project '$project' names an account $splat does not have ('$sacct') -- using the Default account"
      sacct="default"
    fi
```

e, na chamada `elem="$("$JQ" -nc …`, acrescentar `--arg account "$sacct" \` à lista de argumentos (a seguir a `--arg perm "$perm" \`) e `account:$account,` ao objecto, a seguir a `platform:$platform,`.

- [ ] **Step 8: A migração do `claude_config_dir`**

Substituir a função `legacy_config_dir_warning()` inteira por:

```bash
legacy_config_dir_warning() { # one line per project or security block still carrying claude_config_dir: install converts what it can, and this names the rest
  [ -f "$PROJECTS_FILE" ] || return 0
  "$JQ" -r '
    .projects[]? | select(type == "object")
    | (.claude_config_dir // "") as $a | (((.security | objects) // {}).claude_config_dir // "") as $b
    | select($a != "" or $b != "") | .name' "$PROJECTS_FILE" 2>/dev/null \
  | while IFS= read -r n; do
      printf "WARNING: projects.json: claude_config_dir on %s is not read — accounts live in Settings › Platforms; pick one in the project editor\n" "$n"
    done
}
```

e acrescentar, logo a seguir:

```bash
# The per-project account before accounts: a directory written into
# projects.json, read by no version since the account became the platform's.
# install turns each one into an account -- the Default when it is the
# Default's directory, the registered account that has it, or a new one named
# after the directory -- and sets it on the level that carried it. A level
# that does not run on Anthropic, or a directory that is gone, keeps the
# field, said here and warned about by status.
accounts_migrate_legacy() { # accounts_migrate_legacy -> one line per level converted or left
  [ -f "$PROJECTS_FILE" ] || return 0
  local rows name level dir plat nd aid nm
  rows="$("$JQ" -r '.projects[]? | select(type == "object") | .name as $n
      | ( ((.claude_config_dir // "") | select(type == "string" and . != "") | [$n, "project", .]),
          ((((.security | objects) // {}).claude_config_dir // "") | select(type == "string" and . != "") | [$n, "security", .]) )
      | @tsv' "$PROJECTS_FILE" 2>/dev/null)"
  [ -n "$rows" ] || return 0
  while IFS="$(printf '\t')" read -r name level dir; do
    [ -n "$name" ] || continue
    if [ "$level" = "project" ]; then plat="$(project_get "$name" '.platform' 'anthropic')"
    else
      plat="$(security_get "$name" '.platform' '')"
      [ -n "$plat" ] || plat="$(project_get "$name" '.platform' 'anthropic')"
    fi
    case "$plat" in ''|null) plat="anthropic" ;; esac
    platform_known "$plat" || plat="anthropic"
    if [ "$plat" != "anthropic" ]; then
      echo "projects.json: claude_config_dir on $name ($level) left in place — that level runs on $plat, and a Claude account signs in Anthropic runs only"
      continue
    fi
    if ! nd="$(account_norm_dir "$dir")"; then
      echo "projects.json: claude_config_dir on $name ($level) left in place — '$dir' is not an absolute directory"; continue
    fi
    if [ "$nd" = "$(account_default_dir anthropic)" ]; then aid="default"
    else
      aid="$(accounts_json anthropic | "$JQ" -r '.[] | [.id, .dir] | @tsv' \
        | while IFS="$(printf '\t')" read -r i d; do
            if [ "$(account_norm_dir "$d")" = "$nd" ]; then printf '%s' "$i"; break; fi
          done)"
      if [ -z "$aid" ]; then
        if [ ! -d "$nd" ]; then
          echo "projects.json: claude_config_dir on $name ($level) left in place — $nd does not exist"; continue
        fi
        nm="$(basename "$nd" | sed 's/^\.//')"
        if ! aid="$(account_add anthropic "$nm" "$nd")"; then
          if ! aid="$(account_add anthropic "$nd" "$nd")"; then
            echo "projects.json: claude_config_dir on $name ($level) left in place — $aid"; continue
          fi
        fi
        echo "registered the Claude account '$(account_field anthropic "$aid" name)' ($nd) from projects.json"
      fi
    fi
    if [ "$level" = "project" ]; then
      write_projects --arg n "$name" --arg a "$aid" '.projects = [.projects[] | if .name == $n
          then ((if ((.account // "") == "" and $a != "default") then .account = $a else . end) | del(.claude_config_dir))
          else . end]'
    else
      write_projects --arg n "$name" --arg a "$aid" '.projects = [.projects[] | if .name == $n and (.security | type) == "object"
          then .security |= ((if ((.account // "") == "" and $a != "default") then .account = $a else . end) | del(.claude_config_dir))
          else . end]'
    fi
    echo "projects.json: claude_config_dir on $name ($level) is now the account '$aid'"
  done <<EOF
$rows
EOF
}
```

Em `cmd_install`, logo antes da linha `  legacy_env_warnings` que abre os avisos no fim da função, inserir `  accounts_migrate_legacy`.

- [ ] **Step 9: Correr — devem passar**

O comando do Step 2, e ainda:

```bash
$BLOCK "accounts — the sign-ins Settings registers" "claude_config_dir — install turns what is left"
$BLOCK "cmd_install() — the account it pins" "spent_today() — today's spend is summed"
$BLOCK "configuration — platform is a field" "PLATFORMS_JQ — every platform the registry runs"
$BLOCK "security_derived_jobs() — the block's platform" "model_alias_baseline() — the init event"
```

Esperado: `fail=0` em todos.

- [ ] **Step 10: CHANGELOG**

Acrescentar ao ponto aberto na Task 1 (a seguir à sua última frase):

```markdown
  A job, a project and a security block pick one (`account`): a job inherits
  its project's when both run on the same platform, an analysis its
  project's on the same terms, and `set-field`, `create` and `project-set`
  refuse an account the platform does not have — a platform change clears
  one it leaves behind, and says so. `install` turns a `claude_config_dir`
  still in `projects.json` into an account.
```

- [ ] **Step 11: Commit**

```bash
/usr/bin/git add bin/agentloop test/selftest.sh CHANGELOG.md
/usr/bin/git commit -m "feat(engine): a job, a project and a security block pick the account they run under

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: O lançamento na conta — portas, ambiente, precheck, journal, resume e rollout

**Files:**
- Modify: `bin/agentloop` (`account_export`, `journal_account_of_session`, `record_run`, `run_record_stopped_early`, `run_refusals`, `run_job`, `cmd_precheck`, `cmd_check`, `platform_finish`, `openai_rollout_for`)
- Modify: `test/fake-codex`
- Modify: `test/e2e.test.sh`
- Modify: `test/selftest.sh`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `job_account`, `account_env_dir`, `account_known`, `account_field`, `account_platform`, `account_var`, `account_cli_default`, `account_env_value`, `platform_ready <p> [id [pasta]]`.
- Produces: `account_export <p> <account_dir>`; `journal_account_of_session <sid>` (imprime `<conta>\t<pasta>` ou nada); `record_run` com os argumentos 20 (`account`) e 21 (`account_dir`) — as chaves só entram no registo quando o 20 não é vazio; `run_refusals` com os argumentos 9 (`account`), 10 (`account_dir`) e 11 (`resume_sid`); `platform_finish <p> <stream> <sid> [job] [run_cwd] [codex_home]`; `openai_rollout_for <thread> [codex_home]`; os ficheiros `$slot/account` e `$slot/account_dir`.

- [ ] **Step 1: O fake do Codex grava a conta**

Em `test/fake-codex`, logo a seguir ao bloco `if [ -n "${FAKE_ARGV_OUT:-}" ]; then … fi`, inserir:

```bash
# The account this launch signs in as travels in the environment, where the
# argv cannot show it: CODEX_HOME, or an empty line when it has none.
if [ -n "${FAKE_ACCOUNT_OUT:-}" ]; then
  printf '%s\n' "${CODEX_HOME:-}" > "$FAKE_ACCOUNT_OUT"
fi
```

e, no cabeçalho, a seguir a `FAKE_PROMPT_OUT`:

```bash
#   FAKE_ACCOUNT_OUT       record the CODEX_HOME this launch runs with (empty line when unset)
```

- [ ] **Step 2: Os cenários e2e (falham)**

Em `test/e2e.test.sh`, a seguir à função `mkjob_opencode()`, inserir:

```bash
# mkjob_acct <id> <account> [platform] -- a job of the sandbox project on one
# of the platform's accounts (the account must be registered first).
mkjob_acct() {
  E2E_JOB="$1"
  jq -nc --arg id "$1" --arg a "$2" --arg p "${3:-anthropic}" \
    '{jobs:[{id:$id, project:"sandbox", enabled:false, prompt:"do the thing", interval_seconds:3600,
             platform:$p, model:(if $p == "openai" then "gpt-5.6-sol" else "claude-opus-5" end),
             permission_mode:(if $p == "openai" then "workspace-write" else "bypassPermissions" end),
             max_parallel:1, account:$a}]}' > "$ROOT/config/jobs.json"
  mkdir -p "$ROOT/config/prechecks"
  printf '#!/bin/bash\nexit 0\n' > "$ROOT/config/prechecks/$1.sh"
  chmod +x "$ROOT/config/prechecks/$1.sh"
}
```

A seguir à função `scenario_46()`, inserir:

```bash
scenario_47() {
echo "47. a job on a registered Claude account launches in that account's directory, and so does its precheck"
mkdir -p "$ROOT/accounts/claude-a"
"$AL" platform account-add anthropic "Client A" "$ROOT/accounts/claude-a" >/dev/null 2>&1 || bad "account-add over the stand-in failed"
mkjob_acct j47 client-a
jq --arg pc "printf '%s' \"\${CLAUDE_CONFIG_DIR-<unset>}\" > $ROOT/pc-47; exit 0" '.jobs[0].precheck = $pc' \
  "$ROOT/config/jobs.json" > "$ROOT/config/jobs.next" && mv "$ROOT/config/jobs.next" "$ROOT/config/jobs.json"
acct47="$ROOT/account-47"; rm -f "$acct47" "$ROOT/pc-47"
FAKE_ACCOUNT_OUT="$acct47" FAKE_MODE=complete FAKE_SESSION=sess-47 "$AL" run j47 >/dev/null 2>&1
sleep 1
[ "$(cat "$acct47" 2>/dev/null)" = "$ROOT/accounts/claude-a" ] \
  && ok "the agent runs with CLAUDE_CONFIG_DIR set to the account's directory" || bad "the agent saw '$(cat "$acct47" 2>/dev/null)'"
[ "$(cat "$ROOT/pc-47" 2>/dev/null)" = "$ROOT/accounts/claude-a" ] \
  && ok "and so does its precheck" || bad "the precheck saw '$(cat "$ROOT/pc-47" 2>/dev/null)'"
[ "$(lastrun | jq -r '[.account, .account_dir] | join(" ")')" = "client-a $ROOT/accounts/claude-a" ] \
  && ok "the journal records the account and the directory the run used" || bad "record: $(lastrun | jq -c '{account, account_dir}')"

echo
}

scenario_48() {
echo "48. a job on a registered Codex account launches with that CODEX_HOME, and its rollout is read from there"
mkdir -p "$ROOT/accounts/codex-a"
"$AL" platform account-add openai "Client A" "$ROOT/accounts/codex-a" >/dev/null 2>&1 || bad "openai account-add failed"
mkjob_acct j48 client-a openai
acct48="$ROOT/account-48"; rm -f "$acct48"
FAKE_ACCOUNT_OUT="$acct48" FAKE_MODE=complete FAKE_SESSION=thr-48 "$AL" run j48 >/dev/null 2>&1
sleep 1
[ "$(cat "$acct48" 2>/dev/null)" = "$ROOT/accounts/codex-a" ] \
  && ok "the Codex CLI runs with CODEX_HOME set to the account's home" || bad "codex saw '$(cat "$acct48" 2>/dev/null)'"
ls "$ROOT"/accounts/codex-a/sessions/*/*/*/rollout-*-thr-48.jsonl >/dev/null 2>&1 \
  && ok "the stand-in wrote its rollout under that home" || bad "no rollout under the account's home"
[ "$(lastrun | jq -r .model_id)" = "gpt-5.6-sol-real" ] \
  && ok "and model_id came from it: the rollout was looked for where the run wrote it" || bad "model_id $(lastrun | jq -r .model_id)"

echo
}

scenario_49() {
echo "49. an account on the CLI's own directory runs with CLAUDE_CONFIG_DIR unset, even under a pin"
# Claude Code reads its credentials from another Keychain entry the moment
# CLAUDE_CONFIG_DIR is set at all -- even to ~/.claude (measured, 2.1.280) --
# so an account there must reach the CLI with the variable gone. A home of
# its own for the engine: ~/.claude is the sandbox's.
home49="$ROOT/home-49"; mkdir -p "$home49/.claude" "$ROOT/pinned-49"
HOME="$home49" AGENTLOOP_CLAUDE_CONFIG_DIR="$ROOT/pinned-49" \
  "$AL" platform account-add anthropic "Home" "~/.claude" >/dev/null 2>&1 || bad "account-add of ~/.claude under a pin failed"
mkjob_acct j49 home
acct49="$ROOT/account-49"; rm -f "$acct49"
HOME="$home49" AGENTLOOP_CLAUDE_CONFIG_DIR="$ROOT/pinned-49" FAKE_ACCOUNT_OUT="$acct49" \
  FAKE_MODE=complete FAKE_SESSION=sess-49 "$AL" run j49 >/dev/null 2>&1
sleep 1
[ -f "$acct49" ] && [ -z "$(cat "$acct49")" ] \
  && ok "the agent ran with no CLAUDE_CONFIG_DIR at all: not the pin, not ~/.claude" || bad "the agent saw '$(cat "$acct49" 2>/dev/null)'"
[ "$(lastrun | jq -r '[.account, .account_dir] | join("|")')" = "home|" ] \
  && ok "and the journal says so: the account, and no directory to export" || bad "record: $(lastrun | jq -c '{account, account_dir}')"

echo
}

scenario_50() {
echo "50. a job on an account with no session, or one Settings does not have, is refused before a slot"
mkdir -p "$ROOT/accounts/claude-out"; : > "$ROOT/accounts/claude-out/.fake-logged-out"
"$AL" platform account-add anthropic "Signed Out" "$ROOT/accounts/claude-out" >/dev/null 2>&1 || bad "account-add failed"
mkjob_acct j50 signed-out
FAKE_MODE=complete FAKE_SESSION=sess-50 "$AL" run j50 >/dev/null 2>&1
grep -qF "j50: anthropic is not ready (claude is not signed in in $ROOT/accounts/claude-out (run: CLAUDE_CONFIG_DIR=$ROOT/accounts/claude-out claude auth login)), skipped" "$ROOT/data/tick.log" \
  && ok "no session: the refusal names the account's directory and the login to run" || bad "no refusal line: $(tail -3 "$ROOT/data/tick.log")"
[ -z "$(dirs j50)" ] && ok "and no run directory was cut" || bad "a worktree was cut for a refused run"
mkjob_acct j50c ghost
"$AL" run j50c >/dev/null 2>&1
grep -qF "j50c: account 'ghost' is not an account of anthropic in Settings, skipped" "$ROOT/data/tick.log" \
  && ok "an account Settings does not have is refused by name" || bad "no ghost refusal: $(tail -3 "$ROOT/data/tick.log")"
mkjob j50b
FAKE_MODE=complete FAKE_SESSION=sess-50b "$AL" run j50b >/dev/null 2>&1
sleep 1
[ "$(lastrun | jq -r .session)" = "sess-50b" ] && ok "a job on the Default account runs as before" || bad "the Default job did not run: $(lastrun)"

echo
}

scenario_51() {
echo "51. a resume signs in where its session was created, whatever the job says now"
mkdir -p "$ROOT/accounts/claude-r1" "$ROOT/accounts/claude-r2"
"$AL" platform account-add anthropic "R1" "$ROOT/accounts/claude-r1" >/dev/null 2>&1
"$AL" platform account-add anthropic "R2" "$ROOT/accounts/claude-r2" >/dev/null 2>&1
mkjob_acct j51 r1
FAKE_MODE=undeclared FAKE_SESSION=sess-51 "$AL" run j51 >/dev/null 2>&1
sleep 2
printf 'r2' | "$AL" set-field j51 account >/dev/null 2>&1 || bad "set-field account r2 failed"
acct51="$ROOT/account-51"; rm -f "$acct51"
FAKE_ACCOUNT_OUT="$acct51" FAKE_MODE=complete FAKE_SESSION=sess-51 "$AL" resume j51 sess-51 >/dev/null 2>&1
sleep 2
[ "$(cat "$acct51" 2>/dev/null)" = "$ROOT/accounts/claude-r1" ] \
  && ok "the resume ran on R1, where sess-51 lives, though the job now names R2" || bad "the resume saw '$(cat "$acct51" 2>/dev/null)'"
[ "$(lastrun | jq -r .account)" = "r1" ] && ok "and its record names R1 too" || bad "resume record: $(lastrun | jq -c '{account, account_dir}')"

echo
}
```

Na lista do fim do ficheiro, acrescentar `47 48 49 50 51` ao fim de `E2E_ALL` e ao fim de `E2E_LIST_4`.

Correr:

```bash
$E2E1 47 48 49 50 51
```

Esperado: FAIL (a conta não chega ao CLI, o journal não a tem).

- [ ] **Step 3: `account_export` e a conta no journal**

No bloco de contas (Task 1), a seguir a `account_env_dir()`, inserir:

```bash
account_export() { # account_export <platform> <account-dir> -- in the calling shell: the platform's account variable unset, then exported when the account has a directory of its own (run_env's rule, for a precheck)
  local v
  account_platform "${1:-}" || return 0
  v="$(account_var "$1")"
  unset "$v"
  [ -z "${2:-}" ] || export "$v=$2"
}
```

Substituir `record_run` para aceitar os argumentos 20 e 21 — a linha de assinatura passa a terminar em `<tokens-json> [account] [account-dir]`, a lista de `--arg` ganha `--arg account "${20:-}" --arg account_dir "${21:-}"` e o fim do filtro, `platform:$platform, cost_basis:$cost_basis, tokens:$tokens}`, passa a:

```
      platform:$platform, cost_basis:$cost_basis, tokens:$tokens}
      # The account the run signed in as, and the directory its variable
      # carried (empty: the CLI's own) -- what a resume signs in with. Left
      # out when the caller does not know it, so a record never guesses.
      + (if $account == "" then {} else {account:$account, account_dir:$account_dir} end)
```

A seguir a `journal_platform_of_session()`, inserir:

```bash
journal_account_of_session() { # journal_account_of_session <session-id> -> "<account>\t<account-dir>" off the run that recorded the session; nothing when that run predates accounts
  [ -s "$RUNS_FILE" ] && [ -n "${1:-}" ] || return 0
  grep -F "\"session\":\"$1\"" "$RUNS_FILE" 2>/dev/null | tail -1 \
    | "$JQ" -r 'select(type == "object" and has("account")) | [.account, (.account_dir // "")] | @tsv' 2>/dev/null
}
```

Em `run_record_stopped_early`, acrescentar `account account_dir` à linha `local id="$1" slot="${2:-}" …`; logo antes da chamada a `record_run`, inserir:

```bash
  account="$(cat "$slot/account" 2>/dev/null || true)"
  account_dir="$(cat "$slot/account_dir" 2>/dev/null || true)"
```

e acrescentar `"$account" "$account_dir"` ao fim dessa chamada (a seguir a `"none" "null"`).

- [ ] **Step 4: As portas**

Em `run_refusals`: no comentário de cabeçalho, trocar a primeira linha por `# run_refusals <id> <platform> <model> <effort> <permission> <allowed> <disallowed> <interactive> <account> <account-dir> <resume-sid>`; a seguir à linha `  local id="$1" platform="$2" … interactive="$8"`, inserir

```bash
  local account="${9:-default}" account_dir="${10:-}" resume_sid="${11:-}"
```

e substituir

```bash
  if ! not_ready="$(platform_ready "$platform")"; then
```

por

```bash
  # The account, before the CLI is asked anything: an id Settings no longer
  # has, or a registered account whose directory is gone, fails at the login
  # prompt otherwise. A resume is exempt from the id test -- it signs in with
  # the directory its session was created under, whatever Settings says
  # today. The Default's directory is the install's (the pin, CODEX_HOME):
  # the readiness check below speaks for it, as it always has.
  if [ "$platform" = "opencode" ] && [ "$account" != "default" ]; then
    log_tick "$id: OpenCode has no accounts (account '$account'), skipped"; return 1
  fi
  if [ -z "$resume_sid" ] && ! account_known "$platform" "$account"; then
    log_tick "$id: account '$account' is not an account of $platform in Settings, skipped"; return 1
  fi
  if [ "$account" != "default" ] && [ -n "$account_dir" ] && [ ! -d "$account_dir" ]; then
    local _an; _an="$(account_field "$platform" "$account" name)"; [ -n "$_an" ] || _an="$account"
    log_tick "$id: account '$_an' is missing its directory ($account_dir), skipped"; return 1
  fi
  if ! not_ready="$(platform_ready "$platform" "$account" "$account_dir")"; then
```

- [ ] **Step 5: `run_job`**

(a) Na linha `  local run_cwd worktree run_dir run_env run_cfgdir _envln slot max_par`, trocar `run_cfgdir` por `account account_dir`.

(b) Substituir as seis linhas desde `  # Which account this run signs in as: the install's pin, exported as` até `  run_cfgdir=""` por:

```bash
  # Which account this run signs in as (see the accounts block): the job's
  # own, else its project's when both run on the same platform, else the
  # Default. account_dir is what the platform's variable carries -- empty is
  # the CLI's own directory, and means the variable is left unset. A RESUME
  # signs in where its session was created, off the journal: the session is
  # stored in that account's directory, whatever the job says today.
  account="$(job_account "$id")"
  account_dir="$(account_env_dir "$platform" "$account")"
  if [ -n "$resume_sid" ]; then
    local _ra
    _ra="$(journal_account_of_session "$resume_sid")"
    if [ -n "$_ra" ]; then
      IFS="$(printf '\t')" read -r account account_dir <<EOF
$_ra
EOF
    fi
  fi
```

(c) Trocar a chamada `  run_refusals "$id" "$platform" "$model" "$effort" "$permission" "$allowed" "$disallowed" "$interactive" || return 1` por:

```bash
  run_refusals "$id" "$platform" "$model" "$effort" "$permission" "$allowed" "$disallowed" "$interactive" "$account" "$account_dir" "$resume_sid" || return 1
```

(d) No precheck, trocar `    pc_out="$( cd "$cwd" && { [ -n "$run_cfgdir" ] && export CLAUDE_CONFIG_DIR="$run_cfgdir"` por `    pc_out="$( cd "$cwd" && { account_export "$platform" "$account_dir"`.

(e) Substituir

```bash
  # The env the agent starts with. It exists whether or not this project is
  # isolated — the account is a property of the project, not of the worktree —
  # and the worktree's own venv/vars are appended to it below when there is one.
  run_env=()
  [ -n "$run_cfgdir" ] && run_env+=("CLAUDE_CONFIG_DIR=$run_cfgdir")
```

por

```bash
  # The env the agent starts with. It exists whether or not this project is
  # isolated — the account is not a property of the worktree — and the
  # worktree's own venv/vars are appended to it below when there is one.
  # First the account: the platform's variable is cleared, then set when the
  # account has a directory of its own. The engine's environment may carry
  # the install's pin, and an account on the CLI's own directory needs the
  # variable GONE, not pointed at ~/.claude. `env` applies the -u before the
  # assignments. OpenCode has no such variable.
  run_env=()
  if account_platform "$platform"; then
    run_env+=(-u "$(account_var "$platform")")
    [ -z "$account_dir" ] || run_env+=("$(account_var "$platform")=$account_dir")
  fi
```

(f) A seguir à linha `  [ -n "$resume_sid" ] && echo "$resume_sid" > "$slot/resume_of" 2>/dev/null || true`, inserir:

```bash
  # The account, for the dialog while the run is going and for a stop that
  # records the run before it ends (run_record_stopped_early).
  printf '%s\n' "$account" > "$slot/account" 2>/dev/null || true
  printf '%s\n' "$account_dir" > "$slot/account_dir" 2>/dev/null || true
```

(g) Na chamada `  platform_finish "$platform" "$streamfile" "$session" "$id" "$run_cwd"`, acrescentar `"${account_dir:-$(account_cli_default openai)}"` no fim.

(h) Na chamada final `  record_run "$id" "$status" … "$tokens_json"`, acrescentar `"$account" "$account_dir"` no fim.

- [ ] **Step 6: O rollout no `CODEX_HOME` do run**

Em `platform_finish`: a assinatura passa a `# platform_finish <platform> <streamfile> <session-id> [job-id] [run_cwd] [codex-home]`; acrescentar `home="${6:-$CODEX_HOME_DIR}"` à primeira linha `local` (`local tid="${3:-}" id="${4:-run}" home="${6:-$CODEX_HOME_DIR}"`); trocar `PF_ROLLOUT="$(openai_rollout_for "$tid")"` por `PF_ROLLOUT="$(openai_rollout_for "$tid" "$home")"` e, na linha de `log_tick` seguinte, `under $CODEX_HOME_DIR/sessions` por `under $home/sessions`.

Em `openai_rollout_for`, a assinatura passa a `# openai_rollout_for <thread_id> [codex-home] -> the rollout's path, or nothing` e `ls -t "$CODEX_HOME_DIR"/sessions/…` passa a `ls -t "${2:-$CODEX_HOME_DIR}"/sessions/…`.

- [ ] **Step 7: O precheck avulso**

Em `cmd_precheck`, trocar

```bash
  pc_out="$( cd "$cwd" && export AL_PRECHECK_DRY_RUN=1 CC_PRECHECK_DRY_RUN=1 && eval "$precheck" 2>&1 )"; pc_rc=$?
```

por

```bash
  # The same account as the run it gates (run_job's precheck): a probe that
  # asks the CLI itself must answer for the account the job signs in as.
  local plat adir
  plat="$(job_platform "$id")"; adir="$(account_env_dir "$plat" "$(job_account "$id")")"
  pc_out="$( cd "$cwd" && account_export "$plat" "$adir" && export AL_PRECHECK_DRY_RUN=1 CC_PRECHECK_DRY_RUN=1 && eval "$precheck" 2>&1 )"; pc_rc=$?
```

Em `cmd_check`, trocar

```bash
  ( cd "$cwd" && export AL_PRECHECK_DRY_RUN=1 CC_PRECHECK_DRY_RUN=1 && eval "$precheck" ); local rc=$?
```

por

```bash
  local plat adir
  plat="$(job_platform "$id")"; adir="$(account_env_dir "$plat" "$(job_account "$id")")"
  ( cd "$cwd" && account_export "$plat" "$adir" && export AL_PRECHECK_DRY_RUN=1 CC_PRECHECK_DRY_RUN=1 && eval "$precheck" ); local rc=$?
```

- [ ] **Step 8: Selftest — a ordem das portas e o registo**

Em `test/selftest.sh`, a seguir ao bloco `run_job's parts — every RJ_* is assigned …` (antes de `  echo "cpu_tree_sum() — a busy tool tree is proof of life, not a stall"`), inserir:

```bash
  echo "run_refusals() — the account's gates sit after Settings' own and before the CLI is asked"
  local _rfb _rfo
  _rfb="$(sed -n '/^run_refusals()/,/^}/p' "$BIN_DIR/agentloop")"
  # Which gate each line is, in the order the lines come: a gate moved ahead
  # of Settings' own, or behind the readiness probe, changes this sequence.
  _rfo="$(printf '%s\n' "$_rfb" | awk '
    /no model is enabled for/ { print "nomodel" }
    /OpenCode has no accounts/ { print "opencode" }
    /is not an account of/ { print "unknown" }
    /is missing its directory/ { print "missing" }
    /platform_ready "\$platform" "\$account" "\$account_dir"/ { print "ready" }' | tr '\n' ' ')"
  [ "$_rfo" = "nomodel opencode unknown missing ready " ] \
    && ok "no model -> OpenCode -> unknown account -> missing directory -> the account's own readiness, in that order" \
    || bad "gate order: $_rfo"
  : > "$tmp/acct-runs.ndjson"
  ( RUNS_FILE="$tmp/acct-runs.ndjson"; LOCK_DIR="$tmp"
    record_run j1 success 1 2 0 1 sess-a /x.json "" false "" P opus claude-opus-5 "" "" anthropic reported null cliente-a /x/.claude-a
    record_run j2 success 1 2 0 1 sess-b /y.json "" false "" P opus claude-opus-5 "" "" anthropic reported null )
  [ "$( RUNS_FILE="$tmp/acct-runs.ndjson"; journal_account_of_session sess-a | tr '\t' '|' )" = "cliente-a|/x/.claude-a" ] \
    && [ -z "$( RUNS_FILE="$tmp/acct-runs.ndjson"; journal_account_of_session sess-b )" ] \
    && ok "record_run keeps the account and its directory; a record without them says nothing" \
    || bad "journal: $(cat "$tmp/acct-runs.ndjson")"
  ( env -u CLAUDE_CONFIG_DIR AGENTLOOP_CONFIG="$tmp/acexp/config" AGENTLOOP_DATA="$tmp/acexp/data" \
      bash -c '. "$1" --help >/dev/null 2>&1; CLAUDE_CONFIG_DIR=/pin; export CLAUDE_CONFIG_DIR
      account_export anthropic ""; printf "%s|" "${CLAUDE_CONFIG_DIR-<unset>}"
      account_export anthropic /x/a; printf "%s" "$CLAUDE_CONFIG_DIR"' _ "$SELF" ) > "$tmp/acct-export.out" 2>/dev/null
  [ "$(cat "$tmp/acct-export.out")" = "<unset>|/x/a" ] \
    && ok "account_export: the CLI's own directory unsets the variable, even over a pin; any other sets it" \
    || bad "account_export: $(cat "$tmp/acct-export.out")"
```

(A linha do `record_run` do selftest tem 19 argumentos antes dos dois novos, pela ordem da assinatura.)

- [ ] **Step 9: Correr — devem passar**

```bash
$E2E1 47 48 49 50 51
$E2E1 1 2 3 12 13 14 15 20 25 26
$BLOCK "run_refusals() — the account's gates sit" "cpu_tree_sum() — a busy tool tree"
$BLOCK "run_job's parts — every RJ_* is assigned" "cpu_tree_sum() — a busy tool tree"
$BLOCK "platform_finish() — the model that ran comes from the rollout" "turn_is_over() — over a normalized OpenAI stream"
```

Esperado: `fail=0` em todos (o segundo comando prova que os cenários antigos de lançamento, resume, OpenAI e pin continuam iguais).

- [ ] **Step 10: CHANGELOG**

Acrescentar ao ponto da funcionalidade:

```markdown
  A run signs in with its account's directory — the agent and its precheck,
  `agentloop precheck` and `check` included — and is refused in `tick.log`,
  before a slot is taken, when the account is not in Settings, its directory
  is gone, or it has no session. The journal records the account and the
  directory each run used, a resume signs in where its session was created
  whatever the job says today, and the Codex rollout is read from the run's
  own `CODEX_HOME`.
```

- [ ] **Step 11: Commit**

```bash
/usr/bin/git add bin/agentloop test/fake-codex test/e2e.test.sh test/selftest.sh CHANGELOG.md
/usr/bin/git commit -m "feat(engine): a run signs in with its account, and a resume with the account its session lives in

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Os limites de utilização por conta, o statusline, `usage` e `status`

**Files:**
- Modify: `bin/agentloop` (`rl_key`, `rl_capture`, `rl_capture_openai`, `rl_gate`, chamadas em `run_job` e `platform_finish`, `usage_account_label`, `usage_statusline`, `cmd_usage`, `status_account_lines`, `status_platforms_block`)
- Modify: `bin/statusline-rate-limits.sh`
- Modify: `test/selftest.sh`, `test/e2e.test.sh`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `account_env_value`, `account_env_dir`, `accounts_json`, `account_field`, `account_check_sentence`, `account_users`, `skills_missing`, `account_cli_default`.
- Produces: `rl_key <p> <account_dir>`; `rl_capture <stream> [key]`; `rl_capture_openai <rollout> [refused] [key]`; `rl_gate [key] [nome]`; `usage_account_label <p> <account_dir>`; `usage_statusline <settings.json> <key> <nome-ou-vazio>`; `status_account_lines <p>`.

- [ ] **Step 1: Testes (falham)**

Em `test/selftest.sh`, no bloco `rate limits — the usage window the API reports, read and acted on`, imediatamente antes da linha `  echo "statusline-rate-limits.sh — the figure the run stream never carries"`, inserir:

```bash
  # The windows are an ACCOUNT's: the platform's own key is the CLI's default
  # directory, any other account directory reads and writes <platform>@<dir>.
  [ "$(rl_key anthropic "")" = "anthropic" ] && [ "$(rl_key openai /x/.codex-a)" = "openai@/x/.codex-a" ] \
    && ok "rl_key: the platform for the CLI's own directory, platform@dir for any other" || bad "rl_key"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/acct.json"
    printf '%s' '{}' > "$RATE_LIMIT_FILE"
    rl_capture "$tmp/rl/s.ndjson" "anthropic@/x/.claude-a"
    "$JQ" -e '.["anthropic@/x/.claude-a"].seven_day.utilization == 0.98 and (has("anthropic") | not)' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "rl_capture writes a run's reading into its account's block" || bad "rl_capture per account: $(cat "$tmp/rl/acct.json")"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/acct-oa.json"
    printf '%s' '{}' > "$RATE_LIMIT_FILE"
    rl_capture_openai "$BASE_DIR/test/fixtures/codex/rollout-sample.stripped.jsonl" "" "openai@/x/.codex-a"
    "$JQ" -e '.["openai@/x/.codex-a"].five_hour.utilization == 0.05 and (has("openai") | not)' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "and so does rl_capture_openai" || bad "rl_capture_openai per account: $(cat "$tmp/rl/acct-oa.json")"
  got="$(rl_at "anthropic@/x/.claude-a" five_hour 0.97 "$soon" "anthropic@/x/.claude-a")"
  case "$got" in *"the anthropic five_hour window is 97% used"*) ok "an account's spent window holds that account's runs back" ;; *) bad "account gate: '$got'" ;; esac
  got="$(rl_at "anthropic@/x/.claude-a" five_hour 0.97 "$soon" anthropic)"
  [ -z "$got" ] && ok "and not the Default's" || bad "cross-account gate: $got"
  got="$(rl_at anthropic five_hour 0.97 "$soon" "anthropic@/x/.claude-a")"
  [ -z "$got" ] && ok "nor does the Default's hold another account back" || bad "cross-account gate: $got"
  got="$( DATA_DIR="$tmp/rl"; RATE_LIMIT_FILE="$tmp/rl/named.json"
          "$JQ" -n --arg k "anthropic@/x/.claude-a" --argjson r "$soon" \
            '{($k): {five_hour: {status:"allowed", utilization:0.97, resets_at:$r, overage:null, seen_at:0}}}' > "$RATE_LIMIT_FILE"
          rl_gate "anthropic@/x/.claude-a" "Cliente A" 2>/dev/null )"
  case "$got" in *"the anthropic five_hour window of Cliente A is 97% used"*) ok "and the hold names the account" ;; *) bad "named gate: '$got'" ;; esac
```

No bloco `statusline-rate-limits.sh — the figure the run stream never carries`: trocar a linha do `sl_run` por

```bash
    printf '%s' "$1" | env -u CLAUDE_CONFIG_DIR AGENTLOOP_DATA="$tmp/sl" AGENTLOOP_STATUSLINE_MIN_SECONDS=0 sh "$sl" >/dev/null 2>&1
```

e, a seguir à última asserção do bloco (`the statusline migration keeps the fresher of the two shapes too`), inserir:

```bash
  # A session's account is its CLAUDE_CONFIG_DIR: the reading lands in that
  # account's block, the one its runs read -- the CLI's own directory, with
  # the variable set or not, is the platform's block.
  rm -f "$tmp/sl/rate-limits.json"
  printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":333}}}' \
    | CLAUDE_CONFIG_DIR="/x/.claude-a/" AGENTLOOP_DATA="$tmp/sl" AGENTLOOP_STATUSLINE_MIN_SECONDS=0 sh "$sl" >/dev/null 2>&1
  [ "$(sl_get '.["anthropic@/x/.claude-a"].five_hour.utilization')" = "0.4" ] && [ "$(sl_get 'has("anthropic")')" = "false" ] \
    && ok "a session with CLAUDE_CONFIG_DIR feeds that account's block, trailing slash or not" || bad "statusline per account: $(sl_get '.|tostring')"
  printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":41,"resets_at":333}}}' \
    | CLAUDE_CONFIG_DIR="$HOME/.claude" AGENTLOOP_DATA="$tmp/sl" AGENTLOOP_STATUSLINE_MIN_SECONDS=0 sh "$sl" >/dev/null 2>&1
  [ "$(sl_get '.anthropic.five_hour.utilization')" = "0.41" ] \
    && ok "and one pointed at ~/.claude feeds the platform's own" || bad "statusline ~/.claude: $(sl_get '.|tostring')"
```

No bloco `agentloop usage — the feature can say whether it is switched on`, trocar a linha `    ( HOME="$tmp/usg_home"; mkdir -p "$HOME/.claude"; cp "$tmp/usg/settings.json" "$HOME/.claude/settings.json"` por

```bash
    ( HOME="$tmp/usg_home"; mkdir -p "$HOME/.claude"; cp "$tmp/usg/settings.json" "$HOME/.claude/settings.json"
      PLIST_PATH=/nonexistent; AGENTLOOP_CLAUDE_CONFIG_DIR=""; PLATFORMS_FILE="${USG_PLATFORMS:-$PLATFORMS_FILE}"
```

e, a seguir ao último `case` do bloco (`usage lists both platforms, each window named by its platform`), inserir:

```bash
  mkdir -p "$tmp/usg/acct-a"
  printf '%s' "$wired" > "$tmp/usg/acct-a/settings.json"
  printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":[],"accounts":[{"id":"a","name":"Cliente A","dir":"%s"}]}}}\n' "$tmp/usg/acct-a" > "$tmp/usg/platforms.json"
  got="$(USG_PLATFORMS="$tmp/usg/platforms.json" usg '{}' '{"anthropic@'"$tmp/usg/acct-a"'":{"five_hour":{"status":"allowed","utilization":0.3,"resets_at":'"$soon2"',"seen_at":0,"source":"statusline"}},"anthropic@/gone/.claude-x":{"five_hour":{"status":"allowed","utilization":0.2,"resets_at":'"$soon2"',"seen_at":0}}}')"
  case "$got" in *"anthropic (Cliente A) five_hour: 30% used"*"anthropic (/gone/.claude-x — no longer an account) five_hour: 20% used"*)
      ok "usage names each account's block: a registered one by name, one Settings no longer has by its directory" ;;
    *) bad "usage per account: $got" ;; esac
  case "$got" in *"statusline (Cliente A): wired to"*"it has fed the gate"*) ok "and says whether each account's own settings feed its gate" ;; *) bad "statusline per account: $got" ;; esac
```

No bloco `status_platforms_block() — one line per platform …`, a seguir à asserção `status_platforms_block: a platform switched off says disabled` e antes do `echo "RESULT ok=$_upass bad=$_ufail"`, inserir:

```bash
    mkdir -p "$tmp/sp/acct-a"
    CLAUDE_BIN="$BASE_DIR/test/fake-claude"
    write_platforms '.platforms.anthropic.enabled = true' >/dev/null 2>&1
    write_platforms --arg d "$tmp/sp/acct-a" '.platforms.anthropic.accounts = [{id:"a", name:"Cliente A", dir:$d}]' >/dev/null 2>&1
    printf 'a@example.org' > "$tmp/sp/acct-a/.fake-email"
    _b="$(status_platforms_block)"
    printf '%s\n' "$_b" | grep -qF "            account Cliente A ($tmp/sp/acct-a) — signed in as a@example.org · max plan; used by 0; $(skills_missing "$tmp/sp/acct-a/skills") skill(s) not linked there (agentloop skills install)" \
      && ok "status_platforms_block: one line per registered account, under its platform" \
      || bad "account line: $(printf '%s\n' "$_b" | grep account)"
```

e trocar `RESULT ok=9 bad=0` e `all 9 assertions` por `RESULT ok=10 bad=0` e `all 10 assertions` nesse bloco.

Em `test/e2e.test.sh`: no cenário 13, trocar a linha `jq -e '.openai.five_hour.utilization == 0.05 and .openai.five_hour.source == "rollout"' "$ROOT/data/rate-limits.json" >/dev/null 2>&1 \` por

```bash
# The sandbox's CODEX_HOME is not ~/.codex: the Default's windows are keyed
# by that home, like any other account's.
jq -e --arg k "openai@$CODEX_HOME" '.[$k].five_hour.utilization == 0.05 and .[$k].five_hour.source == "rollout"' "$ROOT/data/rate-limits.json" >/dev/null 2>&1 \
```

e, no cenário 18, `[ "$(jq -r '.openai.five_hour.status' "$ROOT/data/rate-limits.json")" = "usage_limit_reached" ] \` por `[ "$(jq -r --arg k "openai@$CODEX_HOME" '.[$k].five_hour.status' "$ROOT/data/rate-limits.json")" = "usage_limit_reached" ] \` (e o `jq -c .openai` da mensagem de erro por `jq -c .`).

A seguir ao cenário 51, inserir:

```bash
scenario_52() {
echo "52. one account's spent window holds its own scheduled runs back, not another account's"
mkdir -p "$ROOT/accounts/claude-rl"
"$AL" platform account-add anthropic "Limited" "$ROOT/accounts/claude-rl" >/dev/null 2>&1 || bad "account-add failed"
soon52="$(( $(date +%s) + 3600 ))"
jq -n --arg k "anthropic@$ROOT/accounts/claude-rl" --argjson r "$soon52" \
  '{($k): {five_hour: {status:"allowed", utilization:0.97, resets_at:$r, overage:null, seen_at:0}}}' > "$ROOT/data/rate-limits.json"
mkjob_acct j52 limited
"$AL" _exec j52 >/dev/null 2>&1
grep -qF "j52: usage limit reached — the anthropic five_hour window of Limited is 97% used" "$ROOT/data/tick.log" \
  && ok "a scheduled run on the spent account is held back, and the line names the account" || bad "no hold line: $(tail -3 "$ROOT/data/tick.log")"
mkjob j52b
FAKE_MODE=complete FAKE_SESSION=sess-52b "$AL" _exec j52b >/dev/null 2>&1
sleep 1
[ "$(lastrun | jq -r .session)" = "sess-52b" ] && ok "while a scheduled run on the Default account goes ahead" || bad "the Default run was held: $(tail -3 "$ROOT/data/tick.log")"
rm -f "$ROOT/data/rate-limits.json"

echo
}
```

e acrescentar `52` ao fim de `E2E_ALL` e de `E2E_LIST_4`.

Correr:

```bash
$BLOCK "rate limits — the usage window the API reports" "failure causes — an outage is not the job's fault"
$BLOCK "agentloop usage — the feature can say" "the Claude account comes from the setting"
$BLOCK "status_platforms_block() — one line per platform" "cmd_resolve_pricing() — will not race"
$E2E1 52
```

Esperado: FAIL.

- [ ] **Step 2: A chave e o travão**

Em `bin/agentloop`, logo a seguir à função `rl_migrate()`, inserir:

```bash
# Which block of data/rate-limits.json a run's account reads and writes. The
# windows are an ACCOUNT's, not a platform's: the platform's own key is the
# CLI's default directory -- what every install had before accounts, and
# what the statusline of a session with no CLAUDE_CONFIG_DIR writes -- and
# any other account directory has a block of its own, <platform>@<dir>.
rl_key() { # rl_key <platform> <account-dir> -> the block's key
  if [ -z "${2:-}" ]; then printf '%s\n' "$1"; else printf '%s@%s\n' "$1" "$2"; fi
}
```

Em `rl_capture`: assinatura `# rl_capture <streamfile> [key] -- key: rl_key's block (anthropic when none)`; primeira linha `local sf="${1:-}" key="${2:-anthropic}" tmp lock`; acrescentar `--arg k "$key"` à chamada do `jq` e trocar `.anthropic[$e.rateLimitType] = {` por `.[$k][$e.rateLimitType] = {`.

Em `rl_capture_openai`: assinatura `# rl_capture_openai <rollout-file> [refused] [key] -- key: rl_key's block (openai when none)`; primeira linha `local roll="${1:-}" refused="${2:-}" key="${3:-openai}" tmp lock`; acrescentar `--arg k "$key"` e trocar `| .openai = ((.openai // {})` por `| .[$k] = ((.[$k] // {})`.

Substituir `rl_gate` por:

```bash
rl_gate() { # rl_gate [key] [account-name] -> 0 = hold this run back (reason on stdout); anthropic when unnamed. The name is said for an account that is not the Default
  local k="${1:-anthropic}" p of=""
  p="${k%%@*}"
  [ -z "${2:-}" ] || of=" of ${2}"
  rl_migrate
  [ -s "$RATE_LIMIT_FILE" ] || return 1
  "$JQ" -e -r --arg k "$k" --arg p "$p" --arg of "$of" --argjson now "$(now_epoch)" --argjson stop "$RL_STOP_AT" '
    (.[$k] // {}) | to_entries
    | map(select(.value.resets_at != null and .value.resets_at > $now))
    | map(. + {mins: (((.value.resets_at - $now) / 60) | floor)})
    # A refusal outranks a number: if the API has stopped saying `allowed`, the
    # window is spent whatever the last utilisation reading was. A reading with
    # NO status is not a refusal — the statusline reports utilisation without
    # one, and treating its silence as a refusal would gate every healthy run.
    | ( [ .[] | select(.value.status != null and ((.value.status | startswith("allowed")) | not)) ]
        | map("the \($p) \(.key) window\($of) is spent (API says \(.value.status)) -- it resets in \(.mins) min")
      ) + (
        [ .[] | select((.value.utilization // 0) >= $stop) ]
        | map("the \($p) \(.key) window\($of) is \((.value.utilization * 100) | floor)% used"
              + (if .value.overage == "rejected" then " and overage is off, so the ceiling is a dead stop" else "" end)
              + " -- it resets in \(.mins) min")
      )
    | first // empty
  ' "$RATE_LIMIT_FILE" 2>/dev/null
}
```

Em `run_job`, no bloco do travão, substituir

```bash
    local rl_reason
    if rl_reason="$(rl_gate "$platform")" && [ -n "$rl_reason" ]; then
```

por

```bash
    # The account's own windows (rl_key), named in the hold when it is not the Default.
    local rl_reason _rl_of=""
    if [ "$account" != "default" ]; then
      _rl_of="$(account_field "$platform" "$account" name)"; [ -n "$_rl_of" ] || _rl_of="$account"
    fi
    if rl_reason="$(rl_gate "$(rl_key "$platform" "$account_dir")" "$_rl_of")" && [ -n "$rl_reason" ]; then
```

e `  rl_capture "$streamfile"` por `  rl_capture "$streamfile" "$(rl_key "$platform" "$account_dir")"`.

Em `platform_finish`, trocar `  rl_capture_openai "$PF_ROLLOUT" $refused` por `  rl_capture_openai "$PF_ROLLOUT" "$refused" "$(rl_key openai "$(account_env_value openai "$home")")"`.

- [ ] **Step 3: O statusline**

Em `bin/statusline-rate-limits.sh`, logo a seguir à linha `OUT="$DATA_DIR/rate-limits.json"`, inserir:

```sh
# The account this session runs as is its CLAUDE_CONFIG_DIR, and the windows
# are that account's: the reading goes to the engine's key for it (rl_key) --
# anthropic for the CLI's own directory, anthropic@<dir> for any other, the
# directory without trailing slashes.
acct="${CLAUDE_CONFIG_DIR:-}"
while [ "${#acct}" -gt 1 ] && [ "${acct%/}" != "$acct" ]; do acct="${acct%/}"; done
if [ -z "$acct" ] || [ "$acct" = "$HOME/.claude" ]; then KEY="anthropic"; else KEY="anthropic@$acct"; fi
```

Substituir a linha do `last`:

```sh
  last="$("$JQ" -r '[(.anthropic // {})[]?.seen_at // 0, .[]?.seen_at // 0] | max // 0' "$OUT" 2>/dev/null || echo 0)"
```

por:

```sh
  # the floor is per account: another account's fresh write must not hold this one's back
  last="$("$JQ" -r --arg k "$KEY" '[((.[$k] // {})[]?.seen_at // 0), (if $k == "anthropic" then (.[]?.seen_at // 0) else 0 end)] | max // 0' "$OUT" 2>/dev/null || echo 0)"
```

No filtro final (o `printf '%s' "$payload" | "$JQ" --slurpfile prev "$OUT" --argjson now "$now" '`), acrescentar `--arg k "$KEY"` aos argumentos, e dentro do `reduce` trocar `(.anthropic[$w] // {}) as $old` por `(.[$k][$w] // {}) as $old` e `| .anthropic[$w] = {` por `| .[$k][$w] = {`.

- [ ] **Step 4: `usage`**

Substituir `cmd_usage` inteira por:

```bash
usage_account_label() { # usage_account_label <platform> <account-dir> -> the name a usage block goes by: Default, a registered account, or the directory with a note
  local aid
  if [ "$(account_env_dir "$1" default)" = "$2" ]; then printf 'Default'; return 0; fi
  for aid in $(accounts_json "$1" | "$JQ" -r '.[].id'); do
    if [ "$(account_env_dir "$1" "$aid")" = "$2" ]; then account_field "$1" "$aid" name | tr -d '\n'; return 0; fi
  done
  printf '%s — no longer an account' "$2"
}

usage_statusline() { # usage_statusline <settings.json> <rate-limit key> <account name, or empty for the Default> -- whether that account's interactive sessions feed its gate
  local settings="$1" key="$2" tag="" cmd=""
  [ -z "${3:-}" ] || tag=" ($3)"
  [ -f "$settings" ] && cmd="$("$JQ" -r '.statusLine.command // ""' "$settings" 2>/dev/null)"
  if [ -z "$cmd" ]; then
    echo "statusline$tag: not configured — the gate is blind below 0.75 utilisation."
    echo "  Point statusLine at $BIN_DIR/statusline-rate-limits.sh in $settings."
  elif [ "${cmd%statusline-rate-limits.sh}" = "$cmd" ]; then
    echo "statusline$tag: configured, but not to this script — nothing feeds the gate."
    echo "  It runs: $cmd"
  elif [ ! -x "${cmd%% *}" ]; then
    echo "statusline$tag: configured but NOT RUNNABLE — every session's status line is failing."
    echo "  Missing or not executable: ${cmd%% *}"
  else
    echo "statusline$tag: wired to ${cmd%% *}"
    if [ -s "$RATE_LIMIT_FILE" ] \
       && "$JQ" -e --arg k "$key" 'any(.[$k][]?; .source == "statusline")' "$RATE_LIMIT_FILE" >/dev/null 2>&1; then
      echo "  and it has fed the gate — readings above are live."
    else
      echo "  but it has never fed the gate yet. The statusLine is read when a"
      echo "  session STARTS, so any session already open when you wired it will"
      echo "  never call it. Open a new interactive session and re-run this."
    fi
  fi
}

cmd_usage() {
  local now p key keys who reason aid adir
  now="$(now_epoch)"

  rl_migrate
  if [ ! -s "$RATE_LIMIT_FILE" ]; then
    echo "No usage window has been recorded yet."
  else
    for p in $PLATFORMS; do
      if [ "$p" = "opencode" ]; then
        echo "opencode: no usage windows — each provider has its own API, and nothing on the stream or in the export reports one"
        continue
      fi
      # The platform's own block -- the account on the CLI's own directory --
      # first, then one per other account directory the file holds.
      keys="$("$JQ" -r --arg p "$p" '[keys_unsorted[] | select(. == $p or startswith($p + "@"))]
          | (map(select(. == $p)) + map(select(. != $p)))[]' "$RATE_LIMIT_FILE" 2>/dev/null)"
      while IFS= read -r key; do
        [ -n "$key" ] || continue
        if [ "$key" = "$p" ]; then who="$p"; else who="$p ($(usage_account_label "$p" "${key#*@}"))"; fi
        "$JQ" -r --arg k "$key" --arg who "$who" --argjson now "$now" '
          (.[$k] // {}) | to_entries[]
          | .value as $v
          | (if $v.utilization == null then "  ?" else (($v.utilization * 100) | floor | tostring) + "%" end) as $pct
          | (if $v.resets_at == null then "reset time unknown"
             elif $v.resets_at <= $now then "that window has already reset — this reading no longer counts"
             else "resets in " + (((($v.resets_at - $now) / 60) | floor) | tostring) + " min" end) as $when
          | (((($now - ($v.seen_at // 0)) / 60) | floor) | tostring) as $age
          | "\($who) \(.key): \($pct) used, \($when)"
            + "\n  read \($age) min ago from the \($v.source // "run stream")"
            + (if $v.plan_type != null then " (\($v.plan_type) plan)" else "" end)
            + (if $v.status != null then ", API said \($v.status)" else "" end)
            + (if $v.overage == "rejected" then ", overage off (the ceiling is a dead stop)" else "" end)
        ' "$RATE_LIMIT_FILE" 2>/dev/null
        if reason="$(rl_gate "$key")" && [ -n "$reason" ]; then
          echo
          echo "SCHEDULED $who RUNS ARE BEING HELD BACK: $reason"
          echo "  (\`agentloop run <job>\` still overrides this, as it does the budget.)"
        fi
      done <<EOF
$keys
EOF
    done
  fi

  # The other half: is the figure going to keep arriving? A window whose only
  # reading came off a run stream is one the gate cannot see below 75%. The
  # statusLine lives in each Claude account's own settings.json.
  echo
  for aid in default $(accounts_json anthropic | "$JQ" -r '.[].id'); do
    adir="$(account_env_dir anthropic "$aid")"
    if [ "$aid" = "default" ] && [ -z "$adir" ]; then
      usage_statusline "$HOME/.claude/settings.json" anthropic ""
    else
      usage_statusline "${adir:-$HOME/.claude}/settings.json" "$(rl_key anthropic "$adir")" "$(account_field anthropic "$aid" name | tr -d '\n')"
    fi
  done
  echo "openai: fed by every run's own rollout (the Codex CLI reports both windows on every turn); nothing to wire."
}
```

- [ ] **Step 5: `status`**

Imediatamente antes de `status_platforms_block()`, inserir:

```bash
status_account_lines() { # status_account_lines <platform> -> one indented line per registered account: its directory, its session, how many run on it, skills not linked there
  account_platform "$1" || return 0
  local aid aname adir ach users miss extra
  for aid in $(accounts_json "$1" | "$JQ" -r '.[].id'); do
    aname="$(account_field "$1" "$aid" name)"
    adir="$(account_env_dir "$1" "$aid")"
    ach="$(account_check_sentence "$1" "$aid")"
    users="$(num "$(account_users "$1" "$aid" | grep -c . 2>/dev/null)")"
    extra=""
    if [ -n "$adir" ] && [ -d "$adir" ]; then
      miss="$(skills_missing "$adir/skills")"
      [ "$miss" -eq 0 ] || extra="; $miss skill(s) not linked there (agentloop skills install)"
    fi
    printf '            account %s (%s) — %s; used by %s%s\n' "$aname" "${adir:-$(account_cli_default "$1")}" "$ach" "$users" "$extra"
  done
}
```

Em `status_platforms_block`, trocar `    if [ "$ready" != "true" ]; then printf '%-9s : %s — %s\n' "$p" "$state" "$reason"; continue; fi` por

```bash
    if [ "$ready" != "true" ]; then printf '%-9s : %s — %s\n' "$p" "$state" "$reason"; status_account_lines "$p"; continue; fi
```

e o `    printf '\n'` do fim do corpo do `for` por

```bash
    printf '\n'
    status_account_lines "$p"
```

- [ ] **Step 6: Correr — devem passar**

Os quatro comandos do Step 1 e ainda `$E2E1 13 18 47 48`. Esperado: `fail=0`.

- [ ] **Step 7: CHANGELOG**

Acrescentar ao ponto da funcionalidade:

```markdown
  The usage-window gate is per account: a run reads and feeds its account's
  own windows (`<platform>@<directory>` in `data/rate-limits.json`, the
  platform's own key for the CLI's default directory), so one account's spent
  five hours no longer holds another's runs back. The statusline feeds the
  account its session runs as, and `agentloop usage` and `status` list every
  account.
```

e, em `## [Unreleased]` → `### Changed` (criar a secção se não existir), um ponto:

```markdown
- **An install pinned to a Claude account keys that account's usage windows
  by its directory.** `anthropic@<pin>` replaces the bare `anthropic` block
  for pinned runs, so the gate is blind for them until the next reading lands
  — one run, or the next interactive turn of a session wired to the
  statusline in that account.
```

- [ ] **Step 8: Commit**

```bash
/usr/bin/git add bin/agentloop bin/statusline-rate-limits.sh test/selftest.sh test/e2e.test.sh CHANGELOG.md
/usr/bin/git commit -m "feat(engine): the usage-window gate is per account, and usage and status list the accounts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: O servidor — acções, `/api/models`, e a conta de cada run

**Files:**
- Modify: `bin/agentloop-server`
- Modify: `tests/test_platforms_api.py`
- Create: `tests/test_run_accounts.py`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: os verbos da Task 1; os campos `account`/`account_dir` do journal e do slot (Task 3).
- Decisão do plano (refina a spec): a spec previa um espelho em Python da regra de resolução (`_job_account`) para o detalhe de um run vivo. O slot passa a guardar a conta que o motor resolveu (Task 3, `$slot/account` e `$slot/account_dir`), o que é exacto — um resume usa a conta do registo, que nenhum espelho da regra saberia — e dispensa a duplicação: nada em Python replica a regra.
- Produces: `ACCOUNT_PLATFORMS`; `_accounts_of(entry)`; acções `platform_accounts {platform}` → `{ok, accounts}`, `platform_account_add {platform, name, dir}`, `platform_account_edit {platform, id, name, dir}`, `platform_account_remove {platform, id}`, `platform_check {platform, account?}`; `platforms.<p>.accounts` em `/api/models` (só `anthropic` e `openai`); `set_field` aceita `account`; `SCHEMA_VERSION = "7"`; `account`/`account_dir` no detalhe (índice e run vivo) e em `active_runs_for`.

- [ ] **Step 1: Testes (falham)**

Em `tests/test_platforms_api.py`, acrescentar no fim:

```python
def test_account_actions_relay_to_the_engine(srv, monkeypatch):
    seen = []

    def fake(args, stdin=None):
        seen.append(args)
        if args[1] == "accounts":
            return True, '[{"id":"default","name":"Default","dir":"~/.claude","account_dir":"","builtin":true,"check":{"ready":true,"account":"a","reason":""},"used_by":{"jobs":[],"projects":[],"security":[]}}]'
        if args[1] == "account-remove":
            return False, "platform account-remove: 'A' is used by j1 — move them to another account first"
        return True, "account 'A' added on anthropic (id a) — signed in as a@example.org · max plan"
    monkeypatch.setattr(srv, "al", fake)
    code, payload = srv.platform_action("platform_accounts", {"platform": "anthropic"})
    assert code == 200 and payload["accounts"][0]["id"] == "default"
    assert srv.platform_action("platform_account_add", {"platform": "anthropic", "name": "A", "dir": "~/.claude-a"})[0] == 200
    srv.platform_action("platform_account_edit", {"platform": "anthropic", "id": "a", "name": "A2", "dir": "~/.claude-a"})
    code, payload = srv.platform_action("platform_account_remove", {"platform": "anthropic", "id": "a"})
    assert code == 500 and "is used by j1" in payload["output"]
    srv.platform_action("platform_check", {"platform": "anthropic", "account": "a"})
    srv.platform_action("platform_check", {"platform": "anthropic"})
    assert seen == [["platform", "accounts", "anthropic"],
                    ["platform", "account-add", "anthropic", "A", "~/.claude-a"],
                    ["platform", "account-edit", "anthropic", "a", "A2", "~/.claude-a"],
                    ["platform", "account-remove", "anthropic", "a"],
                    ["platform", "check", "anthropic", "a"],
                    ["platform", "check", "anthropic"]]
    assert srv.platform_action("platform_account_add", {"platform": "anthropic", "name": 3, "dir": "/x"})[0] == 400
    assert srv.platform_action("platform_account_remove", {"platform": "anthropic"})[0] == 400
    assert srv.platform_action("platform_account_edit", {"platform": "anthropic", "name": "A", "dir": "/x"})[0] == 400
    assert srv.platform_action("platform_check", {"platform": "anthropic", "account": ["a"]})[0] == 400


def test_the_account_actions_are_routed(srv):
    src = (REPO / "bin" / "agentloop-server").read_text()
    route = src[src.index('if op in ("platform_check"'):][:400]
    for op in ("platform_accounts", "platform_account_add", "platform_account_edit", "platform_account_remove"):
        assert f'"{op}"' in route, f"{op} is not routed to platform_action"


def test_api_models_lists_the_registered_accounts(srv):
    _write_platforms(srv, {
        "anthropic": {"enabled": True, "bin": "", "models": ["claude-opus-5"],
                      "accounts": [{"id": "a", "name": "A", "dir": "~/.claude-a"}, {"id": "", "name": "x", "dir": "/y"},
                                   "junk", {"id": "default", "name": "D", "dir": "/z"}]},
        "openai": {"enabled": True, "bin": "", "models": [], "accounts": "oops"},
        "opencode": {"enabled": False, "bin": "", "models": []}})
    p = srv.list_models()["platforms"]
    assert p["anthropic"]["accounts"] == [{"id": "a", "name": "A", "dir": "~/.claude-a"}]
    assert p["openai"]["accounts"] == []
    assert "accounts" not in p["opencode"]


def test_the_server_lets_account_through_set_field():
    src = (REPO / "bin" / "agentloop-server").read_text()
    allow = src[src.index('elif op == "set_field"'):][:900]
    assert '"account"' in allow
```

Criar `tests/test_run_accounts.py`:

```python
"""The account a run signed in as, carried from the journal and the slot to
the run dialog. Two ADDITIVE columns (`account`, `account_dir`) and a schema
bump that re-reads the journal; a record from before accounts reads empty."""
import json
import os
import sqlite3

OLD_CREATE = """CREATE TABLE runs (
    key TEXT PRIMARY KEY, job TEXT, start INTEGER, status TEXT,
    duration INTEGER, cost REAL, session TEXT, log TEXT, forced INTEGER,
    precheck_note TEXT, result_json TEXT, stream TEXT, precheck_txt TEXT,
    stderr TEXT, doc TEXT, project TEXT, model TEXT, model_id TEXT,
    note TEXT, resumed_from TEXT, cause TEXT, platform TEXT, cost_basis TEXT,
    tokens TEXT, pruned INTEGER DEFAULT 0)"""


def _record(**over):
    rec = {"id": "j1", "status": "success", "start": 1700000000, "end": 1700000100,
           "duration": 100, "cost": 0.5, "session": "s-1", "log": "/nope.json", "note": "",
           "cause": "", "forced": False, "precheck": "", "project": "", "model": "opus",
           "model_id": "claude-opus-5", "resumed_from": "", "platform": "anthropic"}
    rec.update(over)
    return rec


def test_the_schema_is_seven(srv):
    assert srv.SCHEMA_VERSION == "7"


def test_a_run_detail_names_its_account(srv, clean_data):
    srv.RUNS_FILE.write_text(
        json.dumps(_record(account="cliente-a", account_dir="/Users/me/.claude-a")) + "\n"
        + json.dumps(_record(id="j2", session="s-2", account="default", account_dir="")) + "\n"
        + json.dumps(_record(id="j3", session="s-3")) + "\n")
    d1 = srv.load_run_detail("j1", 1700000000)["record"]
    assert (d1["account"], d1["account_dir"]) == ("cliente-a", "/Users/me/.claude-a")
    d2 = srv.load_run_detail("j2", 1700000000)["record"]
    assert (d2["account"], d2["account_dir"]) == ("default", "")
    d3 = srv.load_run_detail("j3", 1700000000)["record"]
    assert (d3["account"], d3["account_dir"]) == ("", ""), "a record from before accounts reads empty"


def test_an_index_from_schema_six_gains_the_two_columns(srv, clean_data):
    conn = sqlite3.connect(str(srv.DB_FILE))
    conn.execute(OLD_CREATE)
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("INSERT INTO meta (key, value) VALUES ('schema', '6')")
    conn.commit(); conn.close()
    srv.RUNS_FILE.write_text(json.dumps(_record(account="cliente-a", account_dir="/x/a")) + "\n")
    srv.ingest()
    conn = srv.db_conn()
    try:
        cols = [r[1] for r in conn.execute("PRAGMA table_info(runs)").fetchall()]
        row = conn.execute("SELECT account, account_dir FROM runs WHERE job='j1'").fetchone()
    finally:
        conn.close()
    assert {"account", "account_dir"} <= set(cols)
    assert (row["account"], row["account_dir"]) == ("cliente-a", "/x/a")


def test_a_live_run_names_its_account_off_the_slot(srv, clean_data):
    """A run still going is not in the journal yet: its slot says which account
    it signed in as from its first second, as it says when it started."""
    srv.JOBS_FILE.write_text(json.dumps({"jobs": [{"id": "jlive", "project": "P"}]}))
    srv.PROJECTS_FILE.write_text(json.dumps({"projects": [{"name": "P"}]}))
    start = 1700000700
    slot = srv.DATA_DIR / "locks" / "jlive" / "4244"
    slot.mkdir(parents=True, exist_ok=True)
    (slot / "pid").write_text(str(os.getpid()))       # this process is alive, so the slot is
    (slot / "start").write_text(str(start))
    (slot / "boot").write_text(srv.boot_id())
    (slot / "account").write_text("cliente-a\n")
    (slot / "account_dir").write_text("/Users/me/.claude-a\n")
    assert srv.active_runs_for("jlive")[0]["account"] == "cliente-a"
    d = srv.load_run_detail("jlive", start)
    assert d is not None and d["live"] is True
    assert (d["record"]["account"], d["record"]["account_dir"]) == ("cliente-a", "/Users/me/.claude-a")
```

Correr:

```bash
python3.13 -m pytest tests/test_platforms_api.py tests/test_run_accounts.py -p no:cacheprovider -q
```

Esperado: FAIL.

- [ ] **Step 2: Acções e rota**

Em `bin/agentloop-server`, a seguir ao dicionário `PLATFORM_PERMISSIONS` (fim da sua definição), acrescentar:

```python
# The two platforms whose CLI keeps one signed-in account per directory
# (CLAUDE_CONFIG_DIR, CODEX_HOME). OpenCode's credentials are its providers.
ACCOUNT_PLATFORMS = ("anthropic", "openai")


def _accounts_of(entry):
    """The accounts Settings registered on one platform, exactly as the
    engine's accounts_json keeps them: well-formed {id, name, dir} only, never
    one called default (the Default is the install's own and never stored)."""
    raw = entry.get("accounts") if isinstance(entry, dict) else None
    out = []
    for a in raw if isinstance(raw, list) else []:
        if not isinstance(a, dict):
            continue
        aid, name, d = a.get("id"), a.get("name"), a.get("dir")
        if not all(isinstance(x, str) and x for x in (aid, name, d)) or aid == "default":
            continue
        out.append({"id": aid, "name": name, "dir": d})
    return out
```

Substituir `platform_action` inteira por:

```python
def platform_action(op, body):
    """The Settings ops, each one `agentloop platform <verb> <platform>` -- the
    engine validates and refuses; this only shapes the request and relays the answer."""
    platform = str(body.get("platform", "") or "").strip()
    if platform not in PLATFORM_REGISTRY:
        return 400, {"error": "unknown platform"}
    # check enable disable set-bin models set-models accounts account-add account-edit account-remove
    verb = op[len("platform_"):].replace("_", "-")
    args = ["platform", verb, platform]
    stdin = None

    def text(key):
        v = body.get(key, "")
        return v if isinstance(v, str) else None

    if op == "platform_set_bin":
        args.append(str(body.get("bin", "") or ""))
    elif op == "platform_set_models":
        models = body.get("models")
        if not isinstance(models, list) or not all(isinstance(m, str) for m in models):
            return 400, {"error": "models must be a list of ids"}
        stdin = json.dumps(models)
    elif op == "platform_check":
        acct = body.get("account")
        if acct not in (None, ""):
            if not isinstance(acct, str):
                return 400, {"error": "account must be an id"}
            args.append(acct)
    elif op == "platform_account_add":
        name, d = text("name"), text("dir")
        if name is None or d is None:
            return 400, {"error": "name and dir must be text"}
        args += [name, d]
    elif op == "platform_account_edit":
        aid, name, d = text("id"), text("name"), text("dir")
        if not aid or name is None or d is None:
            return 400, {"error": "id, name and dir must be text"}
        args += [aid, name, d]
    elif op == "platform_account_remove":
        aid = text("id")
        if not aid:
            return 400, {"error": "missing account id"}
        args.append(aid)
    ok, out = al(args, stdin=stdin)
    if ok and op in ("platform_check", "platform_models", "platform_accounts"):
        try:
            payload = json.loads(out)
        except ValueError:
            return 500, {"ok": False, "output": out}
        key = {"platform_check": "check", "platform_models": "catalog", "platform_accounts": "accounts"}[op]
        return 200, {"ok": True, key: payload}
    return (200 if ok else 500), {"ok": ok, "output": out}
```

Na rota (`if op in ("platform_check", "platform_enable", "platform_disable", …)`), acrescentar `"platform_accounts", "platform_account_add", "platform_account_edit", "platform_account_remove"` ao tuplo.

No `elif op == "set_field":`, acrescentar `"account"` ao tuplo de campos permitidos (a seguir a `"platform"`).

Em `platform_entry`, substituir o `return {…}` por uma variável `out = {…}` com o mesmo conteúdo, seguida de:

```python
    # Only the two platforms whose CLI keeps an account per directory; the
    # editors read the list to offer an account after the platform.
    if p in ACCOUNT_PLATFORMS:
        out["accounts"] = _accounts_of(entry)
    return out
```

- [ ] **Step 3: O índice e o detalhe**

- `SCHEMA_VERSION = "7"   # account and account_dir columns: the account each run signed in as`.
- Em `db_init`, na `CREATE TABLE IF NOT EXISTS runs`, trocar `tokens TEXT, pruned INTEGER DEFAULT 0)` por `tokens TEXT, account TEXT, account_dir TEXT, pruned INTEGER DEFAULT 0)`.
- Na lista `canon` de `ingest`, a seguir a `("platform", "TEXT"), ("cost_basis", "TEXT"), ("tokens", "TEXT"),`, acrescentar uma linha `# The account a run signed in as, and the directory its variable carried.` e `("account", "TEXT"), ("account_dir", "TEXT"),`.
- Em `_upsert`: a lista de colunas do `INSERT OR REPLACE` passa a `… platform, cost_basis, tokens, account, account_dir, pruned)`; o comentário "25 columns, 25 placeholders" passa a "27 columns, 27 placeholders" (manter o resto do comentário); os `VALUES` ganham mais dois `?`; e o tuplo ganha, entre `_tokens_json(rec, art),` e `pruned))`, as duas linhas `rec.get("account") or "",` e `rec.get("account_dir") or "",`.
- Em `load_run_detail`, no dicionário `rec`, a seguir a `"cost_basis": row["cost_basis"] or "reported"`, acrescentar `, "account": row["account"] or "", "account_dir": row["account_dir"] or ""`.
- Em `active_runs_for`, no dicionário acrescentado a `out`, a seguir a `"forced": _read("forced")`, acrescentar `,` e as linhas `# the account the run signs in as, and the directory its variable carries` e `"account": _read("account"), "account_dir": _read("account_dir")`.
- Em `load_live_detail`, no dicionário `rec`, a seguir a `"platform": _platform_from_stream(stream, job_platform),`, acrescentar `"account": (slot or {}).get("account") or "", "account_dir": (slot or {}).get("account_dir") or "",`.

- [ ] **Step 4: Correr — devem passar**

```bash
python3.13 -m pytest tests --ignore=tests/security -p no:cacheprovider -q
```

Esperado: tudo verde.

- [ ] **Step 5: CHANGELOG e commit**

Acrescentar ao ponto da funcionalidade: `The dashboard's server relays the account actions and carries the account on every run — finished, from the journal, and live, from the run's slot.`

```bash
/usr/bin/git add bin/agentloop-server tests/test_platforms_api.py tests/test_run_accounts.py CHANGELOG.md
/usr/bin/git commit -m "feat(server): the account actions, the accounts in /api/models, and the account of every run

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: A página — Accounts em Settings, o combo Account nos três editores, e o detalhe do run

**Files:**
- Modify: `ui/app/editor-domain.js`, `ui/app/index.js`, `ui/app/settings.js`, `ui/css/pages.css`
- Modify: `bin/dashboard.html`
- Modify: `bin/static/*` (por `bash build/build-ui.sh`)
- Modify: `tests/test_page_contract.py`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `/api/models` `platforms.<p>.accounts`; acções da Task 5; `rec.account`, `rec.account_dir`.
- Decisão do plano (refina a spec): a célula *Session* da grelha fica como está — é a sessão da Default, a que o chip do cartão lê —, e a lista completa das contas entra numa secção *Accounts* de largura inteira, entre a grelha e *Models*, desenhada como *Models* (cabeçalho em faixa, uma linha por conta). Meia largura não cabe o nome, a pasta, o estado e as acções de cada conta.
- Produces (editor-domain.js, exportados em `window.ALApp`): `accountsOf(platform, platforms)`, `accountChoice(platform, platforms)`, `accountName(platform, id, platforms)`, `inheritedAccountName(platform, project, platforms)`, `accountNoneLabel(inheritName)`, `ACCOUNT_GONE_SUFFIX`, `accountOptions(platform, platforms, current)`. settings.js: `ACCOUNT_PLATFORMS`, `accountStatusText(platform, check)`, `accountUsersText(used)`. dashboard.html: `edAccountCfg`/`pjAccountCfg`/`secAccountCfg`, os três combos, `paintAccountCombo`, `paintJobAccount`, `paintProjectAccount`, `paintSecurityAccount`, `accountCell(rec)`, `reopenCommand` com o prefixo.

- [ ] **Step 1: Testes (falham)**

Em `tests/test_page_contract.py`:

(a) Substituir a função `test_the_project_editor_no_longer_offers_an_account_of_its_own` por:

```python
def test_the_editors_pick_an_account_from_settings_never_a_path(srv):
    """The account a level runs under is one Settings › Platforms registered,
    picked from a list after the platform and before the model -- never a
    directory typed into the editor, which is what the removed
    claude_config_dir field was."""
    page = srv.render_page("boot-authed")
    assert 'id="pj-ccd"' not in page and 'id="sec-cfgdir"' not in page
    assert "claude_config_dir" not in _js(srv)
    for prefix, before in (("ed", "ed-model-combo"), ("pj", "pj-cwd"), ("sec", "sec-model-combo")):
        row = f'<div id="{prefix}-account-row" hidden>'
        assert row in page, f"{prefix}-account-row is missing or not hidden by default"
        assert f'id="{prefix}-account"' in page
        assert page.index(f'id="{prefix}-platform-combo"') < page.index(row) < page.index(f'id="{before}"'), \
            f"{prefix}: the Account combo must sit after the Platform combo and before {before}"
```

(b) Em `test_the_project_editor_has_a_security_pane`, acrescentar `"sec-account"` ao tuplo de campos.

(c) Em `_run_save`, acrescentar `"pj-account":"","sec-account":"cliente-a",` ao dicionário `vals` (a seguir a `"pj-platform":"anthropic",`); em `test_saving_always_sends_the_whole_security_block_with_a_real_boolean`, acrescentar `"account"` ao conjunto esperado de chaves de `sec`, e a seguir às asserções existentes:

```python
    assert sec["account"] == "cliente-a", "the block's account is always sent, like its platform"
    assert proj["account"] == "", "the project's account is always sent too: empty is how it goes back to the Default"
```

(d) Acrescentar no fim do ficheiro:

```python
@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_account_options_and_what_an_empty_one_resolves_to(srv, tmp_path):
    js = _app_js(srv)
    deps = (_const(js, "KNOWN_PLATFORMS") + _const(js, "ACCOUNT_GONE_SUFFIX")
            + "\n".join(_plainfn(js, n) for n in ("platformKey", "accountsOf", "accountChoice", "accountName",
                                                   "inheritedAccountName", "accountNoneLabel", "accountOptions")))
    script = tmp_path / "accounts.js"
    script.write_text(deps + """
    const P = {anthropic: {accounts: [{id: "a", name: "Cliente A", dir: "~/.claude-a"}, {id: "", name: "x", dir: "/x"}]},
               openai: {accounts: []}, opencode: {}};
    console.log(JSON.stringify({
      choiceA: accountChoice("anthropic", P), choiceO: accountChoice("openai", P), choiceOC: accountChoice("opencode", P),
      opts: accountOptions("anthropic", P, ""),
      gone: accountOptions("anthropic", P, "zz").slice(-1)[0],
      inherit: inheritedAccountName("anthropic", {platform: "", account: "a"}, P),
      otherPlatform: inheritedAccountName("openai", {platform: "anthropic", account: "a"}, P),
      projectDefault: inheritedAccountName("anthropic", {platform: "anthropic", account: "default"}, P),
      labels: [accountNoneLabel("Cliente A"), accountNoneLabel("")],
      names: [accountName("anthropic", "default", P), accountName("anthropic", "a", P), accountName("anthropic", "zz", P)],
    }));
    """)
    out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
    assert (out["choiceA"], out["choiceO"], out["choiceOC"]) == (True, False, False), \
        "the combo shows only where there is an account to pick besides the Default"
    assert out["opts"] == [{"v": "default", "label": "Default"}, {"v": "a", "label": "Cliente A — ~/.claude-a"}]
    assert out["gone"] == {"v": "zz", "label": "zz (not in Settings)", "flagged": True}
    assert out["inherit"] == "Cliente A" and out["otherPlatform"] == "" and out["projectDefault"] == ""
    assert out["labels"] == ["— Project's account (Cliente A) —", "— Default —"]
    assert out["names"] == ["Default", "Cliente A", "zz"]


def test_the_job_editor_saves_the_account_after_the_platform(srv):
    js = _js(srv)
    body = _fn(js, "saveEditor")
    assert 'job.account=' in body, "a job being created must carry its account"
    i_plat = body.index('field:"platform"')
    i_acct = body.index('setF("account"')
    i_model = body.index('setF("model"')
    assert i_plat < i_acct < i_model, "the account is saved after the platform (which may clear it) and before the model"
    assert 'paintJobAccount(' in _plainfn(js, "applyPlatformToJobEditor")
    assert 'paintSecurityAccount(' in _plainfn(js, "applyPlatformToSecurity")


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_the_run_dialog_names_the_account_and_the_reopen_line_carries_it(srv, tmp_path):
    js = _js(srv)
    deps = "\n".join(_plainfn(js, n) for n in ("reopenCommand", "accountCell"))
    script = tmp_path / "reopen.js"
    script.write_text("""
    const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;");
    const PLATFORMS = {anthropic: {accounts: [{id: "a", name: "Cliente A", dir: "~/.claude-a"}]}};
    const ALApp = {
      accountsOf: (p, P) => ((P[p] || {}).accounts || []),
      accountName: (p, id, P) => id === "default" ? "Default" : (((P[p] || {}).accounts || []).find(a => a.id === id) || {name: id}).name,
    };
    """ + deps + """
    console.log(JSON.stringify({
      plain: reopenCommand({platform: "anthropic", session: "s1"}, {}),
      claude: reopenCommand({platform: "anthropic", session: "s1", account_dir: "/Users/me/.claude-a"}, {}),
      codex: reopenCommand({platform: "openai", session: "t1", account_dir: "/Users/me/.codex-a"}, {}),
      spaced: reopenCommand({platform: "anthropic", session: "s1", account_dir: "/Users/me/My Accounts/.claude"}, {}),
      none: accountCell({platform: "anthropic"}),
      named: accountCell({platform: "anthropic", account: "a", account_dir: "/Users/me/.claude-a"}),
      gone: accountCell({platform: "anthropic", account: "zz", account_dir: "/Users/me/.claude-z"}),
      pinned: accountCell({platform: "anthropic", account: "default", account_dir: "/Users/me/.claude-pin"}),
    }));
    """)
    out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
    assert out["plain"] == "claude --resume s1"
    assert out["claude"] == "CLAUDE_CONFIG_DIR=/Users/me/.claude-a claude --resume s1"
    assert out["codex"] == "CODEX_HOME=/Users/me/.codex-a codex exec resume t1"
    assert out["spaced"] == "CLAUDE_CONFIG_DIR='/Users/me/My Accounts/.claude' claude --resume s1"
    assert out["none"] == "", "the Default on the CLI's own directory is every single-account run: no row"
    assert "Cliente A" in out["named"] and "/Users/me/.claude-a" in out["named"]
    assert "zz" in out["gone"] and "no longer in Settings" in out["gone"]
    assert "Default" in out["pinned"] and "/Users/me/.claude-pin" in out["pinned"]


@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_the_accounts_section_speaks_the_session_line_s_language(srv, tmp_path):
    js = _app_js(srv)
    deps = "\n".join(_plainfn(js, n) for n in ("accountStatusText", "accountUsersText"))
    script = tmp_path / "acct-status.js"
    script.write_text(deps + """
    console.log(JSON.stringify({
      an: accountStatusText("anthropic", {ready: true, account: "a@example.org · max plan"}),
      oa: accountStatusText("openai", {ready: true, account: "Logged in using ChatGPT"}),
      off: accountStatusText("anthropic", {ready: false, reason: "claude is not signed in in /x"}),
      none: accountStatusText("anthropic", null),
      users: [accountUsersText({jobs: ["j1", "j2"], projects: ["P"], security: []}), accountUsersText({})],
    }));
    """)
    out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
    assert out["an"] == {"ok": True, "text": "Signed in as a@example.org · max plan"}
    assert out["oa"] == {"ok": True, "text": "Logged in using ChatGPT"}
    assert out["off"] == {"ok": False, "text": "claude is not signed in in /x"}
    assert out["none"]["ok"] is None
    assert out["users"] == ["used by 2 jobs, 1 project", "nothing runs on it yet"]


def test_settings_draws_the_accounts_of_the_two_account_platforms(srv):
    src = (REPO / "ui" / "app" / "settings.js").read_text()
    for op in ("platform_accounts", "platform_account_add", "platform_account_edit", "platform_account_remove"):
        assert f'"{op}"' in src, f"settings.js never calls {op}"
    card = _plainfn(_app_js(srv), "platformCard")
    assert "accountsSection(" in card and "ACCOUNT_PLATFORMS.includes(r.id)" in card
    paint = _plainfn(_app_js(srv), "paint")
    assert '"acct-name-"' in paint and '"acct-dir-"' in paint, \
        "a repaint must read the account form back first: the folder picker sets .value with no event"
    assert "data-cwd-target" in _plainfn(_app_js(srv), "accountForm") or "cwdTarget" in _plainfn(_app_js(srv), "accountForm"), \
        "the directory field reuses the page's folder picker"
```

Correr:

```bash
python3.13 -m pytest tests/test_page_contract.py -p no:cacheprovider -q -k "account or security_pane or saving_always_sends"
```

Esperado: FAIL.

- [ ] **Step 2: `editor-domain.js` e `index.js`**

Em `ui/app/editor-domain.js`, a seguir à função `platformOptions`, inserir:

```js
// The accounts a platform can run under besides its Default: the ones
// Settings › Platforms registered, as /api/models lists them (`accounts`). The
// Default is the install's own and never listed -- every platform has it --
// and OpenCode has none at all.
export function accountsOf(platform, platforms){
  const p = (platforms || {})[platformKey(platform)];
  const list = (p && Array.isArray(p.accounts)) ? p.accounts : [];
  return list.filter(a => a && typeof a.id === "string" && a.id && a.id !== "default"
                          && typeof a.name === "string" && typeof a.dir === "string");
}

// Whether an editor shows its Account combo at all: only when the platform
// has an account to pick besides the Default.
export function accountChoice(platform, platforms){
  return accountsOf(platform, platforms).length > 0;
}

// The name an account id reads as: Default, a registered account's name, or
// the id itself once Settings no longer has it.
export function accountName(platform, id, platforms){
  if(!id || id === "default") return "Default";
  const hit = accountsOf(platform, platforms).find(a => a.id === id);
  return hit ? hit.name : id;
}

// What an EMPTY account resolves to, the engine's job_account rule: the
// project's own account when the job -- or the analysis -- runs on the
// project's platform, else the Default. The account's name, or "" for the
// Default, so the empty row can say which.
export function inheritedAccountName(platform, project, platforms){
  if(!project) return "";
  const pp = KNOWN_PLATFORMS.includes(project.platform) ? project.platform : "anthropic";
  if(pp !== platformKey(platform)) return "";
  const a = project.account;
  if(!a || a === "default") return "";
  return accountName(platform, a, platforms);
}

// The empty row of an Account combo, in words: which account an empty value
// lands on.
export function accountNoneLabel(inheritName){
  return inheritName ? "— Project's account (" + inheritName + ") —" : "— Default —";
}

// The Account combo's options: the Default by name, then every registered
// account with its directory. `current` -- the value already on screen --
// joins the end flagged when Settings no longer has it: the editor shows the
// truth instead of rewriting the job, as it does for a switched-off model.
export const ACCOUNT_GONE_SUFFIX = " (not in Settings)";
export function accountOptions(platform, platforms, current){
  const list = accountsOf(platform, platforms);
  const opts = [{v: "default", label: "Default"}]
    .concat(list.map(a => ({v: a.id, label: a.name + " — " + a.dir})));
  if(current && current !== "default" && !list.some(a => a.id === current)){
    opts.push({v: current, label: current + ACCOUNT_GONE_SUFFIX, flagged: true});
  }
  return opts;
}
```

Em `ui/app/index.js`, acrescentar `accountsOf, accountChoice, accountName, inheritedAccountName, accountNoneLabel, ACCOUNT_GONE_SUFFIX, accountOptions,` ao `import … from "./editor-domain.js"` e aos nomes de `window.ALApp` (a seguir a `platformOptions`).

- [ ] **Step 3: `settings.js` e o CSS**

Em `ui/app/settings.js`:

- A seguir a `export const REGISTRY = [...]`, inserir:

```js
// The two platforms whose CLI keeps one signed-in account per directory --
// CLAUDE_CONFIG_DIR, CODEX_HOME. OpenCode's credentials are its providers.
export const ACCOUNT_PLATFORMS = ["anthropic", "openai"];
```

- `const live = {…}` ganha `accounts: {}, acctForm: {}`.
- Em `runCheck`, acrescentar como última linha `  await loadAccounts(id);`.
- A seguir a `loadCatalog`, inserir:

```js
async function loadAccounts(id){
  if(!ACCOUNT_PLATFORMS.includes(id)) return;
  const j = await post("platform_accounts", {platform: id});
  if(j && Array.isArray(j.accounts)) live.accounts[id] = j.accounts;
  paint();
}

// One account's state in words: whom it is signed in as -- the prefix only
// on Anthropic, like the Session line, since Codex phrases its own answer --
// or why it is not; `ok` null until it has been checked.
export function accountStatusText(platform, check){
  if(!check) return {ok: null, text: "— not checked"};
  if(check.ready) return {ok: true, text: platform === "anthropic" ? "Signed in as " + (check.account || "unknown") : (check.account || "signed in")};
  return {ok: false, text: check.reason || "not signed in"};
}

// Who is configured on an account, counted the way `platform accounts`
// splits it: jobs, projects, analyses.
export function accountUsersText(used){
  const u = used || {}, parts = [];
  const add = (list, one, many) => { const n = (list || []).length; if(n) parts.push(n + " " + (n === 1 ? one : many)); };
  add(u.jobs, "job", "jobs"); add(u.projects, "project", "projects"); add(u.security, "analysis", "analyses");
  return parts.length ? "used by " + parts.join(", ") : "nothing runs on it yet";
}

function accountRow(r, a){
  const row = el("div", "mrow");
  const name = el("div", "mname");
  name.appendChild(el("b", null, a.builtin ? "Default — the install's own" : a.name));
  name.appendChild(el("span", null, a.dir + " · " + accountUsersText(a.used_by)));
  const st = accountStatusText(r.id, a.check);
  const sl = el("span", "acct-st" + (st.ok === true ? " ok" : st.ok === false ? " err" : ""));
  sl.appendChild(icon(st.ok === false ? "xcircle" : "check"));
  sl.appendChild(document.createTextNode(st.text));
  name.appendChild(sl);
  row.appendChild(name);
  const meta = el("div", "mmeta");
  if(!a.builtin){
    meta.appendChild(button("Edit", "pencil", () => { live.acctForm[r.id] = {mode: "edit", id: a.id, name: a.name, dir: a.dir}; paint(); }, live.busy[r.id]));
    meta.appendChild(button("Remove", "trash", () => removeAccount(r.id, a), live.busy[r.id]));
  }
  row.appendChild(meta);
  return row;
}

// Add or edit, as a row of its own. The directory field reuses the page's
// folder picker (a [data-cwd-target] button, delegated on the document),
// which sets .value with no event -- paint() reads both fields back into
// live.acctForm before every teardown, so a repaint never loses them.
function accountForm(r){
  const f = live.acctForm[r.id];
  const row = el("div", "mrow acctform");
  const ctrl = el("div", "ctrl");
  const nm = el("input"); nm.type = "text"; nm.id = "acct-name-" + r.id; nm.value = f.name || "";
  nm.placeholder = "Name — e.g. Client A";
  const dir = el("input"); dir.type = "text"; dir.id = "acct-dir-" + r.id; dir.value = f.dir || "";
  dir.placeholder = r.id === "anthropic" ? "~/.claude-client-a — the CLAUDE_CONFIG_DIR it signs in with" : "~/.codex-client-a — the CODEX_HOME it signs in with";
  const browse = el("button", "btn"); browse.type = "button"; browse.dataset.cwdTarget = dir.id;
  browse.appendChild(document.createTextNode("Browse…"));
  ctrl.appendChild(nm); ctrl.appendChild(dir); ctrl.appendChild(browse);
  ctrl.appendChild(button(f.mode === "edit" ? "Save" : "Add", "check", () => saveAccount(r.id), live.busy[r.id]));
  ctrl.appendChild(button("Cancel", null, () => { delete live.acctForm[r.id]; paint(); }, live.busy[r.id]));
  row.appendChild(ctrl);
  return row;
}

async function saveAccount(pid){
  const f = live.acctForm[pid]; if(!f) return;
  const n = $("acct-name-" + pid), d = $("acct-dir-" + pid);
  if(n) f.name = n.value; if(d) f.dir = d.value;
  const ok = f.mode === "edit"
    ? await change("platform_account_edit", {platform: pid, id: f.id, name: (f.name || "").trim(), dir: (f.dir || "").trim()})
    : await change("platform_account_add", {platform: pid, name: (f.name || "").trim(), dir: (f.dir || "").trim()});
  if(!ok) return;
  delete live.acctForm[pid];
  await loadAccounts(pid);
}

async function removeAccount(pid, a){
  const ok = await change("platform_account_remove", {platform: pid, id: a.id});
  if(ok) await loadAccounts(pid);
}

// Every account of an account platform, the Default first -- drawn like the
// Models section: a header strip, then one row each.
function accountsSection(r){
  const frag = document.createDocumentFragment();
  const head = el("div", "models-h");
  head.appendChild(el("h3", null, "Accounts"));
  head.appendChild(el("span", "age", r.id === "anthropic"
    ? "one per Claude config directory (CLAUDE_CONFIG_DIR) — jobs, projects and analyses pick one"
    : "one per Codex home (CODEX_HOME) — jobs, projects and analyses pick one"));
  head.appendChild(el("span", "sp"));
  head.appendChild(button("Add account", "plus", () => { live.acctForm[r.id] = {mode: "add", name: "", dir: ""}; paint(); },
    live.busy[r.id] || !!live.acctForm[r.id]));
  frag.appendChild(head);
  const list = live.accounts[r.id];
  const form = live.acctForm[r.id];
  if(!list){
    frag.appendChild(el("div", "mempty", live.busy[r.id] ? "Checking the accounts…" : "The accounts have not been checked yet — Test checks them."));
  } else {
    list.forEach(a => frag.appendChild(form && form.mode === "edit" && form.id === a.id ? accountForm(r) : accountRow(r, a)));
  }
  if(form && form.mode === "add") frag.appendChild(accountForm(r));
  return frag;
}
```

- Em `binaryBlock`, a seguir a `const inp = el("input"); inp.type = "text";`, acrescentar `inp.id = "bin-" + r.id;`.
- Em `platformCard`, entre `card.appendChild(g);` e `card.appendChild(modelsSection(r, entry, check, catalog));`, inserir:

```js
  if(ACCOUNT_PLATFORMS.includes(r.id) && entry.supported !== false) card.appendChild(accountsSection(r));
```

- Em `paint()`: logo a seguir a `const active = document.activeElement;`, inserir:

```js
  // The account form's two fields, typed into or filled by the folder picker
  // (which sets .value with no event): read back into live.acctForm before
  // the teardown below, so a repaint never loses them.
  ACCOUNT_PLATFORMS.forEach(pid => {
    const f = live.acctForm[pid]; if(!f) return;
    const n = $("acct-name-" + pid), d = $("acct-dir-" + pid);
    if(n) f.name = n.value;
    if(d) f.dir = d.value;
  });
```

  e no bloco do `savedFocus`: guardar também `inputId: active.id || ""` no objecto, e na reposição trocar `const inp = card && card.querySelector(".ctrl input");` por `const inp = savedFocus.inputId ? $(savedFocus.inputId) : (card && card.querySelector(".ctrl input"));`.

Em `ui/css/pages.css`, a seguir à regra `.mempty{…}`, acrescentar:

```css
/* Settings › Platforms, Accounts: read like Models -- one row per account;
   its state is a line of its own under the directory, allowed to wrap (a
   reason names a directory and a command); the add/edit form is a row too. */
.mname .acct-st{display:flex;align-items:center;gap:6px;white-space:normal;margin-top:2px}
.mname .acct-st .ic{width:13px;height:13px;flex:none}
.mname .acct-st.ok{color:var(--ok)} .mname .acct-st.err{color:var(--err)}
.acctform .ctrl{flex:1 1 auto;margin-top:0}
```

- [ ] **Step 4: `dashboard.html` — os três combos**

(a) Markup. Logo a seguir à linha `  <p class="fieldhelp" id="ed-platform-note">…</p>` inserir:

```html
  <div id="ed-account-row" hidden>
  <label>Account — which of the platform's sign-ins this job runs under</label>
  <div class="combo" id="ed-account-combo">
    <button type="button" class="combo-trigger" id="ed-account-trigger" aria-haspopup="listbox" aria-expanded="false">
      <span class="combo-val" id="ed-account-val">— Default —</span>
      <span class="combo-caret"></span>
    </button>
    <div class="combo-pop" id="ed-account-pop" hidden>
      <input type="text" class="combo-search" id="ed-account-search" placeholder="Search accounts…" autocomplete="off">
      <ul class="combo-list" id="ed-account-opts" role="listbox"></ul>
    </div>
    <input type="hidden" id="ed-account">
  </div>
  <p class="fieldhelp">Registered in Settings › Platforms. Empty follows the project's account when the job runs on the
    project's platform, and the Default otherwise; a resume always signs in where its session was created.</p>
  </div>
```

Logo a seguir ao `</p>` do `fieldhelp` que segue o combo `pj-platform-combo` (o parágrafo que começa `Anthropic is Claude Code, OpenAI is the Codex CLI, OpenCode is the OpenCode CLI (providers you` e acaba em `slot is taken).</p>`), inserir o mesmo bloco com `pj` no lugar de `ed`, a label `Account — which sign-in this project's runs use on its platform` e o texto de ajuda `Registered in Settings › Platforms. The project's jobs on this platform inherit it unless they pick their own; the Security tab can pick another for the analysis.`

Logo a seguir ao `</p>` do `fieldhelp` que segue o combo `sec-platform-combo` (o parágrafo que acaba em `the cost is what the CLI reports from its catalog.</p>`), inserir o mesmo bloco com `sec`, a label `Account` e o texto `Which sign-in runs the analysis — the project's account when the analysis runs on the project's platform, unless set here.`

(b) Configurações e combos. A seguir à `const secModelCfg=…;` (e à linha seguinte que a termina), inserir:

```js
// The three Account combos, configured by name so the paint functions below
// can relabel the empty row with what it resolves to -- createCombo keeps
// cfg by reference and reads noneLabel in set(). The project's own pick
// changes what the Security pane's empty row resolves to.
const edAccountCfg={id:"ed-account", allowNone:true, noneLabel:"— Default —", allowCustom:false};
const pjAccountCfg={id:"pj-account", allowNone:true, noneLabel:"— Default —", allowCustom:false,
  onPick:()=>paintSecurityAccount(true)};
const secAccountCfg={id:"sec-account", allowNone:true, noneLabel:"— Default —", allowCustom:false};
let edAccountCombo=null, pjAccountCombo=null, secAccountCombo=null;
```

Em `initCombos()`, a seguir a `modelCombo.set("opus", modelOptions("anthropic"));`, inserir:

```js
  edAccountCombo=createCombo(edAccountCfg);
  pjAccountCombo=createCombo(pjAccountCfg);
  secAccountCombo=createCombo(secAccountCfg);
```

trocar `onPick:(v)=>syncCwdField(v)});` (o do `projectCombo`) por `onPick:(v)=>{ syncCwdField(v); paintJobAccount(true); }});`, e trocar o `onPick` do `pjPlatformCombo` por:

```js
    onPick:()=>{ paintProjectAccount(false);
                 if(!$("sec-platform").value && secEffectivePlatform()!==secPlatApplied) applyPlatformToSecurity(secEffectivePlatform(), false);
                 else paintSecurityAccount(true); }});
```

(c) Pintura. A seguir à função `paintLimitsNote`, inserir:

```js
// One editor's Account combo, rebuilt for platform `p`: hidden while the
// platform has nothing to pick besides the Default, the empty row saying
// what it resolves to, and the value kept only while it is still one of p's
// (`keep`) -- or flagged when Settings dropped it (accountOptions).
function paintAccountCombo(prefix, combo, cfg, p, keep, inheritName){
  if(!combo) return;
  $(prefix+"-account-row").hidden=!ALApp.accountChoice(p, PLATFORMS);
  cfg.noneLabel=ALApp.accountNoneLabel(inheritName);
  const cur=keep ? $(prefix+"-account").value : "";
  const opts=ALApp.accountOptions(p, PLATFORMS, cur);
  combo.set(opts.some(o=>o.v===cur) ? cur : "", opts);
}
function paintJobAccount(keep){
  const p=$("ed-platform").value||"anthropic", np=$("ed-project").value.trim();
  paintAccountCombo("ed", edAccountCombo, edAccountCfg, p, keep,
    ALApp.inheritedAccountName(p, np?projById(np):null, PLATFORMS));
}
function paintProjectAccount(keep){
  paintAccountCombo("pj", pjAccountCombo, pjAccountCfg, $("pj-platform").value||"anthropic", keep, "");
}
function paintSecurityAccount(keep){
  const sp=secEffectivePlatform();
  paintAccountCombo("sec", secAccountCombo, secAccountCfg, sp, keep,
    ALApp.inheritedAccountName(sp, {platform:$("pj-platform").value||"anthropic", account:$("pj-account").value||""}, PLATFORMS));
}
```

Em `applyPlatformToJobEditor`, antes de `  edPlatApplied=p;`, inserir `  paintJobAccount(keep);`. Em `applyPlatformToSecurity`, antes de `  secPlatApplied=p;`, inserir `  paintSecurityAccount(keep);`. Em `refillPlatformBound`, no fim, inserir `  paintProjectAccount(true);`.

(d) Abrir. Em `fill(j)`, logo a seguir à linha `  applyPlatformToJobEditor(plat, false);`, inserir:

```js
  // The job's own account, drawn against the platform just applied: an
  // account Settings no longer has shows flagged, never rewritten.
  $("ed-account").value=j.account||"";
  paintJobAccount(true);
```

Em `openProjectEditor`, logo a seguir à linha `  pjPlatformCombo.set(pjp, ALApp.platformOptions(PLATFORMS, pjp));`, inserir:

```js
  $("pj-account").value=(p&&p.account)||"";
  paintProjectAccount(true);
```

e, logo a seguir à linha `  applyPlatformToSecurity(splat, false);` (que pinta o combo do bloco com `keep=false`, isto é, vazio), inserir:

```js
  $("sec-account").value=sec.account||"";
  paintSecurityAccount(true);
```

(e) Gravar. Em `saveEditor`: no ramo de criação, a seguir a `if(f.interactive) job.interactive=true;`, inserir `      if($("ed-account").value) job.account=$("ed-account").value;`; no ramo de edição, a seguir à linha `    if(platSent){ if(!await api("set_field",{id,field:"platform",value:f.platform})) return; }`, inserir:

```js
    // The account after the platform -- a platform change clears one the new
    // platform does not have -- and re-sent with it, like the model below.
    if(!await setF("account",$("ed-account").value,j.account||"",platSent)) return;
```

Em `saveProject`, a seguir a `    proj.platform=$("pj-platform").value||"anthropic";`, inserir:

```js
    // Always sent, like the platform: empty is how a project goes back to the Default.
    proj.account=$("pj-account").value||"";
```

e, no objecto `proj.security`, a seguir a `      platform: $("sec-platform").value,`, inserir `      account: $("sec-account").value||"",`.

- [ ] **Step 5: `dashboard.html` — o detalhe do run**

Substituir `reopenCommand` por:

```js
function reopenCommand(rec, a){
  const sid=(a&&a.session)||rec.session||"";
  // The account travels in the environment, not the argv: without it the CLI
  // looks for the session in its own default directory, where it is not.
  const dir=(rec&&rec.account_dir)||"";
  const q=/^[A-Za-z0-9_.\/~@+-]+$/.test(dir) ? dir : "'"+dir.replace(/'/g,"'\\''")+"'";
  const env=dir ? ((rec.platform==="openai" ? "CODEX_HOME=" : "CLAUDE_CONFIG_DIR=")+q+" ") : "";
  return env+((({openai: "codex exec resume ", opencode: "opencode run --dir <run dir> -s "})[(rec&&rec.platform)] || "claude --resume ") + sid);
}

/* Which account the run signed in as -- a row only when it is not simply the
   Default on the CLI's own directory, which every run of a single-account
   install without a pin is. */
function accountCell(rec){
  const id=rec.account||"", dir=rec.account_dir||"";
  if((!id || id==="default") && !dir) return "";
  const name=ALApp.accountName(rec.platform, id||"default", PLATFORMS);
  const gone=!!id && id!=="default" && !ALApp.accountsOf(rec.platform, PLATFORMS).some(a=>a.id===id);
  return esc(name)+(gone?' <span class="muted">(no longer in Settings)</span>':'')+(dir?' · <code>'+esc(dir)+'</code>':'');
}
```

Em `renderLog`, a seguir à entrada `    ["Platform", esc(ALApp.platformLabel(rec.platform))],`, inserir `    ...(accountCell(rec) ? [["Account", accountCell(rec)]] : []),`.

- [ ] **Step 6: Bundles e testes**

```bash
bash build/build-ui.sh
python3.13 -m pytest tests --ignore=tests/security -p no:cacheprovider -q
```

Esperado: tudo verde. E o bloco dos artefactos da UI (o marcador final entre plicas, para o shell não expandir `$pass`):

```bash
$BLOCK "the committed UI artifacts — built from the sources" '$pass passed'
```

Esperado: `fail=0` — os três bundles batem com as fontes e com os próprios carimbos.

- [ ] **Step 7: CHANGELOG e commit**

Acrescentar ao ponto da funcionalidade: `Settings › Platforms lists every account of Anthropic and OpenAI with its session and who runs on it, and adds, edits and removes them; the job, project and Security editors pick Platform → Account → Model, the Account combo showing only where there is a choice; the run dialog names the account, and its reopen line carries the variable.`

```bash
/usr/bin/git add ui bin/dashboard.html bin/static tests/test_page_contract.py CHANGELOG.md
/usr/bin/git commit -m "feat(dashboard): Settings manages the accounts, and the editors pick platform, account, model

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Documentação, verificação final e aceitação real

**Files:**
- Modify: `README.md`, `CHANGELOG.md`

- [ ] **Step 1: README**

Substituir a secção inteira `### Which Claude account a run signs in as` (até à linha `---` que a encerra, exclusive) por:

````markdown
### Accounts — which sign-in a run uses

Claude Code keeps credentials, settings, plugins, MCP servers, skills and past
sessions **per config directory** — one signed-in account each — and the Codex
CLI does the same per `CODEX_HOME`. If you keep several accounts on one Mac
(a client's and your own, say), the directory is what chooses between them:

```bash
CLAUDE_CONFIG_DIR=~/.claude-client-a claude auth login
CODEX_HOME=~/.codex-client-a codex login          # mkdir -p ~/.codex-client-a first
```

Sign in without a trailing slash: Claude Code names the Keychain entry that
holds the session after the exact directory string it was given.

**Every platform has a Default** — the install's own: the pin below, or the
CLI's own `~/.claude`; the engine's `CODEX_HOME`, or `~/.codex`. **Settings ›
Platforms › Accounts** registers the others, one row per directory, each with
the session it holds (*Signed in as …*, or the login to run) and who runs on
it; the same from the terminal:

```bash
agentloop platform accounts anthropic                                   # every account, with its session
agentloop platform account-add anthropic "Client A" ~/.claude-client-a  # register one
agentloop platform check anthropic client-a                             # its session, live
agentloop platform account-edit anthropic client-a "Client A" ~/.claude-a
agentloop platform account-remove anthropic client-a                    # refused while anything uses it
```

**Who runs where.** The job editor, the project editor and the Security tab
pick **Platform → Account → Model** (the Account list appears once a platform
has an account besides the Default). A job runs on its own account; without
one, on its project's when the job runs on the project's platform; else on
the Default. A security analysis follows the same rule against its block. A
**resume** always signs in where its session was created — the journal
records the account and the directory of every run — whatever the job says
today.

**What follows the account.** The agent and its precheck run with the
account's variable (an account on the CLI's own directory runs with the
variable *unset*: set, even to `~/.claude`, Claude Code looks for another
Keychain entry); a run whose account is gone, whose directory is gone, or
which has no session is refused in `tick.log` before a slot is taken; the
Codex rollout is read from the run's own `CODEX_HOME`; the usage-window gate
is the account's own (`data/rate-limits.json` keys every account directory as
`<platform>@<dir>`), and the statusline feeds the account its session runs as
— wire it in each account's own `settings.json`; the agentloop skills are
linked into every account directory. The model probes and the catalog
refreshes run on the Default. OpenCode has no accounts: its credentials are
the providers configured in opencode itself.

**The pin.** `launchd` inherits nothing from your shell, so the Default's
Claude account is set at install time:

```bash
AGENTLOOP_CLAUDE_CONFIG_DIR=~/.claude-work bash install.sh
```

The value is written into both `launchd` plists — under
`AGENTLOOP_CLAUDE_CONFIG_DIR`, the name the engine reads, and under
`CLAUDE_CONFIG_DIR` beside it — and re-running the installer without the
variable keeps it. A run you type yourself (`agentloop run <id>`) reads only
the explicit variable, never the `CLAUDE_CONFIG_DIR` your shell exports.

**From before accounts.** `agentloop install` turns a `claude_config_dir`
still in `config/projects.json` into an account and sets it on the level that
carried it; `status` names any it could not convert.
````

- [ ] **Step 2: CHANGELOG final**

Reescrever o ponto da funcionalidade (o que a Task 1 abriu e as seguintes alargaram) num só texto coerente, com o mesmo conteúdo, a começar por `**Accounts per platform: a job, a project and an analysis run under the Claude or Codex account they pick.**` e a dizer, por esta ordem: o que o cliente tem (várias contas, uma pasta cada); Settings (lista, sessão, quem usa, add/edit/remove, e a linha de comandos); a escolha e a regra de herança; o que segue a conta (ambiente e precheck, portas, journal e resume, rollout, limites, statusline, skills); o que corre sempre na Default; a migração do `claude_config_dir`. Em `### Changed`, manter o ponto da Task 4 sobre o pin e acrescentar:

```markdown
- **`claude_config_dir` in `projects.json` is converted, not ignored.**
  `install` turns it into an account; the warning in `status` and `install`
  now names only what it could not convert, and why.
```

- [ ] **Step 3: Verificação final (rápida, local)**

```bash
python3.13 -m pytest tests --ignore=tests/security -p no:cacheprovider -q
$E2E1 1 2 3 12 13 14 15 18 20 25 26 27 47 48 49 50 51 52
$BLOCK "accounts — the sign-ins Settings registers" "resolve_pricing_openai() — the price table refreshes itself"
$BLOCK "the changelog moves when main moves" "a human's board move is an answer"
```

Esperado: tudo verde. O último bloco verifica o CHANGELOG, os home dirs em ficheiros versionados e a skill `security-analysis`.

- [ ] **Step 4: Aceitação real (CLIs verdadeiros, configuração de rascunho)**

Nunca na instalação viva. Numa pasta de rascunho `$A` (no scratchpad, fora de qualquer repositório git):

```bash
mkdir -p "$A/config" "$A/data" "$A/empty-claude" "$A/empty-codex" "$A/work" "$A/scratch-claude"
cp config/pricing.example.json "$A/config/pricing.json"
printf '{"projects":[{"name":"acc","cwd":"%s","worktree":{"enabled":false}}]}\n' "$A/work" > "$A/config/projects.json"
printf '{"jobs":[]}\n' > "$A/config/jobs.json"
printf '{"platforms":{"anthropic":{"enabled":true,"bin":"","models":["claude-haiku-4-5-20251001"],"accounts":[{"id":"home","name":"Home","dir":"~/.claude"}]},"openai":{"enabled":true,"bin":"","models":["gpt-5.6-luna"],"accounts":[{"id":"home","name":"Home","dir":"~/.codex"}]},"opencode":{"enabled":false,"bin":"","models":[]}}}\n' > "$A/config/platforms.json"
export AGENTLOOP_CONFIG="$A/config" AGENTLOOP_DATA="$A/data"
export AGENTLOOP_CLAUDE_CONFIG_DIR="$A/empty-claude"    # the Default: a directory with no session
export CODEX_HOME="$A/empty-codex"                      # the Codex Default: a home with no session
PATH="$WT/bin:$PATH"
agentloop resolve-models openai
```

A conta `Home` entra escrita directamente no `platforms.json` de rascunho, nunca por `account-add`: esse comando liga as skills da árvore em execução a `<dir>/skills`, e feito a partir de um worktree isso reapontaria os links da instalação viva em `~/.claude/skills` e `~/.codex/skills` para um worktree que é apagado depois do merge. Os verbos em si exercitam-se à parte, sobre um directório de rascunho:

```bash
agentloop platform account-add anthropic "Scratch" "$A/scratch-claude"
agentloop platform account-edit anthropic scratch "Scratch" "$A/scratch-claude"
agentloop platform account-remove anthropic scratch
agentloop platform accounts anthropic | jq -c '.[] | {id, dir, ready: .check.ready}'
agentloop platform accounts openai | jq -c '.[] | {id, dir, ready: .check.ready}'
```

Esperado: a Default das duas plataformas `ready:false` (pastas vazias), a conta `home` `ready:true` nas duas.

Criar dois jobs baratos (`printf '{"id":"acc-c","project":"acc","account":"home","model":"claude-haiku-4-5-20251001","prompt":"Reply with the single word OK, then end your run as the contract says.","enabled":false}' | agentloop create` e o equivalente `acc-o` com `"platform":"openai","model":"gpt-5.6-luna","permission_mode":"read-only"`), mais um `acc-d` na Default Claude, e correr `agentloop run acc-d`, `agentloop run acc-c`, `agentloop run acc-o`. Esperado:

- `acc-d` recusado no `tick.log` com `claude is not signed in in $A/empty-claude (run: CLAUDE_CONFIG_DIR=$A/empty-claude claude auth login)`;
- `acc-c` no estado que a resposta do agente ao contrato render — uma resposta NOTHING TO DO dá `warning`, que nada diz sobre contas; o que prova a conta é o registo a dizer `"account":"home","account_dir":""` e a ausência de qualquer recusa (correu com a variável por definir, o único caminho para a sessão real do `~/.claude`);
- `acc-o` `success`, `model_id` lido do rollout em `~/.codex/sessions` e `data/rate-limits.json` com o bloco `openai` (a chave do `~/.codex`) e sem `openai@$A/empty-codex`.

Depois, servidor de rascunho numa porta que não a 8787 (`AGENTLOOP_PORT=8798 python3 "$WT/bin/agentloop-server"` em segundo plano) e, no browser integrado, confirmar: o bloco Accounts nos cartões Anthropic e OpenAI (Default *Not signed in* com o comando, Home *Signed in as …*); o combo Account nos três editores, depois de Platform e antes de Model; e, no detalhe dos runs `acc-c` e `acc-o`, a linha Account e o comando de reabrir. No fim: matar o servidor pelo PID, `unset` das variáveis, e apagar `$A`.

- [ ] **Step 5: Commit**

```bash
/usr/bin/git add README.md CHANGELOG.md
/usr/bin/git commit -m "docs: accounts per platform -- Settings, the editors, and what follows the account

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
