#!/usr/bin/env bash
# Provision the check tools inside a smolvm guest.
# Run this script from /workspace, the repository root in the guest.
# The local pack build and the remote run both use this script.
set -euo pipefail

if [[ ! -d /workspace ]]; then
  echo "error: /workspace is missing." >&2
  exit 1
fi
cd /workspace

# Run one provisioning step in a guest login shell.
# Print the step label and keep the exit code when the step fails.
run_step() {
  local label="$1"
  local command="$2"
  local rc
  bash -lc "set -euo pipefail; $command" || {
    rc=$?
    echo "error: $label failed." >&2
    exit "$rc"
  }
}

run_step "package install" \
  'export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y --no-install-recommends bash ca-certificates curl git && rm -rf /var/lib/apt/lists/*'
run_step "mise install script" \
  'curl --fail --location --silent --show-error https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh'
run_step "mise tools install" 'cd /workspace && mise install'
run_step "mise cache clear" 'mise cache clear'
run_step "git safe directory" 'git config --global --add safe.directory /workspace'

# The profile file covers login shells. The links cover other shell shapes.
# shellcheck disable=SC2016
run_step "mise PATH setup" \
  'shim_dir="$HOME/.local/share/mise/shims"; mkdir -p /etc/profile.d; printf "export PATH=\"%s:\$PATH\"\n" "$shim_dir" > /etc/profile.d/mise.sh'
# shellcheck disable=SC2016
run_step "mise shim links" \
  'shim_dir="$HOME/.local/share/mise/shims"; for shim in "$shim_dir"/*; do [ -e "$shim" ] || continue; ln -sf "$shim" "/usr/local/bin/$(basename "$shim")"; done'

echo "init complete"
