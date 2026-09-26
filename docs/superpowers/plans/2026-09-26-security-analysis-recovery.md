# Recuperação de uma análise de segurança: plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectivo:** uma falha do ambiente deixa de queimar uma análise de
segurança, e uma análise que acabou `capped` ou `failed` retoma-se correndo
só o que desistiu.

**Arquitectura:** três camadas, de baixo para cima.

1. Os dois sweeps (o do tick, `wt_prune_orphans`, e o do orquestrador,
   `security_unit_sweep`) deixam de poder criar um ficheiro no lugar de um
   run dir e removem o ficheiro vazio que um motor anterior tenha deixado.
2. O classificador do motor passa a reconhecer uma run cujo agente nunca
   arrancou (`start_failed`), com a última linha do stderr como razão. O
   fecho da unidade mantém-lhe a tentativa, como já faz a um outage do
   provider, e o orquestrador fecha um gate quando isso se repete em várias
   linhagens: a análise fica `interrupted`, e o Resume que já existe
   continua-a.
3. Um verbo novo, `reopen` no CLI e `retry` no motor, reabre uma análise
   `capped`/`failed`: acrescenta uma unidade filha a cada linhagem que
   desistiu, corta da nota o que o fecho anterior lhe juntou, e segue pelo
   caminho do Resume. O dashboard ganha o botão **Retry failed units**.

**Stack:** bash 3.2 (`bin/agentloop`, `bin/worktree-lib.sh`), Python 3.13
(`bin/security/*.py`, `bin/agentloop-server`), JavaScript sem framework
(`ui/security/*.js`, empacotado por `build/build-ui.sh` com esbuild 0.25.0),
pytest, o selftest e o e2e em bash.

**Spec:** [2026-09-26-security-analysis-recovery-design.md](../specs/2026-09-26-security-analysis-recovery-design.md)

## Restrições globais

- Nome de um run dir: `^[0-9]{8}T[0-9]{6}Z-[0-9]+$` (`run_job`:
  `date -u +%Y%m%dT%H%M%SZ` seguido de `-$$`).
- Causa nova do classificador: `start_failed`. A nota da run é
  `START FAILED: <razão>`. A razão é a última linha não vazia do stderr do
  agente, sem códigos ANSI e com no máximo 300 caracteres; sem stderr, é
  `the agent exited <rc> with nothing on stderr`.
- Nota da unidade: `The agent could not start (<razão>); nothing ran, so the attempt is kept.`
- `LAUNCH_STRIKES = 3` e `MAX_ATTEMPTS = 3` não mudam. Novo:
  `START_FAIL_BREAKER = 3` falhas de arranque seguidas, em pelo menos 2
  linhagens diferentes.
- Frase do gate: `the agent could not start: <n> units in a row ended before a session opened (last error: <razão>)`.
- Nota de uma linhagem dada como perdida por falhas de arranque:
  `The engine could not run this unit: its agent could not start <n> times in a row (<razão>; see tick.log).`
- Retry: só a partir de `capped` ou `failed`; só a análise mais recente do
  mesmo `(project, repo, branch)`; só com pelo menos uma linhagem cuja última
  unidade está `failed`. Cada filha tem o tipo e o payload da folha,
  `attempt` 1 e `parent` = a folha. A folha continua `failed`.
- Frase do retry na nota: `Retried on <AAAA-MM-DD>: <n> unit(s) that had given up was/were run again.`
- Rótulo do botão: `Retry failed units`.
- Código, docstrings, comentários, mensagens de commit, CHANGELOG e README em
  inglês. A prosa deste plano está em pt-PT. Nenhum commit, PR ou comentário
  menciona agentes ou ferramentas (sem `Co-Authored-By`).
- Cada commit que toca `bin/`, `skills/` ou `test/` leva a sua entrada no
  `CHANGELOG.md` no mesmo commit: o selftest falha quando o CHANGELOG fica
  mais velho do que o código.
- Nenhum ficheiro versionado leva um diretório home real (o selftest
  verifica). Os caminhos de teste usam `$tmp`, `/gone/…` ou `/Users/me/…`.
- Nunca mexer no checkout instalado (o `main` em `~/projects/agentloop`), nem
  no `data/` e no `config/` reais.

## Estrutura de ficheiros

| ficheiro | o que muda |
|---|---|
| `bin/worktree-lib.sh` | `_wt_prune_one` pergunta pelo diretório depois do lock e do dono, e a adopção usa `touch -c`; `wt_is_run_dir_name` e `wt_remove_stray_file` (novos); o laço do `wt_prune_orphans` remove o ficheiro vazio que um run dir deixou |
| `bin/agentloop` | `security_unit_sweep` com a mesma verificação e a mesma limpeza; `run_start_failed` e `run_start_error` (novos); o ramo `start_failed` no bloco de causas do `run_classify`; `cmd_security_retry`, a ajuda e o dispatch |
| `bin/security/units.py` | `START_FAILED`, `KEPT_ATTEMPT_CAUSES`, `START_FAILED_NOTE`, `start_error`; o fecho sem stream mantém a tentativa de um `start_failed`; `failed_lineages`, `retry_refusal`, `retryable`, `close_part_start`, `retry_sentence` |
| `bin/security/ledger.py` | `reopen_analysis` |
| `bin/security/orchestrator.py` | `_outages_before` conta também as falhas de arranque e devolve a razão; a nota de desistência por falhas de arranque; o disjuntor (`start_fails`, `_count_start`, `START_FAIL_GATE`) |
| `bin/security/cli.py` | `cmd_reopen` e o seu parser; `reopen` em `AGENT_FORBIDDEN`; `retryable` na saída do `checklist` |
| `bin/agentloop-server` | `security_retry` e o seu dispatch |
| `bin/dashboard.html` | o objecto `AL` passa `showConfirm` à área de segurança |
| `ui/security/page.js`, `ui/security/state.js`, `ui/security/analysis.js` | o `showConfirm` na ponte; `secState.retryable`; o botão e `secRetryAnalysis` |
| `bin/static/security.js` | reconstruído por `npm run build` |
| `test/fake-opencode` | o interruptor `FAKE_OPENCODE_START_FAIL` |
| `tests/security/fixtures/fake-engine` | os modos `start-fail` e `start-fail-hunt`; `--reason` no fecho |
| `test/selftest.sh`, `test/e2e.test.sh` | os blocos novos e o cenário 58 |
| `tests/test_fake_opencode.py`, `tests/security/test_units.py`, `tests/security/test_orchestrator.py`, `tests/security/test_ledger_units.py`, `tests/security/test_finish_units.py`, `tests/test_security_api.py`, `tests/test_page_contract.py` | os testes de cada tarefa |
| `README.md`, `CHANGELOG.md` | o comportamento novo |

## Emendas à spec, decididas no planeamento

A Task 13 aplica-as à spec.

1. **A razão no `tick.log`.** A linha `finished` já acaba em `— $wdreason`,
   e a razão entra aí (`… cause=start_failed … — START FAILED: <razão>`),
   não num `reason="…"` novo.
2. **O reopen não cria um tipo de evento.** Um tipo novo obrigaria a mexer em
   `ledger.EVENT_KINDS`, no `ACTIVITY_KINDS` do servidor, no vocabulário da UI
   e nos filtros da Activity, para um facto que já fica registado em dois
   sítios: a nota da análise (`Retried on …`) e uma linha do `tick.log`.
3. **A frase do disjuntor não nomeia a plataforma**, porque o orquestrador
   não a conhece: `(last error: <razão>)`.
4. **O número de runs antes de o disjuntor fechar** é no máximo
   `paralelismo + START_FAIL_BREAKER − 1`, não o paralelismo. As vagas que as
   primeiras falhas libertam são reocupadas antes de a terceira chegar.
5. **A ordem das perguntas no sweep.** Primeiro o `wt_is_claimed`, depois o
   `-d`. O `run_cleanup` remove a árvore e só depois liberta o slot: sem
   dono, uma desmontagem que estivesse em curso já acabou, e o `-d`
   perguntado a seguir é a resposta final.

## Notas de execução (para quem implementa cada tarefa)

- Trabalha no worktree `.claude/worktrees/analysis-recovery`. Antes da Task 1,
  dá ao ramo o nome da entrega: `git branch -m fix/security-analysis-recovery`.
- O Python é o `python3.13` (em `~/.local/bin`).
- Só correm os testes que cobrem o código mexido. As quatro suítes completas
  **não** correm, e o corpo do PR di-lo.
- O selftest é uma função só e corre o e2e lá dentro. Nas tarefas em bash,
  corre-o sem o e2e (o interruptor de CI), uma vez por tarefa e nunca em
  ciclo:

  ```bash
  AGENTLOOP_SELFTEST_E2E=separate GITHUB_ACTIONS=true bash bin/agentloop selftest > "$TMPDIR/st.log" 2>&1; grep -E '^  FAIL' "$TMPDIR/st.log"; tail -3 "$TMPDIR/st.log"
  ```

  A linha que fala do e2e a correr como jobs de CI é esperada com esse
  interruptor. Qualquer outra linha `FAIL` é um problema.
- O e2e corre só a lista do cenário novo: `E2E_LISTS=4 bash test/e2e.test.sh`.
- Depois de qualquer mudança em `ui/`, corre `npm run build` e junta
  `bin/static/security.js` ao mesmo commit.
- Um commit por tarefa, em inglês, sem atribuição a agentes.

---

### Task 1: O sweep do tick nunca cria um caminho

**Files:**
- Modify: `bin/worktree-lib.sh` (`_wt_prune_one`, dentro de `wt_prune_orphans`)
- Test: `test/selftest.sh` (bloco do `wt_prune_orphans`)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: nada.
- Produces: só comportamento. A adopção passa a acontecer apenas a um
  diretório que existe e que ninguém reclama.

- [ ] **Step 1: Escrever o teste que falha**

Em `test/selftest.sh`, logo depois da linha
`rm -rf "$tmp/locks/jSweepRace" "$tmp/wtroot/jSweepRace"` (o fim do teste
«a reattach that claims first cannot be swept out from under it»), acrescentar:

```bash
  echo "wt_prune_orphans() — a run dir torn down while the sweep waited for the lock never comes back as a file"
  # Analysis 12 (2026-09-26): the sweep tested `-d` before taking
  # $LOCK_DIR/.resume, which every run_job also takes as it starts. A unit's
  # run tore its tree down and released its slot while the sweep waited, the
  # adoption branch found no marker and no owner, and its `touch` left a
  # 0-byte FILE where the run dir had been -- which OpenCode then failed every
  # boot of the project on (measurement 39). Its own worktree root, so the
  # sweep meets THIS directory first and blocks on the lock the holder has,
  # instead of blocking on another test's directory and arriving after the fact.
  local rdGone="$tmp/wtgone/jGone/stampG" goneTick="$tmp/gone.tick"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtgone"
    wt_setup jGone two "$tmp/g/repo" stampG ) >/dev/null 2>&1
  : > "$goneTick"
  (
    LOCK_DIR="$tmp/locks"; WORKTREES_DIR="$tmp/wtgone"; TICK_LOG="$goneTick"
    rlock="$LOCK_DIR/.resume"; rm -rf "$rlock"
    mkdir -p "$LOCK_DIR/jGone"
    sleep 5 & pidG=$!
    slotG="$LOCK_DIR/jGone/$pidG"; mkdir -p "$slotG"
    echo "$pidG" > "$slotG/pid"; boot_id > "$slotG/boot"; echo "$rdGone" > "$slotG/worktree"
    # The unit's own end, holding the lock the way a run_job starting beside
    # it does: the tree goes, then the slot -- run_cleanup's order.
    ( lock_take "$rlock"; sleep 0.5; wt_remove_all "$rdGone"; rm -rf "$slotG"; lock_drop "$rlock" ) \
      & holder=$!
    i=0; while [ ! -d "$rlock" ] && [ "$i" -lt 200 ]; do sleep 0.01; i=$(( i + 1 )); done
    ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"
      wt_prune_orphans ) >/dev/null 2>&1
    wait "$holder"
    kill "$pidG" 2>/dev/null; wait "$pidG" 2>/dev/null
  )
  [ ! -e "$rdGone" ] && [ ! -L "$rdGone" ] \
    && ok "nothing is left where the run dir was" \
    || bad "the sweep left a $(stat -f %HT "$rdGone" 2>/dev/null) of $(stat -f %z "$rdGone" 2>/dev/null) bytes where the run dir was"
  grep -q "adopted" "$goneTick" \
    && bad "it logged the adoption of a directory that was gone: $(cat "$goneTick")" \
    || ok "and no adoption is logged for it"
  rm -rf "$tmp/wtgone" "$tmp/locks/jGone"
```

- [ ] **Step 2: Correr e confirmar que falha**

Corre o selftest sem o e2e (ver as notas de execução). Esperado, no código
actual:

```
  FAIL  the sweep left a Regular File of 0 bytes where the run dir was
  FAIL  it logged the adoption of a directory that was gone: …
```

- [ ] **Step 3: A correcção**

Em `bin/worktree-lib.sh`, dentro de `_wt_prune_one`, substituir a linha

