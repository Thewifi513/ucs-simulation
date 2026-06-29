# 视频业务流模块

本目录负责把 Gazebo 相机话题转换为实验网中的 RTP/H.264 业务流。视频流被视为业务负载，会从 UAV 实验网地址发往 GS，经过 BMv2/ns-3，而不是 dashboard 的本地假流。

## 文件说明

```text
run_rtp_camera_flow.sh  按拓扑启动单架、全机或指定业务流的视频发送进程
rtp_camera_bridge.py    订阅 Gazebo camera topic，缩放/编码后发送 RTP/H.264 UDP
```

## 常用指令

单架子流：

```bash
sudo -v
./video/run_rtp_camera_flow.sh --uav uav04 --duration-sec 30
```

全机子流：

```bash
sudo -v
./video/run_rtp_camera_flow.sh --all
```

单架 1080p 主流：

```bash
sudo -v
./video/run_rtp_camera_flow.sh --uav uav04 --flow video_main
```

只解析命令，不启动流：

```bash
./video/run_rtp_camera_flow.sh --uav uav04 --dry-run
```

指定编码器：

```bash
./video/run_rtp_camera_flow.sh --uav uav04 --encoder hard
./video/run_rtp_camera_flow.sh --uav uav04 --encoder x264
```

子流默认 keyframe 间隔为 0.5s，主流默认 1.0s。调试切换时可临时覆盖：

```bash
./video/run_rtp_camera_flow.sh --uav uav04 --keyframe-interval-sec 0.5
```

Ubuntu 20 宿主机缺 Gazebo Python binding 或 GStreamer Python binding 时，使用 Docker helper：

```bash
UCS_GZ_HELPER_BACKEND=docker \
UCS_GZ_HELPER_DOCKER_GPU=1 \
./video/run_rtp_camera_flow.sh --uav uav04 --encoder hard
```

Docker helper 使用 `--network container:uavNN` 共享对应 UAV 容器网络命名空间，RTP 源地址仍是 UAV 实验网 IP，业务流继续经过 BMv2/ns-3。

GS 侧直接查看 RTP：

```bash
gst-launch-1.0 udpsrc address=10.10.0.254 port=5604 \
  caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" \
  ! rtph264depay ! avdec_h264 ! videoconvert ! autovideosink sync=false
```

## 运行产物

```text
/tmp/ucs_mesh_rtp_camera_<scenario>.launcher.log
/tmp/ucs-mesh-$UID/<scenario>/rtp-camera.pid
/tmp/ucs-mesh-$UID/<scenario>/rtp-camera/uavNN-video.log
```

## 预留接口

- 业务流定义来自拓扑 `globals.business_flows.video` 和 `video_main`。
- 新增码流类型时，在拓扑中增加新的 flow key，然后通过 `--flow <key>` 启动。
- `--print-pipeline` 用于暴露实际 GStreamer pipeline，便于后续前端或调试接口展示。
- `--encoder auto|hard|nvh264enc|nvautogpuh264enc|nvcudah264enc|va|vaapi|v4l2|openh264enc|x264` 是当前编码器扩展口。
- `UCS_GZ_HELPER_BACKEND=auto|host|docker` 控制相机桥运行位置；Docker 模式需要运行中的 UAV 容器。
- 多路硬编受 NVENC session 和宿主 GPU 状态影响，`fleet_down.sh` 会按视频端口清理新旧路径残留，避免旧进程占用编码器。
