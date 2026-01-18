#!/bin/bash
# agentwrap.sh - A high-security, low-overhead sandbox for AI agents
AGENT_CONFIG="$HOME/.agent_sandboxes/sandbox_profile"

ALLOWED_HOSTS=()
PROJECT_SRC=""
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
            echo "USAGE: ./agentwrap.sh [--mount-ro PATH] [--mount-rw SRC[:DEST]] [--mount-home] [--sync-out] [--check-diff] [--sync-exclude PATH] [--unlock] /project/path [command...]"
            exit 0
            ;;
        -*) # Handle other flags if you add them
            echo "Unknown option: $1"
            exit 1
            ;;
        *) # First non-flag is the project path, everything after is the command
            if [ -z "$PROJECT_SRC" ]; then
                PROJECT_SRC=$(realpath "$1")
                shift
            else
                CMD_ARGS=("$@") # Capture all remaining args as the command
                break
            fi
            ;;
    esac
done

if [[ -n "${AGENTWRAP_ACTIVE:-}" ]]; then
    echo "agentwrap: detected AGENTWRAP_ACTIVE in environment; refusing to nest."
    exit 1
fi


SANDBOX_ROOT="$HOME/.agent_sandboxes/$(basename "$PROJECT_SRC")_$(echo "$PROJECT_SRC" | md5sum | head -c 6)"
UPPER="$SANDBOX_ROOT/upper"
WORK="$SANDBOX_ROOT/work"
MERGED="$SANDBOX_ROOT/merged"
TARGET_PATH="$PROJECT_SRC"
REAL_RESOLV=$(realpath /etc/resolv.conf)
# Define where the 'actual' file will live inside the bubble
INTERNAL_DNS_PATH=$REAL_RESOLV
LOCK_FILE="$SANDBOX_ROOT/lock"
LOCK_HELD=""
BASH_HISTORY_FILE="$SANDBOX_ROOT/bash_history"

# Ensure sandbox root exists before writing any derived files (e.g. resolv.conf)
mkdir -p "$SANDBOX_ROOT"

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
AGENT_RESOLV="$SANDBOX_ROOT/resolv.conf"

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
SSH_JAIL="$SANDBOX_ROOT/ssh_jail"
mkdir -p "$SSH_JAIL"
chmod 700 "$SSH_JAIL"

# Clean old jail config
echo "" > "$SSH_JAIL/config"

for HOST in "${ALLOWED_HOSTS[@]}"; do
    echo "Scoping SSH access for: $HOST"
    
    # 1. Get the resolved config for this host
    # 2. Filter out things we don't want (like ControlPath or local includes)
    # 3. Force BatchMode for non-interactive agents
    ssh -G "$HOST" | grep -E "^(hostname|user|port|identityfile) " >> "$SSH_JAIL/config"
    echo "  BatchMode yes" >> "$SSH_JAIL/config"
    echo "  IdentitiesOnly yes" >> "$SSH_JAIL/config"
    
    # 4. Extract the IdentityFile path and add it to RO_MOUNTS
    ID_FILE=$(ssh -G "$HOST" | awk '$1 == "identityfile" {print $2}' | head -n 1)
    # Expand tilde if necessary
    ID_FILE="${ID_FILE/#\~/$HOME}"
    
    if [ -f "$ID_FILE" ]; then
        RO_MOUNTS+=("$ID_FILE")
    fi
done

# Add the synthetic config to full mounts (so the agent sees it as ~/.ssh/config)
RW_MOUNTS+=("$SSH_JAIL/config:$HOME/.ssh/config")


echo "Using CONDA_PREFIX=$CONDA_PREFIX"

# Setup physical directories
mkdir -p "$UPPER" "$WORK" 

is_mounted() {
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$MERGED"
    else
        grep -Fq " $MERGED " /proc/mounts
    fi
}

ensure_merged_dir() {
    if is_mounted; then
        return
    fi
    if [[ -L "$MERGED" ]]; then
        if ! rm "$MERGED"; then
            echo "agentwrap: failed to remove symlink at $MERGED."
            exit 1
        fi
    elif [[ -e "$MERGED" && ! -d "$MERGED" ]]; then
        echo "agentwrap: $MERGED exists and is not a directory."
        exit 1
    fi
    if ! mkdir -p "$MERGED"; then
        echo "agentwrap: failed to create $MERGED."
        exit 1
    fi
    if [[ -L "$MERGED" ]]; then
        echo "agentwrap: $MERGED is still a symlink; refusing to mount."
        exit 1
    fi
}

ensure_merged_symlink() {
    if is_mounted; then
        return
    fi
    if [[ -L "$MERGED" ]]; then
        return
    fi
    if [[ -d "$MERGED" ]]; then
        if rmdir "$MERGED" 2>/dev/null; then
            ln -s "$PROJECT_SRC" "$MERGED"
        else
            echo "Warning: $MERGED exists and is not empty; leaving as-is."
        fi
        return
    fi
    if [[ -e "$MERGED" ]]; then
        echo "Warning: $MERGED exists and is not a directory or symlink; leaving as-is."
        return
    fi
    ln -s "$PROJECT_SRC" "$MERGED"
}

acquire_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        local pid=""
        pid=$(awk -F= '$1 == "pid" {print $2}' "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$pid" && -d "/proc/$pid" ]]; then
            echo "agentwrap: lock file exists at $LOCK_FILE (pid $pid)."
            echo "agentwrap: project already wrapped; aborting."
            exit 1
        fi
        echo "agentwrap: stale lock file exists at $LOCK_FILE."
        echo "agentwrap: run with --unlock to clear it."
        exit 1
    fi

    {
        echo "pid=$$"
        echo "started=$(date -Iseconds)"
        echo "project=$PROJECT_SRC"
        echo "sandbox=$SANDBOX_ROOT"
    } > "$LOCK_FILE"
    chmod 600 "$LOCK_FILE"
    LOCK_HELD=1
}

