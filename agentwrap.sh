#!/bin/bash
# agentwrap.sh - A high-security, low-overhead sandbox for AI agents
AGENT_CONFIG="$HOME/.agent_sandboxes/sandbox_profile"

ALLOWED_HOSTS=()
PROJECT_PATHS=()
CMD_ARGS=()
RO_MOUNTS=()
RW_MOUNTS=()
SYNC_REAL_FROM_SANDBOX=""
CHECK_DIFF=""
SYNC_EXCLUDES=()
UNLOCK_ONLY=""

# --- PARSE ARGUMENTS ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-ssh)
            ALLOWED_HOSTS+=("$2")
            ENABLE_SSH=1
            shift 2
            ;;
        --mount-home)
            RO_MOUNTS+=( "$HOME" )
            shift 1
            ;;
        --mount-ro)
            RO_MOUNTS+=( $(realpath "$2") )
            shift 2
            ;;
        --mount-rw)
            RW_MOUNTS+=( $(realpath "$2") )
            shift 2
            ;;
        --sync-out)
            SYNC_REAL_FROM_SANDBOX=1
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
        --help)
            echo "USAGE: ./agentwrap.sh [OPTIONS] /path1 [/path2 ...] [-- command...]"
            echo ""
            echo "OPTIONS:"
            echo "  --mount-ro PATH       Mount PATH as read-only"
            echo "  --mount-rw SRC[:DEST] Mount SRC as read-write (optionally at DEST)"
            echo "  --mount-home          Mount entire home directory as read-only"
            echo "  --allow-ssh HOST      Allow SSH access to HOST"
            echo "  --sync-out            Sync sandbox changes to real project(s)"
            echo "  --check-diff          Show differences between sandbox and real project(s)"
            echo "  --sync-exclude PATH   Exclude PATH from sync operations"
            echo "  --unlock              Clear stale lock(s) for the specified project(s)"
            echo ""
            echo "Use -- to separate project paths from the command to run."
            echo "Example: agentwrap /project/a /project/b -- claude"
            exit 0
            ;;
        --)
            shift
            CMD_ARGS=("$@")
            break
            ;;
        -*) # Handle other flags if you add them
            echo "Unknown option: $1"
            exit 1
            ;;
        *) # Collect project paths until -- or end
            PROJECT_PATHS+=("$(realpath "$1")")
            shift
            ;;
    esac
done

