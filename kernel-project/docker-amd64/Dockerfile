# x86_64 (emulated on Apple Silicon) build environment, used ONLY to run the AOSP
# aarch64-linux-android-4.9 prebuilt toolchain, which ships as x86_64 binaries.
#
# Purpose: test whether the custom kernel's early-boot hang is a GCC-7-codegen problem by
# rebuilding with the SAME compiler family (gcc 4.9) the stock kernel used.
FROM --platform=linux/amd64 ubuntu:18.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential bc bison flex libssl-dev libelf-dev \
      git make perl python python3 cpio kmod rsync file unzip xz-utils \
      device-tree-compiler ca-certificates libncurses5-dev \
      zlib1g-dev libc6-dev \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /src
