# Arasaka

Immutable, A/B, OTA-updatable Arch Linux desktop distribution built around
COSMIC, with signed over-the-air updates delivered via RAUC.

## Highlights

- **Immutable A/B rootfs** — two raw slot partitions (`arasaka-slot-a` /
  `arasaka-slot-b`) beside a shared btrfs data partition (`arasaka-data`). A
  fresh install writes plain ext4 slots; the first OTA that targets a slot
  replaces it with a squashfs image carrying an appended dm-verity hash tree,
  verified block-by-block at every boot. Slots are replaced wholesale by
  updates; all persistent user and runtime state lives on `/data` and the
  writable `/boot`, and survives OTA slot swaps.
- **Signed OTA updates** — RAUC `verity` bundles signed with the OTA key,
  downloaded from a Backblaze B2 updates bucket, verified against a baked-in
  keyring, and installed to the inactive slot. No Arch mirrors at runtime.
- **systemd-boot with a custom RAUC backend** — slot switching is done by a
  boot handler that points `loader.conf`'s `default` at the new slot's entry,
  re-extracts the kernel/initramfs from the freshly-written slot into `/boot`,
  records their hashes, and marks slots good/bad. A failed or tampered boot
  falls back to the previous slot.
- **Automatic weekly updates** — `arasaka-update.timer` checks the signed
  update pointer, and `arasaka-reboot-after-update.timer` reboots into the new
  slot after a successful install.
- **COSMIC desktop, uutils coreutils, AppArmor + snap, Flatpak, CUPS,
  Bluetooth, Mesa** — the userland is built around a specific, opinionated
  package set (see `build.sh`).
- **Graphical installer** — a live ISO with Calamares installs to disk,
  creating the A/B layout, loader entries, and RAUC state.
- **Fully automated CI** — GitHub Actions bootstraps an Arch chroot, builds the
  rootfs, ISO, and signed OTA bundle, and publishes everything to Backblaze B2.

## Architecture

```
                 ┌──────────────────────────────┐
                 │         systemd-boot         │
                 │   loader/loader.conf         │
                 │   entries/arasaka-a.conf     │  rauc.slot=A
                 │   entries/arasaka-b.conf     │  rauc.slot=B
                 └──────────────┬───────────────┘
                                │
        ┌───────────────────────┴────────────────────────┐
        │                                                │
┌───────▼────────┐                              ┌────────▼───────┐
│ rootfs.0 (A)   │  /dev/disk/by-partlabel/     │ rootfs.1 (B)   │
│ squashfs+      │  arasaka-slot-a              │ squashfs+      │
│ dm-verity      │  verified root               │ dm-verity      │
│ (squashfs img  │  (squashfs opened via        │ (squashfs img  │
│  + hash tree)  │   dm-verity at boot)         │  + hash tree)  │
└───────┬────────┘                              └────────┬───────┘
        │            ┌────────────────────────┐          │
        └────────────►      arasaka-data      ◄──────────┘
                     │      btrfs (rw)         │
                     │  /data/rauc  RAUC state│
                     │  @flatpak @snap @log   │  persists across
                     │  @cache @home ...     │  slot swaps
                     └────────────────────────┘
```

