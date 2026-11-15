# Check pipeline

This document describes the local check pipeline.

## Overview

The check pipeline is the set of scripts that verify the repository. An
entry point is the command that starts the pipeline. The entry point is
[`scripts/ci.sh`](../scripts/ci.sh). It finds every check script and runs
it in name order. A check script checks one area, such as shell syntax
or the commit history.

The `pre-commit` and `pre-push` hooks and the Makefile call the same
check scripts. A Git hook is a script that Git runs at a defined event.
This design keeps one set of checks. The
[release workflow](release.md) uses the same commit format.

[`mise`](https://mise.jdx.dev/) installs development tools. It does not
start the check pipeline. The `pre-commit` and `pre-push` hooks run
`scripts/ci.sh` directly.
`make ci` runs the same script and does not call mise. `make hooks`
sets the hook path and makes the hooks executable.
`scripts/check-mise.sh` uses `mise` only to check `mise.toml`, and
skips that check when mise is absent.

## How the pieces fit

These commands and files make up the pipeline:

- `scripts/ci.sh`: Runs every `scripts/check-*.sh` in name order. Stops
  at the first failure.
- `make ci`: Runs `scripts/ci.sh`.
- `.githook/commit-msg`: Runs `cog verify` on the commit message. A bad
  message stops the commit.
- `.githook/pre-commit`: Runs `scripts/ci.sh` before each commit.
- `.githook/pre-push`: Runs `scripts/ci.sh` before each push.
- `make hooks`: Sets `core.hooksPath` to `.githook`. Makes the hooks
  executable.

The `pre-commit` and `pre-push` hooks call `scripts/ci.sh` directly.
The `commit-msg` hook calls `cog verify`. No hook calls mise. If a
required tool is missing from `PATH`, the hook fails.

`scripts/ci.sh` prints `run: <script>` before each check. It prints
`all checks passed (N scripts)` after the last check. A failed check
stops the run. The exit status is non-zero.

## Run the checks locally

### Prerequisites

You need `git` and `shellcheck` on `PATH`. You also need `make` to use
the Makefile targets. `mise` is optional. Run `make help` to list the
available targets.

### Run all checks

Run this command:

```bash
make ci
```

From the repository root, run the entry point directly:

```bash
scripts/ci.sh
```

You can also use a path that reaches the script. `scripts/ci.sh` changes
to the repository root after it starts.

`make ci` and `scripts/ci.sh` run the same checks. The Makefile target
calls the script.

The run stops at the first failed check. Fix the failure and run the
command again.

### Run one check

Run a single check through the Makefile:

```bash
make check-bash
make check-commits
make check-mise
```

These targets call `scripts/check-bash.sh`, `scripts/check-commits.sh`,
and `scripts/check-mise.sh`.

From the repository root, run a check script directly:

```bash
./scripts/check-bash.sh
```

The existing check scripts change to the repository root. A new check
script must do the same. The worktree is the checked-out copy of the
repository.

`scripts/check-mise.sh` prints a skip warning and exits 0 when `mise` is
absent. This behavior is intentional.

## Add a new check

1. Create `scripts/check-<area>.sh`. Replace `<area>` with the area name,
   for example `yaml`. Make the file executable:

   ```bash
   chmod +x scripts/check-<area>.sh
   ```

2. Start the file with a shebang, a short comment, and strict shell
   options:

   ```bash
   #!/usr/bin/env bash
   # Check every <area> file with <tool>.
   set -euo pipefail
   ```

3. Check each required command with `command -v`. Print a clear
   `error:` message to stderr when a command is missing. Exit non-zero.

4. Change to the repository root with `git rev-parse --show-toplevel`.
   Do not use a relative path or a hardcoded path.

5. Collect files from git. Include tracked and untracked files. Exclude
   ignored files. Do not use a hardcoded file list.

   ```bash
   mapfile -d '' -t files < <(
     git ls-files -z --cached --others --exclude-standard -- '<pattern>'
   )
   ```

   `--cached` selects tracked files. `--others` selects untracked files.
   `--exclude-standard` removes ignored files.

6. Run the tool in read-only mode. Do not pass a fix flag. Print one
   short result line. Return non-zero on failure. `set -e` stops the
   script when the tool exits non-zero.

7. Add the tool to [`mise.toml`](../mise.toml) when it is a development
   dependency. Run `mise use <tool>@<major>`. Do not use `latest`. Do
   not use an exact pin unless you have a reason. A major constraint
   permits bug and security fixes.

   Some tools use a backend prefix in the mise key. The key can differ
   from the command name. This command writes
   `"npm:markdownlint-cli2" = "0"` in `mise.toml`:

   ```bash
   mise use npm:markdownlint-cli2@0
   ```

   The same command provides the `markdownlint-cli2` command. Check the
   command with `command -v`, not the mise key:

   ```bash
   command -v markdownlint-cli2
   ```

8. Run `make ci`. `scripts/ci.sh` finds the new file automatically. The
   file name sets the run order. A Makefile convenience target is
   optional for the pipeline. Add one when the repository convention
   expects a direct target.

9. Test the failure path. Add a file with a known violation. Run
   `make ci` and confirm a non-zero exit. Remove the file and confirm a
   zero exit.

### When existing files fail the check

Fix the files. Do not disable the check or a rule. Add the check before
the files that must pass it. This order stops a bad file from entering
the repository. Do not add a config file that disables a rule.

### Example check script

This example is not in the repository. Do not add this file. It shows
the required structure.

```bash
#!/usr/bin/env bash
# Check every YAML file with yamllint.
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is not on PATH. Install git first." >&2
  exit 1
fi

if ! command -v yamllint >/dev/null 2>&1; then
  echo "error: yamllint is not on PATH. Install yamllint first." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

mapfile -d '' -t files < <(
  git ls-files -z --cached --others --exclude-standard -- \
    '*.yml' '*.yaml'
)

if (( ${#files[@]} == 0 )); then
  echo "no YAML files"
  exit 0
fi

yamllint --strict "${files[@]}"
echo "checked ${#files[@]} YAML files"
```

The example file would be `scripts/check-yaml.sh`. Its tool would be
installed with `mise use yamllint@1`.

A Makefile target is optional. Add the target name to the `.PHONY` line
at the top of the [Makefile](../Makefile) when you add a target.

## Use mise

mise is the local installer for development tools. It does not start the
check pipeline. No check script requires mise. The scripts use tools from
`PATH`.

Keep one tool version list in [`mise.toml`](../mise.toml). A second list
can drift and produce different results.

## Rules for a check script

A check script follows these rules:

- No network access. A check that downloads data is not deterministic.
- No writes to the worktree. Use a temporary directory for scratch files.
- No auto-fix. Report the problem and exit non-zero.
- No secrets. A check must not need credentials.
- Deterministic output. The same input gives the same result.
- Short output. Print a result line and the tool output that explains a
  failure.
- Exit non-zero on failure.

## Troubleshooting

### A required tool is not on PATH

Install the missing tool with your system package manager. Then open a
new shell.

If the tool is still absent, the check prints this message:

```text
error: shellcheck is not on PATH. Install shellcheck first.
```

### The mise config check did not run

This message is expected when mise is absent. `scripts/check-mise.sh`
exits 0. The check runs when `mise` is on `PATH`.

The check prints this message:

```text
skip: mise is not on PATH. The mise config check did not run.
```

### The hooks do not run

Run this command:

```bash
make hooks
```

The target sets the hook path and makes the hooks executable. Then run:

```bash
git config --get core.hooksPath
```

The output must be `.githook`. If the output is empty or different, run
`make hooks` again.

### A check passes on one machine but fails on another

A tool version or the environment differs. Align the tool with
[`mise.toml`](../mise.toml). Remove network access and write side effects
from the check. Reproduce the failure in a clean checkout.

### `--no-verify` bypasses the hooks

`--no-verify` skips the commit or push hooks. Use it only in an emergency.
Do not use it to merge a failing change.
