#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/bin/myskoda"
fixture="$repo_dir/tests/fixture.json"

bash -n "$helper"
jq -e . "$repo_dir/manifest.json" >/dev/null

reading=$(MYSKODA_FIXTURE="$fixture" "$helper" car)
jq -e '.ok == true and .model == "Enyaq" and .battery == 68 and .charging == true' \
  <<<"$reading" >/dev/null

help=$($helper --help)
grep -q 'read one Skoda' <<<"$help"

printf '%s\n' "All offline checks passed."