- **Slots**: two raw rootfs slots, selected by `rauc.slot=A|B` on the kernel
  command line and mounted read-only by the initramfs A/B hook. Each slot holds
  either a fresh-install ext4 filesystem or (once updated) a squashfs image
  with an appended dm-verity hash tree. When `/boot/ab/verity-<slot>.conf`
  exists (root hash + hash offset written by the bundle's post-install hook)
  the hook opens the slot with `veritysetup` and mounts `/dev/mapper`; plain
  ext4 is mounted only when no verity conf exists. A dm-verity open failure
  never falls back to an unverified mount — the rollback path takes over.
  Slots are immutable: updates replace a whole slot, and no user data lives on
  them — persistent state lives on the shared btrfs data partition (`/data`),
  which survives every update.
- **RAUC**: `config/rauc/system.conf` describes the slots and a custom
  `bootloader=custom` backend (`/usr/lib/rauc/rauc-boot-handler.sh`) that
  performs the systemd-boot slot switching, kernel/initramfs hash recording,
  and good/bad slot tracking.
- **Boot verification**: `arasaka-verify-boot.sh` compares the actually booted
  kernel/initramfs against the hashes recorded when the slot was made primary
  and marks the slot BAD on mismatch; `arasaka-rauc-mark-good.service` confirms
  a healthy boot once multi-user.target is reached.

## OTA update flow

1. `arasaka-ota-update.sh` fetches `update/stable/latest.json` + its detached
   signature from the updates bucket.
2. The pointer signature is verified against `/etc/arasaka/ota-pub.pem`
   (extracted from the signing certificate at build time).
3. If the advertised version is newer than the installed one, the referenced
   `.raucb` bundle is downloaded and its SHA-256 is checked.
4. `rauc install` verifies the bundle CMS signature against
   `/etc/rauc/keyring.pem` and the `compatible=arasaka-x86_64` string, writes
   the new squashfs slot image to the inactive slot, and its post-install hook
   records the root hash in `/boot/ab/verity-<slot>.conf` before the slot is
   made primary.
5. On reboot the initramfs opens the slot through dm-verity and verifies every
   block; a failed or tampered boot rolls back to the previous slot, and the
   custom backend marks slots good/bad.

## Repository layout

| Path | Purpose |
| --- | --- |
| `build.sh` | Rootfs builder: bootstrap, packages, immutable A/B setup, RAUC config, systemd units. |
| `create-iso.sh` | Builds the bootable live ISO with the Calamares installer. |
| `build-bundle.sh` | Packs the built rootfs into a signed RAUC verity bundle. |
| `install-to-disk.sh` | Disk installer logic: partitions, A/B slots, loader entries, RAUC state. |
| `cleanup-stale-rootfs.sh` | Removes stale files from a previously built rootfs before re-running `build.sh`. |
| `config/rauc/` | RAUC `system.conf`, the device CA (`ca.crt`) and OTA signing cert (`signing.crt`). |
| `config/calamares/` | Calamares installer branding, modules, and scripts. |
| `scripts/` | RAUC boot handler + system-info, OTA update engine, boot verification, boot-succeeded confirmation, data persistence, update reboot, read-only remount, install hardening. |
| `systemd/` | Units + timers for updates, update reboot, boot verification, mark-good, boot-succeeded, data persistence, and read-only remount. |
| `initcpio/` | Initramfs A/B + dm-verity hooks: read-only slot mount (verity or ext4), `/var` overlay on `/data`, per-device machine-id bind, boot-attempt rollback markers. |
| `aur/` | Local AUR-style packages: calamares, snapd, system76-power, findutils. |
| `branding/` | Logo and product artwork. |
| `plymouth/` | Boot splash theme. |
| `.github/workflows/build-iso.yml` | CI: build ISO + OTA bundle, upload to B2. |

## Building locally

The build scripts require a **real Arch Linux machine** running as a non-root
user with sudo, and peak at roughly 35 GB of disk. Sudo is never hardcoded:
provide the password via the `ARASAKA_SUDO_PASSWORD` environment variable or a
gitignored `build.conf` (see `build.conf.example`).

```sh
cp build.conf.example build.conf   # edit and set ARASAKA_SUDO_PASSWORD

./build.sh          # build the rootfs into build/rootfs
./create-iso.sh     # build the live ISO (Calamares installer)
```

To also produce a signed OTA bundle you need the OTA signing material:

```sh
OTA_SIGNING_KEY=/path/to/signing.key \
OTA_SIGNING_CERT=config/rauc/signing.crt \
./build-bundle.sh   # writes build/arasaka-<version>.raucb
```

> The OTA signing key must remain private. Only the public CA and signing
> certificates are committed under `config/rauc/`.

## Continuous integration

`.github/workflows/build-iso.yml` runs weekly (and on manual dispatch):

1. Frees space on an `ubuntu-latest` runner and bootstraps an Arch chroot.
2. Builds the rootfs, the ISO, and the signed OTA bundle inside the chroot.
3. Copies the ISO and bundle out.
4. Writes and self-verifies the signed update pointer (`latest.json` + `.sig`).
5. Uploads the ISO to the main B2 bucket (keeping only the newest) and the
   bundle + pointer to the updates bucket — the bundle is uploaded first and
   the pointer last, so devices can never resolve a half-uploaded bundle.

Required repository secrets:

| Secret | Description |
| --- | --- |
| `B2_APPLICATION_KEY_ID`, `B2_APPLICATION_KEY`, `B2_BUCKET` | Backblaze B2 credentials for the ISO bucket. |
| `B2_UPDATES_APPLICATION_KEY_ID`, `B2_UPDATES_APPLICATION_KEY`, `B2_UPDATES_BUCKET` | Backblaze B2 credentials for the updates bucket (e.g. `arasaka-updates`). |
| `OTA_SIGNING_KEY` | Private key matching `config/rauc/signing.crt`. |
| `OTA_SIGNING_CERT` | The OTA signing certificate. |

