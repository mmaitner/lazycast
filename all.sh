#!/bin/bash
#################################################################################
# Run script for lazycast
# Licensed under GNU General Public License v3.0 GPL-3 (in short)
#
#   You may copy, distribute and modify the software as long as you track
#   changes/dates in source files. Any modifications to our software
#   including (via compiler) GPL-licensed code must also be made available
#   under the GPL along with build & install instructions.
#
#################################################################################
managefrequency=0
LD_LIBRARY_PATH=/opt/vc/lib
export LD_LIBRARY_PATH
export PYTHONUNBUFFERED=1

# Wi-Fi settings from lazycast.conf (written by configure-lazycast.sh).
# Only known values are accepted; anything else falls back to the defaults.
CONF="$(dirname "$(readlink -f "$0")")/lazycast.conf"
FREQ_24=auto; FREQ_5=5180; ALLOW_HT40=0
v=$(sed -n 's/^FREQ_24=\([0-9]*\)$/\1/p' "$CONF" 2>/dev/null | tail -1)
case "$v" in 2412|2417|2422|2427|2432|2437|2442|2447|2452|2457|2462) FREQ_24=$v ;; esac
v=$(sed -n 's/^FREQ_5=\([0-9]*\)$/\1/p' "$CONF" 2>/dev/null | tail -1)
case "$v" in 5180|5200|5220|5240|5745|5765|5785|5805|5825) FREQ_5=$v ;; esac
v=$(sed -n 's/^ALLOW_HT40=\([01]\)$/\1/p' "$CONF" 2>/dev/null | tail -1)
[ -n "$v" ] && ALLOW_HT40=$v
case "$(tr -d '\0' < /proc/device-tree/model)" in
  *"Pi 3 Model B Plus"*|*"Pi 3 Model A Plus"*|*"Raspberry Pi 4"*|*"Raspberry Pi 5"*|*"Compute Module 4"*|*"Compute Module 5"*)
    GOFREQ_CFG="freq=$FREQ_5"; HT40=$ALLOW_HT40
    GOFREQ_FALLBACK="freq=2437" ;;   # if the 5 GHz channel is rejected: 2.4 GHz ch 6 (never DFS)
  *)
    if [ "$FREQ_24" = auto ]; then GOFREQ_CFG=""; else GOFREQ_CFG="freq=$FREQ_24"; fi
    HT40=0
    GOFREQ_FALLBACK="" ;;            # 2.4 GHz has no DFS channels, automatic is safe
esac


iw dev wlan0 set power_save off 2>/dev/null

PINFILE=/run/lazycast.pin

new_pin() {   # 7 random digits + WPS checksum digit
  local p acc
  p=$(( $(od -An -N4 -tu4 /dev/urandom) % 9000000 + 1000000 ))
  acc=$(( 3*(p/1000000%10 + p/10000%10 + p/100%10 + p%10) + (p/100000%10 + p/1000%10 + p/10%10) ))
  echo "$p$(( (10 - acc % 10) % 10 ))" > "$PINFILE"
}
current_pin() { cat "$PINFILE" 2>/dev/null; }


# Logging: off by default. For troubleshooting, swap the two lines.
LOG=/dev/null
#LOG="$(dirname "$(readlink -f "$0")")/lazycast.log"

{ exec 3>/dev/tty1; } 2>/dev/null || exec 3>/dev/null
exec >"$LOG" 2>&1           # everything else goes to the log

