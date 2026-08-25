# Context for picking this up in a new session

Working on a **UNO Q** board (`arduino,imola`, QRB2210, kernel
`7.0.0-g122c2c22d838`). Goal: extend the board's existing ADB USB gadget
(`g1`, built at runtime by `adbd-usb-gadget`/`adbd.service`) with extra
functions the vendor kernel didn't ship modules for. Read `README.md` in
this directory first — it's the detailed writeup for the HID piece
specifically. This file is the "where things stand across everything"
picture, including work not yet written up in README.md.

## Status

| Function | Kernel module | Live-tested | Boot-persistent | Notes |
|---|---|---|---|---|
| HID (keyboard) | Built (`module/usb_f_hid.ko`) | Yes — enumerated, keystroke landed | **Not yet** — see below | Fully documented in `README.md` |
| Mass storage | Already shipped (`usb_f_mass_storage.ko`) | Not started | Not started | No module build needed at all, just configfs |
| Audio (UAC2) | Not built yet | Not started | Not started | Needs 2 modules: `u_audio.ko` + `usb_f_uac2.ko` |
| UVC (webcam) | Not built yet | Not started | Not started | Needs 1 module from 4-5 objects; also needs a userspace streaming daemon to be useful (see below) |

**Important nuance on HID's "not yet persistent":** `usb_f_hid.ko` is
currently `insmod`'d and showing in `lsmod` (loaded manually during
testing, `modprobe usb_f_hid` was run as part of `test-hid-live.sh add`).
It will **not** survive a reboot yet — `arduino-hid-gadget` /
`10-hid.conf` are written and ready in this directory but have **not**
been copied to `/usr/local/sbin/` and `/etc/systemd/system/adbd.service.d/`
respectively. That's the very next step for HID specifically. Commands are
in `README.md` §6.

## Critical environment facts (don't re-derive these, they cost real time to find)

- **No passwordless sudo, and no way to answer an interactive sudo prompt
  from an agent's Bash tool.** Every root-requiring command (module
  install, configfs writes under the gadget's `configs/`/`UDC` — those
  need root even though *reading* `/sys/kernel/config/usb_gadget/g1` as
  `arduino` works fine) has to be handed to the user as an exact command
  block to run themselves, interactively, over SSH. Build steps that stay
  under the user's home directory (downloading packages, extracting,
  `make`) don't need root and *can* be run directly.
- **Two SSH paths exist to this board: one tunneled through adb
  (`127.0.0.1`), one over Wi-Fi (`192.168.1.71`).** Any command that
  unbinds/rebinds the gadget's UDC (`echo "" > .../UDC`, or restarting
  `adbd.service`) drops the adb-tunneled session. Always tell the user to
  run gadget-touching commands over the Wi-Fi session, never adb.
- **`/tmp` is tmpfs** — everything under `/tmp/hidwork/` (downloaded
  `.deb`s, extracted kernel headers, extracted `linux-source-7.0` tree) is
  gone on reboot and was already gone once mid-session (an early `tar`
  extraction silently no-op'd into an empty directory for reasons never
  fully root-caused — switching from relative to absolute paths for both
  the archive and `-C` destination made it work reliably; if extraction
  ever silently produces an empty directory again, that's the same class
  of issue, retry with absolute paths). If `/tmp/hidwork` is missing in a
  new session, re-run the download/extract commands in `README.md` §3 —
  they're idempotent and take well under a minute.
- **`/bin/sh` is dash.** Its `printf` only implements POSIX `\NNN` octal
  escapes, not `\xNN` hex. Any future byte-blob-into-configfs script needs
  octal escapes or a decimal/hex→octal conversion loop (see
  `hid_report_desc()` in `arduino-hid-gadget` for the pattern used).
