# Raspberry Pi 5 boot and update path

Board decision is `DECISIONS.md` D3/D4: **Pi 5 with userspace-only rollback**. This file
records what that costs, what is built, and what is still yours to implement.

---

## Why the Pi 5 is different

| | Pi 4 | Pi 5 |
|---|---|---|
| u-boot support upstream | yes (`bcm2711`) | **none** — no `bcm2712` under `arch/arm/mach-bcm283x`, still absent at v2025.07 |
| meta-updater class | `sota_raspberrypi.bbclass` | none — ours, `classes/sota_raspberrypi5.bbclass` |
| `OSTREE_BOOTLOADER` | `u-boot` | `none` |
| Kernel format | `fitImage` (for u-boot) | raw arm64 `Image` (firmware loads it) |
| Boot-failure recovery | u-boot `bootcount`/`bootlimit` | **nothing** |

With `OSTREE_BOOTLOADER = "none"`, `image_types_ota.bbclass` runs
`ostree config --repo=... set sysroot.bootloader none`. OSTree then deploys commits normally
but writes **no bootloader configuration at all**. Nothing updates a boot menu, because there
is no boot menu.

## What that means at runtime

OSTree lays each deployment out as:

```
/boot/ostree/<osname>-<bootcsum>/vmlinuz
/boot/ostree/<osname>-<bootcsum>/initramfs
/ostree/boot.<N>/<osname>/<checksum>/0        <- the deployment root
```

and expects the kernel command line to carry:

```
ostree=/ostree/boot.1/ota-platform/<checksum>/0
```

The Pi 5 firmware knows none of this. It reads `config.txt` and `cmdline.txt` from the FAT
partition and loads whatever kernel they name. So **something in userspace must, on every
deploy:**

1. copy the new deployment's `vmlinuz` and `initramfs` into the FAT boot partition,
2. rewrite `cmdline.txt` with the new `ostree=` path,
3. `sync`, then reboot.

That is the gap. `ota-agent` owns it — see its `[bootloader]` section, `kind = "none"`.

## The danger this creates

Steps 1–3 are **not atomic**. Between rewriting `cmdline.txt` and a successful boot there is a
window where a power cut leaves the device pointing at a half-copied kernel. On the Pi 4 this
did not matter, because u-boot would have counted the failure and fallen back on its own.

Mitigations, in order of value:

- **Write the new kernel under a new name, then rewrite `cmdline.txt` last**, with
  `sync` between. `cmdline.txt` is small enough that its rewrite is close to atomic on FAT;
  the kernel copy is not.
- **Keep the previous deployment's kernel in the FAT partition** and keep a known-good
  `cmdline.txt.bak` next to it, so a technician has a one-file recovery.
- **Never prune the previous OSTree deployment** until the new one has been confirmed.

None of this recovers a kernel that panics on boot. Accept that or revisit D4.

## What is already built

`classes/sota_raspberrypi5.bbclass` handles the Yocto side:

- bypasses meta-updater's u-boot-only Pi class by way of `SOTA_MACHINE:rpi = "raspberrypi5"`
- `OSTREE_BOOTLOADER = "none"`, `RPI_USE_U_BOOT:sota = "0"`
- raw `Image` kernel, no `kernel-fitimage`
- `bcm2712-rpi-5-b.dtb` + `vc4-kms-v3d-pi5.dtbo`
- `console=ttyAMA10,115200` — the Pi 5's UART, not the Pi 4's `ttyS0`, and without
  meta-updater's bogus `bcm2708_fb.*` arguments
- `sdimage-sota.wks` (vfat boot + ext4 OSTree sysroot; carries no u-boot assumptions)

## What is not built yet

1. **`cmdline.txt` with the right `ostree=` karg in the factory image.** On u-boot boards the
   bootloader derives this. Here the `.wks` produces a boot partition whose `cmdline.txt` comes
   from `RPI_CMDLINE`/`bootfiles`, with no `ostree=` in it. Until this is added, the first
   flashed image will not boot into a deployment. Options: a `do_image_wic:prepend` that writes
   `cmdline.txt` after reading the deployed checksum, or an initramfs that locates the
   deployment itself.
2. **The agent's `none` bootloader backend** — the three steps above.
3. **A confirm/reject path that means anything.** With no bootcount, "reject" can only mean
   "rewrite `cmdline.txt` back to the previous deployment and reboot", and only if userspace
   still runs.

Test 3 in `ota-agent`'s testing section (power loss between deploy and confirm) is expected to
**fail** on this board. That is the accepted trade, not a bug — but verify it fails the way you
expect, on real hardware, before shipping anything.
