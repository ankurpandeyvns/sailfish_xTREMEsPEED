#!/bin/bash
set -euo pipefail

# Clean build — NO patches, just stock kernel with GCC 4.9
# Fix: wrap SMP2P mock calls with #ifdef so they only compile with test config

KERNEL_REPO="https://android.googlesource.com/kernel/msm/"
KERNEL_BRANCH="android-msm-marlin-3.18-android10"
KERNEL_DIR="/kernel/msm"
OUT_DIR="/kernel/out"
ARCH="arm64"
CROSS_COMPILE="/toolchains/aarch64/bin/aarch64-linux-gnu-"
CROSS_COMPILE_ARM32="/toolchains/arm/bin/arm-linux-gnueabi-"
JOBS="$(nproc)"

echo "=== Cloning kernel source ==="
if [ ! -d "$KERNEL_DIR/.git" ]; then
    git clone --depth=1 --single-branch -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
else
    echo "Already cloned, skipping"
fi

cd "$KERNEL_DIR"
mkdir -p "$OUT_DIR"

echo "=== Fixing SMP2P mock references ==="
# smp2p.c calls mock functions that only exist when CONFIG_MSM_SMP2P_TEST is set.
# Wrap these calls with #ifdef guards. The mock processor doesn't exist on real HW.
if ! grep -q "SMP2P_BUILD_FIX" drivers/soc/qcom/smp2p.c; then
    python3 << 'PYFIX'
import re

filepath = "drivers/soc/qcom/smp2p.c"
with open(filepath, "r") as f:
    content = f.read()

# Fix 1: Wrap the mock rx interrupt call (around line 1599)
# Pattern: else { smp2p_remote_mock_rx_interrupt(); }
content = content.replace(
    '\tsmp2p_remote_mock_rx_interrupt();',
    '#ifdef CONFIG_MSM_SMP2P_TEST /* SMP2P_BUILD_FIX */\n\tsmp2p_remote_mock_rx_interrupt();\n#endif'
)

# Fix 2: Wrap the mock smem item call (around line 420)
# Pattern: item_ptr = msm_smp2p_get_remote_mock_smem_item(&size);
content = content.replace(
    '\t\titem_ptr = msm_smp2p_get_remote_mock_smem_item(&size);',
    '#ifdef CONFIG_MSM_SMP2P_TEST /* SMP2P_BUILD_FIX */\n\t\titem_ptr = msm_smp2p_get_remote_mock_smem_item(&size);\n#else\n\t\titem_ptr = NULL;\n#endif'
)

with open(filepath, "w") as f:
    f.write(content)
print("  Fixed SMP2P mock references with #ifdef guards")
PYFIX
fi

echo "=== Using stock config (unmodified) ==="
cp "$OUT_DIR/stock_config" "$OUT_DIR/.config"

echo "=== Running olddefconfig ==="
make O="$OUT_DIR" ARCH="$ARCH" olddefconfig

echo "=== Building kernel (clean, no patches) ==="
make O="$OUT_DIR" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    KCFLAGS="-Wno-error=unused-variable" \
    -j"$JOBS"

IMAGE="$OUT_DIR/arch/$ARCH/boot/Image.lz4-dtb"
if [ -f "$IMAGE" ]; then
    echo "=== BUILD SUCCESS ==="
    echo "Kernel: $IMAGE"
    ls -lh "$IMAGE"
    strings "$OUT_DIR/vmlinux" | grep "Linux version" | head -1
else
    echo "=== BUILD FAILED ==="
    exit 1
fi
