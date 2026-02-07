#!/bin/bash
set -euo pipefail

# xTREMEsPEED Patched Build — GCC 4.9, 3.18.137, all patches
# Based on working clean build + all 5 xTREMEsPEED patches

KERNEL_DIR="/kernel/msm"
OUT_DIR="/kernel/out"
ARCH="arm64"
CROSS_COMPILE="/toolchains/aarch64/bin/aarch64-linux-gnu-"
CROSS_COMPILE_ARM32="/toolchains/arm/bin/arm-linux-gnueabi-"
JOBS="$(nproc)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[xTREMEsPEED]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

set_config() {
    local config_file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$config_file"; then
        sed -i "s/^${key}=.*/${key}=${value}/" "$config_file"
    elif grep -q "^# ${key} is not set" "$config_file"; then
        sed -i "s/^# ${key} is not set/${key}=${value}/" "$config_file"
    else
        echo "${key}=${value}" >> "$config_file"
    fi
}

cd "$KERNEL_DIR"
mkdir -p "$OUT_DIR"

# ============================================================
# STEP 1: Fix SMP2P build issue (same as clean build)
# ============================================================
log "Fixing SMP2P mock references..."
if ! grep -q "SMP2P_BUILD_FIX" drivers/soc/qcom/smp2p.c; then
    python3 << 'PYFIX'
filepath = "drivers/soc/qcom/smp2p.c"
with open(filepath, "r") as f:
    content = f.read()
content = content.replace(
    '\tsmp2p_remote_mock_rx_interrupt();',
    '#ifdef CONFIG_MSM_SMP2P_TEST /* SMP2P_BUILD_FIX */\n\tsmp2p_remote_mock_rx_interrupt();\n#endif'
)
content = content.replace(
    '\t\titem_ptr = msm_smp2p_get_remote_mock_smem_item(&size);',
    '#ifdef CONFIG_MSM_SMP2P_TEST /* SMP2P_BUILD_FIX */\n\t\titem_ptr = msm_smp2p_get_remote_mock_smem_item(&size);\n#else\n\t\titem_ptr = NULL;\n#endif'
)
with open(filepath, "w") as f:
    f.write(content)
print("  Fixed SMP2P mock references")
PYFIX
fi

# ============================================================
# STEP 2: Apply xTREMEsPEED patches
# ============================================================
if grep -q "xTREMEsPEED" drivers/power/qpnp-fg.c 2>/dev/null; then
    warn "Patches already applied — skipping"
else
    # --- Patch 1/5: qpnp-fg.c — Fake battery temp at fuel gauge level ---
    log "[1/5] Patching qpnp-fg.c — hardcode temp to 25°C"
    python3 << 'PYEOF'
import re, sys
filepath = "drivers/power/qpnp-fg.c"
with open(filepath, "r") as f:
    content = f.read()
pattern = r'(case POWER_SUPPLY_PROP_TEMP:\s*\n)(.*?)(break;)'
replacement = (
    r'\1'
    '\t\t/* xTREMEsPEED: Always report 25.0°C — no battery present.\n'
    '\t\t * Thermistor reads garbage (60-75°C) triggering thermal shutdown. */\n'
    '\t\tval->intval = 250;\n'
    '\t\t\\3'
)
new_content, count = re.subn(pattern, replacement, content, count=1, flags=re.DOTALL)
if count == 0:
    print("WARNING: Could not find POWER_SUPPLY_PROP_TEMP case in qpnp-fg.c", file=sys.stderr)
    sys.exit(0)
with open(filepath, "w") as f:
    f.write(new_content)
print(f"  Patched {filepath}: replaced PROP_TEMP handler ({count} match)")
PYEOF

    # --- Patch 2/5: qpnp-smbcharger.c — Force health GOOD + temp 25°C ---
    log "[2/5] Patching qpnp-smbcharger.c — force health GOOD, temp 25°C"
    python3 << 'PYEOF'
import re, sys
filepath = "drivers/power/qpnp-smbcharger.c"
with open(filepath, "r") as f:
    content = f.read()
pattern = r'(static int get_prop_batt_health\(struct smbchg_chip \*chip\)\s*\{)\s*\n(.*?)(^\})'
replacement = (
    r'\1\n'
    '\t/* xTREMEsPEED: Always return GOOD — no battery, temp readings invalid. */\n'
    '\treturn POWER_SUPPLY_HEALTH_GOOD;\n'
    '}'
)
new_content, c1 = re.subn(pattern, replacement, content, count=1, flags=re.DOTALL | re.MULTILINE)
pattern2 = r'(static int get_prop_batt_temp\(struct smbchg_chip \*chip\)\s*\{)\s*\n(.*?)(^\})'
replacement2 = (
    r'\1\n'
    '\t/* xTREMEsPEED: Always return 25.0°C (250 decidegrees). */\n'
    '\treturn 250;\n'
    '}'
)
new_content, c2 = re.subn(pattern2, replacement2, new_content, count=1, flags=re.DOTALL | re.MULTILINE)
if c1 == 0:
    print("WARNING: Could not find get_prop_batt_health in smbcharger", file=sys.stderr)
