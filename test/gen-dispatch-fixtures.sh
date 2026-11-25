#!/usr/bin/env bash
# Regenerates testdata/fixtures/dispatch/* from the spec fixtures, applying the
# mapping of Angelia's github-dispatch sink (angelia internal/sink/githubdispatch,
# clientPayload and viewOf): a flat client_payload of event_id, source,
# package, version, previous_version, bump, purl, release_url, watch.
# Usage: test/gen-dispatch-fixtures.sh   (run from the repository root)
set -euo pipefail
cd "$(dirname "$0")/.."
fx=testdata/fixtures
out=$fx/dispatch

rd() { # rd <envelope.json> <event_type> <outfile>
  jq --arg et "$2" '{
    action: $et,
    client_payload: {
      event_id: .id, source: .data.source, package: .data.package, version: .data.version,
      previous_version: .data.previous_version, bump: .data.bump, purl: .data.purl,
      release_url: .data.urls.release, watch: (.data.watch.name // .data.watch.id)
    },
    repository: {full_name: "octo-org/octo-app"},
    sender: {login: "octo-bot"}
  }' "$1" >"$out/$3"
}
wd() { # wd <envelope.json> <outfile>: workflow_dispatch with the event as one JSON input
  jq '{inputs: {event: tojson}, ref: "refs/heads/main", repository: {full_name: "octo-org/octo-app"}}' "$1" >"$out/$2"
}

# The sink's default event_type is sent for every event, yanked ones included.
d=angelia.release.published
rd $fx/spec-envelope/published-pypi.json $d repository-dispatch-default-published.json
rd $fx/spec-envelope/prerelease-npm-scoped.json $d repository-dispatch-default-prerelease.json
rd $fx/spec-envelope/yanked-pypi.json $d repository-dispatch-default-yanked.json
# event_type: '{{.type}}', the full CloudEvents type
for k in published:published-pypi prerelease:prerelease-npm-scoped yanked:yanked-pypi; do
  rd $fx/spec-envelope/${k#*:}.json dev.angelia.release.${k%%:*}.v1 repository-dispatch-type-${k%%:*}.json
done
# a custom template
rd $fx/spec-envelope/published-pypi.json release.pypi repository-dispatch-custom-event-type.json
wd $fx/spec-envelope/published-pypi.json workflow-dispatch-event-input.json
wd $fx/spec-envelope/yanked-pypi.json workflow-dispatch-event-input-yanked.json
# workflow_dispatch with the flat inputs of the sink's documented example
jq '{inputs: {package: .data.package, version: .data.version, source: .data.source}, ref: "refs/heads/main"}' \
  $fx/spec-envelope/published-pypi.json >$out/workflow-dispatch-flat-inputs.json
# ... and with every input the README recommends, all strings as GitHub delivers them
jq '{inputs: {type: .type, source: .data.source, package: .data.package, version: .data.version,
     previous_version: .data.previous_version, bump: .data.bump, prerelease: (.data.prerelease | tostring),
     purl: (.data.purl // ""), release_url: .data.urls.release}, ref: "refs/heads/main"}' \
  $fx/spec-envelope/prerelease-npm-scoped.json >$out/workflow-dispatch-flat-inputs-full.json
