#!/usr/bin/env bash
#
# Remove the modules installed by install.sh and restore the kernel's own.
#
set -euo pipefail

KREL="${KREL:-$(uname -r)}"
DEST="/lib/modules/$KREL/updates"
MODS=(dw9719 ov8865)

if [ "$(id -u)" -ne 0 ]; then
	echo "error: run as root (sudo ./uninstall.sh)" >&2
	exit 1
fi

removed=0
for mod in "${MODS[@]}"; do
	if [ -f "$DEST/$mod.ko" ]; then
		rm -f "$DEST/$mod.ko"
		echo "removed $DEST/$mod.ko"
		removed=1
	else
		echo "not installed: $DEST/$mod.ko"
	fi
done

# Leave a clean, empty directory behind rather than a stray one.
rmdir "$DEST" 2>/dev/null || true

if [ "$removed" -eq 1 ]; then
	depmod -a "$KREL"
	echo
	echo "Done. Reboot for the built-in modules to be used again."
	echo "Verify with: modinfo -n dw9719 ov8865   (paths should no longer contain /updates/)"
else
	echo
	echo "Nothing to do."
fi
