#!/bin/bash
# Assertion tests for the secure-by-default network/X11/DBus posture:
#   * no --share-net unless --allow-net (or --allow-ssh) is given
#   * host session env (DISPLAY/DBUS/XDG/SSH_AUTH_SOCK) is unset by default
#   * keyring files are masked unless --allow-keyring/--allow-dbus is given
#   * --allow-net / --allow-x11 / --allow-dbus re-add only what they name
#
# Part A (dry-run): stubs fuse-overlayfs and script(1) to capture the generated
#   bwrap command line. Works anywhere, even inside an agentwrap sandbox.
# Part B (runtime): enters the sandbox to observe behavior. Skipped when nested
#   inside agentwrap or when bwrap/fuse are unavailable.
#
# Uses a throwaway fake HOME so the real config, sandboxes and locks stay untouched.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTWRAP="$(dirname "$SCRIPT_DIR")/agentwrap.sh"

TEST_ROOT=$(mktemp -d /tmp/agentwrap_isotest.XXXXXX)
FAKE_HOME="$TEST_ROOT/home"
PROJECT="$TEST_ROOT/project"
STUB_BIN="$TEST_ROOT/stub_bin"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

# Populate the fake home with the paths the generated config references, plus a
# keyring dir so the default mask has something to hide.
mkdir -p "$FAKE_HOME/.agent_sandboxes" "$FAKE_HOME/.nvm" \
         "$FAKE_HOME/.local/share/opencode" "$FAKE_HOME/.local/share/keyrings" \
         "$FAKE_HOME/.cache" "$FAKE_HOME/.gemini" "$FAKE_HOME/.codex" \
         "$FAKE_HOME/.claude" "$FAKE_HOME/.ssh"
echo "secret" > "$FAKE_HOME/.local/share/keyrings/login.keyring"
touch "$FAKE_HOME/.gitconfig" "$FAKE_HOME/.ssh/known_hosts" "$FAKE_HOME/.claude.json"
echo "# test profile" > "$FAKE_HOME/.agent_sandboxes/sandbox_profile"

mkdir -p "$PROJECT"

PASS=0
FAIL=0

check() {
    local name="$1" pattern="$2" output="$3"
    if grep -q -- "$pattern" <<< "$output"; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name (expected match: $pattern)"
        sed 's/^/    /' <<< "$output" | tail -20
        FAIL=$((FAIL + 1))
    fi
}

check_absent() {
    local name="$1" pattern="$2" output="$3"
    if grep -q -- "$pattern" <<< "$output"; then
        echo "FAIL: $name (unexpected match: $pattern)"
        grep -- "$pattern" <<< "$output" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $name"
        PASS=$((PASS + 1))
    fi
}

# =========================================================================
# Part A: dry-run — capture the generated bwrap command without executing it
# =========================================================================
echo "=== Part A: secure-defaults command construction (dry-run) ==="

mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/fuse-overlayfs" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$STUB_BIN/script" <<'EOF'
#!/bin/bash
# Stub for util-linux script(1): print the -c command instead of executing it.
while [ $# -gt 0 ]; do
    case "$1" in
        -c) printf '%s\n' "$2"; shift 2 ;;
        *) shift ;;
    esac
done
EOF
chmod +x "$STUB_BIN/fuse-overlayfs" "$STUB_BIN/script"

dry_run() {
    env -u AGENTWRAP_ACTIVE HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" \
        bash "$AGENTWRAP" "$@" 2>/dev/null | grep '^bwrap ' | tail -1
}

dry_run_all() {
    env -u AGENTWRAP_ACTIVE HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" \
        bash "$AGENTWRAP" "$@" 2>&1
}

KEYRING_MASK="--tmpfs $FAKE_HOME/.local/share/keyrings"

# --- default: isolated network, scrubbed env, masked keyring ---
CMD=$(dry_run "$PROJECT" -- true)
check "default keeps the isolated network namespace" "--unshare-all" "$CMD"
check_absent "default does not share the host network namespace" "--share-net" "$CMD"
check "default unsets DISPLAY" "--unsetenv DISPLAY" "$CMD"
check "default unsets DBUS_SESSION_BUS_ADDRESS" "--unsetenv DBUS_SESSION_BUS_ADDRESS" "$CMD"
check "default unsets XDG_RUNTIME_DIR" "--unsetenv XDG_RUNTIME_DIR" "$CMD"
check "default unsets SSH_AUTH_SOCK" "--unsetenv SSH_AUTH_SOCK" "$CMD"
check "default masks the on-disk keyring" "$KEYRING_MASK" "$CMD"
check_absent "default does not set DISPLAY" "--setenv DISPLAY" "$CMD"

