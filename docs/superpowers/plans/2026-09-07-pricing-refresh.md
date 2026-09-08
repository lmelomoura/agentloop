# Preços e catálogo OpenAI actualizados sozinhos — plano B1.1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a tabela de preços OpenAI (`config/pricing.json`) actualiza-se sozinha a partir de uma fonte legível por máquina, na mesma cadência diária com que o catálogo de modelos se actualiza, e um modelo novo que apareça no catálogo do Codex fica com preço sem ninguém editar um ficheiro.

**Architecture:** o engine ganha `resolve_pricing_openai`, que lê a fonte por `curl`, converte de "USD por token" para "USD por milhão" e reescreve `config/pricing.json` linha a linha (uma linha `"source": "manual"` nunca é tocada; um slug que a fonte não tem mantém a última linha). Corre no mesmo trabalho diário destacado que já refresca o catálogo (`_resolve_models`, sob o mesmo lock), e a pedido como `agentloop resolve-pricing`; **nunca** dentro de um pedido HTTP nem de um lançamento. `agentloop platforms` e `/api/models` passam a dizer quando a tabela foi refrescada e que modelos visíveis estão sem preço. O catálogo de modelos **já** se actualiza sozinho: `codex debug models` refresca do servidor da OpenAI (cache em `~/.codex/models_cache.json`, com `fetched_at`) e o tick corre `resolve-models` a cada 24 h — este plano não muda isso, só garante que o slug novo chega com preço.

**Tech Stack:** bash 3.2, jq, curl (dependência já obrigatória), Python 3 stdlib no servidor, pytest em `python3.13`.

**Spec:** [`docs/superpowers/specs/2026-09-06-platforms-anthropic-openai-design.md`](../specs/2026-09-06-platforms-anthropic-openai-design.md), secção *Custos* — este plano substitui a frase "valores … confirmados pelo operador" por uma rotina. A decisão da fonte está abaixo.

## Factos medidos (2026-09-07)

- `https://openai.com/api/pricing/` devolve **403** a `curl` (com ou sem user agent de browser) e ao fetcher do harness: a página oficial não serve para automação. Foi lida de manhã por um caminho que hoje já não responde; os cinco preços lidos então são os da tabela actual.
- `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json` (2,3 MB, 229 entradas com `litellm_provider: "openai"`, última alteração upstream 2026-09-06) tem **todos** os slugs do catálogo do Codex, por token: `input_cost_per_token`, `cache_read_input_token_cost`, `cache_creation_input_token_cost`, `output_cost_per_token`, mais escalões (`_above_272k_tokens`, `_flex`, `_priority`, `_batches`) que **não** se usam. Serve `ETag` e honra `If-None-Match` (304). Convertidos a USD por 1M coincidem com a página da OpenAI nos cinco modelos: sol 4.00 / 0.40 / 20.00; terra 2.00 / 0.20 / 12.00; luna 0.20 / 0.02 / 1.20; gpt-5.5 5.00 / 0.50 / 30.00; gpt-5.4-mini 0.75 / 0.075 / 4.50.
- **A família 5.6 cobra a escrita de cache**: sol 5.00, terra 2.50, luna 0.25 por 1M (`cache_creation_input_token_cost`); gpt-5.5 e gpt-5.4-mini não têm o campo (0). A tabela actual diz `cache_write: 0` "porque a OpenAI não cobra" — estava errado para a 5.6; o `usage` do Codex traz `cache_write_input_tokens`, por isso a estimativa passa a usar o valor da fonte.
- `curl` lê URLs `file://` (é o que os testes usam; `%{http_code}` é `000` nesse caso).
- `codex debug models --help`: `--bundled` "Skip refresh and dump only the bundled catalog" — o modo normal **refresca** o catálogo remoto; `~/.codex/models_cache.json` tem `fetched_at`, `etag`, `client_version`, `models`.

## Global Constraints

- **Bash 3.2:** sem arrays associativos, sem `mapfile`; `case` dentro de `$( )` parte em runtime. Uma asserção do selftest dentro de `( … )` não reprova o gate: ou `ok`/`bad` ao nível de topo, ou o padrão `_upass/_ufail` + `RESULT ok=N bad=M` que o bloco `_rmout` já usa.
- **CHANGELOG na mesma commit** que toque `bin/`, `skills/` ou `test/`: a entrada vai sob `## [Unreleased]` → `### Added`, como bullet aninhado novo da entrada *The OpenAI platform, engine side*.
- **Sem rede nos testes:** todos os casos apontam `AGENTLOOP_PRICING_URL` a `file://…/test/fixtures/pricing/litellm-sample.json` (ou a um caminho inexistente / não-JSON para os casos de falha). Nenhum teste toca `~/.codex`, o `codex` real ou o `data/` real; `AGENTLOOP_CODEX_BIN=test/fake-codex` onde o catálogo for preciso.
- **Sem rede em caminhos quentes:** `resolve-models` (catálogo) continua sem preços — o servidor chama-o em síncrono quando o bloco falta; `openai_catalog_ensure` também. Só o trabalho diário destacado e `agentloop resolve-pricing` vão à rede. Timeout do `curl`: 30 s.
- **Nunca inventar um número:** uma linha só é escrita com valores numéricos vindos da fonte; a conversão é `valor × 1 000 000`, arredondada a 6 decimais (`((. * 1000000 * 1000000) | round) / 1000000`); `cached_input` ausente na fonte cai para o preço de `input` (sem desconto: sobrestima, nunca subestima, e fica anotado `cached_input_assumed: true`); `cache_write` ausente é 0.
- **Uma linha manual manda:** `"source": "manual"` numa linha de `config/pricing.json` nunca é reescrita. Uma linha que a fonte deixou de ter mantém-se como estava (com o seu `at` antigo).
- **Nomes, verbatim:** `PRICING_SOURCE_DEFAULT`, `AGENTLOOP_PRICING_URL`, `pricing_source_url`, `pricing_unpriced`, `resolve_pricing_openai`, `cmd_resolve_pricing`, `agentloop resolve-pricing`; chaves de topo `_source_url`, `_source_etag`, `_refreshed_at`, `_checked_at`, `_unit`, `_note`; por linha `input`, `cached_input`, `output`, `cache_write`, `source` (`litellm`|`manual`), `at`, opcional `cached_input_assumed`; em `platforms` e `/api/models`: `pricing_at`, `pricing_source`, `unpriced` (lista de slugs visíveis sem preço numérico); por modelo em `/api/models`: `price` (objecto com as seis chaves acima) ou `null`.
- **Suites no fim de cada tarefa** (uma linha cada, do worktree):

  ```bash
  bin/agentloop selftest
  python3.13 -m pytest -p no:cacheprovider tests/ -q --ignore=tests/security
  bash test/e2e.test.sh
  TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true python3.13 -m pytest -p no:cacheprovider tests/security -q --deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on
  ```

