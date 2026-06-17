#!/system/bin/sh
# Enable the USB DIAG function on LineageOS via configfs, as root, SELinux permissive.
# Adds diag without removing existing functions (adb survives). Not persistent (reboot reverts).
set -x
setenforce 0 2>/dev/null

G=$(ls -d /config/usb_gadget/* 2>/dev/null | head -1)
if [ -z "$G" ]; then echo "NO usb_gadget configfs found"; exit 1; fi
echo "gadget=$G"

C=$(ls -d "$G"/configs/* 2>/dev/null | head -1)
echo "config=$C"
UDC_NAME=$(ls /sys/class/udc 2>/dev/null | head -1)
echo "udc=$UDC_NAME"

echo "BEFORE: UDC=$(cat $G/UDC 2>/dev/null)"
echo "BEFORE functions in config:"; ls -l "$C" 2>/dev/null | grep '\->'

# create the diag function instance if missing
[ -d "$G/functions/diag.diag" ] || mkdir "$G/functions/diag.diag"

# unbind, add diag link (keep existing links), rebind
echo "" > "$G/UDC" 2>/dev/null
sleep 1
ln -sf "$G/functions/diag.diag" "$C/diag.diag" 2>/dev/null
echo "$UDC_NAME" > "$G/UDC" 2>/dev/null
sleep 1

echo "AFTER: UDC=$(cat $G/UDC 2>/dev/null)"
echo "AFTER functions in config:"; ls -l "$C" 2>/dev/null | grep '\->'
echo "done. From the Mac run: qfenix list ; ls /dev/cu.* ; system_profiler SPUSBDataType | grep -i diag"
