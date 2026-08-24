SUMMARY = "Development variant: debug tools, no read-only rootfs"
LICENSE = "MIT"

require ota-image.bb

IMAGE_FEATURES += "debug-tweaks tools-debug tools-profile"

IMAGE_INSTALL:append = " \
    gdbserver \
    strace \
    curl \
    vim \
    "
