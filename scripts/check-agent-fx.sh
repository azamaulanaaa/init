#!/usr/bin/env bash
# Judge commit messages against changes with the fx agent.
# Run this check only inside a smolvm guest with a repo-root settings file.
set -euo pipefail

warn() {
  echo "warning: $*" >&2
}

# The host and the offline CI path must never run the agent-fx check.
# SMOLVM_GUEST is set only in the guest commands in the smolvm scripts.
# SMOLVM_ENABLED=0 is not a signal because the host also sets it.
if [[ "${SMOLVM_GUEST:-}" != "1" ]]; then
  warn "agent-fx check runs only inside smolvm. Skipping."
  exit 0
fi

if ! command -v fx >/dev/null 2>&1; then
  warn "fx is not on PATH. Skipping the agent-fx check."
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  warn "jq is not on PATH. Skipping the agent-fx check."
  exit 0
fi

cd "$(git rev-parse --show-toplevel)"
repo_root="$PWD"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The judge runs fx from a temporary workspace. The mise shim needs the
# repository config to resolve the fx version from that directory.
export MISE_GLOBAL_CONFIG_FILE="$repo_root/mise.toml"

mode="${AGENT_FX_MODE:-staged}"
case "$mode" in
staged | history) ;;
*)
  warn "AGENT_FX_MODE $mode is not supported. Skipping the agent-fx check."
  exit 0
  ;;
esac

history_limit="${AGENT_FX_HISTORY_LIMIT:-20}"
if [[ ! "$history_limit" =~ ^[1-9][0-9]*$ ]]; then
  warn "AGENT_FX_HISTORY_LIMIT must be a positive integer. Skipping the agent-fx check."
  exit 0
fi

# The settings file lives in the repo-root .fx directory. The guest mounts
# that root read-only at /workspace. A bare fx does not read this path.
settings_json="$PWD/.fx/settings.json"
if [[ ! -r "$settings_json" ]]; then
  warn ".fx/settings.json is missing or unreadable. Skipping the agent-fx check."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fx_home="$tmp/fxhome"
mkdir -p "$fx_home"
export FX_HOME="$fx_home"
export FX_AUTO_UPGRADE=0
export FX_PERMISSION_MODE=auto
export FX_HERDR=0
export NO_COLOR=1

