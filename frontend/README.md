# 前端与 Dashboard 模块

本目录负责浏览器观测界面、HTTP API、MJPEG 视频代理和浏览器控制入口聚合。它不直接启动仿真组件，只读取 runtime、日志、端口和拓扑状态。

## 文件说明

```text
dashboard_up.sh       启动 dashboard HTTP 服务
dashboard_server.py   HTTP API、状态聚合、MJPEG 视频代理、控制 runtime 探测
index.html            浏览器前端页面
```

## 常用指令

启动 dashboard：

```bash
./frontend/dashboard_up.sh --host 0.0.0.0 --port 8088
```

指定控制 WebSocket 默认入口：

```bash
./frontend/dashboard_up.sh \
  --control-protocol relay \
  --control-ws ws://127.0.0.1:8774
```

指定视频解码策略：

```bash
./frontend/dashboard_up.sh --video-decoder hard
./frontend/dashboard_up.sh --video-decoder avdec_h264
```

访问：

```text
http://127.0.0.1:8088
http://127.0.0.1:8088/api/state
http://127.0.0.1:8088/video/uav04.mjpg?stream=sub&w=960&h=540&q=75
```

## 运行产物

```text
/tmp/ucs_mesh_dashboard_<scenario>.launcher.log
/tmp/ucs-mesh-$UID/<scenario>/dashboard.pid
/tmp/ucs_mesh_control_<scenario>_uavNN.runtime.json
```

## 预留接口

- `/api/state` 是前端和外部观测工具的主要状态接口。
- `/video/<uav>.mjpg` 是当前浏览器视频代理接口，可通过 `stream=sub|main` 选择子流或主流。
- 控制面板默认读取每架 UAV 的 control runtime，切换 UAV 时应切换对应 relay/core/MAVSDK 端口。
- 后续 debug 工具接入前端时，建议新增只读 API 读取 `debug/` 输出，不让前端直接执行高权限命令。
- 前端只做展示和轻控制，不应承担网络、PX4、P4 的启动逻辑。
