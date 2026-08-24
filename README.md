# meta-ota-platform

Yocto/OpenEmbedded layer producing an **OSTree-managed** embedded Linux image containing the
HomeAuto HMI (`HomeAutomationGUI`) and the OTA update client (`ota-agent`).

This layer is the *build* half of the OTA system. The *serve* half is `ota-server`, the
*apply* half is `ota-agent`.

---

## What "OSTree-managed" means here

A normal Yocto image is a filesystem you flash once. An OSTree image is a filesystem checked
out from a content-addressed object store, which means:

- `/usr` is **read-only**. Applications that write there will fail at runtime, not build time.
- Multiple *deployments* (checked-out commits) coexist on one partition. Booting a different
  one is a bootloader choice, not a reflash.
- `/etc` is 3-way merged on update: your changes to a config file survive, unless the new
  commit also changed that file.
- `/var` is persistent and never touched by updates. All application state belongs there.
- An update is a `pull` of only the objects that differ, then an atomic swap of a symlink.
  Rollback is booting the previous deployment — the files are still on disk.

Every constraint the other repos live under traces back to this list.

---

## Layer dependencies

| Layer | Source | Purpose |
|---|---|---|
| `poky` (meta, meta-poky, meta-yocto-bsp) | `https://git.yoctoproject.org/poky` | base build system |
| `meta-openembedded` (meta-oe, meta-python, meta-networking, **meta-filesystems**) | `https://git.openembedded.org/meta-openembedded` | common dependencies; `meta-filesystems` is a hard dependency of `sota`, not optional |
| `meta-qt6` | `https://code.qt.io/yocto/meta-qt6.git` | QT 6 |
| `meta-updater` (layer name `sota`) | `https://github.com/uptane/meta-updater` | OSTree recipes, `image_types_ostree` / `image_types_ota` bbclasses, OSTree-aware wic partitioning, u-boot integration |
| BSP layer | vendor (`meta-raspberrypi`, `meta-ti`, `meta-freescale`, …) | board support |

Pin every layer to the same release branch. `scarthgap` (5.0 LTS) is the default in the
scaffold, and here it is a **ceiling, not a preference**: `meta-updater` declares
`LAYERSERIES_COMPAT_sota = "nanbield scarthgap"` and `meta-raspberrypi` the same. Moving to a
newer Yocto release means those two layers must gain support first. `meta-qt6` is compatible
much further out (kirkstone → whinlatter), so it is not the constraint. See `DECISIONS.md` D3.

Layer dependencies are declared, so `bitbake-layers add-layer` refuses the whole set if one is
missing rather than failing later — `ERROR: Layer 'sota' depends on layer 'filesystems-layer',
but this layer is not enabled` means exactly what it says. Verify the result with
`bitbake-layers show-layers`; the expected list is 11 layers, `ota-platform` last at
priority 10.

> **On meta-updater**: adding the layer and the `sota` `DISTRO_FEATURE` does nothing on its
> own — its `conf/layer.conf` never inherits `sota.bbclass`. `conf/ota.conf` carries the
> `INHERIT += "sota"` that actually activates OSTree image types, the OSTree-aware `.wks` and
> the u-boot wiring.
>
> It ships OSTree *and* aktualizr (the Uptane client). This layer uses the OSTree half only —
> `ota-agent` replaces aktualizr — so `conf/ota.conf` also strips the image types that pull in
> `aktualizr-native` and `garage-sign`. If you later adopt aktualizr instead
> (`DECISIONS.md` D1), drop those `:remove` lines and delete `ota-agent`.
>
> Use the `uptane/meta-updater` repo. The older `advancedtelematic/meta-updater` is dead.

---

## Setup

