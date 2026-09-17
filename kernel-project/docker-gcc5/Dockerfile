# x86_64 (emulated on Apple Silicon) build environment with Ubuntu 16.04's packaged
# aarch64 cross compiler: GCC 5.4.0 (gcc-5-aarch64-linux-gnu) + binutils 2.26.
#
# Why: linux-stable v4.4.270+ refuses GCC < 5.1 on arm64 (GCC bug 63293 -- stack references
# beyond an already-adjusted SP, memory corruption under interrupts). The AOSP 4.9 toolchain
# in docker-amd64/ is the only compiler that has produced a bootable kernel for this board so
# far, and stock was built with it too; the user chose to move to 4.4.302 with a GCC >= 5.1.
# 5.4 is the closest packaged release past that floor. Linaro's old binary archive is gone,
# and xenial is still served from archive.ubuntu.com (not old-releases).
#
# Same package set as docker-amd64/Dockerfile, plus the cross compiler. Nothing from the 4.9
# toolchain volume is used: CROSS_COMPILE=aarch64-linux-gnu- resolves inside the image.
FROM --platform=linux/amd64 ubuntu:16.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential bc bison flex libssl-dev libelf-dev \
      git make perl python python3 cpio kmod rsync file unzip xz-utils \
      device-tree-compiler ca-certificates libncurses5-dev \
      zlib1g-dev libc6-dev \
      gcc-5-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  && ln -s /usr/bin/aarch64-linux-gnu-gcc-5 /usr/bin/aarch64-linux-gnu-gcc \
  && ln -s /usr/bin/aarch64-linux-gnu-gcc-ar-5 /usr/bin/aarch64-linux-gnu-gcc-ar \
  && ln -s /usr/bin/aarch64-linux-gnu-gcc-nm-5 /usr/bin/aarch64-linux-gnu-gcc-nm \
  && ln -s /usr/bin/aarch64-linux-gnu-gcc-ranlib-5 /usr/bin/aarch64-linux-gnu-gcc-ranlib \
  && ln -s /usr/bin/aarch64-linux-gnu-cpp-5 /usr/bin/aarch64-linux-gnu-cpp \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /src
