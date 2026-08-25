# Generates the Raspberry Pi 5 cmdline.txt from the OSTree boot loader entry.
#
# Image-only class -- pulled in via IMAGE_CLASSES from sota_raspberrypi5.bbclass,
# never inherited globally.

# Generate cmdline.txt from the boot loader entry OSTree just wrote.
#
# With sysroot.bootloader=none OSTree writes no bootloader config, but it still
# emits a Boot Loader Spec entry at boot/loader/entries/ostree-N.conf whose
# `options` line is the authoritative kernel command line, ostree= karg and all.
# Reading it is more robust than recomputing the deployment path ourselves.
python do_write_ostree_cmdline() {
    import glob, os, re

    sysroot = d.getVar('OTA_SYSROOT')
    entries = sorted(glob.glob(os.path.join(sysroot, 'boot/loader/entries/ostree-*.conf')))
    if not entries:
        bb.fatal("No OSTree boot loader entry under %s/boot/loader/entries. "
                 "do_image_ota must run before this task." % sysroot)
    if len(entries) > 1:
        bb.warn("Multiple OSTree boot entries found; using the first: %s" % entries[0])

    options = None
    for line in open(entries[0]):
        if line.startswith('options '):
            options = line[len('options '):].strip()
            break
    if not options:
        bb.fatal("No 'options' line in %s" % entries[0])
    if 'ostree=' not in options:
        bb.fatal("Boot entry %s has no ostree= karg; the image would not boot "
                 "into a deployment." % entries[0])

    outdir = os.path.join(d.getVar('DEPLOY_DIR_IMAGE'), 'ostree-cmdline')
    bb.utils.mkdirhier(outdir)
    with open(os.path.join(outdir, 'cmdline.txt'), 'w') as f:
        f.write(options + "\n")
    bb.note("Wrote OSTree cmdline.txt: %s" % options)
}

# Must run after do_image_ota (which creates the sysroot and the boot entry) and
# before do_image_wic (which copies IMAGE_BOOT_FILES into the FAT partition).
addtask write_ostree_cmdline after do_image_ota before do_image_wic
do_write_ostree_cmdline[dirs] = "${DEPLOY_DIR_IMAGE}"
