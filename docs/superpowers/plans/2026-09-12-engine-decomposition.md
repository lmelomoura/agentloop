# Partir o motor: plano de implementação

Desenho: [`../specs/2026-09-12-engine-decomposition-design.md`](../specs/2026-09-12-engine-decomposition-design.md).

Quatro tarefas, em **dois PRs**. A Tarefa 1 sozinha no primeiro; as Tarefas
2, 3 e 4 no segundo. A razão está na spec: a primeira não toca em código que
corra numa corrida, as outras tocam no caminho crítico, e uma bissecção tem
de as poder distinguir.

## Global Constraints

- **Nada muda de comportamento.** Nem uma mensagem, nem um código de saída,
  nem a ordem de duas linhas de log. Uma refactorização que corrige uma
  coisinha pelo caminho deixa de ser verificável, e a correcção deixa de ser
  revista. Se encontrares um defeito, **anota-o e não lhe toques**.
- **Mover não é reescrever.** Nos blocos movidos, o `git diff` só pode
  mostrar remoção num sítio e adição igual noutro, mais a mudança de
  indentação quando a houver. Se uma linha do corpo movido aparecer alterada,
  a tarefa falhou.
- **Bash 3.2:** sem arrays associativos, sem `${var,,}`, sem `mapfile`; um
  `case` (ou um apóstrofo num comentário) **dentro de `$( )`** parte em
  runtime e o `bash -n` passa à mesma. Validar a correr, nunca só a compilar.
  `local` em todas as variáveis de função.
- **Âncoras semânticas, nunca números de linha.** Este plano cita números
  medidos sobre `main` em `7543506` para dimensionar, mas navega por nomes de
  função e por texto de comentário: o merge do OpenCode desloca tudo.
- **O CHANGELOG move-se com cada commit de código** (o selftest falha quando
  o último commit que tocou `bin/`, `skills/` ou `test/` é mais novo do que o
  último que tocou `CHANGELOG.md`).
- **Nunca `git add -A` nem `git add .`** — há ficheiros `.before-*` e
  `.claude-flow/` por rastrear. Adicionar sempre por caminho.
- **Nenhum ficheiro versionado com um home real** (`/Users/<nome>`).
- **As suites no fim de cada tarefa**, em primeiro plano. O e2e **não se
  corre à parte**: o selftest corre-o lá dentro e conta os seus checks no
  total (correr os dois ao mesmo tempo colide em `test/sandbox`). A bateria
  toda é `bash test/suites.sh` (entrega dos testes rápidos, 2026-09-13), ou:

  ```bash
  bash bin/agentloop selftest
  python3.13 -m pytest tests --ignore=tests/security -p no:cacheprovider -q
  TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true python3.13 -m pytest tests/security -p no:cacheprovider -q --deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on
  ```

  **Os números têm de ficar iguais, não maiores.** Medidos a 2026-09-13 sobre
  `main` em `2962690`, antes da Tarefa 1: **selftest 858/0** (com os 181 do
  e2e lá dentro), **pytest 636**, **security 1109 + 1 deselected**. Os
  números de 12 de Setembro (730/99/552/1038) datam de antes da entrega
  OpenCode e das três entregas seguintes. Um número que suba sem uma tarefa
  ter acrescentado um teste é sinal de que alguma coisa mudou.
- **Pré-requisito:** o merge da entrega OpenCode. As tarefas 4 e 5 dessa
  entrega mexem no `run_job`. Não começar antes.

---

## Tarefa 1: a suite sai para `test/selftest.sh`

**Ficheiros:** cria `test/selftest.sh`; muda `bin/agentloop`, `CHANGELOG.md`,
`README.md` (a secção *Tests*, se disser onde a suite vive).

### Antes de mover

1. Procurar asserções que leiam a suite a si própria — as que contam linhas
   do motor ou procuram texto dentro de `cmd_selftest`:

   ```bash
   sed -n '/^cmd_selftest()/,/^}/p' bin/agentloop | grep -n 'cmd_selftest\|wc -l.*agentloop'
   ```

   As que lêem **outras** funções por caminho
   (`sed -n '/^run_job()/,/^}/p' "$BIN_DIR/agentloop"`, pelo menos cinco)
   continuam válidas e não se tocam. Uma que se leia a si própria muda de
   alvo para `$BASE_DIR/test/selftest.sh` e a tarefa di-lo no commit.

2. Guardar a saída de referência, para comparar no fim:

   ```bash
   bash bin/agentloop selftest > /tmp/selftest-before.txt 2>&1
   ```

### Mover