- **Branch:** `feat/pricing-refresh`, cortado de `main` (7334887). Código, comentários, commits e docs entregues em inglês; nunca o nome antigo do produto. Trailer: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

## Estrutura de ficheiros

| Ficheiro | Responsabilidade |
|---|---|
| `bin/agentloop` — bloco `# --- the price table ---` a seguir a `openai_catalog_ensure()` (T1) | `PRICING_SOURCE_DEFAULT`, `pricing_source_url`, `pricing_unpriced`, `resolve_pricing_openai`, `cmd_resolve_pricing`; `cmd_platforms` com `pricing_at`/`pricing_source`/`unpriced`; dispatch `resolve-pricing` e `_resolve_models` a chamar o refresh; `usage` |
| `test/fixtures/pricing/litellm-sample.json` (novo, T1) | um excerto da fonte com a forma real: quatro slugs do catálogo (um sem `cache_creation`), um slug de outro fornecedor, e **sem** `gpt-5.4-mini` |
| `bin/agentloop` — `cmd_selftest` (T1) | os casos do refresh: escrita, conversão, manual preservado, slug ausente mantido, falhas, `platforms` |
| `test/e2e.test.sh` (T1) | `AGENTLOOP_PRICING_URL` no topo; cenário 23 (`resolve-pricing` sobre a fixture) |
| `config/pricing.example.json`, `install.sh`, `README.md`, `CHANGELOG.md` (T1) | a tabela de exemplo com os valores da fonte (escrita de cache incluída) e metadados; a mensagem de semente; a secção *Platforms* → *Cost*, *Models*, *CLI* |
| `bin/agentloop-server` — `_openai_platform` (T2) | `pricing_at`, `pricing_source`, `unpriced`, e `price` por modelo |
| `tests/test_platforms_api.py` (T2) | os campos novos de `/api/models` |

---

### Task 1: A rotina no engine — `resolve-pricing`, o trabalho diário, a fixture, os casos, a tabela de exemplo, a documentação

**Files:**
- Modify: `bin/agentloop` (bloco novo depois de `openai_catalog_ensure()` ~L1456; `cmd_platforms` ~L7630; dispatch `_resolve_models)` ~L9917 e a linha nova `resolve-pricing)`; `usage` ~L9885; `cmd_selftest` depois do bloco `_rmout` ~L2866), `test/e2e.test.sh`, `config/pricing.example.json`, `install.sh`, `README.md`, `CHANGELOG.md`
- Create: `test/fixtures/pricing/litellm-sample.json`

**Interfaces:**
- Consumes: `PRICING_FILE`, `CONFIG_DIR`, `MODELS_FILE`, `JQ`, `now_epoch`, `num`, `log_tick`, `openai_catalog_slugs`, `openai_catalog_visible`, `openai_catalog_available`, `cmd_resolve_models` (existentes).
- Produces: as funções e nomes da lista *Nomes, verbatim*; a forma nova de `config/pricing.json`; os campos `pricing_at`, `pricing_source`, `unpriced` de `agentloop platforms` (T2 espelha-os no servidor).

- [ ] **Step 1: A fixture**

Cria `test/fixtures/pricing/litellm-sample.json` — a forma real da fonte, reduzida (os campos de escalões ficam num só slug para provar que são ignorados):

```json
{
  "gpt-5.6-sol": {
    "input_cost_per_token": 0.000004, "cache_read_input_token_cost": 4e-7,
    "cache_creation_input_token_cost": 0.000005, "output_cost_per_token": 0.00002,
    "input_cost_per_token_above_272k_tokens": 0.000008, "input_cost_per_token_flex": 0.000002,
    "litellm_provider": "openai", "mode": "chat", "max_input_tokens": 922000
  },
  "gpt-5.6-terra": {
    "input_cost_per_token": 0.000002, "cache_read_input_token_cost": 2e-7,
    "cache_creation_input_token_cost": 0.0000025, "output_cost_per_token": 0.000012,
    "litellm_provider": "openai", "mode": "chat"
  },
  "gpt-5.6-luna": {
    "input_cost_per_token": 2e-7, "cache_read_input_token_cost": 2e-8,
    "output_cost_per_token": 0.0000012,
    "litellm_provider": "openai", "mode": "chat"
  },
  "gpt-5.5": {
    "input_cost_per_token": 0.000005, "output_cost_per_token": 0.00003,
    "litellm_provider": "openai", "mode": "chat"
  },
  "gpt-reserve": {
    "input_cost_per_token": 0.000001, "cache_read_input_token_cost": 1e-7, "output_cost_per_token": 0.000002,
    "litellm_provider": "somebody-else", "mode": "chat"
  },
  "azure/gpt-5.4-mini": {
    "input_cost_per_token": 7.5e-7, "cache_read_input_token_cost": 7.5e-8, "output_cost_per_token": 0.0000045,
    "litellm_provider": "azure", "mode": "chat"
  }
}
```

