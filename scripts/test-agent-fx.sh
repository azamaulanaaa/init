#!/usr/bin/env bash
# Test the agent-fx check guard and strict verdict parsing with a fake fx.
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
if [[ -n "${FX_ENV_LOG:-}" ]]; then
  printf 'MISE_GLOBAL_CONFIG_FILE=%s\n' "${MISE_GLOBAL_CONFIG_FILE:-}" >>"$FX_ENV_LOG"
fi
if [[ -n "${FX_SETTINGS_LOG:-}" ]]; then
  jq -c '.permission' "$FX_HOME/settings.json" >>"$FX_SETTINGS_LOG"
fi
if [[ "${FAKE_DENIED:-0}" == "1" ]]; then
  echo "error: bash is denied by the permission rules" >&2
  exit 1
fi
if [[ "${FAKE_FX_FAIL:-0}" == "1" ]]; then
  printf 'error: upstream refused key %s\n' "${AGENT_FX_API_KEY:-}" >&2
  printf '%s\n' '{"output":"failure","exit_code":1}'
  exit 1
fi
case "${FAKE_JSON_MODE:-pass}" in
pass) printf '%s\n' '{"final_output":"{\"verdict\":\"PASS\",\"reason\":\"message matches\"}","output":""}' ;;
fail) printf '%s\n' '{"final_output":"{\"verdict\":\"FAIL\",\"reason\":\"message does not match\"}","output":""}' ;;
empty_reason) printf '%s\n' '{"final_output":"{\"verdict\":\"PASS\",\"reason\":\"\"}"}' ;;
fallback) printf '%s\n' '{"final_output":"","output":"{\"verdict\":\"PASS\",\"reason\":\"fallback reason\"}"}' ;;
empty) printf '%s\n' '{"final_output":"","output":""}' ;;
missing_final) printf '%s\n' '{"output":""}' ;;
bad_json) printf '%s\n' 'not-json' ;;
inner_bad_json) printf '%s\n' '{"final_output":"not-json"}' ;;
missing_verdict) printf '%s\n' '{"final_output":"{\"reason\":\"only reason\"}"}' ;;
missing_reason) printf '%s\n' '{"final_output":"{\"verdict\":\"PASS\"}"}' ;;
extra_key) printf '%s\n' '{"final_output":"{\"verdict\":\"PASS\",\"reason\":\"x\",\"extra\":1}"}' ;;
lowercase) printf '%s\n' '{"final_output":"{\"verdict\":\"pass\",\"reason\":\"x\"}"}' ;;
wrong_type) printf '%s\n' '{"final_output":"{\"verdict\":1,\"reason\":\"x\"}"}' ;;
*) printf '%s\n' '{"final_output":"{\"verdict\":\"PASS\",\"reason\":\"x\"}"}' ;;
esac
SH
chmod +x "$fakebin/fx"

config_bearer="$tmp/fx-bearer.json"
cat >"$config_bearer" <<'JSON'
{
  "provider": "router",
  "providers": {
    "router": {
      "protocol": "openai-chat-completions",
      "base_url": "https://router.example.com/v1",
      "auth": { "type": "bearer", "env": "AGENT_FX_API_KEY" },
      "headers": { "X-Org-Id": { "env": "AGENT_FX_ORG_ID" } },
      "model_metadata": {
        "test-model": {
          "context_window": 32768,
          "max_output_tokens": 1024,
          "supports_tool_use": true
        }
      }
    }
  },
  "models": { "router": "test-model" }
}
JSON

config_bad_env="$tmp/fx-bad-env.json"
cat >"$config_bad_env" <<'JSON'
{
  "provider": "router",
  "providers": {
    "router": {
      "protocol": "openai-chat-completions",
      "base_url": "https://router.example.com/v1",
      "auth": { "type": "bearer", "env": "CUSTOM_KEY" },
      "model_metadata": {
        "test-model": {
          "context_window": 32768,
          "max_output_tokens": 1024,
          "supports_tool_use": true
        }
      }
    }
  },
  "models": { "router": "test-model" }
}
JSON

config_bad_header="$tmp/fx-bad-header.json"
cat >"$config_bad_header" <<'JSON'
{
  "provider": "router",
  "providers": {
    "router": {
      "protocol": "openai-chat-completions",
      "base_url": "https://router.example.com/v1",
      "auth": { "type": "bearer", "env": "AGENT_FX_API_KEY" },
      "headers": { "X-Org-Id": { "env": "CUSTOM_ORG" } },
      "model_metadata": {
        "test-model": {
          "context_window": 32768,
          "max_output_tokens": 1024,
          "supports_tool_use": true
        }
      }
    }
  },
  "models": { "router": "test-model" }
}
JSON

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

repo="$tmp/repo"
repo_no_config="$tmp/repo-no-config"

# The temporary repos have unmapped owners. Trust them through the
# environment. The check script inherits these values.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$repo"
export GIT_CONFIG_KEY_1=safe.directory
export GIT_CONFIG_VALUE_1="$repo_no_config"

