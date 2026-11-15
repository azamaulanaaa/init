# Guide

The sections below show how to install the hooks, run the checks,
commit, and release a version.

## Requirements

You need `git` and `make`.

The checks need `cog`, `dclint`, `dockerfmt`, `hadolint`, `jactionlint`,
`markdownlint-cli2`, `shellcheck`, `shfmt`, and `zizmor`. If you use
[`mise`](https://mise.jdx.dev/), run `mise install` to install these
tools. Then activate `mise` in your shell so the installed tools are on
`PATH`. The `mise` documentation describes the command for each shell.

## Setup

Run this command from the repository root:

```bash
make hooks
```

The target sets `core.hooksPath` to `.githook`. The target also makes
the three hook files executable.

## Checks

`make ci` runs every check. It calls `scripts/ci.sh`. That script runs
each `scripts/check-*.sh` file in name order. The run stops when a check
fails.

Run these commands to check one area at a time:

```bash
make check-jactionlint
make check-bash
make check-commits
make check-dclint
make check-dockerfmt
make check-hadolint
make check-markdown
make check-mise
make check-shfmt
make check-zizmor
```

`make check-mise` prints a skip message and exits 0 when `mise` is
absent. `make help` lists every target.

The checks do not change files. They report a problem and exit non-zero.

## Format

`make ci` does not write files. Run this command to apply the formatters:

```bash
make format
```

The target calls `scripts/format.sh`. That script runs each
`scripts/format-*.sh` file in name order. The run stops when a formatter
fails.

Run these commands to apply one formatter at a time:

```bash
make format-shfmt
make format-dockerfmt
make format-dclint
```

`make format-shfmt` formats the bash files with `shfmt`.
`make format-dclint` fixes the Docker Compose files with `dclint`.
`make format-dockerfmt` formats the Dockerfile and Containerfile files
with `dockerfmt`. Commit the changed files after `make format`.

GitHub Actions runs the same checks on pull requests and pushes to
`main`. The workflow is `.github/workflows/ci.yml`. The
[check pipeline](docs/ci.md) describes the workflow.

## Git hooks

`make hooks` installs three hooks:

- `.githook/commit-msg` checks the commit message with `cog verify`.
- `.githook/pre-commit` runs `scripts/ci.sh` before each commit.
- `.githook/pre-push` runs `scripts/ci.sh` before each push.

Do not use `--no-verify` to skip a hook. A failed hook shows a problem.
Fix the problem. Then commit or push again.

## Commit format

Write every commit subject in this form:

```text
<type>(<scope>): <description>
```

`<scope>` is optional. Use one of these types: `feat`, `fix`, `docs`,
`test`, `refactor`, `perf`, `build`, `ci`, `chore`.

The [release workflow](docs/release.md) describes the format and the
version rules.

## Release

Run the release on the `main` branch. `cog.toml` permits a bump on that
branch only. Run this command:

```bash
make release
```

The target runs `cog bump --auto`. It updates `CHANGELOG.md`. It creates
a version commit. It also creates a tag with the `v` prefix, for example
`v1.2.3`.

Run this command to see the next version:

```bash
cog bump --dry-run --auto
```

The command changes nothing.

The first release needs an explicit version. Run one of these commands:

```bash
cog bump --version 1.0.0
cog bump --version 0.1.0
```

Use `1.0.0` when the public interface is stable. Use `0.1.0` when the
interface can change.

## Repository layout

- `.github/workflows/ci.yml` defines the check workflow for GitHub
  Actions.
- `.githook/` contains the three Git hooks.
- `scripts/` contains the check scripts, the format scripts, and the
  `ci.sh` entry point.
- `docs/` contains the check and release documents.
- `cog.toml` contains the `Cocogitto` settings for commits, changelog,
  and tags.
- `Makefile` contains the command targets for setup, checks, and
  release.
- `mise.toml` contains the tool version constraints.
- `LICENSE` contains the license text.

## Documentation

- The [check pipeline](docs/ci.md) describes how the checks run and how
  to add a check.
- The [release workflow](docs/release.md) describes the commit format
  and the release steps.

## License

This project uses the MIT License. See [`LICENSE`](LICENSE).

Copyright (c) 2026 Aza Maulana.
