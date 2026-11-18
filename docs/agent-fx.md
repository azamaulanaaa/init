# agent-fx check

This check asks the fx agent whether a commit message matches a change.
The agent uses the `fx` CLI. The check has two modes. The `staged` mode
checks a new message. The `history` mode checks past commits. The check
is opt-in. It runs only inside a smolvm microVM. The default `make ci`
path stays offline and does not call the fx agent.

## Precondition

`scripts/check-agent-fx.sh` has one hard precondition. The process must
run inside the smolvm guest. The guest commands in `scripts/smolvm.sh`
and `scripts/smolvm-exec.sh` set `SMOLVM_GUEST=1`. The agent-fx run command in
`scripts/agent-fx.sh` sets the same marker. The check reads this
marker. No flag and no environment variable can replace it.

`SMOLVM_ENABLED=0` is not a valid signal. The host also sets that
variable. Do not use it to enable the agent-fx check.

When the marker is absent, the check prints a warning to stderr. It
exits 0. It does not call `fx`. It does not fail the host build. The
offline checks in `scripts/ci.sh` do not change.

## Modes

Set `AGENT_FX_MODE` to select a mode. The default is `staged`.

`staged` checks one new commit message. The driver passes the message
file path and the staged diff into the guest. The prompt states a
pre-commit hook state.

`history` checks past commits. For each commit the check reads the
message with `git show -s --format=%B` and the diff with `git show
--format= --no-ext-diff`. The prompt states a post-commit history check
and names the commit hash. The check makes one fx call for each commit.
A `FAIL` verdict fails the run and names the commit. A warning prints
and the run continues. All `PASS` verdicts give exit 0.

Run `make agent-fx-history` to select history mode. The target sets
`AGENT_FX_MODE=history`.

History mode selects commits since the latest tag. When no tag exists it
selects all commits reachable from `HEAD`. `AGENT_FX_HISTORY_LIMIT`
bounds the list to the newest commits. The default is 20. Set a positive
integer.

## Run the check

Run this command from the repository root:

```bash
make agent-fx
```

`make agent-fx` calls `scripts/agent-fx.sh`. The script builds the
cached pack when it is missing. A one-shot `machine run --from` cannot
combine with the network and secret flags. The script creates a named
machine from the pack. The name is unique for each run. The script
starts the machine. It runs `scripts/check-agent-fx.sh` with `machine
exec`. The exec exit code becomes the exit code of the make target.

The script stops and deletes the machine on every path. An EXIT trap
does this cleanup on failure too. `machine create` and `machine exec`
have no timeout flag. The script uses a host `timeout` or `gtimeout`
wrapper. The cleanup trap still runs when the wrapper ends a command.

The host needs `jq` on `PATH`. The pack installs jq through mise, so the
guest has jq too. Both scripts warn and exit 0 when jq is missing.

The driver forwards `AGENT_FX_MODE`, `AGENT_FX_HISTORY_LIMIT`, and
`AGENT_FX_PROMPT` into the guest with `-e`. All three are plain values,
not secrets. The driver omits `AGENT_FX_PROMPT` when no name is set.

The check runs fx from a temporary workspace. The mise shim needs the
repository `mise.toml` to resolve the fx version there. The script sets
`MISE_GLOBAL_CONFIG_FILE` to that file before it calls fx.

Copy `.fx/settings.json.example` to `.fx/settings.json` under `.fx`. The
tracked template holds the endpoint, the model, and the auth fields. The
local `.fx/settings.json` is not committed. Keep a local copy and set it
aside with `git stash` when needed. It holds no secret. The bearer key comes
from `AGENT_FX_API_KEY`. No `AGENT_FX_CONFIG` variable exists.

The guest mounts the repository read-only at `/workspace`. The check reads
`/workspace/.fx/settings.json` from that mount. The host driver reads
`./.fx/settings.json` to find the endpoint host for `--allow-host`.

### Why the config lives in the repository

`.fx/settings.json` lives in the repository root. The read-only
`/workspace` mount carries it into the guest. The check does not use a
system-wide fx profile. The endpoint and the model stay in the repository.
They must stay the same across runs and machines.

A bare `fx` in the repository reads `.fx.json`, not `.fx/settings.json`.
This is accepted. The check copies `.fx/settings.json` into `FX_HOME` as
`settings.json` before it calls fx. A global fx config cannot change the
model that this check uses.

`.fx/settings.json` uses the fx settings format. It declares one custom connection.
Use only documented fields:

- `provider`: the connection name. It must match a key under `providers`.
  When `providers` holds one connection, the host uses it without
  `provider`.
- `providers`: the connection under that name. Use `protocol`,
  `base_url`, `auth`, and `model_metadata`. Optional fields such as
  `headers`, `timeouts`, and `tool_choice_mode` also work.
- `models`: the model ID for the connection.

