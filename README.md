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
| `meta-openembedded` (meta-oe, meta-python, meta-networking) | `https://git.openembedded.org/meta-openembedded` | common dependencies |
| `meta-qt6` | `https://code.qt.io/yocto/meta-qt6.git` | QT 6 |
| `meta-updater` (layer name `sota`) | `https://github.com/uptane/meta-updater` | OSTree recipes, `image_types_ostree` / `image_types_ota` bbclasses, OSTree-aware wic partitioning, u-boot integration |
| BSP layer | vendor (`meta-raspberrypi`, `meta-ti`, `meta-freescale`, …) | board support |

Pin every layer to the same release branch. `scarthgap` (5.0 LTS) is the default in the
scaffold — see `DECISIONS.md` D3, because vendor BSPs often lag the LTS.

> **On meta-updater**: it ships OSTree *and* aktualizr (the Uptane client). This layer uses the
> OSTree half only — `ota-agent` replaces aktualizr. `conf/ota.conf` has the knobs that keep
> aktualizr out. If you later decide to use aktualizr instead (`DECISIONS.md` D1), reverse
> those three lines and delete `ota-agent`.
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
git clone <this-repo>  meta-ota-platform

source poky/oe-init-build-env build

bitbake-layers add-layer \
  ../meta-openembedded/meta-oe \
  ../meta-openembedded/meta-python \
  ../meta-openembedded/meta-networking \
  ../meta-qt6 \
  ../meta-updater \
  ../meta-raspberrypi \
  ../meta-ota-platform

cat ../meta-ota-platform/conf/ota.conf >> conf/local.conf
# edit conf/local.conf: MACHINE, OSTREE_REMOTE_URL, SSTATE_DIR, DL_DIR

bitbake ota-image
```

First build is hours. Every build after that should be minutes if `SSTATE_DIR` and `DL_DIR`
are on persistent storage — set them outside `build/` and share them with CI.

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
| `BUILD_REPRODUCIBLE_BINARIES` | stable commits across rebuilds | **load-bearing** — see below |
| `QT_HMI_PLATFORM` | `eglfs` / `wayland` / `linuxfb` | substituted into the HMI's systemd unit; must match the BSP's graphics stack |
| `IMAGE_FSTYPES` | `wic.gz` for flashing, `ostreepush` for publishing | |

### Reproducibility is not optional

Two builds of identical source must produce identical OSTree objects. If they do not, every
build rewrites files that did not really change, static deltas balloon to near-full-image size,
and the bandwidth argument for OSTree evaporates.

Reproducibility killers to watch for: `SRCREV = "${AUTOREV}"`, timestamps baked into binaries,
`__DATE__`/`__TIME__` in C++, build paths leaking into debug info, and non-deterministic file
ordering in custom `do_install` steps.

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
| `LIC_FILES_CHKSUM does not match` | expected on first build — copy the md5 bitbake prints |
| `unable to connect to git.yoctoproject.org: errno=Connection timed out` | port 9418 blocked — use https and set `url."https://".insteadOf git://` |
| Fetch failure hours into a build, one recipe only | that recipe's upstream host is down or blocked — enable the `PREMIRRORS` block in `conf/ota.conf` |
| App crashes writing a config file | writing under `/usr`; move to `/var` |
| App loses settings after every update | settings in `/etc` and the new commit changed that file, so the 3-way merge dropped them; move to `/var` |
| Update downloads are near full image size | reproducibility broken, or no static delta generated |
| Device boots old version after update | healthcheck never confirmed; check `bootcount`/`upgrade_available` |
| Black screen, HMI unit active | `QT_QPA_PLATFORM` doesn't match the BSP's graphics stack |
