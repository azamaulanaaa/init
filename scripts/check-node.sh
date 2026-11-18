#!/usr/bin/env bash
# Check the Node and Vite starter when node and npm are available.
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is not on PATH. Install git first." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

if ! command -v node >/dev/null 2>&1; then
  echo "skip: node is not on PATH. The Node check did not run." >&2
  exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "skip: npm is not on PATH. The Node check did not run." >&2
  exit 0
fi

if [[ ! -f package.json ]]; then
  echo "skip: package.json is not at the repository root. The Node check did not run." >&2
  exit 0
fi

npm ci
npm run test
npm run format:check
npm run build
npm run audit
echo "checked the Node and Vite starter"
