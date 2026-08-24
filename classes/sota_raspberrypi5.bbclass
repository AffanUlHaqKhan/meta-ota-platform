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
# The ostree= karg is NOT set here. With sysroot.bootloader=none nothing
# rewrites it automatically -- see docs/rpi5-boot.md.
OSTREE_KERNEL_ARGS:sota ?= "console=ttyAMA10,115200 console=tty1 rootwait"

# --- Image layout -----------------------------------------------------------
# Generic: vfat boot partition + ext4 rootfs carrying the OSTree physical
# sysroot. It carries no u-boot assumptions, so it is reused as-is.
WKS_FILE:sota = "sdimage-sota.wks"
IMAGE_FSTYPES:remove:sota = "rpi-sdimg"

# rpi-base.inc's IMAGE_BOOT_FILES default is what populates the vfat partition
# (firmware, start*.elf, config.txt, kernel, dtbs, overlays). It is left alone
# on purpose -- meta-updater's :sota override of it exists to inject u-boot.
