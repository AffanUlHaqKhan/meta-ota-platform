SUMMARY = "OSTree-updatable image with the HomeAuto HMI and OTA agent"
LICENSE = "MIT"

require recipes-core/images/core-image-minimal.bb

inherit core-image

IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL:append = " \
    homeautomationgui \
    ota-agent \
    ostree \
    ca-certificates \
    openssl \
    util-linux \
    e2fsprogs \
    "

# Qt 6 runtime for the HMI. HomeAuto links Quick, Gui, Qml and QuickControls2 —
# in Qt 6 all four live in qtbase + qtdeclarative. It draws its icons and charts
# with QML Canvas, so no qtsvg and no qtcharts.
IMAGE_INSTALL:append = " \
    qtbase \
    qtdeclarative \
    "

IMAGE_ROOTFS_EXTRA_SPACE = "524288"