- **configfs symlinks resolve the source path at creation time, via the
  kernel, not like an ordinary VFS symlink.** `ln -s` needs a *relative*
  symname valid from the process's cwd — `cd` into the gadget root first,
  then `ln -s functions/X configs/c.1/`. An absolute-path symlink source
  failed with ENOENT in live testing. Also: **unbinding the UDC has an
  async teardown tail** — a link creation or a rebind attempted
  immediately after unbind can transiently fail (ENOENT / EBUSY) even
  though it would succeed a second or two later. Every script here retries
  instead of trusting one attempt (see `rebind()` in
  `test-hid-live.sh` — it polls `/sys/class/udc/*/state` for `configured`
  rather than trusting the rebind write's exit code, which is unreliable).

## The general recipe (established and proven via HID, reusable for the rest)

1. Check `/boot/config-$(uname -r)` for the relevant `CONFIG_USB_F_*` /
   `CONFIG_USB_U_*` symbol. If it's `=m`, the `.ko` already exists
   somewhere under `/lib/modules/$(uname -r)/kernel/...` — no build needed,
   skip to configfs wiring.
2. If missing, get matching headers (`apt-get download
   linux-headers-$(uname -r)`, `dpkg-deb -x` into a scratch dir — no root
   needed) and matching-enough source (`apt-get download linux-source-7.0`
   from Debian, **not** raw upstream `torvalds/linux` — checked, Debian's
   patched `7.0.13` sources actually contained a real stable-tree bug fix
   in `f_hid.c` that the bare `v7.0` tag lacked, so the substitution turned
   out to matter, not just "close enough"; `apt-get download` also avoids
   ad-hoc external fetches for something that becomes a loaded kernel
   module).
3. Copy only the needed `.c`/`.h` files into `module/` here (check local
   `#include "..."` dependencies first — `grep -n '#include "' file.c` —
   to know exactly which siblings are needed; don't copy the whole
   `drivers/usb/gadget/function/` tree into the module dir, it's 68 files
   and most aren't relevant).
4. Add an `obj-m` target to `module/Makefile` (single shared Makefile,
   multiple targets — this is deliberate, "same build dir" was an explicit
   ask). Build with `make KDIR=<extracted-headers-path>`.
5. Verify: `strings module/whatever.ko | grep -E "vermagic|depends"` —
   `vermagic` must exactly match `uname -r`.
6. Write a `test-<function>-live.sh` mirroring `test-hid-live.sh`: unbind,
   create the function + set its attrs, link with the `cd`+relative
   pattern + retry, rebind polling for `configured`, `revert` subcommand.
   **Always live-test before writing the persistent boot hook** — a broken
   boot-time script risks `adbd.service` not recovering cleanly on next
   boot, and there's no interactive revert available at boot time the way
   there is live.
7. Only after live verification: write the boot-persistent piece
   (mirroring `arduino-hid-gadget` + `10-hid.conf`) and hand over the
   install commands.

## Where each of the three remaining functions was left off

### Mass storage — no module build needed at all
`CONFIG_USB_F_MASS_STORAGE=m` is already set, `usb_f_mass_storage.ko`
already exists at
`/lib/modules/7.0.0-g122c2c22d838/kernel/drivers/usb/gadget/function/`.
This is pure configfs wiring, same tier of effort as the very first
`acm.GS1` prototype in this session (not even a real module build).
Needs a decision on a backing file (blank image for the user to format,
vs. a specific existing file/partition to expose) before writing the
script — worth asking the user rather than assuming.

### Audio (UAC2) — needs building, not yet done
Chose UAC2 over UAC1/UAC1-legacy as the default (broadest native OS
support with no vendor driver needed — Windows 10+, macOS, Linux all have
built-in UAC2 class drivers) but **this default was never confirmed with
the user** — worth a quick check before committing, especially since
UAC1-legacy is simpler if the goal is just "basic audio I/O" rather than
higher quality/duplex.

Confirmed present and sufficient:
- `CONFIG_SND=m`, `CONFIG_SND_PCM=m` (ALSA core) — already loaded/available
  (`snd.ko`, `snd-pcm.ko` exist under `/lib/modules/.../kernel/sound/core/`)
- `include/sound/pcm.h` and the rest of `include/sound/` present in the
  already-extracted headers package

Not yet built: `u_audio.c`/`u_audio.h` (shared ALSA-backed core, needs its
own `.ko` — same pattern as `u_serial.ko`/`u_ether.ko` which are separate
modules that `usb_f_acm.ko`/`usb_f_ecm.ko` depend on) plus
`f_uac2.c` + `u_uac2.h` for `usb_f_uac2.ko` itself. All four files are
already sitting in
`/tmp/hidwork/src/linux-source-7.0/drivers/usb/gadget/function/` (pulled
during the full-folder extraction) — just need copying into `module/` and
adding to the Makefile. Confirmed local include chain: `f_uac2.c` needs
`u_audio.h` and `u_uac2.h`.

### UVC (webcam) — needs building, investigation incomplete, and has a runtime caveat beyond the module
Confirmed present and sufficient:
- V4L2/videobuf2 core already available as modules:
  `videodev.ko`, `videobuf2-common.ko`, `videobuf2-v4l2.ko`,
  `videobuf2-vmalloc.ko`, `videobuf2-dma-contig.ko`,
  `videobuf2-dma-sg.ko`, `videobuf2-memops.ko` under
  `/lib/modules/.../kernel/drivers/media/` — plausibly already present
  because this board supports camera Bricks (imx219 CSI camera DT
  overlays exist). This is the one that could have been a hard blocker
  and wasn't.
- `include/media/` headers (`v4l2-dev.h`, `v4l2-fh.h`, etc.) present in
  the extracted headers package.

Files needed (confirmed via `#include "..."` grep, all already sitting in
`/tmp/hidwork/src/.../function/`): `f_uvc.c` + `f_uvc.h`, `uvc.h`,
`uvc_configfs.c` + `uvc_configfs.h`, `uvc_queue.c` + `uvc_queue.h`,
`uvc_v4l2.c` + `uvc_v4l2.h`, `uvc_video.c` + `uvc_video.h`. Upstream's own
Makefile fragment (copied into `/tmp/hidwork/src/.../function/Makefile`
from the earlier full extraction) builds these five `.o`s into one
`usb_f_uvc.o`, plus conditionally `uvc_trace.o` — only `ifneq
($(CONFIG_TRACING),)`.

**Left off here:** checking whether `CONFIG_TRACING` is actually set on
this kernel, which decides whether `uvc_trace.c` must also be built in.
`uvc_video.c` calls `trace_uvcg_*()` twice — if `CONFIG_TRACING` is unset,
the kernel's own `<linux/tracepoint.h>` macros expand those to genuine
no-op inline stubs with no external symbol reference, and `uvc_trace.o`
can be skipped safely. If it *is* set, skipping it will fail the module
link with an undefined `__tracepoint_uvcg_*` symbol.
`grep -E "^CONFIG_TRACING=" /boot/config-$(uname -r)` came back **empty**
(only `CONFIG_TRACING_SUPPORT=y` is set, which is a different, weaker
symbol — infrastructure support, not the tracing subsystem itself) — this
is a reasonably strong signal `CONFIG_TRACING` is unset and `uvc_trace.o`
isn't needed, but it wasn't confirmed with a clean positive check before
the session got redirected to writing this file. **Confirm this before
building** — if wrong, the fix is just adding `uvc_trace.c` to the
`obj-m` sources and pulling `uvc_trace.h` in (already present locally
too).

**Runtime caveat worth flagging to the user early, before they assume UVC
is "done" the same way HID was:** unlike HID (write bytes to `/dev/hidg0`,
host sees a keypress) or mass storage (backing file just *is* the disk,
no daemon needed), a UVC gadget function only creates a `/dev/video<N>`
node on the **device** side. Nothing shows up on the host as actual video
until a userspace program on the board reads frames from somewhere (a
real camera via V4L2, a test pattern, whatever) and pushes them into that
uvc video node — typically via something like the `uvc-gadget` reference
app, not built by any of this. Getting `usb_f_uvc.ko` to build and the
function to enumerate is necessary but not sufficient for "the host sees a
webcam picture" — say so explicitly when reporting progress on this one,
don't let silence imply it's equivalent to the HID/mass-storage cases.

## File manifest

| File | Status |
|---|---|
| `README.md` | Detailed HID writeup — build process, gotchas, install commands. Read this for the HID story. |
| `module/f_hid.c`, `module/u_hid.h` | Verbatim upstream (Debian `linux-source-7.0`), built |
| `module/usb_f_hid.ko` | Built, loaded right now, not yet boot-persistent |
| `module/Makefile` | Currently only has the `usb_f_hid` target — extend this same file for uac2/uvc, don't create sibling Makefiles, per explicit ask to reuse the build dir |
| `arduino-hid-gadget` | HID boot-time setup/teardown script — written, tested logic, **not yet copied to `/usr/local/sbin/`** |
| `10-hid.conf` | systemd drop-in for `adbd.service` — written, **not yet copied to `/etc/systemd/system/adbd.service.d/`** |
| `99-hidg.rules` | udev rule for `/dev/hidg0` perms — written, **not yet copied to `/etc/udev/rules.d/`** |
| `test-hid-live.sh` | Live add/tap-a/revert tool for HID — this is the one that got the actual proof (host `lsusb` diff + keystroke) |

## Scratch state that may or may not still exist (`/tmp/hidwork/`, tmpfs)

If present, saves re-downloading:
- `headers-extracted/usr/src/linux-headers-7.0.0-g122c2c22d838/` — the
  `KDIR` used for every build so far
- `src/linux-source-7.0/drivers/usb/gadget/function/` — **all 68 function
  driver files**, already extracted (includes everything needed for
  mass_storage/uac2/uvc, no re-extraction needed for those specifically)
- `extracted/`, the two downloaded `.deb`s, and `upstream_f_hid.c` /
  `upstream_u_hid.h` (used once for the Debian-vs-upstream diff, not
  needed again)

If gone, `README.md` §3 has the exact re-download/extract commands.
