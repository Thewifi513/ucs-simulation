# 开关与环境模块

本目录负责平台级启动、停止、环境路径推导、桌面入口和 UAV 容器准备。团队协作时，这里是“整个平台怎么起来、怎么停、默认路径从哪里来”的入口。

## 文件说明

```text
fleet_up.sh             完整平台启动入口，编排 Gazebo/PX4/network/metrics/dashboard/control/video/P4
fleet_down.sh           完整平台停止和清理入口，回收进程、容器网络、TAP/bridge/veth、旧 RTP 残留
env_defaults.sh         统一路径、镜像和 PYTHON_BIN 默认值，不直接运行，只供其他脚本 source
desktop_fleet_up.sh     桌面快捷方式启动入口
desktop_fleet_down.sh   桌面快捷方式停止入口
ensure_container.sh     按拓扑确保单架 UAV 容器存在，可按需重建
uav_profile.sh          从拓扑解析单架 UAV 的 PX4、网络、MAVLink、metrics、BMv2 参数
icons/                  桌面快捷方式图标
```

## 常用指令

从平台根目录启动完整 headless 栈：

```bash
PYTHON_BIN=/path/to/venv/bin/python \
UCS_GAZEBO_BACKEND=docker \
UCS_GAZEBO_DOCKER_GPU=1 \
./fleet/fleet_up.sh --headless
```

停止并清理：

```bash
./fleet/fleet_down.sh --verbose
```

只做单架 UAV profile 解析：

```bash
./fleet/uav_profile.sh --idx 4
./fleet/uav_profile.sh --id uav04
```

重建单架 UAV 容器：

```bash
./fleet/ensure_container.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --idx 4 --recreate
```

常见启动开关：

```bash
./fleet/fleet_up.sh --headless --no-video --no-control --with-dashboard
./fleet/fleet_up.sh --headless --with-video-main
./fleet/fleet_up.sh --headless --control-uav uav04
```

## 运行产物

```text
/tmp/ucs-mesh-$UID/<scenario>/                 平台 PID 和组件日志
/tmp/ucs_mesh_ns3_<scenario>.launcher.log      ns-3/network 日志
/tmp/ucs_mesh_metrics_<scenario>.launcher.log  metrics 日志
/tmp/ucs_mesh_rtp_camera_<scenario>.launcher.log 视频启动日志
/tmp/ucs_mesh_dashboard_<scenario>.launcher.log dashboard 日志
/tmp/ucs_mesh_control_<scenario>_uavNN.*       控制后端日志和 runtime JSON
```

## 预留接口

- 路径迁移不要改脚本硬编码，优先覆盖 `UCS_WORKSPACE_ROOT`、`PX4_DIR`、`NS3_DIR`、`PYTHON_BIN`。
- 服务器运行时 `PYTHON_BIN` 应指向平台 venv；系统 `python3` 只作为开发机兜底。
- 镜像固定由 `env_defaults.sh` 管理，可通过 `UCS_UAV_BASE_IMAGE`、`UCS_MESH_BMV2_IMAGE`、`UCS_GAZEBO_IMAGE` 覆盖。
- 新增业务组件时，建议在 `fleet_up.sh` 增加 `start_xxx` 和 `xxx_should_start`，并在 `fleet_down.sh` 增加对称清理。
- 新增拓扑字段时，先让 `uav_profile.sh` 能解析，再让具体模块消费，避免多个脚本各自解析 JSON。
- 桌面入口只调用本目录脚本；图标放在 `fleet/icons/`，根目录 `.desktop` 只保留便于复制。
