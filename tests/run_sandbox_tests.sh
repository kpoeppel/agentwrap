#!/bin/bash
# Run GPU, Apptainer and Flatpak tests both outside and inside the sandbox,
# comparing default (restricted) vs. --allow-gpu / --allow-apptainer /
# --allow-flatpak, plus self-contained env/config assertion tests.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AGENTWRAP="$PROJECT_DIR/agentwrap.sh"
TEST_PROJECT="/tmp/agentwrap_test_project"

mkdir -p "$TEST_PROJECT"

GPU_TEST='
echo "=== GPU Access Test ==="
echo "--- /dev/nvidia* devices ---"
ls -la /dev/nvidia* 2>&1
echo "--- /dev/dri/* devices ---"
ls -la /dev/dri/ 2>&1
echo "--- /dev/nvidia-caps/ ---"
ls -la /dev/nvidia-caps/ 2>&1
echo "--- nvidia-smi ---"
nvidia-smi 2>&1 | head -5
echo "--- Python torch GPU test ---"
python3 -c "import torch; print(\"CUDA available:\", torch.cuda.is_available()); print(\"Device count:\", torch.cuda.device_count())" 2>&1
echo "=== END GPU Test ==="
'

APPTAINER_TEST='
echo "=== Apptainer Access Test ==="
echo "--- /dev/fuse device ---"
ls -la /dev/fuse 2>&1
echo "--- /var/lib/apptainer/mnt/session ---"
ls -la /var/lib/apptainer/mnt/session 2>&1
echo "--- user namespace map ---"
cat /proc/self/uid_map 2>&1
echo "--- apptainer exec test ---"
apptainer exec docker://alpine:latest cat /etc/os-release 2>&1 | head -6
echo "=== END Apptainer Test ==="
'

FLATPAK_TEST='
echo "=== Flatpak Access Test ==="
UID_NUM=$(id -u)
echo "--- runtime dirs under /run/user/$UID_NUM ---"
for item in .flatpak .flatpak-cache .flatpak-helper bus doc; do
    ls -ld "/run/user/$UID_NUM/$item" 2>&1
done
echo "--- /sys ---"
ls /sys 2>&1 | head -3
echo "--- env ---"
echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-<unset>}"
echo "--- dbus session ping ---"
dbus-send --session --print-reply --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames 2>&1 | head -5
echo "--- flatpak ---"
flatpak --version 2>&1
flatpak list 2>&1 | head -5
echo "=== END Flatpak Test ==="
'

sep() { echo ""; echo "============================================"; echo "  $*"; echo "============================================"; echo ""; }

sep "BASELINE: outside sandbox"
eval "$GPU_TEST"
echo ""
eval "$APPTAINER_TEST"
echo ""
eval "$FLATPAK_TEST"

sep "SANDBOX (default — no GPU/Apptainer flags)"
bash "$AGENTWRAP" "$TEST_PROJECT" -- bash -c "$GPU_TEST"
bash "$AGENTWRAP" --unlock "$TEST_PROJECT" 2>/dev/null
bash "$AGENTWRAP" "$TEST_PROJECT" -- bash -c "$APPTAINER_TEST"
bash "$AGENTWRAP" --unlock "$TEST_PROJECT" 2>/dev/null
bash "$AGENTWRAP" "$TEST_PROJECT" -- bash -c "$FLATPAK_TEST"
bash "$AGENTWRAP" --unlock "$TEST_PROJECT" 2>/dev/null

sep "SANDBOX with --allow-gpu"
bash "$AGENTWRAP" --allow-gpu "$TEST_PROJECT" -- bash -c "$GPU_TEST"
bash "$AGENTWRAP" --unlock "$TEST_PROJECT" 2>/dev/null

sep "SANDBOX with --allow-apptainer"
bash "$AGENTWRAP" --allow-apptainer "$TEST_PROJECT" -- bash -c "$APPTAINER_TEST"
bash "$AGENTWRAP" --unlock "$TEST_PROJECT" 2>/dev/null

sep "SANDBOX with --allow-flatpak"
bash "$AGENTWRAP" --allow-flatpak "$TEST_PROJECT" -- bash -c "$FLATPAK_TEST"
bash "$AGENTWRAP" --unlock "$TEST_PROJECT" 2>/dev/null

sep "ENV / CONFIG ASSERTION TESTS"
bash "$SCRIPT_DIR/test_env_config.sh"

sep "CLEANUP"
rm -rf "$TEST_PROJECT"
echo "Done."