# Validate at least one project path
if [[ ${#PROJECT_PATHS[@]} -eq 0 ]]; then
    echo "agentwrap: no project path specified."
    echo "Run with --help for usage."
    exit 1
fi

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

# Session sandbox: combines all project paths for unique session identity
# This holds shared resources: logs, entrypoint, bash_history, resolv.conf
if [[ "${#PROJECT_PATHS[@]}" -gt 1 ]]
then
SESSION_HASH=$(printf '%s\n' "${PROJECT_PATHS[@]}" | sort | md5sum | head -c 6)
SESSION_SANDBOX="$HOME/.agent_sandboxes/session_${SESSION_HASH}"
else
SESSION_HASH=$(echo "${PROJECT_PATHS[0]}" | md5sum | head -c 6)
SESSION_SANDBOX="$HOME/.agent_sandboxes/$(basename "$PROJECT_SRC")_${SESSION_HASH}"
fi


REAL_RESOLV=$(realpath /etc/resolv.conf)
INTERNAL_DNS_PATH=$REAL_RESOLV
BASH_HISTORY_FILE="$SESSION_SANDBOX/bash_history"

# Track which locks we've acquired for cleanup
LOCKS_HELD=()

# Ensure session sandbox exists
mkdir -p "$SESSION_SANDBOX"

# Create persistent bash history file if it doesn't exist
touch "$BASH_HISTORY_FILE"

# Initialize per-project sandbox directories
for proj in "${PROJECT_PATHS[@]}"; do
    sandbox=$(get_project_sandbox "$proj")
    mkdir -p "$sandbox" "$(get_project_upper "$proj")" "$(get_project_work "$proj")"
done

# Create persistent bash history file if it doesn't exist
touch "$BASH_HISTORY_FILE"

# --- CONFIGURATION ---
# Directories the agent can READ but not TOUCH
RO_MOUNTS+=(
    "/usr" "/bin" "/lib" "/lib64"
    "$HOME/.nvm"
    "$HOME/.miniconda3"
    "$HOME/.local"
    "$HOME/.gitconfig"
    "$HOME/.ssh/known_hosts"
)

# Directories the agent has FULL autonomy over
# Note: $MERGED is handled separately as the project root
RW_MOUNTS+=(
    "$HOME/.cache:$HOME/.cache"
    "$HOME/.gemini"
    "$HOME/.codex"
    "$HOME/.claude"
    "$HOME/.claude.json"
    "$BASH_HISTORY_FILE:$HOME/.bash_history"
)
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


# --- SSH SCOPING CONFIG ---
SSH_JAIL="$SESSION_SANDBOX/ssh_jail"
mkdir -p "$SSH_JAIL"
chmod 700 "$SSH_JAIL"

# Clean old jail config
echo "" > "$SSH_JAIL/config"
echo "Host *" >> "$SSH_JAIL/config"

for HOST in "${ALLOWED_HOSTS[@]}"; do
    echo "Scoping SSH access for: $HOST"
    
    # 1. Get the resolved config for this host
    # 2. Filter out things we don't want (like ControlPath or local includes)
    # 3. Force BatchMode for non-interactive agents
    echo "" >> "$SSH_JAIL/config"
    echo "Host $HOST" >> "$SSH_JAIL/config"
    RESOLVED_CFG=$(ssh -G "$HOST")
    DEFAULT_CFG=$(ssh -G -F /dev/null "$HOST")
    echo "$RESOLVED_CFG" | awk '$1 == "hostname" {print "  HostName " $2}' >> "$SSH_JAIL/config"
    echo "$RESOLVED_CFG" | awk '$1 == "user" {print "  User " $2}' >> "$SSH_JAIL/config"
    echo "$RESOLVED_CFG" | awk '$1 == "port" {print "  Port " $2}' >> "$SSH_JAIL/config"
    RESOLVED_BATCHMODE=$(echo "$RESOLVED_CFG" | awk '$1 == "batchmode" {print $2}' | tail -n 1)
    DEFAULT_BATCHMODE=$(echo "$DEFAULT_CFG" | awk '$1 == "batchmode" {print $2}' | tail -n 1)
    if [[ -n "$RESOLVED_BATCHMODE" && "$RESOLVED_BATCHMODE" != "$DEFAULT_BATCHMODE" ]]; then
        echo "  BatchMode $RESOLVED_BATCHMODE" >> "$SSH_JAIL/config"
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

    if [ -f "$ID_FILE" ]; then
        RO_MOUNTS+=("$ID_FILE")
        echo "  IdentityFile $ID_FILE" >> "$SSH_JAIL/config"
        echo "  IdentitiesOnly yes" >> "$SSH_JAIL/config"
    else
        echo "  IdentityAgent /tmp/ssh-agent.sock" >> "$SSH_JAIL/config"
        echo "  IdentitiesOnly no" >> "$SSH_JAIL/config"
    fi
done

# Add the synthetic config to full mounts (so the agent sees it as ~/.ssh/config)
RW_MOUNTS+=("$SSH_JAIL/config:$HOME/.ssh/config")


echo "Using CONDA_PREFIX=$CONDA_PREFIX"

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
    # Unmount all project overlays
    for proj in "${PROJECT_PATHS[@]}"; do
        local merged=$(get_project_merged "$proj")
        if is_project_mounted "$merged"; then
            fusermount -u "$merged" 2>/dev/null || umount "$merged"
        fi
        ensure_project_merged_symlink "$proj"
    done
    release_all_locks
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

# If requested, sync from the sandbox to the real project(s) and exit.
if [[ -n $SYNC_REAL_FROM_SANDBOX ]]; then
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
    --share-net
    --dir $HOME/.ssh
    --die-with-parent
    --setenv PATH "$HOME/.local/bin:$HOME/.miniconda3/bin:/usr/bin:/bin"
    --setenv NVM_DIR "$HOME/.nvm"
    --setenv HOME "$HOME"
    --setenv AGENTWRAP_ACTIVE "1"
    --ro-bind "/etc" "/etc"
    --ro-bind "$AGENT_RESOLV" "$INTERNAL_DNS_PATH"
)

# Add bind mounts for all project overlays
for proj in "${PROJECT_PATHS[@]}"; do
    merged=$(get_project_merged "$proj")
    BWRAP_ARGS+=(--bind "$merged" "$proj")
done

if [[ -n $ENABLE_SSH ]] ; then
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        echo "agentwrap: SSH_AUTH_SOCK is not set; cannot forward ssh agent."
        exit 1
    fi
    SSH_AUTH_SOCK_REAL=$(readlink -f "$SSH_AUTH_SOCK" 2>/dev/null || echo "$SSH_AUTH_SOCK")
    if [[ ! -S "$SSH_AUTH_SOCK_REAL" ]]; then
        echo "agentwrap: SSH_AUTH_SOCK is not a socket: $SSH_AUTH_SOCK_REAL"
        exit 1
    fi
BWRAP_ARGS+=(
    --bind "$SSH_AUTH_SOCK_REAL" "/tmp/ssh-agent.sock"
    --setenv SSH_AUTH_SOCK "/tmp/ssh-agent.sock"
)
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
for dir in "${RO_MOUNTS[@]}"; do
    BWRAP_ARGS+=(--ro-bind "$dir" "$dir")
done

# Add Read-Write Mounts (handling the host:guest mapping)
for mapping in "${RW_MOUNTS[@]}"; do
    BWRAP_ARGS+=(--bind ${mapping%%:*} ${mapping#*:})
done
BWRAP_ARGS+=(--ro-bind "$ENTRYPOINT" "$HOME/entrypoint.sh")

echo "--- Sandbox Active: Recording to $LOG_FILE ---"
# limit resources in the future
# prlimit --as=$MEM_LIMIT --nproc=1000
script -q -f -c "bwrap ${BWRAP_ARGS[*]} $HOME/entrypoint.sh" "$LOG_FILE"

# Optional: Clean up empty log files
[ ! -s "$LOG_FILE" ] && rm "$LOG_FILE"

# 4. Cleanup
cleanup
trap - EXIT INT TERM
echo "--- Sandbox Closed ---"
