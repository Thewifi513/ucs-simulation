# UCS BMv2 Mesh 仿真平台

这里是当前无人机集群 BMv2/P4 仿真平台目录。根目录只保留文档、拓扑、源码和资源；运行脚本按职责归到对应模块目录，不再散落在根目录，也不再集中塞进单个脚本目录。

## 当前平台

默认场景如下：

```text
拓扑文件:     topology/wifi_adhoc_matrix_2x3_6uav.json
场景 ID:      wifi_adhoc_matrix_2x3_6uav_v1
Gazebo world: px4_gazebo/worlds/ucs_obstacle_field.sdf
无人机:       uav01 ... uav06
载荷:         PX4/Gazebo x500_gimbal
链路:         ns-3 独立端点对 L2 链路损伤
转发:         UAV 边缘和 GS 边缘内联 BMv2 simple_switch_grpc
```

平台由这些部分组成：

- Gazebo/PX4 SITL 负责动力学、云台载荷、相机话题、MAVLink 端点。
- Linux namespace、TAP、bridge、veth 暴露实验网接口。
- ns-3 负责 21 条端点对无线链路的损伤模型。
- BMv2/P4Runtime 负责可编程边缘转发。
- metrics、dashboard、RTP 视频、浏览器控制负责实验观测和交互。

## 常用入口

从本目录启动完整平台：

```bash
./fleet/fleet_up.sh
```

GPU 服务器上可以让 Gazebo world 走 headless Docker 后端，PX4、ns-3、BMv2、metrics、视频注入和控制仍沿用外部运行链：

```bash
UCS_GAZEBO_BACKEND=docker UCS_GAZEBO_DOCKER_GPU=1 ./fleet/fleet_up.sh --headless
```

Ubuntu 20 宿主机缺 `gz.transport13/gz.msgs10` 时，metrics 和 RTP 相机桥会自动切到 Gazebo helper Docker。显式指定：

```bash
UCS_GZ_HELPER_BACKEND=docker UCS_GZ_HELPER_DOCKER_GPU=1 ./fleet/fleet_up.sh --headless
```

停止并清理：

```bash
./fleet/fleet_down.sh --verbose
```

桌面快捷方式入口仍在根目录：

```text
UCS-Fleet-up.desktop
UCS-Fleet-down.desktop
```

## 目录约定

```text
fleet/            开关、环境、桌面入口、桌面图标、UAV profile、容器确保
control/          UAV 浏览器控制
px4_gazebo/       PX4/Gazebo 启动脚本和 world 资源
network/          ns-3 网络、metrics 启停、metrics worker、ns-3 scratch 源码
frontend/         Web 前端、dashboard server、dashboard 启动入口
topology/         当前有效拓扑
video/            业务视频流注入和 RTP bridge
p4/               P4 源码、编译、P4Runtime 加载、已编译运行时产物
deploy/           部署、迁移、镜像导出、Docker 镜像定义
debug/            非活跃调试工具，后续可接入前端按需调用
```

路径默认值由 `fleet/env_defaults.sh` 统一派生。脚本默认从 `ucs-simulation` 目录推导工作区布局；服务器路径不同的时候优先导出环境变量，不要改脚本：

```bash
export UCS_WORKSPACE_ROOT=/path/to/workspace
export PX4_DIR=/path/to/PX4-Autopilot
export NS3_DIR=/path/to/ns-3
export PYTHON_BIN=/path/to/ucs/.venv/bin/python
export MAVSDK_SERVER_BIN=/path/to/ucs-simulation/control/mavsdk_server_musl_x86_64
```

服务器建议创建平台专用 venv，并让所有宿主机 Python 入口都走 `PYTHON_BIN`。控制链路需要 `mavsdk/websockets`；Gazebo transport 和 GStreamer helper 可以由 `ucs-gazebo-runtime:20260625` 容器提供：

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

## 网络模型

观测网：

