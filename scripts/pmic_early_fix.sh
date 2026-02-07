#!/system/bin/sh
# === xTREMEsPEED PMIC Early Fix — post-fs-data ===
# Runs before Android services start
# Disables SMBCHG USBIN monitoring to prevent hardware power cuts

# 0. Clear pstore to prevent Magisk safe mode
cp /sys/fs/pstore/console-ramoops-0 /data/local/tmp/last_crash_log 2>/dev/null
rm -f /sys/fs/pstore/console-ramoops* 2>/dev/null
rm -f /sys/fs/pstore/pmsg-ramoops* 2>/dev/null

# 1. Disable SMBCHG charging — keep USB power path active
echo 0 > /sys/class/power_supply/battery/charging_enabled

# 2. Disable SMBCHG USBIN power path via PMIC registers
cd /sys/kernel/debug/spmi/spmi-0
echo 1 > count
echo 0x21316 > address && echo 0x7F > data
echo 0x213D0 > address && echo 0xA5 > data
echo 0x213F1 > address && echo 0x00 > data
echo 0x213D0 > address && echo 0xA5 > data
echo 0x213F3 > address && echo 0x00 > data

# 3. Re-enable APSD + SRC_DET for USB data only
echo 0x213D0 > address && echo 0xA5 > data
echo 0x213F1 > address && echo 0x02 > data
echo 0x21315 > address && echo 0x04 > data

# 4. Disable PMIC thermal comparators
echo 0x210D0 > address && echo 0xA5 > data
echo 0x210FA > address && echo 0x18 > data
echo 0x212D0 > address && echo 0xA5 > data
echo 0x212F2 > address && echo 0x00 > data
echo 0x21218 > address && echo 0xFF > data

log -t xTREMEsPEED "PMIC early fix applied — USBIN disabled, thermals disabled"