# Copy the repo-root settings into the temporary fx profile. The file holds
# documented fx fields only. jq reads the auth form.
meta="$tmp/config.meta"
settings="$fx_home/settings.json"
cp "$settings_json" "$settings"
if ! jq -r '
  . as $s
  | ($s.provider // "") as $p
  | ($s.providers[$p] // {}) as $c
  | ([$p, ($s.models[$p] // ""), ($c.auth.type // ""), ($c.auth.env // "")])
    + [($c.headers // {} | to_entries[] | .value.env // "" | select(. != ""))]
  | .[]
' "$settings" >"$meta"; then
  warn ".fx/settings.json is not valid fx settings. Skipping the agent-fx check."
  exit 0
fi

mapfile -t fields <"$meta"
if ((${#fields[@]} < 4)); then
  warn ".fx/settings.json is missing connection fields. Skipping the agent-fx check."
  exit 0
fi
provider="${fields[0]}"
model="${fields[1]}"
auth_type="${fields[2]}"
auth_env="${fields[3]}"

if [[ -z "$provider" || -z "$model" ]]; then
  warn ".fx/settings.json has no provider or model. Skipping the agent-fx check."
  exit 0
fi

# Restrict tools through permission rules. The rules deny every tool first.
# Then they allow read, glob, and grep. The verdict comes from JSON output,
# so fx needs no write permission. The last matching rule wins.
if ! jq '. + {
  permission: {
    "*": "deny",
    read: "allow",
    glob: "allow",
    grep: "allow"
  }
}' "$settings" >"$settings.tmp"; then
  warn "could not add permission rules. Skipping the agent-fx check."
  exit 0
fi
if ! mv "$settings.tmp" "$settings"; then
  warn "could not save permission rules. Skipping the agent-fx check."
  exit 0
fi

# The host forwards the fixed env names into the guest. Check them here.
case "$auth_type" in
none)
  ;;
bearer)
  if [[ "$auth_env" != "AGENT_FX_API_KEY" ]]; then
    warn "auth.env must be AGENT_FX_API_KEY. Skipping the agent-fx check."
    exit 0
  fi
  if [[ -z "${AGENT_FX_API_KEY:-}" ]]; then
    warn "AGENT_FX_API_KEY is missing or empty. Skipping the agent-fx check."
    exit 0
  fi
  ;;
*)
  warn "auth type $auth_type is not supported. Skipping the agent-fx check."
  exit 0
  ;;
esac

if ((${#fields[@]} > 4)); then
  for header_env in "${fields[@]:4}"; do
    if [[ "$header_env" != "AGENT_FX_ORG_ID" ]]; then
      warn "header env must be AGENT_FX_ORG_ID. Skipping the agent-fx check."
      exit 0
    fi
  done
fi

# Substitute runtime values into a prompt template. Leave unknown
# placeholders in the text so a prompt author can see the mistake.
render_prompt() {
  local raw="$1"
  local mode="$2"
  local label="$3"
  local change_file="$4"
  local hash="$5"
  local text="$raw"
  text="${text//\{\{MODE\}\}/$mode}"
  text="${text//\{\{LABEL\}\}/$label}"
  text="${text//\{\{MESSAGE_FILE\}\}/commit-message.txt}"
  text="${text//\{\{CHANGE_FILE\}\}/$change_file}"
  text="${text//\{\{HASH\}\}/$hash}"
  printf '%s\n' "$text"
}

# The core check uses a fixed prompt. Prompt templates are added later.
prompt_text="# Commit message review

You run in {{MODE}} mode.
You are checking {{LABEL}}.
Read the commit message file {{MESSAGE_FILE}}.
Read the change file {{CHANGE_FILE}}.
Decide whether the commit message describes the change.

End your answer with exactly one JSON object.
The object has exactly two fields: verdict and reason.
Set verdict to the exact string PASS or FAIL.
Write no text before or after the JSON object.
Use no markdown fence.
# Replace the key value with *** before any fx output reaches stderr.
redact_stream() {
  local value="${!auth_env:-}"
  if [[ -z "$value" ]]; then
    cat
    return
  fi
  REDACT_VALUE="$value" awk '
    BEGIN { needle = ENVIRON["REDACT_VALUE"] }
    {
      line = $0
      while ((at = index(line, needle)) > 0) {
        line = substr(line, 1, at - 1) "***" substr(line, at + length(needle))
      }
      print line
    }
  '
}

# Print fx diagnostics. Debug mode prints every line. Other runs print
# the last 20 lines of each stream.
dump_fx_output() {
  local label="$1"
  if [[ "${AGENT_FX_DEBUG:-}" == "1" ]]; then
    {
      printf 'fx stderr for %s:\n' "$label"
      redact_stream <"$tmp/fx.err"
      printf 'fx stdout for %s:\n' "$label"
      redact_stream <"$tmp/fx.out"
    } >&2
  else
    {
      printf 'fx stderr (last 20 lines):\n'
      tail -n 20 "$tmp/fx.err" | redact_stream
      printf 'fx stdout (last 20 lines):\n'
      tail -n 20 "$tmp/fx.out" | redact_stream
    } >&2
  fi
}

# Run one fx call. Return 0 for PASS, 1 for FAIL, and 2 for a warning.
judge() {
  local label="$1"
  local judge_mode="$2"
  local message="$3"
  local change="$4"
  local diff_file="staged.diff"
  local hash=""

  if [[ "$judge_mode" == "history" ]]; then
    diff_file="commit.diff"
    hash="$label"
  fi

  printf '%s\n' "$message" >"$tmp/commit-message.txt"
  printf '%s\n' "$change" >"$tmp/$diff_file"
  render_prompt "$prompt_text" "$judge_mode" "$label" "$diff_file" "$hash" >"$tmp/rendered-prompt.md"

  if ! fx ask --json --no-save --auto \
    --provider "$provider" --model "$model" \
    --config max_agent_steps=8 \
    --timeout 30 \
    <"$tmp/rendered-prompt.md" >"$tmp/fx.out" 2>"$tmp/fx.err"; then
    warn "fx ask failed for $label. provider=$provider model=$model."
    dump_fx_output "$label"
    return 2
  fi
  if [[ "${AGENT_FX_DEBUG:-}" == "1" ]]; then
    dump_fx_output "$label"
  fi

  local answer validated verdict reason
  if ! answer="$(jq -r '. as $o | ($o.final_output // "") | if . == "" then ($o.output // "") else . end' "$tmp/fx.out" 2>/dev/null)"; then
    warn "fx output for $label is not valid JSON."
    return 2
  fi
  if [[ -z "$answer" ]]; then
    warn "fx output for $label has no verdict."
    return 2
  fi

  # Accept only an object with exactly verdict and reason. The verdict
  # must be PASS or FAIL. The reason must be a string, even when empty.
  validated="$(printf '%s\n' "$answer" | jq -c '
    if type == "object" and ((keys | sort) == ["reason", "verdict"])
       and (.verdict == "PASS" or .verdict == "FAIL")
       and ((.reason | type) == "string")
    then {verdict: .verdict, reason: .reason}
    else empty end
  ' 2>/dev/null || true)"
  if [[ -z "$validated" ]]; then
    warn "fx output for $label has no valid verdict object."
    return 2
  fi

  verdict="$(printf '%s\n' "$validated" | jq -r '.verdict')"
  reason="$(printf '%s\n' "$validated" | jq -r '.reason')"
  if [[ "$verdict" == "PASS" ]]; then
    return 0
  fi
  if [[ -n "$reason" ]]; then
    printf 'reason: %s\n' "$reason" >&2
  fi
  return 1
}

# Run fx from the temporary directory. The input files stay relative to
# that workspace. The verdict comes from JSON, so fx writes no files.
cd "$tmp"

if [[ "$mode" == "staged" ]]; then
  message_file="${AGENT_FX_MESSAGE_FILE:-}"
  if [[ -z "$message_file" ]]; then
    warn "AGENT_FX_MESSAGE_FILE is not set. Skipping the agent-fx check."
    exit 0
  fi
  if [[ "$message_file" != /* ]]; then
    message_file="$repo_root/$message_file"
  fi
  if [[ ! -r "$message_file" ]]; then
    warn "commit message file is missing or unreadable. Skipping the agent-fx check."
    exit 0
  fi
  diff_text="$(git -C "$repo_root" diff --cached --no-color)"
  diff_text="${diff_text:0:20000}"
  if [[ -z "$diff_text" ]]; then
    warn "no staged change. Skipping the agent-fx check."
    exit 0
  fi
  message_text="$(cat "$message_file")"
  judge "staged change" staged "$message_text" "$diff_text" && rc=0 || rc=$?
  if ((rc == 0)); then
    echo "agent-fx check: relevant"
    exit 0
  fi
  if ((rc == 1)); then
    echo "agent-fx check: not relevant" >&2
    exit 1
  fi
  exit 0
fi

# History mode. Check the newest commits since the latest tag, or all
# commits when the repository has no tag.
if [[ -n "$(git -C "$repo_root" tag --list)" ]]; then
  latest_tag="$(git -C "$repo_root" describe --tags --abbrev=0)"
  range="$latest_tag..HEAD"
else
  range="HEAD"
fi
mapfile -t commits < <(git -C "$repo_root" log --format=%H -n "$history_limit" "$range")
if ((${#commits[@]} == 0)); then
  echo "no commits to check"
  exit 0
fi

failed=0
for sha in "${commits[@]}"; do
  message_text="$(git -C "$repo_root" show -s --format=%B "$sha")"
  change_text="$(git -C "$repo_root" show --format= --no-ext-diff "$sha")"
  change_text="${change_text:0:20000}"
  if [[ -z "$change_text" ]]; then
    warn "commit $sha has no diff."
    continue
  fi
  judge "$sha" history "$message_text" "$change_text" && rc=0 || rc=$?
  if ((rc == 0)); then
    echo "agent-fx check: relevant ($sha)"
  elif ((rc == 1)); then
    echo "agent-fx check: not relevant (commit $sha)" >&2
    failed=1
  fi
done

if ((failed)); then
  exit 1
fi
exit 0