```bash
    wt_is_claimed "$id" "$d" && return 0
```

por

```bash
    wt_is_claimed "$id" "$d" && return 0
    # GONE WHILE THIS SWEEP WAITED FOR THE LOCK. The loop below tests `-d`
    # BEFORE taking $rlock, and every run_job takes the same lock as it
    # starts: a unit that tore its tree down and released its slot in that
    # wait reached the adoption branch below with no marker and no owner,
    # and its `touch` left a 0-byte FILE where the run dir had been
    # (analysis 12, 2026-09-26; OpenCode then failed every boot of the
    # project on that path, measurement 39). Asked AFTER the claim, never
    # before: run_cleanup removes a tree first and releases its slot last,
    # so once nothing claims $d, a teardown that was under way has finished
    # and this answer is final.
    [ -d "$d" ] || return 0
```

e, no ramo da adopção, substituir

```bash
      printf 'open\n' > "$d/.ended" 2>/dev/null || true
      touch "$d" 2>/dev/null || true
```

por

```bash
      # The braces take the redirection's own error too: a bare
      # `> file 2>/dev/null` reports a missing directory before the
      # 2>/dev/null applies, and launchd.err.log caught exactly that.
      { printf 'open\n' > "$d/.ended"; } 2>/dev/null || true
      # -c: restart the clock of a directory that exists, never create one.
      # A `touch` that CREATES is how a vanished run dir came back as a file.
      touch -c "$d" 2>/dev/null || true
```

- [ ] **Step 4: Correr e confirmar que passa**

O mesmo selftest. Esperado: `ok    nothing is left where the run dir was` e
`ok    and no adoption is logged for it`. Os testes de adopção que já
existiam continuam `ok`, incluindo «and its clock restarted», porque
`touch -c` actualiza o mtime de um diretório que existe.

- [ ] **Step 5: CHANGELOG**

Em `CHANGELOG.md`, em `## [Unreleased]`, na secção `### Fixed` (criá-la a
seguir a `### Changed` se ainda não existir), acrescentar no topo:

```markdown
- **The tick's orphan sweep can no longer leave a file where a run dir was.**
  It tested a run dir before taking the lock every `run_job` also takes as it
  starts, and a unit that tore its tree down and released its slot in that
  window was "adopted": the marker write failed, and `touch` created a 0-byte
  file at the run dir's path. OpenCode keeps every directory it boots in as a
  sandbox of the project and fails every boot on a sandbox whose parent is a
  file (measurement 39), so on a real install a deep analysis lost 231 of its
  267 verify units, three attempts each, before it closed `capped`. The sweep
  now asks whether the directory is still there once it holds the lock and
  knows nobody claims it, and an adoption only ever restarts an existing
  directory's clock (`touch -c`).
```

- [ ] **Step 6: Commit**

```bash
git add bin/worktree-lib.sh test/selftest.sh CHANGELOG.md
git commit -m "fix(worktrees): the orphan sweep never re-creates a run dir it lost to a teardown"
```

---

### Task 2: O sweep do tick remove o ficheiro que um run dir deixou

**Files:**
- Modify: `bin/worktree-lib.sh` (dois helpers novos a seguir a `wt_mtime`; o laço de `wt_prune_orphans`)
- Test: `test/selftest.sh`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `log_tick` (bin/agentloop).
- Produces:
  - `wt_is_run_dir_name <basename>`: sai com 0 quando o nome tem a forma de
    um run dir.
  - `wt_remove_stray_file <job id> <path>`: remove um ficheiro regular
    **vazio** com nome de run dir, escreve uma linha no `tick.log` e sai com
    0; sai com 1 sem tocar em nada em qualquer outro caso. A Task 3 usa os
    dois.

- [ ] **Step 1: Escrever o teste que falha**

Em `test/selftest.sh`, logo depois do bloco da Task 1
(`rm -rf "$tmp/wtgone" "$tmp/locks/jGone"`):

```bash
  echo "wt_prune_orphans() — what a vanished run dir left behind is removed, and nothing else is"
  # The 0-byte file an older engine's adoption left (Task 1) is still there
  # after an upgrade: the sweep skipped everything that was not a directory,
  # so nothing ever looked at it again, and OpenCode kept failing on it. Only
  # an EMPTY REGULAR FILE with a run dir's name can be that; the rest is not
  # the engine's.
  local strayRoot="$tmp/wtstray/jStray"
  mkdir -p "$strayRoot"
  : > "$strayRoot/20260926T005011Z-38238"                  # the file analysis 12 left
  printf 'data\n' > "$strayRoot/20260926T005012Z-38239"    # the same shape, with content
  : > "$strayRoot/notes"                                   # empty, but not a run dir's name
  : > "$strayRoot/.20260926T005011Z.tsv"                   # a scratch file
  ln -s /nonexistent "$strayRoot/20260926T005013Z-38240"   # the same shape, a symlink
  : > "$tmp/stray.tick"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtstray"
    LOCK_DIR="$tmp/locks"; TICK_LOG="$tmp/stray.tick"
    wt_prune_orphans ) >/dev/null 2>&1
  [ ! -e "$strayRoot/20260926T005011Z-38238" ] \
    && ok "an empty file with a run dir's name is removed" || bad "the stray file survived the sweep"
  grep -q "jStray: removed a stray empty file where run dir 20260926T005011Z-38238 was" "$tmp/stray.tick" \
    && ok "and tick.log says so" || bad "tick.log: $(cat "$tmp/stray.tick")"
  [ -s "$strayRoot/20260926T005012Z-38239" ] && [ -e "$strayRoot/notes" ] \
    && [ -e "$strayRoot/.20260926T005011Z.tsv" ] && [ -L "$strayRoot/20260926T005013Z-38240" ] \
    && ok "a file with content, another name, a scratch file and a symlink are all left alone" \
    || bad "the sweep removed something it did not make: $(ls -A "$strayRoot" | tr '\n' ' ')"
  rm -rf "$tmp/wtstray"
```

- [ ] **Step 2: Correr e confirmar que falha**

Selftest sem o e2e. Esperado:
`FAIL  the stray file survived the sweep` e `FAIL  tick.log: `.

- [ ] **Step 3: A implementação**

Em `bin/worktree-lib.sh`, logo a seguir à função `wt_mtime`:

```bash
# The name run_job gives a run dir: the UTC stamp and the pid of the run that
# made it (`date -u +%Y%m%dT%H%M%SZ`-$$). The `.<stamp>.tsv` scratch files
# beside them start with a dot and never match.
wt_is_run_dir_name() { # <basename>
  [[ "${1:-}" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]
}

# An EMPTY REGULAR FILE with a run dir's name can only be what is left of a
# run dir removed while something wrote to its path: the 0-byte file an
# older engine's adoption `touch` left (analysis 12, 2026-09-26), which
# OpenCode then failed every boot of the project on (measurement 39). It is
# removed, and tick.log says so. Anything else with that name -- a file with
# content, a symlink -- was not made by the engine, and is left alone
# without a word. 0 when it removed one.
wt_remove_stray_file() { # <job id> <path>
  local id="${1:-}" p="${2:-}"
  [ -f "$p" ] && [ ! -L "$p" ] && [ ! -s "$p" ] || return 1
  wt_is_run_dir_name "${p##*/}" || return 1
  rm -f "$p" 2>/dev/null || return 1
  log_tick "$id: removed a stray empty file where run dir ${p##*/} was"
}
```

No laço de `wt_prune_orphans`, substituir

```bash
      [ -d "$d" ] || continue                 # skips the .<stamp>.tsv scratch files
```

por

```bash
      if [ ! -d "$d" ]; then
        # Not a run dir. What a vanished one left behind goes; nothing else
        # is touched (the .<stamp>.tsv scratch files never match).
        wt_remove_stray_file "$id" "$d" || true
        continue
      fi
```

- [ ] **Step 4: Correr e confirmar que passa**

Selftest sem o e2e. Esperado: os três `ok` do bloco novo, e os das Tasks
anteriores continuam `ok`.

- [ ] **Step 5: CHANGELOG**

Acrescentar ao fim da entrada da Task 1:

```markdown
  A 0-byte file with a run dir's name, which an older engine could leave, is
  removed by the next sweep and named in tick.log; anything else in that
  place (a file with content, a symlink) is not the engine's and is left
  alone.
```

- [ ] **Step 6: Commit**

```bash
git add bin/worktree-lib.sh test/selftest.sh CHANGELOG.md
git commit -m "fix(worktrees): the orphan sweep removes the empty file a vanished run dir left"
```

---

### Task 3: O sweep do orquestrador pergunta da mesma maneira

**Files:**
- Modify: `bin/agentloop` (`security_unit_sweep`)
- Test: `test/selftest.sh`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `wt_remove_stray_file` (Task 2), `wt_is_claimed`, `wt_teardown`.
- Produces: só comportamento. A linha
  `swept <n> unit worktree(s) …` deixa de contar uma árvore que outra pessoa
  removeu.

- [ ] **Step 1: Escrever o teste que falha**

