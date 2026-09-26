# Recuperação de uma análise de segurança: a unidade que não arranca e a análise que se retoma (design)

> **Origem (2026-09-26).** Uma análise `deep` de um projecto real (6 670
> ficheiros, 1 241 385 linhas, 8,36 USD) fechou `capped`. A leitura inteira
> ficou provada, mas 231 das 267 unidades de verificação desistiram «after 3
> attempts», e a nota de cada uma dizia apenas «The run left no stream». O
> operador: «Preciso de um plano para resolver isso e preciso que investigue
> melhor e além disso, quando falhar, preciso de uma forma de recomeçar.»

**Objectivo:** três garantias.

1. O sweep do tick nunca cria nada no lugar de um run dir.
2. Uma run cujo agente não chega a arrancar é chamada pelo nome, não gasta
   tentativas, e pára a análise cedo em vez de a queimar unidade a unidade.
3. Uma análise `capped` ou `failed` retoma-se correndo **só o que falhou**,
   no mesmo commit, sem refazer o que já está provado.

Evidência: medição 39 em `2026-09-12-opencode-measurements/` (o script, a
saída e o `meta`). Os nomes, caminhos e commits do projecto do operador estão
anonimizados: o repositório é público.

---

## O problema, medido

### A linha do tempo (UTC)

| hora | o que aconteceu |
|---|---|
| 25/09 20:31:41 | a análise é lançada |
| 00:37:27 a 00:51:02 | 36 unidades de verificação acabam `done`, cerca de 70 s cada |
| 00:50:13 | a unidade *verify 35* arranca no run dir `…Z-38238` |
| 00:51:11 | acaba `success`; o seu `run_cleanup` desmonta a árvore e liberta o slot |
| 00:51:12 | o tick regista `adopted …Z-38238 (no .ended, no .session found)`; no mesmo segundo nasce um **ficheiro regular de 0 bytes** nesse caminho, e o `launchd.err.log` guarda a falha do `printf 'open' > …Z-38238/.ended` (*No such file or directory*) |
| 00:51:19 em diante | cada arranque do OpenCode no projecto sai com rc 1 em cerca de 1 s: `BadResource: FileSystem.access (…Z-38238/<repo>)` |
| 00:51:13 a 01:33:06 | 693 runs (231 linhagens × 3), todas `status=error cause=killed turns=0 cost=$0` |
| 01:33:06 | a análise fecha `capped` com 231 achados por verificar |

### As unidades no fecho

| tipo | `done` | `incomplete` | `failed` | custo |
|---|---|---|---|---|
| triage | 4 | 2 | 0 | 0,12 USD |
| hunt | 1 | 0 | 0 | 0,07 USD |
| read | 277 | 15 | 0 | 7,98 USD |
| verify | 36 | 462 | 231 | 0,20 USD |

As 693 runs falhadas custaram 0 USD e cerca de 9 s cada (a maior parte a
montar a árvore). O custo real foi outro: cada uma deixou a sua árvore no
disco, marcada `open` para uma retoma que nunca viria (o motor da altura
guardava a árvore de uma unidade falhada durante as 24 h do TTL). Eram 700
árvores de 371 MB cada, **cerca de 254 GB**, com 700 registos em
`.git/worktrees` do repositório analisado.

### A cadeia

**1. O gatilho: uma corrida no sweep do tick.** `wt_prune_orphans`
(`bin/worktree-lib.sh`) testa `[ -d "$d" ]` **antes** de tomar o lock
`.resume`, e `_wt_prune_one` não volta a testar depois de o ter. Uma unidade
que desmonta a árvore e liberta o slot dentro dessa janela chega ao ramo da
adopção com a directoria já apagada:

- `wt_is_claimed` diz que ninguém a reclama (o slot já foi libertado);
- não há `.ended` nem `.session` (a directoria já não existe);
- o `printf 'open\n' > "$d/.ended"` falha;
- `touch "$d"` **cria um ficheiro regular vazio** no caminho.

A janela não é de microssegundos. O `.resume` é tomado também por cada
`run_job` ao arrancar (o reattach), pelo `security_unit_sweep` e pelo
`worktree drop`. O orquestrador lançou unidades nesses mesmos segundos, e o
sweep esperou pelo lock com o resultado do `-d` já velho. Depois, o sweep
salta tudo o que não é directoria (`[ -d "$d" ] || continue`), e o ficheiro
fica ali para sempre.

