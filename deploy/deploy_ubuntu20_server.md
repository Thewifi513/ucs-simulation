# Ubuntu 20 GPU 服务器部署说明

这份说明用于把当前 UCS BMv2 mesh 仿真平台迁移到必须保留 Ubuntu 20.04 的 GPU 服务器。服务器上已有旧项目，但旧项目不涉及无人机且不活跃，因此部署策略是隔离新平台，不升级系统，不清理共享 Docker 环境。

## 部署判断

不要为了本平台升级宿主系统。

推荐形态：

- 宿主机只承担 Docker、NVIDIA 驱动、网络权限、端口和存储。
- UCS 平台放在清晰独立的项目目录。
- Gazebo/PX4/BMv2 运行依赖尽量通过固定 Docker 镜像和显式路径管理。
- Python 依赖放在项目 venv 或专用运行环境里，不污染系统 Python。

## 安全边界

- 不执行 `apt upgrade`。
- 不执行 `docker system prune`。
- 不覆盖旧项目目录。
- 不依赖 `latest` 镜像做可复现实验。
- 不用宽泛清理命令处理共享服务器。
- 每次失败重试前先运行 `./fleet/fleet_down.sh --verbose`。

## 预检

预检脚本只读，不会启动仿真，也不会清理环境：

```bash
cd /path/to/ucs/ucs-simulation
bash ./deploy/ubuntu20_server_preflight.sh
```

常用覆盖变量：

```bash
PX4_DIR=/path/to/PX4-Autopilot \
NS3_DIR=/path/to/ns-3 \
PYTHON_BIN=/path/to/ucs/.venv/bin/python \
MAVSDK_SERVER_BIN=/path/to/ucs/ucs-simulation/control/mavsdk_server_musl_x86_64 \
bash ./deploy/ubuntu20_server_preflight.sh
```

退出码：

```text
0  没有硬失败，warning 仍需人工判断
1  使用 --strict 且存在 warning
2  至少一个硬失败
```

预检会检查命令、Docker 权限、固定镜像、GPU 可见性、PX4/Gazebo 路径、ns-3 scratch、网络权限、GStreamer/MAVSDK 组件和默认端口。

分阶段检查和部署准备可以使用集成脚本：

```bash
./deploy/ubuntu20_server_check_deploy.sh check --strict
```

服务器首次准备：

```bash
./deploy/ubuntu20_server_check_deploy.sh deploy \
  --image-tar ./ucs-runtime-images-20260625.tar
```

这个 `deploy` 子命令只准备运行环境：平台 venv、Docker 镜像导入、ns-3 scratch 安装、preflight 和 dry-run。它不会启动完整仿真，也不会清理旧项目。

## 服务器基础清单

迁移前先记录共享服务器状态，作为回滚参考，不作为清理依据：

```bash
hostnamectl
docker ps -a
docker image ls
ss -lntu
nvidia-smi
systemctl --type=service --state=running
```

## 宿主机需要具备的能力

```text
Docker Engine
NVIDIA driver
NVIDIA Container Toolkit
iproute2: ip, tc, ss
iptables
util-linux: nsenter, setsid
coreutils: timeout, realpath
procps: pgrep
ethtool
tcpdump
GStreamer runtime 和插件:
  gst-launch-1.0, gst-inspect-1.0
  x264enc, rtph264pay, rtph264depay, avdec_h264, videoconvert
  NVIDIA H.264 编码/解码插件，用于硬编硬解
Gazebo Harmonic runtime，与 PX4 当前 gz transport 栈匹配
平台专用 Python venv:
  mavsdk
  websockets
Gazebo helper runtime:
  host Python 可导入 gz.transport13/gz.msgs10 和 gi.repository.Gst，或
  Docker 镜像 ucs-gazebo-runtime:20260625 提供这些能力
PX4-Autopilot checkout/build:
  build/px4_sitl_default/rootfs/gz_env.sh
ns-3 checkout/build:
  scratch/ucs_fleet_l2_mesh_topology.cc
```

