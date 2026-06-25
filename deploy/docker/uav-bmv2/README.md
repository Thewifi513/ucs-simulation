# UAV BMv2 镜像

这个目录定义当前平台使用的 UAV BMv2 运行时镜像。

镜像从已经验证过的 Gazebo/PX4 UAV 运行时派生：

```text
ucs-uav-base-gz:20260625
  -> ucs-uav-base-gz-bmv2:20260625
```

它增加：

- 从固定 `ucs-bmv2-runtime:20260625` 镜像复制的 `simple_switch_grpc`。
- BMv2 运行时库兼容目录。
- 内联数据面调试需要的网络和抓包工具。

开发机重建：

```bash
./deploy/docker/uav-bmv2/build_image.sh
```

默认使用 `DOCKER_BUILDKIT=0` 和 `DOCKER_BUILD_NETWORK=host`，是为了兼容部分实验室机器上 BuildKit 与 APT `_apt` 用户的 DNS/权限问题。Docker 环境稳定时可以覆盖这些变量。

当前 p4lang OBS 包没有直接发布 `xUbuntu_24.04` 包集，旧包集又会牵扯旧 Thrift/Boost/Protobuf 依赖。因此本镜像采用 multi-stage copy，从 `ucs-bmv2-runtime:20260625` 复制 BMv2 运行时，而不是在每个 UAV 镜像里安装完整 P4 开发环境。

P4 编译和 P4Runtime Python 工具不放进 UAV 镜像。开发和控制环境应使用单独的编译/控制镜像或开发机环境。

覆盖镜像 tag：

```bash
BASE_IMAGE=ucs-uav-base-gz:20260625 \
BMV2_IMAGE=ucs-uav-base-gz-bmv2:20260625 \
BMV2_RUNTIME_IMAGE=ucs-bmv2-runtime:20260625 \
./deploy/docker/uav-bmv2/build_image.sh
```

当拓扑要求 `container_bmv2_inline` 时，`./fleet/ensure_container.sh` 默认使用 `ucs-uav-base-gz-bmv2:20260625`。只有显式设置 `CONTAINER_IMAGE` 才会覆盖。
