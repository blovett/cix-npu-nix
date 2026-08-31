#!/usr/bin/env bash
# Load the freshly built aipu.ko, probe CIXH4000:00, report, then unload.
# Run after a reboot (a failed probe can leave the module wedged; this
# kernel has no MODULE_FORCE_UNLOAD).
set -u

NPU=/sys/bus/platform/devices/CIXH4000:00

if [ -n "${1:-}" ]; then
	KO=$1
else
	nix build .#aipu -o result-aipu
	KO=result-aipu/lib/modules/$(uname -r)/extra/aipu.ko
fi

echo "== module: $KO"
[ -f "$KO" ] || { echo "not found - run: nix build .#aipu"; exit 1; }
modinfo "$KO" | grep -E '^(vermagic|name)'
echo "running kernel: $(uname -r)"

if lsmod | grep -q '^aipu'; then
	echo "!! aipu already loaded (state: $(cat /sys/module/aipu/initstate 2>/dev/null)). Reboot first."
	exit 1
fi

echo "== before: driver bound?"; readlink "$NPU/driver" || echo "  (none)"

sudo dmesg -C
echo "== insmod"
sudo insmod "$KO"; rc=$?
sleep 1
echo "== dmesg"; sudo dmesg

echo; echo "== after"
echo "insmod rc: $rc"
echo "driver bound: $(readlink "$NPU/driver" 2>/dev/null || echo none)"
echo "module state: $(cat /sys/module/aipu/initstate 2>/dev/null || echo 'not loaded')"
ls -l /dev/aipu* 2>/dev/null || echo "no /dev/aipu*"
ls /sys/class/accel/ 2>/dev/null || true

echo "== unload"
sudo rmmod aipu && echo "clean rmmod OK" || echo "!! rmmod failed - likely wedged, reboot to clear"
