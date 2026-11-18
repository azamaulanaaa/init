#!/usr/bin/env bash
# Format the Node and Vite code when node and npm are available.
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is not on PATH. Install git first." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

if ! command -v node >/dev/null 2>&1; then
  echo "skip: node is not on PATH. The format command did not run." >&2
  exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "skip: npm is not on PATH. The format command did not run." >&2
  exit 0
fi

if [[ ! -f package.json ]]; then
  echo "skip: package.json is not at the repository root. The format command did not run." >&2
  exit 0
fi

npm run format
echo "formatted the Node and Vite code"
