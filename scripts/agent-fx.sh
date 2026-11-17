#!/usr/bin/env bash
# Run the agent-fx check inside a smolvm microVM.
# This opt-in path grants network and reads the repo-root .fx settings.
set -euo pipefail

warn() {
  echo "warning: $*" >&2
}

machine_name=""
cleanup() {
  if [[ -n "$machine_name" ]]; then
    smolvm machine stop --name "$machine_name" >/dev/null 2>&1 || true
    smolvm machine delete --name "$machine_name" --force >/dev/null 2>&1 || true
  fi
}

host_accel_ok() {
  command -v smolvm >/dev/null 2>&1 || return 1
  case "$(uname -s)" in
  Linux)
    [[ -e /dev/kvm && -r /dev/kvm ]]
    ;;
  Darwin)
    case "$(uname -m)" in
    arm64 | aarch64) [[ "$(sysctl -n kern.hv_support 2>/dev/null)" == "1" ]] ;;
    *) return 1 ;;
    esac
    ;;
  *) return 1 ;;
  esac
}

# machine create and machine exec have no timeout flag. Use a host
# timeout when one is available. The EXIT trap still cleans the machine.
run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    "$@"
  fi
}

# Resolve the endpoint host from ./.fx/settings.json. Write the host to stdout.
# Warn to stderr and return 1 when the config cannot be used.
resolve_endpoint() {
  local check_out provider names=() valid=0 base_url endpoint

  if ! check_out="$(jq -e . ./.fx/settings.json 2>&1)"; then
    warn ".fx/settings.json is not valid JSON. $check_out"
    return 1
  fi

  provider="$(jq -r '.provider // ""' ./.fx/settings.json)"
  mapfile -t names < <(jq -r '.providers | if type == "object" then keys[] else empty end' ./.fx/settings.json)

  if [[ -n "$provider" ]] && jq -e --arg p "$provider" \
    '.providers | if type == "object" then has($p) else false end' ./.fx/settings.json >/dev/null; then
    valid=1
  fi
  if ((valid == 0)) && ((${#names[@]} == 1)); then
    provider="${names[0]}"
    valid=1
  fi
  if ((valid == 0)); then
    if [[ -z "$provider" ]]; then
      warn ".fx/settings.json has no provider. Available connections: ${names[*]:-none}. Set provider to one of these names."
    else
      warn ".fx/settings.json provider $provider does not match a connection. Available connections: ${names[*]:-none}. Set provider to one of these names."
    fi
    return 1
  fi

  base_url="$(jq -r --arg p "$provider" '.providers[$p].base_url // ""' ./.fx/settings.json)"
  if [[ -z "$base_url" ]]; then
    warn ".fx/settings.json has no base_url for provider $provider."
    return 1
  fi
  if [[ "$base_url" != *"://"* ]]; then
    warn ".fx/settings.json base_url for provider $provider has no scheme."
    return 1
  fi
  endpoint="$(printf '%s\n' "$base_url" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://([^/:?]+).*#\1#')"
  if [[ -z "$endpoint" ]]; then
    warn ".fx/settings.json base_url for provider $provider has no host."
    return 1
  fi
  printf '%s\n' "$endpoint"
}

main() {
  git config --global --add safe.directory "${GITHUB_WORKSPACE:-$PWD}" >/dev/null 2>&1 || true
  cd "$(git rev-parse --show-toplevel)"

  # Use the Git message file by default. The guest resolves relative
  # paths from /workspace, so keep paths inside the repository relative.
  local message_file
  message_file="${AGENT_FX_MESSAGE_FILE:-}"
  if [[ -z "$message_file" ]]; then
    message_file=".git/COMMIT_EDITMSG"
  fi
  if [[ "$message_file" == /* ]]; then
    case "$message_file" in
    "$PWD"/*) message_file="${message_file#"$PWD"/}" ;;
    esac
  fi
  if [[ ! -r "$message_file" ]]; then
    warn "commit message file is missing or unreadable. The agent-fx check did not run."
    return 0
  fi

  if ! host_accel_ok; then
    warn "smolvm or the host accelerator is not available. The agent-fx check did not run."
    return 0
  fi

  if [[ ! -r ./.fx/settings.json ]]; then
    warn ".fx/settings.json is missing in the repository root. The agent-fx check did not run."
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq is not on PATH. The agent-fx check did not run."
    return 0
  fi

  local endpoint_host
  endpoint_host="$(resolve_endpoint)" || return 0

  if ! command -v sha256sum >/dev/null 2>&1; then
    warn "sha256sum is not on PATH. The agent-fx check did not run."
    return 0
  fi

  local hash pack
  hash="$(sha256sum mise.toml smol/*.smolfile smol/pack-build.sh | sha256sum | cut -d' ' -f1)"
  pack=".cache/smolvm/ci-${hash}.smolmachine"
  if [[ ! -f "$pack" ]]; then
    if ! smol/pack-build.sh "$hash"; then
      warn "the smolvm pack build failed. The agent-fx check did not run."
      return 0
    fi
  fi
  if [[ ! -f "$pack" ]]; then
    warn "pack was not built: $pack. The agent-fx check did not run."
    return 0
  fi

  # A one-shot machine run rejects --allow-host and --secret-env when
  # --from is present. Use a named machine from the pack instead. The
  # secret reference is attached on create and again on exec.
  machine_name="agent-fx-$$-$(date +%s)"
  trap cleanup EXIT

  local create_args=(
    machine create --name "$machine_name" --from "$pack"
    -v "$PWD":/workspace:ro
    --allow-host "$endpoint_host"
    --secret-env AGENT_FX_API_KEY=AGENT_FX_API_KEY
  )
  if [[ -n "${AGENT_FX_ORG_ID:-}" ]]; then
    create_args+=(--secret-env AGENT_FX_ORG_ID=AGENT_FX_ORG_ID)
  fi
  create_args+=(-e "AGENT_FX_MESSAGE_FILE=$message_file")
  create_args+=(-e "AGENT_FX_MODE=${AGENT_FX_MODE:-staged}")
  create_args+=(-e "AGENT_FX_HISTORY_LIMIT=${AGENT_FX_HISTORY_LIMIT:-20}")
  if [[ -n "${AGENT_FX_PROMPT:-}" ]]; then
    create_args+=(-e "AGENT_FX_PROMPT=$AGENT_FX_PROMPT")
  fi
  if [[ -n "${AGENT_FX_DEBUG:-}" ]]; then
    create_args+=(-e "AGENT_FX_DEBUG=$AGENT_FX_DEBUG")
  fi

  if ! smolvm "${create_args[@]}"; then
    warn "could not create the smolvm machine. The agent-fx check did not run."
    return 0
  fi
  if ! smolvm machine start --name "$machine_name"; then
    warn "could not start the smolvm machine. The agent-fx check did not run."
    return 0
  fi

  # machine exec resolves its own secret refs. Attach the same refs again.
  local exec_args=(
    machine exec --name "$machine_name"
    --secret-env AGENT_FX_API_KEY=AGENT_FX_API_KEY
  )
  if [[ -n "${AGENT_FX_ORG_ID:-}" ]]; then
    exec_args+=(--secret-env AGENT_FX_ORG_ID=AGENT_FX_ORG_ID)
  fi

  local rc=0
  run_with_timeout "${SMOLVM_TIMEOUT:-10m}" smolvm "${exec_args[@]}" -- bash -lc \
    'cd /workspace && SMOLVM_ENABLED=0 SMOLVM_GUEST=1 bash scripts/check-agent-fx.sh' || rc=$?

  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
