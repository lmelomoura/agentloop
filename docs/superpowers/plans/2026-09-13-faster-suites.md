# Suites mais rápidas: plano

Desenho: [`../specs/2026-09-13-faster-suites-design.md`](../specs/2026-09-13-faster-suites-design.md).

Quatro tarefas, dois PRs. A Tarefa 1 sozinha no primeiro (ganho imediato,
risco nulo, nada de testes tocados); as Tarefas 2 a 4 no segundo.

## Global Constraints

- **Nenhum teste muda de significado.** Esta entrega muda **onde** e **quando**
  um teste corre, nunca o que ele afirma. Um teste que precise de ser alterado
  para passar em paralelo é um teste que estava a depender da ordem — e isso
  regista-se e discute-se, não se remenda.
- **Os números não podem descer.** selftest **850**, e2e **181**, pytest
  **608**, security **1038** (nesta máquina, `main` em `6e29b52`). Fixar os
  quatro no arranque, antes de tocar em nada, e comparar no fim de cada tarefa.
- **Bash 3.2:** sem `wait -n`, sem arrays associativos, sem `${var,,}`. A
  espera por vários filhos faz-se com `wait <pid>` num ciclo sobre uma lista
  de PIDs guardada numa variável com espaços, e o resultado de cada
  trabalhador passa por **ficheiro**, não por variável — um subshell não
  devolve estado ao pai.
- **`E2E_WORKERS=1` tem de dar exactamente o comportamento de hoje**, na mesma
  ordem, com o mesmo output. É o modo de bissectar uma falha, e se divergir do
  sequencial deixa de servir para isso.
- **O CHANGELOG move-se com cada commit de código.**
- **Nunca `git add -A`.**
- **Nenhum home real** em ficheiro versionado.

---

## Tarefa 1: as três suites ao mesmo tempo (PR próprio)

**Cria:** `test/suites.sh`. **Muda:** `README.md` (a secção que hoje manda
correr as quatro em sequência), `CHANGELOG.md`.

Lança em paralelo, cada uma com o seu ficheiro de log:

1. `bash bin/agentloop selftest`
2. `python3.13 -m pytest tests --ignore=tests/security -p no:cacheprovider -q`
3. `TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true python3.13 -m pytest tests/security -p no:cacheprovider -q --deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on`

Espera pelas três, imprime **quatro** números — os três resultados mais o
`end-to-end suite (N checks)` extraído do log do selftest — e sai com ≠ 0 se
alguma falhar, imprimindo o `tail` da que falhou.

**O e2e NÃO é lançado à parte.** O selftest embute-o (`bin/agentloop` ~7807) e
corrê-lo outra vez é pagar 2m30 por nada — e é o que colidiria com o selftest
em `test/sandbox`. **Escrever isto em comentário no topo do script**, porque a
regra antiga ("nunca os dois ao mesmo tempo") vai levar alguém a "corrigir"
isto de volta.

**Verificar:** os quatro números iguais aos de referência; o tempo de parede
impresso e abaixo de 5 minutos; uma falha injectada de propósito em cada uma
das três faz o script sair ≠ 0 e dizer qual foi.

**Fim do primeiro PR.** Ganho: ~7m → ~4m30, sem um teste tocado.

---

## Tarefa 2: `lastrun` deixa de significar "o último"

**Muda:** `test/e2e.test.sh`.

```bash
lastrun() { tail -1 "$ROOT/data/runs.ndjson" 2>/dev/null; }
```

passa a

```bash
run_of() { grep -F "\"job\":\"$1\"" "$ROOT/data/runs.ndjson" 2>/dev/null | tail -1; }
```

(confirmar o nome exacto do campo no `runs.ndjson` antes de escrever o
padrão; se o id do job não estiver lá em texto, esta tarefa muda de forma e o
plano tem de o dizer em vez de improvisar).

