ARG BMV2_RUNTIME_IMAGE=ucs-bmv2-runtime:20260625
ARG BASE_IMAGE=ucs-uav-base-gz:20260625
FROM ${BMV2_RUNTIME_IMAGE} AS bmv2_runtime

FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    chmod 0644 /etc/resolv.conf || true; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      ethtool \
      iproute2 \
      iputils-ping \
      libgmp10 \
      libpcap0.8t64 \
      procps \
      tcpdump; \
    rm -rf /var/lib/apt/lists/*

COPY --from=bmv2_runtime /usr/local /usr/local

RUN mkdir -p /opt/bmv2/compat-lib
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libboost_program_options.so.1.71.0 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libboost_thread.so.1.71.0 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libboost_filesystem.so.1.71.0 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libssl.so.1.1 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libcrypto.so.1.1 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/libavl.so.1 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/libavl.so.1.5 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libev.so.4 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libev.so.4.0.0 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libprotobuf-c.so.1 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libprotobuf-c.so.1.0.0 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libpcre.so.3 /opt/bmv2/compat-lib/
COPY --from=bmv2_runtime /lib/x86_64-linux-gnu/libpcre.so.3.13.3 /opt/bmv2/compat-lib/

RUN set -eux; \
    mkdir -p /usr/local/libexec/bmv2; \
    mv /usr/local/bin/simple_switch_grpc /usr/local/libexec/bmv2/simple_switch_grpc; \
    { \
      printf '%s\n' '#!/usr/bin/env bash'; \
      printf '%s\n' 'set -Eeuo pipefail'; \
      printf '%s\n' 'export LD_LIBRARY_PATH="/usr/local/lib:/opt/bmv2/compat-lib:${LD_LIBRARY_PATH:-}"'; \
      printf '%s\n' 'exec /usr/local/libexec/bmv2/simple_switch_grpc "$@"'; \
    } > /usr/local/bin/simple_switch_grpc; \
    chmod +x /usr/local/bin/simple_switch_grpc; \
    ldconfig; \
    command -v simple_switch_grpc; \
    simple_switch_grpc --version

ENV UCS_BMV2_IMAGE=1 \
    P4RUNTIME_GRPC_PORT=9559

WORKDIR /px4