The host parses `.fx/settings.json` with jq. It reports invalid JSON, an unknown
provider, or a bad `base_url` by name. It lists the available connection
names when `provider` does not match one. The check stops before it
starts the VM.

Use one of these `auth` forms:

- `{ "type": "none" }` for an endpoint that needs no key.
- `{ "type": "bearer", "env": "AGENT_FX_API_KEY" }` for a bearer key.

The fixed names are `AGENT_FX_API_KEY` and `AGENT_FX_ORG_ID`. Use
`AGENT_FX_ORG_ID` as the env name for a header entry. The check warns
and exits 0 when `auth.env` or a header env uses another name.

Export `AGENT_FX_API_KEY` on the host before you run `make agent-fx`.
Export `AGENT_FX_ORG_ID` too when the config uses a header. The driver
attaches a `--secret-env` reference on machine create. It attaches the
same reference on `machine exec`. smolvm resolves secrets for each exec
command, so the exec call needs its own reference. The key value does
not enter the command line.

The check warns and exits 0 when bearer auth is declared and the key is
missing or empty in the guest. The check does not print the key. A guest
process can read its own environment. Treat that as a known trade-off of
the opt-in path.

The endpoint host must be reachable from the guest. Use a public HTTPS
host. A loopback address on the host is not reachable from the guest.

## Git inputs

The commit message file is the primary message input. `make agent-fx`
uses `.git/COMMIT_EDITMSG` by default. Set `AGENT_FX_MESSAGE_FILE` on the
host to override that path. The driver checks that the file is readable.
It warns and exits 0 before it creates a machine when the file is
missing. An absolute path inside the repository becomes a path relative
to the repository root. A relative path resolves from `/workspace` in the
guest. The driver forwards the resolved path into the guest. The check
copies the file into the temporary workspace. The prompt names that copy.
The check does not read the `HEAD` message.

In staged mode the change input is `git diff --cached`, the staged diff
against `HEAD`. The staged diff holds the changes that will enter the
commit. The check uses the first 20000 bytes and writes them to
`staged.diff` in the temporary workspace. The prompt names that file.
When the staged diff is empty, the check prints a warning and exits 0.

In history mode the change input is the diff of each selected commit.
The check writes it to `commit.diff`. The check uses the first 20000
bytes of each diff.

The check does not write to `/workspace`. It builds its prompt in a
temporary directory.

## Prompt templates

The check keeps its prompts in `.fx/prompt/` at the repository root. Each
file in that directory is one prompt template. The file name without `.md`
is the prompt name. Commit every prompt that the team needs. Add more files
to create more prompts.

A prompt is a regular Markdown file. fx sends the selected file as its
normal prompt. fx uses its own system prompt. The check does not add a
system prompt.

Set `AGENT_FX_PROMPT` on the host to select a prompt. The driver forwards
the name into the guest as a plain value. It is not a secret. When the name
is unset, the check uses the default prompt. The committed
`.fx/prompt/default.md` holds the original instructions.

A name starts with a letter or a digit. It can hold letters, digits, dots,
underscores, and hyphens. Do not use a path separator. When the name is not
valid, the check warns and exits 0. When the file is missing, not readable,
or empty, the check warns and exits 0. The check never fails the build
because of a prompt.

When the repository under test has no `.fx/prompt/` directory, the check
reads the prompts shipped beside `scripts/check-agent-fx.sh`. This fallback
keeps the check usable in a repository that carries no prompts.

### Prompt content

Every prompt must end with one JSON object. The object has exactly two
fields: `verdict` and `reason`. `verdict` is the exact string `PASS` or
`FAIL`. `reason` is a string, and it may be empty. The prompt states that
the agent writes no text around the object and uses no markdown fence. The
check validates the object. A bad shape warns and exits 0.

A prompt may name a skill from `.fx/skills`. The default prompt permits a
skill when one is relevant. The check copies `.fx/skills` and `.fx/prompt`
into the temporary workspace so fx can find them.

### Skills

Skills stay in `.fx/skills/<name>/SKILL.md`. This is the fx discovery
layout. Each skill starts with YAML front matter:

```md
---
name: strict
description: Use this skill when the agent-fx check needs strict review.
---
```

The `name` field is required. The `description` field states when to use
the skill. The committed `default` skill is reusable. A prompt may name it
or may name another skill. Add a skill by creating a new directory under
`.fx/skills` with a `SKILL.md` file.

### Placeholders

The check replaces each placeholder before it calls fx. A placeholder uses
double braces. The check supports these names:

| Placeholder | Staged value | History value |
| --- | --- | --- |
| `{{MODE}}` | `staged` | `history` |
| `{{LABEL}}` | `staged change` | The commit hash |
| `{{MESSAGE_FILE}}` | `commit-message.txt` | `commit-message.txt` |
| `{{CHANGE_FILE}}` | `staged.diff` | `commit.diff` |
| `{{HASH}}` | An empty string | The commit hash |

