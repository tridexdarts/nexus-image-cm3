#!/bin/bash
# Runs as root inside the aarch64 chroot of the DietPi image (called by build.sh).
# Replaces the Armbian kernel/bootloader with the Radxa BSP for the CM3 IO board
# and sets up user, hostname and SSH.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
log() { echo -e "\e[1;36m[chroot]\e[0m $*"; }

: "${ROOT_UUID:?}" "${NEXUS_HOSTNAME:?}" "${NEXUS_USER:?}"
: "${RADXA_PRODUCT:?}" "${RADXA_SOC_REPO:?}" "${RADXA_KERNEL_FLAVOR:?}" "${NEXUS_PACKAGES:?}"
APT=(apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Build speed-ups (reverted by build.sh at the end):
# - dpkg without fsync
# - do not rebuild the initramfs for every package, only once at the end
echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/nexus-build-unsafe-io
sed -i 's/^update_initramfs=.*/update_initramfs=no/' /etc/initramfs-tools/update-initramfs.conf

# ---------------------------------------------------------------------------
log "DietPi: treating the hardware as 'Generic Device' (Radxa manages the kernel, not DietPi)"
echo 22 > /etc/.dietpi_hw_model_identifier

# ---------------------------------------------------------------------------
log "Setting up the Radxa repositories (BSP packages only)"
dpkg -i /root/radxa-archive-keyring.deb
cat > /etc/apt/sources.list.d/radxa.list <<EOF
deb [signed-by=/usr/share/keyrings/radxa-archive-keyring.gpg] https://radxa-repo.github.io/bookworm bookworm main
deb [signed-by=/usr/share/keyrings/radxa-archive-keyring.gpg] https://radxa-repo.github.io/$RADXA_SOC_REPO $RADXA_SOC_REPO main
EOF
cat > /etc/apt/preferences.d/nexus-radxa <<EOF
# nexus: allow only the CM3 IO BSP from the Radxa repositories.
Package: radxa-archive-keyring radxa-firmware radxa-overlays-dkms u-boot-$RADXA_PRODUCT u-boot-rk* linux-image-$RADXA_PRODUCT linux-headers-$RADXA_PRODUCT linux-image-*-$RADXA_KERNEL_FLAVOR linux-headers-*-$RADXA_KERNEL_FLAVOR
Pin: origin radxa-repo.github.io
Pin-Priority: 500

Package: *
Pin: origin radxa-repo.github.io
Pin-Priority: -1

# Never reinstall the Armbian kernel/bootloader from the DietPi base image
Package: linux-image-*-rockchip64 linux-dtb-*-rockchip64 linux-headers-*-rockchip64 linux-u-boot-* armbian-firmware*
Pin: version *
Pin-Priority: -1
EOF

# ---------------------------------------------------------------------------
log "Kernel command line for u-boot-menu (extlinux.conf)"
mkdir -p /etc/kernel
echo "root=UUID=$ROOT_UUID rootfstype=ext4 rootwait rw console=ttyFIQ0,1500000n8 console=tty1 earlycon consoleblank=0 loglevel=4 coherent_pool=2M irqchip.gicv3_pseudo_nmi=0 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1 kasan=off fsck.repair=yes net.ifnames=0" \
	> /etc/kernel/cmdline

# ---------------------------------------------------------------------------
log "Installing packages"
apt-get update
# gcc/libc6-dev: Kbuild needs a compiler, even for the DKMS overlays (.dtbo only)
"${APT[@]}" install u-boot-menu initramfs-tools dkms make cpp gcc libc6-dev
# armbian-firmware overlaps with radxa-firmware -> remove it first
"${APT[@]}" purge armbian-firmware || true
"${APT[@]}" install radxa-archive-keyring radxa-firmware \
	"linux-headers-$RADXA_PRODUCT" "linux-image-$RADXA_PRODUCT" "u-boot-$RADXA_PRODUCT" \
	|| { cat /var/lib/dkms/radxa-overlays/*/build/make.log 2>/dev/null; exit 1; }

KVER=$(dpkg-query -W -f='${Package}\n' "linux-image-*-$RADXA_KERNEL_FLAVOR" | sed 's/^linux-image-//' | sort -V | tail -1)
[[ $KVER ]] || { echo "Radxa kernel is not installed"; exit 1; }
log "Radxa kernel: $KVER"
dkms autoinstall -k "$KVER" || true
dkms status

log "Removing the Armbian kernel and bootloader"
mapfile -t ARMBIAN < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*rockchip64' 'linux-dtb-*' 'linux-headers-*rockchip64' 'linux-u-boot-*' 2>/dev/null | awk '$1 ~ /^ii/ {print $2}')
(( ${#ARMBIAN[@]} )) && "${APT[@]}" purge "${ARMBIAN[@]}"
rm -rf /boot/boot.scr /boot/boot.cmd /boot/dietpiEnv.txt /boot/Image /boot/uInitrd /boot/initrd.img /boot/dtb /boot/dtb-*-rockchip64

log "Generating extlinux.conf"
u-boot-update
grep -q "$KVER" /boot/extlinux/extlinux.conf || { echo "extlinux.conf does not contain the Radxa kernel"; exit 1; }
[[ -f /boot/initrd.img-$KVER ]] || update-initramfs -c -k "$KVER"   # -c ignores update_initramfs=no

# ---------------------------------------------------------------------------
log "SSH: OpenSSH instead of Dropbear"
"${APT[@]}" install openssh-server
"${APT[@]}" purge dropbear dropbear-bin dropbear-run 2>/dev/null || "${APT[@]}" purge dropbear dropbear-bin || true
mkdir -p /etc/ssh/sshd_config.d
printf '# nexus: only %s may log in via SSH\nPermitRootLogin no\nAllowUsers %s\n' \
	"$NEXUS_USER" "$NEXUS_USER" > /etc/ssh/sshd_config.d/00-local.conf
systemctl enable ssh.service

# ---------------------------------------------------------------------------
log "Tridex Nexus Software: $NEXUS_PACKAGES"
dpkg -i /root/nexus-archive-keyring.deb
apt-get update
# shellcheck disable=SC2086
"${APT[@]}" install $NEXUS_PACKAGES
rm -f /root/nexus-archive-keyring.deb

# ---------------------------------------------------------------------------
log "Hostname $NEXUS_HOSTNAME"
echo "$NEXUS_HOSTNAME" > /etc/hostname
if grep -q '^127\.0\.1\.1' /etc/hosts; then
	sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEXUS_HOSTNAME/" /etc/hosts
else
	printf '127.0.1.1\t%s\n' "$NEXUS_HOSTNAME" >> /etc/hosts
fi

log "User $NEXUS_USER"
id "$NEXUS_USER" &>/dev/null || useradd -m -s /bin/bash "$NEXUS_USER"
# No password ('*'), no SSH keys, no passwordless sudo:
# login is only possible once the first password has been set (captive portal).
usermod -p '*' "$NEXUS_USER"
rm -rf "/home/$NEXUS_USER/.ssh/authorized_keys" /etc/sudoers.d/nexus-nopasswd
for g in $NEXUS_GROUPS; do getent group "$g" >/dev/null && usermod -aG "$g" "$NEXUS_USER"; done
id "$NEXUS_USER"
passwd -l root

# ---------------------------------------------------------------------------
log "First boot: auto-expand, SSH host keys, machine-id"
systemctl enable dietpi-fs_partition_resize.service
systemctl enable nexus-firstboot.service
touch /etc/nexus-firstboot
rm -f /etc/ssh/ssh_host_*

# ---------------------------------------------------------------------------
log "Cleaning up"
apt-get clean
rm -rf /var/lib/apt/lists/* /root/.bash_history /root/radxa-archive-keyring.deb
echo "$KVER" > /root/.nexus-kernel-version
