# Plataformas Anthropic e OpenAI — plano B1, o engine

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** um job com `platform: openai` corre no Codex CLI a partir da linha de comandos — lançado, vigiado, classificado, custeado por estimativa, registado no journal e na base de dados, com resume, stop, rate limits por plataforma e recusas honestas no `tick.log` — sem que nenhum job Anthropic mude de comportamento.

**Architecture:** o Codex é traduzido na fronteira. `bin/platforms/openai_stream.py` lê o JSONL de `codex exec --json` por um FIFO e escreve o `stream-json` que todos os leitores existentes já conhecem; o engine ganha uma tabela de plataformas (funções `platform_*`, um `case "$platform"` em cada) que o `run_job` consulta em vez de nomear `$CLAUDE_BIN`; o custo OpenAI é estimado no normalizador a partir de `config/pricing.json`; o modelo real e os rate limits são lidos do rollout do Codex no fim do run. A dashboard (plano B2, a seguir) só lê o que este plano grava — este plano não toca em `ui/` nem em `bin/dashboard.html`.

**Tech Stack:** bash 3.2 (macOS), jq, Python 3 stdlib (normalizador e servidor), pytest em `python3.13`, Codex CLI 0.148.0 (medido), `test/fake-codex` como stand-in offline.

**Spec:** [`docs/superpowers/specs/2026-09-06-platforms-anthropic-openai-design.md`](../specs/2026-09-06-platforms-anthropic-openai-design.md), com a secção *Correcções por medição (2026-09-07)* que a Tarefa 1 lhe acrescenta. Evidência: [`docs/superpowers/specs/2026-09-06-codex-measurements/`](../specs/2026-09-06-codex-measurements/README.md).

**Âmbito deste plano (B1) e do seguinte (B2):** B1 é tudo o que corre sem browser — normalizador, tabela de plataformas, lançamento, catálogo, esquema de configuração, journal/base de dados/API de dados, rate limits, README do engine. B2 é a dashboard (Platform → Model nos três editores, cartões, tabelas, modal, Overview), a análise de segurança em OpenAI (prompt, skills em `~/.codex/skills`), `install.sh`/`status` a reportarem o `codex`, e a aceitação da análise real. A API `/api/models` fica neste plano com **as chaves antigas intactas** (`models`, `efforts`) e a nova (`platforms`) ao lado, para a página actual continuar a funcionar até B2.

## Global Constraints

- **Bash 3.2:** sem arrays associativos, sem `mapfile`; `case` dentro de `$( )` parte em runtime e o `bash -n` não apanha — validar a correr. Uma função que "devolve" uma lista devolve-a por stdout (uma por linha) ou numa variável global nomeada (`PLATFORM_ARGV`, `PF_MODEL_ID`, `PF_ROLLOUT`).
- **CHANGELOG na mesma commit:** `agentloop selftest` falha quando a última commit (sem merges) que tocou `bin/`, `skills/` ou `test/` é mais recente do que a última que tocou `CHANGELOG.md`. **Toda** a commit que toque `bin/` ou `test/` (fixtures incluídas) leva a sua linha no CHANGELOG, na entrada *OpenAI platform* sob `## [Unreleased]` → `### Added`, que a Tarefa 1 abre e as seguintes alargam.
- **O ramo Anthropic do `run_job` não muda.** A linha `args="-p --output-format stream-json …"`, o array `toolargs`, o ramo interactivo e o ramo normal ficam byte a byte como estão; o ramo OpenAI é um `elif` novo antes deles. O selftest já lê o argv real de um lançamento Anthropic e continua verde.
- **Factos medidos do Codex CLI 0.148.0, que o código segue e nunca contradiz:**
  - `codex exec --json --skip-git-repo-check -C <dir> -m <slug> [-c model_reasoning_effort=<e>] (-s <mode> -c approval_policy=never | --dangerously-bypass-approvals-and-sandbox) -- <prompt> </dev/null`; sem `</dev/null` o processo fica pendurado.
  - `codex exec resume --json --skip-git-repo-check -m <slug> [-c …] [-c sandbox_mode=<mode>] <thread_id> -- <prompt> </dev/null`; `resume` **não** aceita `-s` nem `-C`, opera no cwd do processo (medição 11), devolve o mesmo `thread_id` (03), aceita `--` antes do prompt (13).
  - Valores de `-c` **sem aspas**: o CLI tenta TOML e cai para string literal (`--help`); é assim que as medições 05b, 07 e 11 os passaram. Escrever `-c model_reasoning_effort=ultra`, nunca `-c model_reasoning_effort="ultra"`.
  - Eventos: `thread.started{thread_id}`, `turn.started`, `item.started/completed{item:{id,type,…}}`, `turn.completed{usage}`, `turn.failed{error.message}`, `error{message}`; exit 0/1; sem dólares, sem modelo no stream.
  - Tipos de item vistos: `agent_message{text}`, `command_execution{command,aggregated_output,exit_code,status}`, `file_change{changes:[{path,kind}],status}` (10), `collab_tool_call{tool,sender_thread_id,receiver_thread_ids,prompt,agents_states,status}` (17), `error{message}` (04).
  - `usage`: `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`; **`output_tokens` inclui `reasoning_output_tokens`** (15: 42 ≥ 35; 10: 90 ≥ 27).
  - `ultra` é um esforço aceite (14). `--strict-config` recusa chaves `-c` desconhecidas (05a).
  - **Os subagentes do Codex não se fecham por flag** (16a/16b/17): `--disable multi_agent` deixa `collaboration.spawn_agent` no roster e um spawn corre na mesma. Nenhum código emite `--disable multi_agent`; `disallowed_tools` e `allowed_tools` são **ignorados** em OpenAI com uma linha no `tick.log`.
  - stderr traz sempre `Reading additional input from stdin...`; uma negação de sandbox não gera evento; modelo desconhecido → `item.completed{type:error}` + `error` + `turn.failed` com `{"status":400,…}` embebido, exit 1; quota esgotada → `error` + `turn.failed` com "hit your usage limit", exit 1.
  - O modelo real (`turn_context.model`) e os rate limits (`token_count.rate_limits.primary` 300 min / `secondary` 10080 min, `used_percent`, `resets_at`, `plan_type`, `rate_limit_reached_type`) vivem no rollout `${CODEX_HOME:-~/.codex}/sessions/YYYY/MM/DD/rollout-<ts>-<thread_id>.jsonl`; um resume acrescenta ao mesmo ficheiro.
  - `codex debug models` (e `--bundled`, offline) devolve `{"models":[{slug, display_name, description, default_reasoning_level, supported_reasoning_levels[].effort, visibility (list|hide), priority, upgrade{model,retirement_at}|null, …}]}` em 0 s. `codex login status` devolve 0 com sessão iniciada. O binário desta máquina é `/opt/homebrew/bin/codex`.
- **Nomes, verbatim:** campo `platform` ∈ {`anthropic`,`openai`} em job, projecto e bloco `security`; `AGENTLOOP_CODEX_BIN` (override), `CODEX_BIN`, `CODEX_HOME_DIR`; `PRICING_FILE` = `config/pricing.json`, exemplo `config/pricing.example.json`; `bin/platforms/openai_stream.py` com `--model --permission --cwd --pricing --raw-out`; ficheiro cru `<stem>.stream.ndjson.raw`; funções `platform_known`, `platform_bin`, `platform_ready`, `platform_caps`, `platform_stderr_filter`, `platform_finish`, `platform_effort_ok`, `platform_permission_ok`, `platform_model_ok`, `platform_default_model`, `platform_default_permission`, `platform_permissions`, `platform_efforts`, `platform_argv_openai` (enche `PLATFORM_ARGV`), `openai_catalog_available`, `openai_catalog_ensure`, `openai_catalog_slugs`, `openai_catalog_visible`, `openai_catalog_efforts`, `openai_catalog_default_effort`, `openai_catalog_successor`, `resolve_models_openai`, `rl_migrate`, `rl_capture_openai`, `rl_gate <platform>`, `journal_platform_of_session`, `cmd_platforms`; comandos `agentloop resolve-models [anthropic|openai]` e `agentloop platforms`; journal `platform`, `cost_basis` (`reported`|`estimated`|`none`), `tokens` (`{input,cached,cache_write,output,reasoning}` ou `null`); colunas `platform TEXT`, `cost_basis TEXT`, `tokens TEXT`; `SCHEMA_VERSION = "6"`; hooks `AL_PLATFORM`, `AL_COST_BASIS`, `AL_TOKENS` (só `AL_*`: são nomes novos, a exportação dupla cobre apenas os que existiam antes da renomeação); `data/rate-limits.json` com blocos `anthropic` e `openai`; stand-in `test/fake-codex` (`FAKE_SESSION`, `FAKE_MODE` complete|undeclared|dirty|hang|quota|unknown_model, `FAKE_ARGV_OUT`, `FAKE_CODEX_LOGGED_OUT`); fixtures em `test/fixtures/codex/`; servidor `PLATFORM_PERMISSIONS`, `list_models()` com `platforms`.
- **Vocabulários:** permissões Anthropic `acceptEdits auto bypassPermissions manual dontAsk plan`; OpenAI `read-only workspace-write full-access`; esforços Anthropic `low medium high xhigh max`; OpenAI os `supported_reasoning_levels` do modelo (hoje `low…max`, mais `ultra` em 5.6-sol e 5.6-terra). Defaults: Anthropic `opus`/`dontAsk` (job) e `bypassPermissions` (segurança); OpenAI o primeiro `visibility: list` por `priority` ascendente (hoje `gpt-5.6-sol`)/`workspace-write` (job) e `full-access` (segurança).
- **Suites a correr no fim de cada tarefa** (todas offline; o pytest só existe em `python3.13`; a suite `security` precisa das três variáveis Trivy e da desselecção do teste que se auto-lança — o suite completo com ele demora ~6 min):

  ```bash
  bin/agentloop selftest
  python3.13 -m pytest -p no:cacheprovider tests/ -q --ignore=tests/security
  TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true python3.13 -m pytest -p no:cacheprovider tests/security -q --deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on
  bash test/e2e.test.sh
  ```

