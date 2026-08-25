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

## How the factory image boots (implemented)

The first build produced an image that could not boot, in three separate ways. All three are
now handled in `classes/sota_raspberrypi5.bbclass` and `classes/rpi5-ostree-boot.bbclass`:

| Gap | Symptom | Fix |
|---|---|---|
| `cmdline.txt` had no `ostree=` karg | initramfs cannot find a deployment | generated per build from OSTree's own boot loader entry |
| `cmdline.txt` had no `root=` | initramfs cannot mount the sysroot to *look* for one | added to `OSTREE_KERNEL_ARGS` |
| initramfs neither shipped nor referenced | kernel boots, nothing pivots into the deployment | added to `IMAGE_BOOT_FILES` and to `config.txt` |

### Where the command line comes from

`sysroot.bootloader=none` stops OSTree writing bootloader config, but it still emits a Boot
Loader Spec entry at `boot/loader/entries/ostree-1.conf` in the OTA sysroot:

```
options console=ttyAMA10,115200 console=tty1 rootwait root=/dev/mmcblk0p2 rootfstype=ext4 \
        ostree=/ostree/boot.1/ota-platform/64bb26f5...43ee/0
linux  /ostree/ota-platform-64bb26f5...43ee/vmlinuz-6.6.63-v8-16k
initrd /ostree/ota-platform-64bb26f5...43ee/initramfs-6.6.63-v8-16k.img
```

`do_write_ostree_cmdline` reads that `options` line verbatim into
`${DEPLOY_DIR_IMAGE}/ostree-cmdline/cmdline.txt`, and `IMAGE_BOOT_FILES` copies it over the
generic `cmdline.txt` from `rpi-cmdline.bb`. Reading OSTree's own answer beats recomputing the
deployment path: the checksum changes every build, and OSTree owns the numbering of
`boot.N`. The task fails loudly if the entry is missing or carries no `ostree=`, so a silently
unbootable image cannot be produced again.

Ordering is `after do_image_ota before do_image_wic` — the sysroot must exist, and the file
must be in place before wic populates the FAT partition. The task lives in its own class
because `addtask` in a globally inherited class attaches to every recipe in the tree;
`IMAGE_CLASSES` scopes it to images.

### config.txt

`RPI_EXTRA_CONFIG` appends:

```
kernel=kernel_2712.img
initramfs initramfs.img followkernel
```

`followkernel` places the initramfs directly after the kernel in memory. Without these two
lines the Pi 5 firmware loads a kernel with no initramfs, and the `ostree=` karg has nothing to
act on.

## How updates work (implemented)

The factory image boots because bitbake generated `cmdline.txt`. Nothing kept it correct
afterwards, so an update used to deploy successfully and then reboot into the **old** commit,
silently. `ostree-boot-sync` closes that.

### The gap it bridges

```
partition 1  vfat   <- the Pi 5 EEPROM firmware reads kernel/initramfs/cmdline.txt from here
partition 2  ext4   <- OSTree writes /boot/ostree/<os>-<csum>/vmlinuz and
                       /boot/loader/entries/ostree-N.conf here
```

Nothing connects them. The deployment's stock `/etc/fstab` does not even mount partition 1, so
on a running system the firmware's partition is invisible.

`boot-firmware.mount` mounts it at `/boot/firmware` by label, and `ostree-boot-sync` copies the
deployed kernel and initramfs across and rewrites `cmdline.txt` from the BLS entry.

### Triggering

| Unit | When |
|---|---|
| `ostree-boot-sync.path` | `PathChanged=/boot/loader/entries` — fires whenever OSTree writes a deployment, from `ota-agent`, a manual `ostree admin upgrade`, or a technician over ssh |
| `ostree-boot-sync.service` | also at boot, to repair drift from a deploy interrupted before it synced |

Watching the entries rather than hooking the agent is deliberate: OSTree has no post-deploy
hook, and any path that deploys must not be able to skip the sync.

### The `ostree=` path is keyed on the kernel, not the commit

Measured across two builds whose rootfs differed (one added `ostree-boot-sync`):

```
commit checksum   96c1ca2c...  <- changed
ostree= karg      /ostree/boot.1/ota-platform/64bb26f5.../0   <- did NOT change
```

`64bb26f5...` is the **bootcsum**, a hash of the kernel and initramfs, not of the rootfs
commit. `/ostree/boot.1/<osname>/<bootcsum>/0` is a directory OSTree itself re-points at the
current deployment.

The consequence is worth designing around: **an update that does not change the kernel needs no
write to the boot partition at all.** Same kernel, same initramfs, same command line — OSTree's
own symlink does the work, and `ostree-boot-sync` correctly exits early as "already in sync".

So the risky path — multi-megabyte writes to a vfat partition with no atomic replace — is taken
only when the kernel changes. Application-only updates, which is most of them, never touch it.
Keep kernel changes to deliberate, separately tested releases and this board's weak rollback
story matters far less in practice.

### Write ordering is the only safety net on this board

```
1. back up outgoing kernel/initramfs/cmdline  ->  kernel_prev.img, cmdline.txt.bak
2. check free space BEFORE writing anything   (vfat has no atomic replace)
3. copy kernel + initrd to .name.new, sync, rename, sync
4. write cmdline.txt LAST, sync
```

Until step 4 lands, `cmdline.txt` still names the previous deployment **and** the previous
kernel is still in place, so an interruption anywhere in steps 1–3 leaves a bootable system on
the old commit. Reversing steps 3 and 4 would produce a brick. Do not "optimise" this order.

The script refuses to write a `cmdline.txt` without an `ostree=` karg, and is idempotent — it
compares the stored command line (which embeds the deployment checksum) and exits early when
already in sync.

## What is still not built

1. **A confirm/reject path.** With no bootcount, "reject" can only mean "restore
   `cmdline.txt.bak` and `kernel_prev.img`, then reboot" — and only while userspace still runs.
   `ostree-boot-sync` leaves those backups precisely so that path can be written.
2. **`ota-agent` itself**, which is what would decide *when* to reject.

## Untested

`ostree-boot-sync` has not run on hardware. It is written defensively — dies rather than writes
on every unexpected condition — but the first real test is a Pi 5 doing an actual
`ostree admin upgrade`. Verify in this order:

```bash
systemctl status boot-firmware.mount          # is partition 1 mounted?
ostree-boot-sync                              # run by hand, read the log
ostree admin status                           # what does OSTree think is default?
cat /boot/firmware/cmdline.txt                # does the ostree= checksum match?
```

Test 3 in `ota-agent`'s testing section (power loss between deploy and confirm) is expected to
**fail** on this board. That is the accepted trade, not a bug — but verify it fails the way you
expect, on real hardware, before shipping anything.
