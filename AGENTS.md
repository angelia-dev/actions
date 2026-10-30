# AGENTS.md — how to work in `actions`

This repository is part of [Angelia](https://github.com/angelia-dev/angelia), built mostly by **AI coding agents** working with a human maintainer. It holds the GitHub Actions that consume Angelia release events in workflows.

The rules of the core repository apply here: read [angelia/AGENTS.md](https://github.com/angelia-dev/angelia/blob/main/AGENTS.md) (picking issues, when to stop and ask a human, Graft trailers, definition of done) and [docs/ESTIMATION.md](https://github.com/angelia-dev/angelia/blob/main/docs/ESTIMATION.md) (executor, complexity and model).

## Specific to this repository
- Actions must pin third-party actions by commit SHA and request the least `permissions`.
- Every input and output is documented in the action's `README.md` and tested in `.github/workflows/test.yml` with recorded event fixtures from `angelia-dev/spec`.
- Release with SemVer tags plus a moving major tag (`v1`).