- **Worktree:** a execução corre num worktree (`superpowers:using-git-worktrees`). Nele o guarda do Bash recusa comandos compostos e qualquer `rtk git`: um comando simples por chamada, `/usr/bin/git` para o git. `CODEX_HOME` e `HOME` reais nunca são tocados por um teste: o e2e aponta `CODEX_HOME` para a sandbox, o selftest para `$tmp`.
- **Branch:** `feat/platforms-engine`, cortado de `main` (que já contém os PRs #26, #27 e #28). Código, comentários, mensagens de commit e documentação entregue em inglês; prosa deste plano em pt-PT. Nunca escrever o nome antigo do produto num comentário novo: `tests/test_no_old_name_survives.py` apanha-o. Trailer de commit: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- **Preços:** os cinco valores em `config/pricing.example.json` foram lidos de https://openai.com/api/pricing/ a 2026-09-07 e **têm de ser confirmados pelo operador** antes do PR ser fundido (é a nota na descrição do PR). Um `null` conta como "sem preço", nunca como zero.

---

## Correcções à spec por medição (2026-09-07)

A Tarefa 1 escreve esta tabela na própria spec. Aqui fica para o implementador de qualquer tarefa a ter à mão.

| A spec dizia | Medido | Consequência neste plano |
|---|---|---|
| `--disable multi_agent` fecha os subagentes; `disallowed_tools: Agent` traduz-se nessa flag | 16a/16b/17: o roster mantém `collaboration.spawn_agent` com a flag e um spawn corre | nenhuma flag; `allowed_tools`/`disallowed_tools` ignorados em OpenAI com linha no `tick.log`; a análise de segurança em OpenAI (B2) proíbe subagentes por prompt |
| resume: cwd "a confirmar", `-c sandbox_mode` "a confirmar" | 11: opera no cwd do **processo**; `-c sandbox_mode=workspace-write` aceite em `--strict-config` | `cd "$run_cwd"` antes do `exec`, `-c sandbox_mode=<mode>` em vez de `-s` num resume |
| `--` antes do prompt "a confirmar" | 12/13: aceite em `exec` e em `exec resume` | `-- "$prompt"` sempre, como no ramo Anthropic |
| `ultra` "a confirmar" | 14: aceite | o vocabulário de esforço OpenAI vem do catálogo, `ultra` incluído |
| reasoning ⊂ output "a confirmar" | 15: `output_tokens` 42 ≥ `reasoning_output_tokens` 35 | a estimativa cobra `output_tokens` uma vez; `reasoning` é informativo |
| forma de `file_change` desconhecida | 10: `{id,type:"file_change",changes:[{path,kind}],status}` | `tool_use` genérico com `description` "add <path>" para a Timeline |
| preços por preencher | lidos a 2026-09-07 (sol 4/0.40/20, terra 2/0.20/12, luna 0.20/0.02/1.20, 5.5 5/0.50/30, 5.4-mini 0.75/0.075/4.50, USD por 1M; cache write 0) | `config/pricing.example.json` preenchido; **confirmar com o operador** |
| valores de `-c` escritos com aspas | as medições passaram-nos sem aspas e o CLI documenta o fallback para string | sem aspas, sempre |

---

## Estrutura de ficheiros

| Ficheiro | Responsabilidade neste plano |
|---|---|
| `test/fixtures/codex/*.jsonl`, `models-catalog.stripped.json`, `rollout-sample.stripped.jsonl` (novos, T1) | as medições, copiadas para onde os testes as lêem; a pasta das specs fica como registo do dia |
| `bin/platforms/openai_stream.py` (novo, T2) | o normalizador: Codex JSONL → stream-json canónico, estimativa de custo, cópia crua |
| `tests/test_openai_stream.py` (novo, T2) | pytest do normalizador sobre as fixtures; a estimativa; o CLI por subprocesso |
| `config/pricing.example.json` (novo, T2), `.gitignore`, `install.sh` | a tabela de preços versionada; a pessoal semeada e ignorada |
| `bin/agentloop` — bloco `# --- platforms ---` (T3) | a tabela de plataformas; `PLATFORM_ARGV`; `platform_finish` com `PF_MODEL_ID`/`PF_ROLLOUT` |
| `bin/agentloop` — `run_job` (T3, T6) | resolução de `platform`; recusas; ramo de lançamento OpenAI por FIFO; `wait` do normalizador; filtro de stderr; `model_id` do rollout; `cost_basis`/`tokens`; resume na plataforma do run |
| `test/fake-codex` (novo, T3) | o stand-in do Codex: emite as formas medidas, escreve um rollout, responde a `login status` e `debug models` |
| `test/e2e.test.sh` (T3, T5, T6, T7) | cenários 13–20: run OpenAI completo/undeclared/dirty, argv, resume, stop, quota, recusas |
| `bin/agentloop` — catálogo (T4) | `resolve_models_openai`, `cmd_resolve_models [platform]`, `models_stale` sobre os dois blocos, leitores `openai_catalog_*`, `cmd_platforms` |
| `bin/agentloop-server` — `list_models`, `PLATFORM_PERMISSIONS` (T4) | `/api/models` por plataforma, chaves antigas intactas |
| `tests/test_platforms_api.py` (novo, T4) | forma de `/api/models`; as permissões do servidor iguais às do engine |
| `bin/agentloop` — `cmd_set_field`, `cmd_create`, `security_derived_jobs` (T5) | `platform` como campo; validação por plataforma; reescrita ao mudar de plataforma; defaults |
| `config/jobs.example.json` (T5) | um segundo job de exemplo, desligado, em `openai` |
| `bin/agentloop` — `record_run`, `run_end_hook`, `_stop_slot` (T6) | `platform`, `cost_basis`, `tokens` no journal e nos hooks |
| `bin/agentloop-server` — esquema, `_upsert`, `ingest`, `_artifact_paths`, `load_data`, `load_run_detail`, `load_live_detail` (T6) | colunas aditivas, backfill, `.raw` podado, campos novos na API de dados |
| `tests/test_platform_runs.py` (novo, T6) | migração da base de dados; backfill; `/api/data`; detalhe com `tokens`; `.raw` podado |
| `bin/agentloop` — `rl_*`, `cmd_usage`; `bin/statusline-rate-limits.sh` (T7) | `rate-limits.json` por plataforma, migração, `rl_capture_openai`, `rl_gate <platform>` |
| `README.md`, `CHANGELOG.md` (T1, T8) | a entrada do CHANGELOG; secção *Platforms* e as secções *Models*, *Effort*, *Budgets*, *CLI* |

---

### Task 1: A evidência vai para as fixtures, a spec é corrigida, o CHANGELOG abre a entrada

**Files:**
- Create: `test/fixtures/codex/` (cópias de `docs/superpowers/specs/2026-09-06-codex-measurements/*.jsonl`, `models-catalog.stripped.json`, `rollout-sample.stripped.jsonl`, `stderr-every-run.txt`; e `quota-exhausted.jsonl`, cópia de `test/fixtures/codex-exec-quota-exhausted.jsonl`)
- Modify: `docs/superpowers/specs/2026-09-06-codex-measurements/README.md` (linhas 10–17), `docs/superpowers/specs/2026-09-06-platforms-anthropic-openai-design.md` (secção nova), `CHANGELOG.md`
- Os nove ficheiros de medição de 2026-09-07 (`10-…` a `17-…`) já estão versionados na pasta das specs: entraram no PR deste plano. O que falta são as linhas do README das medições e a secção da spec.

**Interfaces:**
- Produces: `test/fixtures/codex/<nome>` — os caminhos que `tests/test_openai_stream.py` (T2), `test/fake-codex` (T3) e o selftest (T7) lêem. Nomes exactos: `01-trivial-turn.jsonl`, `02-tool-use.jsonl`, `03-resume-same-thread.jsonl`, `04-unknown-model.jsonl`, `05b-model-reasoning-effort-low.jsonl`, `06-stdin-closed.jsonl`, `07-approval-policy-never.jsonl`, `08-sandbox-denial-read-only.jsonl`, `09-disable-multi-agent.jsonl`, `10-file-change-workspace-write.jsonl`, `11-resume-from-other-cwd-sandbox-mode.jsonl`, `12-dashdash-before-prompt-exec.jsonl`, `13-dashdash-before-prompt-resume.jsonl`, `14-effort-ultra.jsonl`, `15-effort-high-reasoning-tokens.jsonl`, `17-spawn-under-disable-multi-agent.jsonl`, `quota-exhausted.jsonl`, `models-catalog.stripped.json`, `rollout-sample.stripped.jsonl`, `stderr-every-run.txt`.

- [ ] **Step 1: Copiar a evidência para `test/fixtures/codex/`**

```bash
mkdir -p test/fixtures/codex
cp docs/superpowers/specs/2026-09-06-codex-measurements/*.jsonl test/fixtures/codex/
cp docs/superpowers/specs/2026-09-06-codex-measurements/models-catalog.stripped.json test/fixtures/codex/
cp docs/superpowers/specs/2026-09-06-codex-measurements/stderr-every-run.txt test/fixtures/codex/
cp test/fixtures/codex-exec-quota-exhausted.jsonl test/fixtures/codex/quota-exhausted.jsonl
ls test/fixtures/codex | wc -l
```

Expected: `20` (dezasseis `.jsonl` de medição, o rollout, a quota, o catálogo, o stderr). O ficheiro `rollout-sample.stripped.jsonl` vem com o glob `*.jsonl`.

- [ ] **Step 2: Acrescentar as linhas 10–17 ao README das medições**

Em `docs/superpowers/specs/2026-09-06-codex-measurements/README.md`, logo a seguir à linha da tabela que começa por `| `09-disable-multi-agent.jsonl` |`, inserir:

```markdown
| `10-file-change-workspace-write.jsonl` | `-s workspace-write`, pedir para criar um ficheiro | a forma de `file_change`: `{id, type, changes:[{path, kind}], status}`, em `item.started` e `item.completed`; `reasoning_output_tokens` 27 ≤ `output_tokens` 90 |
| `11-resume-from-other-cwd-sandbox-mode.jsonl` | `codex exec resume --json --strict-config -c sandbox_mode=workspace-write <thread_id>` lançado com o processo noutra pasta, pedindo o cwd | o resume opera no cwd do **processo** (o ficheiro nasceu na pasta nova), e `-c sandbox_mode` é aceite em `--strict-config`; o `thread_id` é o mesmo do run 10 |
| `12-dashdash-before-prompt-exec.jsonl` | `codex exec --json … -- 'Reply with exactly: dashdash'` | `--` antes do prompt é aceite em `exec` |
| `13-dashdash-before-prompt-resume.jsonl` | `codex exec resume --json <thread_id> -- 'Reply with exactly: dashdash-resume'` | `--` antes do prompt é aceite em `exec resume` |
| `14-effort-ultra.jsonl` | `--strict-config -c model_reasoning_effort=ultra` em `gpt-5.6-sol` | `ultra` é aceite |
| `15-effort-high-reasoning-tokens.jsonl` | `-c model_reasoning_effort=high`, um problema de contas | `reasoning_output_tokens` 35 > 0 e `output_tokens` 42 ≥ 35: o output **inclui** o raciocínio |
| `16a-tool-roster-default.txt`, `16b-tool-roster-disable-multi-agent.txt` | pedir ao agente que liste as suas ferramentas, sem e com `--disable multi_agent` | `collaboration.spawn_agent` está nos dois rosters: **a flag não fecha os subagentes** |
| `17-spawn-under-disable-multi-agent.jsonl` | `--disable multi_agent`, pedir para lançar um subagente | um `collab_tool_call` corre e responde `spawned:pong`: os subagentes **não se fecham por flag**; a forma de `collab_tool_call` |
```

E mudar o título do ficheiro para `# Medições do Codex CLI 0.148.0 — 2026-09-05 e 2026-09-07`. Os ficheiros `16a`/`16b` são texto (o roster que o agente escreveu), não JSONL, e não são copiados para as fixtures.

- [ ] **Step 3: Escrever a secção de correcções na spec**

Em `docs/superpowers/specs/2026-09-06-platforms-anthropic-openai-design.md`, imediatamente antes de `## Ordem de implementação, para o plano`, inserir:

```markdown
## Correcções por medição (2026-09-07)

As oito medições em falta foram feitas a 2026-09-07 (ficheiros 10–17 na pasta
de evidência). Cinco confirmaram a spec; três corrigem-na. Onde esta secção e
o texto acima divergem, **esta secção manda**.

| Ponto | Medido | Correcção |
|---|---|---|
| `--disable multi_agent` | o roster de ferramentas mantém `collaboration.spawn_agent` com a flag (16a/16b) e um spawn pedido sob a flag corre e responde (17) | **os subagentes do Codex não se fecham por flag.** `platform_argv openai` não emite `--disable multi_agent`; `disallowed_tools` e `allowed_tools` são ignorados em OpenAI, com uma linha no `tick.log`; a análise de segurança em OpenAI proíbe subagentes **no prompt** ("Do not spawn subagents; do the work in this session") e conta com o tecto estimado. A capacidade `tool_lists` continua ausente, como a tabela já dizia |
| resume: cwd e sandbox | `exec resume` opera no cwd do **processo** e aceita `-c sandbox_mode=workspace-write` em `--strict-config` (11) | o resume faz `cd "$run_cwd"` antes de lançar e passa `-c sandbox_mode=<mode>` no lugar de `-s`; `full-access` continua a ser `--dangerously-bypass-approvals-and-sandbox` nos dois casos |
| `--` antes do prompt | aceite em `exec` (12) e em `exec resume` (13) | confirmado; `-- <prompt>` sempre |
| `ultra` | aceite (14) | confirmado; o vocabulário de esforço OpenAI é o do catálogo, `ultra` incluído |
| reasoning ⊂ output | `output_tokens` 42 ≥ `reasoning_output_tokens` 35 (15); 90 ≥ 27 (10) | confirmado; a estimativa cobra `output_tokens` uma vez |
| forma de `file_change` | `{id, type:"file_change", changes:[{path, kind}], status}` (10) | o `tool_use` genérico ganha `input.description` = "<kind> <path>" por alteração, para a Timeline mostrar o ficheiro em vez de um JSON |
| forma de `collab_tool_call` | `{id, type, tool, sender_thread_id, receiver_thread_ids, prompt, agents_states, status}` (17) | `tool_use` genérico, sem tratamento especial |
| valores de `-c` | as medições passaram `k=v` sem aspas; o `--help` documenta o fallback de TOML para string literal | `-c model_reasoning_effort=high`, `-c approval_policy=never`, `-c sandbox_mode=workspace-write`, sem aspas |
| preços | lidos de https://openai.com/api/pricing/ a 2026-09-07: gpt-5.6-sol 4.00 / 0.40 / 20.00; gpt-5.6-terra 2.00 / 0.20 / 12.00; gpt-5.6-luna 0.20 / 0.02 / 1.20; gpt-5.5 5.00 / 0.50 / 30.00; gpt-5.4-mini 0.75 / 0.075 / 4.50 (USD por 1M tokens: input / cached input / output; cache write 0) | `config/pricing.example.json` nasce preenchido; **por confirmar pelo operador** |
| `codex login status` sem login | não medido, por não se fazer logout da conta em uso | como previsto: qualquer rc ≠ 0 é "sem login" |
```

- [ ] **Step 4: Abrir a entrada do CHANGELOG**

Em `CHANGELOG.md`, sob `## [Unreleased]`, **antes** de `### Changed`, inserir:

```markdown
### Added

- **The OpenAI platform, engine side.** A job, a project or a project's
  security block can say `"platform": "openai"` and its runs go through the
  Codex CLI (`codex exec --json`) instead of Claude Code — same journal, same
  dashboard, same resume and stop, same dollar caps. Measured against Codex CLI
  0.148.0; the evidence is `docs/superpowers/specs/2026-09-06-codex-measurements/`
  and the fixtures the tests read are copies of it under `test/fixtures/codex/`.
  What it cost to not have it: the only agent this scheduler could run was the
  one it was named after.
  - The eight measurements the design left open are closed. Three corrected
    it: Codex subagents cannot be switched off by flag (`--disable multi_agent`
    leaves `spawn_agent` in the roster), `exec resume` works in the process's
    own directory and takes `-c sandbox_mode=…`, and `-c` values are passed
    bare. The design carries a *Corrections* section with the rest.
```

Os passos seguintes (T2–T8) acrescentam bullets a esta mesma entrada, por baixo deste.

- [ ] **Step 5: Verificar que nada ficou por versionar e que o selftest aceita a commit**

```bash
git add test/fixtures/codex docs/superpowers/specs/2026-09-06-codex-measurements docs/superpowers/specs/2026-09-06-platforms-anthropic-openai-design.md CHANGELOG.md
git status --short
```

Expected: só linhas `A ` e `M ` sobre os ficheiros acima; nenhum `??`.

```bash
bin/agentloop selftest 2>&1 | grep -E 'FAIL|passed|failed' | tail -5
```

Expected: nenhuma linha `FAIL`; a última linha com `0 failed`. (A regra do CHANGELOG compara datas de commit, por isso só falha **depois** de uma commit que toque `test/` sem tocar `CHANGELOG.md`; aqui os dois vão na mesma commit.)

- [ ] **Step 6: Commit**

```bash
git commit -m "docs(platforms): the measured Codex evidence becomes the test fixtures, and the design carries its corrections

Eight measurements from 2026-09-07 (files 10-17) join the nine from 2026-09-05.
Three of them correct the design: Codex subagents cannot be closed by flag,
exec resume runs in the process cwd and accepts -c sandbox_mode, and -c values
travel bare. The design gets a Corrections section that outranks the text
above it, and test/fixtures/codex/ holds the copies the tests will read.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: O normalizador, a tabela de preços e os seus testes

**Files:**
- Create: `bin/platforms/openai_stream.py`, `tests/test_openai_stream.py`, `config/pricing.example.json`
- Modify: `.gitignore` (uma linha), `install.sh` (secção 4), `CHANGELOG.md`
- Test: `tests/test_openai_stream.py`

**Interfaces:**
- Consumes: `test/fixtures/codex/*` (T1); `srv.parse_turns_text` e `srv._salvage_from_stream` do servidor (existentes).
- Produces: o comando `python3 -u bin/platforms/openai_stream.py --model <slug> --permission <mode> --cwd <dir> [--pricing <file>] [--raw-out <file>] < codex.jsonl > stream.ndjson`, que T3 lança; o módulo expõe `Normalizer(model, permission, cwd, price)` com `feed(event) -> [events]` e `finish() -> [events]`, `load_price(path, model) -> dict|None`, `estimate(tokens, price) -> float|None`, `tokens_of(usage) -> dict`, `error_status(message) -> int|None`. O `result` canónico leva `platform`, `cost_basis`, `tokens`, `total_cost_usd`, `api_error_status`, que T6 grava.

- [ ] **Step 1: Escrever os testes do normalizador, que vão falhar por o módulo não existir**

Cria `tests/test_openai_stream.py`:

```python
"""The Codex -> stream-json normalizer, tested on the measured fixtures.

Every fixture under test/fixtures/codex/ is a real `codex exec --json` run
(or the Codex rollout beside it), captured on 2026-09-05 and 2026-09-07 — no
event here was written from memory. The normalizer is pure: feed() takes one
Codex event and returns the canonical events it becomes, so these tests drive
it in-process; one test drives the CLI itself, because the FIFO launch in
run_job only ever sees that.
"""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
NORM = REPO / "bin" / "platforms" / "openai_stream.py"
FIX = REPO / "test" / "fixtures" / "codex"
EXAMPLE_PRICES = REPO / "config" / "pricing.example.json"

_spec = importlib.util.spec_from_file_location("openai_stream", NORM)
osm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(osm)

PRICE = {"input": 4.0, "cached_input": 0.4, "output": 20.0, "cache_write": 0.0}
THREAD_02 = "01a071d5-47b0-7343-bcbd-216945ef7927"


def events_of(name):
    out = []
    for line in (FIX / name).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except Exception:  # noqa: BLE001
            continue
    return out


def normalize(name=None, events=None, price=None, model="gpt-5.6-sol"):
    n = osm.Normalizer(model, "workspace-write", "/tmp/x", price)
    out = []
    for ev in (events if events is not None else events_of(name)):
        out.extend(n.feed(ev))
    out.extend(n.finish())
    return out


def as_text(events):
    return "\n".join(json.dumps(e) for e in events) + "\n"


# ------------------------------------------------------------ the shape

def test_the_first_line_is_the_init_event_carrying_the_thread_id():
    out = normalize("02-tool-use.jsonl")
    first = out[0]
    assert first["type"] == "system" and first["subtype"] == "init"
    assert first["session_id"] == THREAD_02
    assert first["model"] == "gpt-5.6-sol"          # what was ASKED for
    assert first["platform"] == "openai"
    assert first["permissionMode"] == "workspace-write"
    assert first["tools"] == []


def test_a_finished_turn_ends_in_a_success_result():
    out = normalize("02-tool-use.jsonl")
    last = out[-1]
    assert last["type"] == "result"
    assert last["subtype"] == "success" and last["is_error"] is False
    assert last["session_id"] == THREAD_02
    assert last["result"] == "done"                  # the last agent_message
    assert last["num_turns"] == sum(1 for e in out if e["type"] == "assistant")
    assert last["permission_denials"] == []
    assert last["platform"] == "openai"
    assert last["usage"] == {"input_tokens": 32675, "cache_read_input_tokens": 28160,
                             "cache_creation_input_tokens": 0, "output_tokens": 123}
    assert last["tokens"] == {"input": 32675, "cached": 28160, "cache_write": 0,
                              "output": 123, "reasoning": 0}


def test_a_command_becomes_a_bash_tool_use_and_its_result():
    out = normalize("02-tool-use.jsonl")
    uses = [b for e in out if e["type"] == "assistant"
            for b in e["message"]["content"] if b["type"] == "tool_use"]
    results = [b for e in out if e["type"] == "user"
               for b in e["message"]["content"] if b["type"] == "tool_result"]
    assert uses == [{"type": "tool_use", "id": "item_1", "name": "Bash",
                     "input": {"command": "/bin/zsh -lc 'ls && cat a.txt'"}}]
    assert results[0]["tool_use_id"] == "item_1"
    assert "alpha" in results[0]["content"]
    assert results[0]["is_error"] is False


def test_the_server_timeline_draws_the_command(srv):
    turns = srv.parse_turns_text(as_text(normalize("02-tool-use.jsonl")))
    tools = [t for turn in turns for t in turn["tools"]]
    assert tools and tools[0]["tool"] == "Bash"
    assert "ls && cat a.txt" in tools[0]["hint"]


def test_a_truncated_copy_still_salvages_session_and_turns(srv):
    text = as_text(normalize("02-tool-use.jsonl"))
    cut = text[: len(text) // 2]
    last_text, turns, sess = srv._salvage_from_stream(cut)
    assert sess == THREAD_02
    assert turns >= 1


def test_events_that_have_no_translation_produce_nothing():
    assert normalize(events=[{"type": "turn.started"}]) == []
    n = osm.Normalizer("m", "read-only", "/", None)
    assert n.feed({"type": "item.started", "item": {"id": "r", "type": "reasoning"}}) == []
    assert n.feed({"type": "item.completed", "item": {"id": "r", "type": "reasoning"}}) == []


def test_a_file_change_is_a_generic_tool_use_naming_the_file():
    out = normalize("10-file-change-workspace-write.jsonl")
    uses = [b for e in out if e["type"] == "assistant"
            for b in e["message"]["content"] if b["type"] == "tool_use"]
    assert len(uses) == 1
    assert uses[0]["name"] == "file_change"
    assert uses[0]["input"]["description"].startswith("add /")
    assert uses[0]["input"]["description"].endswith("/marker.txt")
    for key in ("id", "type", "status"):
        assert key not in uses[0]["input"]


def test_an_unknown_item_type_is_a_generic_tool_use_with_an_empty_result():
    out = normalize("17-spawn-under-disable-multi-agent.jsonl")
    uses = [b for e in out if e["type"] == "assistant"
            for b in e["message"]["content"] if b["type"] == "tool_use"]
    results = [b for e in out if e["type"] == "user"
               for b in e["message"]["content"] if b["type"] == "tool_result"]
    assert uses[0]["name"] == "collab_tool_call"
    assert uses[0]["input"]["tool"] == "wait"
    assert results == [{"type": "tool_result", "tool_use_id": "item_0", "content": "",
                        "is_error": False}]


def test_a_completed_item_that_was_never_started_gets_its_tool_use_first():
    ev = {"type": "item.completed", "item": {"id": "x1", "type": "command_execution",
                                             "command": "true", "aggregated_output": "",
                                             "exit_code": 2, "status": "completed"}}
    out = normalize(events=[{"type": "thread.started", "thread_id": "t"}, ev])
    kinds = [(e["type"], e["message"]["content"][0]["type"]) for e in out[1:]]
    assert kinds == [("assistant", "tool_use"), ("user", "tool_result")]
    assert out[2]["message"]["content"][0]["is_error"] is True   # exit 2


def test_a_long_command_output_is_cut_at_eight_kilobytes():
    big = "x" * 20_000
    ev = {"type": "item.completed", "item": {"id": "b", "type": "command_execution",
                                             "command": "yes", "aggregated_output": big,
                                             "exit_code": 0, "status": "completed"}}
    out = normalize(events=[ev])
    content = out[-1]["message"]["content"][0]["content"]
    assert len(content.encode()) < 9_000 and content.endswith("[truncated]")


# ------------------------------------------------------------ failures

def test_an_unknown_model_carries_the_embedded_status_400():
    out = normalize("04-unknown-model.jsonl")
    last = out[-1]
    assert last["type"] == "result" and last["is_error"] is True
    assert last["subtype"] == "error_during_execution"
    assert last["api_error_status"] == 400
    assert "not supported" in last["result"]
    assert last["cost_basis"] == "none" and last["total_cost_usd"] is None
    # the item-level error was also shown to the reader, as text
    texts = [b["text"] for e in out if e["type"] == "assistant"
             for b in e["message"]["content"] if b["type"] == "text"]
    assert any(t.startswith("error: ") for t in texts)


def test_an_exhausted_quota_carries_429():
    last = normalize("quota-exhausted.jsonl")[-1]
    assert last["type"] == "result" and last["is_error"] is True
    assert last["api_error_status"] == 429


def test_an_error_with_no_turn_failed_still_ends_the_run_at_eof():
    out = normalize(events=[{"type": "thread.started", "thread_id": "t"},
                            {"type": "error", "message": "boom"}])
    assert out[-1]["type"] == "result" and out[-1]["is_error"] is True
    assert out[-1]["result"] == "boom" and out[-1]["api_error_status"] is None


def test_a_run_cut_off_before_its_final_event_emits_no_result():
    evs = events_of("02-tool-use.jsonl")
    out = normalize(events=[e for e in evs if e["type"] != "turn.completed"])
    assert out[-1]["type"] != "result"


def test_error_status_reads_the_embedded_json_then_the_quota_phrase():
    assert osm.error_status(json.dumps({"status": 503})) == 503
    assert osm.error_status("You've hit your usage limit. Try again later.") == 429
    assert osm.error_status("something else") is None


# ------------------------------------------------------------ the estimate

def test_the_estimate_follows_the_price_table():
    last = normalize("02-tool-use.jsonl", price=PRICE)[-1]
    expected = round(((32675 - 28160) * 4.0 + 28160 * 0.4 + 123 * 20.0) / 1_000_000, 6)
    assert last["total_cost_usd"] == expected
    assert last["cost_basis"] == "estimated"


def test_reasoning_tokens_are_reported_but_not_billed_twice():
    last = normalize("15-effort-high-reasoning-tokens.jsonl", price=PRICE)[-1]
    assert last["tokens"]["reasoning"] == 35 and last["tokens"]["output"] == 42
    expected = round(((16252 - 12032) * 4.0 + 12032 * 0.4 + 42 * 20.0) / 1_000_000, 6)
    assert last["total_cost_usd"] == expected


def test_without_a_price_the_cost_is_null_and_the_basis_says_so():
    last = normalize("02-tool-use.jsonl", price=None)[-1]
    assert last["total_cost_usd"] is None and last["cost_basis"] == "none"
    assert last["tokens"]["input"] == 32675          # tokens are still reported


def test_load_price_treats_null_and_missing_slugs_as_no_price(tmp_path):
    table = tmp_path / "p.json"
    table.write_text(json.dumps({"openai": {
        "priced": {"input": 1, "cached_input": 0.1, "output": 2, "cache_write": 0},
        "half": {"input": None, "cached_input": 0.1, "output": 2}}}))
    assert osm.load_price(str(table), "priced") == {"input": 1.0, "cached_input": 0.1,
                                                    "output": 2.0, "cache_write": 0.0}
    assert osm.load_price(str(table), "half") is None
    assert osm.load_price(str(table), "absent") is None
    assert osm.load_price(str(tmp_path / "nope.json"), "priced") is None


def test_the_example_table_prices_every_visible_catalog_model():
    table = json.loads(EXAMPLE_PRICES.read_text())["openai"]
    catalog = json.loads((FIX / "models-catalog.stripped.json").read_text())["models"]
    for m in catalog:
        if m["visibility"] != "list":
            continue
        row = table[m["slug"]]
        assert all(isinstance(row[k], (int, float)) for k in ("input", "cached_input", "output"))


# ------------------------------------------------------------ the CLI

def test_the_cli_normalizes_stdin_and_copies_every_raw_line(tmp_path):
    raw_in = (FIX / "02-tool-use.jsonl").read_text() + "this line is not json\n"
    raw_out = tmp_path / "copy.raw"
    p = subprocess.run([sys.executable, "-u", str(NORM), "--model", "gpt-5.6-sol",
                        "--permission", "read-only", "--cwd", "/tmp/x",
                        "--pricing", str(EXAMPLE_PRICES), "--raw-out", str(raw_out)],
                       input=raw_in, capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, p.stderr
    lines = [json.loads(ln) for ln in p.stdout.splitlines()]
    assert lines[0]["subtype"] == "init" and lines[-1]["type"] == "result"
    assert lines[-1]["cost_basis"] == "estimated"
    assert raw_out.read_text() == raw_in            # copied verbatim, bad line included
    assert p.stderr == ""
```

- [ ] **Step 2: Correr os testes e ver falhar**

Run: `python3.13 -m pytest -p no:cacheprovider tests/test_openai_stream.py -q`
Expected: erro de colecção — `FileNotFoundError` em `bin/platforms/openai_stream.py` (o módulo não existe).

- [ ] **Step 3: Escrever o normalizador**

Cria `bin/platforms/openai_stream.py` (modo 644; é lançado por `$PYTHON`, não por `exec`):

```python
#!/usr/bin/env python3
"""Codex CLI JSONL -> Claude Code stream-json, one line at a time.

`codex exec --json` prints one event per line: thread.started, turn.started,
item.started / item.completed, turn.completed, turn.failed, error. Every
reader in this scheduler -- the watchdog, turn_is_over, bind_session, the
classifier, the dashboard's Timeline and Terminal -- reads the stream-json
shape Claude Code emits. This filter turns the one into the other at the
boundary, so none of those readers learns a second dialect.

Pure and unbuffered: stdin in, stdout out, one canonical line per Codex event
that has a translation, flushed at once (the watchdog measures the file
growing; the Terminal follows it live). Every raw line is copied to --raw-out
BEFORE anything is done with it, so a line that is not JSON, or an event this
filter has never seen, is never lost: it is copied and skipped, which is what
every reader already does with a truncated line.

The only other thing it knows is the price table (--pricing). The Codex
stream carries tokens and no dollars, so the final `result` carries an
ESTIMATE -- or null, with cost_basis "none", when the model has no price.
"""
import argparse
import json
import sys

OUTPUT_CAP = 8192               # bytes of a command's output kept in a tool_result
QUOTA_PHRASE = "hit your usage limit"


def load_price(path, model):
    """The per-1M price row for `model`, or None: no file, no row, or a null
    in any of the three billed fields. `cache_write` may be absent (0)."""
    try:
        with open(path, encoding="utf-8") as fh:
            table = json.load(fh)
    except Exception:  # noqa: BLE001 -- a missing or broken table is "no price"
        return None
    row = (table.get("openai") or {}).get(model) if isinstance(table, dict) else None
    if not isinstance(row, dict):
        return None
    prices = {}
    for key in ("input", "cached_input", "output"):
        v = row.get(key)
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            return None
        prices[key] = float(v)
    cw = row.get("cache_write", 0)
    prices["cache_write"] = float(cw) if isinstance(cw, (int, float)) and not isinstance(cw, bool) else 0.0
    return prices


def tokens_of(usage):
    """The five counters of a turn.completed `usage`, as ints, missing = 0."""
    u = usage if isinstance(usage, dict) else {}

    def n(key):
        v = u.get(key)
        return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else 0

    return {"input": n("input_tokens"), "cached": n("cached_input_tokens"),
            "cache_write": n("cache_write_input_tokens"), "output": n("output_tokens"),
            "reasoning": n("reasoning_output_tokens")}


def estimate(tokens, price):
    """USD for one turn at `price` (USD per 1,000,000 tokens); None without a
    price. `output` already INCLUDES `reasoning` (measured: 15-effort-high),
    so reasoning is never billed a second time."""
    if price is None:
        return None
    uncached = max(0, tokens["input"] - tokens["cached"])
    usd = (uncached * price["input"] + tokens["cached"] * price["cached_input"]
           + tokens["cache_write"] * price["cache_write"] + tokens["output"] * price["output"])
    return round(usd / 1_000_000, 6)


def error_status(message):
    """The status a failed turn carries: the `status` of the JSON the CLI
    embeds in its message (04-unknown-model: 400), else 429 when the message
    is the quota refusal, else None. The engine's cause taxonomy reads it
    unchanged: 429 -> rate_limited, anything else -> api_error."""
    text = message or ""
    try:
        embedded = json.loads(text)
        if isinstance(embedded, dict) and isinstance(embedded.get("status"), int):
            return embedded["status"]
    except Exception:  # noqa: BLE001
        pass
    if QUOTA_PHRASE in text.lower():
        return 429
    return None


class Normalizer:
    """One Codex event in, zero or more canonical events out."""

    def __init__(self, model, permission, cwd, price):
        self.model, self.permission, self.cwd, self.price = model, permission, cwd, price
        self.session = ""
        self.started = set()        # item ids whose tool_use is already out
        self.assistant_events = 0   # what `result.num_turns` reports
        self.last_text = ""         # the last agent_message: `result.result`
        self.pending_error = None   # an `error` waiting for its turn.failed
        self.done = False           # a result has been emitted

    def _msg(self, role, blocks):
        return {"type": "assistant" if role == "assistant" else "user",
                "message": {"role": role, "content": blocks},
                "session_id": self.session}

    def _assistant(self, blocks):
        self.assistant_events += 1
        return self._msg("assistant", blocks)

    def _tool_use(self, item):
        kind = item.get("type") or "item"
        if kind == "command_execution":
            block = {"type": "tool_use", "id": item.get("id"), "name": "Bash",
                     "input": {"command": item.get("command") or ""}}
        else:
            # Generic: the item minus its bookkeeping. It shows on the Timeline
            # under its own type instead of disappearing.
            inp = {k: v for k, v in item.items() if k not in ("id", "type", "status")}
            if kind == "file_change":
                inp["description"] = ", ".join(
                    f"{c.get('kind') or 'change'} {c.get('path') or '?'}"
                    for c in (item.get("changes") or []) if isinstance(c, dict))
            block = {"type": "tool_use", "id": item.get("id"), "name": kind, "input": inp}
        self.started.add(item.get("id"))
        return self._assistant([block])

    def _tool_result(self, item):
        if item.get("type") == "command_execution":
            out = item.get("aggregated_output") or ""
            if len(out.encode("utf-8")) > OUTPUT_CAP:
                out = out.encode("utf-8")[:OUTPUT_CAP].decode("utf-8", errors="ignore") \
                    + "\n...[truncated]"
            code = item.get("exit_code")
            is_error = code is not None and code != 0
        else:
            out, is_error = "", False
        return self._msg("user", [{"type": "tool_result", "tool_use_id": item.get("id"),
                                   "content": out, "is_error": is_error}])

    def _result(self, usage=None, error=None):
        self.done = True
        base = {"type": "result", "session_id": self.session, "platform": "openai",
                "num_turns": self.assistant_events, "permission_denials": []}
        if error is None:
            toks = tokens_of(usage)
            cost = estimate(toks, self.price)
            base.update({"subtype": "success", "is_error": False, "result": self.last_text,
                         # the names the engine's salvage and the modal already sum
                         "usage": {"input_tokens": toks["input"],
                                   "cache_read_input_tokens": toks["cached"],
                                   "cache_creation_input_tokens": toks["cache_write"],
                                   "output_tokens": toks["output"]},
                         "total_cost_usd": cost,
                         "cost_basis": "estimated" if cost is not None else "none",
                         "tokens": toks})
        else:
            base.update({"subtype": "error_during_execution", "is_error": True,
                         "result": error, "total_cost_usd": None, "cost_basis": "none",
                         "tokens": None, "api_error_status": error_status(error)})
        return base

    def feed(self, ev):
        kind = ev.get("type")
        if kind == "thread.started":
            self.session = ev.get("thread_id") or ""
            # FIRST line, always: session_from_stream reads five lines and stops.
            return [{"type": "system", "subtype": "init", "session_id": self.session,
                     "model": self.model, "platform": "openai",
                     "permissionMode": self.permission, "cwd": self.cwd, "tools": []}]
        if kind in ("item.started", "item.completed"):
            item = ev.get("item") or {}
            itype = item.get("type")
            if itype == "reasoning":
                return []                   # Claude's thinking is not drawn either
            if itype == "agent_message":
                if kind != "item.completed":
                    return []
                text = item.get("text") or ""
                self.last_text = text
                return [self._assistant([{"type": "text", "text": text}])]
            if itype == "error":
                if kind != "item.completed":
                    return []
                msg = item.get("message") or ""
                self.pending_error = self.pending_error or msg
                return [self._assistant([{"type": "text", "text": "error: " + msg}])]
            if kind == "item.started":
                return [self._tool_use(item)]
            out = []
            if item.get("id") not in self.started:
                out.append(self._tool_use(item))
            out.append(self._tool_result(item))
            return out
        if kind == "turn.completed":
            return [self._result(usage=ev.get("usage"))]
        if kind == "error":
            self.pending_error = ev.get("message") or self.pending_error or "error"
            return []
        if kind == "turn.failed":
            msg = ((ev.get("error") or {}).get("message")) or self.pending_error or "turn failed"
            self.pending_error = None
            return [self._result(error=msg)]
        return []                           # turn.started, and anything not seen yet

    def finish(self):
        """EOF. An `error` with no `turn.failed` after it still ends the run."""
        if self.pending_error and not self.done:
            msg, self.pending_error = self.pending_error, None
            return [self._result(error=msg)]
        return []


def main(argv=None):
    ap = argparse.ArgumentParser(description="Codex JSONL on stdin -> stream-json on stdout")
    ap.add_argument("--model", required=True, help="the slug the run asked for")
    ap.add_argument("--permission", required=True, help="the run's permission_mode")
    ap.add_argument("--cwd", required=True, help="the run's working directory")
    ap.add_argument("--pricing", default="", help="config/pricing.json")
    ap.add_argument("--raw-out", default="", help="where every raw line is copied")
    args = ap.parse_args(argv)
    price = load_price(args.pricing, args.model) if args.pricing else None
    norm = Normalizer(args.model, args.permission, args.cwd, price)
    raw = open(args.raw_out, "ab") if args.raw_out else None
    out = sys.stdout

    def emit(events):
        for e in events:
            out.write(json.dumps(e) + "\n")     # ASCII-safe whatever the locale
        out.flush()

    try:
        # Bytes in, so a locale with no UTF-8 (launchd's default) can neither
        # refuse a curly quote on the way in nor mangle the raw copy.
        for bline in sys.stdin.buffer:
            if raw is not None:
                raw.write(bline if bline.endswith(b"\n") else bline + b"\n")
                raw.flush()
            line = bline.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:  # noqa: BLE001 -- copied above, skipped here
                continue
            if isinstance(ev, dict):
                emit(norm.feed(ev))
        emit(norm.finish())
    finally:
        if raw is not None:
            raw.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: A tabela de preços versionada, a pessoal ignorada e semeada**

Cria `config/pricing.example.json`:

```json
{
  "_source": "https://openai.com/api/pricing/",
  "_read_on": "2026-09-07",
  "_unit": "USD per 1,000,000 tokens: input, cached input, output. cache_write is 0 because OpenAI does not bill cache writes.",
  "_note": "Confirm these against the page before trusting an estimate. A null, or a missing slug, means no price: such a run is recorded with cost_basis none and the dollar caps do not see its spend.",
  "openai": {
    "gpt-5.6-sol":   {"input": 4.00, "cached_input": 0.40,  "output": 20.00, "cache_write": 0},
    "gpt-5.6-terra": {"input": 2.00, "cached_input": 0.20,  "output": 12.00, "cache_write": 0},
    "gpt-5.6-luna":  {"input": 0.20, "cached_input": 0.02,  "output": 1.20,  "cache_write": 0},
    "gpt-5.5":       {"input": 5.00, "cached_input": 0.50,  "output": 30.00, "cache_write": 0},
    "gpt-5.4-mini":  {"input": 0.75, "cached_input": 0.075, "output": 4.50,  "cache_write": 0}
  }
}
```

Em `.gitignore`, logo a seguir a `config/models.json`, acrescentar a linha `config/pricing.json`.

Em `install.sh`, na secção `# 4) seed a jobs file the first time`, a seguir ao bloco do `jobs.json` e antes do `mkdir -p`, acrescentar:

```bash
if [ ! -f "$HERE/config/pricing.json" ]; then
  cp "$HERE/config/pricing.example.json" "$HERE/config/pricing.json"
  say "Created config/pricing.json from the example — OpenAI runs are priced from it; check the numbers."
fi
```

- [ ] **Step 5: Correr os testes e ver passar**

Run: `python3.13 -m pytest -p no:cacheprovider tests/test_openai_stream.py -q`
Expected: `21 passed`.

Run também o resto, para provar que o servidor não mudou: `python3.13 -m pytest -p no:cacheprovider tests/ -q --ignore=tests/security`
Expected: tudo verde.

- [ ] **Step 6: CHANGELOG**

Sob a entrada *The OpenAI platform, engine side* (T1), acrescentar o bullet:

```markdown
  - `bin/platforms/openai_stream.py` translates the Codex event stream into
    the stream-json every reader here already speaks, one line at a time and
    unbuffered, and keeps a verbatim copy of the raw stream beside it. The
    Codex stream carries tokens and no dollars, so the final event carries a
    cost ESTIMATED from `config/pricing.json` (seeded from
    `config/pricing.example.json` by `install.sh`; the numbers are the OpenAI
    price page's as read on 2026-09-07), with `cost_basis` saying so — or
    `none`, never a fake $0.00, when the model has no price.
```

- [ ] **Step 7: Commit**

```bash
git add bin/platforms/openai_stream.py tests/test_openai_stream.py config/pricing.example.json .gitignore install.sh CHANGELOG.md
git commit -m "feat(platforms): the Codex stream is normalized at the boundary, with an estimated cost

Codex JSONL in, stream-json out, one line per event and flushed at once; a
raw copy beside it; the final result carries tokens, an estimate from
config/pricing.json and a cost_basis that says which. Tested on the measured
fixtures, including the truncated-copy salvage and the server's own Timeline
parser.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: A tabela de plataformas, o lançamento por FIFO, o stand-in e os cenários e2e

**Files:**
- Modify: `bin/agentloop` (variáveis junto a `CLAUDE_BIN` ~L117; bloco novo `# --- platforms ---` antes de `session_from_stream()` ~L1136; `run_job` em seis pontos; `cmd_selftest`), `CHANGELOG.md`
- Create: `test/fake-codex`
- Modify: `test/e2e.test.sh` (cenários 13–20)
- Test: `bin/agentloop selftest`, `bash test/e2e.test.sh`

**Interfaces:**
- Consumes: `bin/platforms/openai_stream.py` (T2) e o seu `result` canónico; `test/fixtures/codex/models-catalog.stripped.json` e `rollout-sample.stripped.jsonl` (T1).
- Produces: as funções `platform_*` e `openai_catalog_*` (assinaturas abaixo), as globais `PLATFORM_ARGV`, `PF_MODEL_ID`, `PF_ROLLOUT`, as variáveis `CODEX_BIN`, `CODEX_HOME_DIR`, `PRICING_FILE`, `PLATFORMS`; em `run_job` a variável local `platform` (que T5, T6 e T7 lêem); o ficheiro `<stem>.stream.ndjson.raw`; `test/fake-codex` e o seu contrato de ambiente; o bloco `openai` de `config/models.json` na forma que T4 passa a escrever: `{"at":<epoch>,"source":"codex debug models"|"bundled","models":[{"slug","display_name","description","default_effort","efforts":[…],"visibility","priority","deprecated_by","retires_at"}]}`.

- [ ] **Step 1: As três variáveis, junto de `CLAUDE_BIN`**

Em `bin/agentloop`, logo a seguir à linha `CLAUDE_BIN="${AGENTLOOP_CLAUDE_BIN:-$HOME/.local/bin/claude}"`, inserir:

```bash
# The Codex CLI, for runs on the openai platform. On PATH from Homebrew
# (/opt/homebrew/bin, which the launchd plists already carry); override for a
# test stand-in or a second install. Its account and its rollouts live under
# CODEX_HOME (the CLI's own variable, honoured as-is: `--help` says auth still
# uses it); platform_finish reads the rollout from there after every run.
CODEX_BIN="${AGENTLOOP_CODEX_BIN:-$(command -v codex 2>/dev/null || echo /opt/homebrew/bin/codex)}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
```

E a seguir a `MODELS_FILE="$CONFIG_DIR/models.json"` (~L84):

```bash
PRICING_FILE="$CONFIG_DIR/pricing.json"   # USD per 1M tokens, per OpenAI slug (install.sh seeds it)
```

- [ ] **Step 2: O bloco `# --- platforms ---`**

Inserir imediatamente antes de `session_from_stream() {`:

```bash
# --- platforms ---------------------------------------------------------------
# Which CLI a run goes through. bash 3.2 has no associative arrays, so the
# "table" is this contiguous block of functions, each one a `case "$platform"`
# and nothing outside it. Adding a platform is adding one branch to each of
# them; run_job asks these and never names a binary itself. Everything the
# openai branch does was measured on Codex CLI 0.148.0 -- see
# docs/superpowers/specs/2026-09-06-codex-measurements/README.md -- and where
# the measurement contradicted the design, the measurement won (its
# "Correcções por medição" section).
PLATFORMS="anthropic openai"

platform_known() { case "${1:-}" in anthropic|openai) return 0 ;; *) return 1 ;; esac; }

platform_bin() { # platform_bin <platform> -> the CLI's path
  case "$1" in anthropic) printf '%s' "$CLAUDE_BIN" ;; openai) printf '%s' "$CODEX_BIN" ;; esac
}

platform_ready() { # platform_ready <platform> -> 0; or 1 with the reason on stdout
  local bin; bin="$(platform_bin "$1")"
  case "$1" in
    anthropic)
      [ -x "$bin" ] || { printf 'claude not found at %s (set AGENTLOOP_CLAUDE_BIN)' "$bin"; return 1; } ;;
    openai)
      [ -x "$bin" ] || { printf 'codex not found at %s (set AGENTLOOP_CODEX_BIN)' "$bin"; return 1; }
      # Any non-zero is "not signed in". The CLI's exit code when it is not was
      # left unmeasured on purpose (measuring it meant logging the working
      # account out); a 0 without a login fails on the first turn as api_error,
      # which is an honest line in tick.log either way.
      "$bin" login status >/dev/null 2>&1 \
        || { printf 'codex is not signed in (run: codex login)'; return 1; } ;;
    *) printf 'unknown platform %s' "$1"; return 1 ;;
  esac
  return 0
}

platform_caps() { # platform_caps <platform> <capability> -> 0 when the platform HAS it
  #   interactive        a stdin protocol for a human to talk to the live run
  #   tool_lists         --allowedTools/--disallowedTools (Codex cannot close a
  #                      tool by flag: --disable multi_agent leaves spawn_agent
  #                      in the roster and a spawn under it runs -- measured)
  #   denials            permission_denials on the final event (a Codex sandbox
  #                      refusal produces no event at all)
  #   budget_flag        --max-budget-usd (on openai the cap is read at the end)
  #   cost_reported      dollars on the final event (openai: estimated from tokens)
  #   stream_rate_limits rate_limit_event on the stream (openai: the rollout)
  #   families           opus/sonnet aliases resolved to an id (openai: exact slugs)
  case "$1" in
    anthropic) case "$2" in
      interactive|tool_lists|denials|budget_flag|cost_reported|stream_rate_limits|families) return 0 ;;
    esac ;;
    openai) : ;;
  esac
  return 1
}

platform_permissions() { # platform_permissions <platform> -> one mode per line
  case "$1" in
    anthropic) printf '%s\n' acceptEdits auto bypassPermissions manual dontAsk plan ;;
    openai)    printf '%s\n' read-only workspace-write full-access ;;
  esac
}

platform_permission_ok() { # platform_permission_ok <platform> <mode>
  platform_permissions "$1" | grep -qx -- "$2"
}

platform_default_permission() { # platform_default_permission <platform> <job|security>
  case "$1" in
    anthropic) case "$2" in security) printf 'bypassPermissions' ;; *) printf 'dontAsk' ;; esac ;;
    openai)    case "$2" in security) printf 'full-access' ;; *) printf 'workspace-write' ;; esac ;;
  esac
}

platform_efforts() { # platform_efforts <platform> [model] -> one level per line
  case "$1" in
    anthropic) printf '%s\n' low medium high xhigh max ;;
    openai)    openai_catalog_efforts "${2:-}" ;;
  esac
}

platform_effort_ok() { # platform_effort_ok <platform> <model> <effort>; "" is always ok (the CLI decides)
  [ -z "${3:-}" ] && return 0
  platform_efforts "$1" "$2" | grep -qx -- "$3"
}

platform_model_ok() { # platform_model_ok <platform> <model>
  case "$1" in
    anthropic) case "$2" in opus|sonnet|haiku|fable|claude-*) return 0 ;; *) return 1 ;; esac ;;
    openai)    openai_catalog_slugs | grep -qx -- "$2" ;;
    *) return 1 ;;
  esac
}

platform_default_model() { # platform_default_model <platform> (openai: empty without a catalog)
  case "$1" in
    anthropic) printf 'opus' ;;
    openai)    openai_catalog_visible | head -1 ;;
  esac
}

platform_stderr_filter() { # platform_stderr_filter <platform> <errfile>
  # The classifier counts stderr bytes, and `codex exec` prints one line on
  # every run whatever happens: "Reading additional input from stdin...".
  # Without this, every OpenAI run would be a warning. Exactly that line,
  # whole, and nothing else: anything more is still stderr and still a warning.
  case "$1" in
    openai)
      [ -s "$2" ] || return 0
      local tmp; tmp="$(mktemp "$2.XXXXXX" 2>/dev/null)" || return 0
      grep -vxF 'Reading additional input from stdin...' "$2" > "$tmp" 2>/dev/null
      mv -f "$tmp" "$2" 2>/dev/null || rm -f "$tmp" ;;
  esac
  return 0
}

# The launch line of an OpenAI run, into PLATFORM_ARGV (bash 3.2 cannot return
# an array). Every flag was measured; the comments say where.
PLATFORM_ARGV=()
platform_argv_openai() { # platform_argv_openai <resume-sid> <run_cwd> <model> <effort> <permission> <prompt>
  local resume_sid="$1" run_cwd="$2" model="$3" effort="$4" permission="$5" prompt="$6"
  if [ -n "$resume_sid" ]; then
    # `exec resume` takes neither -s nor -C: the sandbox travels as a config
    # override and the cwd is the process's own -- run_job cd's there first
    # (measurement 11).
    PLATFORM_ARGV=(exec resume --json --skip-git-repo-check)
  else
    PLATFORM_ARGV=(exec --json --skip-git-repo-check -C "$run_cwd")
  fi
  PLATFORM_ARGV+=(-m "$model")
  # Bare `key=value`: the CLI tries TOML and falls back to a literal string
  # (its --help), and that is how measurements 05b, 07 and 11 passed them.
  [ -n "$effort" ] && PLATFORM_ARGV+=(-c "model_reasoning_effort=$effort")
  case "$permission" in
    read-only|workspace-write)
      if [ -n "$resume_sid" ]; then PLATFORM_ARGV+=(-c "sandbox_mode=$permission")
      else PLATFORM_ARGV+=(-s "$permission"); fi
      PLATFORM_ARGV+=(-c "approval_policy=never") ;;
    full-access) PLATFORM_ARGV+=(--dangerously-bypass-approvals-and-sandbox) ;;
  esac
  [ -n "$resume_sid" ] && PLATFORM_ARGV+=("$resume_sid")
  # `--` before the prompt, as the anthropic launch does: accepted by exec (12)
  # and by exec resume (13). No --disable multi_agent: it closes nothing.
  PLATFORM_ARGV+=(-- "$prompt")
}

# What the stream cannot say. The Codex stream carries neither the model that
# ran nor the usage windows; both sit in the rollout the CLI writes under
# $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<thread_id>.jsonl (a resume
# appends to the same file). Sets PF_MODEL_ID and PF_ROLLOUT; both empty when
# the rollout is not found, with one line in tick.log saying so.
PF_MODEL_ID=""; PF_ROLLOUT=""
platform_finish() { # platform_finish <platform> <streamfile> <session-id> [job-id]
  PF_MODEL_ID=""; PF_ROLLOUT=""
  case "$1" in openai) ;; *) return 0 ;; esac
  local tid="${3:-}" id="${4:-run}"
  [ -n "$tid" ] || return 0
  PF_ROLLOUT="$(openai_rollout_for "$tid")"
  if [ -z "$PF_ROLLOUT" ]; then
    log_tick "$id: no codex rollout for thread $tid under $CODEX_HOME_DIR/sessions — model_id stays the requested slug, no rate-limit reading"
    return 0
  fi
  # The LAST turn_context: a resumed thread may have changed model.
  PF_MODEL_ID="$("$JQ" -r 'select(.type=="turn_context") | .payload.model // empty' "$PF_ROLLOUT" 2>/dev/null | tail -1)"
  return 0
}

openai_rollout_for() { # openai_rollout_for <thread_id> -> the rollout's path, or nothing
  local hit
  # A thread id is unique, so the first hit is the only hit; the glob is
  # bounded to the three date levels the CLI uses.
  hit="$(ls -t "$CODEX_HOME_DIR"/sessions/*/*/*/rollout-*-"$1".jsonl 2>/dev/null | head -1)"
  [ -n "$hit" ] && [ -f "$hit" ] && printf '%s' "$hit"
  return 0
}

# --- the OpenAI catalog, read side ------------------------------------------
# config/models.json carries an `openai` block (written by `resolve-models
# openai`; the writer is with the family resolver, cmd_resolve_models). These
# read it. Without the block every reader answers nothing, which is what makes
# an unresolved catalog REFUSE a launch rather than guess a slug.
openai_catalog_available() { # 0 when config/models.json carries an openai catalog
  [ -f "$MODELS_FILE" ] && "$JQ" -e '.openai.models | type == "array"' "$MODELS_FILE" >/dev/null 2>&1
}

openai_catalog_slugs() { # every slug, listed or hidden, one per line
  openai_catalog_available || return 0
  "$JQ" -r '.openai.models[].slug' "$MODELS_FILE" 2>/dev/null
}

openai_catalog_visible() { # the listed slugs, by ascending priority (the CLI's own order)
  openai_catalog_available || return 0
  "$JQ" -r '[.openai.models[] | select(.visibility == "list")] | sort_by(.priority) | .[].slug' \
    "$MODELS_FILE" 2>/dev/null
}

openai_catalog_efforts() { # openai_catalog_efforts <slug> -> its levels, one per line
  local got=""
  if openai_catalog_available && [ -n "${1:-}" ]; then
    got="$("$JQ" -r --arg s "$1" '.openai.models[] | select(.slug == $s) | .efforts[]?' "$MODELS_FILE" 2>/dev/null)"
  fi
  # A slug the catalog does not describe (hidden, or no catalog): the union of
  # every level the CLI has been seen to accept, ultra included (measured).
  if [ -n "$got" ]; then printf '%s\n' "$got"; else printf '%s\n' low medium high xhigh max ultra; fi
}

openai_catalog_default_effort() { # openai_catalog_default_effort <slug> -> the catalog's default, or nothing
  openai_catalog_available || return 0
  "$JQ" -r --arg s "$1" '.openai.models[] | select(.slug == $s) | .default_effort // empty' "$MODELS_FILE" 2>/dev/null
}

openai_catalog_successor() { # openai_catalog_successor <slug> -> what a deprecated slug was upgraded to, or nothing
  openai_catalog_available || return 0
  "$JQ" -r --arg s "$1" '.openai.models[] | select(.slug == $s) | .deprecated_by // empty' "$MODELS_FILE" 2>/dev/null
}
```

- [ ] **Step 3: `run_job` — a plataforma, os defaults por plataforma e as recusas**

(a) Logo a seguir a `project="$(job_get "$id" '.project' '')"` (o primeiro `project=` de `run_job`), inserir:

```bash
  # Which CLI this run goes through: the job's own value, else the project's,
  # else anthropic -- which is what every job from before platforms means.
  local platform
  platform="$(resolve "$id" platform 'anthropic')"
  case "$platform" in ''|null) platform="anthropic" ;; esac
```

(b) Substituir estas quatro linhas:

```bash
  model="$(resolve "$id" model 'opus')"
  # A family (opus/sonnet/…) becomes the newest concrete id of that family.
  local model_family=""
  case "$model" in opus|sonnet|haiku|fable) model_family="$model" ;; esac
  model="$(effective_model "$model")"
```

por:

```bash
  model="$(resolve "$id" model "$(platform_default_model "$platform")")"
  # A family (opus/sonnet/…) becomes the newest concrete id of that family --
  # anthropic only. An OpenAI slug is used verbatim (platform_caps families).
  local model_family=""
  if platform_caps "$platform" families; then
    case "$model" in opus|sonnet|haiku|fable) model_family="$model" ;; esac
    model="$(effective_model "$model")"
  fi
```

(c) Substituir `permission="$(resolve "$id" permission_mode 'dontAsk')"` por:

```bash
  permission="$(resolve "$id" permission_mode "$(platform_default_permission "$platform" job)")"
```

(d) Logo a seguir ao bloco que termina em `log_tick "$id: claude_config_dir missing ($run_cfgdir), skipped"; return 1; }`, inserir as recusas:

```bash
  # A run that cannot start is refused HERE, before a slot, a precheck or a
  # turn is spent, with the reason in tick.log -- the treatment `cwd missing`
  # gets. Each of these would otherwise fail at launch with nothing saying why.
  local not_ready
  platform_known "$platform" || { log_tick "$id: unknown platform '$platform', skipped"; return 1; }
  if ! not_ready="$(platform_ready "$platform")"; then
    log_tick "$id: $platform is not ready ($not_ready), skipped"; return 1
  fi
  if [ "$platform" = "openai" ]; then
    [ "$interactive" != "true" ] \
      || { log_tick "$id: interactive is not available on openai (codex exec has no stdin protocol), skipped"; return 1; }
    platform_model_ok openai "$model" \
      || { log_tick "$id: model '$model' is not in the OpenAI catalog (run: agentloop resolve-models openai), skipped"; return 1; }
    platform_permission_ok openai "$permission" \
      || { log_tick "$id: permission_mode '$permission' is not an OpenAI mode (read-only, workspace-write, full-access), skipped"; return 1; }
    local successor; successor="$(openai_catalog_successor "$model")"
    [ -z "$successor" ] || log_tick "$id: model '$model' is deprecated — its successor is $successor"
    # Codex has no tool allow/deny list and cannot close a tool by flag
    # (measured: --disable multi_agent leaves spawn_agent in the roster), so
    # the two fields are ignored here, and said to be.
    [ -z "$allowed" ] || [ "$allowed" = "null" ] \
      || log_tick "$id: allowed_tools is ignored on openai (codex has no tool allowlist)"
    [ -z "$disallowed" ] || [ "$disallowed" = "null" ] \
      || log_tick "$id: disallowed_tools is ignored on openai (codex cannot close a tool by flag)"
  fi
```

(e) Logo a seguir a `run_env=()` e à linha `[ -n "$run_cfgdir" ] && run_env+=("CLAUDE_CONFIG_DIR=$run_cfgdir")`, acrescentar `run_env+=("AL_PLATFORM=$platform")` — um precheck ou um hook de provisioning pode querer saber; só `AL_*`, é um nome novo.

- [ ] **Step 4: `run_job` — o ramo de lançamento OpenAI**

Substituir a linha `fifo=""` (imediatamente antes de `if [ "$interactive" = "true" ]; then` no lançamento) por:

```bash
  fifo=""
  local cli_pid="" normalizer="" rawfifo="" nrc=0
  if [ "$platform" = "openai" ]; then
    # The Codex CLI writes its own JSONL; every reader here wants stream-json.
    # The CLI's stdout goes down a FIFO into the normalizer, which writes the
    # canonical stream to $streamfile and a verbatim copy to $streamfile.raw.
    # `exec` makes the subshell BECOME the CLI, so $child below is the CLI's
    # own pid: stop (TERM), the watchdog's tree_cpu_seconds and wait all keep
    # working unchanged. `< /dev/null` is what keeps `codex exec` from waiting
    # on stdin for ever (measured).
    rawfifo="$logfile.raw.fifo"
    rm -f "$rawfifo"; mkfifo "$rawfifo" 2>/dev/null
    platform_argv_openai "$resume_sid" "$run_cwd" "$model" "$effort" "$permission" "$prompt"
    (
      cd "$run_cwd" || exit 1
      exec env ${run_env[@]+"${run_env[@]}"} "$CODEX_BIN" ${PLATFORM_ARGV[@]+"${PLATFORM_ARGV[@]}"} \
        > "$rawfifo" 2> "$logfile.err" < /dev/null
    ) &
    cli_pid=$!
    "$PYTHON" -u "$BIN_DIR/platforms/openai_stream.py" --model "$model" --permission "$permission" \
      --cwd "$run_cwd" --pricing "$PRICING_FILE" --raw-out "$streamfile.raw" \
      < "$rawfifo" > "$streamfile" 2>> "$logfile.err" &
    normalizer=$!
  elif [ "$interactive" = "true" ]; then
```

(o `if [ "$interactive" = "true" ]; then` original passa a `elif`; o resto do bloco, até `local child=$!`, fica intacto.)

Substituir `local child=$!` por:

```bash
  local child=$!
  [ -z "$normalizer" ] || child="$cli_pid"   # openai: $! was the normalizer
```

Logo a seguir a `wait "$child"; rc=$?`, inserir:

```bash
  if [ -n "$normalizer" ]; then
    # The normalizer ends at EOF on the FIFO. A process the CLI left behind
    # can hold the FIFO's write end open after the CLI itself is gone (a
    # backgrounded tool, a server it started), so the wait is bounded: what is
    # on disk by then is the transcript, and the note says what happened.
    local _nw=0
    while kill -0 "$normalizer" 2>/dev/null && [ "$_nw" -lt 100 ]; do sleep 0.1; _nw=$((_nw + 1)); done
    if kill -0 "$normalizer" 2>/dev/null; then
      kill "$normalizer" 2>/dev/null; wait "$normalizer" 2>/dev/null; nrc=-1
    else
      wait "$normalizer"; nrc=$?
    fi
    rm -f "$rawfifo"
  fi
```

Logo a seguir a `rm -f "$wdfile"` (depois de `wdreason` ser lido), inserir:

```bash
  case "$nrc" in
    0) ;;
    -1) wdreason="${wdreason:+$wdreason · }normalizer killed: the CLI's stdout stayed open 10s after it exited" ;;
    *)  wdreason="${wdreason:+$wdreason · }normalizer exited $nrc" ;;
  esac
  platform_stderr_filter "$platform" "$logfile.err"
```

Logo a seguir às três linhas que lêem `model_id` do evento `init` (`model_id="$("$JQ" -r 'select(.type=="system" and .subtype=="init") | .model' …`, e o `[ -n "$model_id" ] … || model_id=""`), inserir:

```bash
  # On openai the init event carries the slug that was ASKED for; the model
  # that ran is in the rollout. platform_finish also feeds the usage gate.
  platform_finish "$platform" "$streamfile" "$session" "$id"
  [ -z "$PF_MODEL_ID" ] || model_id="$PF_MODEL_ID"
```

- [ ] **Step 5: `bash -n` e um smoke test sem stand-in**

```bash
bash -n bin/agentloop && echo syntax-ok
bin/agentloop selftest 2>&1 | tail -3
```

Expected: `syntax-ok`; o selftest ainda todo verde (nada Anthropic mudou — o argv Anthropic lido pelo selftest continua igual). Uma excepção possível: um teste que aponte `AGENTLOOP_CLAUDE_BIN` a um caminho inexistente e espere um run registado como `error` vê agora uma recusa `anthropic is not ready (claude not found …)` no `tick.log` — é o comportamento desenhado; actualiza-se a asserção, não o engine.

- [ ] **Step 6: O stand-in `test/fake-codex`**

Cria `test/fake-codex` (modo 755, como `test/fake-claude`):

```bash
#!/usr/bin/env bash
# A stand-in for the Codex CLI (`codex`), emitting the JSONL shapes measured on
# codex-cli 0.148.0 -- test/fixtures/codex/ is the evidence -- so an OpenAI run
# can be driven end to end offline. Same caveat as test/fake-claude: unless
# FAKE_ARGV_OUT is set this never reads "$@", so a green run proves nothing
# about the launch line; scenarios 15 and 17 in e2e.test.sh read one back.
#
#   FAKE_SESSION           the thread id reported in thread.started
#   FAKE_MODE              complete | undeclared | dirty | hang | quota | unknown_model
#   FAKE_ARGV_OUT          record the argv, one line per argument, "<n><TAB><first line>"
#   FAKE_CODEX_LOGGED_OUT  set to make `login status` exit 1
#   FAKE_USED_5H/7D        the used_percent the rollout reports (default 5.0 / 2.0)
#   CODEX_HOME             where the rollout is written; a test sets it, never ~/.codex
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  login)     [ -z "${FAKE_CODEX_LOGGED_OUT:-}" ] || exit 1
             echo "Logged in using ChatGPT"; exit 0 ;;
  debug)     cat "$HERE/fixtures/codex/models-catalog.stripped.json"; exit 0 ;;   # debug models [--bundled]
  --version) echo "codex-cli 0.148.0"; exit 0 ;;
  exec)      ;;
  *)         echo "fake-codex: unexpected invocation: $*" >&2; exit 2 ;;
esac

if [ -n "${FAKE_ARGV_OUT:-}" ]; then
  { printf 'ARGC\t%s\n' "$#"
    n=0
    for a in "$@"; do n=$((n + 1)); printf '%s\t%s\n' "$n" "${a%%$'\n'*}"; done
  } > "$FAKE_ARGV_OUT"
fi

tid="${FAKE_SESSION:-01a0fake-0000-7000-8000-000000000001}"
mode="${FAKE_MODE:-complete}"
# The one line the real CLI prints on every run, whatever happens.
echo "Reading additional input from stdin..." >&2

# The rollout the real CLI writes, carrying the two facts the stream lacks: the
# model that ran and the usage windows. A resume appends to the existing file.
if [ -n "${CODEX_HOME:-}" ]; then
  roll="$(ls "$CODEX_HOME"/sessions/*/*/*/rollout-*-"$tid".jsonl 2>/dev/null | head -1)"
  if [ -z "$roll" ]; then
    day="$(date -u +%Y/%m/%d)"
    mkdir -p "$CODEX_HOME/sessions/$day"
    roll="$CODEX_HOME/sessions/$day/rollout-$(date -u +%Y-%m-%dT%H-%M-%S)-$tid.jsonl"
  fi
  now="$(date +%s)"
  printf '{"timestamp":"t","type":"turn_context","payload":{"model":"gpt-5.6-sol-real","cwd":"%s"}}\n' "$PWD" >> "$roll"
  printf '{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s},"plan_type":"plus","rate_limit_reached_type":null}}}\n' \
    "${FAKE_USED_5H:-5.0}" "$((now + 3600))" "${FAKE_USED_7D:-2.0}" "$((now + 86400))" >> "$roll"
fi

printf '{"type":"thread.started","thread_id":"%s"}\n' "$tid"
case "$mode" in
  unknown_model)
    cat <<'JSON'
{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `gpt-nope` not found. Defaulting to fallback metadata."}}
{"type":"turn.started"}
{"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-nope' model is not supported.\"}}"}
{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-nope' model is not supported.\"}}"}}
JSON
    exit 1 ;;
  quota)
    cat <<'JSON'
{"type":"turn.started"}
{"type":"error","message":"You have hit your usage limit. Try again at Aug 21st, 2026 6:32 AM."}
{"type":"turn.failed","error":{"message":"You have hit your usage limit. Try again at Aug 21st, 2026 6:32 AM."}}
JSON
    exit 1 ;;
esac
cat <<'JSON'
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"working"}}
{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc ls","aggregated_output":"","exit_code":null,"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc ls","aggregated_output":"README\n","exit_code":0,"status":"completed"}}
JSON
case "$mode" in
  dirty)
    echo "the agent was here" > agent-left-this.txt
    result="RUN COMPLETE: made a change and did not push it." ;;
  undeclared) result="I did some work." ;;
  hang)
    # BECOME the sleep: the engine's TERM then reaches the process that holds
    # the FIFO's write end, so the normalizer sees EOF the moment the run is
    # stopped (a `sleep` left as a child would keep the FIFO open for 600s).
    exec sleep 600 ;;
  *) result="RUN COMPLETE: nothing needed doing." ;;
esac
printf '{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"%s"}}\n' "$result"
printf '{"type":"turn.completed","usage":{"input_tokens":32675,"cached_input_tokens":28160,"cache_write_input_tokens":0,"output_tokens":123,"reasoning_output_tokens":0}}\n'
exit 0
```

```bash
chmod +x test/fake-codex
FAKE_SESSION=t1 test/fake-codex exec --json -- hi </dev/null 2>/dev/null | tail -1
```

Expected: a linha `turn.completed` com os tokens.

- [ ] **Step 7: Os cenários e2e 13–20**

Em `test/e2e.test.sh`, imediatamente antes do bloco final (`echo` + `printf '\n  %s passed, %s failed\n'`), inserir:

```bash
# ------------------------------------------------------- the OpenAI platform
# The same lifecycle over the Codex stand-in: the run goes down a FIFO into
# the normalizer, the classifier reads the normalized stream, the rollout
# under a sandboxed CODEX_HOME supplies the model that ran.
export AGENTLOOP_CODEX_BIN="$E2E/fake-codex"
export CODEX_HOME="$ROOT/codex-home"        # the stand-in's rollouts; never ~/.codex
mkdir -p "$CODEX_HOME"
# The catalog a slug is validated against. `resolve-models openai` writes it
# from `codex debug models` on a real install; here it is seeded directly.
cat > "$ROOT/config/models.json" <<'JSON'
{"resolved":{},"openai":{"at":1788616000,"source":"fixture","models":[
  {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"x","default_effort":"low",
   "efforts":["low","medium","high","xhigh","max","ultra"],"visibility":"list","priority":6,
   "deprecated_by":"","retires_at":""}]}}
JSON
mkjob_openai() { # mkjob_openai <id> [permission]
  printf '{"jobs":[{"id":"%s","project":"sandbox","enabled":false,"platform":"openai","model":"gpt-5.6-sol","effort":"high","prompt":"do the thing",
    "interval_seconds":3600,"permission_mode":"%s","max_parallel":1}]}\n' "$1" "${2:-workspace-write}" \
    > "$ROOT/config/jobs.json"
  mkdir -p "$ROOT/config/prechecks"
  printf '#!/bin/bash\nexit 0\n' > "$ROOT/config/prechecks/$1.sh"
  chmod +x "$ROOT/config/prechecks/$1.sh"
}
lastrun() { tail -1 "$ROOT/data/runs.ndjson" 2>/dev/null; }
# <index><TAB><argument> readers over a recorded argv file
at_in()  { awk -F'\t' -v i="$2" '$1==i {print $2; exit}' "$1"; }
idx_in() { awk -F'\t' -v w="$2" '$2==w {print $1; exit}' "$1"; }

echo
echo "13. an OpenAI run goes through the Codex stand-in and reads as a clean success"
mkjob_openai j13
FAKE_MODE=complete FAKE_SESSION=thr-clean "$AL" run j13 >/dev/null 2>&1
sleep 2
[ -z "$(dirs j13)" ] && ok "its run directory is gone (declared ending, nothing undelivered)" || bad "left $(dirs j13)"
[ "$(lastrun | jq -r .status)" = "success" ] \
  && ok "status success: the CLI's stdin line was filtered out of stderr" \
  || bad "status $(lastrun | jq -r .status): $(lastrun | jq -r .note)"
[ "$(lastrun | jq -r .session)" = "thr-clean" ] && ok "the session recorded is the thread id" || bad "session $(lastrun | jq -r .session)"
[ "$(lastrun | jq -r .model_id)" = "gpt-5.6-sol-real" ] \
  && ok "model_id is the model the rollout says ran, not the slug asked for" || bad "model_id $(lastrun | jq -r .model_id)"
s13="$(ls "$ROOT"/data/logs/j13/*.stream.ndjson 2>/dev/null | head -1)"
[ -f "$s13.raw" ] && grep -q '"thread.started"' "$s13.raw" \
  && ok "the raw Codex stream is kept beside the normalized one" || bad "no .raw copy"
head -1 "$s13" | jq -e '.subtype=="init" and .platform=="openai"' >/dev/null 2>&1 \
  && ok "the normalized stream opens with the init event" || bad "first line: $(head -1 "$s13")"
[ ! -e "$ROOT"/data/logs/j13/*.raw.fifo ] && ok "the FIFO was removed" || bad "FIFO left behind"

echo
echo "14. an OpenAI run that never declares an ending keeps its tree, bound to the thread id"
mkjob_openai j14
FAKE_MODE=undeclared FAKE_SESSION=thr-cut "$AL" run j14 >/dev/null 2>&1
sleep 2
d14="$(dirs j14 | head -1)"
[ -n "$d14" ] && [ "$(ended j14 "$d14")" = "open" ] && ok "kept, marked open" || bad "dir '$d14' ended '$(ended j14 "$d14")'"
[ "$(cat "$ROOT/data/worktrees/j14/$d14/.session" 2>/dev/null)" = "thr-cut" ] \
  && ok ".session holds the thread id" || bad ".session not bound to the thread"

echo
echo "15. a resume of that thread reattaches, and launches as exec resume in the process cwd"
argv15="$ROOT/argv-15"; rm -f "$argv15"
FAKE_ARGV_OUT="$argv15" FAKE_MODE=complete FAKE_SESSION=thr-cut "$AL" resume j14 thr-cut >/dev/null 2>&1
sleep 2
grep -q "resumed thr-cut in its own tree" "$ROOT/data/tick.log" && ok "the tick log says it reattached" || bad "no reattach line"
[ -z "$(dirs j14)" ] && ok "and the finished session took its directory with it" || bad "left $(dirs j14)"
[ "$(at_in "$argv15" 1)" = "exec" ] && [ "$(at_in "$argv15" 2)" = "resume" ] \
  && ok "argv opens with exec resume" || bad "argv: $(tr '\n' ' ' < "$argv15")"
[ -z "$(idx_in "$argv15" -C)" ] && ok "no -C on a resume (exec resume refuses it; the cwd is the process's)" || bad "-C passed to exec resume"
[ -n "$(idx_in "$argv15" sandbox_mode=workspace-write)" ] && ok "the sandbox travels as -c sandbox_mode=…" || bad "no sandbox_mode override"
ti="$(idx_in "$argv15" thr-cut)"; mi="$(idx_in "$argv15" --)"
[ -n "$ti" ] && [ -n "$mi" ] && [ "$ti" -lt "$mi" ] \
  && ok "the thread id precedes --, and the prompt follows it" || bad "thread id at '$ti', -- at '$mi'"

echo
echo "16. work on no remote is reported for an OpenAI run too"
mkjob_openai j16
FAKE_MODE=dirty FAKE_SESSION=thr-dirty "$AL" run j16 >/dev/null 2>&1
sleep 2
lastrun | grep -q 'UNDELIVERED' && [ -n "$(dirs j16)" ] && ok "UNDELIVERED, and the tree is kept" || bad "no UNDELIVERED note, or tree gone"

echo
echo "17. the launch line of a fresh OpenAI run, read back off the stand-in's argv"
argv17="$ROOT/argv-17"; rm -f "$argv17"
mkjob_openai j17 read-only
FAKE_ARGV_OUT="$argv17" FAKE_MODE=complete FAKE_SESSION=thr-argv "$AL" run j17 >/dev/null 2>&1
sleep 1
argc17="$(awk -F'\t' '$1=="ARGC" {print $2; exit}' "$argv17")"
[ "$(at_in "$argv17" 1)" = "exec" ] && [ "$(at_in "$argv17" 2)" = "--json" ] && ok "exec --json" || bad "argv: $(tr '\n' ' ' < "$argv17")"
ci="$(idx_in "$argv17" -C)"; [ -n "$ci" ] && [ -d "$(at_in "$argv17" $((ci + 1)))" ] \
  && ok "-C names the run's working directory" || bad "-C missing or not a directory"
mi="$(idx_in "$argv17" -m)"; [ "$(at_in "$argv17" $((mi + 1)))" = "gpt-5.6-sol" ] && ok "-m carries the slug verbatim" || bad "-m $(at_in "$argv17" $((mi + 1)))"
si="$(idx_in "$argv17" -s)"; [ "$(at_in "$argv17" $((si + 1)))" = "read-only" ] && ok "-s read-only" || bad "-s '$(at_in "$argv17" $((si + 1)))'"
[ -n "$(idx_in "$argv17" approval_policy=never)" ] && ok "-c approval_policy=never, bare" || bad "no bare approval_policy=never"
[ -n "$(idx_in "$argv17" model_reasoning_effort=high)" ] && ok "-c model_reasoning_effort=high, bare" || bad "no bare effort override"
[ -z "$(idx_in "$argv17" --disable)" ] && ok "no --disable flag: it closes nothing (measured)" || bad "--disable was passed"
[ -z "$(idx_in "$argv17" --skip-git-repo-check)" ] && bad "no --skip-git-repo-check" || ok "--skip-git-repo-check"
dd="$(idx_in "$argv17" --)"; [ -n "$dd" ] && [ "$((dd + 1))" = "$argc17" ] \
  && ok "the prompt is the one argument after --" || bad "-- at '$dd', argc $argc17"

echo
echo "18. a spent OpenAI quota is rate_limited, outside the backoff"
mkjob_openai j18
echo '{"j18":{"fail_streak":2}}' > "$ROOT/data/state.json"
FAKE_MODE=quota FAKE_SESSION=thr-quota "$AL" run j18 >/dev/null 2>&1
sleep 2
[ "$(lastrun | jq -r .status)" = "error" ] && [ "$(lastrun | jq -r .cause)" = "rate_limited" ] \
  && ok "error / rate_limited" || bad "$(lastrun | jq -c '{status,cause}')"
[ "$(jq -r '.j18.fail_streak' "$ROOT/data/state.json")" = "2" ] && ok "fail_streak untouched" || bad "streak $(jq -r '.j18.fail_streak' "$ROOT/data/state.json")"

echo
echo "19. a stop ends an OpenAI run that will not end by itself"
mkjob_openai j19
FAKE_MODE=hang FAKE_SESSION=thr-hang "$AL" run j19 >/dev/null 2>&1 &
w=0; while [ "$w" -lt 20 ] && ! ls "$ROOT"/data/locks/j19/*/child >/dev/null 2>&1; do sleep 1; w=$((w + 1)); done
sleep 1
"$AL" stop j19 >/dev/null 2>&1
wait
[ "$(lastrun | jq -r .status)" = "stopped" ] && ok "status stopped (waited ${w}s for the slot)" || bad "status $(lastrun | jq -r .status)"
[ ! -e "$ROOT"/data/logs/j19/*.raw.fifo ] && ok "the FIFO was removed" || bad "FIFO left behind"

echo
echo "20. a run that cannot start is refused in tick.log before it costs a slot"
mkjob_openai j20
FAKE_CODEX_LOGGED_OUT=1 "$AL" run j20 >/dev/null 2>&1
grep -q 'j20: openai is not ready (codex is not signed in' "$ROOT/data/tick.log" && ok "no login → refused" || bad "no login refusal line"
[ ! -d "$ROOT/data/logs/j20" ] && ok "and no log was written" || bad "a run started without a login"
sed -i '' 's/"gpt-5.6-sol"/"gpt-nope"/' "$ROOT/config/jobs.json"
"$AL" run j20 >/dev/null 2>&1
grep -q "j20: model 'gpt-nope' is not in the OpenAI catalog" "$ROOT/data/tick.log" && ok "unknown slug → refused" || bad "no catalog refusal"
mkjob_openai j20
sed -i '' 's/"platform":"openai"/"platform":"openai","interactive":true/' "$ROOT/config/jobs.json"
"$AL" run j20 >/dev/null 2>&1
grep -q "j20: interactive is not available on openai" "$ROOT/data/tick.log" && ok "interactive → refused" || bad "no interactive refusal"
mkjob_openai j20
sed -i '' 's/"platform":"openai"/"platform":"openai","disallowed_tools":"Agent"/' "$ROOT/config/jobs.json"
FAKE_MODE=complete FAKE_SESSION=thr-tools "$AL" run j20 >/dev/null 2>&1
grep -q "j20: disallowed_tools is ignored on openai" "$ROOT/data/tick.log" && ok "disallowed_tools → one line, run goes on" || bad "no ignored-tools line"
```

- [ ] **Step 8: Correr o e2e**

Run: `bash test/e2e.test.sh 2>&1 | tail -40`
Expected: os cenários 13–20 todos `ok`, `0 failed`. Se o 19 ficar pendurado, o FIFO não fechou: confirmar que `fake-codex` faz `exec sleep 600` e que o engine espera o normalizador com o ciclo limitado do passo 4.

- [ ] **Step 9: Os casos do selftest**

Em `cmd_selftest`, logo a seguir ao bloco `echo "session_from_stream() — …"` (antes de `echo "model_alias_baseline() …"`), inserir:

```bash
  echo "platforms — the table run_job asks instead of naming a binary"
  platform_known openai;      want "openai is a known platform"        0 $?
  platform_known anthropic;   want "anthropic is a known platform"     0 $?
  platform_known gemini;      want "an unknown platform is refused"    1 $?
  platform_caps anthropic interactive; want "anthropic has interactive" 0 $?
  local _cap; local _openai_caps=0
  for _cap in interactive tool_lists denials budget_flag cost_reported stream_rate_limits families; do
    platform_caps openai "$_cap" && _openai_caps=$((_openai_caps + 1))
  done
  [ "$_openai_caps" -eq 0 ] && ok "openai has none of the seven capabilities" || bad "openai claims $_openai_caps capabilities"
  platform_permission_ok openai workspace-write; want "workspace-write is an openai mode"   0 $?
  platform_permission_ok openai dontAsk;         want "dontAsk is not an openai mode"        1 $?
  platform_permission_ok anthropic dontAsk;      want "dontAsk is an anthropic mode"         0 $?
  [ "$(platform_default_permission openai job)" = "workspace-write" ] && [ "$(platform_default_permission openai security)" = "full-access" ] \
    && ok "openai defaults: workspace-write for a job, full-access for an analysis" || bad "openai default permissions"
  platform_effort_ok anthropic opus ultra;   want "ultra is not an anthropic effort"          1 $?
  platform_effort_ok anthropic opus "";      want "an empty effort is always fine"            0 $?

  # The catalog readers, over a models.json of this test's own.
  mkdir -p "$tmp/cat"
  "$JQ" -n '{resolved:{}, openai:{at:1, source:"fixture", models:[
      {slug:"gpt-b", visibility:"list", priority:7, efforts:["low","high"], default_effort:"low", deprecated_by:"", retires_at:""},
      {slug:"gpt-a", visibility:"list", priority:6, efforts:["low","high","ultra"], default_effort:"low", deprecated_by:"", retires_at:""},
      {slug:"gpt-hidden", visibility:"hide", priority:3, efforts:["low"], default_effort:"low", deprecated_by:"", retires_at:""},
      {slug:"gpt-old", visibility:"list", priority:23, efforts:["low"], default_effort:"low", deprecated_by:"gpt-b", retires_at:"2026-08-31T19:00:00Z"}]}}' \
    > "$tmp/cat/models.json"
  ( MODELS_FILE="$tmp/cat/models.json"
    [ "$(platform_default_model openai)" = "gpt-a" ] && ok "the default openai model is the listed slug with the lowest priority" || bad "default $(platform_default_model openai)"
    platform_model_ok openai gpt-hidden; want "a hidden slug is accepted when written"      0 $?
    platform_model_ok openai gpt-nope;   want "a slug outside the catalog is refused"       1 $?
    platform_effort_ok openai gpt-a ultra; want "ultra is fine where the catalog lists it"  0 $?
    platform_effort_ok openai gpt-b ultra; want "and refused where it does not"             1 $?
    [ "$(openai_catalog_successor gpt-old)" = "gpt-b" ] && ok "a deprecated slug names its successor" || bad "successor $(openai_catalog_successor gpt-old)"
    [ -z "$(openai_catalog_successor gpt-a)" ] && ok "a live slug names none" || bad "live slug has a successor" )
  ( MODELS_FILE="$tmp/cat/none.json"
    platform_model_ok openai gpt-a; want "without a catalog every slug is refused" 1 $?
    [ -z "$(platform_default_model openai)" ] && ok "and there is no default model" || bad "default without a catalog"
    platform_effort_ok openai gpt-a ultra; want "but the effort vocabulary falls back to the union" 0 $? )

  echo "platform_stderr_filter() — exactly the CLI's one known line, nothing else"
  printf 'Reading additional input from stdin...\nsomething real\n' > "$tmp/e1.err"
  platform_stderr_filter openai "$tmp/e1.err"
  [ "$(cat "$tmp/e1.err")" = "something real" ] && ok "the known line goes, the rest stays" || bad "left: $(cat "$tmp/e1.err")"
  printf 'Reading additional input from stdin...\n' > "$tmp/e2.err"
  platform_stderr_filter openai "$tmp/e2.err"
  [ ! -s "$tmp/e2.err" ] && ok "a stderr that was only that line is now empty" || bad "not emptied"
  printf 'Reading additional input from stdin... and more\n' > "$tmp/e3.err"
  platform_stderr_filter openai "$tmp/e3.err"
  [ -s "$tmp/e3.err" ] && ok "a line that merely contains the phrase is kept" || bad "a longer line was removed"
  printf 'Reading additional input from stdin...\n' > "$tmp/e4.err"
  platform_stderr_filter anthropic "$tmp/e4.err"
  [ -s "$tmp/e4.err" ] && ok "anthropic stderr is never touched" || bad "anthropic stderr was filtered"

  echo "platform_argv_openai() — the measured launch line, for a fresh run and a resume"
  platform_argv_openai "" /tmp/w gpt-a high workspace-write "PROMPT"
  local _av; _av="$(printf '%s\n' "${PLATFORM_ARGV[@]}")"
  [ "${PLATFORM_ARGV[0]}" = "exec" ] && [ "${PLATFORM_ARGV[1]}" = "--json" ] && ok "exec --json first" || bad "argv starts ${PLATFORM_ARGV[0]} ${PLATFORM_ARGV[1]}"
  printf '%s\n' "$_av" | grep -qx -- '-C' && ok "-C on a fresh run" || bad "no -C"
  printf '%s\n' "$_av" | grep -qx -- 'model_reasoning_effort=high' && ok "the effort override is bare" || bad "effort override missing or quoted"
  printf '%s\n' "$_av" | grep -qx -- 'approval_policy=never' && ok "approval_policy=never travels with a sandboxed mode" || bad "no approval_policy"
  printf '%s\n' "$_av" | grep -qx -- '--disable' && bad "--disable is passed and closes nothing" || ok "no --disable flag"
  [ "${PLATFORM_ARGV[$((${#PLATFORM_ARGV[@]} - 2))]}" = "--" ] && [ "${PLATFORM_ARGV[$((${#PLATFORM_ARGV[@]} - 1))]}" = "PROMPT" ] \
    && ok "-- then the prompt, last" || bad "the prompt is not the lone argument after --"
  platform_argv_openai "" /tmp/w gpt-a "" full-access "P"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- '--dangerously-bypass-approvals-and-sandbox' \
    && ok "full-access is the bypass flag" || bad "full-access not translated"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- '-s' && bad "-s alongside the bypass flag" || ok "and no -s beside it"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -q 'model_reasoning_effort' && bad "an empty effort still emitted an override" || ok "an empty effort emits no override"
  platform_argv_openai thr-1 /tmp/w gpt-a low read-only "P"
  [ "${PLATFORM_ARGV[0]}" = "exec" ] && [ "${PLATFORM_ARGV[1]}" = "resume" ] && ok "a resume is exec resume" || bad "resume argv ${PLATFORM_ARGV[*]}"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- '-C' && bad "-C on a resume (exec resume refuses it)" || ok "no -C on a resume"
  printf '%s\n' "${PLATFORM_ARGV[@]}" | grep -qx -- 'sandbox_mode=read-only' && ok "the sandbox is a -c override on a resume" || bad "no sandbox_mode on the resume"
  [ "${PLATFORM_ARGV[$((${#PLATFORM_ARGV[@]} - 3))]}" = "thr-1" ] && ok "the thread id sits right before --" || bad "thread id misplaced"

  echo "platform_finish() — the model that ran comes from the rollout"
  mkdir -p "$tmp/ch/sessions/2026/09/05"
  cp "$BASE_DIR/test/fixtures/codex/rollout-sample.stripped.jsonl" "$tmp/ch/sessions/2026/09/05/rollout-2026-09-05T13-49-58-01a071d5-47b0-7343-bcbd-216945ef7927.jsonl"
  ( CODEX_HOME_DIR="$tmp/ch"; RATE_LIMIT_FILE="$tmp/ch/rate-limits.json"   # T7 makes this write the gate; never the real file
    platform_finish openai /dev/null 01a071d5-47b0-7343-bcbd-216945ef7927 selftest
    [ "$PF_MODEL_ID" = "gpt-5.6-sol" ] && ok "turn_context.model is read" || bad "PF_MODEL_ID '$PF_MODEL_ID'"
    platform_finish openai /dev/null thr-missing selftest
    [ -z "$PF_MODEL_ID" ] && grep -q 'no codex rollout for thread thr-missing' "$TICK_LOG" \
      && ok "a missing rollout leaves model_id alone and says so in tick.log" || bad "missing rollout: '$PF_MODEL_ID'"
    platform_finish anthropic /dev/null sess-x selftest
    [ -z "$PF_MODEL_ID" ] && ok "a no-op on anthropic" || bad "anthropic set PF_MODEL_ID" )

  echo "turn_is_over() — over a normalized OpenAI stream"
  "$PYTHON" -u "$BIN_DIR/platforms/openai_stream.py" --model gpt-5.6-sol --permission read-only --cwd /tmp \
    < "$BASE_DIR/test/fixtures/codex/02-tool-use.jsonl" > "$tmp/oa.ndjson" 2>/dev/null
  turn_is_over "$tmp/oa.ndjson"; want "a finished Codex turn is over" 0 $?
  grep -v turn.completed "$BASE_DIR/test/fixtures/codex/02-tool-use.jsonl" \
    | "$PYTHON" -u "$BIN_DIR/platforms/openai_stream.py" --model gpt-5.6-sol --permission read-only --cwd /tmp > "$tmp/ob.ndjson" 2>/dev/null
  turn_is_over "$tmp/ob.ndjson"; want "a Codex turn cut before its end is not" 1 $?
  [ "$(session_from_stream "$tmp/oa.ndjson")" = "01a071d5-47b0-7343-bcbd-216945ef7927" ] \
    && ok "session_from_stream reads the thread id off the first line" || bad "session $(session_from_stream "$tmp/oa.ndjson")"
```

Run: `bin/agentloop selftest 2>&1 | grep -E 'FAIL|failed'`
Expected: nenhuma linha `FAIL`; `0 failed`.

- [ ] **Step 10: CHANGELOG e commit**

Bullet a acrescentar à entrada:

```markdown
  - The engine has a platform table (`platform_*` in `bin/agentloop`): which
    binary, whether it is ready (for Codex: installed AND signed in), what it
    can and cannot do, and the launch line — measured, including the resume
    that runs in the process's own directory. An OpenAI run goes down a FIFO
    into the normalizer; the CLI is still `$child`, so stop, the watchdog and
    wait are unchanged. Runs that cannot start are refused in `tick.log`
    before a slot is taken: unknown platform, Codex missing or signed out,
    `interactive` on OpenAI, a slug outside the catalog. `test/fake-codex`
    stands in for the CLI offline, and `test/e2e.test.sh` drives an OpenAI run
    through complete, undeclared, dirty, resume, stop, quota and refusal.
```

```bash
git add bin/agentloop test/fake-codex test/e2e.test.sh CHANGELOG.md
git commit -m "feat(platforms): a job on the openai platform runs through the Codex CLI

The platform table (platform_*) answers what run_job used to assume; the
openai launch goes down a FIFO into the normalizer with the CLI still as
\$child; the stdin line is filtered from stderr; the model that ran is read
from the rollout; refusals land in tick.log before a slot is spent. Driven
end to end over test/fake-codex.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: O catálogo — `resolve-models [platform]`, `models.json.openai`, `/api/models` por plataforma, `agentloop platforms`

**Files:**
- Modify: `bin/agentloop` (`cmd_resolve_models` ~L6733, `models_stale` ~L2047, um `resolve_models_openai` e `openai_catalog_ensure` novos junto ao bloco de leitura do catálogo, `cmd_platforms` novo, dispatch), `bin/agentloop-server` (`list_models` ~L2289, `PLATFORM_PERMISSIONS` novo), `test/fake-codex` (nada: já responde a `debug models`), `test/e2e.test.sh` (a semente de `models.json` do cenário 13 passa a vir de `resolve-models openai`), `CHANGELOG.md`
- Create: `tests/test_platforms_api.py`
- Test: `tests/test_platforms_api.py`, `bin/agentloop selftest`, `bash test/e2e.test.sh`

**Interfaces:**
- Consumes: `openai_catalog_*` (T3), `CODEX_BIN` (T3), `PRICING_FILE` (T3), `platform_permissions`/`platform_efforts`/`platform_default_*` (T3).
- Produces: `agentloop resolve-models [anthropic|openai]` (sem argumento faz os dois); `resolve_models_openai` (escreve o bloco `openai`); `openai_catalog_ensure` (resolve uma vez, em síncrono, quando o bloco falta e o `codex` existe — T5 chama-o antes de validar um slug); `agentloop platforms` → JSON `{"anthropic":{"ready":bool,"reason":"","permissions":[…],"efforts":[…],"default_model":"opus","default_permission":"dontAsk"},"openai":{…,"catalog_at":<epoch>,"catalog_available":bool}}`; `/api/models` → `{"models":[…],"efforts":[…],"platforms":{"anthropic":{…},"openai":{…}}}` na forma da spec; `PLATFORM_PERMISSIONS` no servidor.

- [ ] **Step 1: O teste pytest, que vai falhar**

Cria `tests/test_platforms_api.py`:

```python
"""/api/models per platform, and the one vocabulary the server mirrors from
the engine.

The page will read platforms, models, efforts and permission modes from this
endpoint (plan B2); until then the old top-level keys (`models`, `efforts`)
stay exactly as they were, so the page that exists today keeps working. The
permission vocabulary lives in the engine (platform_permissions) and the
server repeats it with labels: `test_the_permission_vocabulary_matches_the_engine`
is what keeps the two from drifting, the way the backoff curve test does.
"""
import json
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENGINE = REPO / "bin" / "agentloop"
FIX = REPO / "test" / "fixtures" / "codex"


def _catalog_block():
    cat = json.loads((FIX / "models-catalog.stripped.json").read_text())["models"]
    return {"at": 1788616000, "source": "fixture", "models": [
        {"slug": m["slug"], "display_name": m["display_name"], "description": m["description"],
         "default_effort": m["default_reasoning_level"],
         "efforts": [l["effort"] for l in m["supported_reasoning_levels"]],
         "visibility": m["visibility"], "priority": m["priority"],
         "deprecated_by": (m.get("upgrade") or {}).get("model") or "",
         "retires_at": (m.get("upgrade") or {}).get("retirement_at") or ""}
        for m in cat]}


def _write_models(srv, openai=None, resolved=None):
    data = {"resolved": resolved or {"opus": {"id": "claude-opus-5", "at": 1788585387}}}
    if openai is not None:
        data["openai"] = openai
    (srv.CONFIG_DIR / "models.json").write_text(json.dumps(data))


def test_the_old_keys_are_still_there_for_the_current_page(srv):
    _write_models(srv, openai=_catalog_block())
    out = srv.list_models()
    assert "claude-opus-5" in out["models"]
    assert out["efforts"] == ["low", "medium", "high", "xhigh", "max"]


def test_platforms_carry_the_catalog_visible_models_in_priority_order(srv):
    _write_models(srv, openai=_catalog_block())
    (srv.CONFIG_DIR / "pricing.json").write_text(
        json.dumps({"openai": {"gpt-5.6-sol": {"input": 4, "cached_input": 0.4, "output": 20}}}))
    p = srv.list_models()["platforms"]
    assert set(p) == {"anthropic", "openai"}
    a, o = p["anthropic"], p["openai"]
    assert a["available"] is True and a["default_model"] == "opus"
    assert a["models"] == srv.list_models()["models"]
    assert [m["v"] for m in a["permissions"]] == \
        ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]
    assert o["available"] is True and o["catalog_at"] == 1788616000
    slugs = [m["v"] for m in o["models"]]
    assert slugs == ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4-mini"]
    assert "gpt-reserve" not in slugs                        # hidden stays hidden
    sol = o["models"][0]
    assert sol["label"] == "GPT-5.6-Sol" and sol["efforts"][-1] == "ultra"
    assert sol["default_effort"] == "low" and sol["priced"] is True
    mini = o["models"][-1]
    assert mini["deprecated_by"] == "gpt-5.6-luna" and mini["retires_at"].startswith("2026-08-31")
    assert mini["priced"] is False                          # no pricing.json row
    assert o["efforts"] == ["low", "medium", "high", "xhigh", "max", "ultra"]
    assert [m["v"] for m in o["permissions"]] == ["read-only", "workspace-write", "full-access"]
    assert o["default_model"] == "gpt-5.6-sol"


def test_an_unavailable_catalog_says_why(srv):
    _write_models(srv, openai={"at": 1, "available": False, "reason": "codex not installed"})
    o = srv.list_models()["platforms"]["openai"]
    assert o["available"] is False and o["reason"] == "codex not installed"
    assert o["models"] == [] and o["default_model"] == ""


def test_a_missing_block_is_resolved_once_when_codex_exists(srv, monkeypatch):
    _write_models(srv, openai=None)
    calls = []

    def fake_al(args, stdin=None, background=False):
        calls.append(args)
        _write_models(srv, openai=_catalog_block())
        return True, "ok"
    monkeypatch.setattr(srv, "al", fake_al)
    monkeypatch.setattr(srv.shutil, "which", lambda name: "/opt/homebrew/bin/codex")
    o = srv.list_models()["platforms"]["openai"]
    assert calls == [["resolve-models", "openai"]]
    assert o["available"] is True


def test_a_missing_block_without_codex_is_reported_not_resolved(srv, monkeypatch):
    _write_models(srv, openai=None)
    monkeypatch.setattr(srv, "al", lambda *a, **k: (_ for _ in ()).throw(AssertionError("al called")))
    monkeypatch.setattr(srv.shutil, "which", lambda name: None)
    monkeypatch.delenv("AGENTLOOP_CODEX_BIN", raising=False)
    o = srv.list_models()["platforms"]["openai"]
    assert o["available"] is False and "codex" in o["reason"]


def test_the_permission_vocabulary_matches_the_engine(srv):
    out = subprocess.run(["/bin/bash", str(ENGINE), "platforms"],
                         capture_output=True, text=True, check=True).stdout
    engine = json.loads(out)
    for platform, modes in srv.PLATFORM_PERMISSIONS.items():
        assert [m["v"] for m in modes] == engine[platform]["permissions"], platform
    assert engine["anthropic"]["efforts"] == ["low", "medium", "high", "xhigh", "max"]
```

Run: `python3.13 -m pytest -p no:cacheprovider tests/test_platforms_api.py -q`
Expected: FAIL — `KeyError: 'platforms'`, `AttributeError: PLATFORM_PERMISSIONS`, e `platforms` é um comando desconhecido para o engine.

- [ ] **Step 2: O escritor do catálogo, no engine**

Em `bin/agentloop`, logo a seguir a `openai_catalog_successor()` (fim do bloco de leitura de T3), inserir:

```bash
# --- the OpenAI catalog, write side ------------------------------------------
resolve_models_openai() { # refresh config/models.json's `openai` block from `codex debug models`
  local raw source block tmp
  tmp="$(mktemp "$CONFIG_DIR/.models.XXXXXX")" || return 1
  [ -f "$MODELS_FILE" ] || echo '{"resolved":{}}' > "$MODELS_FILE"
  if [ ! -x "$CODEX_BIN" ]; then
    block="$("$JQ" -nc --argjson at "$(now_epoch)" '{at:$at, available:false, reason:"codex not installed"}')"
  else
    source="codex debug models"
    raw="$("$CODEX_BIN" debug models 2>/dev/null)"
    if ! printf '%s' "$raw" | "$JQ" -e '.models | type == "array"' >/dev/null 2>&1; then
      source="bundled"
      raw="$("$CODEX_BIN" debug models --bundled 2>/dev/null)"
    fi
    if ! printf '%s' "$raw" | "$JQ" -e '.models | type == "array"' >/dev/null 2>&1; then
      block="$("$JQ" -nc --argjson at "$(now_epoch)" '{at:$at, available:false, reason:"codex debug models returned no catalog"}')"
    else
      # Only what the selector and the validators need. The prompt templates
      # the CLI ships in this JSON are not ours to keep.
      block="$(printf '%s' "$raw" | "$JQ" -c --argjson at "$(now_epoch)" --arg src "$source" '
        {at:$at, source:$src, models:[.models[] | {
          slug, display_name:(.display_name // .slug), description:(.description // ""),
          default_effort:(.default_reasoning_level // ""),
          efforts:[(.supported_reasoning_levels // [])[] | .effort],
          visibility:(.visibility // "list"), priority:(.priority // 999),
          deprecated_by:(.upgrade.model // ""), retires_at:(.upgrade.retirement_at // "")}]}')"
    fi
  fi
  "$JQ" --argjson b "$block" '.openai = $b' "$MODELS_FILE" > "$tmp" && mv "$tmp" "$MODELS_FILE"
  rm -f "$tmp"
  if openai_catalog_available; then
    echo "openai -> $(openai_catalog_visible | tr '\n' ' ')($(printf '%s' "$block" | "$JQ" -r .source))"
  else
    echo "openai -> unavailable: $(printf '%s' "$block" | "$JQ" -r .reason)"
  fi
}

openai_catalog_ensure() { # resolve once, synchronously, when the block is missing and codex exists (0 s measured)
  openai_catalog_available && return 0
  [ -x "$CODEX_BIN" ] || return 1
  resolve_models_openai >/dev/null 2>&1
  openai_catalog_available
}
```

Substituir `cmd_resolve_models()` inteiro por:

```bash
cmd_resolve_models() { # cmd_resolve_models [anthropic|openai] -- no argument does both
  local which="${1:-}" fam id
  case "$which" in
    ""|anthropic)
      for fam in opus sonnet haiku fable; do
        id="$(resolve_family "$fam")"
        [ -n "$id" ] || id="$fam"
        models_cache_set "$fam" "$id"
        echo "$fam -> $id"
      done ;;
  esac
  case "$which" in
    ""|openai) resolve_models_openai ;;
  esac
  case "$which" in ""|anthropic|openai) ;; *) die "resolve-models: unknown platform '$which'" ;; esac
}
```

Substituir `models_stale()` por:

```bash
models_stale() { # 0 = either cache is missing or older than MODELS_TTL
  local oldest oa
  [ -f "$MODELS_FILE" ] || return 0
  oldest="$("$JQ" -r '[.resolved[]?.at // 0] | min // 0' "$MODELS_FILE" 2>/dev/null)"
  case "$oldest" in ''|null|*[!0-9]*) oldest=0 ;; esac
  # The openai block ages the same way. Absent, it is stale by definition --
  # which is what gets it written on the first tick after this upgrade.
  oa="$("$JQ" -r '.openai.at // 0' "$MODELS_FILE" 2>/dev/null)"
  case "$oa" in ''|null|*[!0-9]*) oa=0 ;; esac
  [ "$oa" -lt "$oldest" ] && oldest="$oa"
  [ "$(( $(now_epoch) - oldest ))" -ge "$MODELS_TTL" ]
}
```

No dispatch, substituir `resolve-models) cmd_resolve_models ;;` por `resolve-models) cmd_resolve_models "${2:-}" ;;`. A linha do `usage` que descreve `resolve-models` passa a `agentloop resolve-models [anthropic|openai]  refresh the model catalogues (both, without an argument)`. O ramo `_resolve_models)` do tick fica como está: chama `cmd_resolve_models` sem argumento, os dois.

- [ ] **Step 3: `agentloop platforms`**

A seguir a `cmd_resolve_models()`, inserir:

```bash
cmd_platforms() { # one JSON object: what each platform offers and whether it is ready
  local p ready reason perms efforts dm dp cat_at cat_ok
  for p in $PLATFORMS; do
    if reason="$(platform_ready "$p")"; then ready=true; reason=""; else ready=false; fi
    perms="$(platform_permissions "$p" | "$JQ" -R . | "$JQ" -sc .)"
    if [ "$p" = "openai" ]; then efforts="$(openai_catalog_efforts "" | "$JQ" -R . | "$JQ" -sc .)"
    else efforts="$(platform_efforts "$p" | "$JQ" -R . | "$JQ" -sc .)"; fi
    dm="$(platform_default_model "$p")"; dp="$(platform_default_permission "$p" job)"
    cat_at=0; cat_ok=false
    if [ "$p" = "openai" ]; then
      cat_at="$(num "$("$JQ" -r '.openai.at // 0' "$MODELS_FILE" 2>/dev/null)")"
      openai_catalog_available && cat_ok=true
    fi
    "$JQ" -nc --arg p "$p" --argjson ready "$ready" --arg reason "$reason" \
      --argjson perms "$perms" --argjson efforts "$efforts" --arg dm "$dm" --arg dp "$dp" \
      --argjson cat_at "$cat_at" --argjson cat_ok "$cat_ok" \
      '{($p): ({ready:$ready, reason:$reason, permissions:$perms, efforts:$efforts,
                default_model:$dm, default_permission:$dp}
               + (if $p == "openai" then {catalog_at:$cat_at, catalog_available:$cat_ok} else {} end))}'
  done | "$JQ" -sc 'add'
}
```

E no dispatch, a seguir a `resolve-models)`: `platforms) cmd_platforms ;;`. No `usage`: `agentloop platforms         what each platform offers (permission modes, efforts, defaults) and whether it is ready`.

Validar à mão:

```bash
bin/agentloop platforms | jq .
```

Expected: um objecto com `anthropic` e `openai`; nesta máquina `openai.ready` é `true` (o `codex` está instalado e com sessão) e, depois de `bin/agentloop resolve-models openai`, `openai.default_model` é `gpt-5.6-sol` e `openai.efforts` tem seis níveis. Nota bash 3.2: nenhum `case` dentro de `$( )` acima — só `if`, `[ ]` e chamadas.

- [ ] **Step 4: O servidor — `PLATFORM_PERMISSIONS` e `list_models` por plataforma**

Em `bin/agentloop-server`, logo antes de `MODEL_FAMILIES = [`, inserir:

```python
# The permission vocabulary lives in the engine (platform_permissions); this
# mirrors it with the labels the page shows, and tests/test_platforms_api.py
# pins the two together. The label says what the mode DOES on that CLI --
# the two vocabularies are not the same thing renamed.
PLATFORM_PERMISSIONS = {
    "anthropic": [
        {"v": "acceptEdits", "label": "acceptEdits — edits allowed, commands ask"},
        {"v": "auto", "label": "auto — the CLI decides per tool"},
        {"v": "bypassPermissions", "label": "bypassPermissions — nothing asks"},
        {"v": "manual", "label": "manual — everything asks (headless: everything denied)"},
        {"v": "dontAsk", "label": "dontAsk — allowlisted tools only, no prompts"},
        {"v": "plan", "label": "plan — read-only planning"},
    ],
    "openai": [
        {"v": "read-only", "label": "read-only — sandbox: no writes, no network"},
        {"v": "workspace-write", "label": "workspace-write — sandbox: writes inside the workspace"},
        {"v": "full-access", "label": "full-access — no sandbox, no approvals"},
    ],
}
ANTHROPIC_EFFORTS = ["low", "medium", "high", "xhigh", "max"]
```

Substituir o `return` final de `list_models()` (`return {"models": sorted(ids, key=sort_key), "efforts": [...]}`) por:

```python
    models = sorted(ids, key=sort_key)
    return {"models": models, "efforts": list(ANTHROPIC_EFFORTS),
            "platforms": {"anthropic": {"available": True, "reason": "", "models": models,
                                        "efforts": list(ANTHROPIC_EFFORTS),
                                        "permissions": PLATFORM_PERMISSIONS["anthropic"],
                                        "default_model": "opus"},
                          "openai": _openai_platform()}}
```

E, antes de `list_models()`, a função nova:

```python
def _openai_platform():
    """The openai entry of /api/models, from config/models.json's `openai`
    block. A block that is missing altogether is resolved ONCE, synchronously
    (`codex debug models` answers in 0 s), when the CLI exists; without the CLI
    the answer is `available: false` and the reason, never an empty list that
    looks like "no models"."""
    path = CONFIG_DIR / "models.json"

    def block():
        try:
            return (json.loads(path.read_text()) or {}).get("openai")
        except Exception:  # noqa: BLE001
            return None

    b = block()
    if b is None:
        codex = _env("CODEX_BIN") or shutil.which("codex")
        if codex:
            al(["resolve-models", "openai"])
            b = block()
    if not isinstance(b, dict) or not isinstance(b.get("models"), list):
        reason = (b or {}).get("reason") if isinstance(b, dict) else None
        return {"available": False, "reason": reason or "codex not installed: run codex login, then agentloop resolve-models openai",
                "catalog_at": (b or {}).get("at", 0) if isinstance(b, dict) else 0,
                "models": [], "efforts": [], "permissions": PLATFORM_PERMISSIONS["openai"],
                "default_model": ""}
    try:
        priced = (json.loads((CONFIG_DIR / "pricing.json").read_text()) or {}).get("openai") or {}
    except Exception:  # noqa: BLE001
        priced = {}

    def has_price(slug):
        row = priced.get(slug)
        return isinstance(row, dict) and all(
            isinstance(row.get(k), (int, float)) and not isinstance(row.get(k), bool)
            for k in ("input", "cached_input", "output"))

    visible = sorted((m for m in b["models"] if m.get("visibility", "list") == "list"),
                     key=lambda m: m.get("priority", 999))
    models = [{"v": m["slug"], "label": m.get("display_name") or m["slug"],
               "desc": m.get("description") or "", "efforts": list(m.get("efforts") or []),
               "default_effort": m.get("default_effort") or "",
               "deprecated_by": m.get("deprecated_by") or "", "retires_at": m.get("retires_at") or "",
               "priced": has_price(m["slug"])} for m in visible]
    efforts, seen = [], set()
    for m in b["models"]:                      # the union, in first-seen order
        for e in m.get("efforts") or []:
            if e not in seen:
                seen.add(e); efforts.append(e)
    return {"available": True, "reason": "", "catalog_at": b.get("at", 0),
            "models": models, "efforts": efforts,
            "permissions": PLATFORM_PERMISSIONS["openai"],
            "default_model": models[0]["v"] if models else ""}
```

`shutil` já é importado pelo servidor? Verificar com `grep -n '^import shutil' bin/agentloop-server`; se não, acrescentar ao bloco de imports.

- [ ] **Step 5: O e2e passa a obter o catálogo pelo caminho real**

Em `test/e2e.test.sh`, substituir o `cat > "$ROOT/config/models.json" <<'JSON' … JSON` do cenário 13 (T3) por:

```bash
"$AL" resolve-models openai >/dev/null 2>&1
jq -e '.openai.models | length > 0' "$ROOT/config/models.json" >/dev/null \
  && ok "resolve-models openai wrote the catalog from the stand-in's debug models" \
  || bad "no openai catalog after resolve-models"
```

(o `fake-codex debug models` devolve a fixture do catálogo, que tem `gpt-5.6-sol` visível com `ultra`; os cenários 13–20 continuam a valer.)

- [ ] **Step 6: Correr tudo**

```bash
python3.13 -m pytest -p no:cacheprovider tests/test_platforms_api.py tests/test_page_contract.py -q
bin/agentloop selftest 2>&1 | grep -E 'FAIL|failed'
bash test/e2e.test.sh 2>&1 | tail -3
```

Expected: pytest verde (o contrato da página não muda: as chaves antigas continuam lá); selftest `0 failed`; e2e `0 failed`.

- [ ] **Step 7: CHANGELOG e commit**

Bullet:

```markdown
  - `agentloop resolve-models [anthropic|openai]` keeps `config/models.json`
    current for both platforms (the tick refreshes both daily); the OpenAI
    block comes from `codex debug models`, falling back to the bundled
    catalog, and says `available: false` with a reason when there is no
    Codex. `/api/models` now carries a `platforms` object — models, effort
    levels, permission modes and defaults per platform, and whether each
    slug has a price — while its old keys stay as they were for the current
    page. `agentloop platforms` prints the same from the terminal.
```

```bash
git add bin/agentloop bin/agentloop-server tests/test_platforms_api.py test/e2e.test.sh CHANGELOG.md
git commit -m "feat(platforms): the OpenAI catalog is resolved, cached and served per platform

resolve-models takes a platform (none does both), models.json gains an
openai block from codex debug models, and /api/models answers per platform
beside its old keys. agentloop platforms prints the vocabulary the server
mirrors, and a test pins the two together.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: O esquema de configuração — `platform` como campo, validação por plataforma, defaults, o job derivado

**Files:**
- Modify: `bin/agentloop` (`cmd_set_field` ~L8326, `cmd_create` ~L8526, `security_derived_jobs` ~L212, `cmd_selftest`, `usage`), `bin/agentloop-server` (a lista de campos de `set_field` ~L3505), `config/jobs.example.json`, `README.md` (tabela de campos de *Jobs*), `CHANGELOG.md`
- Test: `bin/agentloop selftest`; `tests/test_platforms_api.py` (um teste novo)

**Interfaces:**
- Consumes: `platform_*`, `openai_catalog_ensure`, `openai_catalog_visible` (T3, T4); `resolve`, `job_get`, `project_get`, `write_jobs`, `security_get`, `security_warn` (existentes).
- Produces: `agentloop set-field <id> platform` (`anthropic`|`openai`|vazio = herdar), com a reescrita dos três campos dependentes; `set-field model|effort|permission_mode` validados na plataforma efectiva do job; `create` com defaults por plataforma; o job derivado de segurança com `platform`; mensagens de erro que começam por `platform must be`, `unknown OpenAI model`, `effort must be one of:`, `invalid permission_mode`.

- [ ] **Step 1: Os casos do selftest, que vão falhar**

Em `cmd_selftest`, logo a seguir ao bloco `platform_finish()` de T3, inserir:

```bash
  echo "configuration — platform is a field, and model, effort and permission_mode are validated on it"
  mkdir -p "$tmp/cfg/config" "$tmp/cfg/data"
  printf '{"projects":[{"name":"oa","cwd":"/tmp","platform":"openai"}]}\n' > "$tmp/cfg/config/projects.json"
  "$JQ" -n '{resolved:{}, openai:{at:1, source:"fixture", models:[
      {slug:"gpt-a", display_name:"A", description:"", visibility:"list", priority:6, efforts:["low","high","ultra"], default_effort:"low", deprecated_by:"", retires_at:""},
      {slug:"gpt-b", display_name:"B", description:"", visibility:"list", priority:7, efforts:["low","high"], default_effort:"low", deprecated_by:"", retires_at:""}]}}' \
    > "$tmp/cfg/config/models.json"
  printf '{"jobs":[{"id":"cj","enabled":false,"cwd":"/tmp","prompt":"p","model":"opus","effort":"max","permission_mode":"dontAsk"}]}\n' \
    > "$tmp/cfg/config/jobs.json"
  cfg_al()  { AGENTLOOP_CONFIG="$tmp/cfg/config" AGENTLOOP_DATA="$tmp/cfg/data" AGENTLOOP_CODEX_BIN=/nonexistent "$BIN_DIR/agentloop" "$@"; }
  cfg_job() { "$JQ" -r --arg id "$1" ".jobs[] | select(.id==\$id) | $2" "$tmp/cfg/config/jobs.json"; }
  printf 'gemini' | cfg_al set-field cj platform >/dev/null 2>&1; want "an unknown platform is refused" 1 $?
  out="$(printf 'openai' | cfg_al set-field cj platform 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(cfg_job cj .platform)" = "openai" ] && ok "platform openai is written" || bad "platform openai: rc=$rc $out"
  [ "$(cfg_job cj .model)" = "gpt-a" ] && ok "a model the new platform does not know is rewritten to its default" || bad "model $(cfg_job cj .model)"
  [ "$(cfg_job cj '.effort // "cleared"')" = "cleared" ] && ok "an effort that model does not offer is cleared" || bad "effort $(cfg_job cj .effort)"
  [ "$(cfg_job cj .permission_mode)" = "workspace-write" ] && ok "a permission mode of the other platform is rewritten to the default" || bad "permission $(cfg_job cj .permission_mode)"
  case "$out" in *"rewritten to gpt-a"*"cleared"*"rewritten to workspace-write"*) ok "and each rewrite is printed" ;; *) bad "rewrites not printed: $out" ;; esac
  out="$(printf 'gpt-zzz' | cfg_al set-field cj model 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && case "$out" in *"unknown OpenAI model"*"gpt-a gpt-b"*"resolve-models openai"*) ok "a slug outside the catalog is refused, naming the catalog and the refresh command" ;; *) bad "refusal text: $out" ;; esac
  printf 'gpt-b' | cfg_al set-field cj model >/dev/null 2>&1; want "a catalog slug is accepted" 0 $?
  printf 'ultra' | cfg_al set-field cj effort >/dev/null 2>&1; want "ultra is refused where the model lacks it" 1 $?
  printf 'high'  | cfg_al set-field cj effort >/dev/null 2>&1; want "high is accepted" 0 $?
  printf 'dontAsk' | cfg_al set-field cj permission_mode >/dev/null 2>&1; want "an anthropic mode is refused on openai" 1 $?
  printf 'full-access' | cfg_al set-field cj permission_mode >/dev/null 2>&1; want "full-access is accepted" 0 $?
  out="$(printf 'anthropic' | cfg_al set-field cj platform 2>&1)"
  [ "$(cfg_job cj .model)" = "opus" ] && [ "$(cfg_job cj .permission_mode)" = "dontAsk" ] && [ "$(cfg_job cj .effort)" = "high" ] \
    && ok "back to anthropic: model and permission rewritten, a valid effort kept" || bad "back to anthropic: $(cfg_job cj '{model,effort,permission_mode}')"
  printf '' | cfg_al set-field cj platform >/dev/null 2>&1
  [ "$(cfg_job cj '.platform // "absent"')" = "absent" ] && ok "an empty platform clears the field (the job inherits)" || bad "platform not cleared"
  # create: the defaults follow the platform the job will run on
  printf '{"id":"oj","platform":"openai","prompt":"p"}' | cfg_al create >/dev/null 2>&1
  [ "$(cfg_job oj .platform)" = "openai" ] && [ "$(cfg_job oj .model)" = "gpt-a" ] && [ "$(cfg_job oj .permission_mode)" = "workspace-write" ] \
    && ok "create with platform openai defaults to its model and permission" || bad "create openai: $(cfg_job oj '{platform,model,permission_mode}')"
  printf '{"id":"aj","prompt":"p"}' | cfg_al create >/dev/null 2>&1
  [ "$(cfg_job aj '.platform // "absent"')" = "absent" ] && [ "$(cfg_job aj .model)" = "opus" ] && [ "$(cfg_job aj .permission_mode)" = "dontAsk" ] \
    && ok "create without a platform is anthropic, and writes no platform key" || bad "create default: $(cfg_job aj '{platform,model,permission_mode}')"
  printf '{"id":"pj","project":"oa","prompt":"p"}' | cfg_al create >/dev/null 2>&1
  [ "$(cfg_job pj '.platform // "absent"')" = "absent" ] && [ "$(cfg_job pj .model)" = "gpt-a" ] && [ "$(cfg_job pj .permission_mode)" = "workspace-write" ] \
    && ok "create under an openai project inherits the platform and takes its defaults" || bad "create under project: $(cfg_job pj '{platform,model,permission_mode}')"
  printf '{"id":"xj","platform":"openai","model":"opus","prompt":"p"}' | cfg_al create >/dev/null 2>&1; want "create refuses a model the platform does not know" 1 $?

  echo "security_derived_jobs() — the block's platform, with the same fallback-and-warn as its permission mode"
  mkdir -p "$tmp/dplat/data"
  cat > "$tmp/dplat/projects.json" <<'JSON'
{"projects":[
 {"name":"Oa","cwd":"/tmp/oa","security":{"enabled":true,"platform":"openai","model":"gpt-zzz","effort":"max","permission_mode":"dontAsk"}},
 {"name":"Ob","cwd":"/tmp/ob","platform":"openai","security":{"enabled":true,"model":"gpt-b","effort":"high"}},
 {"name":"Oc","cwd":"/tmp/oc","security":{"enabled":true,"platform":"martian"}}]}
JSON
  printf '{"jobs":[]}\n' > "$tmp/dplat/jobs.json"
  dplat() { ( JOBS_FILE="$tmp/dplat/jobs.json"; PROJECTS_FILE="$tmp/dplat/projects.json"; DATA_DIR="$tmp/dplat/data"
              MODELS_FILE="$tmp/cfg/config/models.json"; job_get "$1" "$2" '' ); }
  [ "$(dplat security-oa .platform)" = "openai" ] && ok "security.platform reaches the derived job" || bad "platform $(dplat security-oa .platform)"
  [ "$(dplat security-oa .model)" = "gpt-a" ] && ok "a model the platform does not know falls back to its default" || bad "model $(dplat security-oa .model)"
  [ "$(dplat security-oa '.effort // "cleared"')" = "cleared" ] && ok "an effort the default model lacks is cleared" || bad "effort $(dplat security-oa .effort)"
  [ "$(dplat security-oa .permission_mode)" = "full-access" ] && ok "an anthropic mode on openai falls back to full-access" || bad "permission $(dplat security-oa .permission_mode)"
  [ "$(dplat security-ob .platform)" = "openai" ] && [ "$(dplat security-ob .model)" = "gpt-b" ] && [ "$(dplat security-ob .effort)" = "high" ] && [ "$(dplat security-ob .permission_mode)" = "full-access" ] \
    && ok "the project's platform is inherited by the block, and valid values are kept" || bad "Ob: $(dplat security-ob '{platform,model,effort,permission_mode}')"
  [ "$(dplat security-oc .platform)" = "anthropic" ] && [ "$(dplat security-oc .model)" = "opus" ] && [ "$(dplat security-oc .permission_mode)" = "bypassPermissions" ] \
    && ok "an unknown platform in the block falls back to anthropic and its defaults" || bad "Oc: $(dplat security-oc '{platform,model,permission_mode}')"
```

Run: `bin/agentloop selftest 2>&1 | grep -c FAIL`
Expected: um número > 0 (os casos novos falham: `platform` é "unknown field", `gpt-b` é recusado por `model` não validar, etc.).

- [ ] **Step 2: `cmd_set_field`**

Em `cmd_set_field`, substituir o ramo `effort)` inteiro por:

```bash
    effort)
      # Empty clears it (the CLI then uses its own default). The levels are the
      # platform's -- and, on openai, the chosen model's (the catalog says).
      local p pm
      p="$(resolve "$id" platform 'anthropic')"; pm="$(resolve "$id" model "$(platform_default_model "$p")")"
      if [ -z "$value" ]; then
        write_jobs --arg id "$id" '.jobs = [.jobs[] | if .id == $id then del(.effort) else . end]'
      elif platform_effort_ok "$p" "$pm" "$value"; then
        write_jobs --arg id "$id" --arg v "$value" \
          '.jobs = [.jobs[] | if .id == $id then .effort = $v else . end]'
      else
        die "effort must be one of: $(platform_efforts "$p" "$pm" | tr '\n' ',' | sed 's/,$//; s/,/, /g') (or empty)"
      fi ;;
```

Substituir `model|active_hours|description|cwd)` por `active_hours|description|cwd)` e, antes desse ramo, inserir:

```bash
    model)
      local p
      p="$(resolve "$id" platform 'anthropic')"
      [ -n "$value" ] || die "model cannot be empty"
      if ! platform_model_ok "$p" "$value"; then
        if [ "$p" = "openai" ]; then
          openai_catalog_ensure >/dev/null 2>&1 || true      # a stale miss: refresh once, then decide
          platform_model_ok openai "$value" \
            || die "unknown OpenAI model '$value' — the catalog lists: $(openai_catalog_visible | tr '\n' ' ')(refresh with: agentloop resolve-models openai)"
        else
          die "model must be a family (opus, sonnet, haiku, fable) or a claude-* id"
        fi
      fi
      write_jobs --arg id "$id" --arg v "$value" \
        '.jobs = [.jobs[] | if .id == $id then .model = $v else . end]' ;;
    platform)
      # The other three fields have a vocabulary PER platform. Whatever the
      # job carries that the platform it is moving to does not know is
      # rewritten to that platform's default, and every rewrite is printed --
      # the editor saves platform FIRST precisely so this runs before it
      # saves the rest. Empty clears the field: the job inherits its
      # project's platform, and the rewrites are checked against THAT.
      local eff cur dm proj
      case "$value" in
        anthropic|openai) eff="$value" ;;
        "") proj="$(job_get "$id" '.project' '')"; eff="anthropic"
            if [ -n "$proj" ] && [ "$proj" != "null" ]; then eff="$(project_get "$proj" '.platform' 'anthropic')"; fi
            case "$eff" in ''|null) eff="anthropic" ;; esac ;;
        *) die "platform must be anthropic or openai (or empty, to inherit the project's)" ;;
      esac
      if [ "$eff" = "openai" ] && ! openai_catalog_ensure; then
        die "no OpenAI catalog yet: install codex, sign in, and run: agentloop resolve-models openai"
      fi
      if [ -n "$value" ]; then
        write_jobs --arg id "$id" --arg v "$value" '.jobs = [.jobs[] | if .id == $id then .platform = $v else . end]'
      else
        write_jobs --arg id "$id" '.jobs = [.jobs[] | if .id == $id then del(.platform) else . end]'
      fi
      cur="$(job_get "$id" '.model' '')"
      if [ -n "$cur" ] && [ "$cur" != "null" ] && ! platform_model_ok "$eff" "$cur"; then
        dm="$(platform_default_model "$eff")"
        write_jobs --arg id "$id" --arg v "$dm" '.jobs = [.jobs[] | if .id == $id then .model = $v else . end]'
        echo "model '$cur' is not a $eff model — rewritten to $dm"
      fi
      cur="$(job_get "$id" '.effort' '')"
      if [ -n "$cur" ] && [ "$cur" != "null" ] \
         && ! platform_effort_ok "$eff" "$(resolve "$id" model "$(platform_default_model "$eff")")" "$cur"; then
        write_jobs --arg id "$id" '.jobs = [.jobs[] | if .id == $id then del(.effort) else . end]'
        echo "effort '$cur' is not a level of that model on $eff — cleared (the CLI decides)"
      fi
      cur="$(job_get "$id" '.permission_mode' '')"
      if [ -n "$cur" ] && [ "$cur" != "null" ] && ! platform_permission_ok "$eff" "$cur"; then
        dm="$(platform_default_permission "$eff" job)"
        write_jobs --arg id "$id" --arg v "$dm" '.jobs = [.jobs[] | if .id == $id then .permission_mode = $v else . end]'
        echo "permission_mode '$cur' is not a $eff mode — rewritten to $dm"
      fi ;;
```

Substituir o ramo `permission_mode)` por:

```bash
    permission_mode)
      local p
      p="$(resolve "$id" platform 'anthropic')"
      platform_permission_ok "$p" "$value" \
        || die "invalid permission_mode for $p: $value (one of: $(platform_permissions "$p" | tr '\n' ' '))"
      write_jobs --arg id "$id" --arg v "$value" \
        '.jobs = [.jobs[] | if .id == $id then .permission_mode = $v else . end]' ;;
```

No `usage`, a linha de `set-field` ganha `platform` na lista de campos. E na secção *CLI* do README, o mesmo (a lista entre parênteses de `set-field`).

- [ ] **Step 3: `cmd_create`**

Em `cmd_create`, substituir o bloco `defaults="$("$JQ" -n --arg id "$id" --arg pc "bash $path" '{ … }')"` por:

```bash
  # The defaults follow the platform the job will run on: its own `platform`,
  # else its project's, else anthropic. The platform itself is written only
  # when the caller gave one -- a job under an openai project INHERITS it and
  # still gets a model and a permission mode that platform understands (the
  # old fixed `opus`/`dontAsk` would have been refused at its first launch).
  local cplat cproj
  cplat="$(echo "$partial" | "$JQ" -r '.platform // ""')"
  if [ -z "$cplat" ]; then
    cproj="$(echo "$partial" | "$JQ" -r '.project // ""')"
    [ -z "$cproj" ] || cplat="$(project_get "$cproj" '.platform' '')"
  fi
  case "$cplat" in ''|null) cplat="anthropic" ;; anthropic|openai) ;; *) die "create: platform must be anthropic or openai" ;; esac
  if [ "$cplat" = "openai" ] && ! openai_catalog_ensure; then
    die "create: no OpenAI catalog yet: install codex, sign in, and run: agentloop resolve-models openai"
  fi
  defaults="$("$JQ" -n --arg id "$id" --arg pc "bash $path" \
      --arg model "$(platform_default_model "$cplat")" --arg perm "$(platform_default_permission "$cplat" job)" '{
    id: $id, description: "", enabled: true,
    interval_seconds: 300, active_days: [1,2,3,4,5], active_hours: "08:00-20:00",
    precheck: $pc, model: $model, max_budget_usd: 2, stall_timeout_seconds: 1200,
    permission_mode: $perm, prompt: ""
  }')"
```

E logo a seguir a `merged="$(printf '%s\n%s\n' "$defaults" "$partial" | "$JQ" -s '.[0] * .[1]')"`, antes de `write_jobs`:

```bash
  # What the caller wrote has to be that platform's too; a job created wrong
  # would only say so at its first launch, in tick.log, hours later.
  local cm cp
  cm="$(echo "$merged" | "$JQ" -r '.model // ""')"; cp="$(echo "$merged" | "$JQ" -r '.permission_mode // ""')"
  platform_model_ok "$cplat" "$cm" || die "create: model '$cm' is not a $cplat model"
  platform_permission_ok "$cplat" "$cp" || die "create: permission_mode '$cp' is not a $cplat mode"
```

- [ ] **Step 4: `security_derived_jobs`**

Em `security_derived_jobs`, substituir o bloco que vai de `local perm` até ao `esac` de `case "$perm" in acceptEdits|…` (inclusive) por:

```bash
    # Which CLI the analysis runs on: the block's own, else the project's,
    # else anthropic. The model, effort and permission mode it carries have
    # to be that platform's, with the same fallback-and-warn the permission
    # mode already had: a value the CLI does not know falls back rather than
    # launching a run that dies at its first tool call.
    #
    # The permission default is the platform's headless-everything mode
    # (bypassPermissions / full-access), NOT dontAsk: in a headless run
    # dontAsk DENIES every tool that is not allowlisted, and a fresh worktree
    # has no allowlist, so the agent could not run a single command (the
    # first live analysis burnt $0.56 probing the walls and ended BLOCKED).
    # Containment does not come from the permission mode: the worktree is
    # disposable, the ledger only accepts writes through the CLI's validating
    # door, and AL_SECURITY_AGENT keeps the human-authority verbs shut.
    local splat smodel seffort perm
    splat="$(security_get "$project" '.platform' '')"
    [ -n "$splat" ] || splat="$(project_get "$project" '.platform' 'anthropic')"
    case "$splat" in
      anthropic|openai) : ;;
      *) security_warn "security: project '$project' names a platform the engine does not know ('$splat') -- using anthropic"
         splat="anthropic" ;;
    esac
    smodel="$(security_get "$project" '.model' "$(platform_default_model "$splat")")"
    if ! platform_model_ok "$splat" "$smodel"; then
      security_warn "security: project '$project' has a model $splat does not know ('$smodel') -- using $(platform_default_model "$splat")"
      smodel="$(platform_default_model "$splat")"
    fi
    seffort="$(security_get "$project" '.effort' '')"
    if ! platform_effort_ok "$splat" "$smodel" "$seffort"; then
      security_warn "security: project '$project' has an effort '$seffort' that $smodel does not offer on $splat -- cleared"
      seffort=""
    fi
    perm="$(security_get "$project" '.permission_mode' "$(platform_default_permission "$splat" security)")"
    if ! platform_permission_ok "$splat" "$perm"; then
      security_warn "security: project '$project' has a permission_mode the CLI does not know ('$perm') -- using $(platform_default_permission "$splat" security)"
      perm="$(platform_default_permission "$splat" security)"
    fi
```

No `"$JQ" -nc` que constrói `elem`, substituir `--arg model "$(security_get "$project" '.model' 'opus')"` por `--arg model "$smodel"`, `--arg effort "$(security_get "$project" '.effort' '')"` por `--arg effort "$seffort"`, acrescentar `--arg platform "$splat"`, e no objecto jq acrescentar `platform:$platform,` a seguir a `model:$model,`.

(O prompt da análise em OpenAI — "no subagents" em vez de "no `Agent` tool" — é do plano B2; aqui a derivação só passa a plataforma.)

- [ ] **Step 5: O servidor, o exemplo e o README**

Em `bin/agentloop-server`, na tupla de campos aceites por `set_field` (a que começa por `"interval_seconds", "active_hours", "active_days",`), acrescentar `"platform"` no fim. Em `tests/test_platforms_api.py` acrescentar:

```python
def test_the_server_lets_platform_through_set_field():
    src = (REPO / "bin" / "agentloop-server").read_text()
    allow = src[src.index('elif op == "set_field"'):][:900]
    assert '"platform"' in allow
```

Em `config/jobs.example.json`, acrescentar um segundo elemento a `jobs`:

```json
    {
      "id": "example-codex",
      "description": "Demo job on the OpenAI platform (disabled). Needs `codex login`; enable it, then `touch /tmp/agentloop-codex` to see one run.",
      "enabled": false,
      "platform": "openai",
      "cwd": "/tmp",
      "interval_seconds": 300,
      "active_days": [1, 2, 3, 4, 5, 6, 7],
      "active_hours": "",
      "precheck": "test -f /tmp/agentloop-codex",
      "model": "gpt-5.6-luna",
      "effort": "low",
      "max_budget_usd": 0.25,
      "daily_budget_usd": 1,
      "timeout_seconds": 300,
      "permission_mode": "workspace-write",
      "prompt": "Run the shell command `rm -f /tmp/agentloop-codex` to clear the trigger, then reply with one friendly line confirming agentloop can run Codex and the current date."
    }
```

No README, na tabela de campos da secção *Jobs*, inserir a seguir à linha de `project`:

```markdown
| `platform` | `anthropic` (Claude Code) or `openai` (Codex CLI); omit to inherit the project's, which defaults to `anthropic`. `model`, `effort` and `permission_mode` keep their names and take that platform's vocabulary — see **Platforms** |
```

e nas linhas de `model`, `effort` e `permission_mode` acrescentar, no fim de cada, `On `openai`: …` — respectivamente `a catalog slug (`gpt-5.6-sol`), verbatim`, `the model's own levels (up to `ultra`)`, `read-only`, `workspace-write` or `full-access``.

- [ ] **Step 6: Correr, CHANGELOG, commit**

```bash
bin/agentloop selftest 2>&1 | grep -E 'FAIL|failed'
python3.13 -m pytest -p no:cacheprovider tests/ -q --ignore=tests/security
bash test/e2e.test.sh 2>&1 | tail -3
```

Expected: `0 failed`; pytest verde; e2e `0 failed`.

Bullet do CHANGELOG:

```markdown
  - `platform` is a field on a job, on a project (its jobs inherit it) and on
    a project's `security` block. `set-field platform` rewrites a model,
    effort or permission mode the new platform does not know to that
    platform's default and says so; `set-field model|effort|permission_mode`
    validate against the job's platform (an OpenAI slug outside the catalog
    is refused, naming the catalog); `create` takes the platform's defaults,
    including under an OpenAI project. `config/jobs.example.json` carries a
    disabled OpenAI example.
```

```bash
git add bin/agentloop bin/agentloop-server tests/test_platforms_api.py config/jobs.example.json README.md CHANGELOG.md
git commit -m "feat(platforms): platform is a field, and model, effort and permission are validated on it

set-field platform rewrites what the new platform does not know and prints
each rewrite; model, effort and permission_mode are checked against the
job's effective platform; create defaults per platform, inheriting a
project's; the derived security job carries the block's platform with the
same fallback-and-warn its permission mode had.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Journal, base de dados, API de dados, hooks, e o resume na plataforma do run

**Files:**
- Modify: `bin/agentloop` (`record_run` ~L1666, `_stop_slot` ~L1605, `run_end_hook` ~L7799, `run_job` em três pontos, um `journal_platform_of_session` novo junto a `record_run`), `bin/agentloop-server` (`SCHEMA_VERSION`, `db_init`, `ingest` canon, `_upsert`, `_artifact_paths`, `load_data`, `load_run_detail`, `load_live_detail`, um `_platform_from_stream` e um `_tokens_json` novos), `test/e2e.test.sh` (cenário 13 alargado; cenários 21–22), `CHANGELOG.md`
- Create: `tests/test_platform_runs.py`
- Test: `tests/test_platform_runs.py`, `bash test/e2e.test.sh`

**Interfaces:**
- Consumes: a variável `platform` de `run_job` (T3); o `result` canónico com `cost_basis` e `tokens` (T2); `resolve`.
- Produces: `record_run … <model_id> <resumed_from> <cause> <platform> <cost_basis> <tokens-json>` (19 posicionais; os três novos com defaults `anthropic`, `reported`, `null`); cada linha de `runs.ndjson` com `platform`, `cost_basis`, `tokens`; colunas `platform`, `cost_basis`, `tokens` em `index.db`, `SCHEMA_VERSION = "6"`; `/api/data` runs com `platform` e `cost_basis`; `load_run_detail` com `record.platform`, `record.cost_basis`, `agent.tokens`, `agent.cost_basis`; `load_live_detail` com `record.platform`; hooks `AL_PLATFORM`, `AL_COST_BASIS`, `AL_TOKENS`; `journal_platform_of_session <sid>` → `anthropic`|`openai`|vazio; a recusa "this session belongs to <p>; the job now runs on <q>".

- [ ] **Step 1: O pytest, que vai falhar**

Cria `tests/test_platform_runs.py`:

```python
"""What a run records about its platform, and how the server carries it.

Three journal fields arrive with the OpenAI platform: `platform`, `cost_basis`
(reported | estimated | none) and `tokens`. The database gains them as
ADDITIVE columns (the runs table is never dropped: it holds the content of
pruned runs whose files are gone), old journal lines are backfilled, and the
raw Codex stream kept beside the normalized one is pruned with the rest.
"""
import json
import sqlite3
from pathlib import Path

OLD_CREATE = """CREATE TABLE runs (
    key TEXT PRIMARY KEY, job TEXT, start INTEGER, status TEXT,
    duration INTEGER, cost REAL, session TEXT, log TEXT, forced INTEGER,
    precheck_note TEXT, result_json TEXT, stream TEXT, precheck_txt TEXT,
    stderr TEXT, doc TEXT, project TEXT, model TEXT, model_id TEXT,
    note TEXT, resumed_from TEXT, cause TEXT, pruned INTEGER DEFAULT 0)"""


def _artifacts(srv, job, stamp, result, stream="", raw=None):
    d = srv.DATA_DIR / "logs" / job
    d.mkdir(parents=True, exist_ok=True)
    logp = d / f"{stamp}.json"
    logp.write_text(json.dumps(result))
    (d / f"{stamp}.stream.ndjson").write_text(stream)
    if raw is not None:
        (d / f"{stamp}.stream.ndjson.raw").write_text(raw)
    return logp


def _record(srv, **over):
    rec = {"id": "j1", "status": "success", "start": 1700000000, "end": 1700000100,
           "duration": 100, "cost": 0.5, "session": "s-1", "log": "/nope.json", "note": "",
           "cause": "", "forced": False, "precheck": "", "project": "", "model": "opus",
           "model_id": "claude-opus-5", "resumed_from": ""}
    rec.update(over)
    return rec


def _write_journal(srv, *recs):
    srv.RUNS_FILE.write_text("".join(json.dumps(r) + "\n" for r in recs))


def _columns(srv):
    conn = srv.db_conn()
    try:
        return [r[1] for r in conn.execute("PRAGMA table_info(runs)").fetchall()]
    finally:
        conn.close()


def test_an_old_database_gains_the_three_columns_without_losing_rows(srv, clean_data):
    conn = sqlite3.connect(str(srv.DB_FILE))
    conn.execute(OLD_CREATE)
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("INSERT INTO runs (key, job, start, status, pruned, result_json, stream)"
                 " VALUES ('j0|1|/gone.json', 'j0', 1, 'success', 1, '{\"result\":\"kept\"}', '')")
    conn.commit(); conn.close()
    _write_journal(srv, _record(srv, id="j0", start=1, log="/gone.json"))
    srv.ingest()
    cols = _columns(srv)
    assert {"platform", "cost_basis", "tokens"} <= set(cols)
    conn = srv.db_conn()
    row = conn.execute("SELECT result_json, pruned, platform FROM runs WHERE job='j0'").fetchone()
    conn.close()
    assert row["pruned"] == 1 and "kept" in row["result_json"]     # a pruned row survives the resync
    assert row["platform"] == "anthropic"


def test_a_journal_line_from_before_platforms_is_backfilled(srv, clean_data):
    logp = _artifacts(srv, "j1", "20260901T000000Z-1",
                      {"total_cost_usd": 0.5, "result": "RUN COMPLETE: ok",
                       "usage": {"input_tokens": 10, "cache_read_input_tokens": 3,
                                 "cache_creation_input_tokens": 1, "output_tokens": 4}})
    _write_journal(srv, _record(srv, log=str(logp)))
    srv.ingest()
    conn = srv.db_conn()
    row = conn.execute("SELECT platform, cost_basis, tokens FROM runs").fetchone()
    conn.close()
    assert row["platform"] == "anthropic"
    assert row["cost_basis"] == "reported"
    assert json.loads(row["tokens"]) == {"input": 10, "cached": 3, "cache_write": 1,
                                         "output": 4, "reasoning": 0}


def test_an_openai_record_keeps_its_fields_through_the_api(srv, clean_data):
    tokens = {"input": 32675, "cached": 28160, "cache_write": 0, "output": 123, "reasoning": 0}
    stream = json.dumps({"type": "system", "subtype": "init", "session_id": "thr-1",
                         "model": "gpt-5.6-sol", "platform": "openai"}) + "\n"
    logp = _artifacts(srv, "j2", "20260907T000000Z-2",
                      {"total_cost_usd": 0.031784, "cost_basis": "estimated", "tokens": tokens,
                       "result": "RUN COMPLETE: ok", "num_turns": 3, "session_id": "thr-1"},
                      stream=stream, raw='{"type":"thread.started","thread_id":"thr-1"}\n')
    _write_journal(srv, _record(srv, id="j2", log=str(logp), session="thr-1", cost=0.031784,
                                model="gpt-5.6-sol", model_id="gpt-5.6-sol", platform="openai",
                                cost_basis="estimated", tokens=tokens))
    runs = srv.load_data()["runs"]
    assert runs[0]["platform"] == "openai" and runs[0]["cost_basis"] == "estimated"
    d = srv.load_run_detail("j2", 1700000000)
    assert d["record"]["platform"] == "openai"
    assert d["record"]["cost_basis"] == "estimated"
    assert d["agent"]["tokens"] == tokens
    assert d["agent"]["cost_basis"] == "estimated"
    assert d["record"]["model_id"] == "gpt-5.6-sol"


def test_the_raw_codex_stream_is_pruned_with_the_other_artifacts(srv, clean_data):
    logp = _artifacts(srv, "j3", "20260907T000000Z-3", {"result": "x", "total_cost_usd": 0},
                      stream='{"type":"result","result":"x"}\n', raw='{"type":"turn.completed"}\n')
    raw = logp.with_name(logp.stem + ".stream.ndjson.raw")
    assert raw.exists()
    _write_journal(srv, _record(srv, id="j3", log=str(logp)))
    srv.ingest()
    assert not raw.exists() and not logp.exists()


def test_a_record_with_no_tokens_stores_null_and_none(srv, clean_data):
    logp = _artifacts(srv, "j4", "20260907T000000Z-4",
                      {"is_error": True, "subtype": "no_result_event", "result": ""})
    _write_journal(srv, _record(srv, id="j4", log=str(logp), status="error", cause="killed",
                                platform="openai", cost_basis="none", tokens=None, cost=0))
    srv.ingest()
    d = srv.load_run_detail("j4", 1700000000)
    assert d["record"]["cost_basis"] == "none"
    assert d["agent"].get("tokens") is None


def test_a_live_run_reports_its_platform_from_the_stream(srv):
    assert srv._platform_from_stream('{"type":"system","subtype":"init","platform":"openai"}\n') == "openai"
    assert srv._platform_from_stream('{"type":"system","subtype":"init","model":"claude-opus-5"}\n') == "anthropic"
    assert srv._platform_from_stream("") == "anthropic"
```

Run: `python3.13 -m pytest -p no:cacheprovider tests/test_platform_runs.py -q`
Expected: FAIL (colunas ausentes, `_platform_from_stream` inexistente, `platform` ausente em `/api/data`).

- [ ] **Step 2: O servidor**

Em `bin/agentloop-server`:

(a) `SCHEMA_VERSION = "5"   # …` → `SCHEMA_VERSION = "6"   # platform, cost_basis and tokens columns; backfill from result_json.usage`.

(b) Em `db_init`, na `CREATE TABLE IF NOT EXISTS runs (…)`, substituir `note TEXT, resumed_from TEXT, cause TEXT, pruned INTEGER DEFAULT 0)` por `note TEXT, resumed_from TEXT, cause TEXT, platform TEXT, cost_basis TEXT, tokens TEXT, pruned INTEGER DEFAULT 0)`.

(c) Em `ingest`, na lista `canon`, antes de `("pruned", "INTEGER DEFAULT 0"),` inserir:

```python
                # Which CLI ran it, how its cost is known, and its token
                # counts as JSON. Additive, like `cause` before them.
                ("platform", "TEXT"), ("cost_basis", "TEXT"), ("tokens", "TEXT"),
```

(d) Antes de `_upsert`, duas funções novas:

```python
def _tokens_json(rec, art):
    """The run's token counts as the JSON the `tokens` column stores: what the
    engine recorded, else what the stored result's `usage` says (older runs,
    and every Anthropic run before the engine recorded tokens), else ""."""
    if "tokens" in rec:                 # the engine wrote it: a dict, or null for "unknown"
        t = rec.get("tokens")
        return json.dumps(t) if isinstance(t, dict) else ""
    try:
        usage = (json.loads(art.get("result_json") or "{}") or {}).get("usage")
    except Exception:  # noqa: BLE001
        usage = None
    if not isinstance(usage, dict):
        return ""

    def n(*keys):
        for k in keys:
            v = usage.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                return int(v)
        return 0
    return json.dumps({"input": n("input_tokens"),
                       "cached": n("cache_read_input_tokens", "cache_read_tokens"),
                       "cache_write": n("cache_creation_input_tokens", "cache_write_tokens"),
                       "output": n("output_tokens"), "reasoning": n("reasoning_output_tokens")})


def _platform_from_stream(stream):
    """The platform a stream came from: the init event says `openai` for a
    normalized Codex stream; everything else is Claude Code."""
    if not stream:
        return "anthropic"
    for line in stream.splitlines()[:40]:
        line = line.strip()
        if not line or '"init"' not in line:
            continue
        try:
            ev = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            return ev.get("platform") or "anthropic"
    return "anthropic"
```

(e) Em `_upsert`, a `INSERT`: acrescentar `, platform, cost_basis, tokens` a seguir a `cause` na lista de colunas (antes de `pruned`), a linha de placeholders passa a **25** (`?` × 25; actualizar o comentário "22 columns, 22 placeholders" para 25), e na tupla de valores, a seguir a `(rec.get("cause") or "")[:40],` inserir:

```python
         rec.get("platform") or "anthropic",
         # A journal line from before cost_basis existed reported its cost
         # straight from the CLI, which is what "reported" means.
         rec.get("cost_basis") or "reported",
         _tokens_json(rec, art),
```

(f) Em `_artifact_paths`, acrescentar ao dicionário devolvido `"raw": logp.with_name(logp.stem + ".stream.ndjson.raw"),` (a cópia crua de um run OpenAI; só o prune a lê — `_read_artifacts` nomeia as suas chaves).

(g) Em `load_data`, na `SELECT`, acrescentar `, platform, cost_basis` depois de `cause`; e no dicionário de cada run, a seguir a `"cause": row["cause"] or ""`:

```python
                         "platform": row["platform"] or "anthropic",
                         "cost_basis": row["cost_basis"] or "reported",
```

(h) Em `load_run_detail`, no `rec`, a seguir a `"model": row["model"] or "", "model_id": row["model_id"] or ""`:

```python
           "platform": row["platform"] or "anthropic",
           "cost_basis": row["cost_basis"] or "reported",
```

e logo a seguir ao bloco `try: data = json.loads(row["result_json"] …) … except`, antes de `stream = row["stream"] or ""`:

```python
    try:
        detail["agent"]["tokens"] = json.loads(row["tokens"]) if row["tokens"] else None
    except Exception:  # noqa: BLE001
        detail["agent"]["tokens"] = None
    detail["agent"]["cost_basis"] = row["cost_basis"] or "reported"
```

(i) Em `load_live_detail`, no `rec`, a seguir a `"model_id": _model_id_from_stream(stream)`: `, "platform": _platform_from_stream(stream), "cost_basis": ""`.

Run: `python3.13 -m pytest -p no:cacheprovider tests/test_platform_runs.py tests/test_journal_lock.py tests/test_session_from_log.py tests/test_resume_gate.py -q`
Expected: verde.

- [ ] **Step 3: O engine — journal, hooks, `stop`**

(a) `record_run`: o cabeçalho de comentário ganha `<platform> <cost_basis> <tokens-json>`; acrescentar `--arg platform "${17:-anthropic}" --arg cost_basis "${18:-reported}" --argjson tokens "${19:-null}" \` a seguir a `--arg cause "${16:-}" \`; e no objecto jq, a seguir a `cause:$cause` (dentro do `{…}`):

```
      cause:$cause,
      # Which CLI ran it; how its cost is known (reported by the CLI,
      # estimated from tokens, or none); its token counts, or null when the
      # run died without a final event -- unknown is not zero.
      platform:$platform, cost_basis:$cost_basis, tokens:$tokens}
```

(b) A seguir a `record_run()`, inserir:

```bash
journal_platform_of_session() { # journal_platform_of_session <session-id> -> anthropic|openai, or nothing when unrecorded
  [ -s "$RUNS_FILE" ] && [ -n "${1:-}" ] || return 0
  # Compact records: `"session":"<sid>"` is one token. A record from before
  # platforms existed carries none, and is anthropic by definition.
  grep -F "\"session\":\"$1\"" "$RUNS_FILE" 2>/dev/null | tail -1 \
    | "$JQ" -r 'select(type == "object") | .platform // "anthropic"' 2>/dev/null
}
```

(c) Em `_stop_slot`, a chamada `record_run "$id" "stopped" … "${model_family:-$model}" "" ""` ganha três argumentos no fim: `"" "$(resolve "$id" platform 'anthropic')" "none" "null"` — ou seja, a linha passa a `"${model_family:-$model}" "" "" "" "$(resolve "$id" platform 'anthropic')" "none" "null"` (o 16.º, `cause`, continua vazio).

(d) Em `run_job`, a seguir a `session="$("$JQ" -r '.session_id // ""' "$logfile" …)"`, inserir:

```bash
  # How the cost is known, and the token counts. Anthropic reports dollars
  # (`reported`); the normalizer estimates them from tokens (`estimated`) or
  # says it cannot (`none`); a run that died without a final event knows
  # neither, and records null tokens rather than a zero that reads as free.
  local cost_basis tokens_json
  cost_basis="$("$JQ" -r '.cost_basis // empty' "$logfile" 2>/dev/null)"
  if [ -z "$cost_basis" ]; then
    if [ "$("$JQ" -r '.subtype // ""' "$logfile" 2>/dev/null)" = "no_result_event" ]; then cost_basis="none"
    elif [ "$platform" = "anthropic" ]; then cost_basis="reported"
    else cost_basis="none"; fi
  fi
  tokens_json="$("$JQ" -c '
    # The normalizer always writes `tokens` (an object, or null for "unknown"
    # -- a failed Codex turn reports no usage); its word is final. Only a
    # result without the key (Claude) derives the counts from `usage`.
    if has("tokens") then .tokens
    elif (.subtype // "") == "no_result_event" and (.usage.input_tokens // 0) == 0 then null
    elif (.usage | type) == "object" then
      {input:(.usage.input_tokens // 0),
       cached:(.usage.cache_read_input_tokens // .usage.cache_read_tokens // 0),
       cache_write:(.usage.cache_creation_input_tokens // .usage.cache_write_tokens // 0),
       output:(.usage.output_tokens // 0), reasoning:0}
    else null end' "$logfile" 2>/dev/null)"
  [ -n "$tokens_json" ] || tokens_json="null"
```

(e) A chamada `record_run "$id" "$status" … "$resume_sid" "$cause"` ganha `"$platform" "$cost_basis" "$tokens_json"` no fim. A linha `log_tick "$id: finished status=…"` ganha ` platform=$platform cost_basis=$cost_basis` a seguir a `forced=$forced`. A chamada `run_end_hook "$id" "$status" "${cost:-0}" "$wdreason" "$project" "$session" "$logfile" "$start" "$end"` ganha `"$platform" "$cost_basis" "$tokens_json"` no fim.

(f) Em `run_end_hook`, o comentário de cabeçalho ganha `<platform> <cost_basis> <tokens-json>`, e dentro de `_hook()`, a seguir à linha `AL_DURATION=… CC_DURATION=… \`, inserir:

```bash
      AL_PLATFORM="${10:-anthropic}" AL_COST_BASIS="${11:-reported}" AL_TOKENS="${12:-null}" \
```

(só `AL_*`: são nomes novos; a exportação dupla cobre apenas os que existiam antes da renomeação).

(g) A recusa do resume na plataforma errada. Em `run_job`, logo a seguir ao bloco de recusas de T3 (o `if [ "$platform" = "openai" ]; then … fi`), inserir:

```bash
  # A resume continues the session of the run that was cut short, on the
  # platform that run used -- read from the journal, not from the job as it
  # is now. If the job changed platform since, the session belongs to the
  # other CLI and there is nothing to continue it with.
  if [ -n "$resume_sid" ]; then
    local sess_platform
    sess_platform="$(journal_platform_of_session "$resume_sid")"
    if [ -n "$sess_platform" ] && [ "$sess_platform" != "$platform" ]; then
      log_tick "$id: refusing to resume $resume_sid — this session belongs to $sess_platform; the job now runs on $platform"
      return 1
    fi
  fi
```

- [ ] **Step 4: O e2e — o journal do run OpenAI, o hook, a recusa do resume**

Em `test/e2e.test.sh`, no bloco da plataforma OpenAI (antes do cenário 13), a seguir a `mkdir -p "$CODEX_HOME"`, semear os preços: `cp "$REPO/config/pricing.example.json" "$ROOT/config/pricing.json"`.

No cenário 13, a seguir ao `ok`/`bad` do `model_id`, acrescentar:

```bash
[ "$(lastrun | jq -r .platform)" = "openai" ] && ok "the journal names the platform" || bad "platform $(lastrun | jq -r .platform)"
[ "$(lastrun | jq -r .cost_basis)" = "estimated" ] && [ "$(lastrun | jq -r .cost)" = "0.031784" ] \
  && ok "the cost is the estimate from the seeded price table (\$0.031784 for 32,675 in / 28,160 cached / 123 out)" \
  || bad "cost $(lastrun | jq -c '{cost,cost_basis}')"
[ "$(lastrun | jq -r '.tokens.input')" = "32675" ] && [ "$(lastrun | jq -r '.tokens.reasoning')" = "0" ] \
  && ok "the token counts ride on the record" || bad "tokens $(lastrun | jq -c .tokens)"
```

Antes do bloco final, acrescentar:

```bash
echo
echo "21. the run-end hook learns the platform, the cost basis and the tokens"
mkdir -p "$ROOT/config/hooks"
printf '#!/bin/bash\nprintf "%%s %%s %%s\\n" "$AL_PLATFORM" "$AL_COST_BASIS" "$AL_TOKENS" > "%s/hook-21.out"\n' "$ROOT" > "$ROOT/config/hooks/on-run-end.sh"
chmod +x "$ROOT/config/hooks/on-run-end.sh"
mkjob_openai j21
FAKE_MODE=complete FAKE_SESSION=thr-hook "$AL" run j21 >/dev/null 2>&1
sleep 3
case "$(cat "$ROOT/hook-21.out" 2>/dev/null)" in
  "openai estimated {"*'"input":32675'*) ok "AL_PLATFORM, AL_COST_BASIS and AL_TOKENS reach the hook" ;;
  *) bad "hook saw: $(cat "$ROOT/hook-21.out" 2>/dev/null)" ;;
esac
rm -f "$ROOT/config/hooks/on-run-end.sh"

echo
echo "22. a session is resumed on the platform it ran on, or not at all"
mkjob_openai j22
FAKE_MODE=undeclared FAKE_SESSION=thr-moved "$AL" run j22 >/dev/null 2>&1
sleep 2
sed -i '' 's/"platform":"openai"/"platform":"anthropic"/; s/"gpt-5.6-sol"/"opus"/; s/"workspace-write"/"dontAsk"/; s/"effort":"high"/"effort":"low"/' "$ROOT/config/jobs.json"
"$AL" resume j22 thr-moved >/dev/null 2>&1
grep -q 'j22: refusing to resume thr-moved — this session belongs to openai; the job now runs on anthropic' "$ROOT/data/tick.log" \
  && ok "the resume is refused, naming both platforms" || bad "no refusal line for the moved job"
[ -n "$(dirs j22)" ] && ok "and the open session's tree is left where it was" || bad "the tree was taken"
```

- [ ] **Step 5: Correr tudo, CHANGELOG, commit**

```bash
bin/agentloop selftest 2>&1 | grep -E 'FAIL|failed'
python3.13 -m pytest -p no:cacheprovider tests/ -q --ignore=tests/security
bash test/e2e.test.sh 2>&1 | tail -3
```

Expected: tudo verde. Se o selftest tiver um caso que conte os argumentos de `record_run` ou leia `runs.ndjson` de um run simulado, o campo novo `platform: "anthropic"` aparece nesse registo — actualizar a asserção, não o engine.

Bullet do CHANGELOG:

```markdown
  - Every run now records `platform`, `cost_basis` and `tokens` in the
    journal and in `index.db` (additive columns; older rows are backfilled
    as anthropic/reported, with tokens from the stored result), `/api/data`
    and the run detail carry them, and `on-run-end.sh` receives
    `AL_PLATFORM`, `AL_COST_BASIS` and `AL_TOKENS`. A resume continues its
    session on the platform that run used; a job that changed platform
    since is refused with both named. The raw Codex stream is pruned with
    the run's other artifacts.
```

```bash
git add bin/agentloop bin/agentloop-server tests/test_platform_runs.py test/e2e.test.sh CHANGELOG.md
git commit -m "feat(platforms): the journal, the database and the hooks carry platform, cost basis and tokens

record_run gains three fields; index.db gains three additive columns with a
backfill; /api/data and the run detail serve them; the run-end hook sees
them; a resume runs on the platform its session ran on, or is refused.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Rate limits por plataforma — o ficheiro, a migração, o rollout como fonte, o gate e `usage`

**Files:**
- Modify: `bin/agentloop` (`rl_capture` ~L1742, `rl_gate` ~L1779, `cmd_usage` ~L1895, `platform_finish` (T3), o `rl_gate` de `run_job` ~L6910, `cmd_selftest` — os casos existentes de `rate limits`, `statusline` e `usage` e casos novos; `rl_migrate` e `rl_capture_openai` novos junto a `rl_capture`), `bin/statusline-rate-limits.sh`, `CHANGELOG.md`
- Test: `bin/agentloop selftest`, `bash test/e2e.test.sh` (cenário 13 ganha uma asserção)

**Interfaces:**
- Consumes: `PF_ROLLOUT` de `platform_finish` (T3); `test/fixtures/codex/rollout-sample.stripped.jsonl` (T1); `RATE_LIMIT_FILE`, `RL_STOP_AT`, `lock_take`/`lock_drop`, `now_epoch` (existentes).
- Produces: `data/rate-limits.json` = `{"anthropic":{"five_hour":{…},"seven_day":{…}},"openai":{"five_hour":{…,"source":"rollout","plan_type":"plus"},"seven_day":{…}}}`; `rl_migrate` (um ficheiro na forma antiga passa a `anthropic` na primeira leitura); `rl_capture` e o statusline escrevem em `.anthropic`; `rl_capture_openai <rollout> [refused]` escreve em `.openai`; `rl_gate <platform>` (sem argumento: `anthropic`); a frase do gate nomeia a plataforma: "the openai five_hour window is 96% used …"; `cmd_usage` lista as duas plataformas.

- [ ] **Step 1: Os casos do selftest — os existentes mudam de forma, e há novos**

Em `cmd_selftest`, no bloco `echo "rate limits — …"`:

(a) `rl_probe` escreve na forma antiga de propósito (é o teste da migração); manter o seu jq como está. A seguir a `gone="$(( $(now_epoch) - 3600 ))"`, inserir:

```bash
  # The file from before platforms carried the two windows at the top level.
  # It is read as anthropic and rewritten on first contact -- rl_probe above
  # still writes the OLD shape, which is exactly what makes it a migration test.
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/mig.json"
    "$JQ" -n '{five_hour:{status:"allowed",utilization:0.5,resets_at:1,overage:null,seen_at:0}}' > "$RATE_LIMIT_FILE"
    rl_migrate
    "$JQ" -e '.anthropic.five_hour.utilization == 0.5 and (has("five_hour") | not)' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "a pre-platforms file is nested under anthropic on first contact" || bad "the old shape was not migrated"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/mig2.json"
    "$JQ" -n '{anthropic:{five_hour:{utilization:0.1}},openai:{}}' > "$RATE_LIMIT_FILE"
    rl_migrate
    "$JQ" -e '.anthropic.five_hour.utilization == 0.1' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "a file already in the new shape is left alone" || bad "migration damaged a migrated file"
```

(b) No caso `rl_capture` existente, a asserção `'.seven_day.utilization == 0.98 and .seven_day.status == "allowed_warning"'` passa a `'.anthropic.seven_day.utilization == 0.98 and .anthropic.seven_day.status == "allowed_warning"'`, e a mensagem `ok` a "a window reading is lifted off the stream into the anthropic block, truncated tail and all".

(c) Todos os `rl_gate` do bloco (`rl_probe`, o `got="$( … rl_gate 2>/dev/null )"` sobre `{}`, e os do bloco statusline) continuam a chamar `rl_gate` sem argumento (= anthropic) — o `rl_probe` escreve a forma antiga, que o gate migra ao ler. As asserções de texto que dizem `the seven_day window` passam a `the anthropic seven_day window` (procurar `window is` e `window is spent` nos `case`/`grep` do bloco e acrescentar `anthropic `).

(d) A seguir aos casos de `rl_gate` existentes, inserir os do rollout:

```bash
  # The OpenAI reading comes off the rollout, not a stream: primary (300 min)
  # is the five-hour window, secondary (10080 min) the seven-day one.
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/oa.json"
    printf '%s' '{}' > "$RATE_LIMIT_FILE"
    rl_capture_openai "$BASE_DIR/test/fixtures/codex/rollout-sample.stripped.jsonl"
    "$JQ" -e '.openai.five_hour.utilization == 0.05 and .openai.five_hour.resets_at == 1788617232
              and .openai.seven_day.utilization == 0.02 and .openai.seven_day.resets_at == 1788786623
              and .openai.five_hour.source == "rollout" and .openai.five_hour.plan_type == "plus"
              and .openai.five_hour.status == "allowed"' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "the LAST token_count of the rollout feeds both openai windows" || bad "rl_capture_openai: $(cat "$tmp/rl/oa.json")"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/oa2.json"
    "$JQ" -n '{anthropic:{five_hour:{utilization:0.9,resets_at:1,seen_at:0}}}' > "$RATE_LIMIT_FILE"
    rl_capture_openai "$BASE_DIR/test/fixtures/codex/rollout-sample.stripped.jsonl"
    "$JQ" -e '.anthropic.five_hour.utilization == 0.9 and .openai.five_hour.utilization == 0.05' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "and never touches the anthropic block" || bad "the anthropic reading was lost"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/oa3.json"
    printf '%s' '{}' > "$RATE_LIMIT_FILE"
    rl_capture_openai "$BASE_DIR/test/fixtures/codex/rollout-sample.stripped.jsonl" refused
    "$JQ" -e '.openai.five_hour.status == "usage_limit_reached" and .openai.seven_day.status == "allowed"' "$RATE_LIMIT_FILE" >/dev/null ) \
    && ok "a quota refusal marks the fuller window spent until its reset" || bad "refused: $(cat "$tmp/rl/oa3.json")"
  ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/oa4.json"
    printf 'not a rollout\n' > "$tmp/rl/junk.jsonl"; printf '%s' '{}' > "$RATE_LIMIT_FILE"
    rl_capture_openai "$tmp/rl/junk.jsonl"
    [ "$(cat "$RATE_LIMIT_FILE")" = "{}" ] ) \
    && ok "a rollout with no token_count writes nothing" || bad "junk rollout changed the file"

  # The gate is per platform: one spent window must not hold the other CLI back.
  rl_at() { # rl_at <platform> <window> <utilization> <resets_at> -> rl_gate <platform-asked> output
    ( DATA_DIR="$tmp/rl"; LOCK_DIR="$tmp/rl/locks"; RATE_LIMIT_FILE="$tmp/rl/pp.json"
      "$JQ" -n --arg p "$1" --arg w "$2" --argjson u "$3" --argjson r "$4" \
        '{($p): {($w): {status:"allowed", utilization:$u, resets_at:$r, overage:null, seen_at:0}}}' > "$RATE_LIMIT_FILE"
      rl_gate "$5" 2>/dev/null )
  }
  got="$(rl_at openai five_hour 0.97 "$soon" openai)"
  case "$got" in *"the openai five_hour window is 97% used"*) ok "a spent openai window gates an openai run, and names itself" ;; *) bad "openai gate: '$got'" ;; esac
  got="$(rl_at openai five_hour 0.97 "$soon" anthropic)"
  [ -z "$got" ] && ok "and does not gate an anthropic run" || bad "cross-platform gate: $got"
  got="$(rl_at anthropic seven_day 0.98 "$soon" openai)"
  [ -z "$got" ] && ok "a spent anthropic window does not gate an openai run" || bad "cross-platform gate: $got"
  got="$(rl_at openai five_hour 0.97 "$gone" openai)"
  [ -z "$got" ] && ok "an openai window past its reset says nothing" || bad "expired openai window gated: $got"
```

(e) No bloco statusline, `sl_get '.five_hour.utilization'` e irmãos passam a `sl_get '.anthropic.five_hour.utilization'` (todos os caminhos ganham o prefixo `.anthropic`); a semente `"$JQ" -n '{five_hour:{status:"allowed_warning",…}}' > "$tmp/sl/rate-limits.json"` fica na forma antiga (prova que o script migra ao escrever) e a asserção seguinte lê `.anthropic.five_hour.overage`.

(f) No bloco `usage` (`usg()`), acrescentar depois dos casos existentes:

```bash
  case "$(usg '{}' '{"anthropic":{"five_hour":{"status":"allowed","utilization":0.3,"resets_at":'"$soon2"',"seen_at":0,"source":"statusline"}},"openai":{"five_hour":{"status":"allowed","utilization":0.05,"resets_at":'"$soon2"',"seen_at":0,"source":"rollout","plan_type":"plus"}}}')" in
    *"anthropic five_hour: 30% used"*"openai five_hour: 5% used"*"rollout"*) ok "usage lists both platforms, each window named by its platform" ;;
    *) bad "usage output did not list both platforms" ;;
  esac
```

Run: `bin/agentloop selftest 2>&1 | grep -c FAIL`
Expected: > 0.

- [ ] **Step 2: O engine**

(a) Antes de `rl_capture()`, inserir:

```bash
# data/rate-limits.json has one block per platform. Before platforms it held
# the two windows at the top level; that shape is read as anthropic and
# rewritten the first time anything touches the file, under the same lock the
# writers take. Every reader and writer below calls this first.
rl_migrate() {
  [ -s "$RATE_LIMIT_FILE" ] || return 0
  "$JQ" -e 'has("five_hour") or has("seven_day")' "$RATE_LIMIT_FILE" >/dev/null 2>&1 || return 0
  local tmp
  tmp="$(mktemp "$DATA_DIR/.rl.XXXXXX")" || return 0
  "$JQ" '{anthropic: (with_entries(select(.key == "five_hour" or .key == "seven_day")))}
         + (with_entries(select(.key != "five_hour" and .key != "seven_day")))' \
    "$RATE_LIMIT_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$RATE_LIMIT_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}
```

(b) Em `rl_capture`: a seguir a `lock_take "$lock" || return 0`, inserir `rl_migrate`; e no jq, `.[$e.rateLimitType] = {` passa a `.anthropic[$e.rateLimitType] = {`.

(c) A seguir a `rl_capture()`, inserir:

```bash
# The OpenAI reading. The Codex CLI reports both windows on EVERY turn, in
# the rollout's token_count events: primary (300 min) is the five-hour window,
# secondary (10080 min) the seven-day one, used_percent 0-100. So every OpenAI
# run feeds the gate, and there is no statusline to wire. With `refused`, the
# run ended on a quota refusal (turn.failed, "hit your usage limit"): the
# reset time is in the rollout but not which window tripped, so the FULLER
# one is marked spent until its own reset -- the gate then lifts by itself.
rl_capture_openai() { # rl_capture_openai <rollout-file> [refused]
  local roll="${1:-}" refused="${2:-}" tmp lock
  [ -s "$roll" ] || return 0
  grep -q token_count "$roll" 2>/dev/null || return 0
  lock="$LOCK_DIR/.ratelimit"
  lock_take "$lock" || return 0
  rl_migrate
  [ -s "$RATE_LIMIT_FILE" ] || echo '{}' > "$RATE_LIMIT_FILE" 2>/dev/null || { lock_drop "$lock"; return 0; }
  tmp="$(mktemp "$DATA_DIR/.rl.XXXXXX")" || { lock_drop "$lock"; return 0; }
  "$JQ" -n -R --slurpfile prev "$RATE_LIMIT_FILE" --argjson now "$(now_epoch)" --arg refused "$refused" '
    ($prev[0] // {}) as $was
    | [inputs | fromjson? | select(.type == "event_msg" and .payload.type == "token_count") | .payload.rate_limits // empty]
    | last // empty
    | . as $rl
    | (if ($rl.primary.used_percent // 0) >= ($rl.secondary.used_percent // 0) then "five_hour" else "seven_day" end) as $fuller
    | def window($w; $name):
        if $w == null then null else
          { status: (if $rl.rate_limit_reached_type != null then ($rl.rate_limit_reached_type | tostring)
                     elif $refused != "" and $name == $fuller then "usage_limit_reached"
                     else "allowed" end),
            utilization: (($w.used_percent // 0) / 100),
            resets_at: ($w.resets_at // null),
            overage: null, seen_at: $now, source: "rollout",
            plan_type: ($rl.plan_type // null) }
        end;
    $was
    | .openai = ((.openai // {})
        + (if $rl.primary   != null then {five_hour: window($rl.primary; "five_hour")} else {} end)
        + (if $rl.secondary != null then {seven_day: window($rl.secondary; "seven_day")} else {} end))
  ' "$roll" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv "$tmp" "$RATE_LIMIT_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  lock_drop "$lock"
  return 0
}
```

(d) `rl_gate` passa a receber a plataforma. Substituir o cabeçalho e as duas primeiras linhas por:

```bash
rl_gate() { # rl_gate [platform] -> 0 = hold this run back (reason on stdout); anthropic when unnamed
  local p="${1:-anthropic}"
  rl_migrate
  [ -s "$RATE_LIMIT_FILE" ] || return 1
  "$JQ" -e -r --arg p "$p" --argjson now "$(now_epoch)" --argjson stop "$RL_STOP_AT" '
    (.[$p] // {}) | to_entries
```

e nas duas frases do jq, `"the \(.key) window is spent …"` → `"the \($p) \(.key) window is spent …"` e `"the \(.key) window is \(…)% used"` → `"the \($p) \(.key) window is \(…)% used"`.

(e) Em `run_job`, `if rl_reason="$(rl_gate)" && …` → `if rl_reason="$(rl_gate "$platform")" && …`. A frase gravada em `last_rate_limit` e a linha `usage limit reached — …` já levam a razão, agora com a plataforma dentro. `fleet_stall_reason` não muda: procura `usage limit reached`, que continua a ser o prefixo.

(f) Em `platform_finish` (T3), a seguir à leitura de `PF_MODEL_ID`, acrescentar:

```bash
  # Every OpenAI run feeds the gate from its rollout. A run that ended on a
  # quota refusal (api_error_status 429 on the final event) marks the window
  # spent as well -- the classifier's `rate_limited` cause says why the run
  # failed; this says when the next one may start.
  local refused=""
  [ "$("$JQ" -r '.api_error_status // ""' "$2" 2>/dev/null | tail -1)" = "429" ] && refused="refused"
  rl_capture_openai "$PF_ROLLOUT" $refused
```

(`$2` é o streamfile: o `result` normalizado é a sua última linha; `jq -r` sobre o ficheiro inteiro dá um valor por evento, `tail -1` fica com o do `result`. Num stream sem `result` o valor é vazio.)

(g) `cmd_usage`: substituir o bloco `if [ ! -s "$RATE_LIMIT_FILE" ]; then … fi` (até ao `fi` que fecha o `if reason=…`) por:

```bash
  rl_migrate
  if [ ! -s "$RATE_LIMIT_FILE" ]; then
    echo "No usage window has been recorded yet."
  else
    local p reason
    for p in $PLATFORMS; do
      "$JQ" -r --arg p "$p" --argjson now "$now" '
        (.[$p] // {}) | to_entries[]
        | .value as $v
        | (if $v.utilization == null then "  ?" else (($v.utilization * 100) | floor | tostring) + "%" end) as $pct
        | (if $v.resets_at == null then "reset time unknown"
           elif $v.resets_at <= $now then "that window has already reset — this reading no longer counts"
           else "resets in " + (((($v.resets_at - $now) / 60) | floor) | tostring) + " min" end) as $when
        | (((($now - ($v.seen_at // 0)) / 60) | floor) | tostring) as $age
        | "\($p) \(.key): \($pct) used, \($when)"
          + "\n  read \($age) min ago from the \($v.source // "run stream")"
          + (if $v.plan_type != null then " (\($v.plan_type) plan)" else "" end)
          + (if $v.status != null then ", API said \($v.status)" else "" end)
          + (if $v.overage == "rejected" then ", overage off (the ceiling is a dead stop)" else "" end)
      ' "$RATE_LIMIT_FILE" 2>/dev/null
      if reason="$(rl_gate "$p")" && [ -n "$reason" ]; then
        echo
        echo "SCHEDULED $p RUNS ARE BEING HELD BACK: $reason"
        echo "  (\`agentloop run <job>\` still overrides this, as it does the budget.)"
      fi
    done
  fi
```

e a seguir ao bloco do statusline (no fim da função), acrescentar:

```bash
  echo "openai: fed by every run's own rollout (the Codex CLI reports both windows on every turn); nothing to wire."
```

Na verificação `"$JQ" -e 'any(.[]; .source == "statusline")' "$RATE_LIMIT_FILE"` do mesmo bloco, o caminho passa a `'any(.anthropic[]?; .source == "statusline")'`.

- [ ] **Step 3: O statusline**

Em `bin/statusline-rate-limits.sh`:

(a) A leitura `last="$("$JQ" -r '[.[].seen_at // 0] | max // 0' "$OUT" …)"` passa a `last="$("$JQ" -r '[(.anthropic // {})[]?.seen_at // 0, .[]?.seen_at // 0] | max // 0' "$OUT" …)"` (lê a forma nova e a antiga).

(b) No jq da escrita, substituir `($prev[0] // {}) as $was` por:

```
  # A file from before platforms held the windows at the top level; they are
  # the anthropic block now, and move there on this write.
  (($prev[0] // {}) | if has("five_hour") or has("seven_day")
      then {anthropic: (with_entries(select(.key == "five_hour" or .key == "seven_day")))}
           + (with_entries(select(.key != "five_hour" and .key != "seven_day")))
      else . end) as $was
```

e o `reduce` passa a operar em `.anthropic`: `reduce ["five_hour", "seven_day"][] as $w ($was;` fica, e dentro `(.[$w] // {}) as $old` → `(.anthropic[$w] // {}) as $old`, `| .[$w] = {` → `| .anthropic[$w] = {`.

- [ ] **Step 4: O e2e — o run OpenAI alimenta o gate**

No cenário 13, acrescentar:

```bash
jq -e '.openai.five_hour.utilization == 0.05 and .openai.five_hour.source == "rollout"' "$ROOT/data/rate-limits.json" >/dev/null 2>&1 \
  && ok "the run's rollout fed the openai usage windows" || bad "rate-limits.json: $(cat "$ROOT/data/rate-limits.json" 2>/dev/null)"
```

E no cenário 18 (quota):

```bash
[ "$(jq -r '.openai.five_hour.status' "$ROOT/data/rate-limits.json")" = "usage_limit_reached" ] \
  && ok "and the fuller openai window is marked spent until its reset" || bad "window status $(jq -c .openai "$ROOT/data/rate-limits.json")"
```

(o `fake-codex` escreve o rollout antes de emitir a quota, com `used_percent` 5.0/2.0 — o `five_hour` é o mais cheio.)

- [ ] **Step 5: Correr, CHANGELOG, commit**

```bash
bin/agentloop selftest 2>&1 | grep -E 'FAIL|failed'
bash test/e2e.test.sh 2>&1 | tail -3
python3.13 -m pytest -p no:cacheprovider tests/ -q --ignore=tests/security
```

Expected: tudo verde. Depois, no checkout real, `bin/agentloop usage` mostra o bloco `anthropic` migrado do ficheiro existente em `data/rate-limits.json` (o de hoje tem `five_hour`/`seven_day` no topo) e a linha `openai: fed by every run's own rollout`.

Bullet do CHANGELOG:

```markdown
  - `data/rate-limits.json` has one block per platform (a file from before
    is read as `anthropic` and rewritten on first contact). Every OpenAI run
    feeds its block from the Codex rollout — the CLI reports both windows on
    every turn, so there is no statusline to wire — and a run that ended on
    a quota refusal marks the fuller window spent until its reset. The gate
    is per platform: a spent Anthropic window never holds a Codex run back,
    nor the reverse, and `agentloop usage` lists both.
```

```bash
git add bin/agentloop bin/statusline-rate-limits.sh test/e2e.test.sh CHANGELOG.md
git commit -m "feat(platforms): the usage gate is per platform, fed by the Codex rollout

rate-limits.json nests a block per platform and migrates the old shape on
first contact; rl_capture_openai reads primary/secondary off the rollout's
last token_count; rl_gate takes the platform; usage lists both; a quota
refusal marks the fuller window spent until it resets.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Aceitação com o Codex real, e a documentação do engine

**Files:**
- Modify: `README.md` (secção nova *Platforms* entre *Effort* e *Projects*; *Requirements*, *Models*, *Effort*, *Budgets*, *Is the usage gate awake?*, *CLI*), `CHANGELOG.md`
- Nada em `bin/` muda nesta tarefa; se a aceitação encontrar um defeito, a correcção é uma commit própria, com a sua linha no CHANGELOG, antes desta.

**Interfaces:**
- Consumes: tudo o que T1–T7 produziram; o `codex` real desta máquina (`/opt/homebrew/bin/codex`, 0.148.0, sessão iniciada).

- [ ] **Step 1: Um run OpenAI real, numa configuração de rascunho, lido de ponta a ponta**

Nunca contra `config/` e `data/` reais. Tudo abaixo corre com `AGENTLOOP_CONFIG` e `AGENTLOOP_DATA` apontados a uma pasta descartável; o `CODEX_HOME` fica o real (é a conta), e é por isso que o rollout aparece em `~/.codex/sessions`.

```bash
A="${TMPDIR:-/tmp}/al-accept"; rm -rf "$A"; mkdir -p "$A/config" "$A/data" "$A/work/app"
git -C "$A/work/app" init -q
printf '{"projects":[]}\n' > "$A/config/projects.json"
cp config/pricing.example.json "$A/config/pricing.json"
cat > "$A/config/jobs.json" <<'JSON'
{"jobs":[{"id":"acc-openai","enabled":false,"platform":"openai","model":"gpt-5.6-luna","effort":"low",
  "cwd":"__CWD__","permission_mode":"workspace-write","max_budget_usd":0.5,"interval_seconds":3600,
  "prompt":"Create a file named hello.txt in the current directory containing the single word hello. Then reply with one line that starts with RUN COMPLETE: and says what you did."}]}
JSON
sed -i '' "s|__CWD__|$A/work/app|" "$A/config/jobs.json"
export AGENTLOOP_CONFIG="$A/config" AGENTLOOP_DATA="$A/data"
bin/agentloop resolve-models openai
bin/agentloop platforms | jq '.openai | {ready, reason, default_model, catalog_available}'
bin/agentloop run acc-openai; echo "rc=$?"
```

Expected: `resolve-models` imprime `openai -> gpt-5.6-sol gpt-5.6-terra … (codex debug models)`; `platforms` diz `ready: true`; o run termina em menos de um minuto com `rc=0`.

Ler, não só ver verde:

```bash
tail -5 "$A/data/tick.log"
tail -1 "$A/data/runs.ndjson" | jq '{status, cause, platform, cost, cost_basis, tokens, session, model, model_id, note}'
S="$(ls "$A"/data/logs/acc-openai/*.stream.ndjson | head -1)"
head -1 "$S" | jq -c '{subtype, session_id, model, platform, permissionMode}'
tail -1 "$S" | jq -c '{type, subtype, is_error, num_turns, cost_basis, total_cost_usd, tokens}'
wc -l "$S" "$S.raw"; head -1 "$S.raw"
wc -c "$A"/data/logs/acc-openai/*.json.err
cat "$A/work/app/hello.txt"
jq . "$A/data/rate-limits.json"
bin/agentloop usage
```

O que tem de se ler, e onde:

| Facto | Onde | Esperado |
|---|---|---|
| a linha de arranque e a de fim | `tick.log` | `starting run`, depois `finished status=success … platform=openai cost_basis=estimated … model=gpt-5.6-luna (gpt-5.6-luna)` |
| o registo | `runs.ndjson` | `platform: openai`, `cost_basis: estimated`, `cost` > 0 e < 0.01, `tokens.input` > 0, `session` = um thread id UUID, `model_id` = o modelo do rollout |
| a primeira linha do stream | `$S` | `init` com `platform: openai` e o `session_id` igual ao `session` do registo |
| a última linha | `$S` | `result`, `is_error: false`, `cost_basis: estimated`, `total_cost_usd` = `cost` do registo |
| a cópia crua | `$S.raw` | começa por `{"type":"thread.started"`; o número de linhas difere do normalizado (`turn.started` não tem tradução; um `command_execution` vira `tool_use` + `tool_result`) |
| stderr | `*.json.err` | 0 bytes: a linha do stdin foi filtrada |
| o trabalho | `hello.txt` | `hello` |
| o gate | `rate-limits.json` | bloco `openai` com `five_hour` e `seven_day`, `source: rollout`, `plan_type: plus`, `utilization` entre 0 e 1 |
| `usage` | stdout | `openai five_hour: N% used, resets in M min` e a linha `openai: fed by every run's own rollout` |

Conferir a estimativa à mão com os tokens do registo e a linha de `gpt-5.6-luna` da tabela: `((input − cached) × 0.20 + cached × 0.02 + output × 1.20) / 1 000 000` tem de dar o `cost` do registo, a seis casas.

- [ ] **Step 2: Um resume real, na mesma thread**

```bash
sed -i '' 's|Create a file named hello.txt.*RUN COMPLETE: and says what you did.|Reply with exactly the word: partial|' "$A/config/jobs.json"
bin/agentloop run acc-openai >/dev/null; T="$(tail -1 "$A/data/runs.ndjson" | jq -r .session)"; echo "thread $T"
tail -1 "$A/data/runs.ndjson" | jq '{status, note}'
bin/agentloop resume acc-openai "$T"; echo "rc=$?"
tail -1 "$A/data/runs.ndjson" | jq '{status, session, resumed_from, platform, cost_basis}'
grep -c turn_context "$(ls -t ~/.codex/sessions/*/*/*/rollout-*-"$T".jsonl | head -1)"
```

Expected: o primeiro run é `warning` com `UNDECLARED ENDING` (respondeu "partial"); o resume termina `rc=0`, o registo tem `session` = `$T`, `resumed_from` = `$T`, `platform: openai`, `cost_basis: estimated`, e o rollout dessa thread tem **dois** `turn_context` (o CLI acrescentou ao mesmo ficheiro — o contrato do resume verificado com o CLI real).

- [ ] **Step 3: A recusa que mais importa, com o CLI real**

```bash
sed -i '' 's/"gpt-5.6-luna"/"gpt-does-not-exist"/' "$A/config/jobs.json"
bin/agentloop run acc-openai; tail -1 "$A/data/tick.log"
```

Expected: nenhum run; a última linha do `tick.log` é `acc-openai: model 'gpt-does-not-exist' is not in the OpenAI catalog (run: agentloop resolve-models openai), skipped`. Nem um token gasto.

```bash
unset AGENTLOOP_CONFIG AGENTLOOP_DATA; rm -rf "$A"
```

Registar o que se leu (os valores, não "ok") no relatório da tarefa: é o que vai para a descrição do PR.

- [ ] **Step 4: README — a secção *Platforms* e as que mudam**

Em `README.md`, inserir imediatamente antes de `## Projects` (depois do `---` que fecha *Effort*):

```markdown
## Platforms

A job, a project or a project's `security` block can run on one of two
platforms. `platform` is the field; everything else keeps its name and takes
that platform's vocabulary.

| | `anthropic` (default) | `openai` |
|---|---|---|
| CLI | Claude Code, `claude -p` | Codex CLI, `codex exec --json` |
| `model` | a family (`opus`) or an id (`claude-opus-5`) | a catalog slug (`gpt-5.6-sol`), verbatim — no families |
| `effort` | `low` `medium` `high` `xhigh` `max` | the model's own levels (`gpt-5.6-sol` goes up to `ultra`) |
| `permission_mode` | `dontAsk`, `bypassPermissions`, … | `read-only`, `workspace-write`, `full-access` |
| `interactive` | yes | no — `codex exec` has no stdin protocol; the run is refused |
| `allowed_tools`, `disallowed_tools` | yes | ignored, with a line in `tick.log`: Codex cannot close a tool by flag (measured: `--disable multi_agent` leaves `spawn_agent` in the roster) |
| `max_budget_usd` | `--max-budget-usd`, stops the run | no flag: the cap is read at the end and produces the BUDGET LIMITED warning |
| cost | reported by the CLI | **estimated** from tokens with `config/pricing.json` |
| usage windows | the statusline (see `agentloop usage`) | every run's own rollout — nothing to wire |

**Choosing.** Set `"platform": "openai"` on the job, or on the project so its
jobs inherit it. `agentloop set-field <id> platform openai` rewrites a
`model`, `effort` or `permission_mode` the new platform does not know to that
platform's default and prints each rewrite; `create` takes the platform's
defaults. The OpenAI catalog comes from `codex debug models`: `agentloop
resolve-models openai` writes it into `config/models.json`, the tick
refreshes it daily, and a slug outside it is refused at launch — a
deprecated slug still runs, with its successor named in `tick.log`.

**What a run needs.** The Codex CLI installed and signed in (`codex login`);
a job whose platform is not ready is skipped before it costs a slot, with the
reason in `tick.log` (`codex is not signed in`, `codex not found at …`).
`AGENTLOOP_CODEX_BIN` overrides the binary; `CODEX_HOME` is the CLI's own
variable and picks the account and where its rollouts live.

**How a Codex run is read.** `bin/platforms/openai_stream.py` translates the
Codex event stream into the stream-json every reader here already speaks, so
the Timeline, the Terminal, the classifier and the salvage of a killed run
all work unchanged; the raw Codex stream is kept beside it as
`<run>.stream.ndjson.raw` until the run is pruned. The session id is the
Codex thread id, and a resume is `codex exec resume` on that thread — on the
platform the run used, read from the journal; a job that changed platform
since is refused with both named. The model that actually ran and the usage
windows are not on the stream: both are read from the rollout under
`$CODEX_HOME/sessions` when the run ends.

**Cost.** Codex reports tokens, never dollars. The final event carries an
estimate — `(input − cached) × input + cached × cached_input + cache_write ×
cache_write + output × output`, per million, from `config/pricing.json`
(seeded from `config/pricing.example.json` by `install.sh`; the numbers are
the OpenAI price page's as read on 2026-09-07 — check them) — and every run
records `cost_basis`: `reported` (Claude), `estimated`, or `none` when the
model has no price or the run died without a final event. The daily caps sum
estimates like any other cost; a run with `none` counts as zero and the
dashboard says so rather than showing $0.00. `output_tokens` includes
reasoning, so reasoning is reported (`tokens.reasoning`) but never billed
twice.

**Usage windows.** `data/rate-limits.json` holds one block per platform. The
Codex CLI reports both windows on every turn, so every OpenAI run feeds its
block; a run that ended on a quota refusal (`rate_limited`, outside the
failure backoff) marks the fuller window spent until its own reset. The gate
is per platform: a spent Claude window never holds a Codex run back, nor the
reverse.

**Security analyses** on OpenAI are the next release's: the block already
carries `platform`, and an analysis derived with it runs, but the prompt
still speaks of the `Agent` tool. See `docs/superpowers/plans/`.

---
```

Nas outras secções:

- *Requirements*: acrescentar à lista `- Codex CLI 0.148 or later, signed in — **optional**, for jobs on the OpenAI platform (see **Platforms**)`.
- *Models*: acrescentar no fim `On the OpenAI platform a model is a catalog slug used verbatim (`gpt-5.6-sol`); `agentloop resolve-models openai` reads the catalog from `codex debug models` into the same `config/models.json`, and `resolve-models` with no argument refreshes both platforms.`
- *Effort*: acrescentar `On OpenAI it maps to `-c model_reasoning_effort=<level>`, and the levels are the model's own (the catalog says; `gpt-5.6-sol` accepts `ultra`).`
- *Budgets*, bullet *Per-run*: acrescentar `On OpenAI there is no such flag: the cap is compared with the estimated cost when the run ends, and only warns (BUDGET LIMITED).` No parágrafo final: `Estimated costs (OpenAI) count towards the daily caps like reported ones.`
- *Is the usage gate awake?*: acrescentar um parágrafo `The statusline feeds the `anthropic` block only. The `openai` block is fed by every Codex run's rollout, so there is nothing to wire for it; `agentloop usage` lists both.`
- *CLI*: `agentloop resolve-models` → `agentloop resolve-models [anthropic|openai]  # refresh the model catalogs (both, without an argument)`; acrescentar `agentloop platforms         # what each platform offers, and whether it is ready`; na lista de `set-field` acrescentar `platform` (T5 já o fez — confirmar). Em *Environment overrides*, acrescentar `AGENTLOOP_CODEX_BIN` e `CODEX_HOME` (this one is the Codex CLI's own).

- [ ] **Step 5: CHANGELOG, commit, e o fecho do branch**

Bullet final da entrada:

```markdown
  - README: a *Platforms* section (choosing, vocabularies, what each
    platform lacks, how a Codex run is read, estimated cost and the price
    table, usage windows), and *Models*, *Effort*, *Budgets*, *usage* and
    *CLI* updated. Accepted against Codex CLI 0.148.0 with a real run, a real
    resume on the same thread and a refused slug, read end to end.
```

```bash
git add README.md CHANGELOG.md
git commit -m "docs(platforms): the README explains the OpenAI platform, and the engine is accepted against the real CLI

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Depois, `superpowers:finishing-a-development-branch`: as quatro suites verdes uma última vez no worktree, `git push -u origin feat/platforms-engine`, e o PR com a descrição a levar (1) os valores lidos na aceitação, (2) a nota **"the five prices in config/pricing.example.json were read from openai.com/api/pricing on 2026-09-07 and need the operator's confirmation"**, (3) a lista do que fica para B2 (dashboard, análise de segurança em OpenAI, `install.sh`/`status`). Rodapé do PR: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Depois do merge: `git pull --ff-only` e `bash install.sh` no checkout real (o servidor recarrega com o esquema 6 e faz o resync da base de dados; `agentloop resolve-models openai` corre no primeiro tick).

---

## Auto-revisão do plano

**Cobertura da spec (secção → tarefa).** Contexto e factos medidos → Global Constraints e T1. Tabela de plataformas → T3 (todas as doze funções; `platform_argv` é `platform_argv_openai` porque o ramo Anthropic fica intacto). Normalizador e mapeamento → T2 (com as correcções de `file_change` e `collab_tool_call`). Lançamento e fim do run → T3 (FIFO, `child`, `wait` do normalizador, filtro, `platform_finish`, resume na plataforma do run → T6). Configuração: campos, vocabulários, validação, defaults, recusas → T5 e T3; `interactive`/`allowed_tools`/`disallowed_tools` em OpenAI → T3 (ignorados com linha, por medição); `claude_config_dir` ignorado em OpenAI → já o é (só entra em `run_env`, que o Codex não lê). Catálogo e `/api/models` → T4. Custos: tabela, estimativa, `cost_basis`, tectos → T2, T6 (o tecto por run "advisory" é o classificador de hoje a ler o `cost` estimado — nada a fazer; a nota no editor é B2). Rate limits → T7. Journal, base de dados, servidor, hooks → T6. UI → **B2**. Segurança em OpenAI → T5 leva `platform` ao job derivado; prompt, skills em `~/.codex/skills` e aceitação da análise → **B2**. Skills, instalação e estado → `install.sh` semeia os preços (T2); `codex` opcional em `install.sh` e o bloco *platforms* de `status` → **B2**. Erros (tabela) → cada linha tem um cenário e2e ou um caso de selftest em T3, T5, T6, T7, excepto "normalizador termina com erro" (nota `normalizer exited N` em T3, sem cenário: o stand-in não sabe partir o normalizador; fica anotado como lacuna aceite) e "rollout não encontrado" (selftest T3). Testes (secção) → todos mapeados, menos os do contrato da página (B2). Medições em falta → T1. Fora desta versão → respeitado.

**Placeholders.** Nenhum "TBD"/"similar to"; todos os passos de código mostram o código. Os dois pontos que a execução ainda pode ter de ajustar estão nomeados como tal: a mensagem `ok` de casos existentes do selftest que ganham `anthropic ` (T7, c) e um teste que dependa de um binário `claude` inexistente (T3, passo 5).

**Consistência de nomes e assinaturas.** `platform_finish <platform> <streamfile> <session-id> [job-id]` em T3, T7 e no selftest; `PF_MODEL_ID`/`PF_ROLLOUT`; `platform_argv_openai <resume-sid> <run_cwd> <model> <effort> <permission> <prompt>` em T3 e no selftest; `record_run` com 19 posicionais em T6 (chamadas em `run_job` e `_stop_slot`); `run_end_hook` com 12; `rl_gate [platform]`; `rl_capture_openai <rollout> [refused]`; `openai_catalog_*` em T3/T4/T5; o bloco `openai` de `models.json` com `efforts`/`default_effort`/`deprecated_by`/`retires_at` (T3 semente, T4 escritor, T4 servidor, T5 testes); `cost_basis` ∈ {reported, estimated, none} em T2, T6, README; `tokens` com as cinco chaves em T2, T6, e2e 13/21.

## Entrega

Plano completo em `docs/superpowers/plans/2026-09-07-platforms-engine.md`. Duas opções de execução:

1. **Subagent-Driven (recomendado)** — um subagente novo por tarefa, revisão entre tarefas (`superpowers:subagent-driven-development`), num worktree `feat/platforms-engine`.
2. **Inline** — as oito tarefas nesta sessão, com checkpoints (`superpowers:executing-plans`).

---

## Correcções encontradas na execução (2026-09-07)

O plano foi executado no branch `feat/platforms-engine` (PR #30), uma tarefa por subagente com revisão por tarefa e revisão final de todo o branch. Onde a revisão apanhou um defeito **no código do próprio plano**, a correcção está na commit indicada e fica aqui registada para que uma re-execução não a repita. O texto das tarefas acima é o original; esta secção manda onde diverge.

**Tarefa 2 — normalizador** (fix `ff57421`, fix final `b93181f`):
- Um `item.completed{type:"error"}` é um aviso benigno do Codex (fixture 04, linha 2): é mostrado como texto `error: …` e **nunca** fica em `pending_error`; só o evento `error` de topo o faz. Caso contrário `finish()` transformava um run cortado num `error_during_execution` e roubava o salvamento do engine.
- O `result` leva sempre o conjunto completo: `api_error_status: null` no sucesso; `usage` a zeros no erro (`tokens` fica `null`).
- `turn.completed` sem `usage` **ou com `usage: {}`** → `total_cost_usd: null`, `cost_basis: "none"` (a guarda é `isinstance(usage, dict) and usage`).
- Depois de um `result`, um segundo `turn.completed`/`turn.failed` é ignorado; um booleano não é um `status`.
- Testes correspondentes em `tests/test_openai_stream.py` (24, depois 25 casos).

**Tarefa 3 — tabela de plataformas** (fix `8a03cc3`):
- As asserções do selftest **dentro de `( … )`** não movem `pass`/`fail` (locals de `cmd_selftest`): os três blocos (leitores do catálogo ×2, `platform_finish`) usam o padrão da casa — `ok`/`bad` redefinidos para `_upass`/`_ufail` dentro da subshell, linha `RESULT ok=N bad=M` no fim, o pai assere a linha exacta. Aplicar o mesmo a qualquer caso novo.
- `platform_permission_ok`, `platform_effort_ok`, `platform_model_ok` usam `grep -qxF` (um valor como `.*` passava e chegava ao lançamento sem sandbox).
- O servidor apaga `<stem>.stream.ndjson.raw` também nos dois caminhos de eliminação de um run (`delete_run`, `_forget_stranded_row`), com `tests/test_run_delete_raw.py`.
- e2e 17: a verificação de `-C` é um prefixo `data/worktrees/j17/` (o worktree já foi desmontado quando o argv é lido); e2e 20 assere também que o run com `disallowed_tools` prosseguiu (`success`).
- O comentário de `AL_PLATFORM` em `run_env`: só o processo do agente o vê (prechecks correm antes; hooks de provisioning lêem variáveis exportadas).

**Tarefa 4 — catálogo** (fix `77d2fa7`):
- `cmd_platforms` devolve para `openai` a **união dos `efforts` dos modelos visíveis** (leitor novo `openai_catalog_all_efforts`; vazio sem catálogo), não a lista fixa; o servidor calcula a mesma união só sobre os visíveis.
- `tests/test_platforms_api.py` corre o engine com `AGENTLOOP_CODEX_BIN=test/fake-codex` e `CODEX_HOME`/`AGENTLOOP_CONFIG`/`AGENTLOOP_DATA` temporários — nunca o codex nem o `~/.codex` reais.
- Um caso de selftest corre `resolve_models_openai` sobre `test/fake-codex` e pina os campos escritos (ordem dos visíveis, `default_effort`, `efforts`, `visibility`, `deprecated_by`/`retires_at`, `.resolved` preservado, `available:false` sem codex); o e2e assere o slug escondido ausente e `ultra` em `gpt-5.6-sol`.
- `resolve_models_openai` ressemeia um `models.json` que não é JSON válido e devolve 1 numa escrita falhada; `cmd_resolve_models` devolve esse rc (fix final `b93181f`). O servidor descobre o codex também em `/opt/homebrew/bin/codex` (PATH mínimo do launchd).

**Tarefa 5 — esquema de configuração** (fix `e0632ee`):
- Helper `job_platform <id>` (= `resolve` normalizado para `anthropic` quando desconhecido), usado pelos ramos `model`/`effort`/`permission_mode` do `set-field`, pelo ramo vazio de `set-field platform` e por `create`; sem ele, um projecto com `"platform":"gemini"` esvaziava `model` e `permission_mode` com rc 0.
- `project-set` recusa uma `platform` que não seja `anthropic`, `openai` ou vazia.
- `create` valida também `effort`; o job derivado sem catálogo OpenAI avisa de forma legível (nomeia `resolve-models openai`); `install.sh` diz "two disabled demo jobs, one per platform".

**Tarefa 6 — journal e servidor** (já no texto acima): o `tokens_json` do engine usa `has("tokens")` (um `tokens` presente, objecto **ou null**, é tomado como está — null é "desconhecido", nunca zero) e o `_tokens_json` do servidor usa `"tokens" in rec`. `_stop_slot` usa `job_platform` (fix final `b93181f`).

**Tarefa 7 — rate limits** (fix final `b93181f`):
- `rl_migrate` (engine e statusline) funde um ficheiro que traga **as duas formas** janela a janela, ganhando o maior `seen_at` (ausente = 0), com guarda `!= null` para nunca deixar cair uma janela; casos de selftest para as duas direcções e para o statusline.
- **O passo 5 não deve correr `bin/agentloop usage` no checkout real:** um binário por fundir não escreve nos dados vivos. A execução fê-lo e o `rate-limits.json` real ficou na forma nova enquanto o engine instalado escrevia a antiga — daí a fusão acima.

**Tarefa 8 — aceitação e README** (fixes `cca7eff`, `b93181f`):
- A receita de rascunho **não faz `git init`** no `work/app`: um cwd que é repo git liga a isolação `auto` de worktrees e, sem base, o run aborta antes do CLI (o engine já passa `--skip-git-repo-check`).
- Três frases do README descreviam B2, não este branch: o dashboard a mostrar `none` como "—" é B2; a quota só marca a janela "when the refusal's rollout still reports the windows" (um 429 real trouxe `primary`/`secondary` null); o tecto por run em OpenAI compara com o `max_budget_usd` **do próprio job**, a 90%, num run que de resto teve sucesso.
- A tabela de `on-run-end.sh` documenta `AL_PLATFORM`, `AL_COST_BASIS`, `AL_TOKENS`.

**Revisão final do branch** (fix `b93181f`): `list_models()` filtra a chave antiga `models` (e `platforms.anthropic.models`) a famílias e ids `claude-*` — um job ou run OpenAI punha `gpt-*` no selector da página actual; o e2e exporta `AGENTLOOP_CODEX_BIN`/`CODEX_HOME` no topo (três `tick` corriam antes do bloco OpenAI e o refresh diário destacado chamava o codex real).

**Deferido para B2, registado no PR #30:** o editor actual não envia `platform` e faz 500 em `set-field model` num job OpenAI (que `config/jobs.example.json` passa a semear em instalações novas) — B2 tem de aterrar antes de qualquer release, gravando `platform` antes de `model`/`effort`/`permission_mode`.
