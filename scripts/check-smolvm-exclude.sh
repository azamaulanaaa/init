#!/usr/bin/env bash
# Check the .smolvmignore upload filter.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/smolvm-serve.sh
source "$here/smolvm-serve.sh"

# The pre-commit hook exports GIT_DIR. Clear every git override so each
# temporary repository is independent.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

work="$(mktemp -d "${TMPDIR:-/tmp}/smolvm-check-exclude.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

present() {
  [[ -e "$1" || -L "$1" ]] || fail "missing: $1"
}

absent() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "present: $1"
}

new_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email check@example.com
  git -C "$1" config user.name check
}

stage() {
  mkdir -p "$2"
  serve_upload_stage "$1" "$2" .git .cache
}

# 1. A real repository filters tracked files.
root="$work/repo"
new_repo "$root"
mkdir -p "$root/build" "$root/sub" "$root/nested"
printf 'build/\n*.log\n!keep.log\n' >"$root/.smolvmignore"
printf 'secret.txt\n' >"$root/nested/.smolvmignore"
printf '.env\n' >"$root/.gitignore"
: >"$root/build/out.o"
: >"$root/sub/a.log"
: >"$root/keep.log"
: >"$root/nested/secret.txt"
: >"$root/nested/open.txt"
: >"$root/.env"
git -C "$root" add -A
git -C "$root" add -f .env
git -C "$root" ls-files --error-unmatch .env >/dev/null 2>&1 ||
  fail "the tracked .env file is not in the index"
git -C "$root" commit -qm init
stage "$root" "$work/s1"
absent "$work/s1/build/out.o"
absent "$work/s1/sub/a.log"
present "$work/s1/keep.log"
absent "$work/s1/nested/secret.txt"
present "$work/s1/nested/open.txt"
present "$work/s1/.env"
absent "$work/s1/.git"

# 2. A plain directory uses the same filter. The .gitignore file is not
# read.
root="$work/plain"
mkdir -p "$root"
printf '*.log\n' >"$root/.smolvmignore"
printf 'git-only.txt\n' >"$root/.gitignore"
: >"$root/drop.log"
: >"$root/keep.txt"
: >"$root/git-only.txt"
stage "$root" "$work/s2"
absent "$work/s2/drop.log"
present "$work/s2/keep.txt"
present "$work/s2/git-only.txt"
absent "$work/s2/.git"

# 3. A plain directory without .smolvmignore keeps every file.
root="$work/all"
mkdir -p "$root/sub"
: >"$root/a.txt"
: >"$root/sub/b.txt"
stage "$root" "$work/s3"
present "$work/s3/a.txt"
present "$work/s3/sub/b.txt"

# 4. A nested repository stays as one directory entry. Its .git
# directory does not.
root="$work/nested-root"
mkdir -p "$root"
new_repo "$root/nested"
: >"$root/nested/inner.txt"
git -C "$root/nested" add -A
git -C "$root/nested" commit -qm init
stage "$root" "$work/s4"
present "$work/s4/nested/inner.txt"
absent "$work/s4/nested/.git"

# 5. A tracked file deleted from the work tree does not stop the stage.
root="$work/gone"
new_repo "$root"
: >"$root/gone.txt"
: >"$root/stays.txt"
git -C "$root" add -A
git -C "$root" commit -qm init
rm -f "$root/gone.txt"
stage "$root" "$work/s5"
absent "$work/s5/gone.txt"
present "$work/s5/stays.txt"

# 6. Inherited git variables do not change the temporary list directory.
root="$work/hermetic"
sentinel="$work/sentinel"
mkdir -p "$root" "$sentinel"
: >"$root/one.txt"
(
  export GIT_DIR="$work/missing/.git"
  export GIT_OBJECT_DIRECTORY="$sentinel"
  serve_upload_stage "$root" "$work/s6" .git .cache
)
present "$work/s6/one.txt"
shopt -s nullglob dotglob
entries=("$sentinel"/*)
shopt -u nullglob dotglob
((${#entries[@]} == 0)) || fail "the sentinel directory is not empty"

echo "upload filter: ok"
