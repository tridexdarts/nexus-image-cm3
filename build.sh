#!/bin/bash
# Builds the nexus image for the Radxa CM3 IO board:
#   official DietPi image (Radxa ZERO 3, RK3566)
#   + Radxa BSP (kernel, U-Boot, firmware) instead of the Armbian kernel
#   + hostname/user/SSH hardening + first-boot automation
#   -> out/nexus.img.xz
#
# Usage:         sudo ./build.sh
# Requirements (Ubuntu/Debian):
#   sudo apt install qemu-user-static binfmt-support systemd-container curl xz-utils fdisk e2fsprogs
#   (qemu is not needed on an arm64 host)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=config.env
. ./config.env

log() { echo -e "\e[1;32m[build]\e[0m $*"; }
die() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
for c in curl xz sfdisk e2fsck resize2fs dumpe2fs losetup blkid sha256sum chroot systemd-nspawn; do
	command -v "$c" >/dev/null || die "Missing program: $c (see requirements at the top of this script)"
done
if [[ $(uname -m) != aarch64 ]]; then
	[[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] || die "aarch64 emulation missing: sudo apt install qemu-user-static binfmt-support"
	grep -q '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 || die "qemu-aarch64 is registered without the 'F' flag (install qemu-user-static)"
fi

WORK=${WORK:-$PWD/work}
OUT=${OUT:-$PWD/out}
MNT=$WORK/mnt
IMG=$WORK/$IMAGE_NAME.img
LOOP=
NSPAWN_PID=
mkdir -p "$WORK" "$OUT" "$MNT"

cleanup() {
	set +e
	# Keep DietPi's first-run log for the build-logs artifact, also on failure or cancellation
	[[ -f $MNT/var/lib/dietpi/logs/dietpi-firstrun-setup.log ]] && cp "$MNT/var/lib/dietpi/logs/dietpi-firstrun-setup.log" "$OUT/"
	if [[ $NSPAWN_PID ]]; then kill -TERM "$NSPAWN_PID"; sleep 15; kill -KILL "$NSPAWN_PID" 2>/dev/null; wait "$NSPAWN_PID" 2>/dev/null; fi
	if mountpoint -q "$MNT"; then umount -R "$MNT" || umount -lR "$MNT"; fi
	[[ $LOOP ]] && losetup -d "$LOOP"
}
trap cleanup EXIT

attach() { LOOP=$(losetup -fP --show "$IMG"); udevadm settle 2>/dev/null || sleep 2; ROOT_DEV=${LOOP}p1; }
detach() { losetup -d "$LOOP"; LOOP=; }
fsck_root() { e2fsck -fy "$ROOT_DEV" >/dev/null || [[ $? -le 1 ]]; }

# ---------------------------------------------------------------------------
log "1/9 Downloading DietPi image: $DIETPI_IMAGE"
if [[ ! -f $WORK/$DIETPI_IMAGE ]]; then
	curl -fL --retry 3 -o "$WORK/$DIETPI_IMAGE.part" "$DIETPI_URL/$DIETPI_IMAGE"
	mv "$WORK/$DIETPI_IMAGE.part" "$WORK/$DIETPI_IMAGE"
fi
curl -fsSL --retry 3 -o "$WORK/$DIETPI_IMAGE.sha256" "$DIETPI_URL/$DIETPI_IMAGE.sha256"
expected=$(awk '{print $1}' "$WORK/$DIETPI_IMAGE.sha256")
actual=$(sha256sum "$WORK/$DIETPI_IMAGE" | awk '{print $1}')
if [[ $expected != "$actual" ]]; then
	rm -f "$WORK/$DIETPI_IMAGE"
	die "Checksum of the DietPi image does not match (file deleted, please run again)"
fi
log "Checksum OK"

curl -fsSL --retry 3 -o "$WORK/radxa-archive-keyring.deb" "$RADXA_KEYRING_URL"
echo "$RADXA_KEYRING_SHA256  $WORK/radxa-archive-keyring.deb" | sha256sum -c --quiet - \
	|| die "Checksum of the Radxa keyring does not match"
curl -fsSL --retry 3 -o "$WORK/nexus-archive-keyring.deb" "$NEXUS_KEYRING_URL"
if [[ $NEXUS_KEYRING_SHA256 ]]; then
	echo "$NEXUS_KEYRING_SHA256  $WORK/nexus-archive-keyring.deb" | sha256sum -c --quiet - \
		|| die "Checksum of the Nexus keyring does not match"
fi

# ---------------------------------------------------------------------------
log "2/9 Unpacking, removing the DIETPISETUP partition, growing root by $BUILD_GROW_MIB MiB"
xz -T0 -dc "$WORK/$DIETPI_IMAGE" > "$IMG"
[[ $(sfdisk -d "$IMG" | awk -F': ' '/^label:/ {print $2}') == dos ]] || die "Unexpected partition table (expected MBR)"
attach
[[ $(blkid -s TYPE -o value "$ROOT_DEV") == ext4 ]] || die "Partition 1 is not ext4"
SETUP_LABEL=$(blkid -s LABEL -o value "${LOOP}p2" 2>/dev/null || true)
detach
if [[ $SETUP_LABEL == DIETPISETUP ]]; then
	# The configuration comes from this repository; otherwise this partition could
	# overwrite our dietpi.txt on first boot.
	sfdisk -q --no-reread --delete "$IMG" 2
fi
truncate -s +"$BUILD_GROW_MIB"M "$IMG"
echo ',+' | sfdisk -q --no-reread -N 1 "$IMG"
attach
fsck_root
resize2fs "$ROOT_DEV" >/dev/null
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
log "Root UUID: $ROOT_UUID"

# ---------------------------------------------------------------------------
log "3/9 Mounting and preparing the chroot"
mount "$ROOT_DEV" "$MNT"
for d in dev dev/pts proc sys; do mount --bind "/$d" "$MNT/$d"; done
# On the device /tmp is a tmpfs (1777); in the image it is a plain directory _apt cannot write to
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$MNT/tmp"
mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.nexus-orig"
if [[ -f /run/systemd/resolve/resolv.conf ]]; then
	cp /run/systemd/resolve/resolv.conf "$MNT/etc/resolv.conf"
else
	cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
fi
# Do not start any services inside the chroot
printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"
chmod 755 "$MNT/usr/sbin/policy-rc.d"

install -m 644 "$WORK/radxa-archive-keyring.deb" "$MNT/root/radxa-archive-keyring.deb"
install -m 644 "$WORK/nexus-archive-keyring.deb" "$MNT/root/nexus-archive-keyring.deb"
install -m 755 files/nexus-firstboot "$MNT/usr/local/sbin/nexus-firstboot"
install -m 644 files/nexus-firstboot.service "$MNT/etc/systemd/system/nexus-firstboot.service"
install -m 644 files/nexus-auto-upgrade.service files/nexus-auto-upgrade.timer "$MNT/etc/systemd/system/"
install -m 644 files/52nexus-unattended-upgrades "$MNT/etc/apt/apt.conf.d/52nexus-unattended-upgrades"
install -m 755 files/chroot-setup.sh "$MNT/root/nexus-chroot-setup.sh"

# ---------------------------------------------------------------------------
log "4/9 Installing the Radxa BSP and setting up the system (aarch64 chroot)"
chroot "$MNT" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb \
	ROOT_UUID="$ROOT_UUID" \
	NEXUS_HOSTNAME="$NEXUS_HOSTNAME" NEXUS_USER="$NEXUS_USER" \
	NEXUS_GROUPS="$NEXUS_GROUPS" \
	RADXA_PRODUCT="$RADXA_PRODUCT" RADXA_SOC_REPO="$RADXA_SOC_REPO" RADXA_KERNEL_FLAVOR="$RADXA_KERNEL_FLAVOR" \
	NEXUS_PACKAGES="$NEXUS_PACKAGES" \
	/bin/bash /root/nexus-chroot-setup.sh
KVER=$(cat "$MNT/root/.nexus-kernel-version")
rm -f "$MNT/usr/sbin/policy-rc.d" "$MNT/root/nexus-chroot-setup.sh" "$MNT/root/.nexus-kernel-version" "$MNT/etc/resolv.conf"
mv "$MNT/etc/resolv.conf.nexus-orig" "$MNT/etc/resolv.conf"
for d in tmp dev/pts dev proc sys; do umount "$MNT/$d"; done

# ---------------------------------------------------------------------------
log "5/9 Configuring the DietPi first-run setup"
setcfg() { # KEY VALUE -> set in dietpi.txt (also replaces commented-out lines)
	local f=$MNT/boot/dietpi.txt
	if grep -qE "^#?$1=" "$f"; then sed -i -E "s|^#?$1=.*|$1=$2|" "$f"; else echo "$1=$2" >> "$f"; fi
}
setcfg AUTO_SETUP_AUTOMATED 1
setcfg AUTO_SETUP_NET_HOSTNAME "$NEXUS_HOSTNAME"
setcfg AUTO_SETUP_LOCALE "$NEXUS_LOCALE"
setcfg AUTO_SETUP_KEYBOARD_LAYOUT "$NEXUS_KEYBOARD"
setcfg AUTO_SETUP_TIMEZONE "$NEXUS_TIMEZONE"
setcfg AUTO_SETUP_SSH_SERVER_INDEX -2          # OpenSSH
setcfg AUTO_SETUP_CUSTOM_SCRIPT_EXEC 0         # run /boot/Automation_Custom_Script.sh
setcfg AUTO_SETUP_AUTOSTART_TARGET_INDEX 0     # console without autologin
setcfg SURVEY_OPTED_IN 0
setcfg CONFIG_SERIAL_CONSOLE_ENABLE 1
setcfg AUTO_SETUP_SWAPFILE_SIZE 0              # no swap file in the image
# Random password for root/dietpi during the first-run setup. DietPi encrypts it;
# afterwards Automation_Custom_Script.sh locks root and deletes dietpi.
setcfg AUTO_SETUP_GLOBAL_PASSWORD "$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32 || true)"
install -m 700 files/Automation_Custom_Script.sh "$MNT/boot/Automation_Custom_Script.sh"

# ---------------------------------------------------------------------------
log "6/9 Running the DietPi first-run setup in a booted container (slow under qemu)"
# The container shares the network with the build host: DietPi must not configure any
# interfaces there. The eth0 DHCP configuration from the image stays unchanged.
setcfg AUTO_SETUP_NET_ETHERNET_ENABLED 0
setcfg AUTO_SETUP_NET_WIFI_ENABLED 0
# Services that would touch the host network or bind ports the build host already uses
# (the runner's own sshd holds port 22). Blocked only inside the container: starting them
# then succeeds as "condition failed" instead of failing DietPi's software install step.
BUILD_BLOCKED_UNITS="networking.service ifup@.service NetworkManager.service NetworkManager-wait-online.service NetworkManager-dispatcher.service wpa_supplicant.service ModemManager.service comitup.service comitup-web.service ssh.service ssh.socket nexus-panel.service nexus-web-terminal.service"
for u in $BUILD_BLOCKED_UNITS; do
	mkdir -p "$MNT/etc/systemd/system/$u.d"
	printf '[Unit]\nConditionVirtualization=!container\n' > "$MNT/etc/systemd/system/$u.d/nexus-build.conf"
done

# Runs dietpi-login non-interactively (see the unit file for details)
install -m 644 files/nexus-build-firstrun.service "$MNT/etc/systemd/system/nexus-build-firstrun.service"
ln -sf /etc/systemd/system/nexus-build-firstrun.service "$MNT/etc/systemd/system/multi-user.target.wants/"
# Replaces ping inside the container (see the script for details)
install -m 755 files/nexus-build-ping "$MNT/usr/local/sbin/ping"

FIRSTRUN_LOG=$WORK/dietpi-firstrun-container.log
DIETPI_LOG=$MNT/var/lib/dietpi/logs/dietpi-firstrun-setup.log
: > "$FIRSTRUN_LOG"
start_container() {
	systemd-nspawn -q --boot -D "$MNT" -M nexus-build --resolv-conf=bind-host --timezone=off \
		--console=read-only >> "$FIRSTRUN_LOG" 2>&1 &
	NSPAWN_PID=$!
}
start_container
boots=1
deadline=$(( SECONDS + ${FIRSTRUN_TIMEOUT_MIN:-120} * 60 ))
stage=
shown=0
while :; do
	stage=$(cat "$MNT/boot/dietpi/.install_stage" 2>/dev/null || true)
	[[ $stage == 2 ]] && break
	if ! kill -0 "$NSPAWN_PID" 2>/dev/null; then
		# DietPi may reboot between the stages; boot the container again
		(( boots < 4 )) || { tail -n 80 "$FIRSTRUN_LOG"; die "Container keeps exiting before the setup finished (install_stage=$stage)"; }
		log "  container exited at install_stage=$stage, booting it again"
		start_container
		boots=$(( boots + 1 ))
	fi
	if (( SECONDS > deadline )); then
		tail -n 80 "$FIRSTRUN_LOG"; tail -n 40 "$DIETPI_LOG" 2>/dev/null
		journalctl --directory="$MNT/var/log/journal" -u nexus-build-firstrun --no-pager 2>/dev/null | tail -n 60
		kill "$NSPAWN_PID"; die "First-run setup timed out (install_stage=$stage)"
	fi
	sleep 30
	log "  ... install_stage=${stage:-?}, $(( SECONDS / 60 )) min"
	# Print the DietPi log lines written since the last check
	if [[ -f $DIETPI_LOG ]]; then
		total=$(wc -l < "$DIETPI_LOG")
		(( total > shown )) && tail -n +"$(( shown + 1 ))" "$DIETPI_LOG" | tr -d '\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/^/  | /' | cut -c1-200
		shown=$total
	fi
done
log "First-run setup finished, shutting down the container"
sleep 20   # let DietPi finish its last steps (autostart, cleanup)
kill -TERM "$NSPAWN_PID" 2>/dev/null || true
for _ in $(seq 60); do kill -0 "$NSPAWN_PID" 2>/dev/null || break; sleep 5; done
kill -0 "$NSPAWN_PID" 2>/dev/null && { kill -KILL "$NSPAWN_PID"; sleep 5; }
wait "$NSPAWN_PID" 2>/dev/null || true
NSPAWN_PID=
cp "$MNT/var/lib/dietpi/logs/dietpi-firstrun-setup.log" "$OUT/dietpi-firstrun-setup.log" 2>/dev/null || true

log "Checking the result of the first-run setup"
grep -q "^$NEXUS_USER:" "$MNT/etc/passwd" || die "User $NEXUS_USER is missing"
grep -q '^dietpi:' "$MNT/etc/passwd" && die "User dietpi still exists (did Automation_Custom_Script.sh run?)"
grep -q '^root:!' "$MNT/etc/shadow" || die "root is not locked"
[[ $(cat "$MNT/etc/hostname") == "$NEXUS_HOSTNAME" ]] || die "Hostname not set"
[[ -f $MNT/etc/ssh/sshd_config.d/00-local.conf ]] || die "SSH configuration missing"
for p in $NEXUS_PACKAGES; do
	grep -qx "Package: $p" "$MNT/var/lib/dpkg/status" || die "Package $p is not installed"
done
ls "$MNT"/etc/systemd/system/*/dietpi-autologin.conf 2>/dev/null && die "Root autologin is still enabled"
[[ -L $MNT/etc/systemd/system/timers.target.wants/nexus-auto-upgrade.timer ]] || die "nexus-auto-upgrade.timer is not enabled"

log "Reverting build-only settings, preparing the first boot on the device"
rm -f "$MNT/etc/systemd/system/nexus-build-firstrun.service" "$MNT/etc/systemd/system/multi-user.target.wants/nexus-build-firstrun.service" \
	"$MNT/usr/local/sbin/ping"
setcfg AUTO_SETUP_NET_ETHERNET_ENABLED 1
for u in $BUILD_BLOCKED_UNITS; do
	rm -f "$MNT/etc/systemd/system/$u.d/nexus-build.conf"
	rmdir "$MNT/etc/systemd/system/$u.d" 2>/dev/null || true
done
# Wi-Fi belongs to NetworkManager/comitup (nexus-captive-portal): remove DietPi's Wi-Fi
# blacklist and monitor in case the first-run setup created them
rm -f "$MNT/etc/modprobe.d/dietpi-disable_wifi.conf" "$MNT/etc/systemd/system/multi-user.target.wants/dietpi-wifi-monitor.service"
# Revert the build speed-ups from chroot-setup.sh and build the initramfs once
rm -f "$MNT/etc/dpkg/dpkg.cfg.d/nexus-build-unsafe-io"
sed -i 's/^update_initramfs=.*/update_initramfs=yes/' "$MNT/etc/initramfs-tools/update-initramfs.conf"
for d in dev dev/pts proc sys; do mount --bind "/$d" "$MNT/$d"; done
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$MNT/tmp"
chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C update-initramfs -u -k all
chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C u-boot-update
for d in tmp dev/pts dev proc sys; do umount "$MNT/$d"; done
sync
# Left for the device: grow the partition, new SSH host keys, new machine-id (all offline)
rm -f "$MNT"/etc/ssh/ssh_host_*
touch "$MNT/etc/nexus-firstboot"
mkdir -p "$MNT/etc/systemd/system/local-fs.target.wants" "$MNT/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/dietpi-fs_partition_resize.service "$MNT/etc/systemd/system/local-fs.target.wants/"
ln -sf /etc/systemd/system/nexus-firstboot.service "$MNT/etc/systemd/system/sysinit.target.wants/"
rm -f "$MNT/dietpi_skip_partition_resize" "$MNT/root/.bash_history"
rm -rf "$MNT"/var/cache/apt/archives/*.deb "$MNT"/var/lib/apt/lists/*

# ---------------------------------------------------------------------------
log "7/9 Writing the Radxa bootloader"
UBOOT_DIR=$MNT/usr/lib/u-boot/$RADXA_PRODUCT
[[ -f $UBOOT_DIR/idblock.img && -f $UBOOT_DIR/u-boot.itb ]] || die "U-Boot files missing in $UBOOT_DIR"
first_part=$(sfdisk -lqo Start "$IMG" | sed -n 2p | tr -d ' ')
itb_sectors=$(( ($(stat -c %s "$UBOOT_DIR/u-boot.itb") + 511) / 512 ))
(( 16384 + itb_sectors <= first_part )) || die "u-boot.itb does not fit in front of the first partition"
# Wipe Armbian's U-Boot (sector 64 up to the first partition); the MBR is kept
dd if=/dev/zero of="$LOOP" bs=512 seek=64 count=$(( first_part - 64 )) conv=notrunc,fsync status=none
dd if="$UBOOT_DIR/idblock.img" of="$LOOP" bs=512 seek=64 conv=notrunc,fsync status=none
dd if="$UBOOT_DIR/u-boot.itb" of="$LOOP" bs=512 seek=16384 conv=notrunc,fsync status=none

# ---------------------------------------------------------------------------
log "8/9 Unmounting and shrinking"
DIETPI_VERSION=$(. "$MNT/boot/dietpi/.version" && echo "$G_DIETPI_VERSION_CORE.$G_DIETPI_VERSION_SUB.$G_DIETPI_VERSION_RC")
umount -R "$MNT"
fsck_root
resize2fs -M "$ROOT_DEV" >/dev/null
bcount=$(dumpe2fs -h "$ROOT_DEV" 2>/dev/null | awk -F: '/^Block count/ {gsub(/ /,"",$2); print $2}')
bsize=$(dumpe2fs -h "$ROOT_DEV" 2>/dev/null | awk -F: '/^Block size/ {gsub(/ /,"",$2); print $2}')
detach
part_sectors=$(( (bcount * bsize / 512 + IMAGE_FREE_MIB * 2048 + 2047) / 2048 * 2048 ))
echo ",$part_sectors" | sfdisk -q --no-reread -N 1 "$IMG"
truncate -s $(( (first_part + part_sectors) * 512 )) "$IMG"
attach
fsck_root
resize2fs "$ROOT_DEV" >/dev/null
detach
log "Image size: $(du -h --apparent-size "$IMG" | cut -f1)"

# ---------------------------------------------------------------------------
log "9/9 Compressing"
xz -T0 -6 -c "$IMG" > "$OUT/$IMAGE_NAME.img.xz"
(cd "$OUT" && sha256sum "$IMAGE_NAME.img.xz" > "$IMAGE_NAME.img.xz.sha256")
rm -f "$IMG"
cat > "$OUT/release-notes.md" <<EOF
nexus image for the **Radxa CM3 IO board**

| | |
|---|---|
| Base | \`$DIETPI_IMAGE\` (DietPi $DIETPI_VERSION) |
| Kernel | Radxa \`$KVER\` |
| Bootloader | \`u-boot-$RADXA_PRODUCT\` |
| Tridex software | \`$NEXUS_PACKAGES\` (captive portal, web panel :8080, web terminal :7681), updated nightly 04:00-05:00 Europe/Berlin via unattended-upgrades |
| Hostname | \`$NEXUS_HOSTNAME\` |
| User | \`$NEXUS_USER\` without a password: no login until the first password is set; root locked |

Flash: \`xz -dc $IMAGE_NAME.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync\`

The DietPi first-run setup already ran during the build. On first boot the device only
(offline) grows the root partition and creates new SSH host keys and a new machine-id.
EOF
log "Done: $OUT/$IMAGE_NAME.img.xz"