make_repo() {
  local dir="$1"
  mkdir -p "$dir/.fx"
  git -C "$dir" init -q
  printf 'initial\n' >"$dir/file.txt"
  git -C "$dir" add file.txt
  GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com \
    GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com \
    git -C "$dir" commit -q -m 'chore: initial'
  printf 'changed\n' >"$dir/file.txt"
  git -C "$dir" add file.txt
}

make_repo "$repo"
make_repo "$repo_no_config"
printf 'feat: add a feature\n' >"$tmp/message.txt"
cp "$config_bearer" "$repo/.fx/settings.json"

use_config() {
  cp "$1" "$repo/.fx/settings.json"
}

base=(
  PATH="$fakebin:$PATH"
  AGENT_FX_MESSAGE_FILE="$tmp/message.txt"
  AGENT_FX_API_KEY=test-key
  AGENT_FX_ORG_ID=test-org
)
base_no_key=(
  PATH="$fakebin:$PATH"
  AGENT_FX_MESSAGE_FILE="$tmp/message.txt"
  AGENT_FX_ORG_ID=test-org
)
base_no_message=(PATH="$fakebin:$PATH" AGENT_FX_API_KEY=test-key)
base_no_jq=(
  PATH="$fakebin:/usr/bin:/bin"
  AGENT_FX_MESSAGE_FILE="$tmp/message.txt"
  AGENT_FX_API_KEY=test-key
  AGENT_FX_ORG_ID=test-org
)

run_case() {
  local name="$1"
  local expected="$2"
  local message="$3"
  local dir="$4"
  local out rc
  shift 4
  out="$(cd "$dir" && env "$@" bash "$check" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" -eq "$expected" && "$out" == *"$message"* ]]; then
    printf 'pass: %s (exit %d)\n' "$name" "$rc"
  else
    printf 'FAIL: %s expected exit %d and message "%s", got exit %d\n' \
      "$name" "$expected" "$message" "$rc"
    fail=1
  fi
  printf '%s\n' "$out" | sed 's/^/  | /'
}

run_case_redacted() {
  local name="$1"
  local expected="$2"
  local message="$3"
  local forbidden="$4"
  local dir="$5"
  local out rc ok=0
  shift 5
  out="$(cd "$dir" && env "$@" bash "$check" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" -ne "$expected" ]]; then
    printf 'FAIL: %s expected exit %d, got %d\n' "$name" "$expected" "$rc"
    ok=1
  fi
  if [[ "$out" != *"$message"* ]]; then
    printf 'FAIL: %s missing message "%s"\n' "$name" "$message"
    ok=1
  fi
  if [[ "$out" == *"$forbidden"* ]]; then
    printf 'FAIL: %s leaked the key value\n' "$name"
    ok=1
  fi
  if ((ok == 0)); then
    printf 'pass: %s (exit %d, key redacted)\n' "$name" "$rc"
  else
    fail=1
  fi
  printf '%s\n' "$out" | sed 's/^/  | /'
}

run_case host_guard 0 "runs only inside smolvm" "$repo" "${base[@]}"
run_case missing_jq 0 "jq is not on PATH" "$repo" "${base_no_jq[@]}" SMOLVM_GUEST=1
run_case missing_settings 0 ".fx/settings.json is missing" "$repo_no_config" "${base[@]}" SMOLVM_GUEST=1
run_case missing_message_var 0 "AGENT_FX_MESSAGE_FILE is not set" "$repo" "${base_no_message[@]}" SMOLVM_GUEST=1
run_case missing_message_file 0 "commit message file is missing or unreadable" "$repo" "${base[@]}" SMOLVM_GUEST=1 AGENT_FX_MESSAGE_FILE="$tmp/no-such-message.txt"
run_case missing_key_env 0 "AGENT_FX_API_KEY is missing or empty" "$repo" "${base_no_key[@]}" SMOLVM_GUEST=1

use_config "$config_bad_env"
run_case invalid_auth_env 0 "auth.env must be AGENT_FX_API_KEY" "$repo" "${base[@]}" SMOLVM_GUEST=1
use_config "$config_bad_header"
run_case invalid_header_env 0 "header env must be AGENT_FX_ORG_ID" "$repo" "${base[@]}" SMOLVM_GUEST=1
use_config "$config_none"
run_case auth_none 0 "agent-fx check: relevant" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=pass

