# xTREMEsPEED Kernel

Custom kernel for the **Google Pixel 1 (Sailfish/Marlin)** running without a battery — powered directly via USB charger.

## What This Does

The Pixel 1 without a battery reads garbage values from the battery thermistor (60-75°C), causing Android to report "Overheat" and eventually trigger a thermal shutdown. This kernel patches the power subsystem at the driver level to:

| Patch | File | Effect |
|-------|------|--------|
| Fake temperature | `qpnp-fg.c` | Fuel gauge always reports 25.0°C (250 decidegrees) |
| Force health GOOD | `qpnp-smbcharger.c` | Charger driver always returns `POWER_SUPPLY_HEALTH_GOOD` |
| Fake charger temp | `qpnp-smbcharger.c` | Charger temp always returns 25.0°C |
| Disable shutdown | `htc_battery.c` | Blocks critical shutdown, voltage shutdown, overheat tracking |
| Force level 99% | `htc_battery.c` | Battery level always reports 99% |
| Raise thermal limits | `msm8996-htc_sailfish.dtsi` | Warm/hot thresholds raised to 90°C, cold to -40°C |
| Watchdog auto-reboot | `defconfig` | `CONFIG_PANIC_TIMEOUT=5` — auto-reboot on kernel panic |
| Charger mode bypass | `init/main.c` | Forces `androidboot.mode=main` — prevents USB charger bootloop |

### Before vs After

| Reading | Stock (no battery) | xTREMEsPEED |
|---------|-------------------|-------------|
| Temperature | 622 (62.2°C garbage) | **250 (25.0°C)** |
| Health | Overheat | **Good** |
| Capacity | Fluctuating | **99%** |
| Thermal shutdown | Yes, within minutes | **Never** |
| USB boot | Charger mode bootloop | **Normal boot** |

## Build

### Prerequisites

- Docker (with `--platform linux/amd64` support)
- ~2GB disk for toolchains, ~4GB for kernel source + build
- `fastboot` (Android Platform Tools)

### Quick Build

```bash
# 1. Build the Docker image (one-time)
docker build --platform linux/amd64 -t xtremespeed .

# 2. Build the kernel
docker run --rm \
  --platform linux/amd64 \
  -v xtremespeed-src:/kernel/msm \
  -v "$(pwd)/out:/kernel/out" \
  -v "$(pwd)/stock_config:/kernel/out/stock_config:ro" \
  -v "$(pwd)/build.sh:/kernel/build.sh:ro" \
  xtremespeed /kernel/build.sh

# Output: out/arch/arm64/boot/Image.lz4-dtb
```

The first run clones the kernel source (~1.5GB) into the `xtremespeed-src` Docker volume. Subsequent builds reuse the cached source.

### Clean Build (No Patches)

To build a stock-equivalent kernel without xTREMEsPEED patches (useful for debugging):

```bash
docker run --rm \
  --platform linux/amd64 \
  -v xtremespeed-src:/kernel/msm \
  -v "$(pwd)/out:/kernel/out" \
  -v "$(pwd)/stock_config:/kernel/out/stock_config:ro" \
  -v "$(pwd)/build_clean.sh:/kernel/build_clean.sh:ro" \
  xtremespeed /kernel/build_clean.sh
```

## Flash

### Create Boot Image

You need the stock `boot.img` ramdisk. Extract it from the [factory image](https://developers.google.com/android/images#sailfish):

```bash
# Download and extract factory image
unzip sailfish-qp1a.191005.007.a3-factory-*.zip
cd sailfish-qp1a.191005.007.a3
unzip image-sailfish-qp1a.191005.007.a3.zip boot.img

# Unpack stock boot.img
python3 mkbootimg/unpack_bootimg.py --boot_img boot.img --out boot_unpacked

# Repack with xTREMEsPEED kernel
python3 mkbootimg/mkbootimg.py \
  --kernel out/arch/arm64/boot/Image.lz4-dtb \
  --ramdisk boot_unpacked/ramdisk \
  --cmdline "console=ttyHSL0,115200,n8 androidboot.console=ttyHSL0 androidboot.hardware=sailfish user_debug=31 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 cma=32M@0-0xffffffff loop.max_part=7 buildvariant=user veritykeyid=id:7580d366b6e2804279fd88e290c82a5a7d5dd610" \
  --base 0x80000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --second_offset 0x00f00000 --tags_offset 0x00000100 --pagesize 4096 \
  --os_version 10.0.0 --os_patch_level 2019-10 --header_version 0 \
  --output boot_xtremespeed.img
```

### Flash to Device

```bash
# Unlock bootloader (one-time, WIPES DATA)
fastboot flashing unlock

# Flash to both A/B slots
fastboot flash boot_a boot_xtremespeed.img
fastboot flash boot_b boot_xtremespeed.img
fastboot reboot
```

### Verify

```bash
adb shell uname -r
# → 3.18.137-xTREMEsPEED

adb shell cat /sys/class/power_supply/battery/temp
# → 250

adb shell cat /sys/class/power_supply/battery/health
# → Good

adb shell cat /sys/class/power_supply/battery/capacity
# → 99
```

## Technical Details

### Kernel Source

- **Branch:** [`android-msm-marlin-3.18-android10`](https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-marlin-3.18-android10)
- **Version:** 3.18.137 (Google's final release for Pixel 1)
- **Config:** Extracted from factory `boot.img` via `extract-ikconfig`

### Compiler

**Linaro GCC 4.9.4** (2017.01) — the only compiler that produces bootable kernels for msm-3.18.

| Compiler | Compiles? | Boots? |
|----------|-----------|--------|
| GCC 4.9 (Linaro) | Yes | **Yes** |
| GCC 9 | Yes (with `-Wno-error`) | No |
| GCC 12 | Yes | No |

The stock kernel was compiled with `gcc version 4.9.x 20150123 (prerelease)` (Google's AOSP prebuilt). Linaro GCC 4.9.4 is ABI-compatible and produces working kernels.

### Build Fix: SMP2P Mock Functions

The kernel source has an upstream bug where `smp2p.c` unconditionally calls mock/test functions (`smp2p_remote_mock_rx_interrupt`, `msm_smp2p_get_remote_mock_smem_item`) that are only compiled when `CONFIG_MSM_SMP2P_TEST=y`. The stock config doesn't enable this test module.

Our fix wraps these calls with `#ifdef CONFIG_MSM_SMP2P_TEST` guards — the mock code paths are for a fake "MOCK_PROC" that doesn't exist on real hardware, so guarding them out is safe.

### Apple Silicon Note

On Apple Silicon Macs, Docker must use `--platform linux/amd64` to force QEMU x86_64 emulation. Linaro's GCC 4.9 toolchain is x86_64-only and cannot run under Rosetta (it errors with `rosetta error: failed to open elf at /lib64/ld-linux-x86-64.so.2`). Build times are ~10 minutes under QEMU emulation.

## What Still Needs Magisk

This kernel replaces the battery/thermal workarounds but **cannot** replace Magisk for:

| Script | Purpose | Why Magisk |
|--------|---------|-----------|
| `prop.sh` | Security patch date spoofing | `resetprop` (Magisk-only API) |
| `shamiko.sh` | Boot state spoofing (locked/green) | Requires Magisk Hide / Shamiko |
| `hash.sh` | VBMeta digest spoofing | `resetprop` |
| `lineage.sh` | LineageOS prop cleanup | `resetprop` |
| `custom.pif.prop` | Play Integrity fingerprint | Magisk module (PIF) |

## License

Kernel source is GPL v2 (inherited from Linux kernel). Build scripts and patches are MIT.
