# Análise de segurança em pipeline — a cobertura garantida pelo motor — design

> **Origem (2026-09-24).** Duas análises `deep` seguidas de um projecto real
> (~300 mil linhas versionadas) fecharam `capped`: a análise 20 (202 voltas,
> 36,9 min, 19,29 USD) e a 21 (185 voltas, 23,7 min, 18,32 USD). Nenhuma bateu
> num tecto: o projecto não tem orçamento, e as duas terminaram com
> `stop_reason: end_turn`. Foi o próprio agente que parou e fechou `capped`,
> porque o perfil `deep` promete «all versioned code» e ele não o leu todo. O
> operador: «Tenho que conseguir analisar qualquer projeto. Não quero
> remendos, quero funcionalidade a sério. Isso é uma ferramenta de segurança e
> tem de ser confiável.»

**Objectivo:** uma análise de segurança de **qualquer repositório, de
qualquer tamanho, em qualquer das três plataformas** cobre o âmbito do seu
perfil, e um `deep` lê cada ficheiro do âmbito do princípio ao fim. O `done`
passa a ser uma conclusão que o **motor** prova com base no que as sessões
realmente fizeram. Deixa de ser uma afirmação do modelo.

---

## O problema, medido

**Uma cabeça só.** Hoje uma análise é um processo: um agente, uma janela de
contexto e uma skill que lhe pede quatro trabalhos seguidos (re-verificar o
herdado, triar os scanners, o passe SAST, a verificação) e um `finish` no fim.
Tudo tem de caber nessa janela. Nas duas análises:

| | análise 20 | análise 21 |
|---|---|---|
| janela do modelo (`modelUsage.contextWindow`) | 1 000 000 | 1 000 000 |
| contexto na última volta | ~427 mil | ~392 mil |
| tokens relidos da cache (cada volta relê o contexto inteiro) | 52,7 M | 42,8 M |
| custo | 19,29 USD | 18,32 USD |
| fim | `end_turn` | `end_turn` |

**O âmbito não cabe lá.** Linhas versionadas do repositório, por tipo:
`src/` (PHP) 60,6 mil (2,1 MB), frontend 62 mil (2,4 MB), testes 57,8 mil
(2,0 MB), stubs 18,8 mil (0,7 MB), estilos 18,2 mil (0,5 MB). São ~7,7 MB de
código escrito à mão, mais de 2 milhões de tokens: o dobro da janela inteira.
Por cima, o «all versioned code» do `deep` ainda conta 10,9 MB de bundles
gerados em `public/`.

**E a skill proíbe a saída e abençoa a desistência.** «Subagents exist for
Job 4 and for nothing else» (por causa dos 51,44 USD da análise 9, que gastou
o orçamento em seis subagentes a partir o SAST e não triou nada). Na mesma
linha, a resposta a um passe que não chega a tudo é «a `capped` that says
plainly what was not looked at».

**A causa raiz não é o tamanho, é quem decide.** A completude depende do
julgamento do modelo sobre quando parar, dentro de um contexto que não chega
para o âmbito. Acima de ~1 M tokens de código um `deep` nunca pode ser
`done`. Abaixo disso, o `done` é a palavra do agente sobre o que leu. Nenhum
dos dois casos é aceitável numa ferramenta de segurança.

---

## Decisões