Cada uma das 29 chamadas passa a nomear o seu job. **Ainda em sequência, ainda
um só `$ROOT`** — nada de paralelismo nesta tarefa. Só isto já torna cada
cenário auto-contido, que é bom por si: um cenário que leia "o último run"
lê o run de outro cenário no dia em que alguém insere um cenário no meio.

**Verificar:** 181 checks, na mesma ordem, com o mesmo output. Um `diff` entre
o output de antes e o de depois tem de ser **vazio**.

---

## Tarefa 3: medir, e repartir

**Muda:** `test/e2e.test.sh` (instrumentação temporária), e escreve o
resultado no plano ou numa nota na branch.

Antes de repartir, **medir cada cenário**: carimbar o instante de cada
cabeçalho `echo "N. …"` e calcular a duração de cada um dos 29, como foi feito
para o selftest.

Depois, quatro listas equilibradas **pela duração medida**, não pelo número de
cenários. Os que esperam pelo relógio (watchdog, `stop`, os 24 `sleep` que
somam 39 s) repartidos, nunca todos no mesmo trabalhador.

**As listas ficam escritas no ficheiro**, explícitas, com a duração medida ao
lado em comentário. Um cenário novo entra numa lista à mão — e isso é uma
funcionalidade, não uma chatice: obriga quem o escreve a olhar para o
equilíbrio.

**Verificar:** a soma das quatro listas = 29 cenários, sem repetidos e sem
faltas, afirmado por uma asserção e não por leitura.

---

## Tarefa 4: um sandbox por trabalhador

**Muda:** `test/e2e.test.sh`, `README.md`, `CHANGELOG.md`.

- `$ROOT` passa a `$E2E/sandbox-$w`, criado e limpo por trabalhador; o `trap`
  do `EXIT` limpa todos.
- Cada trabalhador corre a sua lista **em sequência**, escreve o seu output
  num ficheiro próprio, e o pai imprime-os **pela ordem das listas** no fim —
  não intercalados. Um output intercalado de quatro trabalhadores é ilegível e
  torna uma falha impossível de ler.
- Os PIDs numa variável com espaços; `wait` num ciclo; o veredicto de cada
  trabalhador **num ficheiro** (`$E2E/rc-$w`), porque um subshell não devolve
  estado.
- `E2E_WORKERS` (omissão 4 **só depois da Tarefa 4 provar as dez corridas
  limpas**; até lá, omissão 1).

**Portas e recursos:** verificar se algum cenário levanta um servidor numa
porta fixa — dois trabalhadores a fazê-lo colidem. Se houver, a porta passa a
derivar do número do trabalhador. **Procurar antes de escrever**, não depois
de um teste falhar às tantas.

**Verificar:**
- `E2E_WORKERS=1` → output idêntico ao da Tarefa 2, `diff` vazio;
- `E2E_WORKERS=4` → os mesmos 181 checks e a mesma lista de nomes de cenário
  (comparar as listas, não só o total);
- **dez corridas seguidas a 4, zero falhas**, antes de mudar a omissão;
- o tempo do e2e a 4 abaixo de metade do tempo a 1, impresso pela suite;
- e a bateria completa da Tarefa 1 a fechar abaixo de 3 minutos.

---

## Auto-revisão do plano

- **A Tarefa 1 é quase todo o retorno por quase nenhum risco.** Se só uma
  coisa deste plano for feita, é esta: 2m30 de parede por um script novo que
  não toca em nenhum teste.
- **A Tarefa 4 é onde se introduz flakiness**, e flakiness é pior do que
  lentidão: uma suite que falha uma vez em dez ensina toda a gente a carregar
  em "repetir", e a partir daí deixa de proteger. Daí as dez corridas limpas
  antes de mudar a omissão, e daí o `E2E_WORKERS=1` continuar a existir para
  sempre.
- **A estimativa dos ~55 s é minha e não está medida.** A Tarefa 3 mede-a. Se
  a realidade for 90 s, o ganho continua a valer a pena; se for 150 s, a
  Tarefa 4 não se justifica e para-se depois da 2, que já melhora os testes
  por outra razão.
