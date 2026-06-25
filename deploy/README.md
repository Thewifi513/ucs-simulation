# 部署与迁移模块

本目录负责服务器预检、固定镜像导出、Docker 镜像定义和 Ubuntu 20 GPU 服务器迁移说明。这里的脚本原则是可复现、少侵入、不清理共享服务器旧项目。

## 文件说明

```text
deploy_ubuntu20_server.md       Ubuntu 20 GPU 服务器部署说明
ubuntu20_server_preflight.sh    只读预检脚本，不安装、不拉镜像、不启动仿真
ubuntu20_server_check_deploy.sh 分阶段迁移检查和部署准备入口
docker_images.env               固定镜像清单和导出版本号
export_docker_images.sh         导出运行时镜像 tar 和 sha256
docker/gazebo-runtime/          Gazebo headless runtime 镜像
docker/uav-bmv2/                UAV BMv2 runtime 镜像
docker/p4-compiler/             P4 编译镜像
```

## 常用指令

只读预检：

```bash
./deploy/ubuntu20_server_preflight.sh
```

指定服务器路径：

```bash
PX4_DIR=/path/to/PX4-Autopilot \
NS3_DIR=/path/to/ns-3 \
PYTHON_BIN=/path/to/venv/bin/python \
./deploy/ubuntu20_server_preflight.sh
```

分阶段迁移检查：

```bash
PX4_DIR=/path/to/PX4-Autopilot \
NS3_DIR=/path/to/ns-3 \
PYTHON_BIN=/path/to/ucs/.venv/bin/python \
./deploy/ubuntu20_server_check_deploy.sh check --strict
```

服务器部署准备，不启动完整仿真：

```bash
PX4_DIR=/path/to/PX4-Autopilot \
NS3_DIR=/path/to/ns-3 \
./deploy/ubuntu20_server_check_deploy.sh deploy \
  --image-tar ./ucs-runtime-images-20260625.tar
```

准备平台 Python venv：

```bash
cd /path/to/ucs
python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r ./ucs-simulation/requirements.txt
python - <<'PY'
import gz.transport13
import gz.msgs10
import mavsdk
import websockets
PY
```

导出固定运行时镜像：

```bash
./deploy/export_docker_images.sh
```

导出时包含构建镜像：

```bash
INCLUDE_BUILD_IMAGES=1 ./deploy/export_docker_images.sh
```

开发机重建镜像：

```bash
./deploy/docker/uav-bmv2/build_image.sh
./deploy/docker/gazebo-runtime/build_image.sh
./p4/compile.sh
```

## 运行产物

```text
ucs-runtime-images-20260625.tar
ucs-runtime-images-20260625.tar.sha256
```

## 预留接口

- 固定镜像列表集中在 `docker_images.env`，新增运行时镜像时先改这里。
- 服务器部署优先 `docker load` 固定镜像，不在服务器现场构建。
- `ubuntu20_server_check_deploy.sh deploy` 只做 venv、镜像导入、ns-3 scratch、preflight 和 dry-run，不启动完整 fleet。
- `ubuntu20_server_preflight.sh --no-ports` 可跳过端口检查，适合共享服务器已有服务较多的场景。
- `--strict` 可用于 CI 或交付前检查，让 warning 也变成非零退出。
- 所有路径都应通过 `PX4_DIR`、`NS3_DIR`、`PYTHON_BIN`、`MAVSDK_SERVER_BIN` 等变量覆盖，不要在部署脚本写死本机路径。
- 服务器运行时所有宿主机 Python 入口都应走平台 venv；系统 `python3` 只保留为开发机兜底。
