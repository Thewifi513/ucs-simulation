# Gazebo Runtime 镜像

这是 UCS BMv2 mesh 平台的实验性 headless Gazebo server 镜像。

这个容器只负责产生 Gazebo world、相机话题和 `/clock`。PX4 容器、metrics、RTP 视频注入、BMv2 和 ns-3 仍在容器外按原平台链路运行。

## 使用方式

服务器部署应导入固定镜像 `ucs-gazebo-runtime:20260625`，不要在服务器上现场重建。

开发机重建：

```bash
./deploy/docker/gazebo-runtime/build_image.sh
```

只启动 world：

```bash
UCS_GAZEBO_BACKEND=docker ./px4_gazebo/world_up.sh --headless
```

随完整平台启动：

```bash
UCS_GAZEBO_BACKEND=docker ./fleet/fleet_up.sh --headless
```

Docker Gazebo 后端目前只支持 headless。启动器会用仓库内挂载的 `ucs-gazebo-headless` 覆盖镜像 entrypoint，所以脚本改动重启即可生效；只有镜像包变化才需要重建。

## GPU 和视频性能

推荐 GPU headless 方式：

```bash
UCS_GAZEBO_BACKEND=docker \
UCS_GAZEBO_DOCKER_GPU=1 \
./fleet/fleet_up.sh --headless
```

设置 `UCS_GAZEBO_DOCKER_GPU=1` 后，`world_up.sh` 会传入 `--gpus all`，停止强制 llvmpipe 软件渲染，并挂载宿主 NVIDIA EGL vendor 文件，通常是：

```text
/usr/share/glvnd/egl_vendor.d/10_nvidia.json
```

如果这个文件缺失，即使容器里能看到 `nvidia-smi`，Gazebo 仍可能回退到 Mesa/LLVM 渲染，导致仿真时间和相机 FPS 明显下降。

Docker+GPU 模式下，`fleet_up.sh` 默认使用硬编硬解：

```text
VIDEO_ENCODER=hard
DASHBOARD_VIDEO_DECODER=hard
```

显式允许软件 fallback：

```bash
UCS_GAZEBO_BACKEND=docker \
UCS_GAZEBO_DOCKER_GPU=1 \
VIDEO_ENCODER=auto \
DASHBOARD_VIDEO_DECODER=auto \
./fleet/fleet_up.sh --headless
```

## 相机 profile

无 GPU 的 Docker bring-up 默认偏向低负载。显式低负载：

```bash
UCS_GAZEBO_BACKEND=docker \
UCS_GAZEBO_CAMERA_PROFILE=lite \
./fleet/fleet_up.sh --headless --video-fps 10 --video-bitrate-kbps 800
```

`lite` 会在运行目录生成临时 `gimbal` 模型覆盖，不改 PX4 源树；相机改为 640x360@10Hz，并关闭 sensor visualization。

强制使用原 PX4 1280x720 相机模型：

```bash
UCS_GAZEBO_BACKEND=docker \
UCS_GAZEBO_CAMERA_PROFILE=off \
./fleet/fleet_up.sh --headless
```

测试 1080p 相机覆盖：

```bash
UCS_GAZEBO_BACKEND=docker \
UCS_GAZEBO_DOCKER_GPU=1 \
UCS_GAZEBO_CAMERA_PROFILE=1080p \
./fleet/fleet_up.sh --headless --video-fps 30 --video-bitrate-kbps 8000
```

## 运行说明

- Gazebo 容器使用 `--network host`。
- `GZ_PARTITION` 和 `GZ_IP` 由 `world_up.sh` 传入。
- Docker headless 默认禁用 PX4 `GstCameraSystem` 和 `OpticalFlowSystem`，因为本平台通过 `rtp_camera_bridge.py` 输出视频。
- 如确需 PX4 插件，可设置 `UCS_GAZEBO_DISABLE_GST_CAMERA_SYSTEM=off` 或 `UCS_GAZEBO_DISABLE_OPTICAL_FLOW_SYSTEM=off`。
- 默认情况下，禁用这些 PX4 自定义插件后，`UCS_GAZEBO_DOCKER_HOST_LIBS=auto` 不再挂载宽泛的 `/ucs-host-libs`。只有缺库时才显式设为 `on`。
- 启动器会挂载 PX4 树、当前 `ucs-simulation` 目录、world SDF 目录和生成的 headless server config。
- RTP 视频仍由每架 UAV namespace 内的 `rtp_camera_bridge.py` 产生，因此业务流继续经过 BMv2/ns-3。
