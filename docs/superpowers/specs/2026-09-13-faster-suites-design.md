# Suites mais rápidas: desenho

## Medido primeiro, porque a intuição estava errada

A hipótese inicial era "os 149 blocos do selftest são independentes e podiam
correr em paralelo". Um perfil bloco a bloco de `bash bin/agentloop selftest`
sobre `main` em `7543506`, com cada linha de output carimbada no instante em
que apareceu, diz outra coisa:

| | segundos | do selftest |
|---|---|---|
| **o e2e, embutido** (*a whole run, end to end*) | **176** | **65%** |
| `security_close_analysis()` | 11 | 4% |
| `cmd_security_analyze --detach` | 9 | 3% |
| `lock_take()` | 8 | 3% |
| os outros 145 blocos | 65 | 24% |
| **total** | **269** | |

**129 dos 149 blocos demoram menos de um segundo** e somam 25 s. Paralelizar
os 148 blocos que não são o e2e ganharia, no melhor caso, cerca de um minuto —
e o e2e, sequencial, continuaria a valer três. A alavanca não é o selftest; é
o **e2e**, que é um bloco só.

E há uma segunda medição, mais barata: as três suites que se correm no fim de
cada tarefa **não partilham nada entre si**. A de segurança usa `tmp_path`
(1 329 vezes) e nunca toca em `test/sandbox`; o pytest do servidor também não;
o único conflito conhecido — selftest contra o e2e avulso — deixa de existir
quando se percebe que o selftest **já embute** o e2e (`bin/agentloop` ~7807) e
que corrê-lo à parte é correr a mesma coisa duas vezes.

A bateria de hoje, corrida como o repositório manda:

| | sequencial (hoje) |
|---|---|
| selftest (com o e2e dentro) | 4m30 |
| pytest servidor | 0m30 |
| security | 2m05 |
| **parede** | **~7m** |

## Duas alavancas, por ordem de retorno sobre risco

### Alavanca 0 — as suites ao mesmo tempo umas com as outras

Não muda um teste. Muda a maneira de as **invocar**: um `test/suites.sh` que
lança as três em paralelo, recolhe os três resultados, imprime os quatro
números (selftest, e2e embutido, pytest, security) e sai com código ≠ 0 se
alguma falhar.

| | parede |
|---|---|
| hoje, em sequência | ~7m |
| previsto | ~4m30 (o máximo das três) |
| **MEDIDO, 2026-09-13** | **7m04 — ganho ZERO** |

**A previsão estava errada e a medição mata a alavanca.** Verifiquei que as
três suites não partilham *estado* e concluí daí que ganhariam tempo. Não
ganham: partilham o recurso que interessa. O selftest lança centenas de
processos e a suite de segurança corre quatro engines; a competir pela CPU, o
selftest estica exactamente o que as outras poupam. 424 s em paralelo contra
~420 s em sequência.

Fica escrito com o número para ninguém repetir a inferência: *não partilham
estado* não implica *ganham tempo juntas*.

O que sobra desta alavanca não é paralelismo, é a **duplicação**: o e2e estava
a ser corrido à parte por quem seguisse o README, e o selftest já o embute.
Deixar de o correr duas vezes poupa 2m30 reais a quem o fazia — e isso não é
paralelismo, é parar de fazer trabalho a dobrar.

Risco: praticamente nenhum. As suites já correm em processos separados com
sandboxes separadas; só passam a correr ao mesmo tempo. O que muda de
comportamento é a carga da máquina — três suites a competir por CPU — e o
único efeito medível disso é o tempo de cada uma esticar um pouco. A regra
"nunca o e2e ao mesmo tempo que o selftest" **continua verdadeira** e continua
escrita; é o e2e avulso que deixa de ser corrido.

### Alavanca 1 — o e2e em paralelo consigo próprio

O e2e são **29 cenários**, cada um a criar um job, a correr um stand-in, a
esperar pelo watchdog ou pelo `stop`, e a ler o resultado. Foi medido o que os
prende uns aos outros, e é pouco:

- **um único `$ROOT`** (`test/sandbox`), criado uma vez no arranque e limpo no
  `EXIT`;
- **`mkjob`** acrescenta cada job ao mesmo `config/jobs.json`;
- **`lastrun()`** é `tail -1 "$ROOT/data/runs.ndjson"` — *"a corrida que acabou
  de acontecer"*, que só faz sentido em sequência.

E o que **não** os prende: nenhum cenário reutiliza o job de outro (cada
`mkjob <id>` aparece uma vez), nenhum lê o estado de outro, e os 24 `sleep`
(39 s somados) são esperas por relógio de cada cenário, não sincronização
entre cenários. Os cenários são **independentes nos dados**; estão acoplados
só pela infraestrutura.

O desenho:

