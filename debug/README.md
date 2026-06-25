# Debug 工具模块

本目录存放非主流程调试工具。这里的脚本默认不属于完整平台启动链路，后续可以挑选稳定工具接入 dashboard，作为用户按需调用的诊断接口。

## 文件说明

```text
check_gimbal_payload.sh       检查拓扑中的 x500_gimbal 载荷、相机 topic 和业务流端口
monitor_link_impairment.py    查看 ns-3 链路损伤日志，支持 follow/focus
pairwise_impair_up.sh         旧 tc/netem pairwise impairment 调试入口
pairwise_impair_worker.py     旧 pairwise impairment worker
```

## 常用指令

检查拓扑载荷配置：

```bash
./debug/check_gimbal_payload.sh
```

对比 live Gazebo topic：

```bash
./debug/check_gimbal_payload.sh --verify-live
```

查看某架 UAV 相关链路损伤日志：

```bash
source ./fleet/env_defaults.sh
"$PYTHON_BIN" ./debug/monitor_link_impairment.py --wait --follow --from-end --focus uav04
```

解析离线 ns-3 日志：

```bash
"$PYTHON_BIN" ./debug/monitor_link_impairment.py \
  --log /tmp/ucs_mesh_ns3_wifi_adhoc_matrix_2x3_6uav_v1.launcher.log \
  --focus uav04
```

旧 tc impairment dry-run：

```bash
./debug/pairwise_impair_up.sh --dry-run --verbose
```

## 运行产物

```text
/tmp/ucs_mesh_ns3_<scenario>.launcher.log
/tmp/ucs_mesh_pairwise_impair_<scenario>.*   旧 pairwise impairment 运行产物
```

## 预留接口

- 后续接入前端时，优先把这些工具做成只读 API，避免浏览器直接触发 sudo 或 tc 操作。
- `monitor_link_impairment.py --focus` 可作为 dashboard 链路详情面板的数据来源。
- `check_gimbal_payload.sh --verify-live` 可作为启动后 payload/topic 自检按钮。
- `pairwise_impair_*` 属于旧调试路径，当前主链路损伤由 `network/ns3` 和 `metrics_worker.py` 负责。
