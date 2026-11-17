#!/usr/bin/env bash
# Test the agent-fx history mode with a temporary git repo and a fake fx.
set -uo pipefail

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$script_dir/check-agent-fx.sh"

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat >"$fakebin/fx" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
hash="$(sed -n 's/^The commit hash is \(.*\)\.$/\1/p' rendered-prompt.md | head -1 || true)"
if [[ -n "$hash" ]]; then
  printf '%s\n' "$hash" >>"$FX_TEST_LOG"
fi
if grep -q 'BAD' commit-message.txt; then
  printf '%s\n' '{"final_output":"{\"verdict\":\"FAIL\",\"reason\":\"message does not match\"}"}'
elif grep -q 'WARN' commit-message.txt; then
  printf '%s\n' '{"final_output":"","output":""}'
else
  printf '%s\n' '{"final_output":"{\"verdict\":\"PASS\",\"reason\":\"message matches\"}"}'
fi
SH
chmod +x "$fakebin/fx"

config_none="$tmp/fx-none.json"
cat >"$config_none" <<'JSON'
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

make_repo() {
  local dir="$1"
  shift
  local n=0
  mkdir -p "$dir/.fx"
  git -C "$dir" init -q
  cp "$config_none" "$dir/.fx/settings.json"
  local message
  for message in "$@"; do
    n=$((n + 1))
    printf 'line %s\n' "$n" >"$dir/file.txt"
    git -C "$dir" add file.txt
    GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com \
      GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com \
      git -C "$dir" commit -q -m "$message"
  done
}

run_history() {
  local name="$1"
  local dir="$2"
  local limit="$3"
  local log="$tmp/$name.log"
  : >"$log"
  OUT="$(
    cd "$dir" || exit 1
    PATH="$fakebin:$PATH" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$dir" \
      SMOLVM_GUEST=1 AGENT_FX_MODE=history AGENT_FX_HISTORY_LIMIT="$limit" \
      FX_TEST_LOG="$log" \
      bash "$check" 2>&1
  )" && RC=0 || RC=$?
}

report() {
  local name="$1"
  local expected="$2"
  local message="$3"
  printf '%s\n' "$OUT" | sed 's/^/  | /'
  if [[ "$RC" -eq "$expected" && "$OUT" == *"$message"* ]]; then
    printf 'pass: %s (exit %d)\n' "$name" "$RC"
  else
    printf 'FAIL: %s expected exit %d and message "%s", got exit %d\n' \
      "$name" "$expected" "$message" "$RC"
    fail=1
  fi
}

repo_pass="$tmp/repo-pass"
make_repo "$repo_pass" "feat: first change" "feat: second change"
run_history two_pass "$repo_pass" 20
# The two-pass case must pass and name both commits.
if [[ "$RC" -ne 0 ]]; then
  printf 'FAIL: two_pass expected exit 0, got %d\n' "$RC"
  fail=1
fi
if (($(wc -l <"$tmp/two_pass.log") != 2)); then
  printf 'FAIL: two_pass expected two judged commits\n'
  fail=1
else
  printf 'pass: two_pass judged two commits\n'
fi

repo_fail="$tmp/repo-fail"
make_repo "$repo_fail" "feat: good change" "feat: BAD change" "feat: last change"
run_history one_fail "$repo_fail" 20
bad_sha="$(git -C "$repo_fail" log --format=%H --grep='BAD' -1)"
report one_fail 1 "not relevant (commit $bad_sha)"

repo_none="$tmp/repo-none"
make_repo "$repo_none" "feat: tagged change"
git -C "$repo_none" tag v1.0.0
run_history no_commits "$repo_none" 20
report no_commits 0 "no commits to check"

run_history limited "$repo_pass" 1
report limited 0 "agent-fx check: relevant"
if (($(wc -l <"$tmp/limited.log") != 1)); then
  printf 'FAIL: limited expected one judged commit\n'
  fail=1
else
  printf 'pass: limited judged one commit\n'
fi

repo_warn="$tmp/repo-warn"
make_repo "$repo_warn" "feat: WARN change" "feat: good change"
run_history warning_continues "$repo_warn" 20
if [[ "$RC" -ne 0 || "$OUT" != *"has no verdict"* ]]; then
  printf 'FAIL: warning case should warn and continue\n'
  fail=1
else
  printf 'pass: warning_continues (exit %d)\n' "$RC"
fi
printf '%s\n' "$OUT" | sed 's/^/  | /'

if [[ "$fail" -eq 0 ]]; then
  echo "all agent-fx history tests passed"
else
  echo "some agent-fx history tests failed" >&2
fi
exit "$fail"