```bash
mkdir -p ~/ota-build && cd ~/ota-build

# https, not git:// — port 9418 is blocked on most corporate/university networks.
git clone -b scarthgap https://git.yoctoproject.org/poky
git clone -b scarthgap https://git.openembedded.org/meta-openembedded
git clone -b 6.8       https://code.qt.io/yocto/meta-qt6.git
git clone -b scarthgap https://github.com/uptane/meta-updater
git clone -b scarthgap https://github.com/agherzan/meta-raspberrypi   # or your BSP
# Symlink, do not copy. A copy silently becomes a second source of truth and you
# end up debugging edits that bitbake never sees.
ln -s /path/to/meta-ota-platform meta-ota-platform

source poky/oe-init-build-env build

bitbake-layers add-layer \
  ../meta-openembedded/meta-oe \
  ../meta-openembedded/meta-python \
  ../meta-openembedded/meta-networking \
  ../meta-openembedded/meta-filesystems \
  ../meta-qt6 \
  ../meta-updater \
  ../meta-raspberrypi \
  ../meta-ota-platform

cat ../meta-ota-platform/conf/ota.conf >> conf/local.conf
# edit conf/local.conf: MACHINE, OSTREE_REMOTE_URL, SSTATE_DIR, DL_DIR

bitbake -p          # parse only -- catches config errors in ~1 min instead of 4 h
bitbake ota-image
```

Always `bitbake -p` after touching `local.conf` or a recipe. Config mistakes here surface as
parse errors across hundreds of unrelated recipes, and finding that out an hour into a build is
the expensive way to learn it.

Verify the OSTree wiring took effect before building:

```bash
bitbake -e ota-image | grep -E '^(IMAGE_FSTYPES|OSTREE_BRANCHNAME|OSTREE_OSNAME|OSTREE_BOOTLOADER|WKS_FILE)='
```

Expected: `ota-ext4` and `ostree.tar.bz2` present, `ostreepush`/`garagesign`/`garagecheck`
absent, `WKS_FILE=sdimage-sota.wks`, `OSTREE_BOOTLOADER=u-boot`. If `WKS_FILE` is the board
default instead, `INHERIT += "sota"` is missing and nothing OSTree-related is active.

First build is hours. Every build after that should be minutes if `SSTATE_DIR` and `DL_DIR`
are on persistent storage — set them outside `build/` and share them with CI.

### `User namespaces are not usable by BitBake` (Ubuntu 24.04+)

bitbake uses a user namespace to isolate the network during builds, and checks up front that it
works (`meta/classes-global/sanity.bbclass`). Ubuntu 24.04 ships
`kernel.apparmor_restrict_unprivileged_userns=1`, which puts an unconfined process that creates
a userns into the `unprivileged_userns` AppArmor profile — that profile denies `CAP_SYS_ADMIN`,
so the `unshare()` succeeds but writing `uid_map` fails and the process is left as `nobody`.
That is precisely the case the check detects.

Confirm it is what you are hitting:

```bash
journalctl -k --since -10min | grep -i 'apparmor.*userns\|unprivileged_userns'
```

A `DENIED ... profile="unprivileged_userns" ... capability=21 capname="sys_admin"` line next to
`comm="Cooker"` is this bug.

Confusing wrinkle: it can *work* in some terminals and not others. A snap-packaged VS Code runs
its integrated terminal under `snap.code.code`, which ships in **complain** mode, so userns is
merely logged rather than denied. Builds that succeed there and fail in a plain terminal are
showing you AppArmor confinement, not anything about your build tree. Do not rely on it — a
snap update flipping that profile to enforce breaks it again.

**A profile scoped to `bitbake` does not work, and it is worth understanding why.**
`poky/bitbake/bin/bitbake` starts with `#!/usr/bin/env python3`, so the binary actually exec'd
is `/usr/bin/python3.12`. AppArmor attaches profiles by the exec'd path, so a profile matching
`poky/bitbake/bin/*` never applies. The `Cooker` process name in the audit log is cosmetic —
`bb.utils.set_process_name()` changes `comm`, not the executable.

That leaves two options, both needing root:

```bash
# Global toggle. Takes effect immediately, no reboot. Revert by setting it back to 1.
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/60-yocto.conf
```

```bash
# Nominally scoped: grant userns to the Python interpreter.
sudo tee /etc/apparmor.d/python3-userns >/dev/null <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>
profile python3-userns /usr/bin/python3.12 flags=(unconfined) {
  userns,
  include if exists <local/python3-userns>
}
PROFILE
sudo apparmor_parser -r /etc/apparmor.d/python3-userns
```