| Decisão | Porquê |
|---|---|
| **O motor planeia e garante; o modelo executa unidades** | A completude tem de ser propriedade do código e não de um julgamento. O `prepare` calcula o âmbito e parte-o em unidades de trabalho gravadas no ledger. O orquestrador corre cada unidade, verifica a prova e repete o que falta. Nenhum modelo decide quanto do âmbito cobrir. |
| **Uma unidade é uma sessão nova com um prompt cunhado pelo CLI e um âmbito fechado** | O contexto por sessão fica limitado ao tamanho da unidade, por isso não há tecto de tamanho. O custo passa a crescer em linha com o repositório, em vez de ao quadrado dentro de um contexto único. O prompt vem do ledger (o padrão do `verify-prompt` do 4.2), nunca de outro agente. |
| **Cada unidade corre como um run normal do job derivado** | Reaproveita o que já é fiável e testado: slot, `agentloop stop`, watchdog, diário, custo, classificador, transcrição e página do run. O `run_job` não muda por dentro. Ganha uma forma de receber o prompt da unidade e um fecho por unidade. |
| **Todas as unidades lêem o mesmo commit** | Uma análise `deep` pode durar horas, e o ramo pode avançar entretanto. Cada run de unidade é cortado do `commit_sha` gravado na abertura, nunca da ponta do ramo. Sem isto, a cobertura juntaria leituras de commits diferentes. |
| **Prova por unidade; o que falta repete-se sozinho** | Uma `read` tem de mostrar no stream cada intervalo lido. Uma `triage` tem de ter cada linha relida no ledger. Uma `verify` tem de ter veredicto. Uma unidade incompleta gera uma continuação só com o que falta, até 3 tentativas por linhagem. Só o que falha três vezes chega ao `capped`, com nome. |
| **O `done` é do motor** | Os agentes deixam de fechar a análise: `finish` entra no `AGENT_FORBIDDEN`. O orquestrador fecha com base nas unidades e nos guardas que já existem (`prepared`, triagem, fila de verificação), que ficam como defesa em profundidade. |
| **O âmbito do `deep` é um inventário determinístico** | Lista de ficheiros com linhas e bytes, e exclusões por regra explícita com contagens e exemplos na nota. `!defaults` em `ignore_paths` desliga as exclusões por omissão, como já faz ao filtro de ruído. |
| **Os subagentes voltam a fechar-se em todas as plataformas** | A distribuição passa a ser do motor. `Agent` fica fechado por flag no Claude Code, `task` fechado pela configuração de permissões no OpenCode, e o prompt proíbe `spawn_agent` no Codex. A protecção dos 51,44 USD fica mais forte, não mais fraca. |
| **A verificação passa a existir no Codex e no OpenCode** | Uma `verify` é uma sessão lançada pelo motor, sem precisar de subagentes. Hoje essas duas plataformas não verificam nada. |
| **O orçamento é por análise** | `max_budget_usd` passa a ser o tecto da análise inteira, controlado pelo orquestrador. Cada unidade é lançada com a sua fatia do que resta. `daily_budget_usd` continua a ser verificado em cada lançamento. |
| **O trabalho pago nunca se perde** | Um stop ou um crash deixa a análise `interrupted`, com as unidades feitas guardadas. A retoma continua do ponto onde ficou, e depois de um crash é automática (até 3 vezes). |
| **Paralelismo configurável** | `security.parallel` no bloco do projecto (1–8, 3 por omissão) passa a ser o `max_parallel` do job derivado. |

---

## Arquitectura

### O fluxo de uma análise

```
security analyze --detach
  └─ __run-analysis  (processo próprio, grupo próprio — como hoje)
       └─ security_orchestrate  (bash: env, lock da análise, sinais)
            └─ security orchestrate --analysis N  (Python, longo)
                 1. prepare (motor, todas as plataformas) → inventário + plano
                 2. ondas de unidades: triage · hunt · read  (até P em paralelo)
                 │     cada unidade = "$SELF" __run-unit <job> N <unit>
                 │                     └─ run_job (slot, stream, watchdog, custo…)
                 │                          └─ fecho da unidade: unit-close (prova)
                 3. continuações do que ficou por fazer (≤ 3 tentativas)
                 4. unidades verify, da fila de verificação final
                 5. finish (motor) → done | capped, com as lacunas nomeadas
```

### As unidades

