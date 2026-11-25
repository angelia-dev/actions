# Angelia GitHub Actions

GitHub Actions to consume [Angelia](https://github.com/angelia-dev) release events in workflows.

**Status:** pre-alpha / Phase 0. Tags (`v1`) are not published yet.

| Action | Use |
|---|---|
| [`on-release`](#on-release) | Read a release event, validate it, expose it as outputs, filter it. |

## on-release

```yaml
on:
  repository_dispatch:
    types: [dev.angelia.release.published.v1, dev.angelia.release.prerelease.v1, dev.angelia.release.yanked.v1]
jobs:
  react:
    runs-on: ubuntu-latest
    permissions: {}
    steps:
      - id: release
        uses: angelia-dev/actions/on-release@v1
        with:
          ecosystem: pypi
          package: requests
      - if: steps.release.outputs.matched == 'true'
        env:
          VERSION: ${{ steps.release.outputs.version }}
        run: echo "requests $VERSION"
```

This requires the Angelia sink to be configured with `event_type: '{{.type}}'` (see [below](#what-the-sink-sends-and-what-that-means-for-the-type)); with the sink's default `event_type` the action cannot tell the types apart.

Full workflows: [`examples/react-to-release.yml`](examples/react-to-release.yml) and the reusable workflow [`examples/reusable-release-handler.yml`](examples/reusable-release-handler.yml).

It is a composite action in bash and `jq` (both preinstalled on GitHub-hosted runners): no build step, no `node_modules`, no third-party action, no network access, no token. A job that only uses it needs `permissions: {}`.

### Where the event comes from

In this order:

1. The **`event` input**, a JSON string: a CloudEvents envelope, its `data` object, or a `client_payload` object.
2. **`repository_dispatch`**: `github.event.client_payload`, the flat payload of Angelia's [github-dispatch sink](https://github.com/angelia-dev/angelia/blob/main/docs/github-dispatch.md), and `github.event.action` (the sink's `event_type`) for the event type.
3. **`workflow_dispatch`**: the input named by `event-input` (default `event`) as a JSON string, for runs you start by hand. Otherwise the flat inputs the sink can render one by one, each a string: `type` (`{{.type}}`), `source`, `package`, `version`, `previous_version`, `bump`, `prerelease`, `yanked`, `purl`, `release_url`. An empty string means null (also for `prerelease` and `yanked`). Sink inputs are cut to 1024 bytes, so do not try to carry the whole event in one.

Any other trigger needs the `event` input.

### What the sink sends, and what that means for the type

For `repository_dispatch` the sink sends `event_type` (a template, default `angelia.release.published`) and a **flat** `client_payload`: `event_id`, `source`, `package`, `version`, `previous_version`, `bump`, `purl`, `release_url`, `watch`, and `truncated` when a value was cut. It carries **neither the event type nor `prerelease`**.

The action therefore takes the type from the dispatch `event_type`, and **only the full CloudEvents type counts**. **Set the sink's `event_type: '{{.type}}'`**, which renders `dev.angelia.release.prerelease.v1` and so on. The sink's default, `angelia.release.published`, is sent for every event, yanked ones included, so it says nothing: the action treats any other `event_type` (that default included) as an unknown type. Then `event_type` is empty, every `event-types` filter fails closed (does not match), `yanked` is `false`, `prerelease` is true only when `bump` is `prerelease`, and the step prints a `::warning::` telling you to set `event_type: '{{.type}}'`. A published type is never a prerelease, whatever `bump` says.

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `event` | `""` | The event as JSON. Overrides the triggering event. |
| `event-input` | `event` | Name of the `workflow_dispatch` input holding the event JSON. |
| `ecosystem` | `""` | Comma-separated source kinds to accept (`pypi`, `npm`, `github-release`, ...), exact match. Empty: all. |
| `package` | `""` | Comma- or newline-separated bash patterns on the package name: `*`, `?`, `[...]` classes (`*` also matches `/`; a pattern cannot contain a comma). Empty: all. |
| `bump` | `""` | Comma-separated bump kinds: `major`, `minor`, `patch`, `prerelease`, `other`, and `none` for an event with no bump (first version). Empty: all. |
| `event-types` | `""` | Comma-separated `published`, `prerelease`, `yanked`. Empty: all. An event of unknown type does not match a non-empty list. |
| `include-prereleases` | `true` | `false`: pre-releases do not match. |

All filters must match (AND); inside one filter any entry may match (OR).

### Outputs

Set on every successful run, matched or not. A missing value (`null` in the event) is an empty string.

| Output | Value |
|---|---|
| `matched` | `true` when every filter passed, else `false`. |
| `event_type` | Full type, e.g. `dev.angelia.release.published.v1`. Empty if unknown (see above). A bare `data` object gets the type implied by its `prerelease` and `yanked` flags. |
| `event_id` | Event id (ULID); empty for a bare `data` object. Delivery is at-least-once, deduplicate on it. |
| `ecosystem` | `data.source`: `pypi`, `npm`, ... |
| `package` | `data.package` |
| `version` | `data.version`, as the registry wrote it |
| `previous_version` | `data.previous_version` |
| `bump` | `major`, `minor`, `patch`, `prerelease`, `other` |
| `prerelease` | `true` / `false` |
| `yanked` | `true` for a `release.yanked` event |
| `purl` | `data.purl` |
| `release_url` | `data.urls.release` |

The output is named `event_type` (underscore) like every other output.

### Event types covered

`dev.angelia.release.published.v1`, `dev.angelia.release.prerelease.v1` and `dev.angelia.release.yanked.v1` are all the types in the [spec](https://github.com/angelia-dev/spec) (release schema v1, spec 0.10.0); each is tested as envelope, as bare `data` and as `repository_dispatch`.

### Verification and trust

The spec and the sink define **no signature or HMAC for `repository_dispatch` or `workflow_dispatch`**: signing (Standard Webhooks) belongs to the webhook sink only. The action does not invent one. A dispatch can only be created by someone holding a token with `contents: write` (`repository_dispatch`) or `actions: write` (`workflow_dispatch`) on your repository, and GitHub runs `repository_dispatch` workflows only from the default branch. **That token is the trust boundary**: keep it as narrow as the Angelia docs say and do not reuse it.

What the action does check, and fails the step on:

- an envelope: `specversion` is `1.0`, `type` is one of the three `dev.angelia.release.*.v1`, `id` is a ULID, `subject` is present, `datacontenttype` (if present) is `application/json`, `data` is an object;
- `source`, `package` and `version` are non-blank strings; `previous_version`, `bump`, `purl`, `release_url` are strings or null; `bump` is a known value; `prerelease` and `yanked` are booleans if present;
- no value contains control characters.

This is a shape check, not full JSON Schema validation (the spec repository's CI does that). Event data is data from a registry: the action reads inputs through environment variables and its error messages never echo event values. In your own workflow pass outputs through `env:` too, never `${{ }}` inside a `run:` script.

### Versioning: the `v1` tag

Releases are SemVer tags (`v1.2.3`) on `main`, and a moving major tag `v1` that is force-moved to the latest `v1.x.y`. Use `@v1` to get compatible fixes, or a full commit SHA to pin. Breaking changes to inputs or outputs (removal, rename, changed meaning) go in `v2`; new optional inputs and outputs are minor. The action follows the Angelia release schema: a new event type or field is additive; a `.v2` event type needs a new major here.

## Development

```
bash test/run.sh                  # the whole fixture suite, needs bash and jq
bash test/gen-dispatch-fixtures.sh  # regenerate testdata/fixtures/dispatch
```

CI ([`.github/workflows/test.yml`](.github/workflows/test.yml)) runs the same script and then the real action on each event type, with the `dispatch` job pointing `GITHUB_EVENT_NAME` and `GITHUB_EVENT_PATH` (step `env`) at the recorded dispatch fixtures; `test/run.sh` covers those cases too, without a runner; the aggregate **CI OK** job gates merging. Fixtures: [`testdata/README.md`](testdata/README.md).

## License

[Apache-2.0](LICENSE)
