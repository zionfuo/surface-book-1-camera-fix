# Surface Book 1 camera fixes for Linux

Two kernel module fixes that make the **front and rear cameras work on a
Surface Book 1 (1703/1705)** running linux-surface. Without them neither
camera is registered at all — `cam -l` prints an empty list, GNOME Snapshot
says there is no camera.

Tested on:

| | |
|---|---|
| Machine | Surface Book 1 (13", 1703/1705) |
| Kernel | `6.19.8-surface-3` (linux-surface) |
| libcamera | 0.7.0 |
| IPU3 stack | `ipu3-cio2`, `ipu3-imgu`, `ov8865` (rear), `ov5693` (front), `dw9719` (VCM) |

Licence: **GPL-2.0-only** — these are kernel modules, both source files are
derived from the Linux kernel.

> 中文说明见 [README.zh-CN.md](README.zh-CN.md)。

## The two bugs

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | **No cameras at all.** Neither front nor rear is listed by libcamera. | v6.19 dropped the `i2c_device_id` table from `dw9719`, so the VCM cannot bind on ACPI platforms, so the CIO2 notifier never completes. | [`patches/0001`](patches/0001-dw9719-add-back-i2c-device-id-table.patch) |
| 2 | **Rear camera gives a flat green image**, or nothing. | `ov8865` only streams in its native 3264x2448 mode. Every other mode delivers ~1 frame and stalls. | [`patches/0003`](patches/0003-ov8865-only-expose-native-mode.patch) |

[`patches/0002`](patches/0002-dw9719-fsleep-power-up-delay.patch) is
**not ours** — it is linux-surface's own probe delay for the same driver,
included only because an out-of-tree module replaces the whole file. On any
linux-surface kernel it is already applied; do not apply it twice.

Your kernel needs the linux-surface patch set. A stock Ubuntu kernel will not
work: it lacks the IPU3 camera support for this machine to begin with.

## Install

```bash
git clone <this repo>
cd surface-book-1-camera-fix

./build.sh                 # needs linux-headers-$(uname -r)
sudo ./install.sh
sudo reboot
./diagnose.sh              # confirmed working? read on
```

`build.sh` needs no kernel source tree — the linux-surface headers package is
enough. It builds both modules out-of-tree and checks their vermagic against
the running kernel before you install anything.

### Why the reboot is not optional

Reloading these modules on a live camera stack is known to wedge `ipu_bridge`:
it stops attaching a software node to the ACPI sensor devices, every sensor
probe then fails with

```
failed to find 360000000 clk rate in endpoint link-frequencies
```

and it never retries. That state does not recover without a reboot. Do not
`modprobe -r`, do not unbind things to "test quickly".

### Secure Boot

The modules are unsigned, so the kernel will taint itself
(`module verification failed ... tainting kernel`). That is expected and
harmless. If you have Secure Boot **enabled** you must sign them with your own
MOK key first, or they will refuse to load.

## Bug 1 — why *both* cameras disappear

The rear camera is an `ov8865` with an autofocus voice coil, `dw9719`. Upstream
v6.19 converted `dw9719` to CCI and in the process dropped its `i2c_device_id`
table:

```console
$ grep -nE 'i2c_device_id|\.id_table' dw9719.c    # v6.18.7
356:static const struct i2c_device_id dw9719_id_table[] = {
373:	.id_table = dw9719_id_table,

$ grep -nE 'i2c_device_id|\.id_table' dw9719.c    # v6.19.8
(nothing)
```

That matters because on ACPI platforms the CIO2 bridge instantiates the VCM as
an **i2c client carrying a software node**, not an OF node:

```
i2c-INT347A:00-VCM      modalias = i2c:dw9719
```

No `of_node` means the OF table can never match it, and with no id table there
is nothing left to match. The chain from there is unforgiving:

```
VCM never probes
  -> ov8865 waits forever in v4l2-async for its fwnode provider
    -> the CIO2 notifier never completes
      -> no media links are created
        -> libcamera's registerCameras() returns -ENODEV
          -> zero cameras
```

The counterintuitive part: **the front `ov5693` dies too.** It has no VCM of its
own — it is simply behind the same notifier. If you find yourself debugging the
front sensor's driver, you are looking in the wrong place.

The fix restores the table v6.18 had. You can see it took effect in the kernel
log:

```
dw9719 i2c-INT347A:00: Instantiated dw9719 VCM
```

and in the module's aliases:

```console
$ modinfo dw9719 | grep '^alias.*i2c:'
alias:          i2c:dw9761
alias:          i2c:dw9719
```

This is not Surface-Book-specific. Any ACPI machine whose camera uses this VCM
(Surface Go 2, Surface Pro 7+, …) loses its cameras the same way on v6.19. If
you are here from one of those, `patches/0001` is the relevant one.

## Bug 2 — the rear camera's green image

`ov8865` has four modes. Only the native one streams:

| Mode | `v4l2-ctl --stream-mmap --stream-count=5` |
|---|---|
| **3264x2448** (native) | **5/5 frames, rc=0** |
| 3264x1836 | 0.99 frames, then nothing |
| 1632x1224 | 0.99 frames, then nothing |
| 800x600 | 1.00 frames, then nothing |

Alternating good/bad/good/bad reproduces the same pattern, so this is a
property of the mode, not leftover stream-on state. The kernel says:

```
ipu3-cio2: payload length is 2585088, received 2588672
CSI-2 receiver port 0: frame sync error
```

3584 bytes *more* than expected and then desync — the HTS/VTS timings for the
non-native modes look wrong and the receiver overflows.

### Why applications hit the bad mode

libcamera picks the *smallest* mode that is at least as large as the request:

| Application asks for | libcamera picks | Result |
|---|---|---|
| 1280x720 | 1632x1224 | broken — 0 or 1 frame |
| 1920x1080 | 3264x2448 | works |
| 2560x1920 | 3264x2448 | works |

GNOME Snapshot asks for 1280x720, so it lands on the broken mode. And it cannot
ask for more, because libcamera exposes the IPU3 cameras to PipeWire with
output sizes **capped at 1280x720** (for every camera, front included — it is a
pipeline limit, not a sensor one). So "just use a bigger resolution" is not a
workaround available to applications.

### What the green actually is

Pure green is `YUV(0,0,0)`, which converts to `RGB(0,154,0)`. libcamera's own
"black" frame is `YUV(0,128,128)`. So green does not mean "wrong colour" — it
means the application got a buffer that was **never written**: zero-initialised
memory. There was no frame. (The one frame that does arrive in 1280x720 renders
as *magenta*, `RGB(255,95,255)` — unconverged AWB — which is why the symptom
looks like a colour bug but is not.)

### The fix, and what it costs

The proper fix needs the OV8865 datasheet. `ov8865_pll1_config` has a single
configuration shared by every mode while `ov8865_pll2_config` has per-mode
variants, and `ov8865_mode_pll1_rate()` / `ov8865_mode_pll1_configure()` take a
`mode` pointer and then ignore it. PLL1 feeds the MIPI clock
(`pll1_rate / m_div / 2`), so every mode reports the same 360 MHz. This is an
unfinished implementation, and without binning PLL1 numbers from the datasheet
there is nothing to correct.

So instead, hide the broken modes: `VIDIOC_ENUM_FRAMESIZES` reports only the
native one, so libcamera has no choice, and `set_fmt` pins the mode as well so a
caller driving V4L2 directly cannot pick a broken one either.

Cost:

- the sensor always runs 3264x2448 and the IMGU downsamples (2.55x for a
  1280x720 request);
- slightly more power;
- field of view gets *wider*, not narrower — the non-native modes crop
  (`crop:(832,652)/1632x1224`), the native one uses the full array
  (`crop:(16,40)/3264x2448`).

This is a workaround, and it is labelled as one. If someone has the datasheet,
please fix PLL1 properly and delete `patches/0003`.

## Rolling back

```bash
sudo ./uninstall.sh
sudo reboot
```

The modules live in `/lib/modules/$(uname -r)/updates/`, which shadows the
kernel's own copies. Uninstalling is a plain file removal and
`depmod -a` — nothing the package manager owns is touched, so
reinstalling `linux-image-surface` always gets you back to stock.

## Notes for anyone debugging the IPU3 stack

- **Raw V4L2 needs the pipeline format aligned by hand.** `ov8865` sits in
  its native 3264x2448 while `ipu3-csi2 0` defaults to 1632x1224; the mismatch
  makes `v4l2_subdev_link_validate()` return `-EPIPE` and `VIDIOC_STREAMON`
  fail with `Broken pipe`. Align them first:

  ```bash
  sudo media-ctl -d /dev/media1 -V '"ov8865 3-0010":0 [fmt:SBGGR10_1X10/1632x1224 field:none]'
  sudo media-ctl -d /dev/media1 -V '"ipu3-csi2 0":0 [fmt:SBGGR10_1X10/1632x1224 field:none]'
  sudo media-ctl -d /dev/media1 -V '"ipu3-csi2 0":1 [fmt:SBGGR10_1X10/1632x1224 field:none]'
  ```

  The front `ov5693` escapes this by luck: its driver default (2592x1944)
  happens to equal the CIO2 default.

- **`cam` argument syntax bites.** In libcamera 0.7.0 it is
  `cam -c1 --capture=5 --stream role=viewfinder,width=1280,height=720 --file=out.raw`.
  `--stream size=...` and `--stream-count=5` do not exist; passing them makes
  `cam` print its help text and exit non-zero, which is easy to misread as a
  capture failure. `-F out.ppm` silently produces a 0-byte file.

- **The "device or resource busy" from `cam`** is usually PipeWire or
  wireplumber holding `/dev/video*` and `/dev/media*`, not a broken driver.

- **`dmesg` is restricted** on Ubuntu; use `sudo journalctl -k -b`.

- **Frame 1 comes back all-zero** on both cameras, every time. That is IPU3
  warmup, not a bug, and `diagnose.sh` accounts for it.

## What is deliberately not in this repo

- **Prebuilt `.ko` files.** They are tied to one exact kernel build, they taint
  the kernel, and you should not be loading binaries from a stranger's repo.
  Three seconds of `make` is better.
- **MOK signing keys.** Signing is machine-specific; do it with your own key.
- The full kernel sources. The patches apply to a kernel tree and the `src/`
  copies build out-of-tree; either way you fetch the kernel yourself.

## Credits

- The IPU3, camera and Surface support is the work of
  [linux-surface](https://github.com/linux-surface/linux-surface) and the
  upstream `drivers/media/i2c` maintainers. `patches/0002` is
  linux-surface's patch (author: mojyack).
- The two fixes here come from debugging one Surface Book 1.