release_lock() {
    if [[ -n "$LOCK_HELD" && -e "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi
}

cleanup() {
    if is_mounted; then
        fusermount -u "$MERGED" 2>/dev/null || umount "$MERGED"
    fi
    release_lock
    ensure_merged_symlink
}

if [[ -n "$UNLOCK_ONLY" ]]; then
    rm -f "$LOCK_FILE"
    ensure_merged_symlink
    echo "agentwrap: cleared lock at $LOCK_FILE."
    exit 0
fi

if [[ -e "$LOCK_FILE" ]]; then
    pid=""
    pid=$(awk -F= '$1 == "pid" {print $2}' "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$pid" && -d "/proc/$pid" ]]; then
        echo "agentwrap: lock file exists at $LOCK_FILE (pid $pid)."
        echo "agentwrap: project already wrapped; aborting."
        exit 1
    fi
    echo "agentwrap: stale lock file exists at $LOCK_FILE."
    echo "agentwrap: run with --unlock to clear it."
    exit 1
fi

# If requested, check for differences between sandbox view and real project and exit.
if [[ -n $CHECK_DIFF ]]; then
    echo "--- Checking sandbox view vs $PROJECT_SRC ---"
    MOUNTED=0
    if ! is_mounted; then
        ensure_merged_dir
        fuse-overlayfs -o lowerdir="$PROJECT_SRC",upperdir="$UPPER",workdir="$WORK" "$MERGED"
        MOUNTED=1
    fi

    if command -v rsync >/dev/null 2>&1; then
        RSYNC_EXCLUDES=()
        for pattern in "${SYNC_EXCLUDES[@]}"; do
            RSYNC_EXCLUDES+=(--exclude "$pattern")
        done
        DIFF_OUTPUT=$(rsync -a --delete --dry-run --itemize-changes "${RSYNC_EXCLUDES[@]}" "$MERGED"/ "$PROJECT_SRC"/)
        if [[ -z $DIFF_OUTPUT ]]; then
            echo "In sync."
        else
            echo "$DIFF_OUTPUT"
        fi
    else
        echo "rsync not found; cannot check diff."
    fi

    if [[ $MOUNTED -eq 1 ]]; then
        fusermount -u "$MERGED" 2>/dev/null || umount "$MERGED"
        ensure_merged_symlink
    fi
    exit 0
fi

# If requested, sync from the sandbox to the real project and exit.
if [[ -n $SYNC_REAL_FROM_SANDBOX ]]; then
    echo "--- Syncing sandbox view to $PROJECT_SRC ---"
    MOUNTED=0
    if ! is_mounted; then
        ensure_merged_dir
        fuse-overlayfs -o lowerdir="$PROJECT_SRC",upperdir="$UPPER",workdir="$WORK" "$MERGED"
        MOUNTED=1
    fi

    if command -v rsync >/dev/null 2>&1; then
        RSYNC_EXCLUDES=()
        for pattern in "${SYNC_EXCLUDES[@]}"; do
            RSYNC_EXCLUDES+=(--exclude "$pattern")
        done
        rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$MERGED"/ "$PROJECT_SRC"/
    else
        echo "rsync not found; cannot sync changes."
    fi

    if [[ $MOUNTED -eq 1 ]]; then
        fusermount -u "$MERGED" 2>/dev/null || umount "$MERGED"
        ensure_merged_symlink
    fi
    exit 0
fi

acquire_lock
trap cleanup EXIT INT TERM

# 1. Mount the OverlayFS (The "Undo" Button)
# Allows the agent to 'delete' files without actually touching your source.
ensure_merged_dir
fuse-overlayfs -o lowerdir="$PROJECT_SRC",upperdir="$UPPER",workdir="$WORK" "$MERGED"

echo "RESOLV" "$AGENT_RESOLV"

# 2. Build the Bubblewrap command
BWRAP_ARGS=(
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --tmpfs "$HOME"                       # Creates the "Ghost Home"
    --bind "$MERGED" "$TARGET_PATH" # Maps overlay to the real path
    --chdir "$TARGET_PATH"          # Start the agent where it expects to be    
    --ro-bind "$AGENT_CONFIG" "$HOME/.bashrc"
    --ro-bind "$LOCK_FILE" "$HOME/.agentwrap.lock"
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

if [[ -n $ENABLE_SSH ]] ; then
BWRAP_ARGS+=(
    --bind "$SSH_AUTH_SOCK" "/tmp/ssh-agent.sock"
    --setenv SSH_AUTH_SOCK "/tmp/ssh-agent.sock"
)
fi

# --- RECORDING SETUP ---
LOG_DIR="$SANDBOX_ROOT/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/session_$TIMESTAMP.log"

echo "--- Sandbox Active ---"
echo "Recording session to: $LOG_FILE"

# Execute via 'script'
# -q: quiet (don't log start/stop messages to the terminal)
# -c: command to run
# -f: flush output after every write (important if the agent crashes)
# --- COMMAND HANDLING ---
ENTRYPOINT="$SANDBOX_ROOT/entrypoint.sh"

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
echo "${BWRAP_ARGS[*]}"
# limit resources in the future
# prlimit --as=$MEM_LIMIT --nproc=1000
script -q -f -c "bwrap ${BWRAP_ARGS[*]} $HOME/entrypoint.sh" "$LOG_FILE"

# Optional: Clean up empty log files
[ ! -s "$LOG_FILE" ] && rm "$LOG_FILE"

# 4. Cleanup
cleanup
trap - EXIT INT TERM
echo "--- Sandbox Closed ---"