(`gpt-5.5` sem `cache_read` prova o fallback `cached_input = input` com `cached_input_assumed`; `gpt-reserve` de outro fornecedor prova o filtro; `gpt-5.4-mini` está ausente de propósito.)

- [ ] **Step 2: Os casos do selftest, que vão falhar**

Em `cmd_selftest`, imediatamente a seguir às duas linhas que fecham o bloco `_rmout` (`printf '%s\n' "$_rmout" | grep -qx 'RESULT ok=15 bad=0' … || bad "…"`), inserir:

```bash
  echo "resolve_pricing_openai() — the price table refreshes itself from the source, never inventing a number"
  local _prout
  _prout="$(
    mkdir -p "$tmp/pr"
    CODEX_BIN="$BASE_DIR/test/fake-codex"
    CONFIG_DIR="$tmp/pr"
    MODELS_FILE="$tmp/pr/models.json"
    PRICING_FILE="$tmp/pr/pricing.json"
    TICK_LOG="$tmp/pr/tick.log"
    AGENTLOOP_PRICING_URL="file://$BASE_DIR/test/fixtures/pricing/litellm-sample.json"
    _upass=0; _ufail=0
    ok()  { _upass=$(( _upass + 1 )); printf '  ok    %s\n' "$1"; }
    bad() { _ufail=$(( _ufail + 1 )); printf '  FAIL  %s\n' "$1"; }
    resolve_models_openai >/dev/null                     # the catalog the slugs come from (fake-codex)
    # A table with one row the source does not carry (gpt-5.4-mini) and one the
    # operator wrote by hand (gpt-5.5, deliberately wrong so a rewrite would show).
    "$JQ" -n '{openai:{"gpt-5.4-mini":{input:0.75,cached_input:0.075,output:4.5,cache_write:0,source:"litellm",at:1},
                       "gpt-5.5":{input:9,cached_input:9,output:9,cache_write:0,source:"manual"}}}' > "$PRICING_FILE"
    resolve_pricing_openai >/dev/null; _rc=$?
    [ "$_rc" -eq 0 ] && ok "resolve_pricing_openai: a good source returns 0" || bad "rc $_rc"
    pr() { "$JQ" -r "$1" "$PRICING_FILE"; }
    [ "$(pr '.openai["gpt-5.6-sol"] | [.input,.cached_input,.output,.cache_write] | join(" ")')" = "4 0.4 20 5" ] \
      && ok "resolve_pricing_openai: gpt-5.6-sol is 4 / 0.4 / 20 per 1M, cache write 5 (per-token × 1M)" \
      || bad "sol row '$(pr '.openai["gpt-5.6-sol"]')'"
    [ "$(pr '.openai["gpt-5.6-luna"] | [.input,.cached_input,.output,.cache_write] | join(" ")')" = "0.2 0.02 1.2 0" ] \
      && ok "resolve_pricing_openai: gpt-5.6-luna keeps its small numbers exact and cache write 0 when the source lists none" \
      || bad "luna row '$(pr '.openai["gpt-5.6-luna"]')'"
    [ "$(pr '.openai["gpt-5.6-sol"].source')" = "litellm" ] && [ "$(num "$(pr '.openai["gpt-5.6-sol"].at')")" -gt 1 ] \
      && ok "resolve_pricing_openai: a written row names its source and when" || bad "source/at '$(pr '.openai["gpt-5.6-sol"] | [.source,.at]')'"
    [ "$(pr '.openai["gpt-5.5"] | [.input,.source] | join(" ")')" = "9 manual" ] \
      && ok "resolve_pricing_openai: a manual row is never overwritten" || bad "manual row '$(pr '.openai["gpt-5.5"]')'"
    [ "$(pr '.openai["gpt-5.4-mini"] | [.input,.at] | join(" ")')" = "0.75 1" ] \
      && ok "resolve_pricing_openai: a slug the source lacks keeps its last row" || bad "kept row '$(pr '.openai["gpt-5.4-mini"]')'"
    [ "$(pr '.openai["gpt-reserve"] // "absent"')" = "absent" ] \
      && ok "resolve_pricing_openai: an entry of another provider is not a price" || bad "gpt-reserve was priced: $(pr '.openai["gpt-reserve"]')"
    [ "$(num "$(pr '._refreshed_at // 0')")" -gt 1 ] && [ "$(pr '._source_url')" = "$AGENTLOOP_PRICING_URL" ] \
      && ok "resolve_pricing_openai: the table records when and where from" || bad "meta '$(pr '[._refreshed_at,._source_url]')'"
    [ -z "$(pricing_unpriced)" ] && ok "pricing_unpriced: every visible slug has a price (the kept row counts)" || bad "unpriced '$(pricing_unpriced | tr '\n' ' ')'"
    # gpt-5.5 has no cache_read in the sample: the manual row shields it here, so
    # test the fallback on a fresh table.
    "$JQ" -n '{openai:{}}' > "$PRICING_FILE"
    resolve_pricing_openai >/dev/null
    [ "$(pr '.openai["gpt-5.5"] | [.input,.cached_input,.cached_input_assumed] | join(" ")')" = "5 5 true" ] \
      && ok "resolve_pricing_openai: no cache price at the source → charged at the input rate, and said so" \
      || bad "5.5 row '$(pr '.openai["gpt-5.5"]')'"
    [ "$(pricing_unpriced | tr '\n' ' ')" = "gpt-5.4-mini " ] \
      && ok "pricing_unpriced: names the visible slug that has no row" || bad "unpriced '$(pricing_unpriced | tr '\n' ' ')'"
    grep -q 'pricing: no price for gpt-5.4-mini' "$TICK_LOG" \
      && ok "resolve_pricing_openai: and tick.log says so" || bad "no tick.log line: $(cat "$TICK_LOG" 2>/dev/null)"
    # Failure keeps the table exactly as it was, and says so.
    _before="$(cat "$PRICING_FILE")"
    AGENTLOOP_PRICING_URL="file:///nonexistent/dir/prices.json" resolve_pricing_openai >/dev/null; _rc=$?
    [ "$_rc" -ne 0 ] && [ "$(cat "$PRICING_FILE")" = "$_before" ] \
      && ok "resolve_pricing_openai: an unreachable source returns 1 and leaves the table untouched" || bad "unreachable: rc $_rc, changed=$([ "$(cat "$PRICING_FILE")" = "$_before" ] && echo no || echo yes)"
    grep -q 'pricing: refresh from file:///nonexistent/dir/prices.json failed' "$TICK_LOG" \
      && ok "resolve_pricing_openai: the failure is in tick.log" || bad "no failure line"
    printf 'not json\n' > "$tmp/pr/junk.txt"
    AGENTLOOP_PRICING_URL="file://$tmp/pr/junk.txt" resolve_pricing_openai >/dev/null; _rc=$?
    [ "$_rc" -ne 0 ] && [ "$(cat "$PRICING_FILE")" = "$_before" ] \
      && ok "resolve_pricing_openai: a source that is not a JSON object returns 1 and leaves the table untouched" || bad "junk: rc $_rc"
    # The source of the URL: env, else the table's own, else the default.
    ( unset AGENTLOOP_PRICING_URL; [ "$(pricing_source_url)" = "file://$BASE_DIR/test/fixtures/pricing/litellm-sample.json" ] ) \
      && ok "pricing_source_url: without the env override, the table's _source_url is used" || bad "url '$(unset AGENTLOOP_PRICING_URL; pricing_source_url)'"
    ( unset AGENTLOOP_PRICING_URL; "$JQ" 'del(._source_url)' "$PRICING_FILE" > "$PRICING_FILE.x"; PRICING_FILE="$PRICING_FILE.x"; [ "$(pricing_source_url)" = "$PRICING_SOURCE_DEFAULT" ] ) \
      && ok "pricing_source_url: and the default when the table has none" || bad "default url"
    # platforms carries the freshness and the gap.
    _pl="$(cmd_platforms 2>/dev/null)"
    [ "$(num "$(printf '%s' "$_pl" | "$JQ" -r '.openai.pricing_at // 0')")" -gt 1 ] \
      && ok "cmd_platforms: openai.pricing_at is the table's refresh time" || bad "pricing_at '$(printf '%s' "$_pl" | "$JQ" -c '.openai.pricing_at')'"
    [ "$(printf '%s' "$_pl" | "$JQ" -c '.openai.unpriced')" = '["gpt-5.4-mini"]' ] \
      && ok "cmd_platforms: openai.unpriced names the visible slug without a price" || bad "unpriced '$(printf '%s' "$_pl" | "$JQ" -c '.openai.unpriced')'"
    printf 'RESULT ok=%s bad=%s\n' "$_upass" "$_ufail"
  )"
  printf '%s\n' "$_prout" | grep -v '^RESULT '
  printf '%s\n' "$_prout" | grep -qx 'RESULT ok=16 bad=0' \
    && ok "resolve_pricing_openai: all 16 refresh assertions passed" \
    || bad "resolve_pricing_openai over the sample source did not: $(printf '%s\n' "$_prout" | tail -1)"
```

