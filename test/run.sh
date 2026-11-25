#!/usr/bin/env bash
# Local test of on-release/run.sh against the recorded fixtures. Needs bash and jq.
# Usage: test/run.sh   (from anywhere). Exit status 0 when every check passes.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fx=$root/testdata/fixtures
script=$root/on-release/run.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 failn=0

ok() { pass=$((pass + 1)); }
bad() { failn=$((failn + 1)); printf 'FAIL: %s\n' "$*" >&2; }

# run <mode> <file> [VAR=value ...]: runs the action script, outputs in $tmp/out.
# Succeeds with the script's own status.
run() {
  local mode=$1 file=$2
  shift 2
  : >"$tmp/out"
  if [[ $mode == event ]]; then
    env -i PATH="$PATH" GITHUB_EVENT_NAME=push GITHUB_OUTPUT="$tmp/out" IN_EVENT="$(cat "$file")" "$@" bash "$script" >"$tmp/log" 2>&1
  else
    env -i PATH="$PATH" GITHUB_EVENT_NAME="$mode" GITHUB_EVENT_PATH="$file" GITHUB_OUTPUT="$tmp/out" "$@" bash "$script" >"$tmp/log" 2>&1
  fi
}
out() { sed -n "s/^$1=//p" "$tmp/out"; }

# 1. every fixture in expected.tsv yields exactly the expected outputs
names=(ecosystem package version previous_version bump prerelease purl release_url event_type)
while IFS='|' read -r mode file e1 e2 e3 e4 e5 e6 e7 e8 e9; do
  [[ -z $mode || $mode == \#* ]] && continue
  exp=("$e1" "$e2" "$e3" "$e4" "$e5" "$e6" "$e7" "$e8" "$e9")
  if ! run "$mode" "$fx/$file"; then bad "$file: script failed: $(cat "$tmp/log")"; continue; fi
  for i in "${!names[@]}"; do
    got=$(out "${names[$i]}")
    if [[ $got == "${exp[$i]}" ]]; then ok; else bad "$file: ${names[$i]}: got '$got', want '${exp[$i]}'"; fi
  done
  [[ $(out matched) == true ]] && ok || bad "$file: matched should be true without filters"
done <"$root/testdata/expected.tsv"

# 2. invalid events fail and say why, with no output written
for f in "$fx"/spec-invalid/*.json; do
  if run event "$f"; then bad "$(basename "$f"): accepted"; else
    grep -q '^::error' "$tmp/log" && [[ ! -s $tmp/out ]] && ok || bad "$(basename "$f"): no error or output written"
  fi
done
for t in repository_dispatch workflow_dispatch; do
  echo '{"action":"x"}' >"$tmp/empty.json"
  run "$t" "$tmp/empty.json" && bad "$t without a payload accepted" || ok
done
echo '{}' >"$tmp/push.json"
run push "$tmp/push.json" && bad "unsupported trigger accepted" || ok
run event "$fx/spec-envelope/published-pypi.json" IN_INCLUDE_PRERELEASES=maybe && bad "bad boolean accepted" || ok

# 3. filters: name|fixture|VAR=value|expected matched
pp=$fx/spec-envelope/published-pypi.json np=$fx/spec-envelope/prerelease-npm-scoped.json yp=$fx/spec-envelope/yanked-pypi.json
nb=$fx/spec-data/published-first-version-no-purl.json
filter() { # filter <file> <expected> [VAR=value ...]
  local file=$1 want=$2
  shift 2
  if ! run event "$file" "$@"; then bad "filter $*: script failed"; return; fi
  [[ $(out matched) == "$want" ]] && ok || bad "filter $* on $(basename "$file"): matched=$(out matched), want $want"
}
filter $pp true IN_ECOSYSTEM=pypi
filter $pp true "IN_ECOSYSTEM=npm, pypi"
filter $pp false IN_ECOSYSTEM=npm
filter $pp true IN_PACKAGE=requests
filter $pp true 'IN_PACKAGE=req*'
filter $pp false 'IN_PACKAGE=flask,django*'
filter $pp true $'IN_PACKAGE=flask\nreq?ests'
filter $np true 'IN_PACKAGE=@angular/*'
filter $np false 'IN_PACKAGE=@angular/c'
filter $pp true IN_BUMP=minor
filter $pp true IN_BUMP=major,minor
filter $pp false IN_BUMP=major,patch
filter $nb true IN_BUMP=none
filter $nb false IN_BUMP=major,minor,patch
filter $pp false IN_BUMP=none
filter $pp true IN_EVENT_TYPES=published
filter $pp false IN_EVENT_TYPES=prerelease,yanked
filter $np true IN_EVENT_TYPES=prerelease
filter $yp true IN_EVENT_TYPES=yanked
filter $yp false IN_EVENT_TYPES=published,prerelease
filter $np false IN_INCLUDE_PRERELEASES=false
filter $np true IN_INCLUDE_PRERELEASES=true
filter $pp true IN_INCLUDE_PRERELEASES=false
filter $pp false IN_ECOSYSTEM=pypi IN_PACKAGE=flask  # all filters must match
filter $pp true IN_ECOSYSTEM=pypi IN_PACKAGE='req*' IN_BUMP=minor IN_EVENT_TYPES=published IN_INCLUDE_PRERELEASES=false
# unfiltered outputs are still written when nothing matches
run event $pp IN_ECOSYSTEM=npm && [[ $(out package) == requests ]] && ok || bad "outputs missing when unmatched"
# a type filter cannot match an event of unknown type (custom dispatch event_type)
run repository_dispatch "$fx/dispatch/repository-dispatch-custom-event-type.json" IN_EVENT_TYPES=published && [[ $(out matched) == false ]] && ok || bad "unknown type matched a type filter"
# the event input overrides the trigger's own payload
run repository_dispatch "$fx/dispatch/repository-dispatch-published.json" IN_EVENT="$(cat $yp)" && [[ $(out event_type) == *yanked* ]] && ok || bad "event input did not override"
# a custom workflow_dispatch input name
jq '{inputs: {release: .inputs.event}}' "$fx/dispatch/workflow-dispatch-event-input.json" >"$tmp/custom.json"
run workflow_dispatch "$tmp/custom.json" IN_EVENT_INPUT=release && [[ $(out package) == requests ]] && ok || bad "custom event-input name"

# 4. hostile data stays data: no shell expansion, no workflow command, no output injection
jq '.data.package = "$(touch '"$tmp"'/pwned)`id`" | .data.version = "1.0\n::set-output name=x::y"' "$pp" >"$tmp/hostile.json"
run event "$tmp/hostile.json" && bad "control character in version accepted" || { grep -q 'control characters' "$tmp/log" && ok || bad "hostile: wrong error"; }
jq '.data.package = "$(touch '"$tmp"'/pwned)`id`;\"x"' "$pp" >"$tmp/hostile2.json"
run event "$tmp/hostile2.json" && [[ ! -e $tmp/pwned && $(out package) == *'$(touch'* ]] && ok || bad "hostile package was expanded"
printf 'not json' >"$tmp/nojson.json"
run event "$tmp/nojson.json" && bad "non-JSON accepted" || { grep -q '^::error' "$tmp/log" && ok || bad "non-JSON: no error"; }

printf '%d checks passed, %d failed\n' "$pass" "$failn"
[[ $failn -eq 0 ]]
