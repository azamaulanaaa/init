#!/usr/bin/env bash
# Run go vet on the Go code when go is available.
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is not on PATH. Install git first." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

if ! command -v go >/dev/null 2>&1; then
  echo "skip: go is not on PATH. The Go vet check did not run." >&2
  exit 0
fi

if [[ ! -f go.mod ]]; then
  echo "skip: go.mod is not at the repository root. The Go vet check did not run." >&2
  exit 0
fi

go vet ./...
echo "checked Go code with vet"
