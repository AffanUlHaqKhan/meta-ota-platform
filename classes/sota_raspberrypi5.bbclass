# Raspberry Pi 5 (BCM2712) OSTree integration.
#
# meta-updater ships sota_raspberrypi.bbclass for the Pi 2/3/4 only, and it
# assumes u-boot throughout. Upstream u-boot has no BCM2712 support (there is
# no bcm2712 target under arch/arm/mach-bcm283x as of v2025.07), so none of it
# applies here.
#
# sota.bbclass ends with `inherit sota_sanity sota_${SOTA_MACHINE}`, so setting
#   SOTA_MACHINE:rpi = "raspberrypi5"
# in local.conf makes it load THIS class instead of meta-updater's. That is
# deliberate: overriding meta-updater's hard `=` assignments from local.conf is
# not possible, because bbclasses are parsed after it.
#
# Consequence, accepted knowingly (DECISIONS.md D4): with no bootloader that
# counts failed boots, a kernel that never reaches userspace cannot recover on
# its own. Rollback here is userspace-only.

# --- No u-boot --------------------------------------------------------------
RPI_USE_U_BOOT:sota = "0"

# "none" is a supported OSTREE_BOOTLOADER in image_types_ota.bbclass; it sets
# `ostree config set sysroot.bootloader none`, so OSTree writes no bootloader
# config at all and the Pi firmware is left in charge of loading the kernel.
OSTREE_BOOTLOADER = "none"

# The FIT image only exists to be loaded by u-boot. The Pi firmware loads a raw
# arm64 Image, so drop kernel-fitimage entirely.
KERNEL_IMAGETYPE:sota = "Image"
KERNEL_IMAGETYPE_UBOOT:sota = "Image"
KERNEL_IMAGETYPE_DIRECT:sota = "Image"
OSTREE_KERNEL = "Image"
INITRAMFS_FSTYPES = "cpio.gz"

# --- Device tree ------------------------------------------------------------
KERNEL_DEVICETREE:raspberrypi5:sota = " \
    broadcom/bcm2712-rpi-5-b.dtb \
    overlays/vc4-kms-v3d-pi5.dtbo \
    "
SOTA_DT_OVERLAYS:raspberrypi5 = "vc4-kms-v3d-pi5.dtbo"

# --- Kernel args ------------------------------------------------------------
# meta-updater's Pi class hardcodes bcm2708 framebuffer args and console=ttyS0,
# both wrong for a Pi 5 (its debug UART is ttyAMA10, per raspberrypi5.conf).
#
# root= is required: the OSTree initramfs must mount the sysroot partition
# before it can resolve the ostree= deployment path inside it. The ostree= karg
# itself is appended by OSTree when it writes the boot loader entry -- it
# contains a per-build checksum, so it cannot be hardcoded here.
OSTREE_KERNEL_ARGS:sota ?= "root=/dev/mmcblk0p2 rootfstype=ext4 rootwait console=ttyAMA10,115200 console=tty1"

# --- Firmware boot configuration --------------------------------------------
# The Pi 5 EEPROM bootloader reads config.txt, so the OSTree initramfs has to be
# named there or it is never loaded -- and without it nothing pivots into a
# deployment. `followkernel` places it directly after the kernel in memory.
RPI_EXTRA_CONFIG:append = "\n# OSTree: load the initramfs that pivots into the deployment\nkernel=kernel_2712.img\ninitramfs initramfs.img followkernel\n"

# Boot partition additions, appended AFTER rpi-base.inc's defaults so that our
# cmdline.txt overwrites the generic one from rpi-cmdline.bb.
IMAGE_BOOT_FILES:append = " \
    initramfs-ostree-image-${MACHINE}.cpio.gz;initramfs.img \
    ostree-cmdline/cmdline.txt;cmdline.txt \
    "

# The cmdline.txt generator lives in its own class because `addtask` in a
# globally inherited class would attach the task to every recipe in the tree.
# IMAGE_CLASSES is inherited only by image recipes.
IMAGE_CLASSES += "rpi5-ostree-boot"

# --- Image layout -----------------------------------------------------------
# Generic: vfat boot partition + ext4 rootfs carrying the OSTree physical
# sysroot. It carries no u-boot assumptions, so it is reused as-is.
WKS_FILE:sota = "sdimage-sota.wks"
IMAGE_FSTYPES:remove:sota = "rpi-sdimg"

# rpi-base.inc's IMAGE_BOOT_FILES default is what populates the vfat partition
# (firmware, start*.elf, config.txt, kernel, dtbs, overlays). It is left alone
# on purpose -- meta-updater's :sota override of it exists to inject u-boot.