Em `test/selftest.sh`, imediatamente antes da linha
`echo "_stop_slot() — a live pid from an earlier boot is cleared, never signalled"`
(o fim do bloco «security_unit_sweep() — what an analysis's units left goes…»):

```bash
  echo "security_unit_sweep() — a tree torn down while it waited is not counted, and a stray file goes"
  # The same shape as wt_prune_orphans' (Task 1): the orchestrator's sweep
  # also tested `-d` before the lock. It creates nothing -- it only writes
  # INSIDE the directory -- but it counted as swept a tree the unit's own
  # cleanup had removed. And it is the sweep that runs as every analysis
  # ends, so it is where an older engine's stray file goes first.
  local usRoot="$tmp/wtus" usd="$tmp/wtus/security-gone/stampUG"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$usRoot"
    wt_setup security-gone two "$tmp/g/repo" stampUG ) >/dev/null 2>&1
  : > "$usRoot/security-gone/20260926T005011Z-38238"
  : > "$tmp/us.tick"
  (
    LOCK_DIR="$tmp/uslocks2"; WORKTREES_DIR="$usRoot"; TICK_LOG="$tmp/us.tick"
    rlock="$LOCK_DIR/.resume"; mkdir -p "$LOCK_DIR/security-gone"
    sleep 5 & pidU=$!
    slotU="$LOCK_DIR/security-gone/$pidU"; mkdir -p "$slotU"
    echo "$pidU" > "$slotU/pid"; boot_id > "$slotU/boot"; echo "$usd" > "$slotU/worktree"
    ( lock_take "$rlock"; sleep 0.5; wt_remove_all "$usd"; rm -rf "$slotU"; lock_drop "$rlock" ) \
      & holder=$!
    i=0; while [ ! -d "$rlock" ] && [ "$i" -lt 200 ]; do sleep 0.01; i=$(( i + 1 )); done
    security_unit_sweep security-gone > "$tmp/us.out" 2>&1
    wait "$holder"
    kill "$pidU" 2>/dev/null; wait "$pidU" 2>/dev/null
  )
  [ ! -e "$usd" ] && ok "nothing is left where the unit's tree was" \
    || bad "the unit sweep left a $(stat -f %HT "$usd" 2>/dev/null) where the tree was"
  grep -q "stampUG" "$tmp/us.out" \
    && bad "it counted as swept a tree it never removed: $(cat "$tmp/us.out")" \
    || ok "and it does not count a tree it never removed"
  [ ! -e "$usRoot/security-gone/20260926T005011Z-38238" ] \
    && ok "an older engine's stray file goes with the analysis's own sweep" \
    || bad "the stray file survived the unit sweep"
  grep -q "security-gone: removed a stray empty file where run dir 20260926T005011Z-38238 was" "$tmp/us.tick" \
    && ok "and tick.log says so" || bad "tick.log: $(cat "$tmp/us.tick")"
  rm -rf "$usRoot" "$tmp/uslocks2"
```

- [ ] **Step 2: Correr e confirmar que falha**

Selftest sem o e2e. Esperado: `FAIL  it counted as swept a tree it never removed: swept 1 unit worktree(s) (stampUG) …`,
`FAIL  the stray file survived the unit sweep` e `FAIL  tick.log: `.

- [ ] **Step 3: A correcção**

Em `bin/agentloop`, em `security_unit_sweep`, substituir o laço das árvores

```bash
    for d in "$WORKTREES_DIR/$jid"/*; do
      [ -d "$d" ] || continue              # skips the .<stamp>.tsv scratch files
      lock_take "$rlock"
      if ! wt_is_claimed "$jid" "$d"; then
        printf 'done\n' > "$d/.ended" 2>/dev/null || true
        wt_teardown "$jid" "" "$d"
        [ -d "$d" ] || trees="$trees ${d##*/}"
      fi
      lock_drop "$rlock"
    done
```

por

```bash
    for d in "$WORKTREES_DIR/$jid"/*; do
      if [ ! -d "$d" ]; then
        # What a vanished run dir left behind goes (wt_remove_stray_file);
        # the .<stamp>.tsv scratch files never match.
        wt_remove_stray_file "$jid" "$d" || true
        continue
      fi
      lock_take "$rlock"
      # Claimed first, then asked whether it is still here -- the order
      # wt_prune_orphans follows, for the same reason: run_cleanup removes a
      # unit's tree before it releases the slot, so a tree whose unit tore it
      # down while this waited for the lock is simply gone, not swept.
      if ! wt_is_claimed "$jid" "$d" && [ -d "$d" ]; then
        { printf 'done\n' > "$d/.ended"; } 2>/dev/null || true
        wt_teardown "$jid" "" "$d"
        [ -d "$d" ] || trees="$trees ${d##*/}"
      fi
      lock_drop "$rlock"
    done
```

- [ ] **Step 4: Correr e confirmar que passa**

Selftest sem o e2e. Esperado: os quatro `ok` do bloco novo. O bloco
«security_unit_sweep() — what an analysis's units left goes…» continua
todo `ok`.

- [ ] **Step 5: CHANGELOG**

Acrescentar ao fim da entrada da Task 1:

```markdown
  The orchestrator's own sweep (`__unit-sweep`, run as every analysis ends)
  asks the same way, removes the same stray file, and no longer reports as
  swept a tree a unit had already removed.
```

- [ ] **Step 6: Commit**

```bash
git add bin/agentloop test/selftest.sh CHANGELOG.md
git commit -m "fix(security): the unit sweep asks after its lock and heals a stray run dir file"
```

---

### Task 4: O `fake-opencode` sabe falhar ao arrancar

**Files:**
- Modify: `test/fake-opencode`
- Test: `tests/test_fake_opencode.py`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: `FAKE_OPENCODE_START_FAIL=<linha>`. Com ele, um `run` escreve no
  stderr `Error: Unexpected error` (com as cores do CLI real), uma linha em
  branco e `<linha>`, não escreve nada no stdout e sai com 1. A Task 5 usa-o.

- [ ] **Step 1: Escrever o teste que falha**

Em `tests/test_fake_opencode.py`, no fim do ficheiro:

```python
def test_a_start_failure_writes_nothing_and_names_the_cause_on_stderr(tmp_path):
    """measurement 39: a project whose sandbox list names a path under a
    regular file fails EVERY boot before a session exists -- rc 1, nothing
    on stdout, and the cause on stderr after a coloured "Error: Unexpected
    error" and a blank line."""
    p = run(["run", "--format", "json", "--dir", str(tmp_path), "--", "do the thing"],
            env={"FAKE_OPENCODE_START_FAIL": "BadResource: FileSystem.access (/gone/run/repo)"})
    assert p.returncode == 1
    assert p.stdout == ""
    lines = p.stderr.splitlines()
    assert "Unexpected error" in lines[0]
    assert lines[1] == ""
    assert lines[-1] == "BadResource: FileSystem.access (/gone/run/repo)"
```

- [ ] **Step 2: Correr e confirmar que falha**

```bash
python3.13 -m pytest tests/test_fake_opencode.py -k start_failure -p no:cacheprovider -q
```

Esperado: FAIL (o stand-in corre a sessão completa e sai com 0).

- [ ] **Step 3: A implementação**

Em `test/fake-opencode`, no cabeçalho, a seguir à linha do
`FAKE_OPENCODE_NO_MODELS`, acrescentar:

```bash
#   FAKE_OPENCODE_START_FAIL  a `run` fails to start, as measurement 39's does: nothing on stdout,
#                           "Error: Unexpected error", a blank line and this value on stderr, rc 1
```

E logo depois do bloco que faz `cd "$dir"` (o que termina em
`fi` depois de «Failed to change directory»), acrescentar:

```bash
# measurement 39: a project whose sandbox list names a path under a regular
# file fails EVERY boot before a session exists -- rc 1, nothing on stdout,
# and the cause on stderr after a coloured "Error: Unexpected error" and a
# blank line.
if [ -n "${FAKE_OPENCODE_START_FAIL:-}" ]; then
  printf '\033[91m\033[1mError: \033[0mUnexpected error\n\n%s\n' "$FAKE_OPENCODE_START_FAIL" >&2
  exit 1
fi
```

- [ ] **Step 4: Correr e confirmar que passa**

O mesmo comando. Esperado: `1 passed`. Depois, o ficheiro inteiro:
`python3.13 -m pytest tests/test_fake_opencode.py -p no:cacheprovider -q`,
todos a passar.

- [ ] **Step 5: CHANGELOG**

Em `## [Unreleased]`, `### Added`, no topo:

```markdown
- **A run whose agent never started says so, and says why.** An agent CLI
  that exits non-zero before its stream holds a single event or a session is
  bound (OpenCode does exactly that for every boot of a project whose
  sandbox list names a path under a file, measurement 39) is recorded
  `error` / `start_failed` instead of `killed`, and its note carries the
  CLI's own last stderr line. On a real install 693 such runs were filed as
  kills that never happened, with the cause left unread in each run's
  stderr. `test/fake-opencode` plays it with `FAKE_OPENCODE_START_FAIL`.
```

- [ ] **Step 6: Commit**

```bash
git add test/fake-opencode tests/test_fake_opencode.py CHANGELOG.md
git commit -m "test(opencode): the stand-in can fail to start the way measurement 39 did"
```

---

### Task 5: O classificador reconhece uma run cujo agente nunca arrancou

**Files:**
- Modify: `bin/agentloop` (`run_start_failed` e `run_start_error` novos, imediatamente antes do comentário que abre `run_classify`; o bloco de causas do `run_classify`)
- Test: `test/selftest.sh` (o harness `cause_of`, um bloco novo, e um bloco `run_cleanup`), `test/e2e.test.sh` (cenário 58)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `FAKE_OPENCODE_START_FAIL` (Task 4).
- Produces:
  - `run_start_failed`: lê do âmbito do `run_classify` `rc`, `wdreason`,
    `slot`, `streamfile` e `run_dir`; sai com 0 quando a run é uma falha de
    arranque.
  - `run_start_error`: lê `logfile` e `rc` e imprime a razão.
  - `cause="start_failed"` e `wdreason="START FAILED: <razão>"`, que chegam
    ao `unit-close` como `--cause start_failed --reason "START FAILED: <razão>"`
    (`security_close_analysis` já passa os dois). A Task 6 lê-os.

- [ ] **Step 1: Alargar o harness `cause_of` e escrever o teste que falha**

Em `test/selftest.sh`, no harness `cause_of` do bloco «failure causes — an
outage is not the job's fault…», trocar `| head -20)"` por `| head -30)"`
na linha do `eval`. O ramo novo acrescenta três linhas ao bloco extraído, e
com 20 o `fi` final ficaria de fora.

Depois, a seguir ao teste «an API failure outranks a denial count on the
same run», acrescentar:

```bash
  echo "failure causes — an agent that never started is start_failed, and its stderr says why"
  # Analysis 12 (2026-09-26): OpenCode failed every boot of the project
  # (measurement 39) and all 693 runs were filed `killed`, the cause left
  # unread in each run's stderr. The same derivation, lifted by the same
  # anchor as cause_of, with the run's own files around it.
  mkdir -p "$tmp/startf"
  start_cause_of() { # <stderr, printf %b> [rc] [stream text] [session] [stopped] [wdreason] -> "<cause>|<note>"
    printf '%s' '{"subtype":"no_result_event"}' > "$tmp/startf/log.json"
    printf '%b' "$1" > "$tmp/startf/log.json.err"
    printf '%s' "${3:-}" > "$tmp/startf/stream.ndjson"
    rm -rf "$tmp/startf/run" "$tmp/startf/slot"; mkdir -p "$tmp/startf/run" "$tmp/startf/slot"
    [ -z "${4:-}" ] || printf '%s\n' "$4" > "$tmp/startf/run/.session"
    [ -z "${5:-}" ] || : > "$tmp/startf/slot/stopped"
    ( logfile="$tmp/startf/log.json"; status="error"; denials=0; wdreason="${6:-}"
      rc="${2:-1}"; streamfile="$tmp/startf/stream.ndjson"; run_dir="$tmp/startf/run"
      slot="$tmp/startf/slot"
      subtype="$("$JQ" -r '.subtype // "success"' "$logfile")"
      cause=""
      eval "$(sed -n '/^  cause=""$/,/^  fi$/p' "$BIN_DIR/agentloop" | head -30)"
      printf '%s|%s' "$cause" "$wdreason" )
  }
  got="$(start_cause_of '\033[91m\033[1mError: \033[0mUnexpected error\n\nBadResource: FileSystem.access (/gone/run/repo)\n')"
  [ "$got" = "start_failed|START FAILED: BadResource: FileSystem.access (/gone/run/repo)" ] \
    && ok "an agent that exits 1 before its first event is start_failed, named by its last stderr line" \
    || bad "start failure -> '$got'"
  got="$(start_cause_of '')"
  [ "$got" = "start_failed|START FAILED: the agent exited 1 with nothing on stderr" ] \
    && ok "with nothing on stderr, the note says so" || bad "silent start failure -> '$got'"
  got="$(start_cause_of "$(printf 'x%.0s' $(seq 1 400))\n")"
  local sfprefix="start_failed|START FAILED: "
  [ "${#got}" -eq $(( ${#sfprefix} + 300 )) ] \
    && ok "and the line is cut at 300 characters" || bad "long line -> ${#got} characters"
  [ "$(start_cause_of 'boom\n' 1 '{"type":"step_start"}')" = "killed|" ] \
    && ok "a run whose stream holds an event did start: killed, as before" \
    || bad "stream with an event -> '$(start_cause_of 'boom\n' 1 '{"type":"step_start"}')'"
  [ "$(start_cause_of 'boom\n' 1 '' ses_x)" = "killed|" ] \
    && ok "a bound session means it started" || bad "bound session -> '$(start_cause_of 'boom\n' 1 '' ses_x)'"
  [ "$(start_cause_of 'boom\n' 1 '' '' stopped)" = "killed|" ] \
    && ok "a stopped run is the stop's to name" || bad "stopped -> '$(start_cause_of 'boom\n' 1 '' '' stopped)'"
  [ "$(start_cause_of 'boom\n' 1 '' '' '' 'WATCHDOG: stalled')" = "killed|WATCHDOG: stalled" ] \
    && ok "the watchdog's ending stays killed" \
    || bad "watchdog -> '$(start_cause_of 'boom\n' 1 '' '' '' 'WATCHDOG: stalled')'"
  [ "$(start_cause_of 'boom\n' 0)" = "killed|" ] \
    && ok "an agent that exited 0 did not fail to start" || bad "rc 0 -> '$(start_cause_of 'boom\n' 0)'"
```

A linha do corte a 300 compara o tamanho: o prefixo
`start_failed|START FAILED: ` (27 caracteres) mais 300.

- [ ] **Step 2: Correr e confirmar que falha**

Selftest sem o e2e. Esperado: `FAIL  start failure -> 'killed|'`,
`FAIL  silent start failure -> 'killed|'` e `FAIL  long line -> …`. Os
controlos (`killed`) passam já.

- [ ] **Step 3: A implementação**

Em `bin/agentloop`, imediatamente antes do comentário
`# run_classify -> the verdict, from everything the run left behind.`:

```bash
# A RUN WHOSE AGENT NEVER STARTED: it exited on its own, non-zero, before
# its stream held a single event or a session was bound -- no stop, no
# watchdog, no normalizer to blame. OpenCode 1.18.30 does exactly this for
# every boot of a project whose sandbox list names a path under a regular
# file (measurement 39), and the classifier called all 693 such runs of
# analysis 12 `killed` -- a kill that never happened -- while the cause sat
# unread in each run's stderr. Reads run_classify's scope: rc, wdreason,
# slot, streamfile, run_dir.
run_start_failed() {
  [ "${rc:-0}" -ne 0 ] || return 1
  [ -z "${wdreason:-}" ] || return 1
  if [ -n "${slot:-}" ] && [ -f "$slot/stopped" ]; then return 1; fi
  if [ -n "${streamfile:-}" ] && [ -s "$streamfile" ]; then return 1; fi
  if [ -n "${run_dir:-}" ] && [ -s "$run_dir/.session" ]; then return 1; fi
  return 0
}

# What such an agent said as it went: the LAST non-empty line of its stderr,
# colour codes dropped, at most 300 characters. OpenCode prints "Error:
# Unexpected error", a blank line, then the cause -- so the last line is the
# one that names it. Reads run_classify's scope: logfile, rc.
run_start_error() {
  local esc line
  esc="$(printf '\033')"
  line="$(sed "s/${esc}\[[0-9;]*m//g" "$logfile.err" 2>/dev/null \
            | awk 'NF { l = $0 } END { print l }' \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-300)"
  printf '%s' "${line:-the agent exited ${rc:-?} with nothing on stderr}"
}
```

No bloco de causas do `run_classify`, substituir

```bash
    elif [ "${denials:-0}" -gt 0 ]; then
      cause="tools_denied"
    elif [ "$subtype" = "no_result_event" ]; then
```

por

```bash
    elif [ "${denials:-0}" -gt 0 ]; then
      cause="tools_denied"
    elif run_start_failed; then
      cause="start_failed"
      wdreason="START FAILED: $(run_start_error)"
    elif [ "$subtype" = "no_result_event" ]; then
```

Nada mais muda no classificador. Os passos seguintes (`NOTHING TO DO`,
`UNDECLARED ENDING`, a nota do orçamento, o trabalho não entregue) só mexem
no `wdreason` de uma run `success`/`warning`, ou quando `_no_result` é
falso. O override do stop vem depois e continua a mandar, mas
`run_start_failed` já recusa uma run parada. A linha `finished` do
`tick.log` já acaba em `— $wdreason`, e o `record_run` guarda o `wdreason`
como a `note` da run.

- [ ] **Step 4: Correr e confirmar que passa**

Selftest sem o e2e. Esperado: todos os `ok` do bloco novo, e os do
`cause_of` antigo continuam `ok` (com `rc` por definir, `run_start_failed`
responde que não).

- [ ] **Step 5: Fixar que uma unidade terminada em erro não deixa árvore**

Em `test/selftest.sh`, imediatamente antes da linha
`echo "run_cleanup() — a re-issued stop cannot kill the cleanup halfway (the slot of analysis 22)"`,
acrescentar:

```bash
  echo "run_cleanup() — a unit whose agent never started goes the same way, once its close has landed"
  # The error path, which the stop tests above do not take: each of
  # analysis 12's 693 start failures left a 371 MB tree behind (an engine
  # from before a unit kept nothing). A unit's close lands for an error
  # exactly as for a stop (RJ_UNIT_CLOSED), and then its tree goes.
  local urd4="$tmp/wtroot/security-app/stampU4" usl4="$tmp/uslocks/security-app/994"
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    wt_setup security-app two "$tmp/g/repo" stampU4 ) >/dev/null 2>&1
  mkdir -p "$usl4"
  echo 994 > "$usl4/pid"; echo 1700000000 > "$usl4/start"; echo "$urd4" > "$usl4/worktree"
  echo "$tmp/uclogs/security-app/20260925T100004Z-994.json" > "$usl4/logfile"
  echo 12349 > "$usl4/child"                 # an agent was spawned, and ended on its own: no stop
  ( PROJECTS_FILE="$tmp/proj/two.json"; CONFIG_DIR="$tmp/cfg"; WORKTREES_DIR="$tmp/wtroot"
    LOCK_DIR="$tmp/uslocks"; DATA_DIR="$tmp"; RUNS_FILE="$tmp/uc.ndjson"; STATE_FILE="$tmp/ucstate.json"
    LOG_DIR="$tmp/uclogs"; TICK_LOG="$tmp/uc.tick"
    AL_SECURITY_ANALYSIS_ID=41 AL_SECURITY_UNIT_ID=14 RJ_UNIT_CLOSED=1
    run_cleanup security-app "$usl4" ) >/dev/null 2>&1
  [ ! -d "$urd4" ] && ok "its tree is torn down, not kept open for a resume" \
    || bad "an error-ended unit's tree survived its run"
  [ ! -d "$usl4" ] && ok "and its slot is released" || bad "the error-ended unit's slot survived"
```

Corre o selftest sem o e2e. Este bloco passa sem mudança de código: fixa
um comportamento que já existe, no caminho que o incidente tomou.

- [ ] **Step 6: O cenário e2e 58**

Em `test/e2e.test.sh`, depois do fim do `scenario_57` (a linha `}` a seguir
ao seu `echo`), acrescentar:

```bash
scenario_58() {
echo "58. an OpenCode run that dies before its first event is start_failed, and its note says why"
# measurement 39: a project whose sandbox list names a path under a regular
# file fails every OpenCode boot before a session exists. Analysis 12
# (2026-09-26) filed 693 of them as `killed`.
mkjob_opencode j58
FAKE_OPENCODE_START_FAIL="BadResource: FileSystem.access (/gone/run/repo)" "$AL" run j58 >/dev/null 2>&1
sleep 1
[ "$(lastrun | jq -r .status)" = "error" ] && [ "$(lastrun | jq -r .cause)" = "start_failed" ] \
  && ok "error / start_failed, not killed" || bad "$(lastrun | jq -c '{status,cause}')"
case "$(lastrun | jq -r .note)" in
  *"START FAILED: BadResource: FileSystem.access (/gone/run/repo)"*) ok "the note carries the CLI's own last stderr line" ;;
  *) bad "note: $(lastrun | jq -r .note)" ;;
esac
grep -q "j58: finished status=error cause=start_failed .*START FAILED: BadResource" "$ROOT/data/tick.log" \
  && ok "and so does tick.log" || bad "no start_failed line in tick.log"

echo
}
```

E registar o cenário: acrescentar ` 58` ao fim de `E2E_ALL` e de
`E2E_LIST_4`.

Corre `E2E_LISTS=4 bash test/e2e.test.sh`. Esperado: os três `ok` do 58, e
os cenários 47 a 57 continuam verdes.

- [ ] **Step 7: CHANGELOG**

A entrada da Task 4 já descreve este comportamento. Confirma que ela diz
que o `tick.log` e a `note` levam a razão (é o que esta tarefa entrega).
Acrescenta, no fim dessa entrada:

```markdown
  The run's note and its tick.log line read `START FAILED: <the line>`.
```

- [ ] **Step 8: Commit**

```bash
git add bin/agentloop test/selftest.sh test/e2e.test.sh CHANGELOG.md
git commit -m "fix(engine): a run whose agent never started is start_failed, named by its stderr"
```

---

### Task 6: O fecho da unidade mantém a tentativa de uma falha de arranque

**Files:**
- Modify: `bin/security/units.py` (constantes a seguir a `OUTAGE_CAUSES`, `start_error`, o ramo sem stream de `close`)
- Test: `tests/security/test_units.py`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `--cause start_failed` e `--reason "START FAILED: <razão>"` (Task 5).
- Produces:
  - `units.START_FAILED = "start_failed"`
  - `units.KEPT_ATTEMPT_CAUSES = OUTAGE_CAUSES + (START_FAILED,)`
  - `units.START_FAILED_NOTE` (com `{error}`)
  - `units.start_error(reason) -> str`
  - Evidência de uma unidade fechada assim:
    `{"stream": "none", "guides": [], "cause": "start_failed", "error": "<razão>"}`
    (mais `ranges`/`covered` numa `read`). A Task 7 lê `cause` e `error`.

- [ ] **Step 1: Escrever os testes que falham**

Em `tests/security/test_units.py`, no fim:

```python
def test_a_run_whose_agent_never_started_keeps_its_attempt_and_names_the_error(conn):
    """Analysis 12 (2026-09-26): OpenCode failed every boot of the project,
    and each run spent one of its unit's three attempts. Nothing ran, so
    nothing is the unit's fault: the close keeps the attempt, as it does for
    a provider outage, and the unit's note carries the agent's own words."""
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    ledger.start_unit(conn, uid)
    out = units.close(conn, ledger.get_unit(conn, uid), status="error", cause=units.START_FAILED,
                      reason="START FAILED: BadResource: FileSystem.access (/gone/repo)")
    assert out["state"] == "incomplete"
    unit = ledger.get_unit(conn, uid)
    assert unit["evidence"]["cause"] == "start_failed"
    assert unit["evidence"]["error"] == "BadResource: FileSystem.access (/gone/repo)"
    assert unit["note"] == ("The agent could not start (BadResource: FileSystem.access (/gone/repo)); "
                            "nothing ran, so the attempt is kept.")
    assert ledger.get_unit(conn, out["continuation"])["attempt"] == 1


def test_a_run_killed_with_no_stream_still_spends_its_attempt(conn):
    """The control: only the causes that are nobody's fault keep it."""
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    ledger.start_unit(conn, uid)
    out = units.close(conn, ledger.get_unit(conn, uid), status="error", cause="killed")
    assert ledger.get_unit(conn, out["continuation"])["attempt"] == 2
    assert "cause" not in ledger.get_unit(conn, uid)["evidence"]


def test_the_start_error_is_the_agents_words_without_the_engines_prefix():
    assert units.start_error("START FAILED: BadResource: x") == "BadResource: x"
    assert units.start_error("BadResource: x") == "BadResource: x"
    assert units.start_error("") == "no reason given"
    assert len(units.start_error("START FAILED: " + "y" * 900)) == 300
```

- [ ] **Step 2: Correr e confirmar que falham**

```bash
python3.13 -m pytest tests/security/test_units.py -k "never_started or killed_with_no_stream or start_error" -p no:cacheprovider -q
```

Esperado: FAIL com `AttributeError: module 'security.units' has no attribute 'START_FAILED'`
(o teste de controlo pode passar já).

- [ ] **Step 3: A implementação**

Em `bin/security/units.py`, substituir

```python
OUTAGE_CAUSES = ("rate_limited", "api_error")
```

por

```python
OUTAGE_CAUSES = ("rate_limited", "api_error")
# The classifier's cause for a run whose agent never started (run_start_failed
# in bin/agentloop): it exited on its own, non-zero, before a single event.
# Nothing the unit could fix -- OpenCode failing every boot of a project on a
# poisoned sandbox (measurement 39) -- so, like an outage, it keeps its
# attempt, and the orchestrator counts it toward giving the lineage up and
# toward pausing the whole analysis (security/orchestrator.py).
START_FAILED = "start_failed"
KEPT_ATTEMPT_CAUSES = OUTAGE_CAUSES + (START_FAILED,)
START_FAILED_NOTE = "The agent could not start ({error}); nothing ran, so the attempt is kept."
# The engine's note for such a run: `START FAILED: <the agent's last stderr line>`.
_START_FAILED_PREFIX = "START FAILED: "
```

A seguir a `NO_STREAM_NOTE`, acrescentar:

```python
def start_error(reason) -> str:
    """The agent's own words in a `start_failed` run's note -- the engine
    writes `START FAILED: <its last stderr line>` -- at most 300 characters."""
    text = (reason or "").strip()
    if text.startswith(_START_FAILED_PREFIX):
        text = text[len(_START_FAILED_PREFIX):].strip()
    return text[:300] or "no reason given"
```

Em `close`, substituir

```python
    outage = cause in OUTAGE_CAUSES
```

por

```python
    outage = cause in OUTAGE_CAUSES
    kept = cause in KEPT_ATTEMPT_CAUSES
```

e, no ramo `if not evidence.stream_proves(stream):`, substituir

```python
        if outage:
            ev["cause"] = cause
        clear = None
        if unit["kind"] == "verify":
            clear = (unit["analysis_id"], unit["payload"].get("fingerprint", ""), f"unit:{unit['id']}")
        return conclude(conn, unit, done=False, evidence=ev, note=NO_STREAM_NOTE,
                        spend_usd=spend_usd, stopped=status == "stopped" or outage,
                        clear_verdict=clear)
```

por

```python
        note = NO_STREAM_NOTE
        if kept:
            ev["cause"] = cause
        if cause == START_FAILED:
            ev["error"] = start_error(reason)
            note = START_FAILED_NOTE.format(error=ev["error"])
        clear = None
        if unit["kind"] == "verify":
            clear = (unit["analysis_id"], unit["payload"].get("fingerprint", ""), f"unit:{unit['id']}")
        return conclude(conn, unit, done=False, evidence=ev, note=note,
                        spend_usd=spend_usd, stopped=status == "stopped" or kept,
                        clear_verdict=clear)
```

O ramo com stream não muda. Uma falha de arranque não tem eventos, por
definição.

- [ ] **Step 4: Correr e confirmar que passam**

O mesmo comando, e depois o ficheiro inteiro:
`python3.13 -m pytest tests/security/test_units.py -p no:cacheprovider -q`.
Esperado: tudo a passar.

- [ ] **Step 5: CHANGELOG**

Em `### Added`, a seguir à entrada da Task 4:

```markdown
- **An agent that cannot start no longer spends its unit's attempts.** A unit
  whose run ended `start_failed` keeps its attempt, as one cut short by a
  provider outage already does, and its note reads "The agent could not start
  (<the agent's words>)". Before, every such run was one of the unit's three
  attempts, and an environment problem that hit every unit alike gave each of
  them up in turn.
```

- [ ] **Step 6: Commit**

```bash
git add bin/security/units.py tests/security/test_units.py CHANGELOG.md
git commit -m "fix(security): a unit whose agent never started keeps its attempt"
```

---

### Task 7: O orquestrador desiste de uma linhagem e pausa a análise

**Files:**
- Modify: `bin/security/orchestrator.py` (constantes, `__init__`, `_after`, `_outages_before`, `_launch_pass`, `_count_start` novo)
- Modify: `tests/security/fixtures/fake-engine`
- Test: `tests/security/test_orchestrator.py`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `units.START_FAILED`, `units.KEPT_ATTEMPT_CAUSES`, a evidência
  `{"cause", "error"}` (Task 6).
- Produces:
  - `orchestrator.START_FAIL_BREAKER = 3`
  - `orchestrator.START_FAIL_GATE` e `orchestrator.STRUCK_OUT_START_NOTE`
  - `Orchestrator._outages_before(unit) -> (n, cause, error)` (antes
    devolvia `(n, cause)`)
  - Modos do `fake-engine`: `start-fail` e `start-fail-hunt`.

- [ ] **Step 1: Os modos do `fake-engine`**

Em `tests/security/fixtures/fake-engine`, na docstring, a seguir a
`always-outage`:

```
      start-fail          every run ends `error` / `start_failed` with no
                          stream, its reason FAKE_ENGINE_START_ERROR (default
                          a BadResource line, measurement 39)
      start-fail-hunt     a hunt unit's runs end as `start-fail`; the other
                          kinds play `complete`
```

Substituir a função `close` por:

```python
def close(aid, uid, status, stream="", cause="", reason=""):
    cli("unit-close", "--analysis", aid, "--unit", uid, "--status", status, "--spend", SPEND,
        "--root", ROOT, *(["--stream", stream] if stream else []),
        *(["--cause", cause] if cause else []),
        *(["--reason", reason] if reason else []))
```

Em `run_unit`, imediatamente antes de
`if MODE == "always-outage" or (MODE == "outage" and not unit["parent"]):`:

```python
    if MODE == "start-fail" or (MODE == "start-fail-hunt" and unit["kind"] == "hunt"):
        close(aid, uid, "error", cause="start_failed",
              reason="START FAILED: " + os.environ.get(
                  "FAKE_ENGINE_START_ERROR", "BadResource: FileSystem.access (/gone/repo)"))
        return
```

- [ ] **Step 2: Escrever os testes que falham**

Em `tests/security/test_orchestrator.py`, a seguir a
`test_three_outages_in_a_row_give_the_lineage_up`:

```python
def test_units_that_cannot_start_pause_the_analysis_after_one_wave(world, monkeypatch):
    """Analysis 12 (2026-09-26): OpenCode failed every boot of the project,
    and the orchestrator spent three attempts on each of 231 lineages, in 42
    minutes, before it closed capped. Every unit failing to start is the
    environment: the gate closes after START_FAIL_BREAKER of them over two
    lineages or more, the analysis is left interrupted with the error in its
    note, and no lineage is given up for it."""
    runs = world["tmp"] / "runs"
    monkeypatch.setenv("FAKE_ENGINE_BUDGETS", str(runs))
    monkeypatch.setenv("FAKE_ENGINE_MODE", "start-fail")
    assert _orchestrator(world).run() == 0
    row = _row(world)
    assert row["state"] == "interrupted", row["coverage_note"]
    assert ("the agent could not start: 3 units in a row ended before a session opened "
            "(last error: BadResource: FileSystem.access (/gone/repo))") in row["coverage_note"]
    launched = len(runs.read_text().splitlines())
    assert 3 <= launched <= 3 + orchestrator.START_FAIL_BREAKER - 1, launched
    assert not [u for u in _units(world) if u["state"] == "failed"], "no lineage given up for the environment"
    assert all(u["attempt"] == 1 for u in _units(world)), "a start failure keeps its attempt"


def test_one_unit_that_cannot_start_is_given_up_without_pausing_the_rest(world, monkeypatch):
    """One lineage failing to start is that unit's own trouble: the others
    run, the gate stays open, and after LAUNCH_STRIKES start failures in a
    row the unit is given up with the agent's own words in its note."""
    monkeypatch.setenv("FAKE_ENGINE_MODE", "start-fail-hunt")
    assert _orchestrator(world).run() == 0
    hunt = [u for u in _last_attempts(world).values() if u["kind"] == "hunt"]
    assert hunt and hunt[0]["state"] == "failed"
    assert hunt[0]["note"] == ("The engine could not run this unit: its agent could not start 3 times "
                               "in a row (BadResource: FileSystem.access (/gone/repo); see tick.log).")
    row = _row(world)
    assert row["state"] == "capped"
    assert "its agent could not start 3 times in a row" in row["coverage_note"]
    assert "the agent could not start: 3 units in a row" not in row["coverage_note"], "no gate for one lineage"


def test_a_paused_analysis_resumes_once_the_agent_can_start_and_closes_done(world, monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "start-fail")
    _orchestrator(world).run()
    assert _row(world)["state"] == "interrupted"
    monkeypatch.setenv("FAKE_ENGINE_MODE", "complete")
    assert ledger.resume_analysis(ledger.connect(world["db"]), world["aid"]) is True
    assert _orchestrator(world).run() == 0
    assert _row(world)["state"] == "done", _row(world)["coverage_note"]
```

- [ ] **Step 3: Correr e confirmar que falham**

```bash
python3.13 -m pytest tests/security/test_orchestrator.py -k "cannot_start or paused_analysis" -p no:cacheprovider -q
```

Esperado: FAIL. O primeiro fecha `capped` com linhagens `failed` (o
`_outages_before` não conta as falhas de arranque, por isso as três
continuações correm), e o segundo não encontra a nota nova.

- [ ] **Step 4: A implementação**

Em `bin/security/orchestrator.py`:

1. A seguir a `STRUCK_OUT_OUTAGE_NOTE`:

```python
STRUCK_OUT_START_NOTE = ("The engine could not run this unit: its agent could not start {n} "
                         "times in a row ({error}; see tick.log).")
# THE ANALYSIS-WIDE BREAKER. Start failures in a row, over two lineages or
# more, are the environment failing every unit alike -- analysis 12 spent
# 693 runs and 42 minutes proving that one lineage at a time. The gate
# closes, nothing more is launched, and the analysis is left interrupted
# for a resume once the cause is fixed (see _count_start).
START_FAIL_BREAKER = 3
START_FAIL_GATE = ("the agent could not start: {n} units in a row ended before a session "
                   "opened (last error: {error})")
```

2. A seguir a `OUTAGE_CAUSES = units.OUTAGE_CAUSES`:

```python
# Every cause whose run keeps its attempt: an outage, or an agent that never
# started (units.close). Runs of either, in a row, are runs the engine could
# not run, and LAUNCH_STRIKES of them give a lineage up.
KEPT_ATTEMPT_CAUSES = units.KEPT_ATTEMPT_CAUSES
```

3. Em `__init__`, a seguir a `self.gate = ""`:

```python
        self.start_fails = []     # (lineage, error) of the start failures in a row (_count_start)
```

4. Substituir `_outages_before` inteiro por:

```python
    def _outages_before(self, unit):
        """(n, cause, error): how many of `unit`'s ancestors IN A ROW, nearest
        first, closed on a run the engine could not run -- a provider outage,
        or an agent that never started (their evidence carries the
        classifier's cause, units.close) -- the nearest one's cause and, for a
        start failure, the agent's own words."""
        n, cause, error, node = 0, "", "", unit
        while node["parent"]:
            node = ledger.get_unit(self.conn, node["parent"])
            evidence = (node.get("evidence") or {}) if node is not None else {}
            if evidence.get("cause") not in KEPT_ATTEMPT_CAUSES:
                break
            if not cause:
                cause, error = evidence["cause"], evidence.get("error", "")
            n += 1
        return n, cause, error
```

5. Em `_launch_pass`, substituir o bloco

```python
            outages, cause = self._outages_before(unit)
            if outages >= LAUNCH_STRIKES:
                # THE PROVIDER CUT SHORT THE LINEAGE'S LAST LAUNCH_STRIKES RUNS
                # IN A ROW: given up, as three runs that died unclosed are.
                # Counted off the ledger at the launch, never off this
                # process's memory: a continuation is pending the moment its
                # parent's close commits, before this loop has even reaped
                # that parent's process -- and a resume must count the same.
                ledger.settle_unit(self.conn, unit["id"], "failed", 0, {},
                                   STRUCK_OUT_OUTAGE_NOTE.format(n=outages, cause=cause))
```

por

```python
            outages, cause, error = self._outages_before(unit)
            if outages >= LAUNCH_STRIKES:
                # THE ENGINE COULD NOT RUN THE LINEAGE'S LAST LAUNCH_STRIKES
                # RUNS IN A ROW -- a provider outage, or an agent that never
                # started: given up, as three runs that died unclosed are.
                # Counted off the ledger at the launch, never off this
                # process's memory: a continuation is pending the moment its
                # parent's close commits, before this loop has even reaped
                # that parent's process -- and a resume must count the same.
                note = (STRUCK_OUT_START_NOTE.format(n=outages, error=error)
                        if cause == units.START_FAILED
                        else STRUCK_OUT_OUTAGE_NOTE.format(n=outages, cause=cause))
                ledger.settle_unit(self.conn, unit["id"], "failed", 0, {}, note)
```

(as duas linhas seguintes do bloco original, o `self.log(…)` e o
`continue`, ficam como estão).

6. Em `_after`, no ramo `if unit["state"] != "running":`, substituir

```python
            self.strikes.pop(lineage, None)      # a run closed it: the engine can run it
            return
```

por

```python
            self.strikes.pop(lineage, None)      # a run closed it: the engine can run it
            self._count_start(unit, lineage)
            return
```

7. A seguir a `_after`, acrescentar:

```python
    def _count_start(self, unit, lineage):
        """The analysis-wide breaker. A unit closed on a start failure adds to
        the run of them; any other close ends it -- an agent started, so the
        environment works. START_FAIL_BREAKER in a row, over two lineages or
        more, closes this orchestrator's gate with the agent's last words:
        _loop stops launching, waits for what is in flight, and run() leaves
        the analysis interrupted (GATE_NOTE), for a resume once the cause is
        fixed. The tick never resumes it on its own: no orchestrator died. One
        lineage alone is that unit's own trouble, given up by _launch_pass."""
        evidence = unit.get("evidence") or {}
        if evidence.get("cause") != units.START_FAILED:
            self.start_fails = []
            return
        self.start_fails.append((lineage, evidence.get("error", "")))
        if (not self.gate and len(self.start_fails) >= START_FAIL_BREAKER
                and len({lin for lin, _error in self.start_fails}) >= 2):
            self.gate = START_FAIL_GATE.format(n=len(self.start_fails),
                                               error=self.start_fails[-1][1])
            self.log(f"stops launching: {self.gate}")
```

- [ ] **Step 5: Correr e confirmar que passam**

O mesmo comando, e depois o ficheiro inteiro:
`python3.13 -m pytest tests/security/test_orchestrator.py -p no:cacheprovider -q`.
Esperado: tudo a passar, incluindo os dois testes de outage que já existiam.

- [ ] **Step 6: CHANGELOG**

Em `### Added`, a seguir à entrada da Task 6:

```markdown
- **A security analysis pauses when its units cannot start, instead of
  burning them one by one.** Three start failures in a row, over two units or
  more, close the orchestrator's gate: nothing more is launched, and the
  analysis is left `interrupted` with the agent's own last words in its note,
  so Resume continues it once the cause is fixed. On a real install the same
  environment failure used every one of 231 units' three attempts in 42
  minutes, and the analysis closed `capped` with none of them verified. One
  unit that alone cannot start is given up after three tries, with the reason
  named, and the rest of the analysis runs.
```

- [ ] **Step 7: Commit**

```bash
git add bin/security/orchestrator.py tests/security/fixtures/fake-engine tests/security/test_orchestrator.py CHANGELOG.md
git commit -m "feat(security): an analysis whose units cannot start pauses instead of burning them"
```

---

### Task 8: As regras do retry e o `reopen_analysis`

**Files:**
- Modify: `bin/security/units.py` (`import time`; `REOPENABLE`, `failed_lineages`, `retry_refusal`, `retryable`, `close_part_start`, `retry_sentence`)
- Modify: `bin/security/ledger.py` (`reopen_analysis`, a seguir a `close_interrupted`)
- Test: `tests/security/test_units.py`, `tests/security/test_ledger_units.py`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `units._lineages`, `units.coverage_sentence`, `units.gaps`, `ledger.INTERRUPTED`.
- Produces:
  - `units.failed_lineages(conn, analysis_id) -> list[dict]`: a última
    unidade de cada linhagem `failed`, pela ordem das raízes.
  - `units.retry_refusal(conn, analysis_id) -> str`: `""` quando o retry é
    permitido; senão a frase, pronta a seguir `analysis <id> `.
  - `units.retryable(conn, analysis_id) -> int`.
  - `units.close_part_start(conn, analysis_id, note) -> int`.
  - `units.retry_sentence(n, day=None) -> str`.
  - `ledger.reopen_analysis(conn, analysis_id, leaves, note) -> bool`.
  - As Tasks 9 a 12 usam-nos.

- [ ] **Step 1: Escrever os testes que falham**

Em `tests/security/test_units.py`, no fim:

```python
def _failed_hunt(conn, aid):
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    ledger.start_unit(conn, uid)
    ledger.settle_unit(conn, uid, "failed", 0, {}, "The engine could not run this unit.")
    return uid


def test_a_retry_is_for_the_newest_closed_analysis_of_its_branch_with_a_lineage_that_gave_up(conn):
    aid = _analysis(conn)
    uid = _failed_hunt(conn, aid)
    assert units.retry_refusal(conn, aid) == "is running: only a capped or failed analysis is retried"
    ledger.finish_analysis(conn, aid, "capped")
    assert units.retry_refusal(conn, aid) == ""
    assert units.retryable(conn, aid) == 1
    assert [u["id"] for u in units.failed_lineages(conn, aid)] == [uid]
    ledger.start_analysis(conn, "web", "web", "feature", "c2", "deep", "security-web")
    assert units.retry_refusal(conn, aid) == "", "another branch does not supersede it"
    newer = _analysis(conn)
    assert units.retry_refusal(conn, aid) == (f"was superseded by analysis {newer} of the same branch: "
                                              "run Analyse again instead")
    assert units.retryable(conn, aid) == 0


def test_a_closed_analysis_where_nothing_gave_up_has_nothing_to_retry(conn):
    aid = _analysis(conn)
    uid = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    ledger.start_unit(conn, uid)
    ledger.settle_unit(conn, uid, "done", 0, {}, "ok")
    ledger.finish_analysis(conn, aid, "capped")
    assert units.retry_refusal(conn, aid) == "has no unit that gave up: there is nothing to retry"
    assert units.retryable(conn, aid) == 0
    done = ledger.start_analysis(conn, "web", "web", "other", "c3", "deep", "security-web")
    _failed_hunt(conn, done)
    ledger.finish_analysis(conn, done, "done")
    assert units.retry_refusal(conn, done) == "is done: only a capped or failed analysis is retried"


def test_a_lineage_retried_is_judged_by_its_new_last_unit(conn):
    """The close judges a lineage by its last unit (units._lineages): once a
    child hangs off the failed leaf, the leaf is history, not a gap."""
    aid = _analysis(conn)
    uid = _failed_hunt(conn, aid)
    ledger.finish_analysis(conn, aid, "capped")
    assert ledger.reopen_analysis(conn, aid, units.failed_lineages(conn, aid), "n") is True
    assert units.failed_lineages(conn, aid) == []
    assert not [g for g in units.gaps(conn, aid) if "gave up" in g]
    assert ledger.get_unit(conn, uid)["state"] == "failed", "the leaf stays what it was"


def test_the_retry_sentence_says_when_and_how_many():
    assert units.retry_sentence(1, day="2026-09-27") == (
        "Retried on 2026-09-27: 1 unit that had given up was run again.")
    assert units.retry_sentence(231, day="2026-09-27") == (
        "Retried on 2026-09-27: 231 units that had given up were run again.")


def test_the_close_part_starts_at_the_units_sentence(conn):
    aid = _analysis(conn)
    _failed_hunt(conn, aid)
    head = "Scope and secrets as prepare wrote them."
    closed = f"{head} {units.coverage_sentence(conn, aid)} {' '.join(units.gaps(conn, aid))}".strip()
    assert closed[:units.close_part_start(conn, aid, closed)].strip() == head
    assert units.close_part_start(conn, aid, head) == len(head), "nothing of a close in it: all kept"
```

Em `tests/security/test_ledger_units.py`, a seguir a
`test_closing_an_interrupted_analysis_fails_it_with_the_reason`:

```python
def test_reopening_plans_one_child_per_leaf_and_moves_only_a_closed_analysis(conn):
    aid = _analysis(conn)
    a = ledger.add_unit(conn, aid, "verify", {"fingerprint": "a" * 64})
    b = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "x.py", "first": 1, "last": 9}]})
    for uid in (a, b):
        ledger.start_unit(conn, uid)
        ledger.settle_unit(conn, uid, "failed", 0, {}, "gave up")
    leaves = [ledger.get_unit(conn, a), ledger.get_unit(conn, b)]
    assert ledger.reopen_analysis(conn, aid, leaves, "n") is False, "a running analysis is not reopened"
    ledger.finish_analysis(conn, aid, "capped", coverage_note="old")
    assert ledger.reopen_analysis(conn, aid, leaves, "kept. Retried.") is True
    row = conn.execute("SELECT state, ended, coverage_note FROM analysis WHERE id=?", (aid,)).fetchone()
    assert (row["state"], row["ended"], row["coverage_note"]) == (ledger.INTERRUPTED, None, "kept. Retried.")
    kids = [u for u in ledger.units_of(conn, aid) if u["parent"] in (a, b)]
    assert [(k["kind"], k["state"], k["attempt"], k["parent"], k["seq"]) for k in kids] == [
        ("verify", "pending", 1, a, 3), ("read", "pending", 1, b, 4)]
    assert kids[0]["payload"] == {"fingerprint": "a" * 64}
    assert ledger.get_unit(conn, a)["state"] == "failed", "the leaf stays what it was"
    assert ledger.reopen_analysis(conn, aid, leaves, "again") is False, "an interrupted one is not"
```

- [ ] **Step 2: Correr e confirmar que falham**

```bash
python3.13 -m pytest tests/security/test_units.py tests/security/test_ledger_units.py -k "retry or reopen or retried or close_part" -p no:cacheprovider -q
```

Esperado: FAIL com `AttributeError` (`retry_refusal`, `reopen_analysis`…).

- [ ] **Step 3: A implementação em `ledger.py`**

A seguir a `close_interrupted`:

```python
def reopen_analysis(conn, analysis_id, leaves, note) -> bool:
    """capped|failed -> interrupted, for a retry (the operator's; security/
    units.py decides when one is allowed). One new `pending` unit per leaf
    in `leaves` -- the last unit of a lineage that gave up -- with the leaf's
    kind and payload, attempt 1 and the leaf as its parent: the lineage
    continues from where it gave up, and the close, which judges a lineage by
    its last unit, judges it by the retry. The leaves stay `failed`: they are
    what happened. `note` replaces the coverage note and `ended` is cleared,
    in ONE transaction, and only while the row is still `capped` or
    `failed` -- False with nothing written otherwise."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        cur = conn.execute(
            "UPDATE analysis SET state=?, ended=NULL, coverage_note=?"
            " WHERE id=? AND state IN ('capped','failed')",
            (INTERRUPTED, note, analysis_id))
        if cur.rowcount == 0:
            conn.rollback()
            return False
        seq = conn.execute("SELECT COALESCE(MAX(seq), 0) FROM unit WHERE analysis_id=?",
                           (analysis_id,)).fetchone()[0]
        for leaf in leaves:
            seq += 1
            conn.execute(
                "INSERT INTO unit (analysis_id, seq, kind, payload, attempt, parent)"
                " VALUES (?,?,?,?,?,?)",
                (analysis_id, seq, leaf["kind"], json.dumps(leaf["payload"], sort_keys=True),
                 1, leaf["id"]))
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    return True
```

- [ ] **Step 4: A implementação em `units.py`**

Acrescentar `import time` aos imports (a seguir a `import sqlite3`). No fim
do módulo:

```python
# A retry reopens only an analysis that ended; `running` and `interrupted`
# are the orchestrator's and the resume's, and `done` has nothing to retry.
REOPENABLE = ("capped", "failed")


def failed_lineages(conn, analysis_id) -> list:
    """The last unit of every lineage that gave up (`failed`), in the order of
    their roots -- what a retry runs again."""
    return [last for _root, last in _lineages(ledger.units_of(conn, analysis_id))
            if last["state"] == "failed"]


def retry_refusal(conn, analysis_id) -> str:
    """Why this analysis cannot be retried, as the words that follow
    `analysis <id> `; "" when it can. A retry reopens a closed analysis to run
    again only what gave up, on the commit it analysed. So: only one that
    ended `capped` or `failed`; only the newest of its scope -- the same
    (project, repo, branch) with which a new analysis already supersedes an
    interrupted one (cli.cmd_open_analysis), because retrying an older one
    would file two readings of one branch out of order; and only one with a
    lineage that gave up (an analysis capped by its budget alone has none)."""
    row = conn.execute("SELECT * FROM analysis WHERE id=?", (analysis_id,)).fetchone()
    if row is None:
        return "does not exist"
    if row["state"] not in REOPENABLE:
        return f"is {row['state']}: only a capped or failed analysis is retried"
    newer = conn.execute(
        "SELECT id FROM analysis WHERE project=? AND repo=? AND branch=? AND id>?"
        " ORDER BY id LIMIT 1",
        (row["project"], row["repo"], row["branch"], analysis_id)).fetchone()
    if newer is not None:
        return (f"was superseded by analysis {newer['id']} of the same branch: "
                "run Analyse again instead")
    if not failed_lineages(conn, analysis_id):
        return "has no unit that gave up: there is nothing to retry"
    return ""


def retryable(conn, analysis_id) -> int:
    """How many units a retry would run again; 0 when it would be refused. The
    page shows the Retry button by this number, computed by the very rule the
    retry applies, so the button and the refusal never disagree."""
    if retry_refusal(conn, analysis_id):
        return 0
    return len(failed_lineages(conn, analysis_id))


def close_part_start(conn, analysis_id, note) -> int:
    """Where the last close from the units began in `note`: `finish
    --from-units` appends the units' coverage sentence first, then the gaps,
    after whatever `prepare` stored. The index of the earliest of them;
    len(note) when none is in it. Computed now from the ledger that close
    read, which nothing has changed since: every unit of a closed analysis is
    settled."""
    marks = [coverage_sentence(conn, analysis_id)] + gaps(conn, analysis_id)
    found = [note.find(mark) for mark in marks if mark and note.find(mark) >= 0]
    return min(found) if found else len(note)


def retry_sentence(n, day=None) -> str:
    """What a retry leaves in the analysis's note: when, and how many units."""
    day = day or time.strftime("%Y-%m-%d", time.gmtime())
    if n == 1:
        return f"Retried on {day}: 1 unit that had given up was run again."
    return f"Retried on {day}: {n} units that had given up were run again."
```

- [ ] **Step 5: Correr e confirmar que passam**

O mesmo comando, e depois os dois ficheiros inteiros:
`python3.13 -m pytest tests/security/test_units.py tests/security/test_ledger_units.py -p no:cacheprovider -q`.

- [ ] **Step 6: Commit**

Esta tarefa ainda não muda nada que o operador veja. A entrada do
CHANGELOG é escrita na Task 9, que expõe o verbo; `bin/` muda aqui, por
isso junta já o esqueleto dessa entrada em `### Added`:

```markdown
- **A capped or failed security analysis can be retried, running only what
  gave up.**
```

```bash
git add bin/security/units.py bin/security/ledger.py tests/security/test_units.py tests/security/test_ledger_units.py CHANGELOG.md
git commit -m "feat(security): the rules and the ledger transition of a retry"
```

---

### Task 9: O verbo `reopen` e o `retryable` no checklist

**Files:**
- Modify: `bin/security/cli.py` (`cmd_reopen` a seguir a `cmd_abandon`; o parser a seguir ao do `abandon`; `AGENT_FORBIDDEN`; `cmd_checklist`)
- Test: `tests/security/test_finish_units.py`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: tudo o que a Task 8 produz.
- Produces:
  - `security/cli.py reopen --analysis <id>`: imprime
    `{"state": "interrupted", "units": <n>}`; recusa com
    `analysis <id> <frase>` no stderr e código ≠ 0.
  - `checklist` ganha `"retryable": <n>`.
  - O motor (Task 10) chama `reopen` e o servidor/UI (Tasks 11 e 12) lêem
    `retryable`.

- [ ] **Step 1: Escrever os testes que falham**

Em `tests/security/test_finish_units.py`, no fim:

```python
import os

from test_cli import fails


def _gave_up(db, tmp_path):
    """A deep analysis closed from its units with one lineage given up: the
    read proved its lines, the hunt never ran."""
    aid, conn = _deep(db, tmp_path)
    hunt = ledger.add_unit(conn, aid, "hunt", {"profile": "deep"})
    read = ledger.add_unit(conn, aid, "read", {"ranges": [{"path": "a.py", "first": 1, "last": 10, "bytes": 100}]})
    _done(conn, read, 1.5, ["ATTACK-CLASSES"], covered={"a.py": [[1, 10]]})
    ledger.start_unit(conn, hunt)
    ledger.settle_unit(conn, hunt, "failed", 0, {}, "The engine could not run this unit.")
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    return aid, conn, hunt, read


def test_a_retry_reopens_only_what_gave_up_and_the_next_close_drops_the_old_gaps(tmp_path):
    db = tmp_path / "security.db"
    aid, conn, hunt, read = _gave_up(db, tmp_path)
    before = _analysis(db, aid)
    assert before["state"] == "capped" and "gave up" in before["coverage_note"]
    assert run(db, "checklist", "--analysis", str(aid))["retryable"] == 1
    assert run(db, "reopen", "--analysis", str(aid)) == {"state": "interrupted", "units": 1}
    child = [u for u in ledger.units_of(conn, aid) if u["parent"] == hunt]
    assert [(c["kind"], c["state"], c["attempt"]) for c in child] == [("hunt", "pending", 1)]
    assert ledger.get_unit(conn, read)["state"] == "done", "what was done stays done"
    reopened = _analysis(db, aid)
    assert "gave up" not in reopened["coverage_note"], "the old close's gaps are cut"
    assert "1 unit that had given up was run again." in reopened["coverage_note"]
    ledger.resume_analysis(conn, aid)
    _done(conn, child[0]["id"], 0.5, ["ATTACK-CLASSES"])
    run(db, "finish", "--analysis", str(aid), "--state", "done", "--from-units")
    after = _analysis(db, aid)
    assert after["state"] == "done", after["coverage_note"]
    assert "gave up" not in after["coverage_note"]
    assert "1 unit that had given up was run again." in after["coverage_note"]
    assert run(db, "checklist", "--analysis", str(aid))["retryable"] == 0


def test_reopen_refuses_with_the_reason_and_never_inside_an_agent_session(tmp_path):
    db = tmp_path / "security.db"
    aid, conn, _hunt, _read = _gave_up(db, tmp_path)
    agent = fails(db, "reopen", "--analysis", str(aid), env={**os.environ, "AL_SECURITY_AGENT": "1"})
    assert agent.returncode != 0, "a unit's session never reopens an analysis"
    assert _analysis(db, aid)["state"] == "capped"
    run(db, "reopen", "--analysis", str(aid))
    again = fails(db, "reopen", "--analysis", str(aid))
    assert again.returncode != 0
    assert f"analysis {aid} is interrupted: only a capped or failed analysis is retried" in again.stderr
```

- [ ] **Step 2: Correr e confirmar que falham**

```bash
python3.13 -m pytest tests/security/test_finish_units.py -k "retry or reopen" -p no:cacheprovider -q
```

Esperado: FAIL (`KeyError: 'retryable'`, e `invalid choice: 'reopen'`).

- [ ] **Step 3: A implementação**

Em `bin/security/cli.py`:

1. Em `AGENT_FORBIDDEN`, na linha que termina em `"resume", "abandon",`,
   acrescentar `"reopen",` a seguir a `"abandon",`.

2. A seguir a `cmd_abandon`:

```python
def cmd_reopen(args):
    """The operator's retry of a capped or failed analysis: the units that
    gave up run again, and nothing else (`agentloop security retry` calls
    this, then `resume`). What the last close appended to the note -- the
    units' sentence and its gaps -- is cut, so the next close describes the
    final state instead of stacking a second verdict on the first; a
    sentence saying when, and how many, takes its place. Refused, with the
    reason, when units.retry_refusal gives one."""
    conn = _conn(args)
    _analysis(conn, args.analysis)
    why = units.retry_refusal(conn, args.analysis)
    if why:
        sys.exit(f"analysis {args.analysis} {why}")
    leaves = units.failed_lineages(conn, args.analysis)
    stored = conn.execute("SELECT coverage_note FROM analysis WHERE id=?",
                          (args.analysis,)).fetchone()["coverage_note"] or ""
    kept = stored[:units.close_part_start(conn, args.analysis, stored)].strip()
    note = f"{kept} {units.retry_sentence(len(leaves))}".strip()
    if not ledger.reopen_analysis(conn, args.analysis, leaves, note):
        sys.exit(f"analysis {args.analysis} changed while it was being reopened: try again")
    print(json.dumps({"state": ledger.INTERRUPTED, "units": len(leaves)}))
```

3. No parser, a seguir às duas linhas do `abandon`:

```python
    ro = sub.add_parser("reopen", parents=[dbflag]); ro.set_defaults(fn=cmd_reopen)
    ro.add_argument("--analysis", type=int, required=True)
```

(e o comentário que diz «all three in AGENT_FORBIDDEN» passa a «all four»).

4. Em `cmd_checklist`, no `print(json.dumps({...}))`, a seguir a
   `"units": units.summary(conn, args.analysis),`:

```python
                      # How many units a Retry would run again -- 0 when it
                      # would be refused -- by the rule `reopen` itself
                      # applies (units.retry_refusal), for the page's button.
                      "retryable": units.retryable(conn, args.analysis),
```

- [ ] **Step 4: Correr e confirmar que passam**

O mesmo comando, e depois:
`python3.13 -m pytest tests/security/test_finish_units.py tests/security/test_cli_units.py tests/security/test_cli_doors.py -p no:cacheprovider -q`.
Esperado: tudo a passar. O `test_cli_doors.py` cobre o `AGENT_FORBIDDEN`.

- [ ] **Step 5: CHANGELOG**

Completar a entrada da Task 8:

```markdown
- **A capped or failed security analysis can be retried, running only what
  gave up.** `security/cli.py reopen` turns the newest analysis of a branch
  back to `interrupted` and gives every lineage that gave up a fresh unit, at
  attempt 1, on the commit it analysed; units already done never run again.
  The last close's gap sentences are cut from the note, so the next close
  describes the final state, and a sentence says when it was retried and how
  many units ran again. Before, the only way on from a `capped` analysis was
  a new one, repeating hours of reading that had already been proved.
```

- [ ] **Step 6: Commit**

```bash
git add bin/security/cli.py tests/security/test_finish_units.py CHANGELOG.md
git commit -m "feat(security): reopen a closed analysis to run only the units that gave up"
```

---

### Task 10: `agentloop security retry`

**Files:**
- Modify: `bin/agentloop` (`cmd_security_retry` a seguir a `cmd_security_resume`; a ajuda; o dispatch)
- Test: `test/selftest.sh` (a seguir ao bloco `cmd_security_resume()`)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `security/cli.py reopen` (Task 9), `resume`, `analysis`,
  `security_launch_detached`, `security_analysis_live`, `slots_active`.
- Produces: `agentloop security retry <project> <analysis-id>`, que imprime
  `{"analysis_id":<id>,"retried":<n>}` e escreve
  `<job>: retried analysis <id>: <n> failed unit(s) run again …` no
  `tick.log`. O servidor (Task 11) chama-o.

- [ ] **Step 1: Escrever o teste que falha**

Em `test/selftest.sh`, imediatamente antes de
`echo "cmd_security_branches() — local and origin branches, HEAD excluded, deduped"`:

```bash
  echo "cmd_security_retry() — reopen, resume and launch, in that order; nothing launched when the reopen refuses"
  # The engine's half of a Retry: the ledger decides (security/cli.py reopen,
  # tested with it); this is the glue, stubbed at its edges.
  : > "$sec/retry.calls"
  ( sec_env
    security_engine_py() {
      printf '%s\n' "$1" >> "$sec/retry.calls"
      case "$1" in
        analysis) printf '{"project":"Sec App","branch":"main","repo":"Sec App"}' ;;
        reopen)   printf '{"state":"interrupted","units":2}' ;;
        resume)   printf '{"state":"running"}' ;;
      esac
    }
    security_analysis_live() { return 1; }
    slots_active() { echo 0; }
    security_launch_detached() { printf 'launch %s %s %s\n' "$2" "$3" "$4" >> "$sec/retry.calls"; }
    cmd_security_retry "Sec App" 41 ) > "$sec/retry.out" 2>&1
  [ "$(tr '\n' ' ' < "$sec/retry.calls")" = "analysis reopen resume launch 41 main Sec App " ] \
    && ok "it reopens, resumes and launches the analysis on its own branch and repo" \
    || bad "retry calls: $(tr '\n' ' ' < "$sec/retry.calls")"
  grep -q '{"analysis_id":41,"retried":2}' "$sec/retry.out" \
    && ok "and says how many units run again" || bad "retry printed: $(cat "$sec/retry.out")"
  : > "$sec/retry.calls"
  ( sec_env
    security_engine_py() {
      printf '%s\n' "$1" >> "$sec/retry.calls"
      case "$1" in
        analysis) printf '{"project":"Sec App","branch":"main","repo":"Sec App"}' ;;
        reopen)   echo "analysis 41 is done: only a capped or failed analysis is retried" >&2; return 1 ;;
      esac
    }
    security_analysis_live() { return 1; }
    slots_active() { echo 0; }
    security_launch_detached() { printf 'launch\n' >> "$sec/retry.calls"; }
    cmd_security_retry "Sec App" 41 ) > "$sec/retry.out" 2>&1; rc=$?
  [ "$rc" -ne 0 ] && grep -q "only a capped or failed analysis is retried" "$sec/retry.out" \
    && ! grep -q "launch" "$sec/retry.calls" \
    && ok "a refused reopen stops it, with the ledger's own sentence, and launches nothing" \
    || bad "refused retry (rc $rc): $(cat "$sec/retry.out"); calls: $(tr '\n' ' ' < "$sec/retry.calls")"
```

- [ ] **Step 2: Correr e confirmar que falha**

Selftest sem o e2e. Esperado:
`FAIL  retry calls: ` e as outras duas (`cmd_security_retry: command not found`).

- [ ] **Step 3: A implementação**

Em `bin/agentloop`, a seguir a `cmd_security_resume`:

```bash
# `agentloop security retry <project> <analysis-id>`: a CAPPED or FAILED
# analysis reopened to run again only the lineages that gave up, on the
# commit it analysed -- the ledger's `reopen` decides when that is allowed
# (security/units.py retry_refusal) and says why when it is not -- then
# continued exactly as a resume continues an interrupted one. Refused, like
# a resume, while anything of the project's is still alive.
cmd_security_retry() { # cmd_security_retry <project> <analysis-id>
  [ $# -ge 2 ] || die "usage: agentloop security retry <project> <analysis-id>"
  local project="$1" aid="$2" jid row out n
  security_enabled "$project" || die "security is not enabled for project '$project'"
  case "$aid" in ''|*[!0-9]*) die "security: '$aid' is not an analysis id" ;; esac
  jid="$(security_job_id "$project")"
  row="$(security_engine_py analysis --id "$aid" 2>/dev/null)" || die "no such analysis: $aid"
  [ "$(printf '%s' "$row" | "$JQ" -r '.project')" = "$project" ] \
    || die "analysis $aid is not an analysis of '$project'"
  security_analysis_live "$jid" && die "an analysis of '$project' is already running (job $jid)"
  [ "$(slots_active "$jid")" -eq 0 ] \
    || die "units of '$project' are still winding down — try again in a moment"
  out="$(security_engine_py reopen --analysis "$aid" 2>&1)" || die "$out"
  n="$(num "$(printf '%s' "$out" | "$JQ" -r '.units // 0' 2>/dev/null)" 0)"
  security_engine_py resume --analysis "$aid" >/dev/null 2>&1 \
    || die "analysis $aid was reopened but could not be resumed: run agentloop security resume '$project' $aid"
  security_launch_detached "$jid" "$aid" "$(printf '%s' "$row" | "$JQ" -r '.branch')" \
    "$(printf '%s' "$row" | "$JQ" -r '.repo')"
  log_tick "$jid: retried analysis $aid: $n failed unit(s) run again $(stop_origin)"
  printf '{"analysis_id":%s,"retried":%s}\n' "$aid" "$n"
}
```

Na ajuda, a seguir às três linhas do `agentloop security resume …`:

```
  agentloop security retry <project> <analysis-id>
                              reopen a capped or failed analysis (the newest
                              of its branch) and run again only the units
                              that gave up, on the commit it analysed
```

No dispatch, a seguir à linha `resume)  shift; cmd_security_resume "$@" ;;`:

```bash
               # The operator's retry of a capped or failed analysis: the
               # ledger's `reopen`, then the same launch a resume makes.
               retry)   shift; cmd_security_retry "$@" ;;
```

- [ ] **Step 4: Correr e confirmar que passa**

Selftest sem o e2e. Esperado: os três `ok` do bloco novo.

- [ ] **Step 5: CHANGELOG**

Acrescentar ao fim da entrada da Task 9:

```markdown
  From the terminal: `agentloop security retry <project> <analysis-id>`.
```

- [ ] **Step 6: Commit**

```bash
git add bin/agentloop test/selftest.sh CHANGELOG.md
git commit -m "feat(security): agentloop security retry reopens and relaunches an analysis"
```

---

### Task 11: A operação `security_retry` no servidor

**Files:**
- Modify: `bin/agentloop-server` (`security_retry` a seguir a `security_resume`; o dispatch)
- Test: `tests/test_security_api.py`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `agentloop security retry` (Task 10).
- Produces: `POST` com `op: "security_retry"`, `{project, analysis}` →
  `200 {"ok": true, "output": …}`, `400` para uma entrada inválida, `500`
  com a frase do motor quando ele recusa. A UI (Task 12) chama-o.

- [ ] **Step 1: Escrever o teste que falha**

Em `tests/test_security_api.py`, a seguir a
`test_resume_asks_the_engine_to_resume_that_analysis_of_that_project`:

```python
def test_retry_asks_the_engine_to_retry_that_analysis_of_that_project(srv, monkeypatch):
    calls = []
    monkeypatch.setattr(srv, "al", lambda args, **kw: (calls.append(args) or (True, '{"analysis_id":7,"retried":3}')))
    code, body = srv.security_retry({"project": "web", "analysis": 7})
    assert (code, calls) == (200, [["security", "retry", "web", "7"]])
    assert srv.security_retry({"project": "web", "analysis": "7; rm -rf /"})[0] == 400
    assert srv.security_retry({"project": "", "analysis": 7})[0] == 400
    monkeypatch.setattr(srv, "al", lambda args, **kw: (False, "analysis 7 is done: only a capped or failed analysis is retried"))
    assert srv.security_retry({"project": "web", "analysis": 7}) == (
        500, {"error": "analysis 7 is done: only a capped or failed analysis is retried"})
```

- [ ] **Step 2: Correr e confirmar que falha**

```bash
python3.13 -m pytest tests/test_security_api.py -k retry -p no:cacheprovider -q
```

Esperado: FAIL com `AttributeError: … has no attribute 'security_retry'`.

- [ ] **Step 3: A implementação**

Em `bin/agentloop-server`, a seguir a `security_resume`:

```python
def security_retry(body):
    """Retry the units of a capped or failed analysis that gave up: the
    engine checks the rest (that it is this project's, the newest of its
    branch, that something gave up, that nothing of it still runs) and says
    why in its own sentence when it refuses."""
    project = str(body.get("project", "")).strip()
    analysis = str(body.get("analysis", "")).strip()
    if not project or not analysis.isdigit():
        return 400, {"error": "project and a numeric analysis id are required"}
    ok, out = al(["security", "retry", project, analysis])
    return (200, {"ok": True, "output": out}) if ok else (500, {"error": out})
```

No dispatch, a seguir a
`if op == "security_resume": return self._send(*security_resume(body))`:

```python
        if op == "security_retry":
            return self._send(*security_retry(body))
```

- [ ] **Step 4: Correr e confirmar que passa**

O mesmo comando, e depois
`python3.13 -m pytest tests/test_security_api.py -p no:cacheprovider -q`.

- [ ] **Step 5: Commit**

Sem mudança de comportamento visível além da da Task 10; a entrada do
CHANGELOG já a cobre, mas o commit toca `bin/`. Acrescenta à entrada da
Task 9 a frase `The dashboard asks for it through a new security_retry operation.`

```bash
git add bin/agentloop-server tests/test_security_api.py CHANGELOG.md
git commit -m "feat(server): a security_retry operation for the dashboard"
```

---

### Task 12: O botão **Retry failed units**

**Files:**
- Modify: `bin/dashboard.html` (o objecto `AL`)
- Modify: `ui/security/page.js`, `ui/security/state.js`, `ui/security/analysis.js`
- Modify: `bin/static/security.js` (por `npm run build`)
- Test: `tests/test_page_contract.py`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `retryable` do checklist (Task 9), a operação `security_retry`
  (Task 11), `showConfirm` do `dashboard.html`.
- Produces: `secRenderPipeline(a, summary, retryable)` e
  `secRetryAnalysis(a, n)`.

- [ ] **Step 1: Escrever os testes que falham**

Em `tests/test_page_contract.py`, substituir `_pipeline_script` por:

```python
def _pipeline_script(block, analysis, summary, retryable=0):
    deps = (_const(block, "SEC_UNIT_KIND_LABEL")
            + _index_screen_deps(block, "secEl", "secRenderPipeline"))
    return _INDEX_DOM_HARNESS + """
    const HOSTS = {};
    function $(id){ if(!HOSTS[id]) HOSTS[id] = document.createElement("div"); return HOSTS[id]; }
    function money(v){ return "$" + Number(v).toFixed(2); }
    function secStopAnalysis(){} function secResumeAnalysis(){} function secRetryAnalysis(){}
    """ + deps + f"""
    secRenderPipeline({json.dumps(analysis)}, {json.dumps(summary)}, {json.dumps(retryable)});
    const host = $("sec-pipeline");
    console.log(JSON.stringify({{hidden: host.hidden, nodes: collectAll(host, []),
      buttons: collectAll(host, []).filter(n => n.cls === "btn").map(n => n.text)}}));
    """
```

E, a seguir a `test_an_interrupted_analysis_offers_resume_and_a_closed_one_offers_nothing`:

```python
@pytest.mark.skipif(not shutil.which("node"), reason="node not installed")
def test_a_closed_analysis_with_units_that_gave_up_offers_retry(srv, tmp_path):
    cases = (("capped", 3, ["Retry failed units"]), ("failed", 1, ["Retry failed units"]),
             ("capped", 0, []), ("done", 0, []), ("interrupted", 0, ["Resume"]))
    for n, (state, retryable, want) in enumerate(cases):
        script = tmp_path / f"pipeline-retry-{n}.js"
        script.write_text(_pipeline_script(_security_js(srv), {"id": 22, "state": state, "run_id": "security-web"},
                                           SUMMARY, retryable))
        out = json.loads(subprocess.run(["node", str(script)], capture_output=True, text=True, check=True).stdout)
        assert out["buttons"] == want, (state, retryable)


def test_retry_says_what_it_will_run_before_it_asks_the_engine(srv):
    block = _security_js(srv)
    retry = _anyfn(block, "secRetryAnalysis")
    assert 'api("security_retry", {project: secState.project, analysis: a.id})' in retry
    assert "showConfirm(" in retry
    assert "on commit" in retry and "stays done" in retry
```

- [ ] **Step 2: Correr e confirmar que falham**

```bash
python3.13 -m pytest tests/test_page_contract.py -k "retry or offers_resume" -p no:cacheprovider -q
```

Esperado: FAIL (nenhum botão de retry, e `secRetryAnalysis` não existe).

- [ ] **Step 3: A ponte**

Em `bin/dashboard.html`, no objecto `const AL = {`, a seguir à linha
`markPending, clearPending, isPending, markIfPending,`:

```js
  // The page's one confirmation dialog, for an action that spends: the
  // Security page's Retry says what it will run before it runs it.
  // Hoisted, like openProjectEditor below.
  showConfirm,
```

Em `ui/security/page.js`, acrescentar `showConfirm` à lista
`export let …` (a seguir a `markPending, clearPending, isPending, markIfPending,`)
e ao destructuring de `bindPage` (a seguir a
`markPending, clearPending, isPending, markIfPending,`).

Em `ui/security/state.js`, trocar `units:null, orchestrator:null};` por
`units:null, orchestrator:null, retryable:0};`.

- [ ] **Step 4: O botão e a acção**

Em `ui/security/analysis.js`:

1. No import de `./page.js`, acrescentar `showConfirm` a seguir a `isPending`.
2. Em `secShowAnalysis`, nos dois sítios que fazem
   `secState.units = null; secState.orchestrator = null;`, acrescentar
   `secState.retryable = 0;`, e a seguir a `secState.orchestrator = j.orchestrator || null;`
   acrescentar `secState.retryable = j.retryable || 0;`.
3. Trocar `secRenderPipeline(a, secState.units);` por
   `secRenderPipeline(a, secState.units, secState.retryable);`.
4. Trocar a assinatura `export function secRenderPipeline(a, summary){` por
   `export function secRenderPipeline(a, summary, retryable){` e, a seguir ao
   bloco `if(a.state === "running" || a.state === "interrupted"){ … }`:

```js
  // A closed analysis with units that gave up: `retryable` is the checklist's
  // count, by the rule the engine's own `reopen` applies, so the button is
  // never offered for an analysis the engine would refuse.
  if((a.state === "capped" || a.state === "failed") && retryable > 0){
    const btn = secEl("button", "btn", "Retry failed units");
    btn.type = "button";
    btn.onclick = () => secRetryAnalysis(a, retryable);
    host.appendChild(btn);
  }
```

5. A seguir a `secResumeAnalysis`:

```js
async function secRetryAnalysis(a, n){
  const k = ["security_retry", secState.project, String(a.id)];
  if(isPending(...k)) return;
  const units = n === 1 ? "1 unit" : n + " units";
  // What it will run, before it runs it: a retry spends, and it reruns the
  // commit the analysis read, not the branch's HEAD.
  const yes = await showConfirm({tone: "warn", icon: "shield",
    title: "Retry the " + units + " that gave up?",
    message: "Runs again only the " + units + " that failed, on commit "
      + String(a.commit_sha || "").slice(0, 7) + ". Everything already done stays done.",
    confirmLabel: "Retry " + units});
  if(!yes) return;
  markPending(...k);
  try{
    // The engine refuses with its own sentence (a newer analysis, nothing
    // gave up, units still winding down), which api() puts on screen.
    if(await api("security_retry", {project: secState.project, analysis: a.id})){
      toast("Retrying " + units, false, "shield");
      await secReload();
      secSyncPoll();
    }
  } finally { clearPending(...k); }
}
```

- [ ] **Step 5: Construir e correr**

```bash
npm run build
python3.13 -m pytest tests/test_page_contract.py -k "retry or offers_resume or pipeline or bindpage or usable" -p no:cacheprovider -q
```

Esperado: tudo a passar, incluindo o
`test_every_name_ccapp_and_ccsecurity_init_pass_is_already_usable` (o
`showConfirm` é uma função içada, declarada antes do objecto `AL`).

- [ ] **Step 6: CHANGELOG**

Acrescentar ao fim da entrada da Task 9:

```markdown
  On the dashboard, a capped or failed analysis with units that gave up shows
  **Retry failed units**, which says how many will run and on which commit
  before it runs them.
```

- [ ] **Step 7: Commit**

```bash
git add bin/dashboard.html ui/security/page.js ui/security/state.js ui/security/analysis.js bin/static/security.js tests/test_page_contract.py CHANGELOG.md
git commit -m "feat(dashboard): Retry failed units on a closed analysis that has some"
```

---

### Task 13: Documentação, emendas à spec e o PR

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-26-security-analysis-recovery-design.md`

- [ ] **Step 1: README**

Em `README.md`, a seguir à frase «Your own Resume is never counted against
that limit.» (a secção do pipeline de segurança), acrescentar:

```markdown
**An agent that cannot start** (its CLI exits before a single event, as
OpenCode does for every boot of a project whose sandbox list names a path
under a file) is recorded `error` / `start_failed`, with the CLI's own last
stderr line as the run's note, instead of `killed`. Its unit keeps its
attempt; three in a row give that unit up, and three in a row across two or
more units pause the whole analysis: it is left `interrupted`, the note names
the error, and Resume continues it once the cause is fixed.

**Retry failed units.** A `capped` or `failed` analysis whose units gave up
is not a dead end. `agentloop security retry <project> <analysis>`, or
**Retry failed units** on the analysis, reopens it and runs again only those
units, each with a fresh round of attempts, on the commit it analysed. Every
unit already done is kept. Only the newest analysis of its branch can be
retried; its next close describes the final state, and its note says when it
was retried.
```

E, na referência da linha de comandos, a seguir ao bloco do
`agentloop security resume <project> <analysis-id>` e ao parágrafo que o
explica:

````markdown
```bash
agentloop security retry <project> <analysis-id>
```

reopens a `capped` or `failed` analysis (the newest of its branch) and runs
again, in the background, only the units that gave up, on the commit it
analysed.
````

- [ ] **Step 2: As emendas à spec**

Na spec, aplicar as cinco emendas da secção «Emendas à spec» deste plano:

- em «3. Uma falha de arranque tem nome», a linha do `tick.log` passa a
  `finished status=error cause=start_failed … — START FAILED: <razão>`;
- em «5. O disjuntor», a frase passa a
  `(last error: <razão>)`, e a linha do `tick.log` passa a
  `<job>: analysis <id> — stops launching: <frase>`;
- em «6. Retomar o que falhou», a linha em `event` sai, e o registo passa a
  ser a frase `Retried on …` na nota e a linha do `tick.log`; nos
  «Invariantes», «registado em `event`» passa a «registado na nota da análise
  e no `tick.log`»;
- em «Testes», «não se lançam mais runs do que o paralelismo» passa a «no
  máximo paralelismo + 2 runs»;
- em «1. O sweep nunca cria um caminho», a re-verificação passa a ser feita
  depois do `wt_is_claimed`, com a razão da emenda 5.

- [ ] **Step 3: Verificação final, só dos ficheiros tocados**

```bash
python3.13 -m pytest tests/test_fake_opencode.py tests/test_security_api.py tests/security/test_units.py tests/security/test_ledger_units.py tests/security/test_orchestrator.py tests/security/test_finish_units.py tests/security/test_cli_units.py tests/security/test_cli_doors.py -p no:cacheprovider -q
python3.13 -m pytest tests/test_page_contract.py -k "retry or offers_resume or pipeline or usable" -p no:cacheprovider -q
AGENTLOOP_SELFTEST_E2E=separate GITHUB_ACTIONS=true bash bin/agentloop selftest > "$TMPDIR/st.log" 2>&1; grep -E '^  FAIL' "$TMPDIR/st.log"; tail -3 "$TMPDIR/st.log"
E2E_LISTS=4 bash test/e2e.test.sh
```

Esperado: tudo verde; no selftest, só a linha esperada do interruptor de CI.

- [ ] **Step 4: Commit, push e PR**

```bash
git add README.md docs/superpowers/specs/2026-09-26-security-analysis-recovery-design.md
git commit -m "docs(security): retry, start failures and the breaker in the README; spec amendments"
git push -u origin fix/security-analysis-recovery
```

Abrir o PR contra `main` com o título
`fix(security): a start failure no longer burns an analysis, and a failed one can be retried`.
O corpo, em inglês, resume as três camadas, cita a medição 39, lista os
comandos da Step 3 com o resultado de cada um e diz, numa linha própria:
**the four suites were NOT run: only the files that cover the changed
code.** Nada de atribuição a agentes. O merge é do operador.

---

## Depois do merge (fora deste plano, pelo operador)

- Actualizar o checkout instalado entre runs (`git pull --ff-only` e
  `launchctl kickstart -k gui/$(id -u)/com.agentloop.server`); nenhum plist
  muda.
- `agentloop security retry <projecto> <id>` na análise do incidente: as 231
  verificações correm no commit original. É a aceitação em produção.