Run: `bin/agentloop selftest 2>&1 | grep -c FAIL`
Expected: > 0 (`resolve_pricing_openai: command not found`, `RESULT` em falta).

- [ ] **Step 3: O bloco do engine**

Em `bin/agentloop`, imediatamente a seguir ao fim de `openai_catalog_ensure()` (antes do comentário `# The session a run reported in its transcript.`), inserir:

```bash
# --- the price table -----------------------------------------------------------
# config/pricing.json prices OpenAI runs: the Codex stream carries tokens and
# no dollars, so the estimate is tokens × this table. The official page
# (openai.com/api/pricing) refuses automated clients (403 to curl and to
# fetchers alike), so the table refreshes itself from a machine-readable
# source: LiteLLM's model_prices_and_context_window.json — per token there,
# per million here — which matched the page for every catalog slug on
# 2026-09-07. A row the operator marks "source": "manual" is never touched; a
# slug the source does not carry keeps its last row. The refresh rides the
# daily model refresh (the detached `_resolve_models` job) and runs on demand
# as `agentloop resolve-pricing`; it never runs inside a request or a launch.
PRICING_SOURCE_DEFAULT="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

pricing_source_url() { # the env override, else the table's own _source_url, else the default
  if [ -n "${AGENTLOOP_PRICING_URL:-}" ]; then printf '%s' "$AGENTLOOP_PRICING_URL"; return; fi
  local u=""
  [ -s "$PRICING_FILE" ] && u="$("$JQ" -r '._source_url // empty' "$PRICING_FILE" 2>/dev/null)"
  printf '%s' "${u:-$PRICING_SOURCE_DEFAULT}"
}

pricing_unpriced() { # the visible catalog slugs with no numeric price, one per line
  local s
  [ -s "$PRICING_FILE" ] || { openai_catalog_visible; return 0; }
  for s in $(openai_catalog_visible); do
    "$JQ" -e --arg s "$s" '.openai[$s] | (.input|type) == "number" and (.cached_input|type) == "number" and (.output|type) == "number"' \
      "$PRICING_FILE" >/dev/null 2>&1 || printf '%s\n' "$s"
  done
}

resolve_pricing_openai() { # refresh config/pricing.json from the source; 0 = current (or unchanged), 1 = could not refresh
  local url tmp src hdr code now etag new_etag slugs age
  local -a hopt=()
  url="$(pricing_source_url)"
  now="$(now_epoch)"
  if [ ! -s "$PRICING_FILE" ] || ! "$JQ" -e 'type == "object"' "$PRICING_FILE" >/dev/null 2>&1; then
    echo "pricing.json missing or not valid JSON — starting from an empty table"
    printf '{"openai":{}}\n' > "$PRICING_FILE" || return 1
  fi
  tmp="$(mktemp "$CONFIG_DIR/.pricing.XXXXXX")" || return 1
  src="$tmp.src"; hdr="$tmp.hdr"
  etag="$("$JQ" -r '._source_etag // empty' "$PRICING_FILE" 2>/dev/null)"
  [ -z "$etag" ] || hopt=(-H "If-None-Match: $etag")
  age="$(( (now - $(num "$("$JQ" -r '._refreshed_at // 0' "$PRICING_FILE" 2>/dev/null)")) / 3600 ))"
  # `-w` prints the status last; a file:// source (the tests) reports 000 and
  # its body is the whole file. Anything but a body we can parse is a failure
  # that leaves the table exactly as it was — an old price is a price, a
  # half-written table is not.
  code="$(curl -sSL --max-time 30 -o "$src" -D "$hdr" -w '%{http_code}' ${hopt[@]+"${hopt[@]}"} "$url" 2>"$tmp.err")" || code="curl-rc-$?"
  if [ "$code" = "304" ]; then
    "$JQ" --argjson now "$now" '._checked_at = $now' "$PRICING_FILE" > "$tmp" && mv "$tmp" "$PRICING_FILE"
    rm -f "$tmp" "$src" "$hdr" "$tmp.err"
    echo "pricing -> unchanged at the source (etag), checked"
    return 0
  fi
  case "$code" in 200|000) ;; *)
    log_tick "pricing: refresh from $url failed ($code) — table unchanged, last refreshed ${age}h ago"
    echo "pricing -> refresh failed ($code); the table is unchanged"
    rm -f "$tmp" "$src" "$hdr" "$tmp.err"; return 1 ;;
  esac
  if ! "$JQ" -e 'type == "object"' "$src" >/dev/null 2>&1; then
    log_tick "pricing: refresh from $url failed (the source is not a JSON object) — table unchanged, last refreshed ${age}h ago"
    echo "pricing -> the source is not a JSON object; the table is unchanged"
    rm -f "$tmp" "$src" "$hdr" "$tmp.err"; return 1
  fi
  new_etag="$(grep -i '^etag:' "$hdr" 2>/dev/null | tail -1 | sed 's/^[Ee][Tt][Aa][Gg]: *//' | tr -d '\r')"
  # The slugs worth a price: everything the catalog knows, listed or hidden,
  # plus whatever the table already carries (a job may pin a slug the catalog
  # since dropped).
  slugs="$( { openai_catalog_slugs; "$JQ" -r '.openai // {} | keys[]' "$PRICING_FILE" 2>/dev/null; } | sort -u | "$JQ" -R . | "$JQ" -sc .)"
  if ! "$JQ" --slurpfile s "$src" --argjson now "$now" --arg url "$url" --arg etag "$new_etag" --argjson slugs "$slugs" '
      ($s[0]) as $src
      | def per_m: if type == "number" then ((. * 1000000 * 1000000) | round) / 1000000 else null end;
      .openai = (reduce $slugs[] as $slug ((.openai // {});
          (.[$slug] // {}) as $old
          | $src[$slug] as $row
          | if ($old.source // "") == "manual" then .
            elif ($row | type) == "object" and (($row.litellm_provider // "openai") == "openai")
                 and (($row.input_cost_per_token | type) == "number") and (($row.output_cost_per_token | type) == "number") then
              .[$slug] = ({input: ($row.input_cost_per_token | per_m),
                           cached_input: (($row.cache_read_input_token_cost // $row.input_cost_per_token) | per_m),
                           output: ($row.output_cost_per_token | per_m),
                           cache_write: (($row.cache_creation_input_token_cost // 0) | per_m),
                           source: "litellm", at: $now}
                          + (if ($row.cache_read_input_token_cost | type) == "number" then {} else {cached_input_assumed: true} end))
            else . end))
      | ._source_url = $url | ._source_etag = $etag | ._refreshed_at = $now | ._checked_at = $now
      | ._unit = "USD per 1,000,000 tokens: input, cached input, output, cache write (0 when the source lists none)"
      | ._note = "Refreshed by agentloop resolve-pricing (daily, with the model refresh). A row with \"source\": \"manual\" is never overwritten; a slug the source does not price keeps its last row, or has none — such a run records cost_basis none and the dollar caps do not see its spend."
    ' "$PRICING_FILE" > "$tmp" 2>"$tmp.err"; then
    log_tick "pricing: could not rewrite $PRICING_FILE ($(head -c 200 "$tmp.err" 2>/dev/null)) — table unchanged"
    rm -f "$tmp" "$src" "$hdr" "$tmp.err"; return 1
  fi
  mv "$tmp" "$PRICING_FILE" || { rm -f "$tmp" "$src" "$hdr" "$tmp.err"; return 1; }
  rm -f "$src" "$hdr" "$tmp.err"
  local priced manual missing
  priced="$(num "$("$JQ" -r '[.openai[] | select(.source == "litellm")] | length' "$PRICING_FILE")")"
  manual="$(num "$("$JQ" -r '[.openai[] | select(.source == "manual")] | length' "$PRICING_FILE")")"
  missing="$(pricing_unpriced | tr '\n' ' ')"
  echo "pricing -> $priced row(s) from the source, $manual manual, refreshed $(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)${missing:+; no price for: $missing}"
  [ -z "$missing" ] || log_tick "pricing: no price for ${missing}— those runs record cost_basis none and the dollar caps do not see their spend (add a manual row to config/pricing.json, or wait for the source)"
  return 0
}

cmd_resolve_pricing() { resolve_pricing_openai; }
```

