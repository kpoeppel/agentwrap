#!/bin/bash
# Self-contained assertion tests for --clearenv, --setenv and the
# ~/.agent_sandboxes/config mount config file.
#
# Part A (dry-run): stubs out fuse-overlayfs and script(1) to capture the
#   generated bwrap command line and assert on it. Runs anywhere, even inside
#   an agentwrap sandbox.
# Part B (runtime): actually enters the sandbox and observes behavior.
#   Skipped when nested inside agentwrap or when bwrap/fuse are unavailable.
#
# Both parts use a throwaway fake HOME so the real user config, sandboxes and
# locks are never touched.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTWRAP="$(dirname "$SCRIPT_DIR")/agentwrap.sh"

TEST_ROOT=$(mktemp -d /tmp/agentwrap_envtest.XXXXXX)
FAKE_HOME="$TEST_ROOT/home"
PROJECT="$TEST_ROOT/project"
EXTRA_RO="$TEST_ROOT/extra_ro"
EXTRA_RW="$TEST_ROOT/extra_rw"
STUB_BIN="$TEST_ROOT/stub_bin"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

# The fake HOME must contain everything the default mount lists reference,
# since bwrap fails hard on missing bind sources.
mkdir -p "$FAKE_HOME/.agent_sandboxes" "$FAKE_HOME/.nvm" "$FAKE_HOME/.miniconda3" \
         "$FAKE_HOME/.local/share/opencode" "$FAKE_HOME/.cache" "$FAKE_HOME/.gemini" \
         "$FAKE_HOME/.codex" "$FAKE_HOME/.claude" "$FAKE_HOME/.pi" "$FAKE_HOME/.ssh"
touch "$FAKE_HOME/.gitconfig" "$FAKE_HOME/.ssh/known_hosts" "$FAKE_HOME/.claude.json"
echo "# test profile" > "$FAKE_HOME/.agent_sandboxes/sandbox_profile"

mkdir -p "$PROJECT" "$EXTRA_RO" "$EXTRA_RW"
echo "ro-content" > "$EXTRA_RO/marker.txt"

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
echo "=== Part A: bwrap command construction (dry-run) ==="

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
    # Returns only the generated bwrap command line.
    env -u AGENTWRAP_ACTIVE HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" \
        bash "$AGENTWRAP" "$@" 2>/dev/null | grep '^bwrap ' | tail -1
}

CMD=$(dry_run --clearenv "$PROJECT" -- true)
check "--clearenv is passed to bwrap, before built-in setenvs" \
    "^bwrap --clearenv --proc" "$CMD"

CMD=$(dry_run "$PROJECT" -- true)
check_absent "no --clearenv without the flag" "--clearenv" "$CMD"

CMD=$(dry_run --setenv FOO "bar baz" "$PROJECT" -- true)
check "--setenv reaches bwrap with spaces quoted intact" \
    '--setenv FOO bar\\ baz' "$CMD"

CMD=$(dry_run --allow-flatpak "$PROJECT" -- true)
check "--allow-flatpak mounts /sys read-only" "--ro-bind /sys /sys" "$CMD"
check "--allow-flatpak sets XDG_RUNTIME_DIR" "--setenv XDG_RUNTIME_DIR /run/user/$(id -u)" "$CMD"
check "--allow-flatpak sets DBUS_SESSION_BUS_ADDRESS" \
    "--setenv DBUS_SESSION_BUS_ADDRESS unix:path=/run/user/$(id -u)/bus" "$CMD"
if [[ -e "/run/user/$(id -u)/bus" ]]; then
    check "--allow-flatpak binds the session bus" \
        "--bind /run/user/$(id -u)/bus /run/user/$(id -u)/bus" "$CMD"
else
    echo "SKIP: session bus bind check (/run/user/$(id -u)/bus not present on this host)"
fi