The second looks tighter but is not by much: it grants unprivileged user namespaces to *every*
Python script on the machine, which is the same interpreter most local exploit tooling would
use anyway. It also breaks whenever Ubuntu bumps the Python minor version and the path changes.

Understand what either one gives up. Ubuntu restricts unprivileged user namespaces because they
are a recurring local privilege-escalation and sandbox-escape surface; disabling the restriction
re-exposes that for the whole system, not just for builds. On a personal development machine
that is usually an acceptable trade. On a shared or internet-facing host, it is not — put the
build in a VM or container instead.

### Build host sizing

`conf/ota.conf` caps `BB_NUMBER_THREADS` and `PARALLEL_MAKE` at 8 each. Do not remove those
lines to "speed things up": bitbake defaults both to `nproc`, and their product is the real
process count — 24 cores means up to 576 concurrent compilers. Yocto runs out of RAM far
before it runs out of CPU, and the failure mode is silent corruption rather than a clean error
(see the failures table). Budget roughly 2 GB of RAM per parallel compile, and give the host
real swap — a 1 GB swap partition on a 30 GB machine is not a safety net.

### If `git://` is blocked on your network

Port 9418 is firewalled almost everywhere. Cloning over https fixes the clones above, but
bitbake fetches hundreds of recipes and many still carry bare `git://` URLs in their `SRC_URI`,
so the same failure reappears mid-build hours later. Rewrite the protocol globally once:

```bash
git config --global url."https://".insteadOf git://
```

bitbake's git fetcher shells out to `git`, so this covers every recipe without editing any of
them. Verify before starting a long build:

```bash
git ls-remote https://git.yoctoproject.org/poky scarthgap    # must print a hash
```

`conf/ota.conf` also carries a commented `PREMIRRORS` block pointing at the Yocto source mirror
over https, as a fallback for recipes whose upstream host is unreachable rather than merely
using the wrong protocol.

---

## Configuration surface (`conf/ota.conf`)

The file is a `local.conf` fragment, not a distro. Everything in it is a decision you may need
to revisit.

| Variable | Meaning | Watch out |
|---|---|---|
| `DISTRO_FEATURES += "sota"` | activates meta-updater's OSTree integration | also forces systemd |
| `OSTREE_BRANCHNAME` | the ref devices track, e.g. `raspberrypi4-64-main` | renaming after shipping means migrating every device's remote config |
| `OSTREE_OSNAME` | OSTree "stateroot" name, appears in `/ostree/deploy/<osname>` | changing it orphans existing deployments |
| `OSTREE_REPO` | local repo bitbake commits into | lives in `DEPLOY_DIR_IMAGE`; CI pushes from here |
| `OSTREE_REMOTE_URL` | baked into the agent config as its default remote | must be reachable from the device, not from your laptop |
| `SOTA_CLIENT = ""` | keeps aktualizr out | reverse if adopting aktualizr |
| *(reproducibility)* | stable commits across rebuilds | **load-bearing**, but nothing to set — it is unconditional since kirkstone. See below |
| `QT_HMI_PLATFORM` | `eglfs` / `wayland` / `linuxfb` | substituted into the HMI's systemd unit; must match the BSP's graphics stack |
| `IMAGE_FSTYPES` | `wic.gz` for flashing, `ostreepush` for publishing | |

### Reproducibility is not optional

Two builds of identical source must produce identical OSTree objects. If they do not, every
build rewrites files that did not really change, static deltas balloon to near-full-image size,
and the bandwidth argument for OSTree evaporates.

There is no switch to turn on. Since kirkstone, `base.bbclass` handles `SOURCE_DATE_EPOCH`
unconditionally; `BUILD_REPRODUCIBLE_BINARIES` and `reproducible_build.bbclass` were both
removed, and referencing either now aborts parsing:

```
ParseError in configuration INHERITs: Could not inherit file classes/reproducible_build.bbclass
```

The work is in not breaking it. Reproducibility killers to watch for: `SRCREV = "${AUTOREV}"`,
timestamps baked into binaries, `__DATE__`/`__TIME__` in C++, build paths leaking into debug
info, and non-deterministic file ordering in custom `do_install` steps.

