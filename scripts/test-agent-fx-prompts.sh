#!/usr/bin/env bash
# Test the agent-fx prompt templates with a fake fx.
set -uo pipefail

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$script_dir/check-agent-fx.sh"
driver="$script_dir/agent-fx.sh"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat >"$fakebin/fx" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FX_CAPTURE_DIR:-}" ]]; then
  prefix="$FX_CAPTURE_DIR/$FX_TEST_TAG"
  cat >"$prefix-stdin.txt"
  printf '%s\n' "$*" >"$prefix-args.txt"
  if [[ -r .fx/skills/default/SKILL.md ]]; then
    printf 'skill-visible\n' >"$prefix-skill.txt"
  fi
else
  cat >/dev/null
fi
printf '%s\n' '{"final_output":"{\"verdict\":\"PASS\",\"reason\":\"message matches\"}"}'
SH
chmod +x "$fakebin/fx"

config="$tmp/settings.json"
cat >"$config" <<'JSON'
{
  "provider": "local",
  "providers": {
    "local": {
      "protocol": "openai-chat-completions",
      "base_url": "http://127.0.0.1:11434/v1",
      "auth": { "type": "none" },
      "model_metadata": {
        "test-model": {
          "context_window": 32768,
          "max_output_tokens": 1024,
          "supports_tool_use": true
        }
      }
    }
  },
  "models": { "local": "test-model" }
}
JSON

message="$tmp/message.txt"
printf 'feat: add a feature\n' >"$message"

make_repo() {
  local dir="$1"
  mkdir -p "$dir/.fx/prompt" "$dir/.fx/skills/default"
  git -C "$dir" init -q
  cp "$config" "$dir/.fx/settings.json"
  cp "$script_dir/../.fx/skills/default/SKILL.md" "$dir/.fx/skills/default/SKILL.md"
  cp "$script_dir/../.fx/prompt/default.md" "$dir/.fx/prompt/default.md"
  printf 'first\n' >"$dir/file.txt"
  git -C "$dir" add file.txt
  GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com \
    GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com \
    git -C "$dir" commit -q -m 'feat: first change'
  printf 'second\n' >"$dir/file.txt"
  git -C "$dir" add file.txt
}

repo_plain="$tmp/repo-plain"
repo_custom="$tmp/repo-custom"
make_repo "$repo_plain"
make_repo "$repo_custom"

cat >"$repo_custom/.fx/prompt/alpha.md" <<'TXT'
# Template alpha writes each runtime value on its own line.

MODE={{MODE}}
LABEL={{LABEL}}
MESSAGE_FILE={{MESSAGE_FILE}}
CHANGE_FILE={{CHANGE_FILE}}
HASH={{HASH}}
OTHER={{UNKNOWN}}
TXT

cat >"$repo_custom/.fx/prompt/beta.md" <<'TXT'
# Template beta uses fixed text.

BETA PROMPT STAGED
Write one JSON object as the final answer.
TXT

: >"$repo_custom/.fx/prompt/empty.md"

run_check() {
  local tag="$1"
  local dir="$2"
  local prompt="$3"
  local mode="$4"
  local capture_dir="$tmp/captured/$tag"
  mkdir -p "$capture_dir"
  local env_args=(
    PATH="$fakebin:$PATH"
    GIT_CONFIG_COUNT=1
    GIT_CONFIG_KEY_0=safe.directory
    GIT_CONFIG_VALUE_0="$dir"
    SMOLVM_GUEST=1
    AGENT_FX_MESSAGE_FILE="$message"
    FX_CAPTURE_DIR="$capture_dir"
    FX_TEST_TAG="$tag"
    AGENT_FX_MODE="$mode"
  )
  if [[ "$prompt" != "UNSET" ]]; then
    env_args+=("AGENT_FX_PROMPT=$prompt")
  fi
  OUT="$(cd "$dir" && env "${env_args[@]}" bash "$check" 2>&1)" && RC=0 || RC=$?
  PROMPT_FILE="$capture_dir/$tag-stdin.txt"
  ARGS_FILE="$capture_dir/$tag-args.txt"
  SKILL_FILE="$capture_dir/$tag-skill.txt"
}

report() {
  local name="$1"
  local expected="$2"
  local wanted="$3"
  if [[ "$RC" -eq "$expected" && "$OUT" == *"$wanted"* ]]; then
    printf 'pass: %s (exit %d)\n' "$name" "$RC"
  else
    printf 'FAIL: %s expected exit %d and message "%s", got exit %d\n' \
      "$name" "$expected" "$wanted" "$RC"
    fail=1
  fi
  printf '%s\n' "$OUT" | sed 's/^/  | /'
}

assert_line() {
  local name="$1"
  local file="$2"
  local wanted="$3"
  if [[ -f "$file" ]] && grep -qxF "$wanted" "$file"; then
    printf 'pass: %s\n' "$name"
  else
    printf 'FAIL: %s has no line "%s"\n' "$name" "$wanted"
    fail=1
  fi
}