浏览器控制还需要 `mavsdk_server` 二进制。它属于 UAV 控制组件，随 `control/` 一起迁移：

```text
control/mavsdk_server_musl_x86_64
```

启动脚本会先查 `control/mavsdk_server` 和 `control/mavsdk_server_musl_x86_64`，再回退到 `PATH`。如果服务器上另有固定位置，也可以显式设置 `MAVSDK_SERVER_BIN`。

## Python venv

服务器不要依赖系统 `python3` 直接运行平台脚本。所有宿主机 Python 入口都会通过 `fleet/env_defaults.sh` 解析到 `PYTHON_BIN`，解析顺序是：

```text
显式 PYTHON_BIN
UCS_VENV_DIR/bin/python
ucs-simulation/.venv/bin/python
python3，仅作为开发机兜底
```

推荐在 `ucs/` 根目录创建平台专用 venv。控制链路需要 `mavsdk/websockets`；Gazebo transport 和 GStreamer helper 可以由 Docker runtime 提供：

```bash
cd /path/to/ucs
python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r ./ucs-simulation/requirements.txt
python - <<'PY'
import mavsdk
import websockets
PY
```

迁移后固定导出：

```bash
export PYTHON_BIN=/path/to/ucs/.venv/bin/python
```

## Gazebo helper 后端

`metrics_worker.py` 和 `rtp_camera_bridge.py` 需要 Gazebo transport Python binding。Ubuntu 20 宿主机通常不适合硬混 `gz.transport13/gz.msgs10` 的新包，因此默认支持 helper Docker：

```bash
export UCS_GZ_HELPER_BACKEND=docker
export UCS_GZ_HELPER_IMAGE=ucs-gazebo-runtime:20260625
export UCS_GZ_HELPER_DOCKER_GPU=1
```

`metrics_up.sh` 在 Docker helper 模式下使用 host network，并挂载 `/tmp`、`/dev/shm`，所以 ns-3 仍读取宿主机同一份 sim time 和 metrics 文件。

`run_rtp_camera_flow.sh` 在 Docker helper 模式下使用 `--network container:uavNN`，共享对应 UAV 容器网络命名空间。RTP 源地址仍绑定 UAV 实验网 IP，业务流继续经过 BMv2/ns-3，不会从宿主机旁路。

`UCS_GZ_HELPER_BACKEND=auto` 会优先使用宿主 helper；宿主缺依赖时自动改用 Docker helper。服务器部署建议显式设为 `docker`，减少 Ubuntu 20 系统包风险。

## 路径默认值

脚本通过 `fleet/env_defaults.sh` 推导平台路径。默认期望类似布局：

```text
<workspace>/
  PX4-Autopilot/
  ns-3/
  ucs/
    ucs-simulation/
```

服务器如果不是这个布局，导出变量即可：

```bash
export UCS_WORKSPACE_ROOT=/path/to/workspace
export PX4_DIR=/path/to/PX4-Autopilot
export NS3_DIR=/path/to/ns-3
export PYTHON_BIN=/path/to/ucs/.venv/bin/python
export MAVSDK_SERVER_BIN=/path/to/ucs-simulation/control/mavsdk_server_musl_x86_64
```

## ns-3 scratch 安装

本仓库保留 ns-3 scratch 源码：

```text
network/ns3/ucs_fleet_l2_mesh_topology.cc
```

首次运行前安装到服务器的 ns-3：

```bash
cp ./network/ns3/ucs_fleet_l2_mesh_topology.cc "$NS3_DIR/scratch/"
cd "$NS3_DIR"
./ns3 build scratch/ucs_fleet_l2_mesh_topology
```

`./network/net_up.sh` 运行时会确保 scratch 二进制拥有 root+suid，以便 ns-3 使用 TapBridge。这一步需要 sudo。

## Docker 镜像

不要在 Ubuntu 20 服务器上临时构建 Docker/P4 产物。开发机上导出固定运行时镜像：