- UAV 容器 `eth0`，Docker 管理的 `172.*` 地址。
- 用于 Gazebo transport、PX4 观测、`/clock`、姿态 metrics、Docker 控制和 P4Runtime 管理。
- 不经过 ns-3 链路损伤。

实验网：

- GS: `10.10.0.254/24`
- 集群 1: `uav01=10.10.1.1/24`, `uav02=10.10.1.2/24`, `uav03=10.10.1.3/24`
- 集群 2: `uav04=10.10.2.4/24`, `uav05=10.10.2.5/24`, `uav06=10.10.2.6/24`
- UAV 容器内可见 `eth1`。
- `br-uavNN` 只是 `tap-uavNN` 和容器之间的接入胶水，不是一架无人机一组 mesh peer 接口。

BMv2 内联路径：

```text
UAV 应用/PX4/RTP/MAVLink
  eth1
  p4local
  BMv2 simple_switch_grpc
  air0
  br-uavNN / tap-uavNN
  ns-3 pairwise L2 fabric
```

GS 侧路径：

```text
GS host traffic
  gs0
  p4gs-local
  BMv2 simple_switch_grpc
  tap-gs
  ns-3 pairwise L2 fabric
```

当前 P4 产物：

```text
p4/ucs_edge_cluster_route.p4
p4/build/ucs_edge_cluster_route.json
p4/build/ucs_edge_cluster_route.p4info.txt
```

手动重载 cluster-head 表项：

```bash
./p4/apply_cluster_heads.sh \
  --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json \
  --cluster-heads 1:uav01,2:uav04
```

绕过 BMv2 做对比：

```bash
UCS_MESH_DISABLE_BMV2=1 ./fleet/fleet_up.sh
```

## 链路仿真

默认拓扑使用 `impairment_policy=ns3_pairwise_links` 和 `large_small_fading_v1`。共 21 条独立逻辑链路：

```text
6  条 GS-UAV 链路来自 links[]
15 条 UAV-UAV 链路来自 mesh_links[]
```

这些链路是端点对损伤管道，不是共享竞争的 ad-hoc Wi-Fi 域。ns-3 日志是实时链路损伤的权威来源，包含接收功率、路径损耗、遮挡损耗、多径扰动、PHY PER、MAC 重传/丢包、队列延迟和 airtime 等字段。

查看实时或离线 ns-3 链路日志：

```bash
source ./fleet/env_defaults.sh
"$PYTHON_BIN" ./debug/monitor_link_impairment.py --wait --follow --from-end --focus uav04
"$PYTHON_BIN" ./debug/monitor_link_impairment.py \
  --log /tmp/ucs_mesh_ns3_wifi_adhoc_matrix_2x3_6uav_v1.launcher.log \
  --focus uav04
```

## 视频和控制

视频源是真实 Gazebo 相机图像，不是背景流量。拓扑定义一套 1080p 相机源和两类 RTP/H.264 业务流：

```text
Gazebo camera topic -> rtp_camera_bridge.py -> RTP/H.264 UDP -> GS
源 IP:       UAV 实验网 IP
目的 IP:     10.10.0.254
子流:        5600 + UAV idx, 960x540, 30fps, 1500kbps
主流:        5700 + UAV idx, 1920x1080, 30fps, 8000kbps
```

`fleet_up.sh` 默认启动所有 UAV 的 540p 子流。1080p 主流是显式开关，因为六架无人机同时双流会产生 12 路 H.264 编码，可能超过当前 GPU 的 NVENC 并发能力：

```bash
UCS_MESH_VIDEO_MAIN_MODE=on ./fleet/fleet_up.sh --headless
./fleet/fleet_up.sh --headless --with-video-main
```

单架次按需拉流入口保留在 `run_rtp_camera_flow.sh`：

```bash
sudo -v
./video/run_rtp_camera_flow.sh --uav uav04 --duration-sec 30
./video/run_rtp_camera_flow.sh --uav uav04 --flow video_main --duration-sec 30
```

GS 上直接查看 RTP：