center() { printf "%*s\n" $(( (${#1} + COLS) / 2 )) "$1"; }

show_screen() {   # $1 = "ready" or "starting"
  COLS=$(stty -F /dev/tty1 size 2>/dev/null | awk '{print $2}')
  [ -z "$COLS" ] && COLS=80
  {
    printf '\033[2J\033[H'           # clear
    setterm --cursor off 2>/dev/null
    echo; echo
    if [ "$1" = "ready" ]; then
      printf '\033[1;37m'; center "Press WIN + K and select:"; echo
      printf '\033[1;36m'; figlet -c -w "$COLS" "$(uname -n)"; echo
      printf '\033[1;37m'; center "PIN:"; echo
      printf '\033[1;33m'; figlet -c -w "$COLS" "$(current_pin)"
    else
      printf '\033[1;37m'; center "Starting up, please wait..."
    fi
    printf '\033[0m'
  } >&3
}

screen_watcher() {
  local state="" new shown=""
  while :; do
    if ss -Htn state established '( dport = :7236 or sport = :7236 )' | grep -q .; then
      new=casting
    else
      new=ready
    fi
    if [ "$state" = casting ] && [ "$new" = ready ]; then
      new_pin                                  # a cast just ended: new PIN
    fi
    if [ "$new" = casting ]; then
      [ "$state" != casting ] && printf '\033[2J\033[H' >&3
    elif [ "$state" != ready ] || [ "$(current_pin)" != "$shown" ]; then
      shown=$(current_pin)
      show_screen ready
    fi
    state=$new
    sleep 1
  done
}

WATCHER=""
trap '[ -n "$WATCHER" ] && kill $WATCHER 2>/dev/null' EXIT


new_pin
ARMED_PIN=""

show_screen starting


while :
do
	p2pdevinterface=$(sudo wpa_cli interface | grep -E "p2p-dev" | tail -1)
	wlaninterface=$(echo $p2pdevinterface | cut -c1-8 --complement)
	echo $p2pdevinterface
	echo $wlaninterface
	ain="$(sudo wpa_cli interface)"
	echo "${ain}"
	if [ `echo "${ain}" | grep -c "p2p-wl"` -gt 0 ] 
	then
		echo "already on"

	else
		sudo wpa_cli -i$p2pdevinterface p2p_stop_find
		sleep 3
		GOFREQ=$GOFREQ_CFG    # try the configured channel first
		if [ "${DFSHITS:-0}" -ge 2 ]; then
			GOFREQ=$GOFREQ_FALLBACK   # configured channel kept ending up on DFS: use the safe one this time
			DFSHITS=0
		fi
		FAILS=0
		sudo wpa_cli -i$p2pdevinterface set device_name "$(uname -n)"
		sudo wpa_cli -i$p2pdevinterface set device_type 7-0050F204-1
		sudo wpa_cli -i$p2pdevinterface set p2p_go_ht40 $HT40
		sudo wpa_cli -i$p2pdevinterface wfd_subelem_set 0 000600111c44012c
		sudo wpa_cli -i$p2pdevinterface wfd_subelem_set 1 0006000000000000
		sudo wpa_cli -i$p2pdevinterface wfd_subelem_set 6 000700000000000000
		perentry="$(sudo wpa_cli -i$p2pdevinterface list_networks | grep "\[DISABLED\]\[P2P-PERSISTENT\]" | tail -1)"
		echo "${perentry}"
		if [ `echo "${perentry}" | grep -c "P2P-PERSISTENT"`  -gt 0 ] 
		then
			networkid=${perentry%%D*}
			perstr="=${networkid}"
		else
			perstr=""
		fi
		echo "${perstr}"
		echo "${p2pdevinterface}"
		wlanfreq=$(sudo wpa_cli -i$wlaninterface status | grep "freq")
		if [ "$managefrequency" == "0" ]
		then
			wlanfreq=""
		fi
		if [ "$wlanfreq" != "" ]
		then	
			echo $wlaninterface": "$wlanfreq
			echo "Setting up wifi p2p with "$wlanfreq
		fi
		while [ `echo "${ain}" | grep -c "p2p-wl"`  -lt 1 ] 
		do
			while [ `echo "${ain}" | grep -c "p2p-wl"`  -lt 1 ]
			do
				#sudo wpa_cli p2p_group_add -i$p2pdevinterface persistent$perstr freq=2
				result=$(sudo wpa_cli p2p_group_add -i$p2pdevinterface persistent$perstr $GOFREQ)
				echo "p2p_group_add ${GOFREQ:-(auto)} -> $result"
				if [ "$result" == "FAIL" ]					
				then
					wlanfreq=""
					managefrequency=0
					FAILS=$((FAILS + 1))
					if [ "$FAILS" -ge 6 ]; then GOFREQ=""                       # last resort: let the Pi choose
					elif [ "$FAILS" -ge 3 ]; then GOFREQ=$GOFREQ_FALLBACK; fi   # safe fallback channel
				fi
				sleep 2
				ain="$(sudo wpa_cli interface)"
				echo "$ain"
			done
			sleep 5
			ain="$(sudo wpa_cli interface)"
		    echo "$ain"
		done

	fi

	p2pinterface=$(echo "${ain}" | grep "p2p-wl" | grep -v "interface")
	echo $p2pinterface

	sudo ifconfig $p2pinterface 192.168.173.1
	printf "start	192.168.173.80\n">udhcpd.conf
	printf "end	192.168.173.80\n">>udhcpd.conf
	printf "interface	$p2pinterface\n">>udhcpd.conf
	printf "option subnet 255.255.255.0\n">>udhcpd.conf
	printf "option lease 30">>udhcpd.conf
	sleep 3
	sudo rm -f /var/lib/misc/udhcpd.leases
	pkill -f '^busybox udhcpd'
	sudo busybox udhcpd ./udhcpd.conf 
	echo "The display is ready"
	echo "Your device is called: "$(uname -n)""
	if [ -z "$WATCHER" ]; then
  		screen_watcher &
  		WATCHER=$!
	fi
	while :
	do

		PIN=$(current_pin)
		if [ "$PIN" != "$ARMED_PIN" ]; then
			sudo wpa_cli -i$p2pinterface wps_cancel    # drop the old PIN
			ARMED_PIN=$PIN
		fi
		sudo wpa_cli -i$p2pinterface wps_pin any $PIN
		./d2.py
		# Group must be running, and never on a DFS channel (5250-5730 MHz):
		# many laptops (e.g. Intel) hide or refuse a Miracast receiver there.
		st=$(sudo wpa_cli -i$p2pinterface status)
		f=$(echo "$st" | sed -n 's/^freq=//p')
		ondfs=0
		[ -n "$f" ] && [ "$f" -ge 5250 ] && [ "$f" -le 5730 ] && ondfs=1
		if ! echo "$st" | grep -q "wpa_state=COMPLETED" || [ "$ondfs" = 1 ]; then
			[ "$ondfs" = 1 ] && echo "Group $p2pinterface is on DFS channel ($f MHz)"
			BAD=$((BAD + 1))
			if [ "$BAD" -ge 3 ]; then
				BAD=0
				[ "$ondfs" = 1 ] && DFSHITS=$(( ${DFSHITS:-0} + 1 ))
				sudo wpa_cli -i$p2pdevinterface p2p_group_remove $p2pinterface
				sleep 2
				break
			fi
		else
			BAD=0
		fi

		if [ `sudo wpa_cli interface | grep -c "p2p-wl"` == 0 ] 
		then
			break
		fi
		
		wlanfreq=$(sudo wpa_cli -i$wlaninterface status | grep "freq")
		p2pfreq=$(sudo wpa_cli -i$p2pinterface status | grep "freq")
		if [ "$managefrequency" == "0" ]
		then
			wlanfreq=""
		fi
		if [ "$wlanfreq" != "" ]
		then		
			if [ "$wlanfreq" != "$p2pfreq" ] 
			then
				echo "The display is disconnected since "$wlaninterface" changes from "$p2pfreq" to "$wlanfreq
				echo "To disable WLAN roaming, run: sudo killall -STOP NetworkManager"
				echo "You can re-enable roaming afterwards by running: sudo killall -CONT NetworkManager"
				sudo wpa_cli -i$p2pinterface p2p_group_remove $p2pinterface
				while :
				do
					if [ `sudo wpa_cli interface | grep -c "p2p-wl"` == 0 ] 
					then
						break
					fi
				done
				break
			fi
		fi

	done
done
