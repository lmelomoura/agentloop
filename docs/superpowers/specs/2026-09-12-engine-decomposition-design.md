# Partir o motor: desenho

## Contexto

`bin/agentloop` tem 12 095 linhas. O número assusta mais do que devia, e a
primeira coisa que esta spec faz é desfazer a impressão errada, porque uma
refactorização feita pela razão errada corta no sítio errado.

| parte | linhas | do ficheiro |
|---|---|---|
| `cmd_selftest()` — a suite | 5 958 | **49%** |
| comentários | 3 609 | 30% |
| tudo o resto | ~3 500 | ~29% |

São 205 funções e **166 delas têm menos de 80 linhas**. O motor está bem
factorizado. O que existe são **duas concentrações**, e só duas:

- `cmd_selftest()`, com 5 958 linhas, metade do ficheiro;
- `run_job()`, com 1 201 linhas, a segunda maior e a única grande no caminho
  de produção.

E a premissa de "um ficheiro só" já é falsa: a linha 183 faz
`. "$BIN_DIR/worktree-lib.sh"` (49 KB), e ao lado já vivem `provision-lib.sh`,
`round-cap.sh`, `statusline-rate-limits.sh`, `bin/platforms/`, `bin/security/`.
Partir mais não inventa um padrão — continua um.

### O que NÃO é razão para fazer isto

**Velocidade.** O bash lê e analisa o ficheiro inteiro a cada invocação, e o
tick corre a cada minuto. Medido nesta máquina, 20 corridas de `bash -n`:

| | por análise |
|---|---|
| com a suite (12 095 linhas) | 16,5 ms |
| sem a suite (6 136 linhas) | 8,0 ms |

8,5 ms por invocação, ~12 segundos por dia de ticks. **Isto não justifica
tocar em nada** e fica aqui escrito para ninguém o usar como argumento.

A razão é outra e é só uma: **raio de alcance**. Uma tarefa que precisa de
mudar o lançamento de uma corrida abre hoje um ficheiro onde 49% do que lê
é código de teste, e a função que tem de mudar tem 1 201 linhas com quarenta
variáveis locais vivas ao mesmo tempo. O custo não é de CPU, é de quem lá
mexe — e mede-se em defeitos, não em milissegundos.

### O que também não resolve

Partir o ficheiro **não** evita a armadilha do bash 3.2 em que um `case`
dentro de `$( )` passa no `bash -n` e só parte a correr. Isso é da linguagem
e parte igual num ficheiro de cem linhas. O que a apanha é correr a suite.
Nenhuma parte deste desenho se justifica com esse argumento.

## Objectivo e âmbito

Duas mudanças, independentes uma da outra, nesta ordem:

1. **A suite sai do motor** para `test/selftest.sh`, carregada pelo verbo
   `selftest` no momento em que ele corre.
2. **`run_job()` perde três blocos** para funções nomeadas, escolhidas por
   terem interface pequena — não por tamanho.

Nada muda de comportamento. Nenhum ficheiro de configuração muda. A saída de
todos os comandos fica igual, byte a byte, e os quatro números das suites
ficam iguais: **selftest 730/0, e2e 99/0, pytest 552, security 1038**
(nesta máquina; 987 + 51 saltados numa sem os engines de segurança).

**Fora de âmbito:** partir o resto do motor em módulos temáticos, tocar em
`bin/agentloop-server`, tocar na UI, mudar `worktree-lib.sh`, e qualquer
alteração de comportamento por pequena que seja. Uma refactorização que
aproveita a boleia para corrigir uma coisinha deixa de ser verificável.

## 1. A suite sai do motor

### Porque tem de ser carregada, e não executada

A suite é de **caixa branca**: chama funções do motor directamente no mesmo
shell — `job_get` (27 vezes), `num` (25), `now_epoch` (22),
`platform_jobs_on` (21), `platform_check` (21), `resolve` (19),
`platform_bin` (12), entre outras. Um script executado à parte não as tem.
Portanto `test/selftest.sh` é **carregado** (`.`), como `worktree-lib.sh` já
é, e não executado.

Os três auxiliares `ok`, `bad` e `want` estão definidos **dentro** de
`cmd_selftest` (linhas 3404–3406) e vão com ela.

### A forma

`test/selftest.sh` contém `cmd_selftest()` inteira, verbatim, com o seu
cabeçalho e os seus comentários. No motor, no despacho do verbo:

```bash
selftest) . "$BASE_DIR/test/selftest.sh"; cmd_selftest "$@" ;;
```

`BASE_DIR` já existe (linha 24, `cd "$BIN_DIR/.." && pwd`) e já resolve
symlinks, porque `SELF` é o caminho real: a instalação é um symlink de
`~/.local/bin/agentloop` para dentro do checkout, portanto o ficheiro irmão
está sempre lá. É a mesma garantia de que `worktree-lib.sh` já depende.

**Carregamento preguiçoso, dentro do ramo do `case`.** Não no topo do
ficheiro: quem corre um `tick` não paga a análise de 6 000 linhas que nunca
vai executar. (E, como está escrito acima, isso vale 8 ms — a razão de o
fazer assim é não recriar o problema, não ganhar tempo.)

### O que pode partir, e a defesa

- **A suite não estar instalada.** Se alguém copiar `bin/agentloop` para fora
  do checkout, o verbo passa a falhar. Hoje falharia à mesma na primeira
  função de `worktree-lib.sh`, portanto não é regressão — mas a mensagem tem
  de dizer o que falta, não `No such file or directory`: um `[ -f … ] ||
  die "the selftest lives in test/selftest.sh, next to the checkout"`.
