# agentwrap

High-security, low-overhead sandbox wrapper for running AI agents in a disposable overlay of real project directories. It creates per-project overlayfs mounts, isolates the environment with bubblewrap, and records each session.

## Features

- **OverlayFS-based "undo"**: agent changes land in an upper layer, not your source tree
- **Multi-project support**: wrap multiple projects simultaneously with isolated overlays
- **Persistent bash history**: per-project command history preserved across sessions
- **Bubblewrap isolation** with a minimal filesystem view
- **Optional SSH scoping** via a synthetic, per-host config
- **Session recording** to timestamped logs
- **Flexible sync operations**: apply changes (`--sync-out`), discard changes (`--sync-in`), or check diffs
- **Read-only mounts** for common system and user tooling
- **Maps conda and nvm** environments from outside to within the container

## Requirements

This script targets Linux.

**Required:**
- `bubblewrap` (`bwrap`)
- `fuse-overlayfs`
- `script` (from `util-linux`)

**Optional:**
- `rsync` (for `--sync-out`, `--check-diff`)
- `ssh` (for `--allow-ssh`)

## Install

No install step is required. Keep `agentwrap.sh` somewhere on your PATH or call it directly.

## Usage

```bash
agentwrap [OPTIONS] /path/to/project1 [/path/to/project2 ...] [-- command ...]
```

**Important:** Options must come before project paths.

If no command is provided, an interactive bash shell starts inside the sandbox. Use `--` to separate project paths from the command if the command itself might start with `/` or look like a path.

### Options

**Note:** All options must come before project paths.

#### Mount Options
- `--mount-home`: Mount your entire home directory read-only inside the sandbox
- `--mount-ro <path>`: Add an extra read-only mount (can be used multiple times)
- `--mount-to-ro <src> <dest>`: Add an extra read-only mount from `src` to `dest` (can be used multiple times)
- `--mount-rw <src[:dest]>`: Add an extra read-write mount; if `:dest` is omitted, mounts to the same path inside (can be used multiple times)
- `--mount-to-rw <src> <dest>`: Add an extra read-write mount from `src` to `dest` (can be used multiple times)
- `--no-mount <item>`: Skip a default mount by name or path (can be used multiple times), e.g. `.gemini` or `~/.claude`

#### SSH Options
- `--allow-ssh <host>`: Allow SSH only to the specified host (can be used multiple times for multiple hosts)

#### Sync & Diff Options
- `--sync-out`: Copy the merged sandbox view back into the real project(s) and exit (uses `rsync`)
- `--sync-in`: Discard all sandbox changes and reset to match the real project(s) (deletes overlay state)
- `--check-diff`: Show differences between the sandbox view and real project(s) (uses `rsync` dry-run)
- `--sync-exclude <path>`: Exclude a path pattern from sync operations (can be used multiple times)

#### Utility Options
- `--unlock`: Remove stale lock file(s) for the specified project(s) and exit
- `--help`: Show usage information

### Examples

#### Basic Usage

Start an interactive shell inside a project sandbox:
```bash
agentwrap ~/src/myproject
```

Run a single command:
```bash
agentwrap ~/src/myproject -- rg "TODO"
```

#### Multi-Project Support

Wrap multiple projects simultaneously (each gets its own overlay):
```bash
agentwrap ~/src/frontend ~/src/backend -- bash
```

All projects are accessible at their real paths inside the sandbox, with changes isolated to separate overlay layers.

#### SSH Access

Allow SSH to a host (scoped to its resolved config and key):
```bash
agentwrap --allow-ssh github.com ~/src/myproject
```

#### Extra Mounts

Add read-only and read-write mounts:
```bash
agentwrap --mount-ro /opt/tools --mount-rw /data:/mnt/data ~/src/myproject
```

Use explicit destination flags:
```bash
agentwrap --mount-to-ro /opt/tools /mnt/tools --mount-to-rw /data /mnt/data ~/src/myproject
```