Pin `SRCREV` to a real commit hash for anything released.

---

## Recipes

```
recipes-core/images/ota-image.bb        production image
recipes-core/images/ota-image-dev.bb    + debug tools, debug-tweaks
recipes-qt/homeautomationgui/           fetches and builds the HomeAuto HMI, installs its unit
recipes-support/ota-agent/              fetches and builds the agent, installs units + config
recipes-ostree/                         bbappends for bootloader/rollback integration
```

### `homeautomationgui_git.bb`

Builds https://github.com/AffanUlHaqKhan/HomeAutomationGUI with `cmake_qt6`. Upstream's CMake
target is `appHomeAuto`, so the installed binary is `/usr/bin/appHomeAuto` while the recipe and
package are named after the repo.

`qt_add_qml_module` compiles the QML into the executable's resources (`main.cpp` loads
`qrc:/HomeAuto/qml/Main.qml`), so the binary is the only installed artifact — no QML files ship
separately. If that ever changes upstream, `FILES:${PN}` here must change with it.

Installs `homeautomationgui.service`, substituting `QT_HMI_PLATFORM` into its
`QT_QPA_PLATFORM=` line, and creates `/var/lib/homeautomationgui` for writable state.

`LICENSE = "MIT"`, checksummed against the app repo's `LICENSE` file. If that file is ever
edited — even the copyright year — bitbake fails with a checksum mismatch and prints the new
md5 to paste back in. That is the intended behaviour: it forces a human to notice licence
changes rather than shipping them silently.

The Qt runtime in `ota-image.bb` is trimmed to `qtbase` + `qtdeclarative`: in Qt 6 Quick
Controls lives inside qtdeclarative, and the app draws its icons and charts with QML `Canvas`,
so `qtsvg` and Qt Charts are not needed. Image size is update bandwidth for every device —
keep it that way.

### `ota-agent_git.bb`

The recipe substitutes `@OSTREE_REMOTE_URL@`, `@OSTREE_OSNAME@` and `@OSTREE_BRANCHNAME@` into
`/etc/ota-agent/agent.toml` at install time. The agent source repo therefore stays environment
agnostic — dev, staging and production differ only in this layer's config.

### Before the first build

- `ota-agent_git.bb` still has a `<you>` placeholder in its `SRC_URI` and a
  `LIC_FILES_CHKSUM` to fill — bitbake prints the correct md5 when it fails the first time.
  (Its repo already carries the same MIT `LICENSE`, so the md5 will be
  `ea4c82615fa45f1b037a425e28147b3d` unless the copyright line is edited.)
- `homeautomationgui_git.bb` has a real URL and a pinned `SRCREV`. Bump that hash when the app
  changes, or the image keeps building the old commit.

---

## Build outputs

In `tmp/deploy/images/<MACHINE>/`:

| Artifact | Use |
|---|---|
| `ota-image-<machine>.wic.gz` + `.bmap` | factory flash / first install (`bmaptool copy`) |
| `ostree_repo/` | the object store CI publishes to the server |
| `ota-image-<machine>.ostree.tar.bz2` | archived commit, useful for offline transfer |

Inspect what you built:

```bash
ostree --repo=tmp/deploy/images/$MACHINE/ostree_repo refs
ostree --repo=tmp/deploy/images/$MACHINE/ostree_repo log $OSTREE_BRANCHNAME
ostree --repo=tmp/deploy/images/$MACHINE/ostree_repo ls -R <commit> /usr/bin | grep HomeAuto
```

---

## Publishing a build

```bash
export OTA_PUSH_TOKEN=...            # operator token for the server API
export OTA_RSYNC_TARGET=ota@host:/srv/ostree-repo
export OSTREE_GPG_KEY_ID=...         # optional but expected in production
export BUILD_VERSION=v1.2.3

./scripts/push-ostree.sh \
    tmp/deploy/images/$MACHINE/ostree_repo \
    https://ota.example.com/repo \
    "$OSTREE_BRANCHNAME"
```

The script signs the commit, updates the repo summary, generates a static delta from the
currently published commit, rsyncs objects, then registers the target with the API.

