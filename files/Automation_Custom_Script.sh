#!/bin/bash
# Run by DietPi as root at the end of the automated first-run setup.
# During the setup DietPi sets a password for root and keeps the user dietpi;
# this script reverts both.
set -e
echo "[nexus] Removing user dietpi"
if id dietpi &>/dev/null; then
	pkill -KILL -u dietpi || true
	userdel -r dietpi 2>/dev/null || userdel dietpi
fi
rm -f /etc/sudoers.d/dietpi

echo "[nexus] Locking root"
passwd -l root
[[ -f /etc/ssh/sshd_config.d/dietpi.conf ]] && sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config.d/dietpi.conf
sshd -t && systemctl reload ssh || true

# Remove the root autologin DietPi uses on the consoles during the first-run setup
rm -f /etc/systemd/system/getty@tty1.service.d/dietpi-autologin.conf \
	/etc/systemd/system/console-getty.service.d/dietpi-autologin.conf \
	/etc/systemd/system/serial-getty@*.service.d/dietpi-autologin.conf
systemctl daemon-reload
echo "[nexus] Done"
