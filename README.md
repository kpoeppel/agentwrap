# agentwrap

High-security, low-overhead sandbox wrapper for running AI agents in a disposable overlay of real project directories. It creates per-project overlayfs mounts, isolates the environment with bubblewrap, and records each session.
Supports the standard directories of claude code, codex, opencode and pi out of the box. Which of them get mounted lives in `~/.agent_sandboxes/config`, written on first run — no need to edit the script.

## Features

- **OverlayFS-based "undo"**: agent changes land in an upper layer, not your source tree
- **Multi-project support**: wrap multiple projects simultaneously with isolated overlays
- **Persistent bash history**: per-project command history preserved across sessions
- **Bubblewrap isolation** with a minimal filesystem view
- **Optional SSH scoping** via a synthetic, per-host config
- **Session recording** to timestamped logs
- **Flexible sync operations**: apply changes (`--sync-out`), discard changes (`--sync-in`), or check diffs
- **Read-only mounts** for common system and user tooling
- **Mount defaults in a config file** (`~/.agent_sandboxes/config`), generated on first run
- **Maps conda and nvm** environments from outside to within the container
- **Secure defaults**: isolated network namespace, no X11 or D-Bus, and on-disk keyrings masked unless explicitly allowed
- **Explicit opt-in grants** for network, X11, D-Bus and keyring access (`--allow-net`, `--allow-x11`, `--allow-dbus`, `--allow-keyring`)

## Requirements

This script targets Linux.

**Required:**
- `bubblewrap` (`bwrap`)
- `fuse-overlayfs`
- `script` (from `util-linux`)

**Optional:**
- `rsync` (for `--sync-out`, `--check-diff`)
- `ssh` (for `--allow-ssh`)
- `rootlesskit` + `slirp4netns` (for `--allow-net=isolated`)
- `Xvfb` (for `--allow-x11=virtual`)

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

#### Passthrough Options
- `--allow-gpu`: Pass NVIDIA GPU devices (and `/sys`, CUDA libraries) into the sandbox
- `--allow-apptainer`: Enable Apptainer (Singularity) container execution inside the sandbox
- `--allow-flatpak`: Pass through the per-user flatpak runtime dirs (`/run/user/$UID/{.flatpak,.flatpak-cache,.flatpak-helper,bus,doc}`), mount `/sys`, and set `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS`
- `--allow-net[=host|isolated]`: Allow networking. Without it the sandbox runs in an isolated network namespace with **no connectivity**. `host` shares the host network namespace (internet, LAN, host loopback services, host abstract sockets); `isolated` runs the sandbox under `rootlesskit` + `slirp4netns` for a private user-mode NAT that blocks the host loopback. `--allow-ssh` implies `--allow-net=host` unless another mode was given.
- `--allow-x11[=real|virtual]`: Allow X11. `real` (the default when no value is given) mounts the host display, which grants full screen, input and clipboard access to your session; `virtual` starts a private `Xvfb` (requires the `xvfb` package) and exposes only that display. X11 is a filesystem socket, so it works even without `--allow-net`.
- `--allow-dbus`: Expose the session D-Bus (`/run/user/$UID/bus`). Implies `--allow-keyring`, because the secret service is reachable over the bus regardless of the on-disk mask.
- `--allow-keyring`: Do not mask `~/.local/share/keyrings`. By default that directory is replaced with an empty tmpfs inside the sandbox.

#### Network, X11 and D-Bus access

agentwrap starts from a **private network namespace** (`--unshare-all`), so by default the agent cannot reach the internet, your LAN, host loopback services (databases, dev servers, sshd on `127.0.0.1`, ...) or host abstract unix sockets — which is what keeps X11 and the running secret-service daemon out of reach.

Access is then granted explicitly:

- `--allow-net[=host|isolated]`: `host` restores the **host** network namespace — the blunt instrument: it re-exposes everything above, including the host's abstract X11 socket even without `--allow-x11`. `isolated` instead builds a private network namespace with user-mode NAT via `rootlesskit` + `slirp4netns`, setting DNS to `10.0.2.3` and passing `--disable-host-loopback`, so host loopback services, host abstract sockets and X11-over-abstract stay out of reach (internet and LAN remain reachable). Requires `rootlesskit` and `slirp4netns`; `--allow-ssh <host>` implies `host` unless a mode is given.
- `--allow-x11` / `--allow-x11=virtual` add X11 without touching the network. `virtual` is the safer choice: the agent gets its own `Xvfb` display and cannot see or type into your real session.
- `--allow-dbus` adds the session bus (needed for portals and keyring/secret-service access).

Keyring files under `~/.local/share/keyrings` are readable through the default `~/.local` mount, so agentwrap masks them with an empty tmpfs unless `--allow-keyring` (or `--allow-dbus`) is given. The files are encrypted at rest, but the mount is the stronger control.

#### Environment Options
By default the sandbox **inherits the full host environment** (including any secrets exported in your shell); the sandbox only overrides a few variables like `PATH` and `HOME`. As a safety net, the session-related variables `DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR` and `SSH_AUTH_SOCK` are **unset** by default; the matching `--allow-x11`/`--allow-dbus`/`--allow-ssh` (and `--allow-flatpak`) flags set them again when requested.
- `--clearenv`: Start from an empty environment instead (passed through to bwrap; built-in variables like `PATH`/`HOME` are still set)
- `--setenv <var> <value>`: Set a variable inside the sandbox (bwrap syntax, can be used multiple times; applied last, so it overrides everything else). Tip: with `--clearenv`, add `--setenv TERM "$TERM"` for interactive TUIs.