E em `cmd_platforms`, acrescentar `pr_at pr_src unpriced` aos `local`, e dentro do `if [ "$p" = "openai" ]; then … fi` que calcula `cat_at`/`cat_ok`:

```bash
      pr_at="$(num "$("$JQ" -r '._refreshed_at // 0' "$PRICING_FILE" 2>/dev/null)")"
      pr_src="$("$JQ" -r '._source_url // ""' "$PRICING_FILE" 2>/dev/null)"
      unpriced="$(pricing_unpriced | "$JQ" -R . | "$JQ" -sc .)"
```

(inicializar `pr_at=0; pr_src=""; unpriced="[]"` antes do `if`), passar `--argjson pr_at "$pr_at" --arg pr_src "$pr_src" --argjson unpriced "$unpriced"` ao `jq -nc`, e no objecto openai acrescentar `pricing_at:$pr_at, pricing_source:$pr_src, unpriced:$unpriced` ao lado de `catalog_at`.

No dispatch: a seguir a `resolve-models) cmd_resolve_models "${2:-}" ;;` inserir `resolve-pricing) cmd_resolve_pricing ;;`; no ramo `_resolve_models)`, a seguir a `cmd_resolve_models`, acrescentar a linha `cmd_resolve_pricing` (o lock `_models` cobre os dois). No `usage`, a seguir à linha de `resolve-models`: `agentloop resolve-pricing     refresh config/pricing.json from the price source (daily on its own)`.