- **As asserções estruturais continuam a funcionar.** A suite lê o motor por
  caminho (`sed -n '/^run_job()/,/^}/p' "$BIN_DIR/agentloop"`) em pelo menos
  cinco sítios; ler um ficheiro que já não a contém não muda nada — o que ela
  procura continua lá.
- **O que a suite lê sobre si própria.** Se houver uma asserção que conte
  linhas do motor ou que procure texto dentro de `cmd_selftest`, muda de
  alvo. A tarefa procura-as antes de mover.

## 2. `run_job()` perde três blocos

### Porque três, e não onze

`run_job` tem, pelos seus próprios comentários, umas onze fases: resolver os
campos, as portas de recusa, montar o prompt, ranhuras e orçamento diário, o
precheck, a worktree, o ambiente, publicar o estado, montar o argv, lançar e
vigiar, e classificar o fim.

Parti-la nas onze seria pior do que deixá-la como está. O bash não devolve
valores: com quarenta locais vivos, onze funções significam onze contratos
de variáveis globais, e uma global que uma fase se esquece de reinicializar
**vaza para a corrida seguinte** — o `tick` corre vários jobs no mesmo
processo. Trocaríamos uma função grande e legível por onze pequenas e um
estado partilhado invisível. Isso é regressão disfarçada de arrumação.

A regra deste desenho é **interface pequena, não bloco grande**: só sai o que
comunica com o resto por poucos valores nomeados. Pelo mesmo critério com que
o motor já usa `PLATFORM_ARGV` e `PF_MODEL_ID`.

### Os três

| função nova | o que leva | entra | sai |
|---|---|---|---|
| `run_refusals` | as portas de recusa antes do lançamento (planned, unknown, disabled, sem modelo activado, not ready, as verificações do openai, modelo fora do catálogo) | `id`, `platform`, `model`, `permission`, `interactive` | 0 ou 1; a razão já escrita em `tick.log`, como hoje |
| `run_launch_and_watch` | o FIFO, o normalizador, o `exec` do CLI, o subshell do watchdog, o `wait`, a nota do normalizador | o argv já montado, o ambiente, `streamfile`, `logfile`, `stall`, `timeout` | `RJ_CHILD_RC`, `RJ_WATCHDOG_NOTE`, `RJ_NORMALIZER_RC` |
| `run_classify` | tudo depois do `wait`: filtro de stderr, `platform_finish`, o classificador, o tecto de orçamento, trabalho não entregue, o contrato de fim | `id`, `run_dir`, `streamfile`, `status` inicial | `RJ_STATUS`, `RJ_REASON` |

Três funções tiram à volta de **600 das 1 201 linhas** e cada uma tem um
contrato que cabe numa linha. O que fica em `run_job` é a espinha: resolver,
recusar, preparar, lançar, classificar, registar — legível de uma vez.

### A regra das globais, e como é imposta

Cada `RJ_*` é **inicializada pela função que a possui, na primeira linha**,
nunca assumida vazia. A suite passa a ter uma asserção estrutural — no mesmo
estilo das que já existem para `bind_session` e para a ordem do
BUDGET LIMITED — a exigir que cada `RJ_*` seja atribuída antes de ser lida
dentro da sua função. Uma global que vaze entre corridas é o único defeito
que esta refactorização pode introduzir, e é o único que não aparece num
teste de uma corrida só: o e2e passa a ter um cenário com **duas corridas
seguidas no mesmo processo**, a segunda a herdar o que a primeira deixou.

## Ordem, e porquê

**A suite primeiro, o `run_job` depois, em PRs separados.** A extracção da
suite não toca em código que corre numa corrida: se der problema, dá-o no
verbo `selftest` e vê-se de imediato. A do `run_job` toca no caminho crítico.
Misturá-las faria com que uma bissecção não distinguisse qual das duas partiu
a produção.

**Depois do merge do OpenCode.** As tarefas 4 e 5 dessa entrega mexem no
`run_job` e no despacho de plataformas. Fazer isto antes garante um conflito
em que as duas partes têm razão e ninguém sabe resolver.

## Testes

Não há testes novos de comportamento, porque não há comportamento novo. O que
há é prova de que nada mudou:

- **Os quatro números iguais**, antes e depois de cada uma das duas mudanças,
  em commits separados: selftest 730/0, e2e 99/0, pytest 552, security 1038.
- **`agentloop selftest` a partir de um symlink**, para provar que o
  carregamento resolve o caminho real e não o do symlink.
- **A mensagem quando `test/selftest.sh` falta**, a dizer o que falta.
- **Duas corridas seguidas no mesmo processo** no e2e, a apanhar uma `RJ_*`
  que vaze.
- **A asserção estrutural** de que cada `RJ_*` é inicializada pela sua dona.
- **`git diff --stat` da extracção da suite**: um ficheiro novo e um ramo de
  `case` mudado. Se o diff mostrar uma linha alterada dentro do corpo movido,
  a tarefa falhou — mover não é reescrever.

## Como este documento envelhece

Nenhuma âncora deste desenho é um número de linha, apesar de os citar como
medição. As tarefas ancoram em **nomes de função e em texto de comentário**,
porque o merge do OpenCode vai deslocar tudo. Os números aqui datam de
2026-09-12 sobre `main` em `7543506` e servem para dimensionar, não para
navegar.
