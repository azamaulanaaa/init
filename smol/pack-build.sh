#!/usr/bin/env bash
# Build the cached smolvm pack for the checks.
# The pack holds the debian base image, mise, and the tools from
# mise.toml. The repository is mounted at run time. It is not baked in.
# Exit 0 without a pack when smolvm or the host accelerator is not available.
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is not on PATH. Install git first." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

print_warning() {
  cat >&2 <<'EOF'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! WARNING: smolvm or the host accelerator is not available.
!! The checks did NOT run in a microVM.
!! The pack was NOT built.
!! Install smolvm and give the host a working accelerator.
!! See docs/smolvm.md for the requirements.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
}

# Detect whether this host can run a smolvm machine.
# Linux needs a readable /dev/kvm.
# macOS on Apple Silicon uses the built-in hypervisor; kern.hv_support must be 1.
# The macOS pack build is UNVERIFIED for this repository.
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

if ! host_accel_ok; then
  print_warning
  echo "skip: smolvm pack was not built." >&2
  exit 0
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "error: sha256sum is not on PATH." >&2
  exit 1
fi

hash="${1:-}"
if [[ -z "$hash" ]]; then
  hash="$(sha256sum mise.toml smol/*.smolfile | sha256sum | cut -d' ' -f1)"
fi

pack_dir=".cache/smolvm"
pack="${pack_dir}/ci-${hash}.smolmachine"

if [[ -f "$pack" ]]; then
  echo "pack cache hit: $pack"
  exit 0
fi

mkdir -p "$pack_dir"

build_name="smolvm-build-${hash:0:16}"

# Delete with --force --cascade, as the smolvm makefile does. Without
# these flags, the delete can fail silently and leave the machine
# dangling on the host. Also remove any partial artifacts that a
# failed pack create could have left: the stub and the sidecar.
cleanup_build() {
  smolvm machine stop --name "$build_name" >/dev/null 2>&1 || true
  smolvm machine delete --name "$build_name" --force --cascade >/dev/null 2>&1 || true
  rm -f "${pack_dir}/ci-${hash}" "${pack_dir}/ci-${hash}.smolmachine"
}
trap cleanup_build EXIT

# Print the guest disk usage. Used on the failure path of a
# provisioning step. The guest is partly provisioned at that point.
# A failure here must not mask the original exit code.
guest_df() {
  smolvm machine exec --name "$build_name" -- bash -lc \
    'df -h /; du -sh /root/.cache/mise /root/.local/share/mise 2>/dev/null || true' || true
}

# Remove a leftover build machine from an earlier failed run.
smolvm machine delete --name "$build_name" --force --cascade >/dev/null 2>&1 || true

# Create the build machine with the repository mounted at /workspace.
# The mount is read-only. The build only reads mise.toml.
smolvm machine create --name "$build_name" --smolfile smol/base.smolfile \
  -v "$PWD":/workspace:ro
smolvm machine start --name "$build_name"

# Run each provisioning step on its own. A failed step stops the build.
# A failed step prints the guest disk usage before the script exits.
smolvm machine exec --name "$build_name" -- bash -lc \
  'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends bash ca-certificates curl git && rm -rf /var/lib/apt/lists/*' ||
  {
    rc=$?
    guest_df
    exit "$rc"
  }
smolvm machine exec --name "$build_name" -- bash -lc \
  'curl --fail --location --silent --show-error https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh' ||
  {
    rc=$?
    guest_df
    exit "$rc"
  }
smolvm machine exec --name "$build_name" -- bash -lc \
  'cd /workspace && mise install' ||
  {
    rc=$?
    guest_df
    exit "$rc"
  }
# Delete the mise download cache. The cache is dead weight in the pack.
# The install is done at this point. Installed tools are not removed.
smolvm machine exec --name "$build_name" -- bash -lc \
  'mise cache clear' ||
  {
    rc=$?
    guest_df
    exit "$rc"
  }
smolvm machine exec --name "$build_name" -- bash -lc \
  'git config --global --add safe.directory /workspace' ||
  {
    rc=$?
    guest_df
    exit "$rc"
  }
# Add the mise shims to the login shell PATH and link the shims into
# /usr/local/bin. The login shell covers bash -lc. The links cover
# every other shell shape.
# The commands expand on the guest, not on this host.
# shellcheck disable=SC2016
smolvm machine exec --name "$build_name" -- bash -lc \
  'shim_dir="$HOME/.local/share/mise/shims"; mkdir -p /etc/profile.d; printf "export PATH=\"%s:\$PATH\"\n" "$shim_dir" > /etc/profile.d/mise.sh' ||
  {
    rc=$?
    guest_df
    exit "$rc"
  }
# shellcheck disable=SC2016
smolvm machine exec --name "$build_name" -- bash -lc \
  'shim_dir="$HOME/.local/share/mise/shims"; for shim in "$shim_dir"/*; do [ -e "$shim" ] || continue; ln -sf "$shim" "/usr/local/bin/$(basename "$shim")"; done' ||
  {
    rc=$?
    guest_df
    exit "$rc"
  }

# The archive captures the disk state. Stop the machine before packing.
smolvm machine stop --name "$build_name"

# smolvm v1.35.1: -o names the executable stub. The sidecar
# <output>.smolmachine is created automatically. --single-file does
# not bypass the output validation, so it is not passed. An -o value
# that ends in .smolmachine is rejected.
smolvm pack create --from-vm "$build_name" --cpus 1 --mem 512 \
  -o "${pack_dir}/ci-${hash}"

# Disarm the trap first. The pack is never discarded by the trap,
# regardless of what happens after this line.
trap - EXIT
smolvm machine delete --name "$build_name" --force --cascade

echo "pack built: $pack"