| tipo | quando | o que leva (`payload`) | prova exigida |
|---|---|---|---|
| `triage` | sempre | até 25 linhas: todas as linhas dos scanners, de qualquer severidade (Job 2), e os achados do agente herdados em aberto da análise anterior (Job 1), cada uma com o fingerprint | cada linha com severidade ≥ `TRIAGE_FLOOR` relida pelo agente nesta análise (o predicado do `_untriaged`, restrito às linhas da unidade); cada achado herdado re-reportado. As linhas `low` e `info` vão no prompt mas não bloqueiam, como hoje |
| `hunt` | sempre | o perfil e os guias recomendados | o run classificado `success`; qualquer outro veredicto conta como tentativa falhada |
| `read` | só no `deep` | uma fatia do inventário: ficheiros ou intervalos de linhas | cada intervalo lido do princípio ao fim, provado pelo stream da própria unidade |
| `verify` | no fim | um fingerprint da fila de verificação | um veredicto gravado para esse fingerprint, por esta unidade |

**O `hunt` por perfil.** No `quick` e no `standard` é o passe de hoje: os
pontos de entrada e, no `standard`, as chamadas que se seguem a partir deles.
No `deep` fica limitado ao âmbito do `standard`, porque a exaustividade é das
unidades `read`. Leva o raciocínio que atravessa ficheiros: a rota numa
fatia, o sink noutra.

**Uma `read` pode sair da sua fatia.** Pode abrir outros ficheiros para
seguir um trace. A obrigação dela é a sua fatia, e as leituras de fora contam
na cobertura desses ficheiros como qualquer outra.

### O inventário do `deep` (no `prepare`)

Os ficheiros versionados do repositório da análise (`git ls-files`, no
commit da análise), com linhas e bytes, menos o que estas regras excluem,
**por esta ordem, e cada exclusão contada com o motivo e os três primeiros
exemplos**. As linhas de um ficheiro são o número de `\n`, mais uma se o
último byte não for `\n` (um ficheiro vazio tem zero linhas e nada a ler).

1. `ignore_paths` e o filtro por omissão (`ignores.ignored`, a mesma leitura
   que todas as fases já partilham);
2. árvores de dependências versionadas: `node_modules/`, `vendor/`, `.venv/`,
   `bower_components/`, em qualquer profundidade (a skill já diz «never read
   dependency trees»);
3. lockfiles, pelos nomes que `deps.py` já reconhece (a fase de dependências
   cobre-os);
4. binários e texto que não é UTF-8 (um NUL, ou falha a descodificar);
5. **gerados ou minificados:** nomes `*.min.js`, `*.min.mjs`, `*.min.css`,
   `*.map`, **ou** uma linha com mais de 2 000 caracteres (o limite a partir
   do qual o Read do Claude Code e o read do OpenCode cortam a linha, embora a
   contem como lida), **ou** um comprimento médio de linha acima de 300 bytes;
6. prosa: `.md`, `.markdown`, `.rst`, `.adoc`, `.txt` (excepto ficheiros que o
   inventário de dependências lê);
7. caminhos que nenhuma unidade pode ver (`unprintable-path`): um carácter de
   controlo (Cc, incluindo C1, ou U+2028/U+2029) ou um caminho tão longo que
   nenhum bloco do `security read` cabe ao lado dele.

`!defaults` desliga as regras 5 e 6, além do filtro de ruído que já
desliga. Nesse caso o inventário grava, por ficheiro, as linhas com mais de
2 000 caracteres (`wide`), e o juiz nunca aceita um resultado do Read como
prova de leitura dessas linhas: só o `security read` as prova. As regras 2, 3 e 4 ficam sempre: uma árvore de dependências é código
que ninguém aqui escreveu, um lockfile já tem a sua fase, e um binário não se
lê linha a linha. O inventário é gravado em
`analysis.scope` e resumido na linha `scope` da tabela de cobertura: ficheiros
e linhas no âmbito, e o excluído por motivo.

### As fatias

O inventário é ordenado pelo caminho (ficheiros da mesma pasta ficam juntos)
e enchido gulosamente em fatias até **300 000 bytes** (~85 mil tokens). Um
ficheiro maior do que isso é partido em intervalos de linhas de até
300 000 bytes cada, e cada intervalo é uma entrada de fatia por direito
próprio. Uma fatia é sempre uma lista de `(caminho, primeira_linha,
última_linha)`. A cobertura mede-se por linha, nunca por ficheiro inteiro.

