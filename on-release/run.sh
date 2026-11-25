#!/usr/bin/env bash
# Angelia on-release: read a release event from the triggering GitHub event
# (or the `event` input), validate its shape, expose it as step outputs and
# apply the input filters. Needs bash 4+ and jq 1.6+ (both on GitHub runners).
#
# Inputs arrive as IN_* environment variables, never interpolated into this
# script, so event data cannot inject shell. Test hooks: GITHUB_EVENT_NAME,
# GITHUB_EVENT_PATH and GITHUB_OUTPUT are the runner's own variables.
set -euo pipefail

fail() { printf '::error title=angelia/on-release::%s\n' "$1"; exit 1; }

command -v jq >/dev/null || fail "jq is required"

event_name=${GITHUB_EVENT_NAME:-}
event_path=${GITHUB_EVENT_PATH:-}
input_name=${IN_EVENT_INPUT:-event}
include_pre=${IN_INCLUDE_PRERELEASES:-true}
case $include_pre in true | false) ;; *) fail "include-prereleases must be true or false" ;; esac

raw=""
action=""
if [[ -n ${IN_EVENT:-} ]]; then
  raw=$IN_EVENT
else
  [[ -r $event_path ]] || fail "no event payload: pass the event input"
  case $event_name in
    repository_dispatch)
      raw=$(jq -c '.client_payload // empty' "$event_path") || fail "unreadable event payload"
      action=$(jq -r '.action // ""' "$event_path")
      ;;
    workflow_dispatch)
      raw=$(jq -r --arg n "$input_name" '.inputs[$n] // empty' "$event_path") || fail "unreadable event payload"
      # No JSON input: accept the flat inputs a sink may render one by one.
      [[ -n $raw ]] || raw=$(jq -c '.inputs // empty' "$event_path")
      ;;
    *) fail "unsupported trigger '$event_name': use repository_dispatch, workflow_dispatch or the event input" ;;
  esac
fi
[[ -n $raw ]] || fail "the event payload is empty"