cat > "$FAKE_HOME/.agent_sandboxes/config" <<EOF
SANDBOX_RO_MOUNTS=("$EXTRA_RO:$FAKE_HOME/mnt_ro")
SANDBOX_RW_MOUNTS=("$EXTRA_RW:$FAKE_HOME/mnt_rw")
SANDBOX_NO_MOUNTS=(.gemini)
EOF
CMD=$(dry_run "$PROJECT" -- true)
check "config file adds RO mount" "--ro-bind $EXTRA_RO $FAKE_HOME/mnt_ro" "$CMD"
check "config file adds RW mount" "--bind $EXTRA_RW $FAKE_HOME/mnt_rw" "$CMD"
check_absent "config SANDBOX_NO_MOUNTS skips default .gemini mount" \
    "$FAKE_HOME/.gemini" "$CMD"

CMD=$(dry_run --no-mount mnt_ro "$PROJECT" -- true)
check_absent "command-line --no-mount skips a config entry" \
    "$FAKE_HOME/mnt_ro" "$CMD"
rm -f "$FAKE_HOME/.agent_sandboxes/config"

OUT=$(HOME="$FAKE_HOME" bash "$AGENTWRAP" --setenv FOO 2>&1)
check "--setenv without VALUE errors out" "requires VAR and VALUE" "$OUT"

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

    OUT=$(SECRET_LEAK_CANARY=supersecret run_sandboxed "$PROJECT" -- env)
    check "host env inherited by default (documented behavior)" \
        "^SECRET_LEAK_CANARY=supersecret$" "$OUT"

    OUT=$(SECRET_LEAK_CANARY=supersecret run_sandboxed --clearenv "$PROJECT" -- env)
    check_absent "--clearenv strips host vars" "SECRET_LEAK_CANARY" "$OUT"
    check "--clearenv keeps built-in PATH" "^PATH=" "$OUT"
    check "--clearenv keeps built-in HOME" "^HOME=$FAKE_HOME$" "$OUT"

    OUT=$(run_sandboxed --setenv FOO "bar baz" "$PROJECT" -- env)
    check "--setenv sets variable with spaces intact" "^FOO=bar baz$" "$OUT"

    OUT=$(run_sandboxed --clearenv --setenv ONLYME yes "$PROJECT" -- env)
    check "--setenv works together with --clearenv" "^ONLYME=yes$" "$OUT"

    cat > "$FAKE_HOME/.agent_sandboxes/config" <<EOF
SANDBOX_RO_MOUNTS=("$EXTRA_RO:$FAKE_HOME/mnt_ro")
SANDBOX_RW_MOUNTS=("$EXTRA_RW:$FAKE_HOME/mnt_rw")
SANDBOX_NO_MOUNTS=(.gemini)
EOF
    OUT=$(run_sandboxed "$PROJECT" -- bash -c '
        cat "$HOME/mnt_ro/marker.txt" 2>&1
        (echo w > "$HOME/mnt_ro/write_attempt") 2>/dev/null && echo RO_WRITABLE || echo RO_BLOCKED
        (echo w > "$HOME/mnt_rw/new.txt") 2>/dev/null && echo RW_OK || echo RW_BLOCKED
        [ -e "$HOME/.gemini" ] && echo GEMINI_PRESENT || echo GEMINI_SKIPPED
    ')
    check "config RO mount is visible at mapped dest" "^ro-content$" "$OUT"
    check "config RO mount rejects writes" "^RO_BLOCKED$" "$OUT"
    check "config RW mount accepts writes" "^RW_OK$" "$OUT"
    check "config SANDBOX_NO_MOUNTS skips a default mount" "^GEMINI_SKIPPED$" "$OUT"

    if [ -f "$EXTRA_RW/new.txt" ]; then
        echo "PASS: config RW mount write reached the host directory"
        PASS=$((PASS + 1))
    else
        echo "FAIL: config RW mount write did not reach the host directory"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$FAKE_HOME/.agent_sandboxes/config"
fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