if c2 == 0:
    print("WARNING: Could not find get_prop_batt_temp in smbcharger", file=sys.stderr)
with open(filepath, "w") as f:
    f.write(new_content)
print(f"  Patched {filepath}: health={c1}, temp={c2} matches")
PYEOF

    # --- Patch 3/5: htc_battery.c — Disable all shutdown paths ---
    log "[3/5] Patching htc_battery.c — disable shutdowns, force level 99%"
    if [ -f "drivers/power/htc_battery.c" ]; then
        python3 << 'PYEOF'
import re, sys
filepath = "drivers/power/htc_battery.c"
with open(filepath, "r") as f:
    content = f.read()
patches_applied = 0

# 3a: Disable g_critical_shutdown assignment
pattern_a = r'(case POWER_SUPPLY_PROP_CRITICAL_SHUTDOWN:\s*\n)\s*g_critical_shutdown\s*=.*?\n(.*?break;)'
repl_a = (
    r'\1'
    '\t\t/* xTREMEsPEED: Never trigger critical shutdown (battery-less). */\n'
    '\t\tpr_info("[BATT][xTREMEsPEED] critical shutdown BLOCKED\\n");\n'
    '\t\t\\2'
)
content, c = re.subn(pattern_a, repl_a, content, count=1, flags=re.DOTALL)
patches_applied += c

# 3b: Disable voltage-based shutdown
pattern_b = r'if\s*\(\s*g_critical_shutdown\s*\|\|.*?force_shutdown_batt_vol.*?\{[^}]*?rep\.level\s*=\s*0;[^}]*?\}'
repl_b = (
    '/* xTREMEsPEED: Voltage-based shutdown DISABLED.\n'
    '\t * Direct charger power has micro drops — no meaningful voltage. */\n'
    '\tif (0) { /* disabled */ }'
)
content, c = re.subn(pattern_b, repl_b, content, count=1, flags=re.DOTALL)
patches_applied += c

# 3c: Disable overheat tracking at 55°C
pattern_c = r'if\s*\(\s*htc_batt_info\.prev\.batt_temp\s*>=\s*550\s*\).*?g_overheat_55_sec\s*\+=.*?;'
repl_c = '/* xTREMEsPEED: Overheat tracking DISABLED — no valid thermistor. */'
content, c = re.subn(pattern_c, repl_c, content, count=1, flags=re.DOTALL)
patches_applied += c

# 3d: Force battery level to 99%
pattern_d = r'(htc_batt_info\.rep\.level\s*=\s*htc_batt_info\.rep\.level_raw;)'
repl_d = (
    r'\1\n'
    '\t/* xTREMEsPEED: Force level 99% — no battery to drain. */\n'
    '\thtc_batt_info.rep.level = 99;'
)
content, c = re.subn(pattern_d, repl_d, content, count=1)
patches_applied += c

with open(filepath, "w") as f:
    f.write(content)
print(f"  Patched {filepath}: {patches_applied} sub-patches applied")
PYEOF
    else
        warn "htc_battery.c not found — shutdown paths handled by qpnp drivers"
    fi

    # --- Patch 4/5: Device tree — Raise thermal thresholds ---
    log "[4/5] Patching device tree — raise thermal thresholds"
    dtsi=""
    for candidate in \
        "arch/arm64/boot/dts/htc/msm8996-htc_sailfish.dtsi" \
        "arch/arm64/boot/dts/htc/msm8996-htc-marlin.dtsi" \
        "arch/arm/boot/dts/qcom/msm8996-htc_sailfish.dtsi" \
        "arch/arm64/boot/dts/qcom/msm8996-marlin.dtsi"; do
        if [ -f "$candidate" ]; then
            dtsi="$candidate"
            break
        fi
    done
    if [ -z "$dtsi" ]; then
        dtsi=$(find arch/ -name "*sailfish*" -o -name "*marlin*" 2>/dev/null | grep -i "\.dtsi$" | head -1 || true)
    fi
    if [ -n "$dtsi" ]; then
        log "  Found device tree: $dtsi"
        python3 << PYEOF
import re
filepath = "$dtsi"
with open(filepath, "r") as f:
    content = f.read()
