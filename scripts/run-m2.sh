#!/usr/bin/env bash
# run-m2.sh - boot an image, catch the plog before Android wraps the ring.
# The loader writes its plog into the ramoops rings. Android logd appends
# after our text and wraps the 2 MiB ring in about 30-40 seconds. So: the
# instant adb sees Android, bounce to recovery and dump the pmsg record.
set -uo pipefail
IMG="$1"
cd "$(dirname "$0")/../gsloader"

adb reboot bootloader 2>/dev/null
for i in $(seq 1 40); do
  [ -n "$(fastboot devices 2>/dev/null)" ] && break
  sleep 2
done
T0=$(date +%s)
fastboot boot "$IMG" >/dev/null 2>&1 && echo "SENT t=$(( $(date +%s) - T0 ))s"

for i in $(seq 1 240); do
  ST=$(adb devices 2>/dev/null | awk 'NR>1 && NF {print $2}' | head -1)
  if [ "$ST" = "device" ]; then
    echo "ANDROID t=$(( $(date +%s) - T0 ))s -> recovery NOW"
    adb reboot recovery
    break
  fi
  sleep 1
done
sleep 20
for i in $(seq 1 40); do
  ST=$(adb devices 2>/dev/null | awk 'NR>1 && NF {print $2}' | head -1)
  if [ "$ST" = "recovery" ]; then break; fi
  sleep 3
done
echo "RECOVERY state=$ST t=$(( $(date +%s) - T0 ))s"
if [ "$ST" = "recovery" ]; then
  echo "==== PLOG ===="
  adb shell "head -c 4096 /sys/fs/pstore/pmsg-ramoops-0" 2>/dev/null | strings | head -60
else
  echo "recovery unauthorized; dump later: adb shell head -c 4096 /sys/fs/pstore/pmsg-ramoops-0"
fi
