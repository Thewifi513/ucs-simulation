# P4/BMv2 模块

本目录负责 P4 程序、编译产物和 P4Runtime 加载。它不创建 Linux 网络接口，只向已经启动的 BMv2 simple_switch_grpc 下发 pipeline 和表项。

## 文件说明

```text
ucs_edge_cluster_route.p4                 当前 P4 源程序
compile.sh                                使用固定 Docker 编译 P4，生成 BMv2 JSON 和 P4Info
load_pipeline_observation.sh              通过观测网给 GS/UAV BMv2 加载 pipeline 和表项
apply_cluster_heads.sh                    运行中更新 cluster-head 路由表项
apply_adaptive_routes.sh                  运行中更新 adaptive_prior/adaptive_resource 路由表项
runtime_set_pipeline.py                   P4Runtime set_pipeline_config 工具
cluster_head_entries.py                   根据拓扑批量生成 cluster_heads/adaptive_* P4Runtime 表项
build/ucs_edge_cluster_route.json         已编译 BMv2 JSON
build/ucs_edge_cluster_route.p4info.txt   已编译 P4Info
```

## 常用指令

编译 P4：

```bash
./p4/compile.sh
```

只检查将要加载的目标：

```bash
./p4/load_pipeline_observation.sh --dry-run
```

加载所有 UAV 和 GS：

```bash
./p4/load_pipeline_observation.sh --include-gs --cluster-head-routes
```

只加载单架：

```bash
./p4/load_pipeline_observation.sh --target uav04 --cluster-head-routes
```

运行中切换 cluster head：

```bash
./p4/apply_cluster_heads.sh \
  --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json \
  --cluster-heads 1:uav01,2:uav04
```

运行中切换为资源调度自选路：

```bash
./p4/apply_adaptive_routes.sh \
  --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json
```

批量更新关键目标，避免每个目标单独启动一次 P4Runtime loader：

```bash
./p4/apply_adaptive_routes.sh \
  --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json \
  --targets gs,uav03,uav01
```

跟随运行时链路状态自动重算：

```bash
./p4/adaptive_route_monitor.sh \
  --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json \
  --interval-sec 0.5
```

监控器每轮会一次性生成所有 watched targets 的候选表项，再比较 `p4/build/p4runtime_entries/*.json`，避免逐目标重复启动 Python 和查询容器 MAC。

## 运行产物

```text
p4/build/ucs_edge_cluster_route.json
p4/build/ucs_edge_cluster_route.p4info.txt
p4/build/p4runtime_entries/*.json   live 加载时临时生成，可删除
```

服务器迁移默认携带 `p4/build/*.json` 和 `*.p4info.txt`，不在服务器现场编译。

## 预留接口

- 新 P4 表或 action 应先扩展 `ucs_edge_cluster_route.p4`，再扩展 `cluster_head_entries.py` 的表项生成逻辑。
- `load_pipeline_observation.sh --target` 是单设备调试入口。
- `--cluster-heads 1:uav01,2:uav04` 是当前 cluster-head 策略的外部控制接口。
- `programmable_net.routing.mode=adaptive_prior` 会按 GS-UAV 边和同 cluster UAV-UAV 边计算最短代价下一跳。
- `programmable_net.routing.mode=adaptive_resource` 会允许全 UAV-UAV mesh 参与调度，不再把 cluster 当作硬约束；`resource_nodes` 中的节点用更高 `tx_power_dbm`、`bandwidth_mbps` 和更低 `relay_penalty` 影响路由代价。
- 自适应模式的边权优先读取运行时 `/dev/shm` 链路状态和 metrics 位置，再读取 `routing_cost`、`prior_cost`、`prior_loss`、`delay_ms` 等显式先验字段，缺省时用拓扑位置距离和障碍物损伤估算。
- `--compile` 可用于开发机自动重编译；服务器建议保持 `--no-compile` 和固定产物。
- 新 BMv2 目标应先在拓扑 `programmable_net` 中声明 device id、grpc 地址和端口映射。