#### Sync & Diff Options
- `--sync-out`: Copy the merged sandbox view back into the real project(s) and exit (uses `rsync`)
- `--sync-in`: Discard all sandbox changes and reset to match the real project(s) (deletes overlay state)
- `--check-diff`: Show differences between the sandbox view and real project(s) (uses `rsync` dry-run)
- `--sync-exclude <path>`: Exclude a path pattern from sync operations (can be used multiple times)

#### Utility Options
- `--unlock`: Remove stale lock file(s) for the specified project(s) and exit
- `--print-config`: Print the built-in mount config template to stdout and exit
- `--help`: Show usage information

### Configuration file (`~/.agent_sandboxes/config`)

The default mounts under `$HOME` live in this file, not in the script. It is created from a built-in template on the first run and sourced as bash, so `$HOME` and other variables expand and conditionals work:

```bash
# agentwrap config v1
SANDBOX_RO_MOUNTS=(          # toolchains and identity the agent may read
    "$HOME/.nvm"
    "$HOME/.miniconda3"
    "$HOME/.local"
    "$HOME/.gitconfig"
    "$HOME/.tmux.conf"
    "$HOME/.tmux"
    "$HOME/.ssh/known_hosts"
)
SANDBOX_RW_MOUNTS=(          # agent state that has to survive the sandbox
    "$HOME/.cache"
    "$HOME/.claude"
    "$HOME/.claude.json"
    "$HOME/.codex"
    "$HOME/.gemini"
    "$HOME/.pi"
    "$HOME/.local/share/opencode"
)
SANDBOX_NO_MOUNTS=()         # entries to drop from the lists above
SANDBOX_ENV=()               # extra VAR=VALUE vars exported inside the sandbox
```

- Entries are `SRC` or `SRC:DEST` like `--mount-ro`/`--mount-rw`.
- A missing source is **skipped with a warning** instead of aborting the sandbox, so listing an agent you haven't installed is harmless. Command-line `--mount-ro`/`--mount-rw` still fail hard, since those are explicit requests.
- System paths (`/usr`, `/bin`, `/lib`, `/lib64`, `/etc`) and session state (bash history, ssh jail, ssh control sockets) stay built into the script.
- Precedence is built-in → config → command line, and `bwrap` lets later binds win. `--no-mount` and `SANDBOX_NO_MOUNTS` apply to the first two tiers, never to explicit command-line mounts.
- `SANDBOX_ENV` is an array of `VAR=VALUE` strings exported into the sandbox, e.g. `SANDBOX_ENV=("EDITOR=vim" "PAGER=less")`. It is applied after the built-in and `--allow-*` settings but before `--setenv`, so command-line values win. Malformed entries (missing `=`, or an empty variable name) are reported and skipped.
- Run `agentwrap --print-config` to reprint the current template, e.g. to diff your file against it after an update.

**Changed in this version:** these arrays used to *extend* a hardcoded list inside the script; they now *define* the `$HOME` tier. A config file written before this change lacks the `# agentwrap config v1` marker on line 1, so agentwrap prints a one-time hint per run until you merge the template in (or just add the marker line if your file is already complete).

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

#### Network / X11 / D-Bus Access

Enable networking when the agent needs it (off by default):
```bash
agentwrap --allow-net ~/src/myproject
```

Or use a private NAT that keeps host loopback out of reach:
```bash
agentwrap --allow-net=isolated ~/src/myproject
```

Give the agent a private throwaway display instead of your real one:
```bash
agentwrap --allow-x11=virtual ~/src/myproject -- xdotool getdisplaygeometry
```

Let a desktop/coding agent use portals and the keyring:
```bash
agentwrap --allow-dbus ~/src/myproject
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

- **User configuration**: `~/.agent_sandboxes/` holds the two files you edit:
  - `sandbox_profile` - becomes `~/.bashrc` inside the sandbox
  - `config` - the default mounts under `$HOME` (see above), generated on first run
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
- **Bubblewrap isolation**: Starts a container with controlled mounts, a minimal filesystem view, an isolated network namespace, a scrubbed session environment, and masked secret stores unless explicit `--allow-*` flags say otherwise
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

agentwrap defaults to a small attack surface: an isolated network namespace (no internet, LAN, host loopback or host abstract sockets), no X11 or D-Bus, and keyring files masked. Each capability is re-enabled by a single explicit flag, so the trust decision is visible on the command line:

- `--allow-net` — full host networking (also re-exposes host abstract sockets)
- `--allow-net=isolated` — private user-mode NAT (rootlesskit + slirp4netns): internet/LAN, but no host loopback or host sockets
- `--allow-x11=real` — full access to your live desktop (screen, input, clipboard); prefer `--allow-x11=virtual`
- `--allow-dbus` — session bus and secret service
- `--allow-keyring` — the on-disk keyring files

This tool is a pragmatic isolation wrapper for local agent execution. It is not a hardened container runtime. Review and adapt the mounts and environment for your threat model.

## License

MIT. See `LICENSE`.

This README was written by Codex from within the sandbox tool. :D
