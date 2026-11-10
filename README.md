# lazycast — Education Edition
<img width="1920" height="1080" alt="splash" src="https://github.com/user-attachments/assets/aa4fdd3e-de73-4085-8c38-c46a001cbe08" />

A boot-to-cast Miracast receiver for Raspberry Pi. Plug a Pi into a TV or projector, and Windows laptops can cast to it with **WIN+K** — no login, no desktop, no network configuration.

This is a heavily modified fork of [lazycast by homeworkc](https://github.com/homeworkc/lazycast). The receiver core is the same, but `all.sh`, `d2.py` and the `h264.bin` player have been changed for a better on-screen experience, lower CPU use and much better stability, and three setup scripts were added to make deployment repeatable.

## Contents

- [What's different from upstream lazycast](#whats-different-from-upstream-lazycast)
- [Requirements](#requirements)
- [Option A: Flash the ready-made image](#option-a-flash-the-ready-made-image)
- [Option B: Build it yourself](#option-b-build-it-yourself)
- [Setting up each Pi](#setting-up-each-pi)
- [The three scripts](#the-three-scripts)
- [Settings (`lazycast.conf`)](#settings-lazycastconf)
- [Creating your own image](#creating-your-own-image)
- [How it behaves](#how-it-behaves)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Credits and license](#credits-and-license)

## What's different from upstream lazycast

- **Full-screen display:** the Pi boots straight to a full-screen splash showing the device name and PIN in large text. Diagnostic output no longer clutters the screen.
- **Starts on boot** as a systemd service, without a desktop or login.
- **Random PIN** that changes after every cast.
- **Self-healing Wi-Fi Direct:** a group that fails to start, gets stuck, or lands on a DFS channel is detected and rebuilt automatically.
- **Much lower CPU use:** fixes for an audio retry loop in the player and a process-spawning loop in `d2.py` (a Pi 3B dropped from ~100% to under 10% player CPU).
- **Works with more laptops:** fixes for 16:10 screens (scrambled bottom strip), Duplicate/Extend switching, multiple laptops connecting one after another, and Intel Wi-Fi 7 laptops.
- **Per-device settings** (frame rate, Wi-Fi channel, channel width) in one file, set with one script.
- **SD-card friendly:** logging off by default, minimal disk writes, and support for a read-only overlay file system so the Pi can simply be unplugged.

See the [changelog](CHANGELOG.md) for full details.

## Requirements

**Raspberry Pi** (tested models in bold):

| Model | Wi-Fi Direct band | Notes |
|---|---|---|
| **Pi 4** | 5 GHz (channel 36 by default) | Recommended |
| **Pi 3B** | 2.4 GHz | Use the 30 fps limit (default) and a ventilated case |
| **Pi Zero 2 W** | 2.4 GHz | Group start can take up to ~1 minute; self-healing handles it |
| Pi 3B+, 3A+, 400, 5 | 5 GHz | Expected to work, not tested |

- **OS:** Raspberry Pi OS (Legacy, 32-bit) **Bullseye**, Lite recommended. Bookworm and 64-bit are not supported.
- **SD card:** 8 GB or larger.
- **Power supply:** a good-quality supply (2.5 A for Pi 3B / Zero 2 W, 3 A for Pi 4). A weak supply causes throttling.
- **Sources:** Windows 10 and 11 laptops with Miracast support.

## Option A: Flash the ready-made image

1. Download the latest lazycast `.img.xz` file from the [Releases](https://github.com/mmaitner/lazycast/releases) page.
2. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
3. Run Raspberry Pi Imager:
   - Select your Raspberry Pi model.
   - On the **Operating System** screen, scroll down and select **Use Custom**, then choose the `.img.xz` file.
   - Select your SD card as storage.
   - Write and verify the card. If Imager asks about **OS customisation**, choose **No** — customisation can change the user, hostname or SSH settings the image depends on.
4. Once written, insert the card into the Pi and turn it on while it's connected to a display.
5. It should boot to the splash screen with the broadcast name **change-me** and a PIN. This takes about a minute.
6. With a keyboard connected, press **Ctrl+Alt+F2** to get to the login prompt on tty2. (**Alt+F1** returns to the splash.)
7. Log in:
   - Username: `cast`
   - Password: `lazycast` Change it after first login with `passwd` or `sudo raspi-config`.
8. Run `sudo raspi-config`.
9. Set the hostname under **System Options** → **Hostname**. This is the name laptops see in WIN+K.
   - Use only letters, numbers and hyphens. **No underscores** or special characters.
   - **32 characters maximum**; 15 or fewer fits on one line of the splash. See [Hostname rules](#2-set-the-hostname).
10. Finish `raspi-config` and allow the reboot.
11. **Optional:** to change the frame rate, the Wi-Fi channel, or enable 40 MHz width on 5 GHz channels, run:

    ```
    sudo ./configure-lazycast.sh
    ```

    The defaults are:

    | Setting | Default |
    |---|---|
    | Frame rate | `auto` (30 on Pi 3B / Zero 2 W, 60 on Pi 4 or newer) |
    | 2.4 GHz channel | auto |
    | 5 GHz channel | 36 |
    | 40 MHz channel width | off |

    See [The three scripts](#configure-lazycastsh) for details.
12. **[RECOMMENDED] Filesystem overlay.** This limits writes to the SD card by keeping all changes in RAM instead, which protects the card against wear and against corruption when the Pi is unplugged. **Do this last:** the device becomes read-only, and settings won't change after this. It can be undone.
    - Run `sudo raspi-config`.
    - Select **Performance Options** → **Overlay File System**.
      - Enable the overlay file system.
      - Enable the read-only boot partition.
    - Reboot when prompted.

    To change something later, turn the overlay **and** the boot write protection off in the same menu, reboot, make the change, then turn both back on.

## Option B: Build it yourself

This follows the same base steps as upstream lazycast, then applies this fork's setup.

### 1. Prepare the OS

Raspberry Pi Imager no longer lists the Bullseye release, so download it directly:

- **Raspberry Pi OS Lite (Bullseye, 32-bit), 2023-05-03:** [downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2023-05-03/](https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2023-05-03/) — download the `.img.xz` file.

Write it with Raspberry Pi Imager using **Use Custom**. In the OS customisation, create a user (the examples below assume `cast`) and set the Wi-Fi country, or set the country later with `sudo raspi-config nonint do_wifi_country US`. Without a Wi-Fi country, Wi-Fi stays blocked and lazycast can't start.

Boot the Pi and log in, then install the build tools and build the Raspberry Pi userland:

```
sudo apt update
sudo apt install cmake git
git clone https://github.com/raspberrypi/userland
cd userland
./buildme
cd ~
```

Switch the display driver to `fkms` and reboot:

```
sudo sed -i 's/vc4-kms-v3d/vc4-fkms-v3d/g' /boot/config.txt
sudo reboot
```

### 2. Build lazycast

```
sudo apt install libx11-dev libasound2-dev libavformat-dev libavcodec-dev python3-evdev figlet
cd /opt/vc/src/hello_pi/libs/ilclient/ && sudo make
cd /opt/vc/src/hello_pi/hello_video && sudo make
cd ~
git clone https://github.com/mmaitner/lazycast.git lazycast
cd lazycast
make
```

lazycast must be in `~/lazycast` of the user that runs it (for example `/home/cast/lazycast`).

### 3. Run the initial setup

Copy the three scripts from this repository (`initialsetup-lazycast.sh`, `prepare-image.sh`, `configure-lazycast.sh`) to your home folder, then:

```
cd ~
chmod +x initialsetup-lazycast.sh prepare-image.sh configure-lazycast.sh
chmod +x ~/lazycast/all.sh ~/lazycast/d2.py
sudo ./initialsetup-lazycast.sh
sudo reboot
```

After the reboot, the splash with the device name and PIN appears. See [The three scripts](#the-three-scripts) for what the initial setup changes.

### 4. Recommended: reduce SD-card writes

These are already done in the ready-made image. They make the system much friendlier to the SD card and are required for a clean boot with the overlay file system.

```
# Remove the swap file (also avoids a boot error with the overlay)
sudo dphys-swapfile swapoff
sudo dphys-swapfile uninstall
sudo systemctl disable dphys-swapfile

# Don't log every sudo call made by lazycast
echo 'Defaults:root !syslog' | sudo tee /etc/sudoers.d/no-root-log
sudo chmod 440 /etc/sudoers.d/no-root-log

# Keep the system journal in RAM, capped at 10 MB
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=10M\n' | sudo tee /etc/systemd/journald.conf.d/volatile.conf

# Turn off rsyslog and automatic package updates
sudo systemctl disable rsyslog
sudo systemctl disable apt-daily.timer apt-daily-upgrade.timer man-db.timer
```

Also add `noatime` to the root (`/`, `ext4`) line in `/etc/fstab` (change `defaults` to `defaults,noatime`), and optionally a weekly restart of lazycast with `sudo crontab -e`:

```
0 3 * * 0 systemctl restart lazycast
```

## Setting up each Pi

Do this on every Pi built by hand (Option B). If you flashed the ready-made image, steps 6–12 of [Option A](#option-a-flash-the-ready-made-image) cover the same ground. You need a keyboard connected to the Pi.

### 1. Log in

Press **Ctrl+Alt+F2** to switch to a login prompt (the splash stays on the first screen; **Alt+F1** goes back). Log in as `cast`.

### 2. Set the hostname

The hostname is the name laptops see in WIN+K and the name shown on the splash.

```
sudo raspi-config nonint do_hostname conf-room-2
sudo reboot
```

Or use `sudo raspi-config` → **System Options** → **Hostname**.

**Hostname rules:**

- Letters, numbers and hyphens only. **No underscores**, spaces or other characters.
- **32 characters maximum.** Longer names are rejected by Wi-Fi Direct, and the Pi keeps broadcasting its old name.
- **15 characters or fewer** recommended, so the name fits on one line of the splash.

### 3. Optional: change frame rate, channel or width

```
sudo ./configure-lazycast.sh
```

Skip this to keep the defaults. See [Settings](#settings-lazycastconf).

### 4. Test

After the reboot, check that the splash shows the new name and a PIN, the Pi appears in WIN+K on a laptop, and a cast works.

### 5. Recommended: enable the overlay file system (do this last)

The overlay file system makes the SD card **read-only**. All changes go to RAM and are discarded at reboot. This protects the card against wear and against corruption when the Pi is unplugged without shutting down — which is how most kiosk devices are restarted.

```
sudo raspi-config
```

1. **Performance Options** → **Overlay File System** → **Yes**.
2. When asked to make the boot partition read-only, choose **Yes**.
3. Reboot when prompted.

**Do this last.** With the overlay on, changes (hostname, settings, files) are lost at the next reboot. To change something later: turn the overlay **and** the boot write protection off in the same menu, reboot, make the change, then turn both back on.

## The three scripts

### `initialsetup-lazycast.sh`

One-time system setup for a Pi built from source (already applied in the image). Run with `sudo`.

- Installs `figlet` for the large name and PIN on the splash.
- Sets the console font to Terminus 16x32.
- Adds boot options to `cmdline.txt` for a clean screen: `quiet loglevel=3 consoleblank=0 logo.nologo vt.global_cursor_default=0`.
- Disables the login prompt on tty1 (tty2–tty6 remain available).
- Writes and enables the `lazycast` systemd service (`/etc/systemd/system/lazycast.service`), which waits for the Wi-Fi Direct interface, pauses, then starts `all.sh`.

It doesn't modify `all.sh` or `d2.py` and is safe to run more than once.

### `configure-lazycast.sh`

Sets the per-Pi options and saves them to `~/lazycast/lazycast.conf`.

| Command | What it does |
|---|---|
| `sudo ./configure-lazycast.sh` | Asks four questions, saves the settings, and offers to reboot to apply them |
| `./configure-lazycast.sh --show` | Shows the current settings (or the defaults if no file exists yet) and what `auto` means on this Pi |

The questions:

1. **Maximum frame rate:** `30`, `60` or `auto`.
2. **2.4 GHz channel:** automatic, or fixed (1–11; 1, 6 or 11 recommended).
3. **40 MHz channel width:** on or off. Only used on models whose Wi-Fi chip supports it.
4. **5 GHz channel:** 36 (default) or another non-DFS channel: 36, 40, 44, 48, 149, 153, 157, 161, 165. With 40 MHz on, the second channel of a pair is saved as the first (for example 48 → 44), because starting on the second channel can be rejected.

Settings are applied by **reboot**. With the overlay on, the script warns that changes only last until the next reboot.

### `prepare-image.sh`

Cleans a finished Pi so its SD card can be captured as a template image for cloning. Run with `sudo` as the last step before capturing.

**Checks first** (and asks before continuing if anything is wrong): `all.sh` and `d2.py` are executable and have Linux line endings, the `d2.py` fixes are present, the service is enabled, and the hostname matches `/etc/hosts`.

**Then removes** everything specific to this Pi or the screen it was tested on: the log, the cached TV information (`edid.txt`), DHCP leases, saved Wi-Fi Direct groups, the machine ID, the DHCP client ID and the SSH host keys. Each clone recreates these on first boot. It also clears logs and shell history, offers to disable SSH, and offers to shut down.

**Do not boot the card again before capturing it** — booting recreates what was just removed.

## Settings (`lazycast.conf`)

`~/lazycast/lazycast.conf` is written by `configure-lazycast.sh`. It is optional: without it, the defaults below apply.

| Setting | Default | Meaning |
|---|---|---|
| `FPS` | `auto` | Maximum frame rate: `30` (max 1080p30), `60` (up to 1080p50 / 720p60), `auto` (30 on Pi 2/3/Zero, 60 on Pi 4 and newer) |
| `FREQ_24` | `auto` | 2.4 GHz channel (as a frequency in MHz) for 2.4 GHz-only models |
| `FREQ_5` | `5180` | 5 GHz channel (as a frequency in MHz) for 5 GHz-capable models; `5180` is channel 36 |
| `ALLOW_HT40` | `0` | `1` allows 40 MHz width where the chip supports it; `0` uses 20 MHz |

`all.sh` only accepts values from the known lists; anything else falls back to the defaults. The frame rate is read at every new connection.

**Channel lists are for the US (FCC).** Other countries allow different channels.

**Why 20 MHz and channel 36 by default:** in testing, a 5 GHz group occasionally started on a DFS channel, and some laptops (an Intel Wi-Fi 7 card in particular) then hid the receiver. A fixed non-DFS channel at 20 MHz was the most compatible. 20 MHz on 5 GHz still provides several times the bandwidth a Miracast stream needs.

## Creating your own image

Use this to build one template and clone it to many Pis.

1. Set up one Pi completely (Option A or B), **without** the overlay file system, and test it.
2. Run the cleanup and let it shut down:

   ```
   sudo ./prepare-image.sh
   ```

3. Remove the SD card and read it into an image file:
   - **Windows:** [Win32 Disk Imager](https://sourceforge.net/projects/win32diskimager/) → choose the card's drive → **Read** (not Write). If Windows offers to format the card, click **Cancel**.
   - **Linux/macOS:** `sudo dd if=/dev/sdX of=lazycast.img bs=4M status=progress` (replace `/dev/sdX` with the card).
4. **Optional, recommended: shrink the image** with [PiShrink](https://github.com/Drewsif/PiShrink) (Linux or WSL). It shrinks the image to the used space, makes it expand automatically on first boot, and `-Z` compresses it:

   ```
   sudo ./pishrink.sh -Z lazycast.img
   ```

   Without shrinking, the image can only be written to cards at least as large as the original.
5. Write it to new cards with Raspberry Pi Imager (**Use custom**, **no** OS customisation), then follow [Setting up each Pi](#setting-up-each-pi) on each one.

To update the template later: boot it, make the change, run `prepare-image.sh` again, and capture a new image.

## How it behaves

- **Name:** the hostname is the broadcast name.
- **Startup:** lazycast waits about 30 seconds after boot before starting. Allow about a minute before the Pi appears in WIN+K. A Pi Zero 2 W can occasionally take a little longer while it retries the group start.
- **PIN:** random, shown on the splash, and replaced with a new one after every cast. Each laptop normally only needs it the first time; with the overlay on, laptops may need to pair again after the Pi reboots.
- **Network:** no Wi-Fi network (SSID) is configured. The Pi works purely over Wi-Fi Direct and doesn't need to be on your network.
- **SSH:** disabled in the image. Enable it temporarily with `sudo raspi-config nonint do_ssh 0` if needed.
- **Weekly restart:** lazycast restarts every Sunday at 3:00 (if the cron entry is installed).
- **Self-healing:** if the Wi-Fi Direct group fails to start, gets stuck, or lands on a DFS channel, it's rebuilt automatically within seconds. If a configured channel is rejected repeatedly, 5 GHz models fall back to channel 6 on 2.4 GHz, and every new group start tries the configured channel first again.

## Troubleshooting

**Turn on the log** (off by default to protect the SD card): in `~/lazycast/all.sh`, comment out `LOG=/dev/null` and uncomment the line below it, then `sudo systemctl restart lazycast`. Read it with `tail -f ~/lazycast/lazycast.log`. Turn it off again afterwards. With the overlay on, the change only lasts until the next reboot — convenient for one-off diagnosis.

**Useful commands:**

```
systemctl status lazycast --no-pager          # is the service running?
sudo wpa_cli interface                        # Wi-Fi Direct group (p2p-wlan0-N)
sudo wpa_cli -i p2p-wlan0-N status            # should show mode=P2P GO, wpa_state=COMPLETED
iw dev p2p-wlan0-N info | grep -iE "channel|width"
vcgencmd measure_temp; vcgencmd get_throttled # heat / power problems (0x0 = fine)
```

**Common issues:**

| Symptom | Likely cause |
|---|---|
| Pi shows the old name (e.g. `change-me`) | Hostname longer than 32 characters, or contains invalid characters |
| `sudo: unable to resolve host` | `/etc/hosts` doesn't match the hostname; fix the `127.0.1.1` line |
| Scripts fail with `No such file or directory` or `bad interpreter` | Windows line endings: `sed -i 's/\r$//' <file>` (use binary mode in WinSCP) |
| One laptop can't see the Pi, others can | Remove the Pi under Settings → Bluetooth & devices → Devices on that laptop; check the Pi isn't on a DFS channel |
| Video lags or the Pi gets hot (Pi 3B) | Use `FPS=30`, add heatsinks and ventilation |

## Known limitations

- **HDCP** (copy-protected content) is not supported.
- **Channel lists are US-specific.**
- **Hostname:** 32 characters maximum.
- **Pairing memory:** with the overlay on, or after the saved group changes, laptops may need to enter the PIN again.
- **Raspberry Pi OS Bookworm and 64-bit** are not supported (the player depends on the legacy Bullseye userland).

## Credits and license

- Original lazycast by [homeworkc](https://github.com/homeworkc/lazycast).
- Education Edition modifications by MMaitner.

Licensed under the **GNU General Public License v3.0**, like the original. Modified files are marked and the changes are documented in the [changelog](CHANGELOG.md). Note the original project's statement: *"Using any part of the codes in this project in commercial products is prohibited."*
