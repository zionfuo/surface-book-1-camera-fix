#!/usr/bin/env bash
#
# Build the two camera modules out-of-tree against the running kernel.
#
# No kernel source tree is needed - the linux-surface headers package is
# enough. Override KREL/KDIR to cross-build for another kernel.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KREL="${KREL:-$(uname -r)}"
KDIR="${KDIR:-/lib/modules/$KREL/build}"

if [ ! -d "$KDIR" ]; then
	echo "error: no kernel build directory at $KDIR" >&2
	echo "       install the matching headers, or set KDIR=/path/to/headers" >&2
	exit 1
fi

echo "kernel release : $KREL"
echo "kernel build   : $KDIR"
echo

for mod in dw9719 ov8865; do
	echo "=== building $mod ==="
	# LOCALVERSION= is NOT optional. Left unset, the build picks up the
	# kernel's local version suffix and the resulting vermagic no longer
	# matches the running kernel, so the module silently refuses to load.
	make -C "$KDIR" M="$HERE/src/$mod" LOCALVERSION= modules
	echo
done

echo "=== vermagic check ==="
status=0
for mod in dw9719 ov8865; do
	ko="$HERE/src/$mod/$mod.ko"
	vm="$(modinfo -F vermagic "$ko" | awk '{print $1}')"
	if [ "$vm" = "$KREL" ]; then
		printf '  %-8s %s  ok\n' "$mod" "$vm"
	else
		printf '  %-8s %s  MISMATCH (expected %s)\n' "$mod" "$vm" "$KREL" >&2
		status=1
	fi
done
[ "$status" -eq 0 ] || exit 1

cat <<'EOF'

Built. Next:

    sudo ./install.sh      # install into /lib/modules/<release>/updates/
    sudo reboot            # required - see install.sh

To check the result afterwards:

    ./diagnose.sh
EOF