**2. O amplificador: o OpenCode 1.18.30.** O OpenCode identifica um projecto
pelo seu commit raiz, por isso todos os worktrees do repositório analisado
são **um** projecto. Cada directoria onde arranca é acrescentada a
`project.sandboxes` na base do operador (`~/.local/share/opencode`), e cada
arranque verifica-as todas com `access`. A medição 39 prova o resto:

- um sandbox que desapareceu (ENOENT) é tolerado e podado;
- um sandbox cujo **pai é um ficheiro** (ENOTDIR) dá `BadResource`, e o
  arranque sai com rc 1 antes de existir sessão, em **qualquer** checkout do
  projecto, incluindo o do próprio operador, fora do agentloop.

Centenas de árvores de unidades já tinham sido desmontadas sem efeito
nenhum. Bastou uma transformada em ficheiro.

**3. A queima: o orquestrador não tem disjuntor.** Uma run sem stream é uma
tentativa perdida (`units.close`, `NO_STREAM_NOTE`). O orquestrador conta as
falhas por linhagem (3), nunca pela análise. Um problema do ambiente, igual
para todas as unidades, consumiu assim as três tentativas de cada uma das
231 linhagens que faltavam, em 42 minutos.

**4. O diagnóstico escondido.** O classificador (`run_classify`) chama
`killed` a um agente que saiu sozinho com rc 1 (`no_result_event`). O stderr,
onde estava a causa exacta, só ficou no índice. A nota da unidade e a do
fecho dizem «left no stream».

**5. Sem recomeço.** Só uma análise `interrupted` volta a `running`
(`ledger.resume_analysis`). `capped` e `failed` são estados finais: a única
saída seria uma análise nova, que repete 4 horas e 8 USD de leitura, quando
só a verificação falhou.

---

## Remediação já aplicada (2026-09-26, fora do código)

- O tick foi descarregado do launchd (`bootout`) durante a limpeza. Remover
  directorias com o tick ligado é exactamente a corrida acima. O tick que
  estava a meio morreu e deixou o lock `.resume` com um pid morto, que o
  próximo `lock_take` quebra.
- Os 700 run dirs e o ficheiro de 0 bytes foram removidos (174 s).
  `git worktree prune` limpou os 700 registos (um `--dry-run` antes não tinha
  nada para podar). O disco livre passou de 257 GiB para 516 GiB.
- O tick foi recarregado e um ciclo manual acabou com rc 0.
- O OpenCode, sobre um clone APFS da base real e no checkout do próprio
  operador: rc 0, e os 10 sandboxes obsoletos podados para 0. A base real
  cura-se no próximo arranque.
- A análise continua `capped`. Será a primeira a usar o `retry` (secção 6).

---

## Decisões

- **Corrigir na origem, parar cedo, retomar o que falhou.** Aprovado pelo
  operador, que escolheu retomar o que falhou em vez de recomeçar do zero.
- **A falha de arranque segue o caminho que um outage do provider já tem.**
  Mantém a tentativa e conta para desistir da linhagem, em vez de voltar a
  correr o mesmo id: o orquestrador proíbe correr de novo uma unidade cuja
  run lançou um agente, e a regra dos outages já é a que o fecho e a retoma
  sabem contar.
- **O disjuntor é um gate do orquestrador.** Pára os lançamentos, espera o
  que está em voo e deixa a análise `interrupted`, com a frase a dizer
  porquê. O caminho é o que um gate de gasto já percorre hoje. O tick não a
  retoma sozinho, porque nenhum orquestrador morreu.
- **O retry acrescenta, não reescreve.** Cada linhagem cuja última unidade
  está `failed` ganha uma unidade filha nova (tentativa 1). A folha antiga
  fica `failed`, como história. O fecho já julga cada linhagem pela sua
  última unidade (`units._lineages`), por isso não precisa de mudar.
- **Mesmo commit.** Um retry termina a análise que existe. Quem quer o HEAD
  actual abre uma análise nova.
- **Fica de fora:** isolar o estado do OpenCode por análise (ver o fim).

---

## Desenho

### 1. O sweep nunca cria um caminho

- Em `_wt_prune_one`, com o `.resume` tomado e logo depois do
  `wt_is_claimed`: `[ -d "$d" ] || return 0`. Depois do dono, nunca antes:
  o `run_cleanup` remove a árvore e só depois liberta o slot, por isso, sem
  dono, uma desmontagem que estivesse em curso já acabou e esta resposta é
  final.
