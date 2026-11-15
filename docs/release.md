# Release workflow

This document describes the release workflow. The repository uses
[Cocogitto](https://docs.cocogitto.io/) for the commit checks, the
changelog, and the version bump. The command name is `cog`.

## Commit format

Write every commit subject in this form:

```text
<type>(<scope>): <description>
```

`<type>` is one of these values: `feat`, `fix`, `docs`, `test`,
`refactor`, `perf`, `build`, `ci`, `chore`.

`<scope>` is optional. Use a short name for the changed area, for
example `ci` or `hooks`. `<description>` is a short sentence in the
imperative mood. Do not end the subject with a period.

A commit that breaks compatibility adds `!` before the colon:

```text
feat(api)!: remove the old flag
```

A `BREAKING CHANGE:` footer also marks a breaking change.

## Enforcement

Three points check the commit format:

- `.githook/commit-msg`: Runs `cog verify --file` on the message before
  Git creates the commit. A bad message stops the commit.
- `scripts/check-commits.sh`: Runs `cog check` from `scripts/ci.sh`.
  `make ci` and both Git hooks run this script.
- `.githook/pre-push`: Runs `scripts/ci.sh` before each push. A bad
  commit in the history stops the push.

Do not use `--no-verify` to skip these checks. The
[check pipeline](ci.md) describes the scripts.

## Changelog

`cog bump` generates `CHANGELOG.md`. Do not edit the file by hand. The
Markdown check skips this file. The file has no entry until the first
release.

## Versioning

`cog` selects the next version from the commit types:

- `fix` bumps PATCH.
- `feat` bumps MINOR.
- `!` or `BREAKING CHANGE:` bumps MAJOR.

Tags have the `v` prefix, for example `v1.2.3`.

`cog bump --auto` never jumps from `0.y.z` to `1.0.0`. The `0.y.z`
series marks a version before the first stable release.

## Make a release

Run the release on the `main` branch. The `cog.toml` file permits a
bump on that branch only. Run this command:

```bash
make release
```

The target runs `cog bump --auto`. It does three steps:

1. It updates `CHANGELOG.md`.
2. It creates a version commit.
3. It creates a tag with the `v` prefix.

No CI release job exists. The release runs on the local machine.

## Dry run

Run this command on the `main` branch to see the next version:

```bash
cog bump --dry-run --auto
```

The command prints the next version and changes nothing. It does not
write the changelog, create a commit, or create a tag.

## First release

The repository has no tag. Select the first version before the first
release. Use one of these commands:

```bash
cog bump --version 1.0.0
cog bump --version 0.1.0
```

The choice is the maintainer's. Use `1.0.0` when the public interface
is stable. Use `0.1.0` when the interface can change.

## Troubleshooting

### `cog` is not on `PATH`

The `cog` command must be on `PATH`. The check prints this message when
the tool is absent:

```text
error: cog is not on PATH. Install cocogitto first.
```

### A commit message is rejected

The commit hook runs `cog verify`. Read the error and write the message
in the commit format. To correct the last commit, run:

```bash
git commit --amend
```

Do not use `--no-verify`.

### The Markdown check skips `CHANGELOG.md`

The skip is correct. `cog bump` generates the file and its format can
disagree with the Markdown rules. `scripts/check-markdown.sh` excludes
the file. Do not add the file to the check.
