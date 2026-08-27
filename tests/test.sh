#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/bin/myskoda"
fixture="$repo_dir/tests/fixture.json"

bash -n "$helper"
jq -e . "$repo_dir/manifest.json" >/dev/null

reading=$(MYSKODA_FIXTURE="$fixture" "$helper" car)
jq -e '.ok == true and .model == "Enyaq" and .battery == 68 and .powertrain == "electric" and .charging == true' \
  <<<"$reading" >/dev/null

help=$($helper --help)
grep -q 'read one Skoda' <<<"$help"

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
login=$(XDG_CONFIG_HOME="$test_dir/config" XDG_CACHE_HOME="$test_dir/cache" XDG_DATA_HOME="$test_dir/data" "$helper" login-url)
jq -e '.ok == true and (.url | startswith("https://identity.vwgroup.io/oidc/v1/authorize?"))' \
  <<<"$login" >/dev/null
test "$(stat -c %a "$test_dir/config/omarchy-myskoda/login-session.json")" = 600
test "$(jq -r '.browser_profile' "$test_dir/config/omarchy-myskoda/login-session.json")" = "$(jq -r '.browserProfile' <<<"$login")"
grep -q 'MimeType=x-scheme-handler/myskoda;' "$test_dir/data/applications/community-myskoda-oauth.desktop"

jq -ne '[{engineType:"electric"}, "unexpected"] | map(objects | select((((.engineType//"")|ascii_downcase)!="electric") and (.engineType!=null))) | length == 0' >/dev/null

printf '%s\n' "All offline checks passed."
