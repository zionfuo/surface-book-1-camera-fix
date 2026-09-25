#!/usr/bin/env bash
#
# Post-reboot verification. Checks each thing the two fixes are supposed to
# change, then does a real 5-frame capture from both cameras.
#
# Read-only apart from two temporary .raw files. Safe to re-run.
#
set -u

KREL="$(uname -r)"
W=1280
H=720
FRAME=$(( W * H * 3 / 2 ))   # the viewfinder stream is NV12

sec() { printf '\n=== %s ===\n' "$1"; }
ok() { printf '  ok  %s\n' "$1"; }
warn() { printf '  !! %s\n' "$1"; }

# Per-frame luma statistics. An all-zero frame means the pipeline never
# wrote that buffer - which is what renders as flat green on screen. On a
# healthy camera the first frame or two can still come back zero while the
# IPU3 warms up, so only an all-zero *file* is treated as a failure.
ystats() {
	python3 - "$1" "$2" "$3" <<'PY' | sed 's/^/    /'
import sys

path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
frame = w * h * 3 // 2
data = open(path, 'rb').read()

n_frames = len(data) // frame
zero_frames = 0

for i in range(n_frames):
    y = data[i * frame:i * frame + w * h]
    lo, hi = min(y), max(y)
    mean = sum(y) / len(y)
    spread = (sum((v - mean) ** 2 for v in y) / len(y)) ** 0.5
    note = ''
    if hi == 0:
        zero_frames += 1
        note = '  <- all-zero, nothing written'
    print(f'frame {i}: Y min={lo} max={hi} mean={mean:.0f} std={spread:.0f}{note}')

if n_frames and zero_frames == n_frames:
    print('verdict: no frames at all - this is the stall, not a warmup artifact')
elif zero_frames:
    print(f'verdict: {n_frames}/{n_frames} frames delivered '
          f'({zero_frames} all-zero, normal IPU3 warmup)')
else:
    print(f'verdict: {n_frames}/{n_frames} frames delivered, all with content')
PY
}

sec "kernel"
echo "  running : $KREL"

sec "where do the two modules come from"
for mod in dw9719 ov8865; do
	path="$(modinfo -n "$mod" 2>/dev/null)"
	if [ -z "$path" ]; then
		warn "$mod: not found"
	elif [[ "$path" == */updates/* ]]; then
		ok "$mod: $path"
	else
		warn "$mod: $path   <- built-in, the fix is NOT installed"
	fi
done

sec "dw9719: i2c device id table (fix 0001)"
if modinfo dw9719 2>/dev/null | grep -q '^alias:[[:space:]]*i2c:'; then
	modinfo dw9719 | grep -E '^alias:[[:space:]]*i2c:' | sed 's/^/    /'
	ok "i2c aliases present"
else
	warn "no i2c: aliases - the VCM cannot bind and no camera will appear"
fi

sec "dw9719: is the VCM bound"
bound=0
for d in /sys/bus/i2c/devices/*/; do
	[ -e "$d/driver" ] || continue
	if [ "$(basename "$(readlink -f "$d/driver")")" = dw9719 ]; then
		ok "$(basename "$d") -> dw9719"
		bound=1
	fi
done
[ "$bound" -eq 1 ] || warn "no i2c client bound to dw9719"

if sudo journalctl -k -b 2>/dev/null | grep -q 'Instantiated dw9719 VCM'; then
	ok "kernel log: 'Instantiated dw9719 VCM'"
else
	warn "kernel log has no 'Instantiated dw9719 VCM' this boot"
fi

sec "ov8865: which sensor mode is it pinned to (fix 0003)"
# The sensor keeps the format it was last configured with, so after any
# capture the pad shows 3264x2448 (native) if the fix is active - and
# 1632x1224 if libcamera was allowed to pick the broken mode.
found_ov8865=0
for m in /dev/media*; do
	[ -e "$m" ] || continue
	block="$(timeout 15 media-ctl -d "$m" -p 2>/dev/null \
		| awk '/^- entity [0-9]+: ov8865/{f=1} f{print} f&&/^[[:space:]]*$/{exit}')"
	[ -n "$block" ] || continue
	found_ov8865=1
	echo "  $m"
	printf '%s\n' "$block" | sed 's/^/    /'
	if printf '%s\n' "$block" | grep -q 'fmt:.*3264x2448'; then
		ok "pinned to the native 3264x2448 mode"
	else
		warn "not on 3264x2448 - non-native modes stall after ~1 frame"
	fi
	break
done
[ "$found_ov8865" -eq 1 ] || echo "  (media-ctl not installed, or no ov8865 entity - skipping)"

sec "libcamera enumeration"
if command -v cam >/dev/null; then
	timeout 30 cam -l 2>&1 | sed -n '/Available cameras/,$p' | sed 's/^/  /'
else
	echo "  (cam not installed - skipping)"
fi

sec "capture test: 5 frames at ${W}x${H} from each camera"
if ! command -v cam >/dev/null; then
	echo "  (cam not installed - skipping)"
else
	# camera index -> name, straight out of `cam -l`
	while IFS= read -r line; do
		idx="${line%%:*}"
		name="${line#*: }"
		echo "  --- camera $idx ($name)"

		out="$(mktemp /tmp/sb1-cam-XXXX.raw)"
		timeout 60 cam -c"$idx" --capture=5 \
			--stream "role=viewfinder,width=$W,height=$H" \
			--file="$out" >/dev/null 2>&1
		rc=$?
		size=$(stat -c%s "$out" 2>/dev/null || echo 0)
		printf '    rc=%s bytes=%s frames=%s\n' \
			"$rc" "$size" "$(awk "BEGIN{printf \"%.2f\", $size/$FRAME}")"
		[ "$size" -gt 0 ] && ystats "$out" "$W" "$H"
		rm -f "$out"
	done < <(timeout 30 cam -l 2>/dev/null | sed -n '/Available cameras/,$p' \
		| grep -E '^[0-9]+: ')

	echo
	echo "  Working: 5/5 frames, most with content (a zero frame or two while"
	echo "           the IPU3 warms up is normal)."
	echo "  Stalled: fewer than 5 frames, or every frame all-zero."
fi

sec "done"