3. `cmd_selftest()` inteira — do `cmd_selftest() {` até ao `}` da coluna 0 —
   sai de `bin/agentloop` para `test/selftest.sh`, **verbatim**, com os três
   auxiliares `ok`, `bad` e `want` que vivem lá dentro.

   **Vão também `check_ui_artifact` e `check_ui_artifacts`** (decisão de
   2026-09-13, ao executar): reportam por `ok`/`bad`, que só existem dentro
   de `cmd_selftest`, portanto nunca foram chamáveis de mais lado nenhum —
   são suite, não motor. Ficam antes de `cmd_selftest` no ficheiro novo, na
   ordem em que estavam, e o teste `tests/test_page_contract.py` que fatiava
   o motor de `check_ui_artifact() {` a `cmd_selftest()` passa a fatiar
   `test/selftest.sh` com as mesmas âncoras.

4. `test/selftest.sh` começa com um cabeçalho que diz o que é e porque é
   carregado e não executado (em inglês, como todo o código):

   ```bash
   # The offline suite, carried out of bin/agentloop so that file is the engine
   # and not half test code. SOURCED, never executed: these checks call the
   # engine's own functions -- job_get, num, now_epoch, platform_check, resolve
   # -- in the engine's own shell, which a separate process would not have.
   # `agentloop selftest` sources this at the moment the verb runs, so a tick
   # never parses what it will never run.
   ```

5. O despacho do verbo, hoje `selftest)  cmd_selftest ;;`, passa a:

   ```bash
   selftest)
     [ -f "$BASE_DIR/test/selftest.sh" ] \
       || die "the selftest lives in test/selftest.sh, beside the checkout this binary links to"
     . "$BASE_DIR/test/selftest.sh"
     cmd_selftest ;;
   ```

   `BASE_DIR` já existe e já resolve o caminho real (`SELF` segue symlinks),
   que é a mesma garantia de que `. "$BIN_DIR/worktree-lib.sh"` depende.

### Provar

6. `diff /tmp/selftest-before.txt <(bash bin/agentloop selftest 2>&1)` —
   **vazio**. A suite tem de dizer exactamente o mesmo, linha a linha.
7. `git diff --stat`: um ficheiro novo, `bin/agentloop` a perder ~5 958
   linhas e a ganhar quatro. Nada mais. (Medido a 2026-09-13: perdeu 6 529 —
   a suite cresceu com as entregas entre os dois dias, e os dois verificadores
   de artefactos vão com ela — e ganhou 5: o ramo do `case` em cinco linhas.)
8. A partir de um symlink, para provar a resolução do caminho real:

   ```bash
   ln -sf "$PWD/bin/agentloop" /tmp/al-link && /tmp/al-link selftest | tail -2
   ```

9. Com o ficheiro escondido, para provar a mensagem:

   ```bash
   mv test/selftest.sh /tmp/ && bash bin/agentloop selftest; mv /tmp/selftest.sh test/
   ```

10. As quatro suites. Entrada no CHANGELOG a dizer o que mudou e o que custava
    não ter — *o motor era metade código de teste; quem ia mudar o lançamento
    de uma corrida lia 6 000 linhas que nunca correm numa corrida*.

**Este é o fim do primeiro PR.** Não continuar para a Tarefa 2 no mesmo ramo.

---

## Tarefa 2: `run_refusals`

A mais pequena e a mais segura das três. Faz-se primeiro para o contrato das
globais nascer num sítio onde é fácil de ver.

**Bloco:** das portas de recusa do operador — âncora, o comentário
*"The operator's own gates, before the CLI's: a planned platform, a"* — até
imediatamente **antes** do comentário *"Resolved once, after the gate, so the
binary that was checked is the"*. Inclui as verificações do ramo `openai` e
a do modelo fora do catálogo.

**Assinatura:** `run_refusals <id> <platform> <model> <permission> <interactive>`
→ 0 para seguir, 1 para recusar. A razão continua a ser escrita em
`tick.log` lá dentro, exactamente como hoje: o chamador não a reconstrói.

**No `run_job`:** `run_refusals "$id" "$platform" "$model" "$permission" "$interactive" || return 1`.

O `cli_bin` **fica em `run_job`**, depois da chamada. A ordem *porta → resolver
o binário → lançar* é uma decisão registada da entrega das Settings (o `bin`
do ficheiro seria decorativo se o lançamento usasse outra coisa) e não se
mexe nela.

**Provar:** as quatro suites; e a ordem das recusas, que o selftest já
exercita, tem de dar as mesmas mensagens pela mesma ordem.

---

## Tarefa 3: `run_launch_and_watch`

**Bloco:** de `local cli_pid="" normalizer="" rawfifo="" nrc=0` até
`wait "$child"; rc=$?` inclusive, mais a nota `normalizer exited N` que a
segue. Inclui o FIFO, o normalizador, o `exec` do CLI, o subshell do
watchdog e o laço interactivo.