### A prova de leitura (unidades `read`)

A cobertura sai do **stream da unidade**, nunca do que o agente diz:

- **Claude Code e OpenCode:** um `tool_use` de nome `Read` (o normalizador do
  OpenCode já traduz `read` para `Read`), com o caminho em `file_path` ou
  `filePath`, o início em `offset` (1 por omissão) e a quantidade em `limit`
  (2000 por omissão). **Só conta se o `tool_result` com o mesmo `tool_use_id`
  não for um erro**: um `Read` de um ficheiro inexistente não lê nada.
- **Codex:** um `Bash` normalizado cujo comando é exactamente uma de três
  formas, sobre um só ficheiro: `sed -n '<a>,<b>p' <f>`, `cat <f>` ou
  `nl -ba <f>`. O prompt da unidade no Codex diz qual usar. Outra forma não
  conta, e a nota da unidade diz porquê.
- Caminhos absolutos passam a relativos à raiz do run da unidade (o `cwd`
  que o motor passa ao fecho). Um caminho fora dessa raiz não conta.
- Um intervalo da unidade está coberto quando a união dos intervalos lidos
  desse ficheiro o contém.

### O fecho de uma unidade (`unit-close`)

Quando o run de uma unidade acaba, o `security_close_analysis` do motor
(agora ciente de unidades) chama `security unit-close --analysis N --unit K
--stream <f> --root <cwd> --status <estado do run> --spend <custo>`. O
comando avalia a prova do tipo da unidade e grava o resultado:

- `done`: prova completa;
- `incomplete`: prova parcial. Cria uma **continuação** (nova unidade,
  `parent` = esta) só com o que falta: os intervalos por ler, as linhas por
  triar, a verificação por fazer;
- `failed`: o run falhou (erro, watchdog, stop) e não há nada aproveitável
  (uma `read` parada a meio aproveita o que leu e fica `incomplete`).

Uma linhagem (a unidade original e as suas continuações) tem no máximo **3
tentativas**. À terceira falha, o que falta fica registado como lacuna final
da análise.

Uma unidade cujo stream mostre uma chamada `Agent`/`Task` fica `failed` nessa
tentativa, com a nota a dizê-lo, e repete-se com o mesmo payload (conta para
as 3 tentativas). O que os subagentes leram não conta: a distribuição é do
motor, nunca da sessão.

### O fecho da análise (`finish`, pelo motor)

Quando não há unidades pendentes nem a correr, o orquestrador chama
`security finish --analysis N --from-units`. A análise fica `done` **só** se:

1. o `prepare` correu (guarda de hoje);
2. todas as unidades estão `done`;
3. no `deep`, a união das provas de todas as unidades `read` cobre o
   inventário inteiro;
4. nenhuma linha dos scanners ≥ `TRIAGE_FLOOR` ficou por triar (guarda de
   hoje, agora também por unidade);
5. a fila de verificação está vazia e cada veredicto foi escrito pela
   unidade `verify` desse fingerprint.

Se alguma falhar, a análise fica `capped` e a nota diz exactamente o quê:
quantos intervalos ou ficheiros ficaram por ler, com os primeiros dez; que
linhas ficaram por triar; que achados por verificar; que unidades falharam e
porquê. Com o orçamento esgotado, a nota diz também quanto ficou por fazer.

### A tabela de cobertura

- **`scope`**: o inventário (ficheiros e linhas no âmbito; o excluído por
  motivo e exemplos).
- **`sast`**: o `hunt` e, no `deep`, «read in full: F of F files (L lines)
  across U units, R of them continued». `ran` só com cobertura completa.
- **`triage`** e **`verification`**: a partir das unidades desses tipos.
- **Guias lidos**: agregados dos streams de todas as unidades
  (`security_guides_read` por unidade).

---

## O que muda em cada peça