assert_absent_line() {
  local name="$1"
  local file="$2"
  local unwanted="$3"
  if [[ ! -f "$file" ]] || ! grep -qF "$unwanted" "$file"; then
    printf 'pass: %s\n' "$name"
  else
    printf 'FAIL: %s has the line "%s"\n' "$name" "$unwanted"
    fail=1
  fi
}

assert_no_prompt() {
  local name="$1"
  if [[ ! -e "$PROMPT_FILE" ]]; then
    printf 'pass: %s\n' "$name"
  else
    printf 'FAIL: %s sent a prompt to fx\n' "$name"
    fail=1
  fi
}

assert_same_bytes() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if cmp -s "$expected" "$actual"; then
    printf 'pass: %s\n' "$name"
  else
    printf 'FAIL: %s has different bytes\n' "$name"
    fail=1
  fi
}

# These expected files hold the rendered default prompt. They guard the
# default template against a change in wording.
expected_staged="$tmp/expected-staged.txt"
{
  printf '%s\n' '# Commit message review'
  printf '%s\n' ''
  printf '%s\n' 'You run in staged mode.'
  printf '%s\n' 'You are checking staged change.'
  printf '%s\n' 'The commit hash is .'
  printf '%s\n' 'Read the commit message file commit-message.txt.'
  printf '%s\n' 'Read the change file staged.diff.'
  printf '%s\n' 'Decide whether the commit message describes the change.'
  printf '%s\n' ''
  printf '%s\n' 'You may apply a skill from .fx/skills when one is relevant.'
  printf '%s\n' ''
  printf '%s\n' 'End your answer with exactly one JSON object.'
  printf '%s\n' 'The object has exactly two fields: verdict and reason.'
  printf '%s\n' 'Set verdict to the exact string PASS or FAIL.'
  printf '%s\n' 'Set verdict to PASS when the message describes the change.'
  printf '%s\n' 'Set verdict to FAIL when it does not.'
  printf '%s\n' 'Set reason to a short string. The string may be empty.'
  printf '%s\n' 'Write no text before or after the JSON object.'
  printf '%s\n' 'Use no markdown fence.'
  printf '%s\n' 'Call no tool other than the read tools.'
  printf '%s\n' 'Do not run shell commands.'
  printf '%s\n' 'Do not use web tools.'
} >"$expected_staged"

# An unset name selects the default prompt.
run_check default_when_unset "$repo_plain" UNSET staged
report default_when_unset 0 "agent-fx check: relevant"
assert_same_bytes default_staged_bytes "$expected_staged" "$PROMPT_FILE"
assert_line skills_copied "$SKILL_FILE" 'skill-visible'
assert_absent_line no_system_injection "$ARGS_FILE" '--system'

# The named default prompt must render the same text as the unset name.
run_check default_when_named "$repo_plain" default staged
report default_when_named 0 "agent-fx check: relevant"
assert_same_bytes named_default_matches_unset \
  "$tmp/captured/default_when_unset/default_when_unset-stdin.txt" "$PROMPT_FILE"

# A custom name selects its own prompt.
run_check custom_selected "$repo_custom" alpha staged
report custom_selected 0 "agent-fx check: relevant"
assert_line custom_mode_selected "$PROMPT_FILE" 'MODE=staged'
assert_line custom_label_selected "$PROMPT_FILE" 'LABEL=staged change'
assert_absent_line custom_fixed_text_absent "$PROMPT_FILE" 'BETA PROMPT STAGED'

# Every placeholder is replaced in the rendered prompt.
run_check placeholders_staged "$repo_custom" alpha staged
report placeholders_staged 0 "agent-fx check: relevant"
assert_line staged_mode "$PROMPT_FILE" 'MODE=staged'
assert_line staged_label "$PROMPT_FILE" 'LABEL=staged change'
assert_line staged_message_file "$PROMPT_FILE" 'MESSAGE_FILE=commit-message.txt'
assert_line staged_change_file "$PROMPT_FILE" 'CHANGE_FILE=staged.diff'
assert_line staged_empty_hash "$PROMPT_FILE" 'HASH='
assert_line unknown_placeholder_left "$PROMPT_FILE" 'OTHER={{UNKNOWN}}'

sha="$(git -C "$repo_custom" log --format=%H -1)"
run_check placeholders_history "$repo_custom" alpha history
report placeholders_history 0 "agent-fx check: relevant ($sha)"
assert_line history_mode "$PROMPT_FILE" 'MODE=history'
assert_line history_label "$PROMPT_FILE" "LABEL=$sha"
assert_line history_message_file "$PROMPT_FILE" 'MESSAGE_FILE=commit-message.txt'
assert_line history_change_file "$PROMPT_FILE" 'CHANGE_FILE=commit.diff'
assert_line history_hash "$PROMPT_FILE" "HASH=$sha"