**Entra:** o argv já montado (`PLATFORM_ARGV` ou o array do ramo), o
ambiente, `streamfile`, `logfile`, `stall`, `timeout`, `run_dir`.
**Sai:** `RJ_CHILD_RC`, `RJ_WATCHDOG_NOTE`, `RJ_NORMALIZER_RC`, `RJ_CHILD_PID`.

**Cuidado, e é o ponto desta tarefa.** Este bloco tem duas coisas que não
sobrevivem a um recorte distraído:

- **`bind_session` é chamado em dois sítios** e ambos são carregantes — a
  suite tem uma asserção estrutural a contá-los
  (`grep -c 'bind_session "\$run_dir"'` sobre o corpo do `run_job`). Depois
  de mover, essa asserção passa a contar sobre o corpo de
  `run_launch_and_watch`: **actualizar o alvo da asserção, não o número**.
- **O `stop` e o watchdog matam `$child`**, um PID que agora nasce dentro de
  outra função. `RJ_CHILD_PID` é publicado antes de o watchdog arrancar, não
  depois, ou há uma janela em que `agentloop stop` não encontra ninguém.

**Provar:** as quatro suites, e no e2e o cenário `stop` e o cenário `hang`
(que exercita o watchdog) — os dois casos em que este bloco falha de maneiras
que um run feliz não mostra.

---

## Tarefa 4: `run_classify`, e o guarda do estado partilhado

**Bloco:** de `platform_stderr_filter "$platform" "$logfile.err"` até ao fim
da classificação — o `platform_finish`, o classificador, o tecto
BUDGET LIMITED, a regra do trabalho não entregue e o contrato de fim.

**Entra:** `id`, `run_dir`, `streamfile`, `logfile`, `platform`, `session`,
`rc`. **Sai:** `RJ_STATUS`, `RJ_REASON`.

**A ordem é lei.** A suite já tem uma asserção estrutural que exige que a
regra do trabalho não entregue venha **depois** do BUDGET LIMITED, com um
comentário a explicar que a inversão é uma edição de uma linha que parece
limpeza inofensiva. Essa asserção passa a ler o corpo de `run_classify`:
actualizar o alvo, manter a exigência.

### O guarda das globais

Só esta refactorização pode introduzir um defeito, e é sempre o mesmo: uma
`RJ_*` que uma corrida deixa e a seguinte lê, porque o `tick` corre vários
jobs no mesmo processo. Duas defesas, ambas nesta tarefa:

1. **Cada função inicializa, na primeira linha, todas as `RJ_*` que possui.**
   `RJ_STATUS=""; RJ_REASON=""` e assim por diante — nunca assumidas vazias.
2. **Uma asserção estrutural** no estilo das que já existem: para cada `RJ_*`
   lida dentro de uma função, essa função tem de lhe atribuir valor antes.

   ```bash
   for fn in run_refusals run_launch_and_watch run_classify; do
     body="$(sed -n "/^$fn()/,/^}/p" "$BIN_DIR/agentloop")"
     for v in $(printf '%s\n' "$body" | grep -oE 'RJ_[A-Z_]+' | sort -u); do
       printf '%s\n' "$body" | grep -qE "^\s*$v=" \
         && ok "$fn initialises $v" \
         || bad "$fn reads $v without ever setting it — it will carry over from the previous run in the same tick"
     done
   done
   ```

3. **Um cenário e2e com duas corridas seguidas no mesmo processo**, a segunda
   a herdar o que a primeira deixou: um `tick` com dois jobs elegíveis, o
   primeiro a acabar em `warning` (o modo `dirty` do stand-in) e o segundo em
   `success`. Se uma `RJ_*` vazar, o segundo herda o estado do primeiro e o
   cenário apanha-o. **Sem este cenário a tarefa não está feita** — é o único
   teste que distingue esta refactorização de uma que parece funcionar.

---

## Auto-revisão do plano

- **A Tarefa 1 tem risco quase nulo e ganho grande**: metade do ficheiro sai
  e nada do que corre numa corrida muda. Se só uma coisa deste plano for
  feita, é esta.
- **A Tarefa 3 é a mais perigosa.** O `stop`, o watchdog e o FIFO são as três
  peças que já custaram defeitos a este repositório, e o PID do filho passa a
  atravessar uma fronteira de função. Se alguma tarefa for abandonada a meio,
  que seja esta — as Tarefas 2 e 4 valem por si.
- **Nenhuma delas é urgente.** O motor funciona. Isto é uma dívida de leitura,
  não um defeito, e o momento certo é logo a seguir a um merge, com a árvore
  limpa e sem nada em voo.