use_config "$config_bearer"
run_case verdict_pass 0 "agent-fx check: relevant" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=pass
run_case verdict_fail 1 "reason: message does not match" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=fail
run_case empty_reason 0 "agent-fx check: relevant" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=empty_reason
run_case fallback_output 0 "agent-fx check: relevant" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=fallback
run_case empty_output 0 "has no verdict" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=empty
run_case missing_final_output 0 "has no verdict" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=missing_final
run_case bad_json 0 "not valid JSON" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=bad_json
run_case inner_bad_json 0 "no valid verdict object" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=inner_bad_json
run_case missing_verdict 0 "no valid verdict object" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=missing_verdict
run_case missing_reason 0 "no valid verdict object" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=missing_reason
run_case extra_key 0 "no valid verdict object" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=extra_key
run_case lowercase_verdict 0 "no valid verdict object" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=lowercase
run_case wrong_type_verdict 0 "no valid verdict object" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=wrong_type
run_case denied_tool 0 "fx ask failed" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_DENIED=1
run_case_redacted fx_error_redacted 0 "upstream refused key" "test-key" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_FX_FAIL=1
run_case fx_error_provider 0 "provider=router" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_FX_FAIL=1
run_case fx_error_model 0 "model=test-model" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_FX_FAIL=1
run_case_redacted fx_debug_redacted 0 "fx stdout for staged change" "test-key" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_FX_FAIL=1 AGENT_FX_DEBUG=1

fx_env_log="$tmp/fx-env.log"
: >"$fx_env_log"
FX_ENV_LOG="$fx_env_log" run_case mise_config_env 0 "agent-fx check: relevant" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=pass
if grep -qx "MISE_GLOBAL_CONFIG_FILE=$repo/mise.toml" "$fx_env_log"; then
  printf 'pass: mise config points at the repository mise.toml\n'
else
  printf 'FAIL: mise config path is wrong\n'
  fail=1
fi

fx_settings_log="$tmp/fx-settings.log"
: >"$fx_settings_log"
FX_SETTINGS_LOG="$fx_settings_log" run_case permission_read_only 0 "agent-fx check: relevant" "$repo" "${base[@]}" SMOLVM_GUEST=1 FAKE_JSON_MODE=pass
if grep -q '"\*":"deny"' "$fx_settings_log" &&
  grep -q '"read":"allow"' "$fx_settings_log" &&
  grep -q '"glob":"allow"' "$fx_settings_log" &&
  grep -q '"grep":"allow"' "$fx_settings_log" &&
  ! grep -q '"edit"' "$fx_settings_log"; then
  printf 'pass: permission rules are read-only\n'
else
  printf 'FAIL: permission rules are not read-only\n'
  cat "$fx_settings_log"
  fail=1
fi

# Host-side endpoint resolution. Source the driver and call its function.
host_root="$tmp/host-config"
mkdir -p "$host_root"/{example,invalid,single,multi,no_url,no_scheme}
for hcase in example invalid single multi no_url no_scheme; do
  mkdir -p "$host_root/$hcase/.fx"
done
cp "$script_dir/../.fx/settings.json.example" "$host_root/example/.fx/settings.json"
printf '%s\n' '{' >"$host_root/invalid/.fx/settings.json"
cat >"$host_root/single/.fx/settings.json" <<'JSON'
{
  "providers": {
    "only": {
      "base_url": "https://one.example.com/v1",
      "auth": { "type": "none" }
    }
  },
  "models": { "only": "test-model" }
}
JSON
cat >"$host_root/multi/.fx/settings.json" <<'JSON'
{
  "provider": "missing",
  "providers": {
    "alpha": { "base_url": "https://alpha.example.com/v1" },
    "beta": { "base_url": "https://beta.example.com/v1" }
  },
  "models": { "alpha": "test-model", "beta": "test-model" }
}
JSON
cat >"$host_root/no_url/.fx/settings.json" <<'JSON'
{
  "provider": "only",
  "providers": { "only": { "auth": { "type": "none" } } },
  "models": { "only": "test-model" }
}
JSON
cat >"$host_root/no_scheme/.fx/settings.json" <<'JSON'
{
  "provider": "only",
  "providers": { "only": { "base_url": "one.example.com/v1" } },
  "models": { "only": "test-model" }
}
JSON

run_host_case() {
  local name="$1"
  local expected="$2"
  local message="$3"
  local dir="$4"
  local out rc
  out="$(
    (
      cd "$dir" || exit 1
      # shellcheck source=/dev/null
      source "$driver" >/dev/null 2>&1
      set +e
      resolve_endpoint
    ) 2>&1
  )" && rc=0 || rc=$?
  if [[ "$rc" -eq "$expected" && "$out" == *"$message"* ]]; then
    printf 'pass: %s (exit %d)\n' "$name" "$rc"
  else
    printf 'FAIL: %s expected exit %d and message "%s", got exit %d\n' \
      "$name" "$expected" "$message" "$rc"
    fail=1
  fi
  printf '%s\n' "$out" | sed 's/^/  | /'
}

run_host_case example_config 0 "router.example.com" "$host_root/example"
run_host_case invalid_json 1 ".fx/settings.json is not valid JSON" "$host_root/invalid"
run_host_case single_connection 0 "one.example.com" "$host_root/single"
run_host_case provider_mismatch 1 "Available connections: alpha beta" "$host_root/multi"
run_host_case missing_base_url 1 "has no base_url" "$host_root/no_url"
run_host_case base_url_without_scheme 1 "has no scheme" "$host_root/no_scheme"

if [[ "$fail" -eq 0 ]]; then
  echo "all agent-fx check tests passed"
else
  echo "some agent-fx check tests failed" >&2
fi
exit "$fail"
