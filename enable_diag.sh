#!/system/bin/sh
# Expose the KERNEL diag function (diag.diag = f_diag) on CPH2459/holi via configfs,
# keeping ffs.adb linked so adb returns after the UDC rebind.
# Why not `setprop sys.usb.config diag,adb`: OPlus's USB HAL maps "diag" to ffs.diag,
# which needs a diag-router daemon that LineageOS doesn't run -> invalid gadget, adb dies.
# Run DETACHED (nohup &) so the brief UDC unbind doesn't kill the script with the shell.
# Not persistent: a reboot reverts to the normal adb-only gadget.
setenforce 0 2>/dev/null
G=/config/usb_gadget/g1
UDC=4e00000.dwc3
C=$(ls -d "$G"/configs/* 2>/dev/null | head -1)
echo "config=$C"
echo "BEFORE:"; ls -l "$C" 2>/dev/null | grep '\->'
# ensure the kernel diag function instance exists (it does on this device)
[ -d "$G/functions/diag.diag" ] || mkdir "$G/functions/diag.diag"
# unbind, add kernel diag alongside existing adb, rebind
echo "" > "$G/UDC" 2>/dev/null
sleep 1
ln -sf "$G/functions/diag.diag" "$C/f_diag" 2>/dev/null
echo "$UDC" > "$G/UDC" 2>/dev/null
sleep 2
echo "AFTER:"; ls -l "$C" 2>/dev/null | grep '\->'
echo "UDC=$(cat $G/UDC 2>/dev/null)"