# The default history prompt names the commit hash and the diff file.
expected_history="$tmp/expected-history.txt"
sed \
  -e "s/^You run in staged mode\.$/You run in history mode./" \
  -e "s/^You are checking staged change\.$/You are checking $sha./" \
  -e "s/^The commit hash is \.$/The commit hash is $sha./" \
  -e 's/^Read the change file staged\.diff\.$/Read the change file commit.diff./' \
  "$expected_staged" >"$expected_history"
run_check default_history_bytes "$repo_custom" UNSET history
report default_history_bytes 0 "agent-fx check: relevant ($sha)"
assert_same_bytes default_history_render "$expected_history" "$PROMPT_FILE"

# Two prompts coexist in one directory and stay independent.
run_check beta_selected "$repo_custom" beta staged
report beta_selected 0 "agent-fx check: relevant"
assert_line beta_prompt "$PROMPT_FILE" 'BETA PROMPT STAGED'
assert_absent_line beta_has_no_alpha_text "$PROMPT_FILE" 'MODE='

# An unknown name warns and skips without calling fx.
run_check unknown_prompt "$repo_custom" missing staged
report unknown_prompt 0 'prompt missing is missing or unreadable'
assert_no_prompt unknown_prompt_skipped_fx

# A name with a path separator warns and skips without calling fx.
run_check invalid_name "$repo_custom" '../evil' staged
report invalid_name 0 'is not a valid prompt name'
assert_no_prompt invalid_name_skipped_fx

# An empty prompt warns and skips without calling fx.
run_check empty_prompt "$repo_custom" empty staged
report empty_prompt 0 'prompt empty has no text'
assert_no_prompt empty_prompt_skipped_fx

# The host driver forwards the name as a plain value.
smolbindir="$tmp/smolbin"
mkdir -p "$smolbindir"
cat >"$smolbindir/smolvm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SMOLVM_TEST_LOG"
exit 0
SH
chmod +x "$smolbindir/smolvm"

driver_repo="$tmp/driver-repo"
mkdir -p "$driver_repo/smol" "$driver_repo/.cache/smolvm" "$driver_repo/.fx"
git -C "$driver_repo" init -q
printf '[tools]\n' >"$driver_repo/mise.toml"
printf 'image = "debian"\n' >"$driver_repo/smol/base.smolfile"
printf '# placeholder\n' >"$driver_repo/smol/pack-build.sh"
printf 'feat: add a feature\n' >"$driver_repo/message.txt"
cp "$script_dir/../.fx/settings.json.example" "$driver_repo/.fx/settings.json"
pack_hash="$(cd "$driver_repo" && sha256sum mise.toml smol/*.smolfile smol/pack-build.sh | sha256sum | cut -d' ' -f1)"
touch "$driver_repo/.cache/smolvm/ci-$pack_hash.smolmachine"

run_driver() {
  local tag="$1"
  local prompt="$2"
  local log="$tmp/$tag-driver.log"
  : >"$log"
  (
    cd "$driver_repo" || exit 1
    PATH="$smolbindir:$PATH" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$driver_repo" \
      SMOLVM_TEST_LOG="$log" \
      AGENT_FX_API_KEY=test-key AGENT_FX_ORG_ID=test-org \
      AGENT_FX_MESSAGE_FILE=message.txt \
      bash -c '
        if [[ -n "$1" ]]; then export AGENT_FX_PROMPT="$1"; else unset AGENT_FX_PROMPT; fi
        source "$2" >/dev/null 2>&1
        host_accel_ok() { return 0; }
        run_with_timeout() { shift; "$@"; }
        main
      ' bash "$prompt" "$driver"
  ) && DRIVER_RC=0 || DRIVER_RC=$?
  DRIVER_LOG="$log"
}

run_driver forwarded alpha
if [[ "$DRIVER_RC" -eq 0 ]] && grep -qF -- '-e AGENT_FX_PROMPT=alpha' "$DRIVER_LOG" &&
  ! grep -qF -- '--secret-env AGENT_FX_PROMPT' "$DRIVER_LOG"; then
  printf 'pass: driver forwards the prompt name as a plain value\n'
else
  printf 'FAIL: driver did not forward the prompt name as a plain value\n'
  fail=1
fi
printf '%s\n' "$(cat "$DRIVER_LOG")" | sed 's/^/  | /'

run_driver not_forwarded ''
if [[ "$DRIVER_RC" -eq 0 ]] && ! grep -qF 'AGENT_FX_PROMPT' "$DRIVER_LOG"; then
  printf 'pass: driver omits the prompt name when no name is set\n'
else
  printf 'FAIL: driver sent a prompt name when no name is set\n'
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "all agent-fx prompt template tests passed"
else
  echo "some agent-fx prompt template tests failed" >&2
fi
exit "$fail"