Run: `bash -n bin/agentloop && bin/agentloop selftest 2>&1 | grep -E 'FAIL|failed'`
Expected: `0 failed`, nenhuma linha `FAIL` (17 casos novos visíveis: 16 no bloco + o do pai).

- [ ] **Step 4: O e2e**

Em `test/e2e.test.sh`, junto às exportações do topo (`export AGENTLOOP_CODEX_BIN=…`, `export CODEX_HOME=…`), acrescentar `export AGENTLOOP_PRICING_URL="file://$REPO/test/fixtures/pricing/litellm-sample.json"` com o comentário `# the price source is a fixture: no test reaches the network`. Antes do bloco final de totais, inserir:

```bash
echo
echo "23. the price table refreshes from the source and names what it could not price"
"$AL" resolve-pricing >/dev/null 2>&1
[ "$(jq -r '.openai["gpt-5.6-sol"].cache_write' "$ROOT/config/pricing.json")" = "5" ] \
  && ok "gpt-5.6-sol's cache-write price came from the source (5 per 1M)" || bad "sol row $(jq -c '.openai["gpt-5.6-sol"]' "$ROOT/config/pricing.json")"
[ "$(jq -r '._source_url' "$ROOT/config/pricing.json")" = "$AGENTLOOP_PRICING_URL" ] \
  && ok "the table records its source" || bad "source $(jq -r '._source_url' "$ROOT/config/pricing.json")"
[ "$("$AL" platforms | jq -c '.openai.unpriced')" = '["gpt-5.4-mini"]' ] \
  && ok "platforms names the one visible slug the source does not price" || bad "unpriced $("$AL" platforms | jq -c '.openai.unpriced')"
grep -q 'pricing: no price for gpt-5.4-mini' "$ROOT/data/tick.log" && ok "and tick.log says so" || bad "no tick.log line"
```

(o cenário 13 continua a semear a tabela de exemplo e a esperar $0.031784 para `gpt-5.6-sol`: os números de `input`/`cached`/`output` são os mesmos na fixture, e o run não escreve cache.)

Run: `bash test/e2e.test.sh 2>&1 | tail -8`
Expected: `73 passed, 0 failed`.

- [ ] **Step 5: A tabela de exemplo, o `install.sh`, o README**

Substituir `config/pricing.example.json` por:

