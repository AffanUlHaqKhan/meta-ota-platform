SUMMARY = "HomeAuto — Qt 6 / QML home automation HMI"
DESCRIPTION = "Device HMI: lighting, watering and climate control pages, QML Canvas visuals, \
C++ QAbstractListModel backends. Installed as /usr/bin/appHomeAuto."
HOMEPAGE = "https://github.com/AffanUlHaqKhan/HomeAutomationGUI"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=ea4c82615fa45f1b037a425e28147b3d"

# Qt 6 ships Quick Controls inside qtdeclarative; no separate qtquickcontrols2 recipe.
# No qtsvg / qtcharts — icons and charts are drawn with QML Canvas.
DEPENDS = "qtbase qtdeclarative qtdeclarative-native"

SRC_URI = "git://github.com/AffanUlHaqKhan/HomeAutomationGUI.git;protocol=https;branch=main \
           file://homeautomationgui.service \
           "

# Pin for releases. AUTOREV breaks reproducibility, which breaks small OSTree deltas.
SRCREV = "f7e95a997032adaa50d6a44b7171f51c33254eb3"
PV = "1.0+git${SRCPV}"

S = "${WORKDIR}/git"

inherit cmake_qt6 systemd

EXTRA_OECMAKE = "-DCMAKE_BUILD_TYPE=Release"

# Upstream target is 'appHomeAuto'; the recipe/package is named after the repo.
SYSTEMD_SERVICE:${PN} = "homeautomationgui.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/homeautomationgui.service ${D}${systemd_system_unitdir}/

    # Graphics platform comes from the build config, not the app repo.
    sed -i -e 's|@QT_QPA_PLATFORM@|${QT_HMI_PLATFORM}|g' \
           ${D}${systemd_system_unitdir}/homeautomationgui.service

    # Writable state lives in /var — /usr is read-only under OSTree.
    install -d ${D}${localstatedir}/lib/homeautomationgui
}

FILES:${PN} += " \
    ${systemd_system_unitdir} \
    ${localstatedir}/lib/homeautomationgui \
    "

# QML is compiled into the executable's resources by qt_add_qml_module, so the
# binary is the only installed artifact. If that changes upstream, extend FILES.
