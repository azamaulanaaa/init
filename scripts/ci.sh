#!/usr/bin/env bash
# Run every check script in name order.
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is not on PATH. Install git first." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

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
