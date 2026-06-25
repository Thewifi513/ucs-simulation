# 网络与链路仿真模块

本目录负责实验网的 Linux plumbing、ns-3 TapBridge、BMv2 接入链路和链路状态 metrics。它定义“包如何从 UAV/GS 进入 ns-3 和 BMv2”，不负责 Gazebo 模型、浏览器控制或视频编码。

## 文件说明

```text
net_up.sh                         启动 ns-3 live helper，配置 TAP/bridge/veth/route/BMv2 接入
metrics_up.sh                     生成 metrics runtime，并启动或停止 metrics worker
metrics_worker.py                 从 Gazebo 读取姿态和 sim time，输出链路状态/共享内存 metrics
ns3/ucs_fleet_l2_mesh_topology.cc  当前 ns-3 scratch 源码
```

## 常用指令

只解析网络拓扑，不改系统网络：

```bash
./network/net_up.sh --dry-run --verbose
```

只配置 plumbing，不启动 ns-3：

```bash
./network/net_up.sh --plumb-only --verbose
```

生成 metrics runtime，不启动 worker：

```bash
./network/metrics_up.sh --dry-run
```

后台启动 metrics：

```bash
./network/metrics_up.sh --bg
```

停止 metrics：

```bash
./network/metrics_up.sh --stop
```

安装 ns-3 scratch 到外部 ns-3 树：

```bash
cp ./network/ns3/ucs_fleet_l2_mesh_topology.cc "$NS3_DIR/scratch/"
cd "$NS3_DIR"
./ns3 build scratch/ucs_fleet_l2_mesh_topology
```

## 运行产物

```text
/tmp/ucs_mesh_ns3_<scenario>.launcher.log
/tmp/ucs_mesh_ns3_<scenario>.pid
/tmp/ucs_mesh_metrics_<scenario>.runtime.json
/tmp/ucs_mesh_metrics_<scenario>.launcher.log
/tmp/ucs_mesh_sim_time.txt
/dev/shm/ucs_mesh_metrics_<scenario>.bin
/tmp/ucs_mesh_metrics_<link>.txt
```

## 预留接口

- 新链路模型优先通过拓扑 `globals.link_simulation` 增加字段，由 `metrics_worker.py` 生成 runtime，再由 ns-3 scratch 消费。
- 新网络拓扑应扩展 `instances[]`、`links[]`、`mesh_links[]`，不要在 `net_up.sh` 中写死节点。
- `net_up.sh --ready-file FILE` 是给 `fleet_up.sh` 等上层编排使用的同步接口。
- `metrics_channel=shm` 是当前高频链路 metrics 通道，旧文本文件只作为兼容和调试输出。
- BMv2 接入由拓扑 `programmable_net` 控制，可用 `UCS_MESH_DISABLE_BMV2=1` 做 Linux/ns-3 对比实验。
