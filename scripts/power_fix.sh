#!/system/bin/sh
# === xTREMEsPEED Power Fix — service.d ===
# Runs after boot_completed — reinforces PMIC fix + sets up CPU/ADB/rclone

# 1. Reinforce PMIC fix in case early script was partial
echo 0 > /sys/class/power_supply/battery/charging_enabled
cd /sys/kernel/debug/spmi/spmi-0
echo 1 > count
echo 0x21316 > address && echo 0x7F > data
echo 0x213D0 > address && echo 0xA5 > data
echo 0x213F1 > address && echo 0x00 > data
echo 0x213D0 > address && echo 0xA5 > data
echo 0x213F3 > address && echo 0x00 > data
echo 0x213D0 > address && echo 0xA5 > data
echo 0x213F1 > address && echo 0x02 > data
echo 0x21315 > address && echo 0x04 > data
echo 0x210D0 > address && echo 0xA5 > data
echo 0x210FA > address && echo 0x18 > data
echo 0x212D0 > address && echo 0xA5 > data
echo 0x212F2 > address && echo 0x00 > data
echo 0x21218 > address && echo 0xFF > data

# 2. CPU: all cores enabled, big cores at max 2.15GHz performance
for c in 0 1 2 3; do
  chmod 644 /sys/devices/system/cpu/cpu$c/online 2>/dev/null
  echo 1 > /sys/devices/system/cpu/cpu$c/online
  chmod 644 /sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor 2>/dev/null
done
echo 2150400 > /sys/devices/system/cpu/cpu2/cpufreq/scaling_max_freq 2>/dev/null
echo 2150400 > /sys/devices/system/cpu/cpu3/cpufreq/scaling_max_freq 2>/dev/null
echo performance > /sys/devices/system/cpu/cpu2/cpufreq/scaling_governor
echo performance > /sys/devices/system/cpu/cpu3/cpufreq/scaling_governor
echo 133000000 > /sys/class/kgsl/kgsl-3d0/max_gpuclk 2>/dev/null
pm disable-user com.franco.kernel 2>/dev/null

# 3. Enable WiFi ADB on port 5555
setprop service.adb.tcp.port 5555
stop adbd
start adbd

# 4. Background battery temp override
(
  while true; do
    if dumpsys battery set temp 250 2>/dev/null; then
      log -t xTREMEsPEED "Battery temp overridden"
      break
    fi
    sleep 0.5
  done
  while true; do
    sleep 30
    dumpsys battery set temp 250 2>/dev/null
  done
) &

# 5. Mount SMB share via rclone FUSE
(
  while true; do
    ping -c 1 -W 1 192.168.1.230 >/dev/null 2>&1 && break
    sleep 2
  done
  setenforce 0
  chmod 666 /dev/fuse
  mkdir -p /mnt/syncthing /data/local/tmp/rclone-cache
  PATH=/data/local/tmp:$PATH /data/local/tmp/rclone-bin mount syncthing:syncthing /mnt/syncthing \
    --config /data/local/tmp/rclone-config/rclone.conf \
    --allow-other --uid 1023 --gid 1023 --dir-perms 0775 --file-perms 0664 \
    --vfs-cache-mode minimal --cache-dir /data/local/tmp/rclone-cache \
    --daemon
  sleep 5
  for view in default read write full; do
    mkdir -p /mnt/runtime/$view/emulated/0/Pictures/Syncthing
    mount --bind /mnt/syncthing /mnt/runtime/$view/emulated/0/Pictures/Syncthing
  done
  mkdir -p /storage/emulated/0/Pictures/Syncthing
  mount --bind /mnt/syncthing /storage/emulated/0/Pictures/Syncthing
  setenforce 1
  log -t xTREMEsPEED "SMB share mounted at /sdcard/Pictures/Syncthing"
) &

log -t xTREMEsPEED "Power fix service applied — all systems go"