### Ledger (`bin/security/ledger.py`)

- **Tabela nova `unit`:** `id`, `analysis_id`, `seq`, `kind` (`triage` |
  `hunt` | `read` | `verify`), `payload` (JSON), `state` (`pending` |
  `running` | `done` | `incomplete` | `failed`), `attempt`, `parent`,
  `run_key`, `started`, `ended`, `spend_usd`, `evidence` (JSON com o resumo da
  prova), `note`.
- **Colunas aditivas em `analysis`:** `scope` (o inventário, JSON), `resumes`
  (quantas retomas automáticas).
- **Estado novo da análise, `interrupted`:** retomável. As transições estão
  abaixo, em «Stop, crash e retoma».
- A postura, o índice e os roll-ups continuam a ler só análises fechadas
  (`done`/`capped`). Uma `interrupted` conta como `running` para esses efeitos:
  ainda não é uma leitura.

### CLI (`bin/security/cli.py` e módulos novos)

- `bin/security/inventory.py` (novo): o inventário e as regras de exclusão.
- `bin/security/slices.py` (novo): as fatias e o corte por intervalos.
- `bin/security/evidence.py` (novo): a prova de leitura a partir de um stream
  normalizado (as três formas acima), a união de intervalos e a relativização
  dos caminhos.
- `bin/security/units.py` (novo): o plano, a máquina de estados, as
  continuações e o limite de tentativas.
- `bin/security/prompts.py`: ganha os prompts de `triage`, `hunt` e `read`
  (o de `verify` já existe e passa a ser usado pela unidade).
- **Verbos novos:** `plan` (dentro do `prepare`), `unit-prompt`, `unit-close`,
  `units` (lista e progresso), `orchestrate`, `resume`.
- **Portas:** `report-verdict` só aceita o veredicto de uma sessão cuja
  `AL_SECURITY_UNIT_ID` seja a unidade `verify` desse fingerprint. `finish`
  passa a `AGENT_FORBIDDEN`. `report-finding` regista a unidade que escreveu
  (`finding.unit`, coluna aditiva) para a auditoria.

### Motor (`bin/agentloop`)

- `__run-analysis` passa a correr `security_orchestrate`: toma o lock da
  análise (`$LOCK_DIR/<job>/analysis`, `mkdir` com pid e id da análise) e
  corre o orquestrador em Python.
- `__run-unit <job> <aid> <unit> <commit> <repo>` (novo, interno): o
  `security_run_analysis` de hoje, com `AL_SECURITY_UNIT_ID` exportado e
  `AL_BASE_OVERRIDE` apontado ao **commit da análise** (o `wt_base_ref` já
  resolve um valor cru com `rev-parse`), nunca ao ramo.
- `run_job`, num run de unidade: o prompt vem de `security unit-prompt`, e não
  do prompt estático do job derivado. O `prepare` do lado do motor deixa de
  correr aqui (corre uma vez, no orquestrador). O fecho chama `unit-close` em
  vez de `finish`.
- O job derivado ganha `max_parallel` = `security.parallel`, e
  `SECURITY_DISALLOWED_TOOLS` volta a `Agent`.
- `agentloop stop <job>` de um job de segurança também termina o orquestrador
  (o pid no lock da análise).
- `security analyze` recusa enquanto o lock da análise tiver um pid vivo, além
  do teste de slots que já faz. O sweep de análises mortas que o mesmo comando
  faz também passa a olhar para o lock. Entre duas unidades não há slot vivo,
  e sem isto o sweep fecharia uma análise que está a correr.
- `security_close_analysis` deixa de passar `--tasks-launched`: a contagem de
  subagentes passa a ser feita por unidade, no `unit-close`.
- O tick detecta análises `running` cujo lock tem um pid morto e sem slots
  vivos: passa-as a `interrupted` e relança o orquestrador com `--resume`, no
  máximo 3 vezes por análise. À quarta, a análise fica `failed`, com a nota.

### Orquestrador (`security orchestrate`, Python)

