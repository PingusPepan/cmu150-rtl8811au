# SPDX-License-Identifier: GPL-2.0-only
#
# Build environment for the RTL8811AU driver targeting the CMU150:
# Linux 3.0.35 / i.MX6 / soft-float ARM EABI.
#
#  - stage `fetch`: a modern Debian that does every download (Jessie can no longer complete
#    a TLS handshake with most hosts):
#      * the cross toolchain: kernel.org's crosstool gcc-4.9.4 "nolibc" arm-linux-gnueabi
#        (soft-float), purpose-built for compiling kernels and modules and matching the
#        Freescale i.MX6 BSP ABI;
#      * the reference kernel: Boundary Devices' i.MX6 3.0.35 BSP at a pinned commit. It is
#        only a compile reference for build/prepare-kernel.sh; nothing from it is shipped.
#  - final stage: Debian Jessie, whose host gcc 4.9 and period-correct host tools can
#    actually build a 3.0.35 tree. Modern make/gcc break this kernel's build scripts.
#    It downloads nothing.

FROM debian:bookworm AS fetch
ARG KERNEL_SHA=d97f449780544a18ca7c877dfc4742a3d92e4ccf
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates \
 && wget -q --tries=3 --timeout=30 \
      https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/x86_64/4.9.4/x86_64-gcc-4.9.4-nolibc-arm-linux-gnueabi.tar.gz \
      -O /tmp/tc.tar.gz \
 && mkdir -p /opt/tc && tar -C /opt/tc -xf /tmp/tc.tar.gz \
 && wget -q --tries=3 --timeout=60 \
      "https://github.com/boundarydevices/linux-imx6/archive/${KERNEL_SHA}.tar.gz" \
      -O /opt/linux-imx6.tar.gz
# the toolchain extracts to /opt/tc/gcc-4.9.4-nolibc/arm-linux-gnueabi/

FROM debian/eol:jessie
COPY --from=fetch /opt/tc /opt/tc
COPY --from=fetch /opt/linux-imx6.tar.gz /opt/linux-imx6.tar.gz
# archive.debian.org Release files are long expired -> disable the validity check.
RUN apt-get -o Acquire::Check-Valid-Until=false update \
 && apt-get install -y --no-install-recommends \
        build-essential make bc libncurses5-dev kmod git rsync binutils file \
 && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/tc/gcc-4.9.4-nolibc/arm-linux-gnueabi/bin:${PATH}"
ENV ARCH=arm
ENV CROSS_COMPILE=arm-linux-gnueabi-
WORKDIR /build
