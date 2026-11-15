# Guide

The sections below show how to set up the hooks, run the checks, commit,
and release a version.

## Requirements

You need `git` and `make`.

The checks need `cog`, `dockerfmt`, `hadolint`, `jactionlint`,
`markdownlint-cli2`, `shellcheck`, `shfmt`, and `zizmor`. If you use
[mise](https://mise.jdx.dev/), run `mise install` to install them. Then
activate mise in your shell so the installed tools are on `PATH`. The
mise documentation describes the command for each shell.

## Setup

Run this command from the repository root:

```bash
make hooks
```

The target sets `core.hooksPath` to `.githook`. It also makes the three
hook files executable.

## Checks

`make ci` runs every check. It calls `scripts/ci.sh`, and that script
runs each `scripts/check-*.sh` file in name order. The run stops at the
first failure.

Run one check with a Makefile target:

```bash
make check-jactionlint
make check-bash
make check-commits
make check-dockerfmt
make check-hadolint
make check-markdown
make check-mise
make check-shfmt
make check-zizmor
```

`make check-mise` prints a skip message and exits 0 when mise is absent.
`make help` lists every target.

The checks are read-only. They report a problem and exit non-zero. They
do not change files.

## Format

`make ci` does not write files. To apply the formatters, run:

```bash
make format
```

The target calls `scripts/format.sh`, and that script runs each
`scripts/format-*.sh` file in name order. The run stops at the first
failure. Run one formatter with a Makefile target:

```bash
make format-shfmt
make format-dockerfmt
```

`make format-shfmt` writes the bash file format with `shfmt`.
`make format-dockerfmt` writes the Dockerfile and Containerfile format
with `dockerfmt`. Commit the changed files after `make format`.

GitHub Actions runs the same checks on pull requests and pushes to
`main`. The workflow is `.github/workflows/ci.yml`. The
[check pipeline](docs/ci.md) describes it.

## Git hooks

`make hooks` installs three hooks:

- `.githook/commit-msg` checks the commit message with `cog verify`.
- `.githook/pre-commit` runs `scripts/ci.sh` before each commit.
- `.githook/pre-push` runs `scripts/ci.sh` before each push.

Do not use `--no-verify` to skip a hook. A hook failure shows a real
problem. Fix the problem, then commit or push again.

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

The target runs `cog bump --auto`. It updates `CHANGELOG.md`, creates a
version commit, and creates a tag with the `v` prefix, for example
`v1.2.3`.

To see the next version and change nothing, run:

```bash
cog bump --dry-run --auto
```

The first release needs an explicit version. Use one of these commands:

```bash
cog bump --version 1.0.0
cog bump --version 0.1.0
```

Use `1.0.0` when the public interface is stable. Use `0.1.0` when the
interface can change.

## Repository layout

- `.github/workflows/ci.yml`: The GitHub Actions check workflow.
- `.githook/`: The three Git hooks.
- `scripts/`: The check and format scripts, and the `ci.sh` entry point.
- `docs/`: The check and release documents.
- `cog.toml`: The Cocogitto settings for commits, changelog, and tags.
- `Makefile`: The command targets for setup, checks, and release.
- `mise.toml`: The tool version constraints.
- `LICENSE`: The license text.

## Documentation

- [Check pipeline](docs/ci.md): How the checks run and how to add one.
- [Release workflow](docs/release.md): The commit format and release
  steps.

## License

This project uses the MIT License. See [LICENSE](LICENSE).

Copyright (c) 2026 Aza Maulana.
