# 拓扑模块

本目录保存当前平台的有效拓扑定义。拓扑是各模块共享的契约：fleet、PX4/Gazebo、network、metrics、video、control、P4 都从这里解析节点、端口、链路、业务流和运行策略。

## 文件说明

```text
wifi_adhoc_matrix_2x3_6uav.json   当前 2x3 六 UAV BMv2 mesh 场景
```

## 当前场景

```text
scenario_id: wifi_adhoc_matrix_2x3_6uav_v1
UAV:         uav01 ... uav06
GS:          10.10.0.254/24
cluster 1:   uav01-uav03
cluster 2:   uav04-uav06
world:       px4_gazebo/worlds/ucs_obstacle_field.sdf
```

## 网络规划

观测网：

- Docker 管理的 `eth0` / `172.*`。
- 用于 Gazebo transport、PX4 观测、`/clock`、姿态 metrics、Docker 控制和 P4Runtime 管理。
- 不经过 ns-3 链路损伤。

实验网：

- GS: `10.10.0.254/24`
- Cluster 1: `uav01=10.10.1.1/24`, `uav02=10.10.1.2/24`, `uav03=10.10.1.3/24`
- Cluster 2: `uav04=10.10.2.4/24`, `uav05=10.10.2.5/24`, `uav06=10.10.2.6/24`
- 每架 UAV 容器内可见 `eth1`。
- `br-uavNN` 只是 `tap-uavNN` 和 UAV 容器之间的接入层，不是一组 mesh peer 接口。

当前拓扑声明 21 条独立逻辑无线链路：

```text
6  条 GS-UAV 链路来自 links[]
15 条 UAV-UAV 链路来自 mesh_links[]
```

这些链路是端点对损伤管道，不是共享竞争的 ad-hoc Wi-Fi 域。

## 业务流

```text
control:         QGC/PX4 UDP 端口，以及 14600 + UAV idx 的 MAVSDK UDP
video:           960x540@30 RTP/H.264 子流，端口 5600 + UAV idx
video_main:      1920x1080@30 RTP/H.264 主流，端口 5700 + UAV idx
```

子流默认随完整平台启动，主流只在显式开启时启动：

```bash
./fleet/fleet_up.sh --headless --with-video-main
UCS_MESH_VIDEO_MAIN_MODE=on ./fleet/fleet_up.sh --headless
```

## BMv2/P4

当前拓扑启用 UAV 容器内联 BMv2：

```json
"programmable_net": {
  "enabled": true,
  "placement": "in_uav_container_inline"
}
```

UAV 数据面路径：

```text
UAV apps / PX4 / RTP / MAVLink
  eth1
  p4local
  BMv2 simple_switch_grpc
  air0
  br-uavNN / tap-uavNN
  ns-3 pairwise L2 fabric
```

GS 数据面路径：

```text
GS host traffic on gs0
  p4gs-local
  BMv2 simple_switch_grpc
  tap-gs
  ns-3 pairwise L2 fabric
```

cluster-head 默认规则：

```text
cluster 1 -> uav01
cluster 2 -> uav04
```

## 常用指令

检查 JSON 格式：

```bash
source ./fleet/env_defaults.sh
"$PYTHON_BIN" -m json.tool ./topology/wifi_adhoc_matrix_2x3_6uav.json >/dev/null
```

解析单架 profile：

```bash
./fleet/uav_profile.sh --idx 6
```

做无副作用联动检查：

```bash
./network/net_up.sh --dry-run --verbose
./network/metrics_up.sh --dry-run
./video/run_rtp_camera_flow.sh --uav uav04 --duration-sec 5 --dry-run
./debug/check_gimbal_payload.sh
```

## 预留接口

- 新增 UAV 时，需要同步增加 `instances[]`、`links[]`、`mesh_links[]`、业务流端口和 cluster 信息。
- 新增业务流时，在 `globals.business_flows` 下增加 flow key，视频模块可通过 `--flow <key>` 消费。
- 新增 world 或模型时，更新 `globals.world_sdf`、实例 `model_name`、spawn pose 和 PX4 model 信息。
- 新增链路损伤参数时，优先扩展 `globals.link_simulation`，再让 `network/metrics_worker.py` 和 ns-3 scratch 消费。
- 新增 P4 策略时，扩展 `programmable_net` 和 `routing` 字段，再由 `p4/cluster_head_entries.py` 或新的 runtime 生成器处理。
