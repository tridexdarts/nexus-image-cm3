# nexus-image-cm3

Builds a DietPi image for the **Radxa CM3 IO board**.

The base is the official DietPi image for the Radxa ZERO 3, which has the same SoC (RK3566). Its Armbian kernel and bootloader are replaced with Radxa's own packages (the Radxa BSP):

| Package | Purpose |
|---|---|
| `linux-image-radxa-cm3-io` | Radxa kernel (`linux-image-*-rk2410-nocsf`) with the DTB `rk3566-radxa-cm3-io.dtb`, plus `radxa-overlays-dkms` |
| `linux-headers-radxa-cm3-io` | Kernel headers, needed for the DKMS overlays |
| `u-boot-radxa-cm3-io` | Bootloader, written to the boot area of the image (sectors 64 and 16384) |
| `radxa-firmware` | Wi-Fi and Bluetooth firmware |
| `radxa-archive-keyring` | Signing key of the Radxa repository |

apt pinning allows **only these packages** from the Radxa repositories. Everything else comes from Debian or DietPi. The rule lives in `/etc/apt/preferences.d/nexus-radxa`.

## Result

- **Tridex Nexus software** from `https://tridexdarts.github.io/nexus-apt/`: the `nexus` package with Wi-Fi setup through a captive portal (comitup, hotspot `Nexus-<nnn>`), a web panel (port 8080) and a web terminal (port 7681). New releases are installed automatically: `nexus-auto-upgrade.timer` starts `unattended-upgrade` every night between 04:00 and 05:00 Berlin time (missed runs are not caught up later), restricted to the Nexus repository (`/etc/apt/apt.conf.d/52nexus-unattended-upgrades`). Configurable in `config.env` (`NEXUS_PACKAGES`).
- Hostname `nexus`, user `tridex`, member of the hardware groups.
- **No login is possible until the first password is set.** In the image `tridex` has no password, no SSH keys and no passwordless `sudo`, and `root` is locked. The first password will be set by a captive portal later. Because the image contains no secrets, the repository and its releases are public.
- `root` is locked: no login over SSH or on the console. SSH only allows `tridex`.
- OpenSSH instead of Dropbear.
- The **DietPi first-run setup happens during the build.** Updates, DietPi settings, OpenSSH and `Automation_Custom_Script.sh` run in a booted container (`systemd-nspawn --boot`). Afterwards the build checks that `dietpi` is deleted and `root` is locked.
- **On first boot on the board**, only the following happens, **without internet access**:
  - The root partition and filesystem grow to the full size of the SD card or eMMC (`dietpi-fs_partition_resize`).
  - New SSH host keys and a new `machine-id` are generated (`nexus-firstboot.service`).

## Building the image

### With GitHub Actions (recommended)

- **Build only:** Under *Actions → "Build image" → Run workflow*, leave the field empty. The image is attached to the run as an artifact.
- **Publish a release:** Enter a tag such as `v1.0` in the same dialog, or push a tag:
  ```bash
  git tag v1.0 && git push origin v1.0
  ```

The workflow runs on a native arm64 runner (`ubuntu-24.04-arm`, free for public repositories), so no qemu emulation is needed. On an x86 runner the build still works with qemu, but takes much longer because the first-run setup is emulated (the action's time limit is 6 hours). The logs of the first-run setup are attached to the run as the `build-logs` artifact.

### Locally

```bash
sudo apt install qemu-user-static binfmt-support systemd-container curl xz-utils fdisk e2fsprogs
sudo ./build.sh
# Output: out/nexus.img.xz, out/nexus.img.xz.sha256
```

## Flashing the latest release

```bash
gh release download --repo tridexdarts/nexus-image-cm3 --pattern 'nexus.img.xz*'
sha256sum -c nexus.img.xz.sha256
xz -dc nexus.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

`/dev/sdX` is the SD card; check its name with `lsblk` first. balenaEtcher or Raspberry Pi Imager work as well.

Writing the image to the eMMC works the same way: boot the board from the SD card and use `of=/dev/mmcblk0` as the target. Remove the SD card afterwards, because the root filesystem has the same UUID on every copy.

## Customizing

All settings are in [`config.env`](config.env).

- **Newer DietPi version:** `DIETPI_IMAGE` stays the same, because DietPi updates the image under the same name. A new build picks up the current version automatically.
- **Newer Radxa kernel:** The meta packages always pull the latest kernel from the Radxa repository. On a running board it arrives through `apt upgrade`.

## Layout

| File | Contents |
|---|---|
| `build.sh` | Download, checksums, partitions, chroot, first-run container, bootloader, shrinking, compression |
| `files/chroot-setup.sh` | Runs in the aarch64 chroot: Radxa BSP, Armbian removal, `extlinux.conf`, SSH, Nexus packages, user, hostname |
| `files/nexus-firstboot*` | First-boot service: SSH host keys and `machine-id` |
| `files/nexus-auto-upgrade.*`, `files/52nexus-unattended-upgrades` | Nightly automatic updates of the Nexus packages (04:00-05:00 Europe/Berlin) |
| `files/nexus-build-firstrun.service`, `files/nexus-build-ping` | Build only: run the DietPi first-run setup non-interactively inside the container; replace `ping`, which GitHub runners block |
| `files/Automation_Custom_Script.sh` | Final step of the DietPi first-run setup: delete `dietpi`, lock `root` |
| `.github/workflows/build.yml` | Build, upload artifacts, publish releases |
