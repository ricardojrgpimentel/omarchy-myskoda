#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/bin/myskoda"
fixture="$repo_dir/tests/fixture.json"
api_ev="$repo_dir/tests/public-api-ev.json"
api_hybrid="$repo_dir/tests/public-api-hybrid.json"
api_combustion="$repo_dir/tests/public-api-combustion.json"
api_headers="$repo_dir/tests/public-api-headers.txt"
ev_vin="TMBJB9NY5RF999999"
hybrid_vin="TMBABCD1234567890"
combustion_vin="TMBZZZAA123456789"
test_key="test-public-api-key"

mode_of() {
  if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"
  else stat -f %Lp "$1"; fi
}

bash -n "$helper"
jq -e . "$repo_dir/manifest.json" "$fixture" "$api_ev" "$api_hybrid" "$api_combustion" >/dev/null

reading=$(MYSKODA_FIXTURE="$fixture" "$helper" car)
jq -e '.ok == true and .model == "Enyaq" and .battery == 68 and .powertrain == "electric" and .charging == true' \
  <<<"$reading" >/dev/null

help=$($helper --help)
grep -q 'official MySkoda Public API' <<<"$help"
grep -q 'configure VIN' <<<"$help"
if grep -Eq 'mysmob\.api|identity\.vwgroup|exchange-authorization-code|refresh-token\?tokenType' "$helper"; then
  printf '%s\n' "Private API or legacy authentication route remains in helper." >&2
  exit 1
fi

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

configured=$(printf '%s\n' "$test_key" | \
  XDG_CONFIG_HOME="$test_dir/config" XDG_CACHE_HOME="$test_dir/cache" \
  MYSKODA_API_FIXTURE="$api_ev" MYSKODA_API_HEADERS_FIXTURE="$api_headers" \
  "$helper" configure "$ev_vin")
jq -e '
  .ok == true and .vin == "TMBJB9NY5RF999999" and .name == "My Enyaq"
  and .powertrain == "electric" and .battery == 68 and .range_km == 312
  and .charging == true and .locked == true and .odometer_km == 18432
  and .api_key_expires_at == "2026-12-31T23:59:59Z"
  and .rate_limit_limit == 20 and .rate_limit_remaining == 17
  and .error == null
' <<<"$configured" >/dev/null
! grep -q "$test_key" <<<"$configured"
test "$(mode_of "$test_dir/config/omarchy-myskoda/api-key")" = 600
test "$(mode_of "$test_dir/config/omarchy-myskoda/vin")" = 600
test "$(mode_of "$test_dir/cache/omarchy-myskoda/last-reading.json")" = 600
test "$(sed -n '1p' "$test_dir/config/omarchy-myskoda/api-key")" = "$test_key"
test "$(sed -n '1p' "$test_dir/config/omarchy-myskoda/vin")" = "$ev_vin"

stored=$(XDG_CONFIG_HOME="$test_dir/config" XDG_CACHE_HOME="$test_dir/cache" \
  MYSKODA_API_FIXTURE="$api_ev" MYSKODA_API_HEADERS_FIXTURE="$api_headers" \
  "$helper" car)
jq -e '.ok == true and .vin == "TMBJB9NY5RF999999" and .license_plate == "00-AA-00"' \
  <<<"$stored" >/dev/null

limited=$(XDG_CONFIG_HOME="$test_dir/config" XDG_CACHE_HOME="$test_dir/cache" \
  MYSKODA_API_FIXTURE="$api_ev" MYSKODA_API_HEADERS_FIXTURE="$api_headers" MYSKODA_API_STATUS=429 \
  "$helper" car)
jq -e '.ok == true and .stale == true and .error == "rate limit reached" and .retry_after == 300' \
  <<<"$limited" >/dev/null

expired=$(XDG_CONFIG_HOME="$test_dir/config" XDG_CACHE_HOME="$test_dir/cache" \
  MYSKODA_API_FIXTURE="$api_ev" MYSKODA_API_STATUS=401 "$helper" car)
jq -e '.ok == false and .error == "API key expired"' <<<"$expired" >/dev/null

hybrid=$(XDG_CONFIG_HOME="$test_dir/hybrid-config" XDG_CACHE_HOME="$test_dir/hybrid-cache" \
  MYSKODA_API_KEY="$test_key" MYSKODA_API_FIXTURE="$api_hybrid" \
  "$helper" --vin "$hybrid_vin" car)
jq -e '
  .ok == true and .powertrain == "hybrid" and .battery == 51 and .fuel == 74
  and .range_km == 610 and .locked == false and .windows == "OPEN"
' <<<"$hybrid" >/dev/null

combustion=$(XDG_CONFIG_HOME="$test_dir/combustion-config" XDG_CACHE_HOME="$test_dir/combustion-cache" \
  MYSKODA_API_KEY="$test_key" MYSKODA_API_FIXTURE="$api_combustion" \
  "$helper" --vin "$combustion_vin" car)
jq -e '
  .ok == true and .powertrain == "combustion" and .battery == null and .fuel == 63
  and .range_km == 720 and .lat == null and .open == ["one or more doors", "boot"]
  and .error == null
' <<<"$combustion" >/dev/null

invalid=$(printf '%s\n' "$test_key" | \
  XDG_CONFIG_HOME="$test_dir/invalid-config" XDG_CACHE_HOME="$test_dir/invalid-cache" \
  "$helper" configure SHORT)
jq -e '.ok == false and .error == "invalid VIN"' <<<"$invalid" >/dev/null

mkdir -p "$test_dir/legacy-config/omarchy-myskoda"
printf '%s\n' "obsolete-refresh-token" > "$test_dir/legacy-config/omarchy-myskoda/refresh-token"
legacy=$(XDG_CONFIG_HOME="$test_dir/legacy-config" XDG_CACHE_HOME="$test_dir/legacy-cache" \
  MYSKODA_VIN="$ev_vin" "$helper" car)
jq -e '.ok == false and .error == "Public API key required"' <<<"$legacy" >/dev/null

logged_out=$(XDG_CONFIG_HOME="$test_dir/config" XDG_CACHE_HOME="$test_dir/cache" "$helper" logout)
jq -e '.ok == true and .configured == false' <<<"$logged_out" >/dev/null
test ! -e "$test_dir/config/omarchy-myskoda/api-key"
test ! -e "$test_dir/config/omarchy-myskoda/vin"

jq -ne '[{engineType:"electric"}, "unexpected"] | map(objects | select((((.engineType//"")|ascii_downcase)!="electric") and (.engineType!=null))) | length == 0' >/dev/null

python3 "$repo_dir/tests/test-transfer.py"

printf '%s\n' "All offline checks passed."
