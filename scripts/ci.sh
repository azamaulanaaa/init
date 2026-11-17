#!/usr/bin/env bash
# Run every check script in name order.
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is not on PATH. Install git first." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

# Run the checks inside the smolvm microVM when it is available.
# SMOLVM_ENABLED=0 is set inside the microVM, so this does not recurse.
# Detect whether this host can run a smolvm machine.
# Linux needs a readable /dev/kvm.
# macOS on Apple Silicon uses the built-in hypervisor; kern.hv_support must be 1.
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

if [[ "${SMOLVM_ENABLED:-}" != "0" ]]; then
  if [[ -n "${SMOLVM_SERVE_ADDR:-}" ]]; then
    exec scripts/smolvm.sh
  fi
  if host_accel_ok; then
    exec scripts/smolvm.sh
  fi
  cat >&2 <<'EOF'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! WARNING: smolvm or the host accelerator is not available.
!! The checks did NOT run in a microVM.
!! The checks run on the HOST instead.
!! Install smolvm and give the host a working accelerator.
!! See docs/smolvm.md for the requirements.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
fi

shopt -s nullglob
checks=(scripts/check-*.sh)
shopt -u nullglob

if ((${#checks[@]} == 0)); then
  echo "error: no check scripts found in scripts/." >&2
  exit 1
fi

for check in "${checks[@]}"; do
  echo "run: $check"
  "$check"
done

echo "all checks passed (${#checks[@]} scripts)"
