# The smolvm sandbox

The checks can run inside a [smolvm](https://smolmachines.com/)
microVM instead of on the host. The microVM runs the same
`scripts/ci.sh` entry point against the live working tree. The
repository is mounted at `/workspace` in the guest. The mount is
read-only. The guest kernel enforces the read-only mount. The
repository is not copied and it is not cloned.

Set `SMOLVM_SERVE_ADDR` to send the checks to a `smolvm serve` endpoint on
another host. The guest command is the same. See
[Remote mode](#remote-mode).

This sandbox is modeled on the
[Throwaway machine](https://smolmachines.com/docs/guides/skills/throwaway-machine)
guide (smolvm v1.34.0, 2026-11-09). Modeled on throwaway-machine.
The checks are trusted static tools, not untrusted code. The guide
wraps untrusted workloads, so it records VM pids and force-kills
them. This sandbox runs trusted, read-only, bounded checks, so it
does not. See [Cancellation and the timeout](#cancellation-and-the-timeout-backstop).

`make ci` runs the checks inside smolvm by default on a host that
can run a machine. The flow was verified on 2026-11-16 on Linux
x86_64 with KVM and smolvm 1.35.1. Read the
[Verification status](#verification-status) section for the
boundary of that verification.

## The model

The sandbox follows the guide's isolation pattern with one change:
the workload here is trusted code.

- Offline by default. The VM runs a baked `.smolmachine` pack from
  the local cache. The pack run asks the registry for nothing.
  Network access happens during the pack build only.
- The repository is mounted with the `:ro` flag. The guest kernel
  refuses writes to it. The checks never write the repository.
- `make smolvm-preflight` reports whether this host can run the
  sandbox. It reads the host and starts no VM.
- `make smolvm-verify` probes the isolation from inside the guest
  and from the host. A run that exits zero proves nothing. The
  verify step checks the claims.
- `SMOLVM_ENABLED=0` marks a process that is already inside the
  microVM. It stops recursion. It also forces the host path on the
  host. `SMOLVM_GUEST=1` also marks a process inside the guest. See
  [SMOLVM_ENABLED](#smolvm_enabled).

## Verification status

Verified on 2026-11-16 on Linux x86_64 with KVM and smolvm 1.35.1:

- `make smolvm-pack` completes. The pack build works. The
  `ci-<key>` stub and the `ci-<key>.smolmachine` sidecar are
  produced.
- `make ci` inside the microVM passes all checks.
- `make smolvm-exec` runs a command inside the guest. The exit
  code propagates.
- `make smolvm-clean` works. It reaps dangling machines and
  removes `.cache/smolvm/`.
- The host is capable of running the microVM. The guest `apt-get`
  step is noninteractive.

Verified on 2026-11-17 with `smolvm serve` v1.33.0 at
`http://127.0.0.1:5000`:

- `GET /health` and `GET /api/v1/machines` returned 200.
- `POST /api/v1/machines` with this repository's create body returned 200.
- The create body rejects a `smolfile` field with HTTP 422.
- `DELETE /api/v1/machines/:name` returned 200.
- With `SMOLVM_SERVE_IMAGE=bash:latest`, `make smolvm-exec
  ARGS='echo hello-from-remote'` printed the guest output.
- With the same image, `make smolvm-exec ARGS='exit 7'` returned exit
  code 7. The machine list was empty after each run.
- `hello-world` and `bash:latest` pulled and started on this server.
- A create with `debian:stable-slim` returned 200. The machine was not
  started.

Still unverified:

- The full `make smolvm` check run over HTTP. `bash:latest` does not
  contain this repository's check tools. The init script needs egress
  for `apt-get` and mise.run. That install did not run on the test
  server. The init exec and its exit-code check are covered only by
  the fake-curl test.
- Remote cleanup on the live server. The fake-curl test covers the
  `smolvm-remote-*` name filter and the delete calls.
- The fake-curl test covers the request order, the image field, the
  `network: true` field, the init exec, the exit-code handling, the
  cleanup, the token header, and the decoding of `stdout` and `stderr`.
  It does not cover the base64 output fields `stdoutB64` and `stderrB64`.
- `./smol/verify.sh` (`make smolvm-verify`). The inside and
  outside isolation assertions were not confirmed green on a KVM
  host. Nothing reports `result=isolation_held` yet. The
  network-leak question from a `net=true` build machine stays open
  until the verify passes.
- macOS on Apple Silicon. The implementation exists (the
  `kern.hv_support` detection) but never ran. Treat it as untested.

## Requirements

- Linux x86_64 or aarch64 with KVM at `/dev/kvm`, readable by the
  user. A cloud instance or a VM must expose nested virtualization.
- Or macOS 11 or later on Apple Silicon. smolvm uses the built-in
  hypervisor there. `kern.hv_support` must be `1`. The detection in
  `scripts/ci.sh` and `scripts/smolvm.sh` supports this path. The
  macOS path is untested. See
  [Verification status](#verification-status).
- `smolvm` on `PATH`. Install it with
  `curl -sSL https://smolmachines.com/install.sh | bash`. See the
  [smolvm local documentation](https://smolmachines.com/docs/local).
- `git`, `make`, `sha256sum`, and `bash` on the host.
- For remote mode, a reachable `smolvm serve` endpoint, `curl`, `tar`, and
  a base image prepared on the server. See [Remote mode](#remote-mode).
- Network access in the guest during the pack build. The build
  installs packages with `apt-get` and mise with the mise.run
  script. The checks themselves do not need the network.

## How it works

`make ci` calls `scripts/ci.sh`. After the `git` preflight and
before the checks run, `scripts/ci.sh` does the following:

1. If `SMOLVM_ENABLED=0`, it skips the detection and runs the
    checks natively. No warning is printed. The microVM sets
    `SMOLVM_ENABLED=0` in the guest command, so this case means the
    checks are already inside the microVM. Any other value, or an
    unset variable, takes the auto path in step 2.
2. Else if `SMOLVM_SERVE_ADDR` has a value, it `exec`s
    `scripts/smolvm.sh`. The script uses the remote REST path. No
    host fallback exists in that case.
3. Else if `smolvm` is on `PATH` and the host accelerator is
    available, it `exec`s `scripts/smolvm.sh`. The detection is
    `/dev/kvm` on Linux and `kern.hv_support=1` on macOS with Apple
    Silicon.
4. Else it prints a loud warning to stderr and runs the checks on
    the host as before.

`scripts/smolvm.sh` does the following:

1. If `SMOLVM_ENABLED=0`, it runs the checks on the host. The
    checks do not recurse.
2. If `SMOLVM_SERVE_ADDR` has a value, it calls the remote REST
    path. See [Remote mode](#remote-mode).
3. Else it detects `smolvm` and the host accelerator. If either is
    missing, it prints the loud warning and `exec`s the host checks
    with `SMOLVM_ENABLED=0`.
4. It computes the pack cache key. The key is the SHA-256 of the
    `sha256sum` lines of `mise.toml`, every `smol/*.smolfile`,
    `smol/pack-build.sh`, and `smol/init.sh`. The init script holds the
    provisioning steps. A change to it must build a new pack.
5. It builds the pack when `.cache/smolvm/ci-<key>.smolmachine` is
    missing. It calls `smol/pack-build.sh` for the build.
6. It runs `smolvm machine run --from <pack> --timeout 10m -v
    "$PWD":/workspace:ro -- bash -lc 'cd /workspace &&
    SMOLVM_ENABLED=0 SMOLVM_GUEST=1 bash scripts/ci.sh'`. The VM is
    discarded on exit. No persistent machine is created. The
    `--timeout` value comes from `SMOLVM_TIMEOUT` and defaults to
    `10m`.
7. The exit code of the checks propagates. The exit code of
    `machine run` in foreground mode is used as the exit code of
    `scripts/smolvm.sh`.

The loud warning looks like this:

```text
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! WARNING: smolvm or the host accelerator is not available.
!! The checks did NOT run in a microVM.
!! The checks run on the HOST instead.
!! Install smolvm and give the host a working accelerator.
!! See docs/smolvm.md for the requirements.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
```

The warning appears on the host every time `make ci` or `make smolvm`
runs without a usable smolvm setup, and `SMOLVM_ENABLED` is not `0`.
The warning appears on stderr. It is easy to
miss in a long log. Read it when a run feels faster than expected.
The warning does not appear when `SMOLVM_ENABLED=0` is set, because
that case is the intended host path.

## Remote mode

Set `SMOLVM_SERVE_ADDR` to run the checks on a remote host. The scripts
call a `smolvm serve` HTTP endpoint with `curl`. The local CLI is not used.
No new runtime is added. The repository is not baked into a machine image.

### Environment variables

- `SMOLVM_SERVE_ADDR` sets the server address. Use a full URL such as
  `http://127.0.0.1:8080` or `https://host:8443`. Use a bare `host:port`
  value to get an `http://` prefix. Use a socket path such as
  `/run/smolvm.sock` or a `unix://` value for a Unix socket.
- `SMOLVM_SERVE_TOKEN` is optional. When set, every API call carries an
  `Authorization: Bearer` header. The scripts never print the token value.
- `SMOLVM_SERVE_IMAGE` names the base image for the machine. The default
  value is `debian:stable-slim`. This is the image in
  `smol/base.smolfile`. Set another image when you publish one with the
  tools already installed.
- `SMOLVM_SERVE_TIMEOUT` sets the curl timeout in seconds. The default
  value is `120`. The local path still uses `SMOLVM_TIMEOUT`.

When `SMOLVM_SERVE_ADDR` is set, the scripts need a reachable server. They
require a successful remote run. They never run the checks or the user
command on the host. If a call fails, they print an error and exit non-zero.

The remote path prints two warnings on stderr. The first warning says
that the local pack cache is not used. The second warning says that the
init script installs the tools on every run. Remote mode has no pack and
no cache. `make smolvm-pack` refuses to run while `SMOLVM_SERVE_ADDR` has
a value. Unset the variable before you build a local pack.

### API flow

`scripts/smolvm-serve.sh` holds the shared REST calls. Both entry points
source it. One run follows these steps:

1. Check that `curl` and `tar` are on PATH.
2. Resolve the server address into a base URL and curl options.
3. Copy the live working tree to a staging directory. Exclude `.git`
    and `.cache`. Build a portable `.git` in the staging directory. The
    client resolves a worktree pointer to the real git dirs first. It
    copies the common git data and overlays the per-worktree files. It
    removes the pointer files and the worktree list. It checks the
    staged git data before any API call. It archives the staging
    directory. No data comes from the local pack cache.
4. Call `GET /health` to check that the server answers.
5. Call `POST /api/v1/machines` with `image` and `network: true` to
    create a machine.
6. Call `POST /api/v1/machines/<name>/start` to start it.
7. Call `POST /api/v1/machines/<name>/exec` to check the workload.
8. Call `PUT /api/v1/machines/<name>/files/...` to upload the archive.
9. Call `POST /api/v1/machines/<name>/exec` to extract the archive.
10. Call `POST /api/v1/machines/<name>/exec` to run `bash
    /workspace/smol/init.sh`. Init output appears on the console. A
    non-zero `exitCode` stops the run.
11. Call `POST /api/v1/machines/<name>/exec` to run the guest command.
12. Call `DELETE /api/v1/machines/<name>` to delete the machine.

Both modes use the same guest command. It is
`cd /workspace && SMOLVM_ENABLED=0 SMOLVM_GUEST=1 bash scripts/ci.sh`.
For `make smolvm-exec` the command runs with the same two variables.

An exec call returns HTTP 200 when the guest command fails. The helper
reads `exitCode` from the response body. The guest exit code becomes the
exit code of the script. The exit trap deletes the machine on every path.
The trap also removes the local archive.

### Serve API reference

This repository calls the smolvm serve API 0.5.2. The spec is an OpenAPI
3.1.0 document. This section records the endpoints that the scripts call.
It records the fields that the scripts send or read. A server may run a
different API version.

#### Endpoints that this repository calls

| Method | Path | Purpose | Fields the scripts use |
| --- | --- | --- | --- |
| GET | `/health` | Check the server. | No body. |
| POST | `/api/v1/machines` | Create a machine. | Req: `name`, `image`, `cpus` |
| | | | Req: `memoryMb`, `network`, `cmd` |
| POST | `/api/v1/machines/{name}/start` | Start a machine. | Path: `name` |
| POST | `/api/v1/machines/{id}/exec` | Run a command. | Req: `command` |
| | | | Resp: `exitCode`, `stdout`, `stderr` |
| | | | Resp: `stdoutB64`, `stderrB64` (byte-exact) |
| PUT | `/api/v1/machines/{id}/files/{path}` | Upload archive. | `id`, `path` |
| | | | Body: `application/octet-stream` |
| GET | `/api/v1/machines` | List machines. | Read `name` from each item. |
| DELETE | `/api/v1/machines/{name}` | Delete a machine. | Path: `name` |

In the table, `Req` names fields in the request body. `Resp` names fields
in the response body. A `name` or `id` in braces is a path parameter.

The scripts send `command` as an array of strings. The first item names
the program. The other items are its arguments. The scripts read
`exitCode` as an integer. A value other than 0 stops the run. The upload
sends the worktree archive as an octet-stream body.

#### Exec timeout

`ExecRequest.timeoutSecs` sets a server-side timeout in integer seconds.
A separate issue changes the scripts to set this field on every remote
exec call. The value comes from `SMOLVM_SERVE_TIMEOUT`. That variable sets
the curl client max-time and defaults to 120 seconds. The scripts subtract
5 seconds. They use a floor of 1. They fall back to 115 when the variable
is missing or invalid.

The server timeout must be shorter than the client timeout. The server
then returns a response with an `exitCode` before curl gives up. If both
timeouts are equal, curl can end the call before the server returns the
exit code.

#### Output fields

`stdout` and `stderr` are a lossy UTF-8 view. A non-UTF-8 byte becomes
U+FFFD. The fields `stdoutB64` and `stderrB64` carry the raw bytes as
base64. Those fields are byte-exact. A caller that needs binary-safe
output uses the base64 fields.

A separate issue changes the scripts to print the base64 fields. When the
base64 fields are absent, the scripts print the lossy fields. They also
print a warning on stderr.

#### Unknown fields

`CreateMachineRequest` and `ExecRequest` set `additionalProperties` to
`false`. An unknown field or a mis-cased field gets HTTP 400. The server
does not treat the field as a silent no-op. The create body has no
`smolfile` field. It uses `image`, or `from` for a `.smolmachine` artifact.

The 0.5.2 spec describes unknown fields as HTTP 400. On a live v1.33.0
server, a create body with `smolfile` returned HTTP 422. See
[Verification status](#verification-status). The observed result stays in
that section.

#### Other useful endpoints

The 0.5.2 spec also lists these endpoints. This repository does not call
them. The list below describes the spec only. It makes no promise about a
server implementation.

- `POST /api/v1/machines/{id}/exec/stream` streams stdout and stderr as
  Server-Sent Events.
- `GET /api/v1/machines/{id}/logs?source=workload` streams the workload's
  stdout and stderr.
- `GET /api/v1/machines/{id}/files/{path}` downloads a file as a raw byte
  stream, or lists a directory as `entries` with name, kind, and size.
- `GET /api/v1/machines/{name}/egress-events` lists the egress denials for
  a machine.
- `GET /api/v1/machines/{name}/mounts` lists the host directories mounted
  into a running machine.
- `POST /api/v1/machines/{name}/cache-disk/publish` publishes the cache
  disk of a stopped machine as a new base in the server cache.

### Provision the machine

`smol/init.sh` holds every provisioning step. The local pack build and
the remote run both use this one script. The script installs the
packages with apt-get. It installs mise from mise.run to
`/usr/local/bin/mise`. It runs `mise install` in `/workspace`. It clears
the mise cache and trusts `/workspace` in git. It adds the mise shims to
the login shell PATH and links them into `/usr/local/bin`. It prints an
`error:` line and exits non-zero when a step fails.

The local pack build runs `bash /workspace/smol/init.sh` in the build
machine. The remote run uploads the working tree and runs the same
command in a fresh machine. The upload carries a portable copy of the
git metadata. The checks need the git history for `git rev-parse` and
`git ls-files`. Without it, a check can fail or report a false pass.

A git worktree has a `.git` pointer file. That pointer names a directory
that does not exist in the guest. The client resolves the worktree
pointer on the host before upload. It copies the common git data, then
overlays the per-worktree files. It removes the pointer files and the
worktree list. A normal checkout needs one copy because its git dir is
its common dir. The client checks the staged git data before it calls
the API. The upload leaves out `.cache`, so no data comes from the
local pack cache. Remote mode uses no pack. It installs the tools on
every run. The create body sets `network: true` so apt-get and mise.run
can reach their endpoints.

The serve API has no pack-create endpoint. It also rejects a `smolfile`
field in the create body with HTTP 422. A create body therefore names an
image. `SMOLVM_SERVE_IMAGE` sets that image. The default is
`debian:stable-slim`, the image in `smol/base.smolfile`. Set another
image when you publish one with the tools already installed.

### Security boundary

`smolvm serve` has no authentication by default. Bind it to loopback or a
protected Unix socket. For a remote host, put it behind an authenticated TLS
proxy. The token is opt-in and the scripts do not print it. Anyone who can
call the API can create machines and run commands. Treat the API as a host
shell. Keep the server and its proxy on a trusted network.

## Offline by default

The pack is a baked artifact built ahead of time. A
`smolvm machine run --from <pack>` run asks the registry for nothing.
The host asks the registry only for `--oci-cache` runs. No step in the
check path passes `--oci-cache`, so the checks run with no network.

The pack build is the only step with a network. Nothing untrusted
runs during the build. The build machine mounts the repository at
`/workspace` with the `:ro` flag and only reads `mise.toml` from it.

This is materially stronger isolation than a run with egress rules. A
filter on egress depends on the workload's cooperation. No network is
a property of the machine.

## The pack

`make smolvm-pack` builds the pack. The build does the following:

1. Creates a machine from `smol/base.smolfile`. The repository is
    mounted at `/workspace` with the `:ro` flag.
2. Installs `bash`, `ca-certificates`, `curl`, and `git` with
    `apt-get`.
3. Installs mise to `/usr/local/bin/mise` with the mise.run script.
4. Runs `mise install` in `/workspace`. The tools land in the pack.
5. Runs `mise cache clear` to remove the download cache from the
    pack. The installed tools are not removed.
6. Adds `safe.directory /workspace` to the root git configuration.
7. Adds the mise shims to the login shell PATH through
    `/etc/profile.d/mise.sh`. It also links the shims into
    `/usr/local/bin` so non-login shells find the tools.
8. Stops the machine.
9. Runs `smolvm pack create --from-vm <name> --cpus 1 --mem 512
    -o .cache/smolvm/ci-<key>`. On smolvm v1.35.1 the `-o` value names
    the executable stub. The sidecar `ci-<key>.smolmachine` is created
    automatically as `<output>.smolmachine`. An `-o` value that ends in
    `.smolmachine` is rejected. `--single-file` does not change this.
    The stub is capped at 1 vCPU and 512 MiB of memory. The caps are
    not reservations.
10. Deletes the build machine.

If a failure happens before the pack create succeeds, the trap
removes the build machine. It stops the machine, deletes it with
`--force --cascade`, and removes possible partial artifacts: the
stub `ci-<key>` and the sidecar `ci-<key>.smolmachine`. The trap is
disarmed when `pack create` succeeds, so the trap never removes a
good pack. If the final machine delete fails after that, the build
machine may dangle, but the pack survives. Use the recovery steps
below in that case. If a provisioning step fails, the build also
prints the guest disk usage before it exits. The output names `/`,
`/root/.cache/mise`, and `/root/.local/share/mise`.

If a build machine ever dangles anyway, `make smolvm-clean` removes
it. The target deletes only the `smolvm-build-*` and `smolvm-run-*`
machines. It then removes `.cache/smolvm/`, which covers the possible
partial artifacts: the stub `ci-<key>` and the sidecar
`ci-<key>.smolmachine`. See [Clean the sandbox](#clean-the-sandbox).

The pack cache key covers `mise.toml`, `smol/pack-build.sh`,
`smol/init.sh`, and every `smol/*.smolfile`. The init script holds the
provisioning steps. Change one of these files and the next
`make smolvm-pack` builds a new pack. The old pack stays in
`.cache/smolvm/` until `make smolvm-clean` removes it. Remote mode does
not use this pack.

The pack does not contain the repository. `pack create --from-vm`
captures the machine disk, and the disk has an empty `/workspace`
from the mount. The checks run against the live working tree on
every run.

`smolvm pack create -o .cache/smolvm/ci-<key>` writes the executable
stub `ci-<key>` and the auto-created sidecar `ci-<key>.smolmachine`.
This repository uses the sidecar through `smolvm machine run --from`.
`scripts/smolvm.sh` checks for the sidecar and runs it.

## Guest disk sizing

The build guest writes to an overlay rootfs. The limits live in
`smol/base.smolfile`. The `overlay` limit caps the writable layer.
The `storage` limit caps the disk. The mise cache, the node runtime,
and the installed tools all live on the overlay.

A pack build can fail near the end of `mise install` with a line
like this:

```text
failed copy: ~/.cache/mise/invocation-downloads/.tmptTmkhE/artifact -> ~/.local/share/mise/downloads/hadolint/2.15.1/.hadolint-linux-x86_64.mise-part
```

The cause is the `overlay` limit. The install downloads node 24,
ten tools, and two npm trees. The cache and the tools together
exceed a 1 GiB overlay. The fix raises `storage` to 2 GiB and
`overlay` to 4 GiB. The pack build also runs `mise cache clear`
after the install. The clear removes the download cache from the
pack. The installed tools stay in the pack.

On 2026-11-16 `make smolvm-pack` completed on Linux x86_64 with
KVM. The pack build works with the 2 GiB `storage` and 4 GiB
`overlay` limits. To check the cache in a pack run:

```bash
smolvm machine run --from .cache/smolvm/ci-<key>.smolmachine \
  -- bash -lc 'du -sh /root/.cache/mise'
```

Expect the output to show an empty or near-empty directory.

The pack cache key includes `smol/init.sh` and every `smol/*.smolfile`.
The bump of `storage` and `overlay` changes that hash. The next
`make smolvm-pack` builds one fresh pack automatically. You do not
need to remove the old pack first.

## Check the isolation

A run that exits zero proves neither the read-only mount nor the
network block. `make smolvm-verify` checks both, in the same shape
as a real run: the cached pack, the repository read-only at
`/workspace`, no network.

The verify step does two halves.

From inside the guest:

1. `touch /workspace/ISOLATION_PROBE` must fail. A success means the
    read-only mount leaked.
2. A TCP connect to `example.com:80` with bash `/dev/tcp` must fail.
    No external probe tool is needed. If the guest bash has no
    `/dev/tcp` support, the step prints `net=no_probe_tool` and fails.
    It does not silently pass.

From the host afterwards:

1. The repository has no `ISOLATION_PROBE` file. If the probe leaked,
    the step deletes the file it created and reports a FAIL.

The step prints key=value lines:

```text
inside_workspace=ok (readonly)
inside_network=ok (blocked)
repo_unchanged=ok
result=isolation_held
```

The step exits 0 when the isolation held. It exits 1 on a FAIL or on
a `result=blocked`. A blocked result means the probe cannot run on
this host: no smolvm, no accelerator, or no pack. On such a host the
step prints its key=value lines and exits 1 instead of crashing.

Run the preflight first, then the verify step, then the microVM:

```bash
make smolvm-preflight
make smolvm-verify
make smolvm
```

As of 2026-11-16 the verify step did not print
`result=isolation_held` on a KVM host. See
[Verification status](#verification-status).

## What a REACHED result means

If the verify step prints `inside_network=FAIL expected=blocked
actual=REACHED` on a host with KVM, the guest reached the network.
That is a failure to report, not a reason to remove the check.

The pack may carry `net=true` from the build machine's Smolfile. A
CLI change can have the same effect. No fix is included here because
no fix was verified. The right response to a REACHED result is:

1. Open an issue on this repository with the full output.
2. Name the smolvm version and the host platform.
3. Propose the fix only with a boot test that shows the probe blocked.

The verify gate is the guardrail. It exists so this condition cannot
pass unnoticed.

## Preflight

`make smolvm-preflight` prints one key=value line per probe. The
last line is `result=ready` or `result=blocked`. The script is
read-only: it starts no VM and writes no smolvm state. The exit code
is 0 when ready, 1 when blocked, 2 on a usage error.

The probe lines:

- `smolvm_installed=yes|no` and `smolvm_version=<version>`.
- `verified_version=1.34.0` and `version_status=match|newer|older|unknown`.
  The guide was verified on v1.34.0. The scripts print
  `version_status` deliberately. Check each flag against your binary.
- `platform=linux-x86_64|linux-aarch64|darwin-aarch64` and
  `accel=kvm|hypervisor_framework`.
- `accel_access=ok|missing|denied`. On Linux the probe tests
  `/dev/kvm`. On macOS it tests `sysctl -n kern.hv_support`; the
  value must be `1`.
- `pack_run=available|unverified|unavailable`. On macOS the printed
  value is `unverified`. The macOS path is untested.
- `planned_mounts=1`, `planned_ports=0`, `devices_requested=1`.
- `device_budget=9` on x86_64 and `device_budget_ok=yes`. A guest
  boots with at most nine devices there, so one mount is always
  inside the budget. On aarch64 `device_budget_ok=not_limiting`.
- `cancel_route=ctrlc`. Ctrl-C on the smolvm CLI ends the VM on
  smolvm v1.20.2 and later.

On a host with no accelerator, the probe prints the failing line,
prints `result=blocked`, and exits 1. That is the correct behavior,
not a bug.

## Cancellation and the timeout backstop

Ctrl-C on the smolvm CLI ends the VM on smolvm v1.20.2 and later.
The sandbox keeps `machine run` in the foreground so that Ctrl-C
reaches the CLI and ends its VM.

`machine run` also gets `--timeout`, default `10m`. Override it with
`SMOLVM_TIMEOUT`. The timeout is a backstop for a hung run.
It is not the normal way to stop a run.

This differs from the guide on purpose. The guide backgrounds the
CLI, records the VM pid in a pid file, and ships a cleanup script
with a `--cancel` mode. That machinery exists for untrusted
workloads: the workload must be force-killed and must not be left
running. The guest here runs trusted, bounded, read-only checks. No
untrusted code runs. `machine run` stays in the foreground, Ctrl-C
ends the VM, and `--timeout` kills a hung run. This sandbox does not
record VM pids and does not ship a reaper. If you adapt this sandbox
to run untrusted code, use the guide's machinery instead.

The guide also collects artifacts from a writable `/out` mount. This
sandbox needs no artifact collection; the checks print their own
results. The guide grants egress with `--allow-host`. This sandbox
grants no egress and publishes no ports, so the device budget is not
a concern.

## Clean the sandbox

`make smolvm-clean` does two things, in this order:

1. It deletes the dangling sandbox machines. Only machines whose names
    match `smolvm-build-*` (a failed or interrupted pack build) or
    `smolvm-run-*` (the older run path) are deleted. The delete runs
    with `--force --cascade`. Machines with every other name stay
    untouched.
2. It removes the `.cache/smolvm/` directory. This removes the
    executable stub and the sidecar `.smolmachine` files.

When `SMOLVM_SERVE_ADDR` has a value, the target also cleans the server.
It calls `GET /api/v1/machines` and deletes each machine whose name
begins with `smolvm-remote-`. It prints one `deleted=<name>` line per
machine. It does not delete other names. A failed delete prints
`delete_failed=<name>` on stderr and does not stop the run. The client
does not need `jq`. The script parses the JSON with grep and sed. The
token stays out of the output.

When `smolvm` is not on `PATH`, the script prints `smolvm=not_found`
and a note that the machine cleanup was skipped. The cache removal
still runs. The exit code is 0. Listing machines reads state. It does
not boot a machine. It is safe on a host with no accelerator.

The script prints one `deleted=<name>` line per deleted machine. It
prints `kept=<N>` with the count of machines with other names. When a
delete fails, it prints `delete_failed=<name>` to stderr and continues
with the next machine. The exit code stays 0. When the cache is
missing, it prints `cache_absent=.cache/smolvm`. When it removed the
cache, it prints `cache_removed=.cache/smolvm`.

The cleanup is idempotent. Run it as often as you want. It never
deletes a machine that has another name. A shared host with other
machines is safe.

## Run a command in the sandbox

`make smolvm-exec` runs one arbitrary command inside the sandbox. The
sandbox shape is the same as the checks: the cached pack (built first
when it is missing, exactly as `scripts/smolvm.sh` builds it), the
repository mounted read-only at `/workspace`, no network, and a
`--timeout` backstop. The timeout defaults to `10m`. Override it with
`SMOLVM_TIMEOUT`. `SMOLVM_ENABLED=0` and `SMOLVM_GUEST=1` are set for the
command. A `bash scripts/ci.sh` inside it takes the native path.

With `SMOLVM_SERVE_ADDR` set, the command runs on a remote server. The
remote path prints `exec=<command>` first. It then prints the guest output.
The exit trap deletes the machine. See [Remote mode](#remote-mode).

Give the command as one string in `ARGS`:

```bash
make smolvm-exec ARGS='which mise && mise --version'
```

Or call the script directly:

```bash
scripts/smolvm-exec.sh 'df -h /'
```

The command runs with `bash -lc` with the repository as the working
directory. The command's stdout and stderr are forwarded as-is. The
command's exit code is the exit code of the script.
`make smolvm-exec ARGS='false'` exits non-zero.

There is no host fallback. If `smolvm` is missing or the host
accelerator is unavailable, the script prints the loud warning to
stderr, does not run the command, and exits 1. If `SMOLVM_SERVE_ADDR` is
set and the server fails, the script prints an error and exits non-zero.
The command is not run on the host under any circumstances. This is on
purpose. A command that must not touch the host never runs by accident.

More examples:

```bash
make smolvm-exec ARGS='df -h /'
make smolvm-exec ARGS='bash scripts/check-shfmt.sh'
make smolvm-exec ARGS='touch /workspace/ISOLATION_PROBE'
```

The last example fails. The mount is read-only.

## Targets

- `make ci` runs the checks. It uses a remote machine when
  `SMOLVM_SERVE_ADDR` has a value. It uses a local machine when smolvm and
  the accelerator are available. Otherwise it runs on the host with a
  loud warning.
- `make smolvm` runs the checks inside smolvm. It uses the remote path
  when `SMOLVM_SERVE_ADDR` has a value. Without a usable local setup and
  without a remote address it prints the loud warning and falls back to
  the host checks.
- `make smolvm-pack` builds the cached pack. It exits 0 without
  building when smolvm or the accelerator is missing. It exits non-zero
  when `SMOLVM_SERVE_ADDR` has a value. Unset the variable first.
- `make smolvm-clean` removes the dangling `smolvm-build-*` and
  `smolvm-run-*` machines. Then it removes `.cache/smolvm/`. With a
  remote address it also deletes `smolvm-remote-*` machines on the
  server. See [Clean the sandbox](#clean-the-sandbox).
- `make smolvm-exec` runs one command inside the sandbox. See
  [Run a command in the sandbox](#run-a-command-in-the-sandbox).
- `make smolvm-preflight` probes the host and prints key=value
  lines. Exits 0 when ready, 1 when blocked.
- `make smolvm-verify` verifies the isolation from inside the guest
  and from the host. Exits 0 when the isolation held, 1 otherwise.
- `make help` lists all targets.

## SMOLVM_ENABLED

`SMOLVM_ENABLED=0` forces the host path. `scripts/ci.sh` skips the
microVM detection and runs the checks natively. No warning is
printed. `scripts/smolvm.sh` does the same and runs the checks
natively. The checks never recurse into the microVM. This rule also
holds in remote mode. `SMOLVM_ENABLED=0` stops the remote call.

Run `SMOLVM_ENABLED=0 make ci` to force the host path on a host that
can run the microVM. Any other value, or an unset variable, keeps the
auto behavior: a remote address sends the checks to a server. Without
one, smolvm with a working accelerator runs the checks in the microVM.
Without them, the loud warning prints and the checks run on the host.

The microVM sets `SMOLVM_ENABLED=0` and `SMOLVM_GUEST=1` in the guest
command. `SMOLVM_GUEST=1` marks a process inside the guest. Set these
variables when you debug the guest command. Do not set them on the
host for a normal run.

## Why the pack is built in explicit steps

Provisioning does not use `[dev].init` in the Smolfile. `init` runs
once per machine and its caching rules are not deterministic across
smolvm versions. Each provisioning step runs as a separate
`smolvm machine exec` command. A failed step stops the build with
the exit code of the failing command. The build machine is stopped
and deleted afterwards, even on failure.

## Known limitations and assumptions

These points come from the smolvm documentation and from reading the
CLI reference.

1. The per-run path uses `smolvm machine run --from` with `-v`.
    `machine run` accepts `-v/--volume` and a `[COMMAND]...` argument.
    It is the documented one-shot equivalent of `machine create --from`
    plus `machine start`. Foreground exit-code propagation is the
    documented normal mode. The pack has no
    baked repository. The mount is supplied at run time.
2. `machine create` with a positional `[COMMAND]` sets a persistent
    detached workload. Without a command, the image's ENTRYPOINT/CMD
    runs detached on every start. For packs, the artifact supplies the
    command. `machine run --from` takes the command as an argument, so
    no detached workload is involved.
3. On 2026-11-16 the exit code of `smolvm machine run` in foreground
    mode propagated the guest command exit code on Linux x86_64 with
    KVM. If it does not
    on your version, `make smolvm` needs a check of the guest output
    instead.
4. The `[artifact]` table in `smol/base.smolfile` is documented for
    packs created from a Smolfile. The documentation does not state
    whether it is read for `pack create --from-vm`. The build passes
    `--cpus 1 --mem 512` as flags as well. Both mechanisms cap CPU and
    memory at the same values on purpose. Caps are not reservations.
    Whether the `[artifact]` table is honored for `--from-vm` packs is
    not confirmed.
5. The mise shims are added to `/etc/profile.d/mise.sh` for login
    shells and linked into `/usr/local/bin` for other shells. The
    checks pass inside the guest, so the tools resolve on `bash -lc`,
    which sources `/etc/profile`.
6. `/dev/kvm` exists and is readable is used as the Linux KVM check.
    This does not prove that the kernel allows a VM to start. A host
    in a restricted container can read `/dev/kvm` and still fail to run
    a VM. The loud warning does not cover this case. The preflight
    probe has the same limit.
7. On macOS the detection was extended to `kern.hv_support=1`. The
    macOS path is untested. The v1.24.0 to v1.29.0 `--oci-cache`
    regression (#1819) does not apply to pack `--from` runs.
8. The pack build needs inbound network access to the Debian and
    mise release endpoints. The check runs need no network. The guest
    `apt-get` step is noninteractive.
9. The pack may carry `net=true` from the build machine's Smolfile.
    If `make smolvm-verify` prints `inside_network=...actual=REACHED`,
    open an issue. See
    [What a REACHED result means](#what-a-reached-result-means).
10. The `--timeout` backstop kills the guest command after the
    duration. What `machine run` does on a timeout kill is not
    measured.
11. `smolvm machine start` is not documented to block until the
    workload is ready. The build does not rely on `start` returning
    for correctness, but a slow guest can fail the first
    `machine exec` if the agent is not up yet. Retry the build if it
    fails at the first step.

## Git hooks and GitHub Actions

The `pre-commit` and `pre-push` hooks call `scripts/ci.sh` with no
changes. On a host with smolvm and a working accelerator the hooks
now run the checks inside the microVM. This makes each commit build
the pack once on the first run. Later commits reuse
`.cache/smolvm/ci-<key>.smolmachine`.

The GitHub Actions workflow is not changed by this work.
