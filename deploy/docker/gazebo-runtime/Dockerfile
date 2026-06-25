ARG BASE_IMAGE=ucs-uav-base-gz:20260625
FROM ${BASE_IMAGE}

COPY ucs-gazebo-headless /usr/local/bin/ucs-gazebo-headless
RUN chmod +x /usr/local/bin/ucs-gazebo-headless

ENTRYPOINT ["/usr/local/bin/ucs-gazebo-headless"]