replacements = {
    r'qcom,warm-bat-decidegc\s*=\s*<\s*\d+\s*>': 'qcom,warm-bat-decidegc = <900> /* xTREMEsPEED */',
    r'qcom,hot-bat-decidegc\s*=\s*<\s*\d+\s*>': 'qcom,hot-bat-decidegc = <900> /* xTREMEsPEED */',
    r'qcom,cool-bat-decidegc\s*=\s*<\s*\(-?\d+\)\s*>': 'qcom,cool-bat-decidegc = <(-400)> /* xTREMEsPEED */',
    r'qcom,cold-bat-decidegc\s*=\s*<\s*\(-?\d+\)\s*>': 'qcom,cold-bat-decidegc = <(-400)> /* xTREMEsPEED */',
}
total = 0
for pattern, repl in replacements.items():
    content, c = re.subn(pattern, repl, content)
    total += c
with open(filepath, "w") as f:
    f.write(content)
print(f"  Patched {filepath}: {total} thermal threshold(s) updated")
PYEOF
    else
        warn "No sailfish/marlin .dtsi found — thermal thresholds unchanged"
    fi

    # --- Patch 5/5: defconfig — Watchdog ---
    log "[5/5] Patching defconfig — watchdog + panic config"
    if [ -f "arch/arm64/configs/marlin_defconfig" ]; then
        set_config "arch/arm64/configs/marlin_defconfig" "CONFIG_PANIC_TIMEOUT" "5"
        set_config "arch/arm64/configs/marlin_defconfig" "CONFIG_WATCHDOG" "y"
        set_config "arch/arm64/configs/marlin_defconfig" "CONFIG_MSM_WATCHDOG_V2" "y"
    fi

    log "All patches applied!"
fi

# ============================================================
# STEP 2b: Charger mode bypass (independent of battery patches)
# ============================================================
if grep -q "xtremespeed_force_normal_boot" init/main.c 2>/dev/null; then
    warn "Charger mode bypass already applied — skipping"
else
    log "[6/6] Patching init/main.c — disable charger mode bootloop"
    python3 << 'PYEOF'
filepath = "init/main.c"
with open(filepath, "r") as f:
    content = f.read()

# Append charger mode override function at end of init/main.c
# This modifies saved_command_line (exposed via /proc/cmdline) to replace
# androidboot.mode=charger with androidboot.mode=main before userspace init reads it.
# Without a battery, charger mode is useless and causes an infinite bootloop.
override_code = """
/* xTREMEsPEED: Force normal boot mode — battery-less device has no use
 * for charger mode, which causes bootloop when powered via USB.
 * Replaces "androidboot.mode=charger" with "androidboot.mode=main   "
 * in /proc/cmdline before Android init reads it. */
static int __init xtremespeed_force_normal_boot(void)
{
\tchar *p;
\tp = strstr(saved_command_line, "androidboot.mode=charger");
\tif (p) {
\t\tmemcpy(p + 18, "main   ", 7);
\t\tpr_info("xTREMEsPEED: Forced androidboot.mode=main (charger mode disabled)\\n");
\t}
\treturn 0;
}
early_initcall(xtremespeed_force_normal_boot);
"""

content += override_code
with open(filepath, "w") as f:
    f.write(content)
print(f"  Patched {filepath}: charger mode override added (early_initcall)")
PYEOF
fi

# ============================================================
# STEP 3: Configure and build
# ============================================================
log "Setting up build config..."
cp "$OUT_DIR/stock_config" "$OUT_DIR/.config"

# Apply config overrides
set_config "$OUT_DIR/.config" "CONFIG_PANIC_TIMEOUT" "5"
set_config "$OUT_DIR/.config" "CONFIG_LOCALVERSION" '"-xTREMEsPEED"'
set_config "$OUT_DIR/.config" "CONFIG_LOCALVERSION_AUTO" "n"

log "Running olddefconfig..."
make O="$OUT_DIR" ARCH="$ARCH" olddefconfig

log "Building with $JOBS jobs..."
make O="$OUT_DIR" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    KCFLAGS="-Wno-error=unused-variable" \
    -j"$JOBS"

IMAGE="$OUT_DIR/arch/$ARCH/boot/Image.lz4-dtb"
if [ -f "$IMAGE" ]; then
    log "========================================="
    log "  BUILD SUCCESS — xTREMEsPEED Kernel"
    log "========================================="
    log "  Kernel: $IMAGE"
    log "  Size: $(du -h "$IMAGE" | cut -f1)"
    strings "$OUT_DIR/vmlinux" | grep "Linux version" | head -1
else
    die "Build failed — Image.lz4-dtb not found"
fi
