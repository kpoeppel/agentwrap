#!/bin/bash
# Test flatpak access inside the sandbox
# Run this script INSIDE an agentwrap session to see what's available

echo "=== Flatpak Access Test ==="
echo ""

UID_NUM=$(id -u)

echo "--- flatpak runtime dirs under /run/user/$UID_NUM ---"
for item in .flatpak .flatpak-cache .flatpak-helper bus doc; do
    ls -ld "/run/user/$UID_NUM/$item" 2>&1
done
echo ""

echo "--- /sys mounted ---"
ls /sys 2>&1 | head -3
echo ""

echo "--- environment ---"
echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-<unset>}"
echo ""

echo "--- D-Bus session bus ping ---"
dbus-send --session --print-reply --dest=org.freedesktop.DBus \
    / org.freedesktop.DBus.ListNames 2>&1 | head -5
echo ""

echo "--- flatpak binary ---"
which flatpak 2>&1
flatpak --version 2>&1
echo ""

echo "--- flatpak list ---"
# Note: listing installed apps also needs ~/.local/share/flatpak (user installs,
# covered by the default ~/.local RO mount) and/or /var/lib/flatpak (system
# installs, shadowed by the apptainer --tmpfs /var if both flags are combined).
flatpak list 2>&1 | head -10
echo ""

echo "--- document portal (doc) ---"
ls "/run/user/$UID_NUM/doc" 2>&1 | head -5
echo ""

echo "=== END Flatpak Test ==="
