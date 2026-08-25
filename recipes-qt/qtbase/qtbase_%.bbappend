# meta-qt6's default PACKAGECONFIG has no eglfs, so no libqeglfs.so is built and
# QT_QPA_PLATFORM=eglfs fails at startup with "no Qt platform plugin could be
# initialized". eglfs over KMS/GBM is the right embedded path on a Pi 5 (vc4 KMS,
# no X, no compositor).
#
# vnc is kept deliberately: it lets the HMI be viewed from a laptop over the
# network during bring-up, without an HDMI monitor attached.
PACKAGECONFIG:append = " eglfs kms gbm vnc"
