ARG BASE_IMAGE=ucs-uav-base-gz:20260625
FROM ${BASE_IMAGE}

RUN chmod 0644 /etc/resolv.conf || true \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3-gi \
        gir1.2-gstreamer-1.0 \
        gir1.2-gst-plugins-base-1.0 \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly \
        gstreamer1.0-libav \
    && rm -rf /var/lib/apt/lists/*

COPY ucs-gazebo-headless /usr/local/bin/ucs-gazebo-headless
RUN chmod +x /usr/local/bin/ucs-gazebo-headless

ENTRYPOINT ["/usr/local/bin/ucs-gazebo-headless"]
