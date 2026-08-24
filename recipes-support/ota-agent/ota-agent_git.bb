SUMMARY = "On-device OTA update agent (OSTree)"
HOMEPAGE = "https://github.com/<you>/ota-agent"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=<fill-after-first-fetch>"

DEPENDS = "ostree curl openssl"
RDEPENDS:${PN} = "ostree curl ca-certificates"

SRC_URI = "git://github.com/<you>/ota-agent.git;protocol=https;branch=main"
SRCREV = "${AUTOREV}"
PV = "0.1+git${SRCPV}"

S = "${WORKDIR}/git"

inherit cmake systemd

SYSTEMD_SERVICE:${PN} = "ota-agent.service ota-healthcheck.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/systemd/*.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/ota-agent
    install -m 0644 ${S}/config/agent.toml ${D}${sysconfdir}/ota-agent/agent.toml

    # Remote URL and OS name come from the Yocto config, not the source repo.
    sed -i -e 's|@OSTREE_REMOTE_URL@|${OSTREE_REMOTE_URL}|g' \
           -e 's|@OSTREE_OSNAME@|${OSTREE_OSNAME}|g' \
           -e 's|@OSTREE_BRANCHNAME@|${OSTREE_BRANCHNAME}|g' \
           ${D}${sysconfdir}/ota-agent/agent.toml
}

FILES:${PN} += "${systemd_system_unitdir} ${sysconfdir}/ota-agent"
