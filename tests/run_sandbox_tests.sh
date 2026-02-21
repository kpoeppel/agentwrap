#!/bin/bash
# Run GPU and Apptainer tests both outside and inside the sandbox,
# comparing default (restricted) vs. --allow-gpu / --allow-apptainer.

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

sep() { echo ""; echo "============================================"; echo "  $*"; echo "============================================"; echo ""; }

sep "BASELINE: outside sandbox"
eval "$GPU_TEST"
echo ""
eval "$APPTAINER_TEST"

sep "SANDBOX (default — no GPU/Apptainer flags)"
bash "$AGENTWRAP" "$TEST_PROJECT" -- bash -c "$GPU_TEST"
bash "$AGENTWRAP" --unlock "$TEST_PROJECT" 2>/dev/null
bash "$AGENTWRAP" "$TEST_PROJECT" -- bash -c "$APPTAINER_TEST"
bash "$AGENTWRAP" --unlock "$TEST_PROJECT" 2>/dev/null

sep "SANDBOX with --allow-gpu"
bash "$AGENTWRAP" --allow-gpu "$TEST_PROJECT" -- bash -c "$GPU_TEST"
bash "$AGENTWRAP" --unlock "$TEST_PROJECT" 2>/dev/null

sep "SANDBOX with --allow-apptainer"
bash "$AGENTWRAP" --allow-apptainer "$TEST_PROJECT" -- bash -c "$APPTAINER_TEST"
bash "$AGENTWRAP" --unlock "$TEST_PROJECT" 2>/dev/null

sep "CLEANUP"
rm -rf "$TEST_PROJECT"
echo "Done."
