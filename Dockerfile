########################################################################################################################
# Build stage for rust backend
########################################################################################################################

FROM rust:alpine AS build-backend

ARG TARGETPLATFORM

RUN apk update && \
    apk add --no-cache \
    musl-dev \
    gcc

WORKDIR /usr/src/qemu-backend
COPY ./web-backend .

# Build the application for musl (64-bit targets only)
RUN if [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        rustup target add aarch64-unknown-linux-musl && \
        cargo build --release --target aarch64-unknown-linux-musl && \
        cp /usr/src/qemu-backend/target/aarch64-unknown-linux-musl/release/qemu-openwrt-web-backend /usr/local/bin; \
    elif [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
        rustup target add x86_64-unknown-linux-musl && \
        cargo build --release --target x86_64-unknown-linux-musl && \
        cp /usr/src/qemu-backend/target/x86_64-unknown-linux-musl/release/qemu-openwrt-web-backend /usr/local/bin; \
    else \
        echo "Error: CPU architecture $TARGETPLATFORM is not supported (64-bit only)"; \
        exit 1; \
    fi

########################################################################################################################
# Build stage for angular frontend
########################################################################################################################

FROM node:latest AS build-frontend

WORKDIR /usr/local/app
COPY ./web-frontend /usr/local/app/

# See https://github.com/nodejs/docker-node/issues/1668
RUN npm update -g npm
RUN npm ci --no-audit --maxsockets 1

RUN npm install
RUN npm run build -- "--base-href='./'"

########################################################################################################################
# OpenWrt image
########################################################################################################################
FROM alpine:latest

ARG OPENWRT_VERSION="25.12.6"
ARG TARGETPLATFORM
ARG OPENWRT_ROOTFS_IMG
ARG OPENWRT_KERNEL
ARG OPENWRT_ROOTFS_TAR

# Configure Alpine (64-bit targets only)
RUN echo "Building for platform '$TARGETPLATFORM'" \
    && if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
        CPU_ARCH="x86_64"; \
        APK_EXTRA="ovmf"; \
    elif [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        CPU_ARCH="aarch64"; \
        APK_EXTRA=""; \
    else \
        echo "Error: CPU architecture $TARGETPLATFORM is not supported (64-bit only)"; \
        exit 1; \
    fi \
    && apk add --no-cache \
        multirun \
        bash \
        wget \
        grep \
        qemu-system-"$CPU_ARCH" \
        qemu-hw-usb-host \
        qemu-hw-usb-redirect \
        nginx \
        nginx-mod-stream \
        netcat-openbsd \
        uuidgen \
        usbutils \
        pciutils \
        openssh-client \
        util-linux-misc \
        iproute2  \
        "$APK_EXTRA" \
    # It seems that PROFINET packages are not forwarded correctly without the package iproute2. The reason is unknown. \
    && sed -i 's/^worker_processes.*/worker_processes 1;daemon off;/' /etc/nginx/nginx.conf

COPY ./openwrt_additional /var/vm/openwrt_additional

# Handle different CPUs architectures and choose the correct OpenWrt images
RUN echo "Building for platform '$TARGETPLATFORM'" \
    && if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
        if [ "$OPENWRT_VERSION" = "master" ]; then \
            OPENWRT_IMAGE="https://downloads.openwrt.org/snapshots/targets/x86/64/openwrt-x86-64-generic-squashfs-combined-efi.img.gz"; \
        elif [ "$OPENWRT_VERSION" = "24.10-SNAPSHOT" ]; then \
            wget https://downloads.openwrt.org/releases/24.10-SNAPSHOT/targets/x86/64/version.buildinfo; \
            VERSION_BUILDINFO=`cat version.buildinfo`; \
            OPENWRT_IMAGE="https://downloads.openwrt.org/releases/24.10-SNAPSHOT/targets/x86/64/openwrt-24.10-snapshot-${VERSION_BUILDINFO}-x86-64-generic-squashfs-combined-efi.img.gz"; \
        else \
            OPENWRT_IMAGE="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64/openwrt-${OPENWRT_VERSION}-x86-64-generic-squashfs-combined-efi.img.gz"; \
        fi; \
    elif [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        if [ "$OPENWRT_VERSION" = "master" ]; then \
          OPENWRT_IMAGE="https://downloads.openwrt.org/snapshots/targets/armsr/armv8/openwrt-armsr-armv8-generic-squashfs-combined-efi.img.gz"; \
        elif [ "$OPENWRT_VERSION" = "24.10-SNAPSHOT" ]; then \
            wget https://downloads.openwrt.org/releases/24.10-SNAPSHOT/targets/armsr/armv8/version.buildinfo; \
            VERSION_BUILDINFO=`cat version.buildinfo`; \
            OPENWRT_IMAGE="https://downloads.openwrt.org/releases/24.10-SNAPSHOT/targets/armsr/armv8/openwrt-24.10-snapshot-${VERSION_BUILDINFO}-armsr-armv8-generic-squashfs-combined-efi.img.gz"; \
        else \
            OPENWRT_IMAGE="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/armsr/armv8/openwrt-${OPENWRT_VERSION}-armsr-armv8-generic-squashfs-combined-efi.img.gz"; \
        fi; \
    else \
        echo "Error: CPU architecture $TARGETPLATFORM is not supported (64-bit only)"; \
        exit 1; \
    fi \
    \
    # Get OpenWrt images  \
    && wget $OPENWRT_IMAGE -O /var/vm/squashfs-combined-${OPENWRT_VERSION}.img.gz \
    && gzip -d /var/vm/squashfs-combined-${OPENWRT_VERSION}.img.gz \
    \
    # 4k align the OpenWrt image so qemu doesn't complain about resize errors \
    # Get current size in bytes \
    && size=$(stat -c\%s "/var/vm/squashfs-combined-${OPENWRT_VERSION}.img") \
    # ceil to MB \
    && size_mb=$(( (size + 1024*1024 - 1) / (1024*1024) ))  \
    && echo "Current size: ${size_mb} MiB " \
    # Decide target size \
    && if [ "$size_mb" -le 128 ]; then \
        target_mb=128; \
    elif [ "$size_mb" -le 256 ]; then \
        target_mb=256; \
    elif [ "$size_mb" -le 512 ]; then \
        target_mb=512; \
    elif [ "$size_mb" -le 1024 ]; then \
        target_mb=1024; \
    fi \
    && echo "Extending /var/vm/squashfs-combined-${OPENWRT_VERSION}.img to${target_mb} MiB..." \
    && dd if=/dev/zero of="/var/vm/squashfs-combined-${OPENWRT_VERSION}.img" seek="${target_mb}" obs=1M count=0 \
    \
    # Each CPU architecture needs a different SSH port to make a possible to make a parallel build \
    && SSH_PORT=1022 \
    \
    # Boot OpenWrt in order to install additional packages and settings \
    && if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
        SSH_PORT=1022; \
        qemu-system-x86_64 -M pc -nographic -nodefaults -m 256 \
        -bios /usr/share/ovmf/bios.bin \
        -blockdev driver=raw,node-name=hd0,cache.direct=on,file.driver=file,file.filename=/var/vm/squashfs-combined-${OPENWRT_VERSION}.img \
        -device virtio-blk-pci,drive=hd0 \
        -device virtio-net,netdev=qlan0 -netdev user,id=qlan0,net=192.168.1.0/24,hostfwd=tcp::$SSH_PORT-192.168.1.1:22 \
        -device virtio-net,netdev=qwan0 -netdev user,id=qwan0 \
        & QEMU_PID=$!; \
    else \
        SSH_PORT=2022; \
        qemu-system-aarch64 -M virt -cpu cortex-a53 -nographic -nodefaults -m 256 \
        -bios /usr/share/qemu/edk2-aarch64-code.fd \
        -blockdev driver=raw,node-name=hd0,cache.direct=on,file.driver=file,file.filename=/var/vm/squashfs-combined-${OPENWRT_VERSION}.img \
        -device virtio-blk-pci,drive=hd0 \
        -device virtio-net,netdev=qlan0 -netdev user,id=qlan0,net=