```bash
gst-launch-1.0 udpsrc address=10.10.0.254 port=5604 \
  caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" \
  ! rtph264depay ! avdec_h264 ! videoconvert ! autovideosink sync=false

gst-launch-1.0 udpsrc address=10.10.0.254 port=5704 \
  caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" \
  ! rtph264depay ! avdec_h264 ! videoconvert ! autovideosink sync=false
```

Dashboard 的 MJPEG 代理地址：

```text
http://127.0.0.1:8088/video/uav04.mjpg?stream=sub&w=960&h=540&q=75
http://127.0.0.1:8088/video/uav04.mjpg?stream=main&w=1920&h=1080&q=80
```

浏览器控制链路：

```text
dashboard browser
  -> control/remote_web.py
  -> control/control_core.py
  -> MAVSDK gRPC
  -> MAVLink UDP
  -> BMv2/ns-3
  -> PX4
```

完整启动默认是 `--control-uav all`，每架 UAV 一套 relay/core/MAVSDK 端口：

```text
relay:          8771 ... 8776
control core:   9011 ... 9016
MAVSDK server: 50101 ... 50106
MAVSDK UDP:     14601 ... 14606
```

单架控制调试：

```bash
./control/control_up.sh --uav uav04 --bg
```

## Dashboard

启动 Web 前端：

```bash
./frontend/dashboard_up.sh --host 127.0.0.1 --port 8088
```

Dashboard 会读取拓扑、metrics、ns-3 链路状态、Docker 状态、RTP 接收状态和每架 UAV 的控制运行时文件。左侧是机群拓扑和链路矩阵，右侧是所选 UAV 的视频和控制面板。

## 常用检查

静态检查：

```bash
source ./fleet/env_defaults.sh
"$PYTHON_BIN" -m json.tool ./topology/wifi_adhoc_matrix_2x3_6uav.json >/dev/null
bash -n ./fleet/*.sh ./px4_gazebo/*.sh ./network/*.sh ./video/*.sh \
  ./frontend/*.sh ./control/*.sh ./deploy/*.sh ./p4/*.sh ./debug/*.sh \
  ./deploy/docker/gazebo-runtime/*.sh ./deploy/docker/uav-bmv2/*.sh
"$PYTHON_BIN" -m py_compile ./control/*.py ./frontend/*.py ./network/*.py \
  ./video/*.py ./p4/*.py ./debug/*.py
git diff --check
```

无副作用解析检查：

```bash
./fleet/uav_profile.sh --idx 6
./network/net_up.sh --dry-run --verbose
./network/metrics_up.sh --dry-run
./video/run_rtp_camera_flow.sh --uav uav04 --duration-sec 5 --dry-run
./debug/check_gimbal_payload.sh
```

启动后现场检查：

```bash
docker exec uav01 ip -br addr show eth0
docker exec uav01 ip -br addr show eth1
docker exec uav01 ip route
docker exec uav01 ip neigh
docker exec uav01 ping -c 3 10.10.1.2
ip route get 10.10.1.1
```

## 迁移和镜像

服务器部署优先使用固定镜像和已编译 P4 产物，不在服务器上临时构建：

```bash
./deploy/export_docker_images.sh
docker load -i ucs-runtime-images-20260625.tar
```

运行时镜像：

```text
ucs-uav-base-gz-bmv2:20260625
ucs-gazebo-runtime:20260625
ucs-p4runtime-sh:20260625
```

开发机上才需要的构建命令：

```bash
./deploy/docker/uav-bmv2/build_image.sh
./deploy/docker/gazebo-runtime/build_image.sh
./p4/compile.sh --program ./p4/ucs_edge_cluster_route.p4
```

P4Runtime 加载默认使用 `p4/build/` 下已存在的产物，不会自动编译。只有开发机需要用 `./p4/load_pipeline_observation.sh --compile`。

## 许可证

当前仓库保留所有权利，见 `LICENSE`。如需改为开源许可证，应先明确授权范围再替换该文件。
