#!/usr/bin/env bash
# Check the Go code format when go is available.
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is not on PATH. Install git first." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

if ! command -v go >/dev/null 2>&1; then
  echo "skip: go is not on PATH. The gofmt check did not run." >&2
  exit 0
fi

if [[ ! -f go.mod ]]; then
  echo "skip: go.mod is not at the repository root. The gofmt check did not run." >&2
  exit 0
fi

unformatted=$(gofmt -l .)
if [[ -n "$unformatted" ]]; then
  echo "error: gofmt found Go files that need formatting." >&2
  echo "$unformatted" >&2
  exit 1
fi

echo "checked Go code format"
