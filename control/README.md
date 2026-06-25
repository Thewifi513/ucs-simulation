# UAV 控制模块

本目录负责浏览器到 PX4 的控制链路。它不负责启动 Gazebo、网络或 dashboard，只负责把 WebSocket/JSON 控制命令转换为 MAVSDK/PX4 offboard 控制。

## 链路结构

```text
dashboard browser
  -> remote_web.py
  -> control_core.py
  -> mavsdk_server gRPC
  -> MAVLink UDP
  -> BMv2/ns-3
  -> PX4
```

## 文件说明

```text
control_up.sh                    启动单架 UAV 的 mavsdk_server、control_core、remote_web
control_down.sh                  停止单架或全场景控制后端
control_core.py                  MAVSDK/PX4 offboard 控制核心，负责速度/航向/事件命令
remote_web.py                    浏览器 WebSocket relay，转发到 control_core JSON-line socket
mavsdk_server_musl_x86_64        控制模块自带的 mavsdk_server 二进制
```

## 常用指令

启动单架控制：

```bash
PYTHON_BIN=/path/to/venv/bin/python ./control/control_up.sh --uav uav04
```

后台启动单架控制：

```bash
PYTHON_BIN=/path/to/venv/bin/python ./control/control_up.sh --uav uav04 --bg
```

指定端口：

```bash
./control/control_up.sh \
  --uav uav04 \
  --core-port 9014 \
  --relay-port 8774 \
  --mavsdk-server-port 50104 \
  --bg
```

停止单架：

```bash
./control/control_down.sh --uav uav04
```

停止当前场景全部控制后端：

```bash
./control/control_down.sh --all
```

完整平台默认由 `fleet/fleet_up.sh` 启动全部 UAV 控制后端：

```bash
PYTHON_BIN=/path/to/venv/bin/python ./fleet/fleet_up.sh --headless --with-control --control-uav all
```

## 端口规则

全 UAV 模式下，端口按拓扑 `idx` 派生：

```text
remote_web relay: 8770 + idx
control_core:     9010 + idx
mavsdk_server:    50100 + idx
MAVSDK UDP:       14600 + idx
```

例如 `uav04`：

```text
browser ws://127.0.0.1:8774
control_core 127.0.0.1:9014
mavsdk_server 127.0.0.1:50104
PX4 MAVSDK UDP udpin://0.0.0.0:14604
```

## 运行产物

```text
/tmp/ucs-mesh-$UID/control/<scenario>/uavNN/<timestamp>/
  mavsdk_server.pid
  control_core.pid
  remote_web.pid
  mavsdk_server.log
  control_core.log
  remote_web.log
  control_trace.csv
  event_trace.csv

/tmp/ucs_mesh_control_<scenario>_uavNN.runtime.json
```

## 依赖

Python 环境需要：

```text
gz.transport13
gz.msgs10
mavsdk
websockets
```

控制模块本身只直接使用 `mavsdk` 和 `websockets`，但完整平台的同一个 `PYTHON_BIN` 还会运行 metrics、video 和 dashboard，因此服务器 venv 也必须能导入 Gazebo Python binding。推荐创建方式：

```bash
cd /path/to/ucs
python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install mavsdk websockets
python - <<'PY'
import gz.transport13
import gz.msgs10
import mavsdk
import websockets
PY
```

解析顺序：

```text
PYTHON_BIN
UCS_VENV_DIR/bin/python
ucs-simulation/.venv/bin/python
python3，仅作为开发机兜底；服务器迁移不要依赖这一项
```

`mavsdk_server` 默认从本目录的 `mavsdk_server` 或 `mavsdk_server_musl_x86_64` 解析，也可以通过 `MAVSDK_SERVER_BIN` 覆盖。

## 预留接口

- `MAX_HORIZONTAL_SPEED_MPS`、`MAX_VERTICAL_SPEED_MPS`、`MAX_YAW_RATE_DEG_S` 控制归一化滑杆到真实速度的映射。
- `MAVSDK_URL` 可覆盖拓扑解析出的 UDP 入口，用于单机调试或特殊网络路径。
- `control_trace.csv` 和 `event_trace.csv` 是后续实验复盘、前端事件面板或控制性能分析的接口。
- `remote_web.py` 是浏览器协议边界；后续新增 UI 控制命令应优先在这里定义兼容消息格式，再让 `control_core.py` 实现动作。
- 控制链路不要抢 QGC 端口；QGC 仍使用 `instances[].qgc_port` 和宿主 `14550`，MAVSDK 使用独立端口组。