```json
{
  "_source_url": "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
  "_refreshed_at": 1788800000,
  "_unit": "USD per 1,000,000 tokens: input, cached input, output, cache write (0 when the source lists none)",
  "_note": "Refreshed by agentloop resolve-pricing (daily, with the model refresh). A row with \"source\": \"manual\" is never overwritten; a slug the source does not price keeps its last row, or has none — such a run records cost_basis none and the dollar caps do not see its spend. These rows were read from the source on 2026-09-07 and matched openai.com/api/pricing that day.",
  "openai": {
    "gpt-5.6-sol":   {"input": 4.0,  "cached_input": 0.4,   "output": 20.0, "cache_write": 5.0,  "source": "litellm", "at": 1788800000},
    "gpt-5.6-terra": {"input": 2.0,  "cached_input": 0.2,   "output": 12.0, "cache_write": 2.5,  "source": "litellm", "at": 1788800000},
    "gpt-5.6-luna":  {"input": 0.2,  "cached_input": 0.02,  "output": 1.2,  "cache_write": 0.25, "source": "litellm", "at": 1788800000},
    "gpt-5.5":       {"input": 5.0,  "cached_input": 0.5,   "output": 30.0, "cache_write": 0,    "source": "litellm", "at": 1788800000},
    "gpt-5.4-mini":  {"input": 0.75, "cached_input": 0.075, "output": 4.5,  "cache_write": 0,    "source": "litellm", "at": 1788800000}
  }
}
```

Em `install.sh`, a mensagem da semente passa a: `say "Created config/pricing.json from the example — OpenAI runs are priced from it, and agentloop refreshes it daily from the price source (agentloop resolve-pricing)."`.

No `README.md`, secção `## Platforms`, substituir o parágrafo **Cost.** por:

```markdown
**Cost.** Codex reports tokens, never dollars. The final event carries an
estimate — `(input − cached) × input + cached × cached_input + cache_write ×
cache_write + output × output`, per million, from `config/pricing.json` — and
every run records `cost_basis`: `reported` (Claude), `estimated`, or `none`
when the model has no price or the run died without a final event. The daily
caps sum estimates like any other cost; a run with `none` counts as zero
towards them. Showing `none` as a dash instead of $0.00, and the estimate as
such, is the dashboard's part and lands with it (see the next release's
notes). `output_tokens` includes reasoning, so reasoning is reported
(`tokens.reasoning`) but never billed twice.

**The price table keeps itself current.** OpenAI's pricing page refuses
automated clients, so the table is refreshed from a machine-readable source —
LiteLLM's `model_prices_and_context_window.json`, which listed every catalog
slug at the page's prices on 2026-09-07 — per token there, per million here,
cache-write price included (the 5.6 family bills it). `agentloop
resolve-pricing` does it on demand; the tick does it daily together with the
model refresh, so a model that appears in the Codex catalog is priced the
same day. Each row says where it came from (`source`, `at`); a row you write
yourself with `"source": "manual"` is never overwritten, and a slug the source
does not carry keeps its last row. `agentloop platforms` shows `pricing_at`
and the visible slugs still without a price (`unpriced`); a failed refresh
leaves the table as it was and says so in `tick.log`. `AGENTLOOP_PRICING_URL`
overrides the source (the tests point it at a fixture).
```

Na secção *Models*, acrescentar no fim do parágrafo sobre a OpenAI: `New OpenAI models need no step here: `codex debug models` refreshes the catalog from OpenAI's servers, the tick runs `resolve-models` daily, and the price refresh runs right after it.` Na secção *CLI*, a seguir à linha de `resolve-models`: `agentloop resolve-pricing    # refresh config/pricing.json from the price source (daily on its own)`; e em *Environment overrides* acrescentar `AGENTLOOP_PRICING_URL`.

- [ ] **Step 6: CHANGELOG, suites, commit**

Bullet aninhado novo sob `- **The OpenAI platform, engine side.**` (`## [Unreleased]` → `### Added`):

```markdown
  - `config/pricing.json` keeps itself current: `agentloop resolve-pricing`
    refreshes it from LiteLLM's machine-readable price table (OpenAI's page
    refuses automated clients), per token there, per million here, cache-write
    price included — the 5.6 family bills it, which the seeded table had as 0.
    The tick runs it daily with the model refresh, so a model that appears in
    the Codex catalog is priced the same day; a row marked `"source":
    "manual"` is never overwritten; a slug the source lacks keeps its last row;
    `agentloop platforms` and `/api/models` report `pricing_at` and the
    visible slugs still without a price; a failed refresh changes nothing and
    says so in `tick.log`.
```