- Na adopção, `touch -c "$d"`: no `touch` do macOS, `-c` nunca cria o
  ficheiro. As escritas dos marcadores calam o erro de verdade
  (`{ printf …; } 2>/dev/null`): hoje o erro do redireccionamento escapa ao
  `2>/dev/null` e vai parar ao `launchd.err.log`.
- `security_unit_sweep` tem a mesma forma (testa `-d`, toma o lock, escreve
  `.ended`). Recebe a mesma re-verificação sob o lock. Hoje é inofensivo,
  porque só escreve dentro de `$d`, mas o padrão fica igual nos dois sweeps.
- Uma auditoria no plano confirma que nenhum outro `touch`, `mkdir -p` ou
  `: >` sobre um caminho de run dir fica fora de `wt_setup`.

### 2. Os sweeps limpam o que sobrou

Uma entrada de `WORKTREES_DIR/<job>/` que não é directoria, cujo nome tem a
forma de um run dir (`AAAAMMDDTHHMMSSZ-<pid>`) e que é um ficheiro regular
vazio, só pode ser o resto de uma directoria removida. Os dois sweeps
removem-na e escrevem uma linha no `tick.log`:

```
<job>: removed a stray empty file where run dir <name> was
```

Os ficheiros de rascunho `.<stamp>.tsv` começam por ponto, não têm essa
forma e nunca são tocados. Qualquer outra coisa com a forma de um run dir
(um ficheiro com conteúdo, um symlink) fica onde está, sem ruído, porque não
foi o motor que a criou. Um motor actualizado cura assim, no primeiro tick,
um caminho que uma versão anterior tenha envenenado.

### 3. Uma falha de arranque tem nome

Uma run é **`start_failed`** quando tudo isto é verdade:

- terminou `error`;
- o agente saiu por si: nem stop (`$slot/stopped`) nem motivo do watchdog;
- o código de saída do agente é diferente de 0;
- o stream tem zero eventos e não se capturou nenhum id de sessão.

A razão é a última linha não vazia do stderr do agente, sem códigos ANSI e
com no máximo 300 caracteres. No caso medido:
`BadResource: FileSystem.access (<sandbox>)`.

- `run_classify` passa a devolver `cause=start_failed` com essa razão. O
  `tick.log` mostra
  `finished status=error cause=start_failed … — START FAILED: <razão>` (a
  linha já acaba em `— $wdreason`), e a razão
  vai para a `note` do registo da run e para o diálogo da run no dashboard.
- A definição só usa o stream, o código de saída e o stderr, por isso vale
  igual para as três plataformas.
- Um agente morto pelo watchdog continua `killed`. Um stop continua
  `stopped`. Um erro da API continua `api_error` ou `rate_limited`.

### 4. Uma falha de arranque não gasta tentativa

- `units.close` trata `start_failed` como já trata `OUTAGE_CAUSES`: a
  continuação mantém a tentativa. A evidência fica
  `{"stream": "none", "cause": "start_failed", "error": "<razão>"}` e a nota
  diz: «The agent could not start (<razão>); nothing ran, so the attempt is
  kept.»
- O `_outages_before` do orquestrador conta os antecessores seguidos cuja
  causa está em `OUTAGE_CAUSES` ou é `start_failed`. Ao fim de
  `LAUNCH_STRIKES` seguidos, a unidade é dada como `failed`, com uma nota que
  nomeia a causa e a razão.
- Isto é seguro: uma run sem stream já é desqualificada (nada do que fez
  conta, secção «NO STREAM, NOTHING COUNTS» de `units.close`). Manter a
  tentativa só deixa de castigar a unidade por uma falha do ambiente.

### 5. O disjuntor

- O orquestrador guarda, em memória, uma sequência de falhas de arranque.
  Cada unidade fechada com `start_failed` soma 1 e regista a sua linhagem.
  Qualquer outro fecho de unidade, seja qual for o resultado, zera a
  sequência: o agente arrancou, por isso o ambiente funciona.
- Com `START_FAIL_BREAKER = 3` seguidas, em pelo menos 2 linhagens
  diferentes, o orquestrador fecha o seu gate com a frase:
  «the agent could not start: 3 units in a row ended before a session
  opened (last error: <razão>)». O orquestrador não conhece a plataforma.
