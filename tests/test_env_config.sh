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

# The fake HOME deliberately omits two paths from the generated config template
# ($HOME/.pi and $HOME/.miniconda3) to prove they are skipped instead of
# failing the sandbox, which is what bwrap does on a missing bind source.
mkdir -p "$FAKE_HOME/.agent_sandboxes" "$FAKE_HOME/.nvm" \
         "$FAKE_HOME/.local/share/opencode" "$FAKE_HOME/.cache" "$FAKE_HOME/.gemini" \
         "$FAKE_HOME/.codex" "$FAKE_HOME/.claude" "$FAKE_HOME/.ssh"
touch "$FAKE_HOME/.gitconfig" "$FAKE_HOME/.ssh/known_hosts" "$FAKE_HOME/.claude.json"
echo "# test profile" > "$FAKE_HOME/.agent_sandboxes/sandbox_profile"
MOUNT_CONFIG="$FAKE_HOME/.agent_sandboxes/config"

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

dry_run_all() {
    # Returns everything the run printed, stderr included.
    env -u AGENTWRAP_ACTIVE HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" \
        bash "$AGENTWRAP" "$@" 2>&1
}

# --- mount config bootstrap (must run before anything creates the config) ---
[ -e "$MOUNT_CONFIG" ] && { echo "FAIL: test setup left a config behind"; exit 1; }

OUT=$(dry_run_all "$PROJECT" -- true)
check "first run reports writing the default config" \
    "wrote default mount config to $MOUNT_CONFIG" "$OUT"
if [ -f "$MOUNT_CONFIG" ]; then
    echo "PASS: first run created $MOUNT_CONFIG"
    PASS=$((PASS + 1))
else
    echo "FAIL: first run did not create $MOUNT_CONFIG"
    FAIL=$((FAIL + 1))
fi
check "generated config carries the version marker" \
    "^# agentwrap config v1$" "$(cat "$MOUNT_CONFIG")"
check "generated config lists the agent state dirs" \
    '"\$HOME/.claude"' "$(cat "$MOUNT_CONFIG")"
check_absent "generated config leaves system paths to the script" \
    '"/usr"' "$(cat "$MOUNT_CONFIG")"

CMD=$(dry_run "$PROJECT" -- true)
check "built-in system mounts are applied" "--ro-bind /usr /usr" "$CMD"
check "generated config RO entry is applied" \
    "--ro-bind $FAKE_HOME/.nvm $FAKE_HOME/.nvm" "$CMD"
check "generated config RW entry is applied" \
    "--bind $FAKE_HOME/.claude $FAKE_HOME/.claude" "$CMD"
check "bash history is bound from the session sandbox" \
    "--bind $FAKE_HOME/.agent_sandboxes/.*bash_history $FAKE_HOME/.bash_history" "$CMD"

# Missing sources must not reach bwrap (it fails hard on them).
OUT=$(dry_run_all "$PROJECT" -- true)
check "missing config source is reported" \
    "skipping read-write mount, no such path: $FAKE_HOME/.pi" "$OUT"
check_absent "missing config source is not passed to bwrap" \
    "--bind $FAKE_HOME/.pi" "$CMD"
check_absent "missing RO config source is not passed to bwrap" \
    "--ro-bind $FAKE_HOME/.miniconda3" "$CMD"

OUT=$(dry_run_all --print-config)
check "--print-config prints the template" "^SANDBOX_RW_MOUNTS=(" "$OUT"
check_absent "--print-config needs no project path" "no project path specified" "$OUT"

# A config predating the version marker gets a migration hint.
cp "$MOUNT_CONFIG" "$TEST_ROOT/config.generated"
grep -v '^# agentwrap config v' "$TEST_ROOT/config.generated" > "$MOUNT_CONFIG"
OUT=$(dry_run_all "$PROJECT" -- true)
check "config without version marker warns about the changed semantics" \
    "has no version marker" "$OUT"
cp "$TEST_ROOT/config.generated" "$MOUNT_CONFIG"
OUT=$(dry_run_all "$PROJECT" -- true)
check_absent "marked config does not warn" "has no version marker" "$OUT"

OUT=$(dry_run_all --mount-ro "$TEST_ROOT/does_not_exist" "$PROJECT" -- true)
check "--mount-ro with a missing path is a hard error" \
    "no such path: $TEST_ROOT/does_not_exist" "$OUT"
