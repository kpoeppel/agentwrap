#!/bin/bash
# agentwrap.sh - A high-security, low-overhead sandbox for AI agents
AGENT_CONFIG="$HOME/.agent_sandboxes/sandbox_profile"
MOUNT_CONFIG="$HOME/.agent_sandboxes/config"

if [[ ! -f "$AGENT_CONFIG" ]]
then
   echo "Please set up your general sandbox profile in $AGENT_CONFIG."
fi

# Template for the user mount config. Written to $MOUNT_CONFIG on first run and
# dumped by --print-config; this heredoc is the only definition of the
# user-tier default mounts.
print_default_config() {
    cat <<'EOF'
# agentwrap config v1
#
# Mount defaults for agentwrap. Sourced as bash, so $HOME and other variables
# expand and conditionals work. Entries are either SRC (mounted at the same
# path inside the sandbox) or SRC:DEST.
#
# These arrays replace the built-in $HOME defaults. System paths (/usr, /bin,
# /lib, /lib64, /etc) and session state (bash history, ssh jail) stay in the
# script. Missing sources are skipped with a warning, so listing an agent you
# have not installed is harmless.
#
# Reprint this template with: agentwrap --print-config

# Read-only: toolchains and identity the agent may read but not modify.
SANDBOX_RO_MOUNTS=(
    "$HOME/.nvm"
    "$HOME/.miniconda3"
    "$HOME/.local"
    "$HOME/.gitconfig"
    "$HOME/.tmux.conf"        # tmux config (history-limit, keybindings, ...)
    "$HOME/.tmux"             # tmux plugins / resurrect state (RO: no writes)
    "$HOME/.ssh/known_hosts"
)

# Read-write: agent state that has to survive the sandbox.
# Applied after the read-only list, so more specific paths win.
SANDBOX_RW_MOUNTS=(
    "$HOME/.cache"
    "$HOME/.claude"
    "$HOME/.claude.json"
    "$HOME/.codex"
    "$HOME/.gemini"
    "$HOME/.pi"
    "$HOME/.local/share/opencode"
)

# Entries to drop from the lists above, matched by basename or full path
# (same as the --no-mount option).
SANDBOX_NO_MOUNTS=()

# Extra environment variables exported inside the sandbox, as VAR=VALUE
# entries. Applied after the built-in and --allow-* settings but before
# --setenv, so command-line values win. Example:
#   SANDBOX_ENV=("EDITOR=vim" "PAGER=less")
SANDBOX_ENV=()
EOF
}

resolve_mount_src() {
    # Resolve a command-line mount source. Unlike config entries these are
    # explicit requests, so a missing path is an error rather than a skip.
    local raw="$1" opt="$2" resolved
    resolved=$(realpath -- "$raw" 2>/dev/null)
    if [[ -z "$resolved" || ! -e "$resolved" ]]; then
        echo "agentwrap: $opt: no such path: $raw" >&2
        return 1
    fi
    printf '%s' "$resolved"
}

ALLOWED_HOSTS=()
PROJECT_PATHS=()
CMD_ARGS=()
RO_MOUNTS=()
RW_MOUNTS=()
CLI_RO_MOUNTS=()
CLI_RW_MOUNTS=()
NO_MOUNTS=()
SYNC_REAL_FROM_SANDBOX=""
SYNC_REAL_TO_SANDBOX=""
CHECK_DIFF=""
SYNC_EXCLUDES=()
UNLOCK_ONLY=""
ALLOW_GPU=""
ALLOW_APPTAINER=""
ALLOW_FLATPAK=""
ALLOW_NET=""          # "", "host" or "isolated"
NET_WRAPPER_ARGS=()
ALLOW_X11=""          # "", "real" or "virtual"
ALLOW_DBUS=""
ALLOW_KEYRING=""
XVFB_PID=""
CLEARENV=""
SETENV_ARGS=()