rsync is deliberate: OSTree objects are content-addressed and immutable, so merging two repos
by copying files is safe and idempotent. Order matters though — objects must land before the
ref that points at them, or a device polling mid-publish sees a ref it cannot resolve. rsync's
default alphabetical traversal happens to put `objects/` before `refs/`; do not "optimise" that
away.

---

## Rollback

Handled at the bootloader, documented in [docs/rollback.md](docs/rollback.md). Summary: u-boot
counts boot attempts, the agent clears the counter only after a healthcheck passes, and a
device that cannot pass the healthcheck falls back to the previous deployment on its own.

This is the part that is board-specific and the part most likely to be silently broken. Test it
by deliberately shipping a commit whose HMI unit fails to start.

---

## Common failures

| Symptom | Cause |
|---|---|
| `Nothing PROVIDES 'homeautomationgui'` | layer not added, or recipe filename doesn't match `PN` |
| `Layer 'sota' depends on layer 'filesystems-layer'` | add `meta-openembedded/meta-filesystems` |
| `Could not inherit file classes/reproducible_build.bbclass` | class removed upstream; delete the `INHERIT` and `BUILD_REPRODUCIBLE_BINARIES` lines from `local.conf` |
| `Could not inherit file classes/cmake_qt6.bbclass` | meta-qt6's class is `qt6-cmake` |
| `No IMAGE_CMD defined for IMAGE_FSTYPES entry 'ostreepush'` on every image in every layer | `ostreepush` set globally in `local.conf`; it only exists under `sota.bbclass`. Remove it — `sota.bbclass` adds it itself |
| `ExpansionError ... fetcher_hashes_dummyfunc ... git ls-remote ... exit code 128` | a recipe uses `SRCREV = "${AUTOREV}"` with an unreachable `SRC_URI`; `AUTOREV` hits the network at parse time. Pin the hash |
| Edits to this layer have no effect | the layer in `bblayers.conf` is a *copy*, not your repo — symlink it |
| `User namespaces are not usable by BitBake, possibly due to AppArmor` | Ubuntu 24.04 userns restriction — see the section above. Note it may work in a snap VS Code terminal and fail elsewhere |
| Build dies with disk-full, or `tmp` has eaten the partition | `tmp/` reaches ~100 GB. Put `SSTATE_DIR` and `DL_DIR` *outside* the build dir so `rm -rf tmp` costs minutes, not hours |
| `undefined symbol: _ZTIN6icu_74...MeasureFormatE`, or any link error naming a symbol that obviously exists | OOM truncated object files to 0 bytes. `find <workdir> -name '*.o' -size 0` to confirm. Cap `BB_NUMBER_THREADS`/`PARALLEL_MAKE`, then `bitbake -c cleansstate <recipe>` — a plain retry relinks the same corrupt objects |
| Random `do_compile` failures in different recipes each run | same cause: memory pressure. See the build-host section of `conf/ota.conf` |
| `No rule to make target '.../overlays/uart0-rpi4.dtbo'` | meta-updater bug — `sota_raspberrypi.bbclass` names an overlay the RPi kernel no longer ships. Overridden in `conf/ota.conf` |
| `Layer ... is not compatible with the core layer` | a layer's branch does not match poky's — check `LAYERSERIES_COMPAT` in its `conf/layer.conf` |
| `LIC_FILES_CHKSUM does not match` | expected on first build — copy the md5 bitbake prints |
| `unable to connect to git.yoctoproject.org: errno=Connection timed out` | port 9418 blocked — use https and set `url."https://".insteadOf git://` |
| Fetch failure hours into a build, one recipe only | that recipe's upstream host is down or blocked — enable the `PREMIRRORS` block in `conf/ota.conf` |
| App crashes writing a config file | writing under `/usr`; move to `/var` |
| App loses settings after every update | settings in `/etc` and the new commit changed that file, so the 3-way merge dropped them; move to `/var` |
| Update downloads are near full image size | reproducibility broken, or no static delta generated |
| Device boots old version after update | healthcheck never confirmed; check `bootcount`/`upgrade_available` |
| Black screen, HMI unit active | `QT_QPA_PLATFORM` doesn't match the BSP's graphics stack |