Skip selected default mounts:
```bash
agentwrap --no-mount .gemini --no-mount ~/.claude ~/src/myproject
```

#### Managing Changes

Check what changed in the sandbox:
```bash
agentwrap --check-diff ~/src/myproject
```

Apply sandbox changes to the real project:
```bash
agentwrap --sync-out ~/src/myproject
```

Discard all sandbox changes (reset overlay):
```bash
agentwrap --sync-in ~/src/myproject
```

Apply changes but exclude certain paths:
```bash
agentwrap --sync-out --sync-exclude node_modules --sync-exclude .git ~/src/myproject
```

#### Multi-Project Sync

Works with multiple projects too:
```bash
# Check diffs for both projects
agentwrap --check-diff ~/src/frontend ~/src/backend

# Apply changes to both
agentwrap --sync-out ~/src/frontend ~/src/backend

# Discard changes in both
agentwrap --sync-in ~/src/frontend ~/src/backend
```

## How it works (high level)

- **Per-project sandboxes**: Each project gets its own sandbox under `~/.agent_sandboxes/<project>_<hash>` containing:
  - `upper/` - overlay layer where all modifications are stored
  - `work/` - fuse-overlayfs temporary directory
  - `merged/` - union view of the project (or symlink when not active)
  - `lock` - prevents concurrent wrapping of the same project
- **Session sandboxes**: When wrapping multiple projects, a session sandbox is created at `~/.agent_sandboxes/session_<hash>` containing:
  - Shared bash history (persists across sessions for this project combination)
  - Session logs
  - Entrypoint scripts
- **OverlayFS mounting**: Uses `fuse-overlayfs` to create a writable union view without touching the real files
- **Bubblewrap isolation**: Starts a container with controlled mounts, a minimal filesystem view, and network access
- **Session recording**: All terminal I/O is logged to `logs/session_<timestamp>.log`
- **Lock-based safety**: Per-project locks prevent accidentally wrapping the same folder alone and in combination

## Notes

### Environment
- The sandbox uses a "ghost home" (`--tmpfs $HOME`) and selectively re-binds specific paths
- DNS is copied from `/etc/resolv.conf` into the sandbox with at least one public resolver
- SSH access is opt-in; when enabled, only the selected host(s) and key(s) are visible

### Bash History
- Command history is persisted in the session sandbox and shared across sessions
- For single projects: history is project-specific
- For multi-project sessions: history is shared by that specific combination of projects

### Locking & Safety
- Each project has its own lock file at `~/.agent_sandboxes/<project>_<hash>/lock`
- **Double-mount protection**: A project cannot be wrapped if it's already wrapped (alone or in any combination)
- Example: If `/project/a` is wrapped alone, then `agentwrap /project/a /project/b` will fail
- Remove stale locks with `--unlock`

### Symlinks
- When no sandbox is active, the `merged` directory is a symlink to the real project
- This keeps external tools current when the sandbox isn't running

## Troubleshooting

- **`fuse-overlayfs: command not found`**: Install `fuse-overlayfs` and ensure it is on your PATH
- **`bwrap: command not found`**: Install `bubblewrap` and verify `bwrap` is available
- **`fusermount: failed to unmount`**: Check for lingering processes in the sandbox and rerun after they exit
- **DNS issues inside the sandbox**: Verify `/etc/resolv.conf` on the host and that outbound DNS is allowed
- **SSH failures with `--allow-ssh`**: Confirm the host is resolvable and your key is listed by `ssh -G <host>`
- **Project already wrapped**: Another sandbox is active for this project; close it first or use `--unlock` to clear stale locks
- **Want to discard changes**: Use `--sync-in` to delete the overlay and reset to the real project state
- **Options not recognized**: Ensure all options come before project paths in the command line

## Security model (short)

This tool is a pragmatic isolation wrapper for local agent execution. It is not a hardened container runtime. Review and adapt the mounts and environment for your threat model.

## License

MIT. See `LICENSE`.

This README was written by Codex from within the sandbox tool. :D
