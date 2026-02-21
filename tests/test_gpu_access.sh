#!/bin/bash
# Test GPU access inside the sandbox
# Run this script INSIDE an agentwrap session to see what's available

echo "=== GPU Access Test ==="
echo ""

echo "--- /dev/nvidia* devices ---"
ls -la /dev/nvidia* 2>&1
echo ""

echo "--- /dev/dri/* devices ---"
ls -la /dev/dri/ 2>&1
echo ""

echo "--- /dev/nvidia-caps/ ---"
ls -la /dev/nvidia-caps/ 2>&1
echo ""

echo "--- nvidia-smi ---"
nvidia-smi 2>&1 | head -20
echo ""

echo "--- NVIDIA libraries accessible ---"
ldconfig -p 2>/dev/null | grep -i nvidia | head -5
echo ""

echo "--- CUDA libraries accessible ---"
ldconfig -p 2>/dev/null | grep -i cuda | head -5
echo ""

echo "--- Python torch GPU test ---"
python3 -c "import torch; print('CUDA available:', torch.cuda.is_available()); print('Device count:', torch.cuda.device_count())" 2>&1
echo ""

echo "=== END GPU Test ==="
