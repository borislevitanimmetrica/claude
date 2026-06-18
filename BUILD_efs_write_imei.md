# Build & run efs_write_imei

Writes the factory IMEI (868957060298983) into the modem EFS item file
`/nv/item_files/modem/mmode/ue_imei_i` via the EFS2 PUT verb over /dev/diag.
Legacy NV_WRITE_F (0x27) is rejected (BAD_CMD 0x13); EFS2 is a different dispatch.

## Build (EC2) — use the SAME toolchain/flags that built nv_write_imei
The source is freestanding aarch64 (no libc), like nv_write_imei.c. Reuse whatever
command built `/phone/tmp/nv_write_imei`. Typically:

```
CC=$(ls -d /phone/lineage/prebuilts/clang/host/linux-x86/clang-r*/bin/clang 2>/dev/null | tail -1)
$CC --target=aarch64-linux-android31 -nostdlib -static -O2 \
    -ffreestanding -fno-builtin -fno-stack-protector -o efs_write_imei efs_write_imei.c
# (or: aarch64-linux-gnu-gcc -nostdlib -static -O2 -o efs_write_imei efs_write_imei.c)
file efs_write_imei      # expect: ELF 64-bit aarch64, statically linked
```

If unsure of the exact compiler, check how nv_write_imei was built:
```
head -40 /phone/tmp/diagchar_build/*.sh 2>/dev/null
grep -rn 'nv_write_imei' /phone/tmp 2>/dev/null | grep -iE 'clang|gcc|cc ' | head
```

## Deploy & run (Mac, device on adb)
```
scp -i ~/.ssh/immetrica_aws_useast1_private_key.pem ec2-user@immetrica.com:/phone/tmp/efs_write_imei /tmp/efs_write_imei
adb -s 9385711f root
adb -s 9385711f shell setenforce 0          # REQUIRED: modem QRTR path is denied under enforcing
# ensure diagchar.ko is loaded and /dev/diag exists (re-insmod if rebooted):
adb -s 9385711f shell 'ls -l /dev/diag || insmod /data/local/tmp/diagchar.ko'
adb -s 9385711f push /tmp/efs_write_imei /data/local/tmp/efs_write_imei
adb -s 9385711f shell 'chmod 755 /data/local/tmp/efs_write_imei; /data/local/tmp/efs_write_imei'
```

## Interpreting
- `PUT errno=0` + `*** SUCCESS ***` -> `adb reboot`, then dial `*#06#`.
- `PUT errno=<n>` -> EFS rejected the write; n tells us why (e.g. EACCES/EROFS =>
  modem gates EFS writes in normal mode -> need FTM). Paste the full hex dump.
- `unexpected cmd` / framing oddities -> paste the RX hex dump; likely a small
  envelope/offset tweak (the verbose hex_dump is there for exactly this).
- If HELLO never acks AND PUT gets no response, the EFS2 subsystem may be gated;
  paste output and we adjust (e.g. try EFS_ALT only, or add EFS2_DIAG_OPEN/WRITE/CLOSE).

## Notes
- After a reboot, diagchar.ko unloads; re-`insmod` it and re-`setenforce 0`
  before re-running. The IMEI write itself persists in modem EFS once it lands.
- We can also write the legacy alias `/nv/item_files/nv/550` the same way if
  needed, but `ue_imei_i` (mmode) is the path the modem reads.
