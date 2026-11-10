#!/bin/bash
#
# configure-lazycast.sh - lazycast settings: frame rate, Wi-Fi channel, width
#
#   sudo ./configure-lazycast.sh            interactive setup
#   ./configure-lazycast.sh --show          show current settings (no sudo)
#
# Writes ~/lazycast/lazycast.conf, read by all.sh (Wi-Fi) and d2.py (frame rate):
#   FPS         30, 60 or auto (auto = 30 on Pi 2/3/Zero, 60 on Pi 4 and newer)
#   FREQ_24     auto, or a 2.4 GHz frequency (used on 2.4 GHz-only models:
#               Pi 3B, Zero W, Zero 2 W)
#   FREQ_5      a non-DFS 5 GHz frequency (used on 5 GHz-capable models:
#               Pi 3B+, 3A+, 4, 400, 5, 500, CM4, CM5). Default 5180 (ch 36)
#   ALLOW_HT40  1 = allow 40 MHz on models that support it, 0 = 20 MHz only
#
# Channel lists are for the US (FCC). Other countries allow different channels.
#

RUN_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
LAZYCAST_DIR="$USER_HOME/lazycast"
CONF="$LAZYCAST_DIR/lazycast.conf"

# --- channel tables (channel:frequency) ---
CH24="1:2412 2:2417 3:2422 4:2427 5:2432 6:2437 7:2442 8:2447 9:2452 10:2457 11:2462"
CH5="36:5180 40:5200 44:5220 48:5240 149:5745 153:5765 157:5785 161:5805 165:5825"

freq_of() {   # freq_of <table> <channel>
  local e
  for e in $1; do [ "${e%%:*}" = "$2" ] && { echo "${e##*:}"; return 0; }; done
  return 1
}
chan_of() {   # chan_of <table> <freq>
  local e
  for e in $1; do [ "${e##*:}" = "$2" ] && { echo "${e%%:*}"; return 0; }; done
  return 1
}

# --- read current values (with defaults) ---
FPS=auto; FREQ_24=auto; FREQ_5=5180; ALLOW_HT40=0
if [ -f "$CONF" ]; then
  v=$(sed -n 's/^FPS=\(30\|60\|auto\)$/\1/p' "$CONF" | tail -1);        [ -n "$v" ] && FPS=$v
  v=$(sed -n 's/^FREQ_24=\([A-Za-z0-9]*\)$/\1/p' "$CONF" | tail -1); [ -n "$v" ] && FREQ_24=$v
  v=$(sed -n 's/^FREQ_5=\([0-9]*\)$/\1/p' "$CONF" | tail -1);        [ -n "$v" ] && FREQ_5=$v
  v=$(sed -n 's/^ALLOW_HT40=\([01]\)$/\1/p' "$CONF" | tail -1);      [ -n "$v" ] && ALLOW_HT40=$v
fi

MODEL=$(tr -d '\0' 2>/dev/null < /proc/device-tree/model)
case "$MODEL" in
  *"Pi 3 Model B Plus"*|*"Pi 3 Model A Plus"*|*"Raspberry Pi 4"*|*"Raspberry Pi 5"*|*"Compute Module 4"*|*"Compute Module 5"*) DUAL=1 ;;
  *) DUAL=0 ;;
esac

describe() {
  local c eff
  if [ "$FPS" = auto ]; then
    case "$MODEL" in *"Raspberry Pi 3"*|*"Raspberry Pi 2"*|*"Raspberry Pi Zero"*) eff=30 ;; *) eff=60 ;; esac
    echo "  Frame rate      : auto (this Pi: $eff)"
  else
    echo "  Frame rate      : max $FPS fps"
  fi
  if [ "$FREQ_24" = auto ]; then echo "  2.4 GHz channel : auto"
  else c=$(chan_of "$CH24" "$FREQ_24"); echo "  2.4 GHz channel : $c ($FREQ_24 MHz)"; fi
  c=$(chan_of "$CH5" "$FREQ_5"); echo "  5 GHz channel   : $c ($FREQ_5 MHz)"
  [ "$ALLOW_HT40" = 1 ] && echo "  40 MHz width    : allowed (where supported)" || echo "  40 MHz width    : off (20 MHz)"
  if [ "$DUAL" = 1 ]; then echo "  This Pi ($MODEL) uses the 5 GHz setting."
  else echo "  This Pi (${MODEL:-unknown}) uses the 2.4 GHz setting (20 MHz only)."; fi
}

if [ "$1" = "--show" ]; then
  if [ -f "$CONF" ]; then
    echo "Current lazycast settings ($CONF):"
  else
    echo "No settings file yet ($CONF) - using the defaults:"
  fi
  describe
  exit 0
fi

if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo:  sudo $0"
  exit 1
fi
if [ ! -f "$LAZYCAST_DIR/all.sh" ]; then
  echo "ERROR: $LAZYCAST_DIR/all.sh not found."; exit 1
fi
if ! grep -q "lazycast.conf" "$LAZYCAST_DIR/all.sh"; then
  echo "WARNING: all.sh does not read lazycast.conf yet, so these settings will have"
  echo "         no effect until all.sh is updated (see the instructions)."
  echo