- A partir daí é o caminho dos gates que já existe: não lança mais, espera o
  que está em voo, `_interrupt(GATE_NOTE…)`, e a análise fica
  `interrupted` com a frase na nota. O `tick.log` ganha
  `<job>: analysis <id> — stops launching: <frase>`.
- Um **Resume** (o botão ou `agentloop security resume`) continua a análise
  com a sequência a zero. Se a causa persistir, o gate volta a fechar ao fim
  de uma vaga, sem custo e sem gastar tentativas. O tick não a retoma
  sozinho, porque só retoma análises cujo orquestrador morreu.
- Uma única unidade que nunca arranca não fecha o gate (é uma linhagem só):
  desiste ao fim de `LAUNCH_STRIKES` falhas (secção 4), com a razão na nota,
  e o `retry` pode voltar a corrê-la depois.
- Com o paralelismo por defeito (3), uma falha sistémica fecha o gate na
  primeira vaga: 3 runs, 3 linhagens, 1 falha cada, cerca de 10 s depois do
  primeiro lançamento. Nenhuma linhagem chega a desistir.

### 6. Retomar o que falhou (`retry`)

**No ledger:** `reopen_analysis(conn, analysis_id)`, numa só transacção:

- só a partir de `capped` ou `failed`;
- só a análise mais recente do seu âmbito: o mesmo `(project, repo,
  branch)` com que uma análise nova já ultrapassa uma `interrupted`
  (`cmd_open_analysis`), sem nenhuma linha mais nova. Caso contrário, recusa
  com «a newer analysis of this scope exists; run Analyse again»;
- só se houver pelo menos uma linhagem cuja última unidade está `failed`.
  Caso contrário, recusa com «nothing failed: there is nothing to retry»
  (uma análise `capped` só pelo orçamento cai aqui);
- para cada uma dessas folhas, uma unidade nova `pending` (mesmo tipo e
  payload, tentativa 1, `parent` = a folha);
- o estado passa a `interrupted` e `ended` volta a vazio. O registo do
  reopen é a frase `Retried on <dia>: <n> units that had given up were run
  again.` na nota e uma linha no `tick.log`; um tipo novo de evento
  obrigaria a mexer no vocabulário da Activity em quatro sítios.

**O fecho de uma análise retomada descreve o estado final.** As frases das
lacunas do fecho anterior («231 units gave up…») não podem ficar coladas à
nota nova. O plano verifica como o `finish --from-units` compõe a
`coverage_note` e garante que as frases das lacunas são recalculadas, nunca
somadas.

**No motor:** `agentloop security retry <projecto> <analysis-id>`, com as
mesmas recusas que o `resume` (um orquestrador vivo, unidades ainda a
terminar). Depois: `reopen`, `resume`, `security_launch_detached`, e uma
linha no `tick.log`
(`<job>: retried analysis <id>: <n> failed units run again`). Imprime
`{"analysis_id": <id>, "retried": <n>}`.

**No servidor:** a operação `security_retry`, ao lado da `security_resume`.
O JSON de cada análise ganha `retryable: <n>` (0 quando o retry seria
recusado). É calculado pela mesma função Python que o ledger usa para
decidir, para que o botão e a recusa nunca discordem.

**No dashboard:** no cartão de uma análise com `retryable > 0`, um botão
**Retry failed units**, com uma confirmação que diz o que vai acontecer:
«Runs again only the <n> units that failed, on commit <sha>. Everything
already done stays done.»

**Orçamento:** o retry não mexe no orçamento. Com orçamento, as unidades
recebem a sua parte como numa análise normal.

### 7. A análise do incidente

Com isto em produção:
`agentloop security retry <projecto> <id>` (ou o botão) corre as 231
verificações no commit original. É a aceitação em produção, feita pelo
operador.

---

## Invariantes

- Um sweep nunca cria nada em `WORKTREES_DIR`.
- O id de uma unidade corre no máximo uma vez (sem mudança).
- Uma run sem stream nunca credita nada (sem mudança).
- Uma unidade `done` nunca volta a correr.
- Uma análise fechada só muda de estado pelo `reopen`: disparado pelo
  operador, só na análise mais recente do âmbito, e registado na nota da
  análise e no `tick.log`.
- A retoma automática do tick nunca retoma uma análise que o disjuntor
  pausou.

---

## Testes

Só os ficheiros que cobrem o código mudado. As quatro suítes completas não
correm durante o ciclo de correcções, e o corpo do PR di-lo.

