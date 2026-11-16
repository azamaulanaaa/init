#!/usr/bin/env bash
# Remove the smolvm cache and dangling smolvm machines.
# Delete only machines made by this repository's tooling: the
# smolvm-build-* names from failed pack builds and the smolvm-run-*
# names from the older run path. Every other machine stays untouched.
# The cleanup is idempotent. Run it as often as you want.
set -euo pipefail

if command -v git >/dev/null 2>&1; then
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$root" ]]; then
    cd "$root"
  fi
fi

# Print one machine name per line.
# Try the JSON list with python3 first.
# Fall back to the quiet text list when python3 is absent or the
# JSON parse fails.
list_names() {
  if command -v python3 >/dev/null 2>&1; then
    if smolvm machine list --json 2>/dev/null | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(3)

if isinstance(data, dict):
    inner = None
    for key in ("machines", "items", "data"):
        if isinstance(data.get(key), list):
            inner = data[key]
            break
    if inner is None:
        sys.exit(3)
    data = inner

if not isinstance(data, list):
    sys.exit(3)

for item in data:
    if isinstance(item, str):
        print(item)
    elif isinstance(item, dict):
        name = item.get("name") or item.get("Name") or item.get("machine")
        if name:
            print(name)
'; then
      return 0
    fi
    echo "note: the JSON machine list failed. Use the text list." >&2
  fi
  smolvm machine ls -q 2>/dev/null
}

if ! command -v smolvm >/dev/null 2>&1; then
  echo "smolvm=not_found"
  echo "note: machine cleanup was skipped. smolvm is not on PATH."
else
  if names="$(list_names)"; then
    kept=0
    while IFS= read -r name; do
      case "$name" in
      smolvm-build-* | smolvm-run-*)
        if smolvm machine delete --name "$name" --force --cascade; then
          echo "deleted=$name"
        else
          echo "delete_failed=$name" >&2
        fi
        ;;
      "")
        ;;
      *)
        kept=$((kept + 1))
        ;;
      esac
    done <<<"$names"
    echo "kept=$kept"
  else
    echo "note: machine cleanup was skipped. The machine list failed." >&2
  fi
fi

cache=.cache/smolvm
if [[ -e "$cache" ]]; then
  rm -rf -- "$cache"
  echo "cache_removed=$cache"
else
  echo "cache_absent=$cache"
fi

exit 0