check_absent "--mount-ro with a missing path does not build a bwrap command" \
    "^bwrap " "$OUT"

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

cat > "$MOUNT_CONFIG" <<EOF
# agentwrap config v1
SANDBOX_RO_MOUNTS=("$EXTRA_RO:$FAKE_HOME/mnt_ro")
SANDBOX_RW_MOUNTS=("$EXTRA_RW:$FAKE_HOME/mnt_rw" "\$HOME/.gemini")
SANDBOX_NO_MOUNTS=(.gemini)
EOF
CMD=$(dry_run "$PROJECT" -- true)
check "config file adds RO mount" "--ro-bind $EXTRA_RO $FAKE_HOME/mnt_ro" "$CMD"
check "config file adds RW mount" "--bind $EXTRA_RW $FAKE_HOME/mnt_rw" "$CMD"
check "config replaces rather than extends the \$HOME defaults" \
    "^bwrap .*--ro-bind /usr /usr" "$CMD"
check_absent "config without .claude drops the default .claude mount" \
    "--bind $FAKE_HOME/.claude " "$CMD"
check_absent "config SANDBOX_NO_MOUNTS skips a config entry" \
    "--bind $FAKE_HOME/.gemini" "$CMD"

CMD=$(dry_run --no-mount mnt_ro "$PROJECT" -- true)
check_absent "command-line --no-mount skips a config entry" \
    "$FAKE_HOME/mnt_ro" "$CMD"

CMD=$(dry_run --mount-rw "$EXTRA_RW:$FAKE_HOME/mnt_rw" "$PROJECT" -- true)
check "command-line mounts are applied after config ones (last bind wins)" \
    "--bind $EXTRA_RW $FAKE_HOME/mnt_rw .*--bind $EXTRA_RW $FAKE_HOME/mnt_rw" "$CMD"

rm -f "$MOUNT_CONFIG"

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

    # The generated config still applies here; $HOME/.pi and $HOME/.miniconda3
    # are missing from the fake home, so this also proves the sandbox starts
    # despite them instead of dying in bwrap.
    OUT=$(run_sandboxed "$PROJECT" -- bash -c '
        [ -e "$HOME/.claude" ] && echo CLAUDE_PRESENT || echo CLAUDE_MISSING
        [ -e "$HOME/.pi" ] && echo PI_PRESENT || echo PI_MISSING
    ')
    check "generated config mounts agent state" "^CLAUDE_PRESENT$" "$OUT"
    check "missing config entry is skipped, sandbox still starts" "^PI_MISSING$" "$OUT"

    cat > "$MOUNT_CONFIG" <<EOF
# agentwrap config v1
SANDBOX_RO_MOUNTS=("$EXTRA_RO:$FAKE_HOME/mnt_ro")
SANDBOX_RW_MOUNTS=("$EXTRA_RW:$FAKE_HOME/mnt_rw" "\$HOME/.gemini")
SANDBOX_NO_MOUNTS=(.gemini)
EOF
    OUT=$(run_sandboxed "$PROJECT" -- bash -c '
        cat "$HOME/mnt_ro/marker.txt" 2>&1
        (echo w > "$HOME/mnt_ro/write_attempt") 2>/dev/null && echo RO_WRITABLE || echo RO_BLOCKED
        (echo w > "$HOME/mnt_rw/new.txt") 2>/dev/null && echo RW_OK || echo RW_BLOCKED
        [ -e "$HOME/.gemini" ] && echo GEMINI_PRESENT || echo GEMINI_SKIPPED
        [ -e "$HOME/.claude" ] && echo CLAUDE_PRESENT || echo CLAUDE_MISSING
    ')
    check "config RO mount is visible at mapped dest" "^ro-content$" "$OUT"
    check "config RO mount rejects writes" "^RO_BLOCKED$" "$OUT"
    check "config RW mount accepts writes" "^RW_OK$" "$OUT"
    check "config SANDBOX_NO_MOUNTS skips a config entry" "^GEMINI_SKIPPED$" "$OUT"
    check "config replaces the built-in \$HOME defaults" "^CLAUDE_MISSING$" "$OUT"

    if [ -f "$EXTRA_RW/new.txt" ]; then
        echo "PASS: config RW mount write reached the host directory"
        PASS=$((PASS + 1))
    else
        echo "FAIL: config RW mount write did not reach the host directory"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$MOUNT_CONFIG"
fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