# --- --allow-net restores the host network namespace ---
CMD=$(dry_run --allow-net "$PROJECT" -- true)
check "--allow-net shares the host network namespace" "--share-net" "$CMD"
check "--allow-net still masks the keyring" "$KEYRING_MASK" "$CMD"

CMD=$(dry_run --allow-net=host "$PROJECT" -- true)
check "--allow-net=host shares the host network namespace" "--share-net" "$CMD"

# --- --allow-net=isolated wraps bwrap in rootlesskit + slirp4netns ---
OUT=$(dry_run_all --allow-net=isolated "$PROJECT" -- true)
check "--allow-net=isolated uses rootlesskit + slirp4netns" \
    "rootlesskit --net=slirp4netns" "$OUT"
check "--allow-net=isolated blocks host loopback" "--disable-host-loopback" "$OUT"
check "--allow-net=isolated retains a network namespace" "--share-net" "$OUT"

OUT=$(dry_run_all --allow-net=bogus "$PROJECT" -- true)
check "--allow-net rejects an unknown mode" "expects 'host' or 'isolated'" "$OUT"
check_absent "--allow-net with a bad mode builds no wrapper" "rootlesskit" "$OUT"

# --- --allow-ssh implies network (SSH needs real egress) ---
# The wrapper refuses --allow-ssh without SSH_AUTH_SOCK, so provide a fake agent
# socket for the dry run.
FAKE_AGENT_SOCK="$TEST_ROOT/agent.sock"
python3 -c "import socket,os; os.path.exists('$FAKE_AGENT_SOCK') and os.unlink('$FAKE_AGENT_SOCK'); s=socket.socket(socket.AF_UNIX); s.bind('$FAKE_AGENT_SOCK'); s.listen(1)" &
FAKE_AGENT_PID=$!
sleep 0.2
CMD=$(SSH_AUTH_SOCK="$FAKE_AGENT_SOCK" env -u AGENTWRAP_ACTIVE HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" \
    bash "$AGENTWRAP" --allow-ssh example.com "$PROJECT" -- true 2>/dev/null | grep '^bwrap ' | tail -1)
kill "$FAKE_AGENT_PID" 2>/dev/null
wait "$FAKE_AGENT_PID" 2>/dev/null
check "--allow-ssh enables the host network namespace" "--share-net" "$CMD"

# --- --allow-keyring opts out of the mask ---
CMD=$(dry_run --allow-keyring "$PROJECT" -- true)
check_absent "--allow-keyring removes the keyring mask" "$KEYRING_MASK" "$CMD"
check_absent "--allow-keyring alone does not share the network" "--share-net" "$CMD"

# --- --allow-dbus exposes the bus and unmasks the keyring (secret service) ---
CMD=$(dry_run --allow-dbus "$PROJECT" -- true)
check "--allow-dbus sets DBUS_SESSION_BUS_ADDRESS" \
    "--setenv DBUS_SESSION_BUS_ADDRESS unix:path=/run/user/$(id -u)/bus" "$CMD"
check "--allow-dbus sets XDG_RUNTIME_DIR" "--setenv XDG_RUNTIME_DIR /run/user/$(id -u)" "$CMD"
check_absent "--allow-dbus unmasks the keyring (secret service reachable)" "$KEYRING_MASK" "$CMD"
if [[ -e "/run/user/$(id -u)/bus" ]]; then
    check "--allow-dbus binds the session bus" \
        "--bind /run/user/$(id -u)/bus /run/user/$(id -u)/bus" "$CMD"
else
    echo "SKIP: session bus bind check (/run/user/$(id -u)/bus not present on this host)"
fi
check_absent "--allow-dbus alone does not share the network" "--share-net" "$CMD"

# --- --allow-flatpak also exposes the session bus, hence no keyring mask ---
CMD=$(dry_run --allow-flatpak "$PROJECT" -- true)
check_absent "--allow-flatpak unmasks the keyring (bus reachable)" "$KEYRING_MASK" "$CMD"

# --- --allow-x11=real hands over the host display (socket bind is filesystem-based) ---
CMD=$(dry_run --allow-x11=real "$PROJECT" -- true)
check "--allow-x11=real sets DISPLAY" "--setenv DISPLAY" "$CMD"
if [[ -d /tmp/.X11-unix ]]; then
    check "--allow-x11=real binds the host X11 socket dir" \
        "--ro-bind /tmp/.X11-unix /tmp/.X11-unix" "$CMD"
else
    echo "SKIP: X11 socket dir bind check (/tmp/.X11-unix not present on this host)"
fi
CMD=$(dry_run --allow-x11 "$PROJECT" -- true)
check "--allow-x11 defaults to real" "--setenv DISPLAY" "$CMD"

# --- --allow-x11=virtual: private Xvfb, single socket only ---
if command -v Xvfb >/dev/null 2>&1; then
    CMD=$(dry_run --allow-x11=virtual "$PROJECT" -- true)
    check "--allow-x11=virtual sets a DISPLAY" "--setenv DISPLAY :" "$CMD"
    check "--allow-x11=virtual binds a single X socket" "--ro-bind /tmp/.X11-unix/X" "$CMD"
else
    OUT=$(dry_run_all --allow-x11=virtual "$PROJECT" -- true)
    check "--allow-x11=virtual without Xvfb errors clearly" "needs Xvfb" "$OUT"
fi

# --- invalid mode rejected ---
OUT=$(dry_run_all --allow-x11=bogus "$PROJECT" -- true)
check "--allow-x11 rejects an unknown mode" "expects 'real' or 'virtual'" "$OUT"
check_absent "--allow-x11 with a bad mode builds no command" "^bwrap " "$OUT"

# --- no keyring dir on the host => no mask is injected ---
mv "$FAKE_HOME/.local/share/keyrings" "$TEST_ROOT/keyrings_saved"
CMD=$(dry_run "$PROJECT" -- true)
check_absent "missing keyring dir produces no mask" "$KEYRING_MASK" "$CMD"
mv "$TEST_ROOT/keyrings_saved" "$FAKE_HOME/.local/share/keyrings"

# =========================================================================
# Part B: runtime — enter the sandbox for real and observe behavior
# =========================================================================
echo ""
echo "=== Part B: runtime behavior ==="

SKIP_REASON=""
if [[ -n "${AGENTWRAP_ACTIVE:-}" ]]; then
    SKIP_REASON="running inside an agentwrap sandbox (nesting refused)"
elif ! command -v bwrap >/dev/null 2>&1; then
    SKIP_REASON="bwrap not found"
elif ! command -v fuse-overlayfs >/dev/null 2>&1; then
    SKIP_REASON="fuse-overlayfs not found"
elif [[ ! -e /dev/fuse ]]; then
    SKIP_REASON="/dev/fuse not available"
fi

if [[ -n "$SKIP_REASON" ]]; then
    echo "SKIP: $SKIP_REASON — run this test directly on the host."
else
    run_sandboxed() {
        HOME="$FAKE_HOME" bash "$AGENTWRAP" "$@" 2>/dev/null | tr -d '\r'
        HOME="$FAKE_HOME" bash "$AGENTWRAP" --unlock "$PROJECT" >/dev/null 2>&1
    }

    PROBE='
        echo "DISPLAY=${DISPLAY:-unset}"
        echo "DBUS=${DBUS_SESSION_BUS_ADDRESS:-unset}"
        echo "XDG=${XDG_RUNTIME_DIR:-unset}"
        echo "SSH=${SSH_AUTH_SOCK:-unset}"
        echo "KEYRING_ENTRIES=$(ls -A "$HOME/.local/share/keyrings" 2>/dev/null | wc -l)"
    '

    OUT=$(run_sandboxed "$PROJECT" -- bash -c "$PROBE")
    check "host DISPLAY does not leak in" "^DISPLAY=unset$" "$OUT"
    check "host DBUS_SESSION_BUS_ADDRESS does not leak in" "^DBUS=unset$" "$OUT"
    check "host XDG_RUNTIME_DIR does not leak in" "^XDG=unset$" "$OUT"
    check "host SSH_AUTH_SOCK does not leak in" "^SSH=unset$" "$OUT"
    check "keyring files are masked by default" "^KEYRING_ENTRIES=0$" "$OUT"

    OUT=$(run_sandboxed --allow-keyring "$PROJECT" -- bash -c "$PROBE")
    check "--allow-keyring exposes the keyring files" "^KEYRING_ENTRIES=1$" "$OUT"

    # Network namespace isolation is observable via the interface list: the
    # default private netns has only loopback; a slirp NAT adds tap0.
    IFACES_PROBE='grep -oE "^ *[a-zA-Z0-9_.@-]+:" /proc/net/dev | tr -d " :" | tr "\n" " "'
    OUT=$(run_sandboxed "$PROJECT" -- bash -c "$IFACES_PROBE")
    check "default network namespace exposes only loopback" "^lo $" "$OUT"

    if command -v rootlesskit >/dev/null 2>&1 && \
       command -v slirp4netns >/dev/null 2>&1 && [[ -e /dev/net/tun ]]; then
        OUT=$(run_sandboxed --allow-net=isolated "$PROJECT" -- bash -c "$IFACES_PROBE")
        check "--allow-net=isolated creates a slirp tap interface" "^lo tap0 $" "$OUT"
    else
        echo "SKIP: --allow-net=isolated runtime check (needs rootlesskit, slirp4netns and /dev/net/tun)"
    fi
fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
