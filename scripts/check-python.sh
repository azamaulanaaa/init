#!/usr/bin/env bash
# Check the Python starter when uv is available.
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is not on PATH. Install git first." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

if ! command -v uv >/dev/null 2>&1; then
  echo "skip: uv is not on PATH. The Python check did not run." >&2
  exit 0
fi

if [[ ! -f pyproject.toml ]]; then
  echo "skip: pyproject.toml is not at the repository root. The Python check did not run." >&2
  exit 0
fi

uv run ruff check .
uv run ruff format --check .
uv run mypy src tests
uv run pytest
echo "checked the Python starter"
