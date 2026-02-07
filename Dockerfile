FROM --platform=linux/amd64 ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

# Build dependencies for Linux kernel compilation
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    bc \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    python3 \
    lz4 \
    liblz4-tool \
    wget \
    xz-utils \
    cpio \
    && rm -rf /var/lib/apt/lists/*

# Linaro GCC 4.9 — matches Google's AOSP prebuilt GCC 4.9 used for stock kernel.
# CRITICAL: Only GCC 4.9 produces bootable kernels for msm-3.18.
# GCC 9, 12, and other versions compile but produce unbootable images.
RUN mkdir -p /toolchains && cd /toolchains && \
    wget -q https://releases.linaro.org/components/toolchain/binaries/4.9-2017.01/aarch64-linux-gnu/gcc-linaro-4.9.4-2017.01-x86_64_aarch64-linux-gnu.tar.xz && \
    tar xf gcc-linaro-4.9.4-2017.01-x86_64_aarch64-linux-gnu.tar.xz && \
    mv gcc-linaro-4.9.4-2017.01-x86_64_aarch64-linux-gnu aarch64 && \
    rm gcc-linaro-4.9.4-2017.01-x86_64_aarch64-linux-gnu.tar.xz && \
    wget -q https://releases.linaro.org/components/toolchain/binaries/4.9-2017.01/arm-linux-gnueabi/gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabi.tar.xz && \
    tar xf gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabi.tar.xz && \
    mv gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabi arm && \
    rm gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabi.tar.xz

WORKDIR /kernel
