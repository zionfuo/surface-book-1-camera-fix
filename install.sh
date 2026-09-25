#!/usr/bin/env bash
#
# Install the built modules into /lib/modules/<release>/updates/.
#
# updates/ takes precedence over the kernel's own copy of the same module,
# so this shadows the built-in dw9719 and ov8865 without touching anything
# the package manager owns. Uninstalling is a plain file removal.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KREL="${KREL:-$(uname -r)}"
DEST="/lib/modules/$KREL/updates"
MODS=(dw9719 ov8865)

if [ "$(id -u)" -ne 0 ]; then
	echo "error: run as root (sudo ./install.sh)" >&2
	exit 1
fi

for mod in "${MODS[@]}"; do
	ko="$HERE/src/$mod/$mod.ko"
	if [ ! -f "$ko" ]; then
		echo "error: $ko not found - run ./build.sh first" >&2
		exit 1
	fi
	vm="$(modinfo -F vermagic "$ko" | awk '{print $1}')"
	if [ "$vm" != "$KREL" ]; then
		echo "error: $mod was built for $vm but this kernel is $KREL" >&2
		exit 1
	fi
done

mkdir -p "$DEST"
for mod in "${MODS[@]}"; do
	install -m 0644 "$HERE/src/$mod/$mod.ko" "$DEST/$mod.ko"
	echo "installed $DEST/$mod.ko"
done

depmod -a "$KREL"

cat <<'EOF'

Done. Now REBOOT.

Rebooting is not paranoia. Reloading these on a live camera stack is known
to wedge ipu_bridge: it stops attaching a software node to the ACPI sensor
devices, after which every sensor probe fails with -EINVAL
("failed to find 360000000 clk rate in endpoint link-frequencies") and
never retries. That state does not recover without a reboot.

After the reboot:

    ./diagnose.sh

To roll back:

    sudo ./uninstall.sh && sudo reboot
EOF
