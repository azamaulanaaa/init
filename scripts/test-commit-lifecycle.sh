#!/usr/bin/env bash
# Test the smolvm machine lifecycle used by the agent-fx check.
set -uo pipefail

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
driver="$script_dir/agent-fx.sh"
fakebin="$tmp/bin"
mkdir -p "$fakebin"

cat >"$fakebin/smolvm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SMOLVM_TEST_LOG"
case "$1 $2" in
"machine create") exit "${FAKE_CREATE_RC:-0}" ;;
"machine start") exit "${FAKE_START_RC:-0}" ;;
"machine exec") exit "${FAKE_EXEC_RC:-0}" ;;
*) exit 0 ;;
esac
SH
chmod +x "$fakebin/smolvm"

make_lifecycle_repo() {
  local dir="$1"
  local with_message="$2"
  local hash
  mkdir -p "$dir/smol" "$dir/.cache/smolvm" "$dir/.fx"
  git -C "$dir" init -q
  printf '[tools]\n' >"$dir/mise.toml"
  printf 'image = "debian"\n' >"$dir/smol/base.smolfile"
  printf '# placeholder\n' >"$dir/smol/pack-build.sh"
  printf 'feat: add a feature\n' >"$dir/message.txt"
  cp "$script_dir/../.fx/settings.json.example" "$dir/.fx/settings.json"
  hash="$(cd "$dir" && sha256sum mise.toml smol/*.smolfile smol/pack-build.sh | sha256sum | cut -d' ' -f1)"
  touch "$dir/.cache/smolvm/ci-$hash.smolmachine"
  if [[ "$with_message" == "1" ]]; then
    printf 'feat: add a feature\n' >"$dir/.git/COMMIT_EDITMSG"
  fi
}

repo="$tmp/repo"
repo_no_message="$tmp/repo-no-message"
make_lifecycle_repo "$repo" 1
make_lifecycle_repo "$repo_no_message" 0

run_lifecycle() {
  local name="$1"
  local dir="$2"
  local log="$tmp/$name.log"
  : >"$log"
  (
    cd "$dir" || exit 1
    PATH="$fakebin:$PATH" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$dir" \
      SMOLVM_TEST_LOG="$log" \
      FAKE_CREATE_RC="$3" FAKE_START_RC="$4" FAKE_EXEC_RC="$5" \
      AGENT_FX_API_KEY=test-key AGENT_FX_ORG_ID=test-org \
      bash -c '
        if [[ "$2" == "UNSET" ]]; then
          unset AGENT_FX_MESSAGE_FILE
        else
          export AGENT_FX_MESSAGE_FILE="$2"
        fi
        if [[ -n "$3" ]]; then export AGENT_FX_MODE="$3"; fi
        if [[ -n "$4" ]]; then export AGENT_FX_HISTORY_LIMIT="$4"; fi
        if [[ -n "$5" ]]; then export AGENT_FX_DEBUG="$5"; fi
        source "$1" >/dev/null 2>&1
        host_accel_ok() { return 0; }
        run_with_timeout() { shift; "$@"; }
        main
      ' bash "$driver" "$6" "${7:-}" "${8:-}" "${9:-}"
  )
}

check_log() {
  local name="$1"
  shift
  local log="$tmp/$name.log"
  local content
  content="$(cat "$log")"
  local ok=0
  if [[ "$content" == *"machine run"* ]]; then
    printf 'FAIL: %s used machine run with --from\n' "$name"
    ok=1
  fi
  local needle
  for needle in "$@"; do
    if [[ "$content" != *"$needle"* ]]; then
      printf 'FAIL: %s log missing "%s"\n' "$name" "$needle"
      ok=1
    fi
  done
  if ((ok == 0)); then
    printf 'pass: %s command construction and cleanup\n' "$name"
  else
    fail=1
  fi
}

check_exec_secret() {
  local name="$1"
  shift
  local log="$tmp/$name.log"
  local line ok=0
  line="$(grep 'machine exec' "$log" || true)"
  if [[ -z "$line" ]]; then
    printf 'FAIL: %s log has no machine exec call\n' "$name"
    fail=1
    return
  fi
  local needle
  for needle in "$@"; do
    if [[ "$line" != *"$needle"* ]]; then
      printf 'FAIL: %s exec call missing "%s"\n' "$name" "$needle"
      ok=1
    fi
  done
  if ((ok == 0)); then
    printf 'pass: %s exec carries the secret refs\n' "$name"
  else
    fail=1
  fi
}

check_no_machine() {
  local name="$1"
  local log="$tmp/$name.log"
  local content
  content="$(cat "$log")"
  if [[ -s "$log" ]]; then
    printf 'FAIL: %s started a smolvm command\n' "$name"
    fail=1
  else
    printf 'pass: %s created no machine\n' "$name"
  fi
}

