# P4 Compiler 镜像

这个镜像是 `ucs-simulation` 的可移植 P4 编译层，和 UAV 运行时镜像分开：

```text
ucs-uav-base-gz-bmv2:20260625  在 UAV 容器内运行 simple_switch_grpc
ucs-p4-compiler:20260625       把 .p4 编译成 BMv2 JSON 和 P4Info
```

开发机上从 `ucs-simulation` 根目录编译：

```bash
./p4/compile.sh
```

输出目录：

```text
p4/build/
```

服务器部署默认使用已存在的 `p4/build/ucs_edge_cluster_route.json` 和 `p4/build/ucs_edge_cluster_route.p4info.txt`，不在服务器上现场编译。只有修改 P4 程序后才需要在开发机重建产物。