# Validate and normalise. Error messages are static: they never echo event
# data, which comes from a registry and must not reach a workflow command.
# shellcheck disable=SC2016
norm=$(jq -c --arg action "$action" '
  def blank: type != "string" or test("^\\s*$");
  def short: capture("^dev\\.angelia\\.release\\.(?<k>published|prerelease|yanked)\\.v1$").k;
  # Only the full CloudEvents type counts (event_type set to the .type template variable).
  # The sinks default event_type, angelia.release.published, is sent for every
  # event, yanked ones included, so it says nothing and is treated as unknown.
  def from_action: if type == "string" and ([short] | length) > 0 then . else null end;
  def ulid: type == "string" and test("^[0-9A-HJKMNP-TV-Z]{26}$");

  (if type == "object" then . else error("the event is not a JSON object") end)
  | if has("specversion") then
      (if .specversion != "1.0" then error("specversion must be 1.0") else . end)
      | (if (.type | type) != "string" or ((.type | short?) // null) == null then error("type must be dev.angelia.release.(published|prerelease|yanked).v1") else . end)
      | (if (.id | ulid | not) then error("id must be a ULID") else . end)
      | (if (.subject | blank) then error("subject is required") else . end)
      | (if has("datacontenttype") and .datacontenttype != "application/json" then error("datacontenttype must be application/json") else . end)
      | (if (.data | type) != "object" then error("data must be an object") else . end)
      | {type: .type, id: .id, d: .data}
    else
      # A client_payload, a bare data object, or workflow_dispatch inputs, which
      # are all strings: "" stands for null and "true"/"false" for booleans.
      (with_entries(select(((.key | IN("prerelease","yanked")) and .value == "") | not))
       | with_entries(if (.value | type) == "string" and (.key | IN("previous_version","bump","purl","release_url")) and .value == "" then .value = null
                    elif (.value | type) == "string" and (.key | IN("prerelease","yanked")) and (.value | IN("true","false")) then .value = (.value == "true")
                    else . end)) as $d
      | (if ($d.event_id // null) != null and ($d.event_id | ulid | not) then error("event_id must be a ULID or null") else . end)
      | {type: (($action | from_action) // ($d.type? | from_action)), id: ($d.event_id // ""), d: $d}
    end
  | .d as $d
  | ($d | has("urls")) as $full
  | (if ($d.source | blank) then error("source is required") else . end)
  | (if ($d.package | blank) then error("package is required") else . end)
  | (if ($d.version | blank) then error("version is required") else . end)
  | (if (["previous_version","purl","bump","release_url"] | map(select($d[.] != null and ($d[.] | type) != "string")) | length) > 0 then error("previous_version, purl, bump and release_url must be strings or null") else . end)
  | (if ($d.bump // null) as $b | $b != null and (["major","minor","patch","prerelease","other"] | index($b) | not) then error("unknown bump") else . end)
  | (if ($d | has("prerelease")) and ($d.prerelease | type) != "boolean" then error("prerelease must be a boolean") else . end)
  | (if ($d | has("yanked")) and ($d.yanked | type) != "boolean" then error("yanked must be a boolean") else . end)
  | (if $full and (($d.urls | type) != "object" or (($d.urls.release // null) | . != null and type != "string")) then error("urls.release must be a string or null") else . end)
  | (if $full then ($d.urls.release // "") else ($d.release_url // "") end) as $rel
  # The type: the envelope, else the dispatch event_type, else the flags the
  # spec ties to each type (prerelease, yanked) when the data has them.
  | (.type // (if ($d | has("yanked") and has("prerelease")) then
        (if $d.yanked then "yanked" elif $d.prerelease then "prerelease" else "published" end)
        | "dev.angelia.release." + . + ".v1"
      else null end)) as $type
  | {
      ecosystem: $d.source,
      package: $d.package,
      version: $d.version,
      previous_version: ($d.previous_version // ""),
      bump: ($d.bump // ""),
      prerelease: (if ($d.prerelease | type) == "boolean" then $d.prerelease
                   elif $type != null and ($type | short) == "prerelease" then true
                   elif $type != null and ($type | short) == "published" then false
                   else ($d.bump // "") == "prerelease" end),
      yanked: (if ($d.yanked | type) == "boolean" then $d.yanked else ($type != null and ($type | short) == "yanked") end),
      purl: ($d.purl // ""),
      release_url: $rel,
      event_type: ($type // ""),
      event_id: .id
    }
  | if [.[] | strings | test("[\\x00-\\x1f\\x7f]")] | any then error("a value contains control characters") else . end
' <<<"$raw" 2>&1) || fail "invalid Angelia release event: $(printf '%s' "${norm%%$'\n'*}" | sed -e 's/^jq: error ([^)]*): //' -e 's/ at <[^>]*>.*$//' | tr -d '\r' | cut -c1-200)"
[[ $norm == \{* ]] || fail "invalid Angelia release event"

get() { jq -r --arg k "$1" '.[$k] | tostring' <<<"$norm"; }

# --- filters ---------------------------------------------------------------
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

# in_list "<comma or newline separated list>" value: empty list matches all.
in_list() {
  local list=${1//$'\n'/,} item found=1 any=1
  local IFS=,
  for item in $list; do
    item=$(trim "$item")
    [[ -n $item ]] || continue
    any=0
    [[ $item == "$2" ]] && found=0
  done
  [[ $any -eq 1 || $found -eq 0 ]]
}

glob_list() {
  local list=${1//$'\n'/,} item found=1 any=1
  local IFS=,
  set -f
  for item in $list; do
    item=$(trim "$item")
    [[ -n $item ]] || continue
    any=0
    # shellcheck disable=SC2053
    [[ $2 == $item ]] && found=0
  done
  set +f
  [[ $any -eq 1 || $found -eq 0 ]]
}

if [[ -z $(get event_type) ]]; then
  echo "::warning title=angelia/on-release::The event type is unknown, so event_type is empty and event-types filters do not match. Set the Angelia github-dispatch sink's event_type to '{{.type}}' to send it."
fi

ecosystem=$(get ecosystem) package=$(get package) bump=$(get bump)
prerelease=$(get prerelease) event_type=$(get event_type)
short=${event_type#dev.angelia.release.}
short=${short%.v1}

matched=true
in_list "${IN_ECOSYSTEM:-}" "$ecosystem" || matched=false
glob_list "${IN_PACKAGE:-}" "$package" || matched=false
in_list "${IN_BUMP:-}" "${bump:-none}" || matched=false
if [[ -n $event_type ]]; then
  in_list "${IN_EVENT_TYPES:-}" "$short" || matched=false
elif [[ -n $(trim "${IN_EVENT_TYPES:-}") ]]; then
  matched=false # a filter on the type cannot match an event of unknown type
fi
if [[ $include_pre == false && $prerelease == true ]]; then matched=false; fi

# --- outputs ---------------------------------------------------------------
out=${GITHUB_OUTPUT:-/dev/stdout}
{
  for k in ecosystem package version previous_version bump prerelease purl release_url event_type event_id yanked; do
    printf '%s=%s\n' "$k" "$(get "$k")"
  done
  printf 'matched=%s\n' "$matched"
} >>"$out"