fi
if ! grep -q "lazycast_video_formats" "$LAZYCAST_DIR/d2.py" 2>/dev/null; then
  echo "WARNING: d2.py does not read lazycast.conf yet, so the frame-rate setting"
  echo "         will have no effect until patch_d2_config.py has been applied."
  echo
fi
if [ "$(findmnt -no FSTYPE / 2>/dev/null)" = "overlay" ]; then
  echo "NOTE: the overlay file system is ON. Changes work now but are lost at the"
  echo "      next reboot. To keep them, turn the overlay off first."
  read -r -p "Continue anyway (for a temporary test)? [y/N] " a
  [[ "$a" =~ ^[Yy] ]] || exit 0
  echo
fi

echo "Current settings:"
describe
echo

# --- 1. frame rate ---
echo "1) Maximum frame rate"
echo "   30   = max 1080p30 (recommended for Pi 3B / Zero 2 W, runs cooler)"
echo "   60   = up to 1080p50 / 720p60"
echo "   auto = 30 on Pi 2/3/Zero, 60 on Pi 4 and newer"
while :; do
  read -r -p "   Choice [30/60/auto] (Enter keeps $FPS): " a
  [ -z "$a" ] && break
  case "$a" in 30|60|auto) FPS=$a; break ;; esac
  echo "   Please enter 30, 60 or auto."
done
echo

# --- 2. 2.4 GHz ---
echo "2) 2.4 GHz channel (used by Pi 3B, Zero W, Zero 2 W)"
read -r -p "   Set a fixed 2.4 GHz channel? (n = automatic) [y/N] " a
if [[ "$a" =~ ^[Yy] ]]; then
  echo "   Channels: 1-11. Recommended: 1, 6 or 11 (they do not overlap)."
  while :; do
    read -r -p "   Channel: " c
    f=$(freq_of "$CH24" "$c") && { FREQ_24=$f; break; }
    echo "   Please enter a number from 1 to 11."
  done
else
  FREQ_24=auto
fi
echo

# --- 3. 40 MHz ---
echo "3) 40 MHz channel width (only used on models whose chip supports it;"
echo "   Pi 3B / Zero always use 20 MHz). 20 MHz is the most compatible."
read -r -p "   Allow 40 MHz? [y/N] " a
[[ "$a" =~ ^[Yy] ]] && ALLOW_HT40=1 || ALLOW_HT40=0
echo

# --- 4. 5 GHz ---
echo "4) 5 GHz channel (used by Pi 3B+, 3A+, 4, 400, 5, 500, CM4, CM5)"
read -r -p "   Use a channel other than 36 (5180 MHz)? [y/N] " a
if [[ "$a" =~ ^[Yy] ]]; then
  echo "   Non-DFS channels: 36 40 44 48 149 153 157 161 165"
  if [ "$ALLOW_HT40" = 1 ]; then
    echo "   With 40 MHz the Pi uses a channel PAIR:"
    echo "     36+40   44+48   149+153   157+161"
    echo "   Either channel of a pair can be entered; the first one is saved."
    echo "   The Pi may announce either channel of the pair as its main channel."
    echo "   165 has no pair and always runs at 20 MHz."
  else
    echo "   (165 supports 20 MHz only)"
  fi
  while :; do
    read -r -p "   Channel: " c
    f=$(freq_of "$CH5" "$c") || { echo "   Please enter one of: 36 40 44 48 149 153 157 161 165"; continue; }
    if [ "$ALLOW_HT40" = 1 ]; then
      case "$c" in
        40|48|153|161)
          low=$((c - 4))
          echo "   -> Using $low instead: at 40 MHz, $c and $low form the same pair"
          echo "      ($low+$c), and starting on $low is more reliable."
          c=$low; f=$(freq_of "$CH5" "$c") ;;
        165)
          echo "   Note: 165 has no 40 MHz pair, so this Pi will use 20 MHz on it." ;;
      esac
    fi
    FREQ_5=$f; break
  done
else
  FREQ_5=5180
fi
echo

# --- write the file ---
cat > "$CONF" <<EOF
# lazycast settings - written by configure-lazycast.sh
# FPS: 30, 60 or auto (read by d2.py at every connection)
# FREQ_24: auto or a 2.4 GHz frequency in MHz (2.4 GHz-only models)
# FREQ_5:  non-DFS 5 GHz frequency in MHz (5 GHz-capable models)
# ALLOW_HT40: 1 = allow 40 MHz where supported, 0 = 20 MHz only
FREQ_24=$FREQ_24
FREQ_5=$FREQ_5
ALLOW_HT40=$ALLOW_HT40
FPS=$FPS
EOF
chown "$RUN_USER":"$RUN_USER" "$CONF" 2>/dev/null
echo "Saved to $CONF:"
describe
echo

# --- apply ---
# A reboot is the most reliable way to switch channels: restarting only
# lazycast can leave the Wi-Fi chip busy with the old channel, so the new
# group start gets rejected and the fallback picks a different channel.
read -r -p "Reboot now to apply the new settings? [Y/n] " a
if [[ ! "$a" =~ ^[Nn] ]]; then
  echo "Rebooting..."
  sync
  systemctl reboot
else
  echo "Settings saved. They take effect at the next reboot:  sudo reboot"
  echo "(The frame rate applies from the next cast, even without a reboot.)"
fi
