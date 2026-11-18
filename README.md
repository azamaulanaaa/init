# Guide

![Checks](https://github.com/azamaulanaaa/init/actions/workflows/ci.yml/badge.svg)

The sections below show how to install the hooks, run the checks,
commit, and release a version.

## Node and Vite starter

This repository includes a minimal Node and Vite starter. It holds one
TypeScript module and one test. npm manages the packages.

Install the dependencies with this command:

```bash
npm ci
```

Run these npm scripts from the repository root:

| Script | Action |
| --- | --- |
| `npm run dev` | Start the Vite development server. |
| `npm run build` | Check the types and build the site. |
| `npm run preview` | Serve the built site. |
| `npm run test` | Run the tests with Vitest. |
| `npm run format` | Format the code with Prettier. |
| `npm run format:check` | Check the code format with Prettier. |
| `npm run audit` | Check the packages for high severity advisories. |

## Customize this template

Replace these values before you use this template:

- The default branch name `main` in `cog.toml` and `ci.yml`. Use your
  default branch name.
- The copyright holder in `LICENSE` and `README.md`. Use your name.

To add this harness to an existing repository, see
[Adopt the harness](docs/adopt.md).

## Requirements

You need `git` and `make`.

The checks need these tools on `PATH`: `cog`, `dclint`, `dockerfmt`,
`editorconfig-checker`, `gitleaks`, `hadolint`, `jactionlint`,
`markdownlint-cli2`, `shellcheck`, `shfmt`, and `zizmor`.

If you use [`mise`](https://mise.jdx.dev/), run `mise install`. Then
activate `mise` in your shell so the tools are on `PATH`.

The sandbox needs `smolvm` and a working host accelerator. See
[Compatibility and limits](#compatibility-and-limits).

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
fails. On a host with smolvm and a working accelerator, the checks run
inside a smolvm microVM. The microVM is offline and mounts the
repository read-only at `/workspace`. Without them, `make ci` prints a
warning and runs the checks on the host. Set `SMOLVM_ENABLED=1` to
require smolvm. The checks then stop with exit code 3 when smolvm
cannot run. Set `SMOLVM_ADDR` to run
the checks on a remote server. The server has no authentication by
default. Put it behind an authenticated TLS proxy. Set
`SMOLVM_SERVE_TOKEN` to send a bearer token. The scripts do not print
the token. See the [smolvm documentation](docs/smolvm.md).

Run these commands to check one area at a time:

```bash
make check-jactionlint
make check-bash
make check-commits
make check-dclint
make check-dockerfmt
make check-editorconfig
make check-gitleaks
make check-hadolint
make check-markdown
make check-mise
make check-node
make check-shfmt
make check-zizmor
```

`make check-mise` prints a skip message and exits 0 when `mise` is
absent. `make check-node` prints a skip message and exits 0 when
`node`, `npm`, or `package.json` is absent. `make help` lists every
target.

The checks do not change files. They report a problem and exit non-zero.

Run these commands to use the sandbox:

```bash
make smolvm
make smolvm-pack
make smolvm-preflight
make smolvm-verify
make smolvm-exec
make smolvm-clean
```

The sandbox is offline: the microVM runs a baked pack and asks the
registry for nothing. The repository is mounted read-only at
`/workspace`. `make smolvm-preflight` probes whether this host is
ready. `make smolvm-verify` checks that the isolation holds from
inside the guest and from the host. `make smolvm` runs the checks
inside a smolvm microVM against the live working tree.
`make smolvm-pack` builds the cached pack that the sandbox runs
from. It refuses to run while `SMOLVM_ADDR` is set.
`make smolvm-clean` removes the cached packs and deletes the dangling
machines of this checkout. Every resource name has an owner:
`smolvm-build-<owner>-<hash>`, `smolvm-run-<owner>-*`, and
`smolvm-remote-<owner>-*`. With a remote address it also deletes
`smolvm-ci-<owner>-<key>.qcow2` cache bases on the server. In local mode
the owner is the first 12 hex characters of the SHA-256 of the canonical
checkout path. Set `SMOLVM_OWNER` to use a name instead. A shared server
requires `SMOLVM_OWNER`. Use one unique value for each repository. An
empty value stops a remote command before any API call. The value uses
lowercase letters, digits, hyphen, and underscore. It starts with a
letter or a digit. It has at most 16 characters. The target prints the
plan and asks one time. Use `--dry-run` to print the plan only, or
`--yes` to skip the prompt. Set `SMOLVM_CLEAN_ASSUME_YES=1` to skip the
prompt too. A non-interactive run without a skip flag stops with an
error. Machines and bases of another owner stay. When `SMOLVM_OWNER` is
unset, a moved checkout gets a new token. Its old resources become
foreign and are reported, not deleted.
`make smolvm-exec ARGS='...'` runs one command inside the sandbox.
Set `SMOLVM_ADDR` to run the checks on a remote `smolvm serve` server.
Set `SMOLVM_OWNER` to a unique name for this repository. The remote
path needs `curl` and `tar`. It has no host fallback. It sends the git
metadata with the working tree so the checks can read the history.
`make smolvm-pack` refuses to run while `SMOLVM_ADDR` is set. Unset the
variable before you build a local pack.

Set `SMOLVM_CPUS` and `SMOLVM_MEMORY_MB` to change the CPU count and
memory of the machine. The defaults are 1 CPU and 512 MiB. Each value
must be a positive integer.

The [smolvm documentation](docs/smolvm.md) describes the environment
variables, the cache key, and the verify step.

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
make format-node
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

## Compatibility and limits

The local sandbox ran on Linux x86_64 with KVM and smolvm 1.35.1. The
remote session flow, a streamed stdin, and a local-directory upload ran
against `smolvm serve` v1.35.4. The streamed exec path ran against
v1.33.0. Check each version against your server before you rely on a
feature.

These paths are not verified:

- The full `make ci` run over HTTP. Live remote runs used
  `make smolvm-exec`.
- A successful cache publish and a warm init. The tested Windows server
  attached a seed base but refused every publish.
- macOS on Apple Silicon. The detection exists, but the path is
  untested.
- The isolation check on a KVM host. `make smolvm-verify` has not
  printed `result=isolation_held` there yet.

See the [smolvm documentation](docs/smolvm.md) for the full list.

## Repository layout

- `.github/workflows/ci.yml` defines the check workflow for GitHub
  Actions.
- `.githook/` contains the three Git hooks.
- `scripts/` contains the check scripts, the format scripts, the
  `ci.sh` entry point, and the `smolvm.sh`, `smolvm-clean.sh`,
  `smolvm-exec.sh`, and `smolvm-serve.sh` helpers.
- `smol/` contains the smolvm base machine, the shared `init.sh`
  provisioning script, and the pack build script.
- `docs/` contains the check, the release, and the smolvm documents.
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
- The [smolvm](docs/smolvm.md) describes the sandbox settings,
  the pack cache, and the known limits.

## License

This project uses the MIT License. See [`LICENSE`](LICENSE).

Copyright (c) 2026 Aza Maulana.
