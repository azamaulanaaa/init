#!/usr/bin/env bash
# Shared REST helper for the remote smolvm serve path.
# Source this file from scripts/smolvm.sh or scripts/smolvm-exec.sh.
# Do not run this file as a command. The helper uses curl only.
# The helper never prints the value of SMOLVM_SERVE_TOKEN.
# CPU and memory come from SMOLVM_CPUS and SMOLVM_MEMORY_MB.

# Globals set by serve_init and serve_run_remote.
SERVE_CURL_CONNECT=()
SERVE_BASE=""
SERVE_MACHINE_NAME=""
SERVE_TARBALL=""
SERVE_STAGE=""
SERVE_GUEST_RC=0
SERVE_EXEC_TIMEOUT_SECS=0

# shellcheck source=scripts/smolvm-resources.sh
source "$(dirname "${BASH_SOURCE[0]}")/smolvm-resources.sh"

# Escape a string for use as a JSON string value.
# Handle the common control characters and the JSON quote characters.
json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

# Report whether the remote path is active.
serve_remote_enabled() {
  [[ -n "${SMOLVM_SERVE_ADDR:-}" ]]
}

# Resolve SMOLVM_SERVE_ADDR into curl connection options and a base URL.
# Accept a URL with a scheme, a bare host:port value, or a socket path.
serve_init() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "error: curl is not on PATH. Install curl first." >&2
    return 1
  fi

  if ! command -v tar >/dev/null 2>&1; then
    echo "error: tar is not on PATH. Install tar first." >&2
    return 1
  fi

  local address="${SMOLVM_SERVE_ADDR:-}"
  case "$address" in
  unix://*)
    SERVE_CURL_CONNECT=(--unix-socket "${address#unix://}")
    SERVE_BASE="http://localhost"
    ;;
  /*)
    SERVE_CURL_CONNECT=(--unix-socket "$address")
    SERVE_BASE="http://localhost"
    ;;
  http://* | https://*)
    SERVE_CURL_CONNECT=()
    SERVE_BASE="${address%/}"
    ;;
  *:*)
    SERVE_CURL_CONNECT=()
    SERVE_BASE="http://${address%/}"
    ;;
  *)
    echo "error: SMOLVM_SERVE_ADDR has an unsupported value." >&2
    echo "error: Use a URL, a host:port value, or a socket path." >&2
    return 1
    ;;
  esac

  # Compute the server exec timeout from the curl client timeout.
  # Use the default client timeout when the value is not a positive number.
  # Keep the server timeout smaller than the client timeout.
  local client_timeout="${SMOLVM_SERVE_TIMEOUT:-120}"
  if [[ ! "$client_timeout" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    [[ "$client_timeout" != *[1-9]* ]]; then
    client_timeout=120
  fi
  local whole_secs="${client_timeout%%.*}"
  SERVE_EXEC_TIMEOUT_SECS=$((whole_secs - 5))
  if ((SERVE_EXEC_TIMEOUT_SECS < 1)); then
    SERVE_EXEC_TIMEOUT_SECS=1
  fi
  return 0
}

# Send one request to the smolvm serve API.
# Print the response body on stdout. Print curl errors on stderr.
# Fail on an HTTP error status. Add the token header when a token is set.
serve_request() {
  local method="$1"
  local path="$2"
  shift 2

  local -a options=(
    --fail
    --silent
    --show-error
    --connect-timeout 5
    --max-time "${SMOLVM_SERVE_TIMEOUT:-120}"
    -X "$method"
  )
  if [[ -n "${SMOLVM_SERVE_TOKEN:-}" ]]; then
    options+=(-H "Authorization: Bearer ${SMOLVM_SERVE_TOKEN}")
  fi

  local url="${SERVE_BASE}${path}"
  curl "${SERVE_CURL_CONNECT[@]}" "${options[@]}" "$@" "$url"
}

# Clean up the machine, the archive, and the staging directory on exit.
# Keep the exit code that the caller produced.
serve_on_exit() {
  local rc=$?
  trap - EXIT
  if [[ -n "$SERVE_MACHINE_NAME" ]]; then
    serve_request DELETE "/api/v1/machines/${SERVE_MACHINE_NAME}" >/dev/null 2>&1 || true
    SERVE_MACHINE_NAME=""
  fi
  if [[ -n "$SERVE_TARBALL" ]]; then
    rm -f "$SERVE_TARBALL"
    SERVE_TARBALL=""
  fi
  if [[ -n "$SERVE_STAGE" ]]; then
    rm -rf -- "$SERVE_STAGE"
    SERVE_STAGE=""
  fi
  exit "$rc"
}

# Install the exit trap in the caller for the machine named by the argument.
serve_install_cleanup() {
  SERVE_MACHINE_NAME="$1"
  trap serve_on_exit EXIT
}

# Read the exitCode field from an exec response body.
# Print nothing when the field is absent.
serve_exec_rc() {
  local body="$1"
  printf '%s' "$body" |
    sed -n 's/.*"exitCode"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' |
    head -n 1
}

# Decode a base64 string into the file named by the second argument.
# Try GNU base64, then BSD base64, then OpenSSL.
# Return non-zero when no decoder works.
serve_decode_b64() {
  local encoded="$1"
  local output="$2"

  if command -v base64 >/dev/null 2>&1; then
    if printf '%s' "$encoded" | base64 -d >"$output" 2>/dev/null; then
      return 0
    fi
    if printf '%s' "$encoded" | base64 -D >"$output" 2>/dev/null; then
      return 0
    fi
  fi
  if command -v openssl >/dev/null 2>&1; then
    if printf '%s' "$encoded" | openssl base64 -d -A >"$output" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Print the byte-exact stream from an exec response.
# Map stdout to stdoutB64. Map stderr to stderrB64.
# Use the lossy parser when the response has no B64 field.
serve_print_stream() {
  local body="$1"
  local key="$2"
  local b64_key="${key}B64"
  local marker="\"${b64_key}\""
  local text
  text="${body#*"$marker"}"
  if [[ "$text" == "$body" ]]; then
    echo "warning: the exec response has no ${b64_key} field." >&2
    serve_print_stream_lossy "$body" "$key"
    return $?
  fi
  text="${text#*:}"
  text="${text#"${text%%[![:space:]]*}"}"
  if [[ "$text" != \"* ]]; then
    echo "warning: the exec response has no ${b64_key} value." >&2
    serve_print_stream_lossy "$body" "$key"
    return $?
  fi
  text="${text#\"}"

  local encoded="${text%%\"*}"
  local tmp
  if ! tmp="$(mktemp "${TMPDIR:-/tmp}/smolvm-stream.XXXXXX")"; then
    echo "error: mktemp failed. Check the temp directory." >&2
    return 1
  fi
  if ! serve_decode_b64 "$encoded" "$tmp"; then
    rm -f "$tmp"
    echo "error: no base64 decoder is on PATH." >&2
    echo "error: install base64 or openssl." >&2
    return 1
  fi

  if [[ -s "$tmp" ]]; then
    cat "$tmp"
    # Keep the newline framing from the lossy parser.
    local tail_byte
    tail_byte="$(
      tail -c 1 "$tmp"
      printf 'X'
    )"
    if [[ "$tail_byte" != $'\nX' ]]; then
      printf '\n'
    fi
  fi
  rm -f "$tmp"
  return 0
}

# Print one string field from an exec response body.
# Decode the common JSON escapes before printing the value.
# Use this parser only for responses that have no B64 field.
serve_print_stream_lossy() {
  local body="$1"
  local key="$2"
  local marker="\"${key}\""
  local text
  text="${body#*"$marker"}"
  if [[ "$text" == "$body" ]]; then
    return 0
  fi
  text="${text#*:}"
  text="${text#"${text%%[![:space:]]*}"}"
  if [[ "$text" != \"* ]]; then
    return 0
  fi
  text="${text#\"}"

  local decoded=""
  local char
  local next
  local index=0
  local length=${#text}
  while ((index < length)); do
    char="${text:index:1}"
    if [[ "$char" == '"' ]]; then
      break
    fi
    if [[ "$char" == "\\" ]] && ((index + 1 < length)); then
      next="${text:index+1:1}"
      case "$next" in
      n) decoded+=$'\n' ;;
      r) decoded+=$'\r' ;;
      t) decoded+=$'\t' ;;
      '"') decoded+='"' ;;
      "\\") decoded+="\\" ;;
      *) decoded+="$char$next" ;;
      esac
      index=$((index + 2))
      continue
    fi
    decoded+="$char"
    index=$((index + 1))
  done

  if [[ -z "$decoded" ]]; then
    return 0
  fi
  if [[ "$decoded" == *$'\n' ]]; then
    printf '%s' "$decoded"
  else
    printf '%s\n' "$decoded"
  fi
}

# Run one command in a machine on the remote server.
# Upload the live working tree as an archive before the command runs.
# Set SERVE_GUEST_RC to the guest exit code on success.
# Return non-zero when an API call fails or a response has no exitCode.
serve_run_remote() {
  local guest_command="$1"
  local repo_root
  local image="${SMOLVM_SERVE_IMAGE:-debian:stable-slim}"

  if ! smolvm_resources_resolve; then
    return 1
  fi
  if ! serve_init; then
    return 1
  fi

  echo "warning: remote mode does not use the local pack cache." >&2
  echo "warning: the init script installs the tools on every run." >&2

  repo_root="$(git rev-parse --show-toplevel)"

  local worker="smolvm-remote-$$-${RANDOM}"
  local tarball
  tarball="$(mktemp "${TMPDIR:-/tmp}/smolvm-worktree.XXXXXX.tar.gz")" || return 1

  serve_install_cleanup "$worker"
  SERVE_TARBALL="$tarball"

  local git_dir
  local common_dir
  if ! git_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null)" ||
    ! common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    echo "error: the git directories were not resolved." >&2
    return 1
  fi

  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/smolvm-stage.XXXXXX")" || return 1
  SERVE_STAGE="$stage"

  # Copy the working tree without the cache. Build a portable .git below.
  if ! tar -C "$repo_root" --exclude=.git --exclude=.cache -cf - . |
    tar -C "$stage" -xf -; then
    echo "error: the working tree was not staged." >&2
    return 1
  fi

  # A worktree has a .git pointer. Copy the common git data, then overlay
  # the per-worktree files. Remove the pointer files and the worktree list.
  # A normal checkout has git_dir equal to common_dir, so one copy suffices.
  mkdir -p "$stage/.git" || return 1
  if ! cp -a "$common_dir"/. "$stage/.git"/; then
    echo "error: the common git directory was not copied." >&2
    return 1
  fi
  if [[ "$git_dir" != "$common_dir" ]]; then
    if ! cp -a "$git_dir"/. "$stage/.git"/; then
      echo "error: the worktree git directory was not copied." >&2
      return 1
    fi
  fi
  rm -f "$stage/.git/commondir" "$stage/.git/gitdir"
  rm -rf -- "$stage/.git/worktrees"

  # Check the staged git data before any API call.
  if ! git -C "$stage" rev-parse --show-toplevel >/dev/null 2>&1 ||
    ! git -C "$stage" tag --list >/dev/null 2>&1; then
    echo "error: the portable git metadata is not valid." >&2
    return 1
  fi

  if ! tar -C "$stage" -czf "$tarball" .; then
    echo "error: the working tree archive was not created." >&2
    return 1
  fi
  rm -rf -- "$stage"
  SERVE_STAGE=""

  if ! serve_request GET /health >/dev/null 2>&1; then
    echo "error: the remote smolvm server is unreachable." >&2
    return 1
  fi

  local create_body
  create_body="$(
    printf '{"name":"%s","image":"%s","cpus":%s,"memoryMb":%s,"network":true,"cmd":["sh","-c","while true; do sleep 3600; done"]}' \
      "$(json_escape "$worker")" "$(json_escape "$image")" \
      "$SMOLVM_CPUS_VALUE" "$SMOLVM_MEMORY_MB_VALUE"
  )"
  if ! serve_request POST /api/v1/machines \
    -H 'content-type: application/json' \
    -d "$create_body" >/dev/null 2>&1; then
    echo "error: the remote smolvm API call failed: create machine." >&2
    return 1
  fi

  if ! serve_request POST "/api/v1/machines/${worker}/start" \
    -H 'content-type: application/json' \
    -d '{}' >/dev/null 2>&1; then
    echo "error: the remote smolvm API call failed: start machine." >&2
    return 1
  fi

  local response
  if ! response="$(serve_request POST "/api/v1/machines/${worker}/exec" \
    -H 'content-type: application/json' \
    -d '{"command":["bash","-lc","echo SMOLVM_READY"],"timeoutSecs":'"$SERVE_EXEC_TIMEOUT_SECS"'}' 2>&1)"; then
    echo "error: the remote smolvm API call failed: readiness check." >&2
    return 1
  fi
  if [[ "$response" != *SMOLVM_READY* ]]; then
    echo "error: the workload in the remote machine did not become ready." >&2
    return 1
  fi

  if ! serve_request PUT "/api/v1/machines/${worker}/files/%2Froot%2Fsmolvm-worktree.tar.gz" \
    -H 'content-type: application/octet-stream' \
    --data-binary "@${tarball}" >/dev/null 2>&1; then
    echo "error: the remote smolvm API call failed: upload working tree." >&2
    return 1
  fi

  if ! response="$(serve_request POST "/api/v1/machines/${worker}/exec" \
    -H 'content-type: application/json' \
    -d '{"command":["bash","-lc","mkdir -p /workspace && tar -xzf /root/smolvm-worktree.tar.gz -C /workspace"],"timeoutSecs":'"$SERVE_EXEC_TIMEOUT_SECS"'}' 2>&1)"; then
    echo "error: the remote smolvm API call failed: extract working tree." >&2
    return 1
  fi
  local setup_rc
  setup_rc="$(serve_exec_rc "$response")"
  if [[ "$setup_rc" != "0" ]]; then
    echo "error: the working tree was not extracted in the remote machine." >&2
    return 1
  fi

  if ! response="$(serve_request POST "/api/v1/machines/${worker}/exec" \
    -H 'content-type: application/json' \
    -d '{"command":["bash","-lc","bash /workspace/smol/init.sh"],"timeoutSecs":'"$SERVE_EXEC_TIMEOUT_SECS"'}' 2>&1)"; then
    echo "error: the remote smolvm API call failed: provision machine." >&2
    return 1
  fi
  serve_print_stream "$response" stdout
  serve_print_stream "$response" stderr
  local init_rc
  init_rc="$(serve_exec_rc "$response")"
  if [[ "$init_rc" != "0" ]]; then
    echo "error: the remote machine was not provisioned." >&2
    return 1
  fi

  local escaped
  escaped="$(json_escape "$guest_command")"
  if ! response="$(serve_request POST "/api/v1/machines/${worker}/exec" \
    -H 'content-type: application/json' \
    -d "{\"command\":[\"bash\",\"-lc\",\"${escaped}\"],\"timeoutSecs\":${SERVE_EXEC_TIMEOUT_SECS}}" 2>&1)"; then
    echo "error: the remote smolvm API call failed: run command." >&2
    return 1
  fi

  serve_print_stream "$response" stdout
  serve_print_stream "$response" stderr

  local guest_rc
  guest_rc="$(serve_exec_rc "$response")"
  if [[ -z "$guest_rc" ]]; then
    echo "error: the remote exec response has no exitCode." >&2
    return 1
  fi

  serve_request DELETE "/api/v1/machines/${worker}" >/dev/null 2>&1 || true
  SERVE_MACHINE_NAME=""
  rm -f "$tarball"
  SERVE_TARBALL=""
  # The caller reads this value after the function returns.
  # shellcheck disable=SC2034
  SERVE_GUEST_RC="$guest_rc"
  return 0
}
