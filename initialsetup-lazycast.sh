#!/bin/bash
#
# setup-lazycast-kiosk.sh
#
# Applies the system changes that turn a Raspberry Pi OS Lite (Bullseye)
# install running lazycast into a boot-to-cast display:
#
#   1. Installs figlet (big block letters for the name/PIN screen)
#   2. Sets the console font to Terminus 16x32
#   3. Adds quiet/no-blank/no-cursor options to cmdline.txt
#   4. Disables the login prompt on tty1 (tty2-6 still work)
#   5. Writes and enables the lazycast systemd service
#
# It does NOT touch all.sh or d2.py; your customised versions must already
# be in place in the lazycast folder.
# Safe to run more than once. Backups are made before files are changed.
#
# Usage:
#   sudo ./setup-lazycast-kiosk.sh                       # uses ~/lazycast of the sudo user
#   sudo ./setup-lazycast-kiosk.sh /path/to/lazycast     # custom location
#

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo:  sudo $0 [lazycast-dir]"
  exit 1
fi

# ---------- Locate lazycast ----------
RUN_USER="${SUDO_USER:-root}"
USER_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
LAZYCAST_DIR="${1:-$USER_HOME/lazycast}"
LAZYCAST_DIR="$(readlink -f "$LAZYCAST_DIR")"

if [ ! -f "$LAZYCAST_DIR/all.sh" ]; then
  echo "ERROR: all.sh not found in $LAZYCAST_DIR"
  echo "Pass the lazycast folder as an argument: sudo $0 /path/to/lazycast"
  exit 1
fi
echo "==> Using lazycast in: $LAZYCAST_DIR"

# ---------- 1. figlet ----------
echo "==> Installing figlet"
apt-get install -y figlet >/dev/null

# ---------- 2. Console font ----------
echo "==> Setting console font to Terminus 16x32"
CS=/etc/default/console-setup
[ -f "$CS.bak" ] || cp "$CS" "$CS.bak"
set_cs() {  # set_cs KEY VALUE
  if grep -q "^$1=" "$CS"; then
    sed -i "s|^$1=.*|$1=\"$2\"|" "$CS"
  else
    echo "$1=\"$2\"" >> "$CS"
  fi
}
set_cs CHARMAP  "UTF-8"
set_cs CODESET  "guess"
set_cs FONTFACE "Terminus"
set_cs FONTSIZE "16x32"
setupcon --force >/dev/null 2>&1 || true   # takes full effect at next boot

# ---------- 3. cmdline.txt ----------
if [ -f /boot/firmware/cmdline.txt ]; then
  CMDLINE=/boot/firmware/cmdline.txt
else
  CMDLINE=/boot/cmdline.txt
fi
echo "==> Updating $CMDLINE"
[ -f "$CMDLINE.bak" ] || cp "$CMDLINE" "$CMDLINE.bak"
line=$(head -n1 "$CMDLINE")
for opt in quiet loglevel=3 consoleblank=0 logo.nologo vt.global_cursor_default=0; do
  case " $line " in
    *" $opt "*) ;;                     # already present
    *) line="$line $opt" ;;
  esac
done
echo "$line" > "$CMDLINE"             # cmdline.txt must stay a single line

# ---------- 4. Disable login prompt on tty1 ----------
echo "==> Disabling login prompt on tty1 (tty2-tty6 remain available)"
systemctl disable getty@tty1.service >/dev/null 2>&1 || true

# ---------- 5. lazycast service ----------
SERVICE=/etc/systemd/system/lazycast.service
echo "==> Writing $SERVICE"
[ -f "$SERVICE" ] && [ ! -f "$SERVICE.bak" ] && cp "$SERVICE" "$SERVICE.bak"
cat > "$SERVICE" <<EOF
[Unit]
Description=lazycast Miracast receiver
After=network-online.target
Wants=network-online.target
Conflicts=getty@tty1.service

[Service]
Type=simple
WorkingDirectory=$LAZYCAST_DIR
ExecStartPre=/bin/sh -c 'until wpa_cli interface 2>/dev/null | grep -q p2p-dev; do sleep 1; done; sleep 15'
ExecStart=$LAZYCAST_DIR/all.sh
TimeoutStartSec=0
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable lazycast.service >/dev/null 2>&1

echo
echo "Done. Backups: $CS.bak, $CMDLINE.bak (and $SERVICE.bak if a service existed)."
echo "Reboot to apply everything:  sudo reboot"
