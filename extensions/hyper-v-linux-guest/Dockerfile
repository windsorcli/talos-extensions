# Standalone build when bldr from siderolabs/extensions is not available.
# Produces a directory layout: manifest.yaml + rootfs/ (use scripts/assemble-extension-image.sh).
ARG LINUX_TOOLS_TAG=v6.12.28
FROM alpine:3.20 AS build
ARG LINUX_TOOLS_TAG
RUN apk add --no-cache build-base curl
WORKDIR /src
RUN curl -fsSL -o hv_kvp_daemon.c \
      "https://raw.githubusercontent.com/torvalds/linux/${LINUX_TOOLS_TAG}/tools/hv/hv_kvp_daemon.c" \
    && curl -fsSL -o hv_vss_daemon.c \
      "https://raw.githubusercontent.com/torvalds/linux/${LINUX_TOOLS_TAG}/tools/hv/hv_vss_daemon.c" \
    && gcc -Os -static -o hv_kvp_daemon hv_kvp_daemon.c \
    && gcc -Os -static -o hv_vss_daemon hv_vss_daemon.c

FROM scratch AS artifacts
COPY --from=build /src/hv_kvp_daemon /src/hv_vss_daemon /