# --- PARSE ARGUMENTS ---
# Parse options first (must come before project paths)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-ssh)
            ALLOWED_HOSTS+=("$2")
            ENABLE_SSH=1
            # SSH needs real egress, which the isolated default netns cannot
            # provide. Default to the host network namespace unless the user
            # already selected an explicit mode (e.g. --allow-net=isolated).
            if [[ -z "$ALLOW_NET" ]]; then
                ALLOW_NET=host
                echo "agentwrap: --allow-ssh implies --allow-net; the host network namespace (internet, LAN, host loopback) will be shared. Use --allow-net=isolated for a private NAT." >&2
            fi
            shift 2
            ;;
        --allow-gpu)
            ALLOW_GPU=1
            shift 1
            ;;
        --allow-apptainer)
            ALLOW_APPTAINER=1
            shift 1
            ;;
        --allow-flatpak)
            ALLOW_FLATPAK=1
            shift 1
            ;;
        --allow-net)
            ALLOW_NET=host
            shift 1
            ;;
        --allow-net=host)
            ALLOW_NET=host
            shift 1
            ;;
        --allow-net=isolated)
            ALLOW_NET=isolated
            shift 1
            ;;
        --allow-net=*)
            echo "agentwrap: --allow-net expects 'host' or 'isolated'."
            exit 1
            ;;
        --allow-x11)
            ALLOW_X11=real
            shift 1
            ;;
        --allow-x11=*)
            ALLOW_X11="${1#--allow-x11=}"
            case "$ALLOW_X11" in
                real|virtual) ;;
                *)
                    echo "agentwrap: --allow-x11 expects 'real' or 'virtual'."
                    exit 1
                    ;;
            esac
            shift 1
            ;;
        --allow-dbus)
            ALLOW_DBUS=1
            shift 1
            ;;
        --allow-keyring)
            ALLOW_KEYRING=1
            shift 1
            ;;
        --clearenv)
            CLEARENV=1
            shift 1
            ;;
        --setenv)
            if [[ $# -lt 3 ]]; then
                echo "agentwrap: --setenv requires VAR and VALUE arguments."
                exit 1
            fi
            SETENV_ARGS+=(--setenv "$2" "$3")
            shift 3
            ;;
        --mount-home)
            CLI_RO_MOUNTS+=( "$HOME" )
            shift 1
            ;;
        --mount-ro)
            MOUNT_SRC=$(resolve_mount_src "$2" "$1") || exit 1
            CLI_RO_MOUNTS+=( "$MOUNT_SRC" )
            shift 2
            ;;
        --mount-to-ro)
            MOUNT_SRC=$(resolve_mount_src "$2" "$1") || exit 1
            CLI_RO_MOUNTS+=( "$MOUNT_SRC:$3" )
            shift 3
            ;;
        --mount-rw)
            if [[ "$2" == *:* ]]; then
                MOUNT_SRC=$(resolve_mount_src "${2%%:*}" "$1") || exit 1
                CLI_RW_MOUNTS+=( "$MOUNT_SRC:${2#*:}" )
            else
                MOUNT_SRC=$(resolve_mount_src "$2" "$1") || exit 1
                CLI_RW_MOUNTS+=( "$MOUNT_SRC" )
            fi
            shift 2
            ;;
        --mount-to-rw)
            MOUNT_SRC=$(resolve_mount_src "$2" "$1") || exit 1
            CLI_RW_MOUNTS+=( "$MOUNT_SRC:$3" )
            shift 3
            ;;
        --no-mount)
            NO_MOUNTS+=( "$2" )
            shift 2
            ;;
        --sync-out)
            SYNC_REAL_FROM_SANDBOX=1
            shift 1
            ;;
        --sync-in)
            SYNC_REAL_TO_SANDBOX=1
            shift 1
            ;;
        --unlock)
            UNLOCK_ONLY=1
            shift 1
            ;;
        --check-diff)
            CHECK_DIFF=1
            shift 1
            ;;
        --sync-exclude)
            SYNC_EXCLUDES+=("$2")
            shift 2
            ;;
        --print-config)
            print_default_config
            exit 0
            ;;
        --help)
            echo "USAGE: agentwrap [OPTIONS] /path1 [/path2 ...] [-- command...]"
            echo ""
            echo "OPTIONS (must come before project paths):"
            echo "  --mount-ro PATH       Mount PATH as read-only"
            echo "  --mount-to-ro SRC DEST Mount SRC as read-only at DEST"
            echo "  --mount-rw SRC[:DEST] Mount SRC as read-write (optionally at DEST)"
            echo "  --mount-to-rw SRC DEST Mount SRC as read-write at DEST"
            echo "  --mount-home          Mount entire home directory as read-only"
            echo "  --no-mount ITEM       Skip a default mount by name/path (repeatable)"
            echo "  --allow-ssh HOST      Allow SSH access to HOST"
            echo "  --allow-gpu           Pass through NVIDIA GPU devices into sandbox"
            echo "  --allow-apptainer     Allow Apptainer (Singularity) container execution"
            echo "  --allow-flatpak       Pass through flatpak runtime dirs and session bus"
            echo "  --allow-net[=MODE]    Allow network. MODE 'host' shares the host network"
            echo "                        namespace (internet, LAN, host loopback, host"
            echo "                        abstract sockets); MODE 'isolated' builds a private"
            echo "                        rootless NAT with rootlesskit+slirp4netns (blocks"
            echo "                        host loopback). Default: no network."
            echo "  --allow-x11[=MODE]    Allow X11. MODE 'real' mounts the host display"
            echo "                        (full screen/input/clipboard access); MODE 'virtual'"
            echo "                        starts a private Xvfb. Default: no X11."
            echo "  --allow-dbus          Expose the session D-Bus (implies --allow-keyring)"
            echo "  --allow-keyring       Do not mask ~/.local/share/keyrings (default: masked)"
            echo "  --clearenv            Start from an empty environment inside the sandbox"
            echo "                        (built-in vars like PATH/HOME are still set)"
            echo "  --setenv VAR VALUE    Set VAR=VALUE inside the sandbox (repeatable)"
            echo "  --sync-out            Sync sandbox changes to real project(s)"
            echo "  --sync-in             Discard sandbox changes (reset to real project state)"
            echo "  --check-diff          Show differences between sandbox and real project(s)"
            echo "  --sync-exclude PATH   Exclude PATH from sync operations"
            echo "  --unlock              Clear stale lock(s) for the specified project(s)"
            echo "  --print-config        Print the default mount config template and exit"
            echo ""
            echo "CONFIG FILE (~/.agent_sandboxes/config):"
            echo "  Bash file holding the default mounts under \$HOME, created from a"
            echo "  built-in template on first run so the script itself needs no edits:"
            echo "      SANDBOX_RO_MOUNTS=(\"\$HOME/.nvm\" \"\$HOME/.gitconfig\")"
            echo "      SANDBOX_RW_MOUNTS=(\"\$HOME/.claude\" \"\$HOME/.cache\")"
            echo "      SANDBOX_NO_MOUNTS=(.gemini)"
            echo "      SANDBOX_ENV=(\"EDITOR=vim\" \"PAGER=less\")"
            echo "  Entries support SRC or SRC:DEST like --mount-ro/--mount-rw and are"
            echo "  skipped with a warning when the source does not exist. System paths"
            echo "  (/usr, /bin, /lib, /lib64, /etc) stay built in. SANDBOX_ENV entries are"
            echo "  VAR=VALUE strings exported into the sandbox. Precedence is"
            echo "  built-in < config < command line; --no-mount applies to the first two."
            echo ""
            echo "EXAMPLES:"
            echo "  agentwrap /project/path -- bash"
            echo "  agentwrap /project/a /project/b -- claude"
            echo "  agentwrap --mount-ro /data /project -- npm test"
            echo "  agentwrap --mount-to-rw /data /mnt/data /project -- bash"
            echo "  agentwrap --no-mount .gemini /project -- bash"
            echo "  agentwrap /project --check-diff"
            echo "  agentwrap /project --sync-out"
            echo "  agentwrap /project --sync-in"
            exit 0
            ;;
        --)
            shift
            CMD_ARGS=("$@")
            break
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Run with --help for usage."
            exit 1
            ;;
        *)
            # First non-option argument: now collect project paths
            PROJECT_PATHS+=("$(realpath "$1")")
            shift

            # Continue collecting paths and command
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --)
                        shift
                        CMD_ARGS=("$@")
                        break 2
                        ;;
                    -*)
                        echo "Error: options must come before project paths"
                        echo "Got option '$1' after project path"
                        exit 1
                        ;;
                    *)
                        PROJECT_PATHS+=("$(realpath "$1")")
                        shift
                        ;;
                esac
            done
            break
            ;;
    esac
done