The check copies the message to `commit-message.txt`. It copies the staged
diff to `staged.diff`. It copies each commit diff to `commit.diff`. The files
live in the temporary workspace. The prompt names them. fx reads them with
the read tools.

The check leaves any other placeholder text as written. Use only the names
in the table. A wrong name stays in the prompt. The agent may then return no
verdict, and the check warns.

### Add a prompt

1. Copy `.fx/prompt/default.md` to a new file in `.fx/prompt/`. Use a name
    such as `strict.md`.
2. Keep the JSON verdict instructions. The check accepts only a JSON object
    with `verdict` and `reason`.
3. Commit the new prompt.
4. Run `AGENT_FX_PROMPT=strict make agent-fx` to select the prompt. Run
    `AGENT_FX_PROMPT=strict make agent-fx-history` for history mode.

Several prompts can stay in the directory at the same time. Set a different
name for each run. `make agent-fx-all` runs every prompt in history mode.
The target ignores a caller value of `AGENT_FX_PROMPT`. It fails when one
prompt fails. CI uses this target so that every prompt is checked.

## Verdict in JSON

Both modes read the verdict from `fx ask --json`. The check uses
`.final_output`. It uses `.output` when the first field is empty. That
text must be one JSON object. The object has exactly two fields:
`verdict` and `reason`. `verdict` is the exact string `PASS` or `FAIL`.
`reason` is a string, and it may be empty. The agent writes no text
around the object, uses no markdown fence, and writes no files.

The staged prompt states a pre-commit hook state. The history prompt
states a post-commit history check and names the commit hash.

The verdict mapping is exact:

| Outcome | Action |
| --- | --- |
| `verdict` is `PASS` | Exit 0. |
| `verdict` is `FAIL` | Print the reason. Exit non-zero. |
| Empty output | Print warning. Exit 0. |
| Bad JSON | Print warning. Exit 0. |
| Missing or extra field | Print warning. Exit 0. |
| Wrong field type or value | Print warning. Exit 0. |
| Lowercase `pass` or `fail` | Print warning. Exit 0. |
| `fx ask` failed | Print warning. Exit 0. |

A warning is never a pass and never a failure. Only `PASS` gives a hard
pass. Only `FAIL` gives a hard failure. In staged mode a warning exits
0. In history mode a warning prints and the run continues. A `FAIL` in
history mode fails the run and names the commit.

## Permission rules

The check adds permission rules to the copied settings file. The rules
deny every tool first. Then they allow `read`, `glob`, and `grep`. The
last matching rule wins. fx runs with `--auto`. Shell commands, web
tools, and all file writes are denied. The check sets
`max_agent_steps=8` and a 30 second tool timeout.

## Diagnostics

Set `AGENT_FX_DEBUG=1` to print the full fx stderr and stdout for every
call. The driver forwards this value into the guest with `-e`. The
variable holds no secret.

When `fx ask` fails, the check prints the provider and the model. It
prints the last 20 lines of fx stderr and stdout. Debug mode prints
every line instead. The check replaces the key value with `***` before
it prints any stream. The key never appears in the output.

## Network exception

`make agent-fx` is an explicit exception to the offline design. The
guest command adds `--allow-host <endpoint-host>`. That flag opens
egress to the endpoint host only. It implies `--net`. The default
`make ci` path passes no network flag and stays offline. The repository
mount stays read-only in every path. `.fx/settings.json` comes from that mount.

The agent-fx call sends the commit message, the change diff, and the prompt to
the endpoint. Treat that content as external data. Use an endpoint that
your organization approves. The key stays in the host environment. The
driver forwards it with `--secret-env`. A guest process can read its own
environment. This is a known trade-off of the opt-in path.

## Nondeterministic results

The agent output is nondeterministic. The same input can give a
different verdict on another run. The model can change the verdict
without a code change. Do not treat this check as a deterministic gate.
Keep the offline checks in `make ci` as the required gate.

## Integration

Three call sites use the driver. The `commit-msg` hook calls it in staged
mode after `cog verify`. It passes the message file path from Git. The
`pre-push` hook runs `scripts/ci.sh` first, then the driver in history
mode. The GitHub Actions `agent-fx` job runs `make agent-fx-all` with
full history. That target checks every prompt template.

The CI job runs only when the repository variable `AGENT_FX_ENABLED` is
`true`. It also needs the `AGENT_FX_API_KEY` secret. The job skips the
check when the secret is absent. GitHub does not allow secrets in a job
`if`, so the key check runs in a step. CI needs a smolvm-capable runner
for the check to run. On other runners the driver warns and exits 0.

`make ci` stays offline and unchanged. The offline checks remain the
required gate.

## Tests

Run these commands to test the modes:

```bash
make test-agent-fx
make test-agent-fx-history
make test-agent-fx-prompts
make test-commit-lifecycle
```

The tests write temporary config files and use a fake `fx`. They need no
network and no credentials.
