#!/bin/bash
# Test Apptainer access inside the sandbox
# Run this script INSIDE an agentwrap session to see what's available

echo "=== Apptainer Access Test ==="
echo ""

echo "--- apptainer binary ---"
which apptainer 2>&1
apptainer --version 2>&1
echo ""

echo "--- /dev/fuse device ---"
ls -la /dev/fuse 2>&1
echo ""

echo "--- apptainer libexec helpers ---"
ls -la /usr/libexec/apptainer/bin/ 2>&1
echo ""

echo "--- apptainer exec test (simple) ---"
# Try running a simple command in a docker container image
apptainer exec docker://alpine:latest cat /etc/os-release 2>&1
echo ""

echo "--- user namespace check ---"
cat /proc/self/uid_map 2>&1
echo ""

echo "--- /proc/self/ns/ ---"
ls -la /proc/self/ns/ 2>&1
echo ""

echo "--- kernel.unprivileged_userns_clone ---"
cat /proc/sys/kernel/unprivileged_userns_clone 2>&1
echo ""

echo "=== END Apptainer Test ==="
