#!/bin/bash
# Network setup for the laptop trader on macOS.
#
# The FPGA exchange sends market data to MAC 02:00:00:00:00:01 /
# 192.168.10.1:5000 and does not answer ARP. This script sets up the Ethernet
# interface the exchange is cabled to so it receives those frames and can reply:
#   - MAC address 02:00:00:00:00:01 (lasts until the adapter is unplugged or
#     the Mac restarts; run the script again after that)
#   - static IP 192.168.10.1/24 on the interface's network service
#   - static ARP entry: 192.168.10.2 -> 02:00:00:00:00:02 (the exchange)
#
# Connect the cable first, then:
#   networksetup -listallhardwareports   # find the device, e.g. en5
#   sudo bash host/setup_mac.sh en5
# Undo (DHCP back on, original MAC, ARP entry removed):
#   sudo bash host/setup_mac.sh en5 --restore

set -euo pipefail

TRADER_MAC=02:00:00:00:00:01
TRADER_IP=192.168.10.1
EXCHANGE_IP=192.168.10.2
EXCHANGE_MAC=02:00:00:00:00:02

if [ $# -lt 1 ]; then
  echo "usage: sudo bash $0 <device, e.g. en5> [--restore]" >&2
  networksetup -listallhardwareports >&2
  exit 1
fi
IF=$1
RESTORE=${2:-}

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 1
fi

# networksetup works on network service names, not devices. The service order
# listing pairs them: "(1) USB 10/100/1000 LAN" then "(Hardware Port: ..., Device: en5)".
SERVICE=$(networksetup -listnetworkserviceorder | awk -v dev="$IF" '
  /^\([0-9*]+\) / { sub(/^\([0-9*]+\) /, ""); name = $0 }
  index($0, "Device: " dev ")") { print name; exit }')
if [ -z "$SERVICE" ]; then
  echo "no network service uses device $IF. Devices:" >&2
  networksetup -listallhardwareports >&2
  exit 1
fi
echo "Interface $IF, service \"$SERVICE\""

if [ "$RESTORE" = "--restore" ]; then
  arp -d "$EXCHANGE_IP" ifscope "$IF" 2>/dev/null || true
  HW_MAC=$(networksetup -getmacaddress "$IF" | awk '{print $3}')
  ifconfig "$IF" ether "$HW_MAC"
  networksetup -setdhcp "$SERVICE"
  echo "Restored: DHCP on, MAC $HW_MAC, ARP entry removed."
  exit 0
fi

networksetup -setmanual "$SERVICE" "$TRADER_IP" 255.255.255.0
ifconfig "$IF" ether "$TRADER_MAC"
sleep 2

MAC_NOW=$(ifconfig "$IF" | awk '/ether/ {print $2}')
if [ "$MAC_NOW" != "$TRADER_MAC" ]; then
  echo "WARNING: MAC is $MAC_NOW, not $TRADER_MAC. Try: sudo ifconfig $IF down; sudo ifconfig $IF ether $TRADER_MAC; sudo ifconfig $IF up" >&2
fi

arp -d "$EXCHANGE_IP" ifscope "$IF" 2>/dev/null || true
arp -s "$EXCHANGE_IP" "$EXCHANGE_MAC" ifscope "$IF"

echo
echo "Done:"
ifconfig "$IF" | awk '/ether|inet / {print "  " $0}'
arp -n "$EXCHANGE_IP" | sed 's/^/  /'
echo
echo "If the macOS firewall is on, allow incoming connections for Python when asked."
echo "Now run:  python3 host/laptop_trader.py"