```bash
bin/agentloop selftest 2>&1 | grep -E 'FAIL|failed'
python3.13 -m pytest -p no:cacheprovider tests/ -q --ignore=tests/security
bash test/e2e.test.sh 2>&1 | tail -3
TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_SKIP_CHECK_UPDATE=true python3.13 -m pytest -p no:cacheprovider tests/security -q --deselect tests/security/test_both_configurations.py::test_the_security_suite_is_green_with_the_engines_on
git add bin/agentloop test/fixtures/pricing/litellm-sample.json test/e2e.test.sh config/pricing.example.json install.sh README.md CHANGELOG.md
git commit -m "feat(platforms): the price table refreshes itself from the source, daily with the catalog

resolve-pricing reads LiteLLM's machine-readable table (the OpenAI page
refuses automated clients), converts per token to per million, keeps manual
rows and last-known rows, records source and time, and names in tick.log and
in platforms the visible slugs it could not price. The tick runs it right
after the daily catalog refresh, so a new Codex model is priced the same day.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: O servidor espelha a frescura e o preço por modelo em `/api/models`

**Files:**
- Modify: `bin/agentloop-server` (`_openai_platform`), `tests/test_platforms_api.py`, `CHANGELOG.md` (o bullet de T1 já nomeia `/api/models`; nada a acrescentar salvo se o texto divergir)

**Interfaces:**
- Consumes: a forma de `config/pricing.json` de T1 (`_refreshed_at`, `_source_url`, linhas com `input`, `cached_input`, `output`, `cache_write`, `source`, `at`).
- Produces: em `platforms.openai`: `pricing_at` (epoch ou 0), `pricing_source` (string), `unpriced` (lista de slugs visíveis sem preço numérico); por modelo: `price` = `{input, cached_input, output, cache_write, source, at}` ou `null`. `priced` continua.

- [ ] **Step 1: O teste, que vai falhar**

Em `tests/test_platforms_api.py`, acrescentar:

```python
def test_the_openai_platform_carries_its_prices_and_their_freshness(srv):
    _write_models(srv, openai=_catalog_block())
    (srv.CONFIG_DIR / "pricing.json").write_text(json.dumps({
        "_source_url": "file:///fixture", "_refreshed_at": 1788800000,
        "openai": {
            "gpt-5.6-sol": {"input": 4, "cached_input": 0.4, "output": 20, "cache_write": 5,
                            "source": "litellm", "at": 1788800000},
            "gpt-5.5": {"input": 9, "cached_input": 9, "output": 9, "cache_write": 0, "source": "manual"}}}))
    o = srv.list_models()["platforms"]["openai"]
    assert o["pricing_at"] == 1788800000 and o["pricing_source"] == "file:///fixture"
    by = {m["v"]: m for m in o["models"]}
    assert by["gpt-5.6-sol"]["priced"] is True
    assert by["gpt-5.6-sol"]["price"] == {"input": 4, "cached_input": 0.4, "output": 20,
                                          "cache_write": 5, "source": "litellm", "at": 1788800000}
    assert by["gpt-5.5"]["price"]["source"] == "manual" and by["gpt-5.5"]["price"]["at"] is None
    assert by["gpt-5.6-luna"]["priced"] is False and by["gpt-5.6-luna"]["price"] is None
    assert o["unpriced"] == ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4-mini"]


def test_without_a_price_table_the_platform_says_so(srv):
    _write_models(srv, openai=_catalog_block())
    p = srv.CONFIG_DIR / "pricing.json"
    if p.exists():
        p.unlink()
    o = srv.list_models()["platforms"]["openai"]
    assert o["pricing_at"] == 0 and o["pricing_source"] == ""
    assert o["unpriced"] == [m["v"] for m in o["models"]]
    assert all(m["price"] is None for m in o["models"])
```

Run: `python3.13 -m pytest -p no:cacheprovider tests/test_platforms_api.py -q`
Expected: 2 failed (`KeyError: 'pricing_at'`).

- [ ] **Step 2: O servidor**

Em `_openai_platform`, substituir o bloco que lê `priced` e define `has_price` por:

```python
    try:
        table = json.loads((CONFIG_DIR / "pricing.json").read_text()) or {}
    except Exception:  # noqa: BLE001
        table = {}
    priced = table.get("openai") or {}

    def _num(v):
        return isinstance(v, (int, float)) and not isinstance(v, bool)

    def price_of(slug):
        """The row as the page will show it, or None when it is not a price."""
        row = priced.get(slug)
        if not isinstance(row, dict) or not all(_num(row.get(k)) for k in ("input", "cached_input", "output")):
            return None
        return {"input": row["input"], "cached_input": row["cached_input"], "output": row["output"],
                "cache_write": row.get("cache_write") if _num(row.get("cache_write")) else 0,
                "source": row.get("source") or "", "at": row.get("at") if _num(row.get("at")) else None}

    def has_price(slug):
        return price_of(slug) is not None
```

e no dicionário de cada modelo acrescentar `"price": price_of(m["slug"])`; no `return` final acrescentar:

```python
            "pricing_at": table.get("_refreshed_at") if _num(table.get("_refreshed_at")) else 0,
            "pricing_source": table.get("_source_url") or "",
            "unpriced": [m["v"] for m in models if not m["priced"]],
```

(no ramo `available: False` acrescentar também `"pricing_at": 0, "pricing_source": "", "unpriced": []`, para a forma ser estável.)

- [ ] **Step 3: Suites e commit**

```bash
python3.13 -m pytest -p no:cacheprovider tests/test_platforms_api.py tests/test_page_contract.py -q
python3.13 -m pytest -p no:cacheprovider tests/ -q --ignore=tests/security
bin/agentloop selftest 2>&1 | grep -E 'FAIL|failed'
git add bin/agentloop-server tests/test_platforms_api.py
git commit -m "feat(platforms): /api/models carries each OpenAI model's price and the table's freshness

pricing_at, pricing_source and the visible slugs still unpriced ride on the
openai platform entry, and each model carries its price row or null, so the
dashboard can show an estimate as such and a missing price as a warning.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

(A commit não toca `bin/agentloop` nem `test/`, mas toca `bin/agentloop-server`, que está sob `bin/`: a regra do CHANGELOG aplica-se — acrescentar ao bullet de T1 a frase `; each model carries its price row in /api/models` se ainda não constar, e incluir `CHANGELOG.md` no `git add`.)

---

## Auto-revisão

- **Cobertura do pedido:** actualização periódica dos preços → T1 (`_resolve_models` diário + `resolve-pricing`); preço para um modelo novo → T1 (os slugs vêm do catálogo acabado de refrescar, no mesmo trabalho); "aparecer na lista" → já acontece no engine (catálogo diário de `codex debug models`) e na API; a lista na página é B2. Frescura visível → T1 (`platforms`), T2 (`/api/models`).
- **Nunca inventar:** só valores numéricos da fonte; o único fallback (`cached_input` = `input`) sobrestima e fica anotado.
- **Consistência:** `pricing_unpriced` (engine) e `unpriced` (servidor) aplicam a mesma regra (três números presentes); `pricing_at` = `_refreshed_at` nos dois; a fixture é a mesma para selftest e e2e.