```bash
./deploy/export_docker_images.sh
```

把下面两个文件复制到服务器：

```text
ucs-runtime-images-20260625.tar
ucs-runtime-images-20260625.tar.sha256
```

服务器导入：

```bash
sha256sum -c ucs-runtime-images-20260625.tar.sha256
docker load -i ucs-runtime-images-20260625.tar
```

运行时必需镜像：

```text
ucs-uav-base-gz-bmv2:20260625
ucs-gazebo-runtime:20260625
ucs-p4runtime-sh:20260625
```

开发/构建镜像列在 `deploy/docker_images.env`，服务器已有 `p4/build/ucs_edge_cluster_route.json` 和 `p4/build/ucs_edge_cluster_route.p4info.txt` 时不需要它们。

检查镜像：

```bash
docker image inspect \
  ucs-uav-base-gz-bmv2:20260625 \
  ucs-gazebo-runtime:20260625 \
  ucs-p4runtime-sh:20260625
```

服务器上保持：

```bash
export UCS_MESH_P4_COMPILE=0
```

## 分阶段启动

先做无副作用解析：

```bash
./fleet/uav_profile.sh --idx 6
./network/net_up.sh --dry-run --verbose
./network/metrics_up.sh --dry-run
./video/run_rtp_camera_flow.sh --uav uav04 --duration-sec 5 --dry-run
```

再跑最小 live 栈：

```bash
sudo -v
./fleet/fleet_up.sh --terminal-mode minimal --headless --no-video --no-control --no-dashboard
```

停止：

```bash
./fleet/fleet_down.sh --verbose
```

稳定后按顺序加功能：

```bash
./fleet/fleet_up.sh --terminal-mode minimal --headless --no-video --no-control --with-dashboard
./fleet/fleet_up.sh --terminal-mode minimal --headless --with-video --no-control --with-dashboard
./fleet/fleet_up.sh --terminal-mode minimal --headless --with-video --with-control --with-dashboard
```

每轮之间都先执行 `./fleet/fleet_down.sh --verbose`，除非正在有意调试 live 进程。

## 默认端口

```text
8088            dashboard HTTP
5601-5606       RTP/H.264 视频子流
5701-5706       RTP/H.264 1080p 主流，显式开启才使用
14550           QGroundControl/MAVLink GS endpoint
14601-14606     MAVSDK GS-side MAVLink UDP
18570-18575     PX4 容器发布 QGC UDP
18601-18606     UAV-side MAVSDK UDP
8771-8776       浏览器控制 relay，全 UAV 模式
9011-9016       control core，全 UAV 模式
50101-50106     mavsdk_server gRPC，全 UAV 模式
9560            GS BMv2 P4Runtime
```

旧项目占用端口时，优先改 UCS 对应环境变量，不要盲停旧服务。

## Ubuntu 20 风险点

- Gazebo Harmonic 和新 PX4 文档通常面向更新 Ubuntu，Ubuntu 20 原生安装更容易脆。
- `mavsdk` 和 `websockets` 必须在平台 venv 内可导入；`gz.transport13/gz.msgs10` 建议交给 `ucs-gazebo-runtime` helper Docker。
- Docker+GPU headless Gazebo 需要确认 EGL/NVIDIA 渲染路径，否则相机 FPS 可能被 Mesa/LLVM 拖到很低。
- 默认会启动六路 960x540@30 子流。1080p 主流建议确认 NVENC 并发能力后再打开。
- 服务器上尽量使用 `--terminal-mode minimal`，GUI terminal 不是服务器路径的必要依赖。

## 回滚边界

正常回滚：

```bash
./fleet/fleet_down.sh --verbose
```

如果启动失败且清理不完整，先检查再动手：

```bash
docker ps -a
ip link show
ip netns list
ss -lntu
```

只删除确认属于本平台的容器、接口和日志，不使用共享服务器级别的宽泛清理命令。