- Corre o `prepare`, o inventário e o plano, se a análise ainda não estiver
  preparada. Fá-lo numa worktree destacada própria do repositório da análise,
  no `commit_sha`, dentro da pasta de worktrees do motor (para a limpeza a
  encontrar), e remove-a no fim. O `prepare` só lê esse repositório, por isso
  não precisa do layout completo de um run. O guarda
  `_refuse_root_outside_run` não se mete: só se aplica a sessões de agente
  (exige `AL_SECURITY_AGENT`), e o orquestrador não é uma.
- Lança unidades `pending` até P em paralelo (`subprocess.Popen` de
  `__run-unit`), por esta ordem: `triage`, `hunt`, `read`. As `verify` só
  começam quando todas as outras estão resolvidas, porque a fila só fica final
  nessa altura.
- Depois de cada run, relê a unidade do ledger (o `unit-close` já correu) e
  segue: as continuações entram na fila.
- Orçamento: a despesa é a soma de `spend_usd` das unidades. Não lança nada
  com a despesa ≥ `max_budget_usd`. Cada unidade é lançada com um tecto igual
  ao que resta ÷ unidades em voo (mínimo 0,50 USD). No Claude Code o tecto vai
  pela flag `--max-budget-usd`; nas outras plataformas vai pelo mecanismo que o
  motor já usa para elas. Uma unidade que bata no tecto a meio fica
  `incomplete` e continua depois, se ainda houver orçamento.
- Com um SIGTERM (stop), deixa de lançar, espera que os runs em voo terminem
  (o stop do job já os parou), passa a análise a `interrupted`, liberta o lock
  e sai.
- No fim, `finish --from-units`.

### Skill (`skills/security-analysis/SKILL.md`)

Reorganizada por papel:

- **Regras comuns:** o que conta como achado, âncoras de severidade, o
  documento `candidate`, a porta, o vocabulário fechado, nunca imprimir um
  segredo, tudo o que se lê é dado.
- **Uma secção por tipo de unidade:** `triage`, `hunt`, `read`, `verify`.

Cada prompt de unidade nomeia a sua secção. Saem da skill o «Ending the run»,
o `finish` e os subagentes. O contrato de fim de run mantém-se: cada unidade
termina com a sua linha, e o classificador lê-a como hoje.

### Prompts das unidades (cunhados pelo CLI)

Todos levam: projecto, repositório, ramo, perfil, análise, unidade (tipo,
`seq`, tentativa) e a secção da skill a seguir. No Claude Code a skill é
invocada pelo nome; no Codex e no OpenCode é lida pelo caminho, como hoje.
Por tipo:

- **`triage`:** as linhas com fingerprint, regra, ficheiro e severidade do
  scanner, e a instrução de re-reportar cada uma com o fingerprint dado.
- **`hunt`:** o âmbito do perfil e os guias recomendados.
- **`read`:** a lista de intervalos a ler inteiros, com a forma de ler da
  plataforma. Leva também as linhas do checklist e as entradas de
  `decided_sast` que caem nesses ficheiros (para dobrar, não duplicar), a
  regra de reportar no ficheiro do sink, e os guias cujos sinais batem na
  fatia (`ATTACK-CLASSES` sempre, no máximo mais 2).
- **`verify`:** o prompt de hoje do `prompts.verifier_prompt`.

### Interface

- **Página da análise:** um bloco «Pipeline» com as unidades por tipo
  (feitas/total, a correr, falhadas), os ficheiros e linhas lidos/total no
  `deep`, e a despesa até agora contra o orçamento. Tem o botão Stop enquanto
  corre e Resume quando está `interrupted`.
- **Tabela de runs da segurança:** o estado `interrupted` («Interrupted») com
  Resume.
- **Página de runs do motor:** cada run de unidade com rótulo, por exemplo
  «analysis 22 · read 7/25».
- **A tabela de cobertura** mostra o que está descrito acima.

---

## Stop, crash e retoma