- **`test/selftest.sh`**, no bloco do `wt_prune_orphans`:
  - (a) a corrida, determinística: um run dir com um slot vivo; o teste toma
    o `.resume`; lança o `wt_prune_orphans` em segundo plano (passa o `-d` e
    fica à espera do lock); remove o run dir e liberta o slot; solta o lock.
    Espera-se nenhum ficheiro no caminho e nenhuma linha `adopted`. **Tem de
    falhar no código actual**;
  - (b) um ficheiro vazio com a forma de run dir é removido e registado; um
    `.x.tsv` e um ficheiro com conteúdo ficam;
  - (c) o mesmo par (a, b) para o `security_unit_sweep`.
- **`test/fake-opencode`**: um interruptor novo, `FAKE_OPENCODE_START_FAIL`,
  que escreve `Error: Unexpected error`, uma linha em branco e o valor do
  interruptor no stderr, e sai com 1 antes de qualquer evento.
- **O classificador** (selftest ou `tests/test_platform_runs.py`): o
  arranque falhado dá `cause=start_failed` com a razão; um kill do watchdog
  continua `killed`; um stop continua `stopped`.
- **`tests/security/test_units.py`**: um fecho com `start_failed` mantém a
  tentativa e guarda a razão.
- **`tests/security/test_orchestrator.py`**, com o `fake-engine`:
  - todas as unidades falham ao arrancar: a análise fica `interrupted`
    depois da primeira vaga, a nota tem a razão, nenhuma linhagem desiste, e
    não se lançam mais do que paralelismo + 2 runs (as vagas das primeiras
    falhas são reocupadas antes de a terceira chegar);
  - uma unidade falha ao arrancar e as outras correm: o gate não fecha, essa
    linhagem desiste ao fim de 3 com a razão, e a análise fecha `capped` a
    nomeá-la;
  - retomada com o ambiente corrigido: fecha `done`.
- **`tests/security/test_ledger_units.py` e `test_cli_units.py`**: o
  `reopen` planeia as filhas, não toca nas `done` e escreve o `event`;
  recusa uma análise a correr, uma `interrupted`, uma `done`, uma
  ultrapassada por outra mais nova e uma sem nada falhado. O fecho de uma
  análise retomada não repete as frases das lacunas antigas.
- **O motor**: uma unidade cujo agente não arrancou não deixa árvore (o
  comportamento do #89, fixado por um teste).
- **`tests/test_security_api.py`**: a operação `security_retry` e o
  `retryable`.
- **`tests/test_page_contract.py`**: o botão só aparece com
  `retryable > 0`, e a confirmação diz o número e o commit.

---

## Fica de fora, de propósito

- **Isolar o estado do OpenCode por análise** (um `XDG_DATA_HOME` do
  agentloop para as runs derivadas). Deixaria de sujar a base do operador (o
  incidente acrescentou-lhe 700 linhas de `project_directory` e 10
  sandboxes), mas mexe em credenciais (`auth.json`), binários descarregados
  e caches, e precisa de uma campanha de medição própria. Com as secções 1 a
  5, um caminho envenenado já não nasce e, se nascer por outra via, cura-se
  no tick seguinte e pára a análise ao fim de uma vaga. Fica como follow-up.
- **Uma sonda de arranque antes da primeira unidade.** O disjuntor já pára
  na primeira vaga (3 runs, cerca de 10 s, 0 USD). Uma sonda por plataforma
  seria código a mais para poupar segundos.
- **Retomar num commit mais novo.** Isso é uma análise nova.
- **Escrever na base do OpenCode.** Nunca. O motor só remove o que ele
  próprio criou.
- **Retomar sozinho depois do disjuntor.** Um problema do ambiente precisa de
  alguém que o resolva. Retomar em ciclo só repetiria a primeira vaga.

---

## Riscos

- **Uma run real classificada como `start_failed`** (um agente que trabalhou,
  mas cujo stream se perdeu por um defeito do motor). Não é castigada (mantém
  a tentativa) e, no pior caso, o disjuntor pausa a análise com o stderr na
  nota. Pausar é seguro, e a nota aponta para a causa.
- **Um retry de uma linhagem que falha por culpa própria** (uma verificação
  que nunca consegue concluir). Corre no máximo mais uma ronda de 3
  tentativas por retry, e cada retry é uma acção do operador.