# Validate at least one project path
if [[ ${#PROJECT_PATHS[@]} -eq 0 ]]; then
    echo "agentwrap: no project path specified."
    echo "Run with --help for usage."
    exit 1
fi

for PPATH in "${PROJECT_PATHS[@]}"; do
if [[ $PPATH == $HOME || $PPATH == "/" ]] ; then
    echo "BAD PROJECT DIR ${PPATH}"
    exit 1
fi
done

# For backwards compatibility, use first project as primary (for chdir)
PROJECT_SRC="${PROJECT_PATHS[0]}"

if [[ -n "${AGENTWRAP_ACTIVE:-}" ]]; then
    echo "agentwrap: detected AGENTWRAP_ACTIVE in environment; refusing to nest."
    exit 1
fi

# --- HELPER FUNCTIONS FOR PER-PROJECT SANDBOXES ---
get_project_sandbox() {
    local path="$1"
    echo "$HOME/.agent_sandboxes/$(basename "$path")_$(echo "$path" | md5sum | head -c 6)"
}

get_project_upper() {
    echo "$(get_project_sandbox "$1")/upper"
}

get_project_work() {
    echo "$(get_project_sandbox "$1")/work"
}

get_project_merged() {
    echo "$(get_project_sandbox "$1")/merged"
}

get_project_lock() {
    echo "$(get_project_sandbox "$1")/lock"
}

# --- MOUNT HELPERS (per-project) ---
is_project_mounted() {
    local merged="$1"
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$merged"
    else
        grep -Fq " $merged " /proc/mounts
    fi
}


ensure_project_merged_dir() {
    local proj="$1"
    local merged=$(get_project_merged "$proj")

    if is_project_mounted "$merged"; then
        return
    fi
    if [[ -L "$merged" ]]; then
        if ! rm "$merged"; then
            echo "agentwrap: failed to remove symlink at $merged."
            exit 1
        fi
    elif [[ -e "$merged" && ! -d "$merged" ]]; then
        echo "agentwrap: $merged exists and is not a directory."
        exit 1
    fi
    if ! mkdir -p "$merged"; then
        echo "agentwrap: failed to create $merged."
        exit 1
    fi
    if [[ -L "$merged" ]]; then
        echo "agentwrap: $merged is still a symlink; refusing to mount."
        exit 1
    fi
}

ensure_project_merged_symlink() {
    local proj="$1"
    local merged=$(get_project_merged "$proj")

    if is_project_mounted "$merged"; then
        return
    fi
    if [[ -L "$merged" ]]; then
        return
    fi
    if [[ -d "$merged" ]]; then
        if rmdir "$merged" 2>/dev/null; then
            ln -s "$proj" "$merged"
        else
            echo "Warning: $merged exists and is not empty; leaving as-is."
        fi
        return
    fi
    if [[ -e "$merged" ]]; then
        echo "Warning: $merged exists and is not a directory or symlink; leaving as-is."
        return
    fi
    ln -s "$proj" "$merged"
}




# Session sandbox: combines all project paths for unique session identity
# This holds shared resources: logs, entrypoint, bash_history, resolv.conf
if [[ "${#PROJECT_PATHS[@]}" -gt 1 ]] ; then
SESSION_HASH=$(printf '%s\n' "${PROJECT_PATHS[@]}" | sort | md5sum | head -c 6)
SESSION_SANDBOX="$HOME/.agent_sandboxes/session_${SESSION_HASH}"
else
SESSION_HASH=$(echo "${PROJECT_PATHS[0]}" | md5sum | head -c 6)
SESSION_SANDBOX="$HOME/.agent_sandboxes/$(basename "${PROJECT_PATHS[0]}")_${SESSION_HASH}"
fi

# If requested, sync from the sandbox to the real project(s) and exit.
if [[ -n $SYNC_REAL_FROM_SANDBOX ]]; then
    if [[ ! -d $SESSION_SANDBOX ]]; then
       echo "SESSION_SANDBOX $SESSION_SANDBOX doesn't exist"
       exit 1
    fi
    RSYNC_EXCLUDES=()
    for pattern in "${SYNC_EXCLUDES[@]}"; do
        RSYNC_EXCLUDES+=(--exclude "$pattern")
    done

    for proj in "${PROJECT_PATHS[@]}"; do
        echo "--- Syncing sandbox view to $proj ---"
        merged=$(get_project_merged "$proj")
        upper=$(get_project_upper "$proj")
        work=$(get_project_work "$proj")

        MOUNTED=0
        if ! is_project_mounted "$merged"; then
            ensure_project_merged_dir "$proj"
            fuse-overlayfs -o lowerdir="$proj",upperdir="$upper",workdir="$work" "$merged"
            MOUNTED=1
        fi

        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$merged"/ "$proj"/
        else
            echo "rsync not found; cannot sync changes."
        fi

        if [[ $MOUNTED -eq 1 ]]; then
            fusermount -u "$merged" 2>/dev/null || umount "$merged"
            ensure_project_merged_symlink "$proj"
        fi
    done
    exit 0
fi

# If requested, discard sandbox changes (reset to real project state) and exit.
if [[ -n $SYNC_REAL_TO_SANDBOX ]]; then
    if [[ ! -d $SESSION_SANDBOX ]]; then
       echo "SESSION_SANDBOX $SESSION_SANDBOX doesn't exist"
       exit 1
    fi

    for proj in "${PROJECT_PATHS[@]}"; do
        echo "--- Discarding sandbox changes for $proj ---"
        merged=$(get_project_merged "$proj")
        upper=$(get_project_upper "$proj")
        work=$(get_project_work "$proj")

        # Unmount if mounted
        if is_project_mounted "$merged"; then
            fusermount -u "$merged" 2>/dev/null || umount "$merged"
        fi

        # Delete overlay state
        if [[ -d "$upper" ]]; then
            echo "Removing overlay state: $upper"
            rm -rf "$upper"
        fi
        if [[ -d "$work" ]]; then
            rm -rf "$work"
        fi

        # Recreate empty directories
        mkdir -p "$upper" "$work"

        # Restore symlink
        ensure_project_merged_symlink "$proj"

        echo "Sandbox reset to match real project."
    done
    exit 0
fi





REAL_RESOLV=$(realpath /etc/resolv.conf)
INTERNAL_DNS_PATH=$REAL_RESOLV
BASH_HISTORY_FILE="$SESSION_SANDBOX/bash_history"

# Track which locks we've acquired for cleanup
LOCKS_HELD=()

expand_tilde_path() {
    local path="$1"
    if [[ "$path" == "~" || "$path" == "~/"* ]]; then
        echo "${path/#\~/$HOME}"
    else
        echo "$path"
    fi
}

mount_source_exists() {
    local entry="$1"
    [[ -e "${entry%%:*}" ]]
}

should_skip_default_mount() {
    local entry="$1"
    local host="${entry%%:*}"
    local guest="${entry#*:}"
    local host_base
    local guest_base
    local rule
    local expanded_rule

    if [[ "$entry" != *:* ]]; then
        guest="$host"
    fi

    host_base=$(basename "$host")
    guest_base=$(basename "$guest")

    for rule in "${NO_MOUNTS[@]}"; do
        expanded_rule=$(expand_tilde_path "$rule")
        if [[ "$expanded_rule" == "$host" || "$expanded_rule" == "$guest" || "$expanded_rule" == "$host_base" || "$expanded_rule" == "$guest_base" ]]; then
            return 0
        fi
    done

    return 1
}

# Ensure session sandbox exists
mkdir -p "$SESSION_SANDBOX"

# Create persistent bash history file if it doesn't exist
touch "$BASH_HISTORY_FILE"

# Initialize per-project sandbox directories
for proj in "${PROJECT_PATHS[@]}"; do
    sandbox=$(get_project_sandbox "$proj")
    mkdir -p "$sandbox" "$(get_project_upper "$proj")" "$(get_project_work "$proj")"
done

# --- CONFIGURATION ---
# Base tier: paths the sandbox cannot work without, plus session state that is
# derived here rather than user data. Not part of the user config, but
# --no-mount still applies to them.
BASE_RO_MOUNTS=(
    "/usr" "/bin" "/lib" "/lib64"
)

# Note: $MERGED is handled separately as the project root
BASE_RW_MOUNTS=(
    "$BASH_HISTORY_FILE:$HOME/.bash_history"
)

# --- USER MOUNT CONFIG ---
# Bash-sourced config holding the default mounts under $HOME, so toolchains and
# agent state can be adapted without editing this script. Created from the
# built-in template on first run. Recognized arrays:
#   SANDBOX_RO_MOUNTS=(...)  read-only mounts (SRC or SRC:DEST)
#   SANDBOX_RW_MOUNTS=(...)  read-write mounts (SRC or SRC:DEST)
#   SANDBOX_NO_MOUNTS=(...)  entries to skip (same matching as --no-mount)
if [[ ! -f "$MOUNT_CONFIG" ]]; then
    if print_default_config > "$MOUNT_CONFIG"; then
        echo "agentwrap: wrote default mount config to $MOUNT_CONFIG"
    else
        echo "agentwrap: failed to write $MOUNT_CONFIG" >&2
        exit 1
    fi
fi

SANDBOX_RO_MOUNTS=()
SANDBOX_RW_MOUNTS=()
SANDBOX_NO_MOUNTS=()
SANDBOX_ENV=()
if ! source "$MOUNT_CONFIG"; then
    echo "agentwrap: failed to read $MOUNT_CONFIG; refusing to run with a partial mount list." >&2
    exit 1
fi
NO_MOUNTS+=("${SANDBOX_NO_MOUNTS[@]}")

# Configs predating the version marker were written when these arrays only
# extended a hardcoded list; they now replace the $HOME defaults instead.
if ! grep -qE '^# agentwrap config v[0-9]+' "$MOUNT_CONFIG"; then
    echo "agentwrap: $MOUNT_CONFIG has no version marker." >&2
    echo "agentwrap: its arrays now replace the built-in \$HOME mounts instead of extending them." >&2
    echo "agentwrap: compare with 'agentwrap --print-config'; add the marker line to silence this." >&2
fi

# bwrap applies binds in order and later ones win, so compose the tiers
# built-in -> config -> command line. Config and built-in entries are optional;
# a missing source is skipped rather than failing the whole sandbox.
for mount in "${BASE_RO_MOUNTS[@]}" "${SANDBOX_RO_MOUNTS[@]}"; do
    if should_skip_default_mount "$mount"; then
        continue
    fi
    if ! mount_source_exists "$mount"; then
        echo "agentwrap: skipping read-only mount, no such path: ${mount%%:*}" >&2
        continue
    fi
    RO_MOUNTS+=("$mount")
done
RO_MOUNTS+=("${CLI_RO_MOUNTS[@]}")

for mount in "${BASE_RW_MOUNTS[@]}" "${SANDBOX_RW_MOUNTS[@]}"; do
    if should_skip_default_mount "$mount"; then
        continue
    fi
    if ! mount_source_exists "$mount"; then
        echo "agentwrap: skipping read-write mount, no such path: ${mount%%:*}" >&2
        continue
    fi
    RW_MOUNTS+=("$mount")
done
RW_MOUNTS+=("${CLI_RW_MOUNTS[@]}")
# ---------------------

# --- STABLE DNS SETUP ---
AGENT_RESOLV="$SESSION_SANDBOX/resolv.conf"

# If the file doesn't exist, or you want to refresh it once per session:
# We filter out local 127.x.x.x resolvers and replace them with a public fallback
# to ensure the sandbox can actually reach the DNS server.
cat /etc/resolv.conf > "$AGENT_RESOLV"
# Fallback to Cloudflare/Google if the file became empty after filtering
if ! grep -q "nameserver" "$AGENT_RESOLV"; then
    echo "nameserver 1.1.1.1" >> "$AGENT_RESOLV"
    echo "nameserver 8.8.8.8" >> "$AGENT_RESOLV"
fi
# slirp4netns serves DNS at 10.0.2.3; the host resolvers are unreachable
# from the isolated user-mode network.
if [[ "$ALLOW_NET" == isolated ]]; then
    echo "nameserver 10.0.2.3" > "$AGENT_RESOLV"
fi


# --- SSH SCOPING CONFIG ---
SSH_JAIL="$SESSION_SANDBOX/ssh_jail"
mkdir -p "$SSH_JAIL"
chmod 700 "$SSH_JAIL"

# Create directory for SSH control sockets (for ControlMaster)
# Keep on host in SESSION_SANDBOX for security, but will mount to short path in bwrap
SSH_CONTROL_DIR="$SESSION_SANDBOX/ssh_control"
SSH_CONTROL_DIR_SANDBOX="/tmp/ssh"  # Short path inside the sandbox
mkdir -p "$SSH_CONTROL_DIR"
chmod 700 "$SSH_CONTROL_DIR"

# Clean old jail config
echo "" > "$SSH_JAIL/config"
echo "Host *" >> "$SSH_JAIL/config"

SSH_AUTH_OPTS=()
if [[ -n $ENABLE_SSH ]] ; then
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        echo "agentwrap: SSH_AUTH_SOCK is not set; cannot forward ssh agent."
        exit 1
    fi
    SSH_AUTH_SOCK_REAL=$(readlink -f "$SSH_AUTH_SOCK" 2>/dev/null || echo "$SSH_AUTH_SOCK")
    SSH_AUTH_SOCK_DIR=$(dirname -- "$SSH_AUTH_SOCK_REAL")
    SSH_AUTH_SOCK_FILENAME=$(basename -- "$SSH_AUTH_SOCK_REAL")
    SSH_AUTH_SOCK_LOCK="${SSH_AUTH_SOCK_DIR}/lock.txt"
    touch $SSH_AUTH_SOCK_LOCK
    if [[ ! -S "$SSH_AUTH_SOCK_REAL" ]]; then
        echo "agentwrap: SSH_AUTH_SOCK is not a socket: $SSH_AUTH_SOCK_REAL"
        exit 1
    fi
    SSH_AUTH_OPTS+=(
        --bind "$SSH_AUTH_SOCK_DIR" "/tmp/ssh-agent-dir/"
        --setenv SSH_AUTH_SOCK "/tmp/ssh-agent-dir/$SSH_AUTH_SOCK_FILENAME"
    )
fi

for HOST in "${ALLOWED_HOSTS[@]}"; do
    echo "Scoping SSH access for: $HOST"

    # 1. Get the resolved config for this host
    # 2. Filter out things we don't want (like ControlPath or local includes)
    # 3. Force BatchMode for non-interactive agents
    echo "" >> "$SSH_JAIL/config"
    echo "Host $HOST" >> "$SSH_JAIL/config"
    RESOLVED_CFG=$(ssh -G "$HOST")
    DEFAULT_CFG=$(ssh -G -F /dev/null "$HOST")

    # Helper function to extract and compare config values
    extract_ssh_option() {
        local option="$1"
        local resolved_val=$(echo "$RESOLVED_CFG" | awk -v opt="$option" '$1 == opt {for(i=2;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""}' | tail -n 1)
        local default_val=$(echo "$DEFAULT_CFG" | awk -v opt="$option" '$1 == opt {for(i=2;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""}' | tail -n 1)

        # Only output if different from default
        if [[ -n "$resolved_val" && "$resolved_val" != "$default_val" ]]; then
            echo "$resolved_val"
        fi
    }

    # Core connection options (always include these)
    echo "$RESOLVED_CFG" | awk '$1 == "hostname" {print "  HostName " $2}' >> "$SSH_JAIL/config"
    echo "$RESOLVED_CFG" | awk '$1 == "user" {print "  User " $2}' >> "$SSH_JAIL/config"

    # Whitelist of additional SSH options to extract (if non-default)
    # These are commonly needed and safe in a sandbox environment
    SSH_OPTIONS=(
        "port:Port"
        "batchmode:BatchMode"
        "compression:Compression"
        "compressionlevel:CompressionLevel"
        "connectionattempts:ConnectionAttempts"
        "connecttimeout:ConnectTimeout"
        "forwardagent:ForwardAgent"
        "proxycommand:ProxyCommand"
        "proxyjump:ProxyJump"
        "serveraliveinterval:ServerAliveInterval"
        "serveralivecountmax:ServerAliveCountMax"
        "stricthostkeychecking:StrictHostKeyChecking"
        "tcpkeepalive:TCPKeepAlive"
        "setenv:SetEnv"
        "controlmaster:ControlMaster"
        "controlpersist:ControlPersist"
    )

    for opt_pair in "${SSH_OPTIONS[@]}"; do
        opt_lower="${opt_pair%%:*}"
        opt_proper="${opt_pair#*:}"
        opt_value=$(extract_ssh_option "$opt_lower")
        if [[ -n "$opt_value" ]]; then
            echo "  $opt_proper $opt_value" >> "$SSH_JAIL/config"
        fi
    done

    # Special handling for ControlPath: always override to use writable directory
    # This enables SSH connection multiplexing (ControlMaster) to work in the sandbox
    # Use %C (hash) to keep path short and avoid "name too long" errors
    control_master=$(extract_ssh_option "controlmaster")
    if [[ -n "$control_master" && "$control_master" != "no" ]]; then
        # Force ControlPath to short sandbox path with hash format
        echo "  ControlPath $SSH_CONTROL_DIR_SANDBOX/%C" >> "$SSH_JAIL/config"
    fi

    # 4. Extract the IdentityFile path and add it to RO_MOUNTS
    ID_FILE=$(echo "$RESOLVED_CFG" | awk '$1 == "identityfile" {print $2}' | head -n 1)
    DEFAULT_ID_FILE=$(echo "$DEFAULT_CFG" | awk '$1 == "identityfile" {print $2}' | head -n 1)
    # Expand tilde if necessary
    ID_FILE="${ID_FILE/#\~/$HOME}"
    DEFAULT_ID_FILE="${DEFAULT_ID_FILE/#\~/$HOME}"
    if [[ -n "$DEFAULT_ID_FILE" && "$ID_FILE" == "$DEFAULT_ID_FILE" ]]; then
        ID_FILE=""
    fi

    if [[ -n "$ID_FILE" ]] && should_skip_default_mount "$ID_FILE"; then
        echo "  IdentityFile $ID_FILE" >> "$SSH_JAIL/config"
        echo "  IdentitiesOnly yes" >> "$SSH_JAIL/config"
    elif [[ -f "$ID_FILE" ]]; then
        RO_MOUNTS+=("$ID_FILE")
        echo "  IdentityFile $ID_FILE" >> "$SSH_JAIL/config"
        echo "  IdentitiesOnly yes" >> "$SSH_JAIL/config"
    else
        echo "  IdentityAgent /tmp/ssh-agent-dir/$SSH_AUTH_SOCK_FILENAME" >> "$SSH_JAIL/config"
        echo "  IdentitiesOnly no" >> "$SSH_JAIL/config"
    fi
done

# Add the synthetic config to full mounts (so the agent sees it as ~/.ssh/config)
RW_MOUNTS+=("$SSH_JAIL/config:$HOME/.ssh/config")

# Mount the SSH control directory for ControlMaster sockets to short path in sandbox
RW_MOUNTS+=("$SSH_CONTROL_DIR:$SSH_CONTROL_DIR_SANDBOX")


echo "Using CONDA_PREFIX=$CONDA_PREFIX"



# --- LOCKING (per-project to prevent double-mounting) ---
check_project_lock() {
    local proj="$1"
    local lock_file=$(get_project_lock "$proj")

    if [[ -e "$lock_file" ]]; then
        local pid=""
        pid=$(awk -F= '$1 == "pid" {print $2}' "$lock_file" 2>/dev/null)
        if [[ -n "$pid" && -d "/proc/$pid" ]]; then
            echo "agentwrap: $proj is already wrapped (pid $pid)."
            return 1
        fi
        echo "agentwrap: stale lock for $proj at $lock_file."
        echo "agentwrap: run with --unlock to clear it."
        return 2
    fi
    return 0
}

acquire_project_lock() {
    local proj="$1"
    local lock_file=$(get_project_lock "$proj")
    local sandbox=$(get_project_sandbox "$proj")

    {
        echo "pid=$$"
        echo "started=$(date -Iseconds)"
        echo "project=$proj"
        echo "sandbox=$sandbox"
    } > "$lock_file"
    chmod 600 "$lock_file"
    LOCKS_HELD+=("$lock_file")
}

release_all_locks() {
    for lock_file in "${LOCKS_HELD[@]}"; do
        rm -f "$lock_file"
    done
    if [[ -n $SSH_AUTH_SOCK_LOCK ]] ; then
    rm $SSH_AUTH_SOCK_LOCK
    rmdir --ignore-fail-on-non-empty $(dirname $SSH_AUTH_SOCK_LOCK)
    fi
    LOCKS_HELD=()
}

# Acquire locks for all projects, abort if any is already locked
acquire_all_locks() {
    # First, check all locks without acquiring
    for proj in "${PROJECT_PATHS[@]}"; do
        if ! check_project_lock "$proj"; then
            return 1
        fi
    done
    # All clear, acquire all
    for proj in "${PROJECT_PATHS[@]}"; do
        acquire_project_lock "$proj"
    done
    return 0
}

cleanup() {
    # Stop a private Xvfb started by --allow-x11=virtual
    if [[ -n "${XVFB_PID:-}" ]]; then
        kill "$XVFB_PID" 2>/dev/null
        wait "$XVFB_PID" 2>/dev/null
        XVFB_PID=""
    fi

    # Unmount all project overlays
    for proj in "${PROJECT_PATHS[@]}"; do
        local merged=$(get_project_merged "$proj")
        if is_project_mounted "$merged"; then
            fusermount -u "$merged" 2>/dev/null || umount "$merged"
        fi
        ensure_project_merged_symlink "$proj"
    done
    release_all_locks

    # Clean up SSH control directory
    if [[ -n "${SSH_CONTROL_DIR:-}" && -d "$SSH_CONTROL_DIR" ]]; then
        rm -rf "$SSH_CONTROL_DIR"
    fi
}

if [[ -n "$UNLOCK_ONLY" ]]; then
    for proj in "${PROJECT_PATHS[@]}"; do
        lock_file=$(get_project_lock "$proj")
        if [[ -e "$lock_file" ]]; then
            rm -f "$lock_file"
            echo "agentwrap: cleared lock for $proj"
        fi
        ensure_project_merged_symlink "$proj"
    done
    exit 0
fi

# Check all locks before proceeding
for proj in "${PROJECT_PATHS[@]}"; do
    if ! check_project_lock "$proj"; then
        exit 1
    fi
done

# If requested, check for differences between sandbox view and real project(s) and exit.
if [[ -n $CHECK_DIFF ]]; then
    RSYNC_EXCLUDES=()
    for pattern in "${SYNC_EXCLUDES[@]}"; do
        RSYNC_EXCLUDES+=(--exclude "$pattern")
    done

    for proj in "${PROJECT_PATHS[@]}"; do
        echo "--- Checking sandbox view vs $proj ---"
        merged=$(get_project_merged "$proj")
        upper=$(get_project_upper "$proj")
        work=$(get_project_work "$proj")

        MOUNTED=0
        if ! is_project_mounted "$merged"; then
            ensure_project_merged_dir "$proj"
            fuse-overlayfs -o lowerdir="$proj",upperdir="$upper",workdir="$work" "$merged"
            MOUNTED=1
        fi

        if command -v rsync >/dev/null 2>&1; then
            DIFF_OUTPUT=$(rsync -a --delete --dry-run --itemize-changes "${RSYNC_EXCLUDES[@]}" "$merged"/ "$proj"/)
            if [[ -z $DIFF_OUTPUT ]]; then
                echo "In sync."
            else
                echo "$DIFF_OUTPUT"
            fi
        else
            echo "rsync not found; cannot check diff."
        fi

        if [[ $MOUNTED -eq 1 ]]; then
            fusermount -u "$merged" 2>/dev/null || umount "$merged"
            ensure_project_merged_symlink "$proj"
        fi
    done
    exit 0
fi

# Acquire locks for all projects
if ! acquire_all_locks; then
    exit 1
fi
trap cleanup EXIT INT TERM

# 1. Mount the OverlayFS for each project (The "Undo" Button)
# Allows the agent to 'delete' files without actually touching your source.
for proj in "${PROJECT_PATHS[@]}"; do
    merged=$(get_project_merged "$proj")
    upper=$(get_project_upper "$proj")
    work=$(get_project_work "$proj")

    ensure_project_merged_dir "$proj"
    fuse-overlayfs -o lowerdir="$proj",upperdir="$upper",workdir="$work" "$merged"
done

echo "RESOLV" "$AGENT_RESOLV"

# 2. Build the Bubblewrap command
BWRAP_ARGS=(
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --tmpfs "$HOME"                       # Creates the "Ghost Home"
    --chdir "$PROJECT_SRC"          # Start in the first project directory
    --ro-bind "$AGENT_CONFIG" "$HOME/.bashrc"
    --unshare-all
    --dir $HOME/.ssh
    --die-with-parent
    --setenv PATH "$CONDA_PREFIX/bin:$HOME/.local/bin:$HOME/.miniconda3/bin:/usr/bin:/bin"
    --setenv CONDA_PREFIX "$CONDA_PREFIX"
    --setenv CONDA_DEFAULT_ENV "$CONDA_DEFAULT_ENV"
    --setenv NVM_DIR "$HOME/.nvm"
    --setenv HOME "$HOME"
    --setenv AGENTWRAP_ACTIVE "1"
    # Host session state must not leak in by default. The matching --allow-*
    # branches re-add what they need later; bwrap applies env options in order,
    # so a later --setenv wins over these --unsetenv entries.
    --unsetenv DISPLAY
    --unsetenv DBUS_SESSION_BUS_ADDRESS
    --unsetenv XDG_RUNTIME_DIR
    --unsetenv SSH_AUTH_SOCK
    --ro-bind "/etc" "/etc"
    --ro-bind "$AGENT_RESOLV" "$INTERNAL_DNS_PATH"
)

# --clearenv must precede the built-in --setenv calls above, so prepend it;
# bwrap applies env options in command-line order.
if [[ -n "$CLEARENV" ]]; then
    BWRAP_ARGS=(--clearenv "${BWRAP_ARGS[@]}")
fi

# Add bind mounts for all project overlays
for proj in "${PROJECT_PATHS[@]}"; do
    merged=$(get_project_merged "$proj")
    BWRAP_ARGS+=(--bind "$merged" "$proj")
done

for SSH_AUTH_OPT in "${SSH_AUTH_OPTS[@]}"; do
BWRAP_ARGS+=($SSH_AUTH_OPT)
done

# --- GPU PASSTHROUGH ---
if [[ -n "$ALLOW_GPU" ]]; then
    # All NVIDIA device nodes (multi-GPU: nvidia0, nvidia1, ...)
    for dev in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-modeset \
               /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
        [[ -e "$dev" ]] && BWRAP_ARGS+=(--dev-bind "$dev" "$dev")
    done
    if [[ -d /dev/nvidia-caps ]]; then
        BWRAP_ARGS+=(--dir /dev/nvidia-caps)
        for cap in /dev/nvidia-caps/*; do
            [[ -e "$cap" ]] && BWRAP_ARGS+=(--dev-bind "$cap" "$cap")
        done
    fi
    if [[ -d /dev/dri ]]; then
        BWRAP_ARGS+=(--dir /dev/dri)
        for dri in /dev/dri/card* /dev/dri/renderD*; do
            [[ -e "$dri" ]] && BWRAP_ARGS+=(--dev-bind "$dri" "$dri")
        done
    fi
    # Mount CUDA toolkit libraries so apptainer --nv can find them
    [[ -d /usr/local/cuda ]] && BWRAP_ARGS+=(--ro-bind /usr/local/cuda /usr/local/cuda)
fi

# --- APPTAINER PASSTHROUGH ---
# Primary use-case: apptainer exec /path/to/file.sif <command>
# Mount SIF files into the sandbox via --mount-ro. Pulling docker:// images also
# works but is secondary; use apptainer --nv for GPU access inside containers.
if [[ -n "$ALLOW_APPTAINER" ]]; then
    # /dev/fuse is required for squashfuse (SIF container mounting)
    [[ -e /dev/fuse ]] && BWRAP_ARGS+=(--dev-bind /dev/fuse /dev/fuse)
    # Apptainer needs /var/lib/apptainer/mnt/session for per-container overlays
    BWRAP_ARGS+=(--tmpfs /var --dir /var/tmp --dir /var/lib/apptainer/mnt/session)
    # Share the host apptainer cache read-write so pre-pulled SIFs are accessible
    # and any new pulls are persisted to the host cache.
    [[ -d "$HOME/.apptainer" ]] && BWRAP_ARGS+=(--bind "$HOME/.apptainer" "$HOME/.apptainer")
    # Host-backed tmpdir for SIF builds (bwrap's /tmp is a nodev tmpfs which
    # blocks device node creation during OCI->SIF conversion).
    APPTAINER_TMP="$SESSION_SANDBOX/apptainer_tmp"
    mkdir -p "$APPTAINER_TMP"
    BWRAP_ARGS+=(--bind "$APPTAINER_TMP" "/tmp/apptainer_build"
                 --setenv APPTAINER_TMPDIR "/tmp/apptainer_build")
fi

# --- FLATPAK PASSTHROUGH ---
# Passes through the per-user flatpak runtime state and the D-Bus session bus
# so flatpak and portal-based tools work inside the sandbox.
if [[ -n "$ALLOW_FLATPAK" ]]; then
    XDG_RUNTIME_HOST="/run/user/$(id -u)"
    for item in .flatpak .flatpak-cache .flatpak-helper bus doc; do
        [[ -e "$XDG_RUNTIME_HOST/$item" ]] && \
            BWRAP_ARGS+=(--bind "$XDG_RUNTIME_HOST/$item" "$XDG_RUNTIME_HOST/$item")
    done
    BWRAP_ARGS+=(--setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_HOST"
                 --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$XDG_RUNTIME_HOST/bus")
    # The session bus reaches the running secret service, so the on-disk mask
    # would be cosmetic; unmask for consistency with --allow-dbus.
    ALLOW_KEYRING=1
fi

# --- NETWORK, DBUS AND X11 PASSTHROUGH (all off by default) ---
# --unshare-all already creates a private network namespace, so host loopback
# services, LAN hosts and host abstract unix sockets (X11, systemd, ...) are
# unreachable by default. --allow-net re-enables networking in one of two ways:
#   host      retain the host network namespace (blunt: also exposes host
#             loopback services and host abstract sockets)
#   isolated  run the whole sandbox under rootlesskit + slirp4netns, which
#             provides user-mode NAT in a private netns and blocks the host
#             loopback. Requires rootlesskit and slirp4netns.
if [[ "$ALLOW_NET" == isolated ]]; then
    if ! command -v rootlesskit >/dev/null 2>&1; then
        echo "agentwrap: --allow-net=isolated requires rootlesskit." >&2
        exit 1
    fi
    if ! command -v slirp4netns >/dev/null 2>&1; then
        echo "agentwrap: --allow-net=isolated requires slirp4netns." >&2
        exit 1
    fi
    NET_WRAPPER_ARGS=(rootlesskit --net=slirp4netns --disable-host-loopback
                      --port-driver=none --copy-up=/etc)
fi
if [[ -n "$ALLOW_NET" ]]; then
    BWRAP_ARGS+=(--share-net)
fi

# The session bus is a filesystem socket, so it works even in an isolated
# network namespace. Reaching it also reaches the secret service, which serves
# the keyring regardless of the on-disk mask below, so unmask in that case.
if [[ -n "$ALLOW_DBUS" ]]; then
    XDG_RUNTIME_HOST="/run/user/$(id -u)"
    [[ -e "$XDG_RUNTIME_HOST/bus" ]] && \
        BWRAP_ARGS+=(--bind "$XDG_RUNTIME_HOST/bus" "$XDG_RUNTIME_HOST/bus")
    BWRAP_ARGS+=(--setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_HOST"
                 --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$XDG_RUNTIME_HOST/bus")
    ALLOW_KEYRING=1
fi

# X11 is a filesystem socket, so it works in an isolated network namespace too.
# 'real' hands over the host display; 'virtual' starts a throwaway Xvfb so the
# agent gets a screen without access to the user's session.
if [[ -n "$ALLOW_X11" ]]; then
    case "$ALLOW_X11" in
        real)
            if [[ -d /tmp/.X11-unix ]]; then
                BWRAP_ARGS+=(--ro-bind /tmp/.X11-unix /tmp/.X11-unix)
            fi
            [[ -f "$HOME/.Xauthority" ]] && \
                BWRAP_ARGS+=(--ro-bind "$HOME/.Xauthority" "$HOME/.Xauthority")
            BWRAP_ARGS+=(--setenv DISPLAY "${DISPLAY:-:0}")
            echo "agentwrap: --allow-x11=real grants full access to display ${DISPLAY:-:0} (screen, input, clipboard)." >&2
            ;;
        virtual)
            if ! command -v Xvfb >/dev/null 2>&1; then
                echo "agentwrap: --allow-x11=virtual needs Xvfb (install the xvfb package); use --allow-x11=real for the host display." >&2
                exit 1
            fi
            VIRTUAL_DISPLAY=""
            for n in $(seq 99 -1 1); do
                if [[ ! -e "/tmp/.X11-unix/X$n" ]]; then
                    VIRTUAL_DISPLAY=":$n"
                    break
                fi
            done
            if [[ -z "$VIRTUAL_DISPLAY" ]]; then
                echo "agentwrap: no free X display number available for Xvfb." >&2
                exit 1
            fi
            VIRTUAL_X_SOCKET="X${VIRTUAL_DISPLAY#:}"
            Xvfb "$VIRTUAL_DISPLAY" -screen 0 1920x1080x24 -nolisten tcp -ac >/dev/null 2>&1 &
            XVFB_PID=$!
            for _ in $(seq 1 50); do
                [[ -e "/tmp/.X11-unix/$VIRTUAL_X_SOCKET" ]] && break
                sleep 0.1
            done
            if [[ ! -e "/tmp/.X11-unix/$VIRTUAL_X_SOCKET" ]]; then
                echo "agentwrap: Xvfb failed to start on $VIRTUAL_DISPLAY." >&2
                kill "$XVFB_PID" 2>/dev/null
                exit 1
            fi
            BWRAP_ARGS+=(--dir /tmp/.X11-unix
                         --ro-bind "/tmp/.X11-unix/$VIRTUAL_X_SOCKET" "/tmp/.X11-unix/$VIRTUAL_X_SOCKET"
                         --setenv DISPLAY "$VIRTUAL_DISPLAY")
            echo "agentwrap: --allow-x11=virtual started a private Xvfb on $VIRTUAL_DISPLAY."
            ;;
    esac
fi

# Config-tier environment variables. Precedence is built-in < config <
# command line, so these come after the built-in/--allow-* setenvs and before
# the user's --setenv values (bwrap applies env options in order).
for kv in "${SANDBOX_ENV[@]}"; do
    if [[ "$kv" != *=* ]]; then
        echo "agentwrap: SANDBOX_ENV entry without '=': $kv" >&2
        continue
    fi
    if [[ -z "${kv%%=*}" ]]; then
        echo "agentwrap: SANDBOX_ENV entry has an empty variable name: $kv" >&2
        continue
    fi
    BWRAP_ARGS+=(--setenv "${kv%%=*}" "${kv#*=}")
done

# User-supplied --setenv values go last so they override built-in and
# mode-specific (e.g. flatpak) env settings.
if [[ ${#SETENV_ARGS[@]} -gt 0 ]]; then
    BWRAP_ARGS+=("${SETENV_ARGS[@]}")
fi

# /sys (sysfs) is required by NVML (GPU enumeration), apptainer and flatpak
# (kernel/hardware queries during container setup). Mount once if any is active.
if [[ -n "$ALLOW_GPU" || -n "$ALLOW_APPTAINER" || -n "$ALLOW_FLATPAK" ]]; then
    BWRAP_ARGS+=(--ro-bind /sys /sys)
fi

# --- RECORDING SETUP ---
LOG_DIR="$SESSION_SANDBOX/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/session_$TIMESTAMP.log"

echo "--- Sandbox Active ---"
echo "Projects: ${PROJECT_PATHS[*]}"
echo "Recording session to: $LOG_FILE"

# Execute via 'script'
# -q: quiet (don't log start/stop messages to the terminal)
# -c: command to run
# -f: flush output after every write (important if the agent crashes)
# --- COMMAND HANDLING ---
ENTRYPOINT="$SESSION_SANDBOX/entrypoint.sh"

{
    echo "#!/bin/bash"
    echo "source ~/.bashrc"
    if [ ${#CMD_ARGS[@]} -eq 0 ]; then
        echo "exec bash -i"
    else
        # This preserves the array exactly as it was received
        echo "exec $(printf "%q " "${CMD_ARGS[@]}")"
    fi
} > "$ENTRYPOINT"
chmod +x "$ENTRYPOINT"

MEM_LIMIT=4000000000
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/session_$TIMESTAMP.log"

# Add Read-Only Mounts
for mapping in "${RO_MOUNTS[@]}"; do
    if [[ "$mapping" == *:* ]]; then
        BWRAP_ARGS+=(--ro-bind "${mapping%%:*}" "${mapping#*:}")
    else
        BWRAP_ARGS+=(--ro-bind "$mapping" "$mapping")
    fi
done

# Add Read-Write Mounts (handling the host:guest mapping)
for mapping in "${RW_MOUNTS[@]}"; do
    if [[ "$mapping" == *:* ]]; then
        BWRAP_ARGS+=(--bind "${mapping%%:*}" "${mapping#*:}")
    else
        BWRAP_ARGS+=(--bind "$mapping" "$mapping")
    fi
done

# Mask secret stores that would otherwise come in through the ~/.local
# read-only mount. Applied after every other bind so it always wins; use
# --allow-keyring (or --allow-dbus, which reaches the secret service anyway)
# to opt out.
if [[ -z "$ALLOW_KEYRING" ]]; then
    for secret_store in "$HOME/.local/share/keyrings"; do
        if [[ -e "$secret_store" ]]; then
            BWRAP_ARGS+=(--tmpfs "$secret_store")
        fi
    done
fi
BWRAP_ARGS+=(--bind "$ENTRYPOINT" "$HOME/entrypoint.sh")

echo "--- Sandbox Active: Recording to $LOG_FILE ---"

echo "${BWRAP_ARGS[*]}"

# limit resources in the future
# prlimit --as=$MEM_LIMIT --nproc=1000
# %q-quote each arg so values with spaces or empty strings survive the
# flattening into the shell command string that 'script' executes.
# --allow-net=isolated keeps the rootlesskit/slirp4netns network namespace by
# retaining it with --share-net while wrapping the bwrap command in rootlesskit.
# Guard the prefix: printf on an empty array emits "'' ", which would break the
# "bwrap ..." command line expected by tests and logs.
if [[ ${#NET_WRAPPER_ARGS[@]} -gt 0 ]]; then
    BWRAP_CMD="$(printf "%q " "${NET_WRAPPER_ARGS[@]}")bwrap $(printf "%q " "${BWRAP_ARGS[@]}") $HOME/entrypoint.sh"
else
    BWRAP_CMD="bwrap $(printf "%q " "${BWRAP_ARGS[@]}") $HOME/entrypoint.sh"
fi
script -q -f -c "$BWRAP_CMD" "$LOG_FILE"

# Optional: Clean up empty log files
[ ! -s "$LOG_FILE" ] && rm "$LOG_FILE"

# 4. Cleanup
cleanup
trap - EXIT INT TERM
echo "--- Sandbox Closed ---"
