SUMMARY = "Sync the Raspberry Pi firmware boot partition with the current OSTree deployment"
DESCRIPTION = "The Pi 5 has no u-boot, so OSTree runs with sysroot.bootloader=none and nothing \
acts on the boot loader entries it writes. This copies the deployed kernel and initramfs to the \
vfat partition the firmware reads, and rewrites cmdline.txt with the deployment's ostree= karg."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "^rpi$"

SRC_URI = " \
    file://ostree-boot-sync \
    file://ostree-boot-sync.service \
    file://ostree-boot-sync.path \
    file://boot-firmware.mount \
    "

S = "${WORKDIR}"

inherit systemd allarch

RDEPENDS:${PN} = "ostree util-linux-mountpoint coreutils"

SYSTEMD_SERVICE:${PN} = "ostree-boot-sync.service ostree-boot-sync.path boot-firmware.mount"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/ostree-boot-sync ${D}${bindir}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ostree-boot-sync.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/ostree-boot-sync.path    ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/boot-firmware.mount      ${D}${systemd_system_unitdir}/

    # No mount point created here on purpose: /boot is populated by OSTree at
    # deploy time, so anything committed under it is unreliable. systemd creates
    # a mount unit's Where= directory itself, and /boot is writable on a running
    # OSTree system (it is the physical sysroot's boot directory).
}

FILES:${PN} += "${systemd_system_unitdir}"
