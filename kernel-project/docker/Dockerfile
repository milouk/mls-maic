# Build environment for the MT8167 (Cortex-A35, arm64) 4.4 kernel.
#
# Two reasons this is a container and not the Mac:
#  1. macOS is case-INSENSITIVE by default, and a Linux tree contains files that
#     differ only by case (xt_CONNMARK.h vs xt_connmark.h). It cannot be checked out.
#  2. The kernel build wants a GNU userland (bc, flex, bison, elf headers, perl).
#
# The target is arm64 and Apple Silicon is arm64, so on an M-series Mac this image
# runs natively and gcc compiles for aarch64 with NO cross-compiler and no qemu.
# On an x86_64 host, pass CROSS_COMPILE=aarch64-linux-gnu- (package installed below).
FROM ubuntu:18.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential bc bison flex libssl-dev libelf-dev \
      gcc-7 g++-7 \
      git make perl python python3 \
      cpio kmod rsync file unzip xz-utils zstd \
      device-tree-compiler ca-certificates openssh-client \
      libncurses5-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*

# The aarch64 cross-compiler only EXISTS on non-arm64 hosts -- on arm64 the target is
# native and the package has no installation candidate. Install it conditionally so the
# same Dockerfile works on both Apple Silicon and an x86_64 machine.
RUN if [ "$(dpkg --print-architecture)" != "arm64" ]; then \
      apt-get update && apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# Linux 4.4 predates several GCC 8+ warnings-as-errors; pin to 7.
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-7 70 \
 && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-7 70

WORKDIR /src
