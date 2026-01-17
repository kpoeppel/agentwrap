# agentwrap

High-security, low-overhead sandbox wrapper for running AI agents in a disposable overlay of a real project directory. It creates a per-project overlayfs, isolates the environment with bubblewrap, and records each session.

## Features

- OverlayFS-based "undo": agent changes land in an upper layer, not your source tree
- Bubblewrap isolation with a minimal filesystem view
- Optional SSH scoping via a synthetic, per-host config
- Session recording to timestamped logs
- Read-only mounts for common system and user tooling
- Maps conda and nvm environments from outside to within the container

## Requirements

This script targets Linux.

- `bubblewrap` (`bwrap`)
- `fuse-overlayfs`
- `script` (from `util-linux`)
- `ssh` (optional, for `--allow-ssh`)

## Install

No install step is required. Keep `agentwrap.sh` somewhere on your PATH or call it directly.

## Usage

```bash
./agentwrap.sh /path/to/project [command ...]
```

If no command is provided, an interactive bash shell starts inside the sandbox.

### Options

- `--allow-ssh <host>`: Allow SSH only to the specified host. Can be provided multiple times.
- `--mount-home`: Mount your entire home directory read-only inside the sandbox.
- `--mount-ro <path>`: Add an extra read-only mount. Can be provided multiple times.
- `--mount-rw <src[:dest]>`: Add an extra read-write mount. If `:dest` is omitted, mounts to the same path inside.
- `--sync-out`: Copy the merged sandbox view back into the real project and exit (uses `rsync`).
- `--check-diff`: Show whether the sandbox view and real project differ (uses `rsync` dry-run).
- `--sync-exclude <path>`: Exclude a path pattern from sync. Can be provided multiple times.
- `--unlock`: Remove a stale `.agentwrap.lock` file for the project and exit.
- `--help`: Show basic usage.

### Examples

Start an interactive shell inside a project sandbox:

```bash
./agentwrap.sh ~/src/myproject
```

Run a single command:

```bash
./agentwrap.sh ~/src/myproject rg "TODO"
```

Allow SSH to a host (scoped to its resolved config and key):

```bash
./agentwrap.sh --allow-ssh github.com ~/src/myproject
```

Add extra mounts:

```bash
./agentwrap.sh --mount-ro /opt/tools --mount-rw /data:/mnt/data ~/src/myproject
```

Sync changes from the sandbox back to the real project:

```bash
./agentwrap.sh --sync-out --sync-exclude node_modules ~/src/myproject
```

Check whether the sandbox view differs from the real project:

```bash
./agentwrap.sh --check-diff --sync-exclude node_modules ~/src/myproject
```

## How it works (high level)

- Creates a per-project sandbox under `~/.agent_sandboxes/<project>_<hash>`.
- Uses `fuse-overlayfs` to mount a merged view of the project.
- Starts a bubblewrap container with controlled mounts and environment.
- Records the session output to `~/.agent_sandboxes/.../logs/session_<timestamp>.log`.

## Notes

- The sandbox uses a "ghost home" (`--tmpfs $HOME`) and selectively re-binds a few paths.
- DNS is copied from `/etc/resolv.conf` into the sandbox and ensured to have at least one public resolver. 
  The original `/etc/resolv.conf` is assumed to be a symlink as very common on Linux!
- SSH access is opt-in; when enabled, only the selected host(s) and key(s) are visible.
- While a sandbox is active, `agentwrap` creates `.agentwrap.lock` in the project root.
  Remove it with `--unlock` if it becomes stale.
- When no sandbox is active, the sandbox `merged` path (`~/.agent_sandboxes/<project>_<hash>/merged`)
  is a symlink to the real project so external tools stay current.

## Troubleshooting

- `fuse-overlayfs: command not found`: install `fuse-overlayfs` and ensure it is on your PATH.
- `bwrap: command not found`: install `bubblewrap` and verify `bwrap` is available.
- `fusermount: failed to unmount`: check for lingering processes in the sandbox and rerun after they exit.
- DNS issues inside the sandbox: verify `/etc/resolv.conf` on the host and that outbound DNS is allowed.
- SSH failures with `--allow-ssh`: confirm the host is resolvable and your key is listed by `ssh -G <host>`.

## Security model (short)

This tool is a pragmatic isolation wrapper for local agent execution. It is not a hardened container runtime. Review and adapt the mounts and environment for your threat model.

## License

MIT. See `LICENSE`.

This README was written by Codex from within the sandbox tool. :D