out="$(run_lifecycle success "$repo" 0 0 0 message.txt 2>&1)" && rc=0 || rc=$?
printf '  | exit %d\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  | /'
if [[ "$rc" -ne 0 ]]; then
  printf 'FAIL: success expected exit 0, got %d\n' "$rc"
  fail=1
fi
check_log success \
  "machine create" "--from .cache/smolvm/ci-" "--allow-host router.example.com" \
  "--secret-env AGENT_FX_API_KEY=AGENT_FX_API_KEY" \
  "--secret-env AGENT_FX_ORG_ID=AGENT_FX_ORG_ID" \
  "-e AGENT_FX_MESSAGE_FILE=message.txt" \
  "-e AGENT_FX_MODE=staged" "-e AGENT_FX_HISTORY_LIMIT=20" \
  "machine start" "machine exec" "machine stop" "machine delete --name"
check_exec_secret success \
  "--secret-env AGENT_FX_API_KEY=AGENT_FX_API_KEY" \
  "--secret-env AGENT_FX_ORG_ID=AGENT_FX_ORG_ID"

out="$(run_lifecycle exec_failure "$repo" 0 0 1 message.txt 2>&1)" && rc=0 || rc=$?
printf '  | exit %d\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  | /'
if [[ "$rc" -ne 1 ]]; then
  printf 'FAIL: exec failure expected exit 1, got %d\n' "$rc"
  fail=1
fi
check_log exec_failure \
  "machine create" "--allow-host router.example.com" \
  "--secret-env AGENT_FX_API_KEY=AGENT_FX_API_KEY" \
  "machine start" "machine exec" "machine stop" "machine delete --name"
check_exec_secret exec_failure "--secret-env AGENT_FX_API_KEY=AGENT_FX_API_KEY"

out="$(run_lifecycle create_failure "$repo" 1 0 0 message.txt 2>&1)" && rc=0 || rc=$?
printf '  | exit %d\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  | /'
if [[ "$rc" -ne 0 || "$out" != *"could not create"* ]]; then
  printf 'FAIL: create failure warning or exit code wrong\n'
  fail=1
fi
check_log create_failure "machine create" "--allow-host router.example.com" "machine stop" "machine delete --name"

out="$(run_lifecycle start_failure "$repo" 0 1 0 message.txt 2>&1)" && rc=0 || rc=$?
printf '  | exit %d\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  | /'
if [[ "$rc" -ne 0 || "$out" != *"could not start"* ]]; then
  printf 'FAIL: start failure warning or exit code wrong\n'
  fail=1
fi
check_log start_failure "machine create" "machine start" "machine stop" "machine delete --name"

out="$(run_lifecycle default_message "$repo" 0 0 0 UNSET 2>&1)" && rc=0 || rc=$?
printf '  | exit %d\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  | /'
if [[ "$rc" -ne 0 ]]; then
  printf 'FAIL: default message expected exit 0, got %d\n' "$rc"
  fail=1
fi
check_log default_message "-e AGENT_FX_MESSAGE_FILE=.git/COMMIT_EDITMSG" "machine create"

out="$(run_lifecycle absolute_message "$repo" 0 0 0 "$repo/message.txt" 2>&1)" && rc=0 || rc=$?
printf '  | exit %d\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  | /'
if [[ "$rc" -ne 0 ]]; then
  printf 'FAIL: absolute message expected exit 0, got %d\n' "$rc"
  fail=1
fi
check_log absolute_message "-e AGENT_FX_MESSAGE_FILE=message.txt" "machine create"

out="$(run_lifecycle missing_default_message "$repo_no_message" 0 0 0 UNSET 2>&1)" && rc=0 || rc=$?
printf '  | exit %d\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  | /'
if [[ "$rc" -ne 0 || "$out" != *"commit message file is missing or unreadable"* ]]; then
  printf 'FAIL: missing default message warning or exit code wrong\n'
  fail=1
fi
check_no_machine missing_default_message

out="$(run_lifecycle history_mode "$repo" 0 0 0 message.txt history 5 2>&1)" && rc=0 || rc=$?
printf '  | exit %d\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  | /'
if [[ "$rc" -ne 0 ]]; then
  printf 'FAIL: history mode expected exit 0, got %d\n' "$rc"
  fail=1
fi
check_log history_mode "-e AGENT_FX_MODE=history" "-e AGENT_FX_HISTORY_LIMIT=5" "machine create"

out="$(run_lifecycle debug_mode "$repo" 0 0 0 message.txt staged 20 1 2>&1)" && rc=0 || rc=$?
printf '  | exit %d\n' "$rc"
printf '%s\n' "$out" | sed 's/^/  | /'
if [[ "$rc" -ne 0 ]]; then
  printf 'FAIL: debug mode expected exit 0, got %d\n' "$rc"
  fail=1
fi
check_log debug_mode "-e AGENT_FX_DEBUG=1" "machine create"

if [[ "$fail" -eq 0 ]]; then
  echo "all agent-fx lifecycle tests passed"
else
  echo "some agent-fx lifecycle tests failed" >&2
fi
exit "$fail"