- **Um `$ROOT` por trabalhador.** N trabalhadores, cada um com o seu sandbox
  completo (`config`, `data`, `remote`, `work`), a correr o seu subconjunto de
  cenários **em sequência**. Dentro de um trabalhador tudo fica como hoje —
  `mkjob`, `lastrun`, a ordem. Entre trabalhadores nada se toca.
- **`lastrun` deixa de ser "o último" e passa a ser "o run deste job"**:
  `run_of <job-id>`, a filtrar `runs.ndjson` pelo id. É a única função que
  encerra a suposição de sequência, e cada cenário já sabe o id do seu job.
  Dentro de um trabalhador continua correcta; e torna cada cenário
  **auto-contido**, o que é melhor mesmo sem paralelismo.
- **A distribuição é estática e escrita**: quatro listas de cenários,
  equilibradas pela duração medida (os cenários do watchdog e do `stop`, com
  os seus `sleep`, repartidos e não todos no mesmo trabalhador). Estática
  porque é previsível e reproduzível; dinâmica poupava um minuto de
  afinação e custava a capacidade de repetir uma falha.
- **O selftest continua a chamar o e2e da mesma maneira** e a contar os
  `  ok ` do output. O paralelismo vive dentro do `test/e2e.test.sh`, atrás de
  `E2E_WORKERS` (omissão 4; `1` dá o comportamento de hoje, byte a byte, e é
  o que se usa para bissectar uma falha).

| | e2e sozinho | selftest (embute o e2e) | parede da bateria |
|---|---|---|---|
| antes | 305 s | ~270 s | ~7m |
| alavanca 0 (medida) | — | — | ~7m — sem ganho |
| **alavanca 1, MEDIDA** (4 trabalhadores) | **84 s** | **208 s** | **~6m** |

**O que foi entregue, com os números medidos (2026-09-13), não os estimados.**
O e2e sozinho caiu 3,6× (305 → 84 s), exactamente o que a partição previa.
Dentro do selftest a queda é menor (270 → 208 s), porque os quatro
trabalhadores partilham a máquina com o resto da suite — a estimativa de
~150 s estava optimista e fica aqui corrigida. A parede da bateria completa
fica em ~6 minutos, não nos 2m30 do título; o título é o que a spec queria e
esta tabela é o que ela conseguiu. A alavanca seguinte, se um dia for
precisa, é a suite de segurança (150 s, quatro engines) — não o selftest.

O tecto do e2e é o trabalhador mais lento, e o trabalhador mais lento é
limitado pelos `sleep` dos seus cenários — não pela CPU. Com os 39 s de
espera bem repartidos por quatro, cada um leva ~10 s de espera e ~35 s de
trabalho. Estimativa, não medição; **a Tarefa 3 do plano mede-a** antes de
fixar o número de trabalhadores por omissão.

## O que fica de fora, e porquê

- **Paralelizar os outros 148 blocos do selftest.** Somam 93 s, 129 deles
  abaixo de um segundo, e partilham um único `$tmp` com `$tmp/cfg` escrito em
  163 sítios. O custo de lhes dar sandboxes privadas e de os coordenar comia
  o ganho, e o ganho é um minuto. Fica medido para ninguém o voltar a propor
  sem medir.
- **A decomposição do motor** (spec de 2026-09-12) **não acelera nada** —
  8,5 ms por invocação, medidos — e está escrito lá. As duas entregas são
  ortogonais: uma é raio de alcance, esta é tempo de parede.
- **Encurtar os `sleep`.** Cada um está lá porque um watchdog ou um `stop`
  precisa de tempo de relógio para disparar; encurtá-los é tornar os testes
  flakey por definição. O paralelismo sobrepõe as esperas em vez de as cortar.
- **Um cache de resultados** entre corridas (só correr o que mudou). Precisa
  de saber que ficheiros influenciam que testes, e num selftest de bash que
  lê o próprio motor com `sed` a resposta honesta é "todos".

## Testes da mudança

- **Os mesmos 181 checks**, com `E2E_WORKERS=1` e com `E2E_WORKERS=4`, e o
  mesmo conjunto de nomes de cenário nos dois — uma asserção que compare as
  listas, para um cenário não cair de uma partição sem ninguém dar por isso.
- **Flakiness:** o e2e a 4 trabalhadores corrido **dez vezes seguidas**, zero
  falhas, antes de o 4 passar a omissão. Um teste paralelo que falha uma vez
  em dez ensina toda a gente a carregar em "repetir" e a partir daí a suite
  não protege nada.
- **A regra da parede:** o tempo do e2e a 4 tem de ser menor que a metade do
  tempo a 1, medido pela própria suite e impresso no fim. Se não for, a
  distribuição está desequilibrada e a Tarefa 3 não está feita.
- **O selftest embutido continua a contar os `  ok `** e a dar
  `end-to-end suite (181 checks)`.
- **`test/suites.sh`** sai com ≠ 0 se qualquer uma das três falhar, e imprime
  os quatro números mesmo quando uma falha — a que falhou, com o `tail` dela.
