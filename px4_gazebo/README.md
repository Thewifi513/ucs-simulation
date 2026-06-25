# PX4/Gazebo 模块

本目录负责仿真 world 和 PX4 SITL 实例启动。它只处理动力学、模型、Gazebo transport、PX4 MAVLink 实例，不负责网络损伤、P4、视频转发或浏览器控制。

## 文件说明

```text
world_up.sh                    启动 Gazebo world，可走宿主机或 Docker headless 后端
px4_up.sh                      启动单架 UAV 对应的 PX4 SITL 实例
worlds/ucs_obstacle_field.sdf  当前场景 world 资源
```

## 常用指令

启动 headless world：

```bash
./px4_gazebo/world_up.sh --headless
```

使用 Docker Gazebo 后端和 NVIDIA GPU：

```bash
UCS_GAZEBO_BACKEND=docker \
UCS_GAZEBO_DOCKER_GPU=1 \
./px4_gazebo/world_up.sh --headless --backend docker
```

启动单架 PX4：

```bash
./px4_gazebo/px4_up.sh --idx 4
./px4_gazebo/px4_up.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --idx 4 --no-terminal
```

完整平台通常不要单独手动调用这里，而是由：

```bash
./fleet/fleet_up.sh --headless
```

统一编排。

## 运行产物

```text
/tmp/ucs-mesh-$UID/<scenario>/world-launcher.log
/tmp/ucs-mesh-$UID/<scenario>/world-A.log
/tmp/ucs-mesh-$UID/<scenario>/px4-uavNN-launcher.log
UAV 容器内 /tmp/ucs-mesh-px4-<instance>.pid
```

## 预留接口

- world 路径来自拓扑 `globals.world_sdf`，新增场景时优先新增 world 文件和拓扑，不要在脚本里写死。
- Gazebo 后端通过 `UCS_GAZEBO_BACKEND=host|docker` 切换。
- Docker headless GPU 通过 `UCS_GAZEBO_DOCKER_GPU=1` 打开。
- 相机负载 profile 通过 `UCS_GAZEBO_CAMERA_PROFILE` 控制，当前可用于 Docker headless 低负载或 1080p 覆盖。
- PX4 路径通过 `PX4_DIR`、`GZ_ENV_SH`、`PX4_GZ_MODELS`、`PX4_GZ_WORLDS` 覆盖。
- 新增机型时，应同时检查拓扑里的 `px4_model`、`model_name`、spawn pose 和 `px4_up.sh` 对应环境变量。
