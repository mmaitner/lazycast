#!/bin/bash
#
# prepare-image.sh
#
# Cleans a lazycast Raspberry Pi so its SD card can be captured as a
# template image. Removes everything that is specific to this Pi or to
# the TV it was tested on, so every clone starts fresh.
#
# Usage:
#   sudo ./prepare-image.sh                    # uses ~/lazycast of the sudo user
#   sudo ./prepare-image.sh /path/to/lazycast  # custom location
#
# After it finishes, the Pi should be shut down and the card captured
# WITHOUT booting it again (booting recreates some of what was removed).
#

if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo:  sudo $0 [lazycast-dir]"
  exit 1
fi

RUN_USER="${SUDO_USER:-root}"
USER_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
LAZYCAST_DIR="$(readlink -f "${1:-$USER_HOME/lazycast}")"
WPA=/etc/wpa_supplicant/wpa_supplicant.conf
WARN=0

step() { echo; echo "==> $*"; }
warn() { echo "    WARNING: $*"; WARN=1; }

# ---------------------------------------------------------------- checks
step "Checking the template"

if [ ! -f "$LAZYCAST_DIR/all.sh" ] || [ ! -f "$LAZYCAST_DIR/d2.py" ]; then
  echo "ERROR: all.sh / d2.py not found in $LAZYCAST_DIR"
  echo "Pass the lazycast folder as an argument: sudo $0 /path/to/lazycast"
  exit 1
fi
echo "    lazycast folder: $LAZYCAST_DIR"

for f in all.sh d2.py; do
  [ -x "$LAZYCAST_DIR/$f" ] || warn "$f is not executable (fix: chmod +x $LAZYCAST_DIR/$f)"
  grep -q $'\r' "$LAZYCAST_DIR/$f" && warn "$f has Windows line endings (fix: sed -i 's/\\r\$//' $LAZYCAST_DIR/$f)"
done

grep -q "ps aux"   "$LAZYCAST_DIR/d2.py" || warn "d2.py is missing the 'ps aux' fix"
grep -q "idr_due"  "$LAZYCAST_DIR/d2.py" || warn "d2.py is missing the mode-switch patch"
grep -q "0F3FFFFF\| 00000000 " "$LAZYCAST_DIR/d2.py" || warn "d2.py is missing the resolution fix"

systemctl is-enabled --quiet lazycast || warn "lazycast service is not enabled"

HN=$(hostname)
HOSTS_HN=$(awk '$1=="127.0.1.1"{print $2; exit}' /etc/hosts)
echo "    hostname: $HN"
[ "$HN" = "$HOSTS_HN" ] || warn "/etc/hosts has '$HOSTS_HN' on the 127.0.1.1 line, not '$HN'"
case "$HN" in *_*) warn "hostname contains an underscore";; esac

if [ "$WARN" = 1 ]; then
  echo
  read -r -p "There are warnings above. Continue anyway? [y/N] " a
  [[ "$a" =~ ^[Yy] ]] || { echo "Aborted. Nothing was changed."; exit 1; }
fi

# ------------------------------------------------------------- lazycast
step "Stopping lazycast"
systemctl stop lazycast 2>/dev/null
pkill -f d2.py 2>/dev/null
pkill -f h264.bin 2>/dev/null
pkill -f "busybox udhcpd" 2>/dev/null

step "Removing lazycast runtime files"
rm -f "$LAZYCAST_DIR/lazycast.log" "$LAZYCAST_DIR/edid.txt" \
      "$LAZYCAST_DIR/udhcpd.conf" "$USER_HOME/lazycast.log" \
      /var/lib/misc/udhcpd.leases /run/lazycast.pin
rm -rf "$LAZYCAST_DIR/__pycache__"
echo "    log, cached TV info (edid.txt), DHCP config and leases removed"

# ------------------------------------------------------- Wi-Fi Direct
step "Removing saved Wi-Fi Direct groups from $WPA"
if [ -f "$WPA" ]; then
  cp "$WPA" /root/wpa_supplicant.conf.pre-image
  before=$(grep -c "mode=3" "$WPA")
  awk '
    /^[[:space:]]*network=\{/ { inblk=1; blk=$0 "\n"; p2p=0; next }
    inblk {
      blk = blk $0 "\n"
      if ($0 ~ /^[[:space:]]*mode=3/) p2p=1
      if ($0 ~ /^[[:space:]]*\}/) { inblk=0; if (!p2p) printf "%s", blk }
      next
    }
    /^[[:space:]]*device_name=/ { next }
    { print }
  ' /root/wpa_supplicant.conf.pre-image > "$WPA"
  echo "    removed $before saved group(s); normal Wi-Fi networks kept"
  echo "    backup: /root/wpa_supplicant.conf.pre-image"
else
  echo "    $WPA not found, skipping"
fi

# -------------------------------------------------- per-device identity
step "Clearing per-device identity (recreated on first boot)"
truncate -s 0 /etc/machine-id
[ -f /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ] && rm -f /var/lib/dbus/machine-id
rm -f /var/lib/dhcpcd/duid /var/lib/dhcpcd5/duid /etc/dhcpcd.duid
rm -f /var/lib/dhcpcd/*.lease /var/lib/dhcpcd5/*.lease /var/lib/dhcpcd/*.lease6 2>/dev/null
echo "    machine-id, DHCP client ID and network leases cleared"

if systemctl list-unit-files 2>/dev/null | grep -q '^regenerate_ssh_host_keys'; then
  rm -f /etc/ssh/ssh_host_*
  systemctl enable regenerate_ssh_host_keys >/dev/null 2>&1
  echo "    SSH host keys removed (each clone generates its own on first boot)"
else
  echo "    SSH host-key regeneration service not found; SSH keys left as-is"
fi

# ------------------------------------------------------------- tidy up
step "Cleaning logs, caches and shell history"
journalctl --rotate >/dev/null 2>&1
journalctl --vacuum-time=1s >/dev/null 2>&1
apt-get clean
rm -f "$USER_HOME/.bash_history" /root/.bash_history
echo "    done"

# --------------------------------------------------------------- finish
echo
read -r -p "Disable SSH in the image? [Y/n] " a
if [[ ! "$a" =~ ^[Nn] ]]; then
  raspi-config nonint do_ssh 1
  echo "    SSH disabled"
fi

echo
echo "Cleanup complete. Do NOT boot this card again before capturing it."
read -r -p "Shut down now? [Y/n] " a
if [[ ! "$a" =~ ^[Nn] ]]; then
  history -c 2>/dev/null
  sync
  shutdown -h now
else
  echo "Shut down later with:  sudo shutdown -h now"
fi