| de | acontecimento | para |
|---|---|---|
| `running` | fecho com todas as provas | `done` |
| `running` | fecho com lacunas (orçamento, 3.ª tentativa falhada) | `capped` |
| `running` | stop do operador | `interrupted` |
| `running` | orquestrador morto (reboot, crash) detectado pelo tick | `interrupted` (retoma automática) |
| `interrupted` | Resume (botão ou `security resume N`) ou retoma automática | `running` |
| `interrupted` | 4.ª retoma automática, ou uma análise nova do mesmo projecto, repositório e ramo | `failed` |
| `running` | o `prepare` falha | `capped` (guarda de hoje) |

Na retoma, as unidades `running` cujo run já não existe são avaliadas pelo
stream que deixaram, se deixaram. Se não deixaram, voltam a `pending`, na
mesma tentativa. As `done` nunca se repetem.

---

## Plataformas

As três correm o mesmo pipeline, porque cada unidade é uma sessão lançada
pelo motor. As diferenças ficam em dois pontos:

- a forma de ler e a sua prova (secção acima);
- o fecho dos subagentes: flag no Claude Code, permissões no OpenCode e prompt
  no Codex. No Codex uma chamada `spawn_agent` não aparece no stream
  normalizado, por isso lá a regra depende do prompt, como hoje.

---

## Testes

- **pytest (`tests/security/`):**
  - regras do inventário, uma a uma, com o motivo e os exemplos;
  - fatias: limite de bytes, agrupamento por pasta, ficheiro gigante partido
    em intervalos;
  - prova de leitura sobre **amostras reais capturadas** de cada plataforma:
    `Read` com e sem `offset`/`limit`, `Read` com erro, `read` do OpenCode,
    `sed -n`/`cat`/`nl` do Codex, caminhos fora da raiz;
  - máquina de estados: continuações só com o que falta, limite de 3
    tentativas, unidade com `Task` dada como falhada;
  - `finish --from-units`: `done` só com tudo provado e `capped` com cada
    lacuna nomeada;
  - orçamento: pára de lançar no tecto e divide o que resta;
  - portas: veredicto fora da sua unidade recusado, `finish` recusado a
    agentes;
  - retoma idempotente.
- **selftest:**
  - o run de unidade recebe o prompt da unidade e fecha com `unit-close`;
  - o stop termina o orquestrador e os slots;
  - o lock da análise;
  - `max_parallel` a partir de `security.parallel`;
  - o tick detecta um orquestrador morto e retoma, até 3 vezes.
- **e2e (`test/e2e.test.sh`, `test/fake-claude`):**
  - pipeline completo com duas `read`, uma `triage`, um `hunt` e uma
    `verify`: uma `read` salta um ficheiro na primeira tentativa, a
    continuação lê-o, e a análise fecha `done`;
  - stop a meio, `interrupted`, Resume e depois `done`.
- **Aceitação real:** um `deep` deste repositório em config e dados de
  rascunho (nunca o ledger vivo), com modelo real. Medem-se as unidades, o
  custo, o tempo e a cobertura completa. O `deep` do projecto grande fica para
  o operador correr depois de instalado.

---

## Entregue à parte

**O `index.db` guarda o princípio e o fim das transcrições longas.** Hoje
guarda os primeiros 2 MB (`slurp(..., STREAM_CAP)` corta `[:cap]`) e apaga o
ficheiro, e num run longo perde-se exactamente o fim: a decisão de parar, o
fecho. Passa a guardar o primeiro e o último megabyte, com uma linha marcadora
no meio. PR próprio (`fix/index-keeps-stream-tail`).

## Fica de fora, de propósito

- **Reaproveitar leituras de análises anteriores** para ficheiros sem
  alterações. Um fluxo vulnerável atravessa ficheiros, e um ficheiro que não
  mudou pode passar a ser vulnerável por causa de outro que mudou. Cada `deep`
  lê tudo.
- **Subagentes dentro de uma sessão.** Foram substituídos pelas unidades do
  motor, por todas as razões acima.
