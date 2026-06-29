#!/usr/bin/env bash
set -Eeuo pipefail

# UCS mesh metrics launcher
#
# 职责：
#   - 读取 topology JSON
#   - 解析并固化 runtime 配置
#   - 检查 Gazebo / 输出路径 / 链路映射
#   - 拉起 network/metrics_worker.py
#
# 用法：
#   ./network/metrics_up.sh
#   ./network/metrics_up.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json
#   ./network/metrics_up.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --verbose
#   ./network/metrics_up.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --dry-run
#   ./network/metrics_up.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --bg
#   ./network/metrics_up.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --stop
#
# 说明：
#   - 当前默认前台运行，便于调试
#   - runtime 配置写到 /tmp/ucs_mesh_metrics_<scenario>.runtime.json
#   - worker PID 写到 /tmp/ucs_mesh_metrics_<scenario>.pid

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"
WORKER_PY="${MESH_DIR}/network/metrics_worker.py"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
WORLD_OVERRIDE=""
VERBOSE=0
DRY_RUN=0
STOP_ONLY=0
FOREGROUND=1
GZ_HELPER_BACKEND="${UCS_GZ_HELPER_BACKEND:-auto}"
GZ_HELPER_IMAGE="${UCS_GZ_HELPER_IMAGE:-$UCS_GAZEBO_IMAGE}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--topology FILE] [--world NAME] [--verbose] [--dry-run] [--fg|--bg] [--stop]

--topology FILE   Topology JSON file. Default: ${DEFAULT_TOPOLOGY}
--world NAME      Override Gazebo world name.
--verbose         Verbose launcher/worker output.
--dry-run         Only resolve runtime config and print it; do not start worker.
--fg              Foreground mode. (Current default behavior.)
--bg              Start worker in detached background mode and exit.
--stop            Stop existing worker for the resolved scenario and exit.

Environment:
  UCS_GZ_HELPER_BACKEND=auto|host|docker  Default: ${GZ_HELPER_BACKEND}
  UCS_GZ_HELPER_IMAGE=IMAGE               Default: ${GZ_HELPER_IMAGE}
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[metrics_up][ERR] missing command: $1" >&2
    exit 1
  }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[metrics_up][ERR] --topology requires a path" >&2; exit 1; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --world)
      [[ $# -ge 2 ]] || { echo "[metrics_up][ERR] --world requires a name" >&2; exit 1; }
      WORLD_OVERRIDE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --fg)
      FOREGROUND=1
      shift
      ;;
    --bg)
      FOREGROUND=0
      shift
      ;;
    --stop)
      STOP_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[metrics_up][ERR] unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

need_cmd "$PYTHON_BIN"
need_cmd timeout
need_cmd ip
need_cmd awk
need_cmd cut

[[ -f "$TOPOLOGY_FILE" ]] || { echo "[metrics_up][ERR] topology file not found: $TOPOLOGY_FILE" >&2; exit 1; }
[[ -f "$WORKER_PY" ]] || { echo "[metrics_up][ERR] worker not found: $WORKER_PY" >&2; exit 1; }

TOPOLOGY_FILE="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TOPOLOGY_FILE")"

SCENARIO_ID="$("$PYTHON_BIN" - "$TOPOLOGY_FILE" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    obj = json.load(f)
sid = obj.get("scenario_id")
if not sid:
    raise SystemExit("[metrics_up][ERR] missing scenario_id")
print(sid)
PY
)"

PIDFILE="/tmp/ucs_mesh_metrics_${SCENARIO_ID}.pid"
LOGFILE="/tmp/ucs_mesh_metrics_${SCENARIO_ID}.log"
RUNTIME_FILE="/tmp/ucs_mesh_metrics_${SCENARIO_ID}.runtime.json"
SAFE_SCENARIO_ID="$(printf '%s' "$SCENARIO_ID" | tr -c 'A-Za-z0-9_.-' '_')"
METRICS_CONTAINER="ucs-metrics-${SAFE_SCENARIO_ID}"

python_has_gz_transport() {
  "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import gz.transport13
import gz.msgs10
PY
}

resolve_gz_helper_backend() {
  case "$GZ_HELPER_BACKEND" in
    host)
      python_has_gz_transport || {
        echo "[metrics_up][ERR] UCS_GZ_HELPER_BACKEND=host but $PYTHON_BIN cannot import gz.transport13/gz.msgs10" >&2
        exit 1
      }
      need_cmd gz
      printf '%s\n' host
      ;;
    docker)
      need_cmd docker
      docker image inspect "$GZ_HELPER_IMAGE" >/dev/null 2>&1 || {
        echo "[metrics_up][ERR] helper image not found: $GZ_HELPER_IMAGE" >&2
        exit 1
      }
      printf '%s\n' docker
      ;;
    auto)
      if python_has_gz_transport && command -v gz >/dev/null 2>&1; then
        printf '%s\n' host
      else
        need_cmd docker
        docker image inspect "$GZ_HELPER_IMAGE" >/dev/null 2>&1 || {
          echo "[metrics_up][ERR] host Gazebo Python binding unavailable and helper image not found: $GZ_HELPER_IMAGE" >&2
          exit 1
        }
        printf '%s\n' docker
      fi
      ;;
    *)
      echo "[metrics_up][ERR] unsupported UCS_GZ_HELPER_BACKEND=$GZ_HELPER_BACKEND" >&2
      exit 1
      ;;
  esac
}

HELPER_BACKEND="$(resolve_gz_helper_backend)"

helper_gz_topic_once() {
  case "$HELPER_BACKEND" in
    host)
      timeout 5s env GZ_PARTITION="$GZ_PARTITION" GZ_IP="$GZ_IP" gz topic -e -n 1 -t /clock >/dev/null 2>&1
      ;;
    docker)
      timeout 8s docker run --rm \
        --network host \
        -e "GZ_PARTITION=${GZ_PARTITION}" \
        -e "GZ_IP=${GZ_IP}" \
        --entrypoint gz \
        "$GZ_HELPER_IMAGE" topic -e -n 1 -t /clock >/dev/null 2>&1
      ;;
  esac
}

find_worker_pids() {
  "$PYTHON_BIN" - "$RUNTIME_FILE" <<'PY'
import os
import sys

runtime_file = os.path.abspath(sys.argv[1])
self_pid = os.getpid()
parent_pid = os.getppid()

for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    pid = int(name)
    if pid in (self_pid, parent_pid):
        continue
    try:
        raw = open(f"/proc/{pid}/cmdline", "rb").read()
    except OSError:
        continue
    args = [part.decode("utf-8", errors="replace") for part in raw.split(b"\0") if part]
    if not args:
        continue
    has_worker = any(arg == "network/metrics_worker.py" or arg.endswith("/network/metrics_worker.py") for arg in args)
    has_runtime = runtime_file in args
    if has_worker and has_runtime:
        print(pid)
PY
}

stop_pid() {
  local label="$1"
  local pid="$2"
  [[ -n "$pid" ]] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  echo "[metrics_up] stopping ${label} pid=${pid}"
  kill "$pid" 2>/dev/null || true
  sleep 0.3
  if kill -0 "$pid" 2>/dev/null; then
    echo "[metrics_up] force killing ${label} pid=${pid}"
    kill -9 "$pid" 2>/dev/null || true
  fi
}

stop_existing() {
  local pid=""
  if [[ "$HELPER_BACKEND" == "docker" ]]; then
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$METRICS_CONTAINER"; then
      echo "[metrics_up] removing helper container: $METRICS_CONTAINER"
      docker rm -f "$METRICS_CONTAINER" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -f "$PIDFILE" ]]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    stop_pid "pidfile worker" "$pid"
    rm -f "$PIDFILE"
  else
    echo "[metrics_up] no pidfile: $PIDFILE"
  fi

  local worker_pids=()
  mapfile -t worker_pids < <(find_worker_pids)
  if [[ "${#worker_pids[@]}" -eq 0 ]]; then
    echo "[metrics_up] no matching metrics_worker process for runtime: $RUNTIME_FILE"
    return 0
  fi

  local worker_pid
  for worker_pid in "${worker_pids[@]}"; do
    [[ -n "$worker_pid" ]] || continue
    if [[ -n "$pid" && "$worker_pid" == "$pid" ]]; then
      continue
    fi
    stop_pid "orphan metrics_worker" "$worker_pid"
  done
}

if [[ "$STOP_ONLY" -eq 1 ]]; then
  stop_existing
  exit 0
fi

if [[ -f "$PIDFILE" ]]; then
  OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "${OLD_PID}" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[metrics_up][ERR] worker already running: pid=${OLD_PID}" >&2
    echo "[metrics_up][ERR] use --stop first if you want to restart it" >&2
    exit 1
  fi
  rm -f "$PIDFILE"
fi

EXISTING_WORKER_PIDS=()
mapfile -t EXISTING_WORKER_PIDS < <(find_worker_pids)
if [[ "${#EXISTING_WORKER_PIDS[@]}" -gt 0 ]]; then
  echo "[metrics_up][ERR] metrics_worker already running for runtime ${RUNTIME_FILE}: ${EXISTING_WORKER_PIDS[*]}" >&2
  echo "[metrics_up][ERR] use --stop first if you want to restart it" >&2
  exit 1
fi

TOPO_DEFAULTS="$("$PYTHON_BIN" - "$TOPOLOGY_FILE" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    obj = json.load(f)
g = obj.get("globals", {})
print(g.get("gz_partition", "ucs"))
print(g.get("px4_gz_world_name", "default"))
print(g.get("tick", "200ms"))
PY
)"
DEFAULT_GZ_PARTITION="$(echo "$TOPO_DEFAULTS" | sed -n '1p')"
DEFAULT_WORLD_NAME="$(echo "$TOPO_DEFAULTS" | sed -n '2p')"
DEFAULT_TICK_RAW="$(echo "$TOPO_DEFAULTS" | sed -n '3p')"

GZ_PARTITION="${GZ_PARTITION:-$DEFAULT_GZ_PARTITION}"

if [[ -z "${GZ_IP:-}" ]]; then
  HOST_DOCKER0_IP="$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
  if [[ -z "$HOST_DOCKER0_IP" && "$DRY_RUN" -eq 1 ]]; then
    HOST_DOCKER0_IP="127.0.0.1"
  fi
  [[ -n "$HOST_DOCKER0_IP" ]] || { echo "[metrics_up][ERR] docker0 has no IPv4; cannot infer GZ_IP" >&2; exit 1; }
  export GZ_IP="$HOST_DOCKER0_IP"
fi

WORLD_NAME="${WORLD_OVERRIDE:-$DEFAULT_WORLD_NAME}"

echo "[metrics_up] topology   = $TOPOLOGY_FILE"
echo "[metrics_up] scenario   = $SCENARIO_ID"
echo "[metrics_up] world      = $WORLD_NAME"
echo "[metrics_up] GZ_PARTITION = $GZ_PARTITION"
echo "[metrics_up] GZ_IP        = $GZ_IP"
echo "[metrics_up] helper     = ${HELPER_BACKEND} (${GZ_HELPER_IMAGE})"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[metrics_up] dry-run: skipping Gazebo /clock readiness check"
else
  echo "[metrics_up] checking Gazebo clock ..."
  if ! helper_gz_topic_once; then
    echo "[metrics_up][ERR] cannot read /clock from Gazebo. Check world/GZ_PARTITION/GZ_IP." >&2
    exit 1
  fi
fi

"$PYTHON_BIN" - "$TOPOLOGY_FILE" "$WORLD_NAME" "$GZ_PARTITION" "$GZ_IP" "$RUNTIME_FILE" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

topology_file, world_name, gz_partition, gz_ip, runtime_file = sys.argv[1:]

with open(topology_file, "r", encoding="utf-8") as f:
    topo = json.load(f)

globals_ = topo.get("globals", {})
instances = topo.get("instances", [])
links = topo.get("links", [])
mesh_links = topo.get("mesh_links", [])
link_simulation = globals_.get("link_simulation", {})
scenario_id = topo.get("scenario_id", "")
if not scenario_id:
    raise SystemExit("[metrics_up][ERR] missing scenario_id")

gs_id = globals_.get("gs_id")
if not gs_id:
    raise SystemExit("[metrics_up][ERR] missing globals.gs_id")

time_file = globals_.get("time_file")
if not time_file:
    raise SystemExit("[metrics_up][ERR] missing globals.time_file")

tick_raw = str(globals_.get("tick", "200ms")).strip()

def parse_tick_ms(value: str) -> int:
    m = re.fullmatch(r"\s*([0-9]+(?:\.[0-9]+)?)\s*(ns|us|ms|s)\s*", value)
    if not m:
        raise SystemExit(f"[metrics_up][ERR] unsupported tick format: {value}")
    num = float(m.group(1))
    unit = m.group(2)
    scale = {"ns": 1e-6, "us": 1e-3, "ms": 1.0, "s": 1000.0}[unit]
    ms = int(round(num * scale))
    if ms <= 0:
      raise SystemExit(f"[metrics_up][ERR] tick must be > 0 after conversion: {value}")
    return ms

tick_ms = parse_tick_ms(tick_raw)
safe_scenario_id = re.sub(r"[^A-Za-z0-9_.-]+", "_", scenario_id)
shared_metrics_file = f"/dev/shm/ucs_mesh_metrics_{safe_scenario_id}.bin"
legacy_file_tick_ms = max(200, tick_ms)

inst_map = {}
for inst in instances:
    inst_id = inst.get("id")
    if not inst_id:
        raise SystemExit("[metrics_up][ERR] found instance without id")
    inst_map[inst_id] = inst

if mesh_links and not isinstance(mesh_links, list):
    raise SystemExit("[metrics_up][ERR] top-level mesh_links must be an array if present")
if link_simulation and not isinstance(link_simulation, dict):
    raise SystemExit("[metrics_up][ERR] globals.link_simulation must be an object if present")

gs_pose = globals_.get("gs_pose", {"x": 0.0, "y": 0.0, "z": 0.0})
if not isinstance(gs_pose, dict):
    raise SystemExit("[metrics_up][ERR] globals.gs_pose must be an object if present")
gs_fallback_pos = {
    "x": float(gs_pose.get("x", 0.0)),
    "y": float(gs_pose.get("y", 0.0)),
    "z": float(gs_pose.get("z", 0.0)),
}

resolved_links = []
seen_link_ids = set()

def pose_fallback(inst_id: str, inst: dict):
    if inst.get("type") == "ground_station":
        return dict(gs_fallback_pos)

    spawn_pose = inst.get("spawn_pose", {})
    if spawn_pose and not isinstance(spawn_pose, dict):
        raise SystemExit(f"[metrics_up][ERR] instance.spawn_pose must be an object if present: {inst_id}")
    return {
        "x": float(spawn_pose.get("x", 0.0)),
        "y": float(spawn_pose.get("y", 0.0)),
        "z": float(spawn_pose.get("z", 0.0)),
    }

def endpoint_model_and_fallback(inst_id: str):
    inst = inst_map.get(inst_id)
    if inst is None:
        raise SystemExit(f"[metrics_up][ERR] link endpoint not found in instances: {inst_id}")
    typ = inst.get("type")
    if typ == "ground_station":
        return None, pose_fallback(inst_id, inst)
    if typ != "uav":
        raise SystemExit(f"[metrics_up][ERR] link endpoint is not a supported metrics endpoint: {inst_id}")
    model_name = inst.get("model_name")
    if not model_name:
        raise SystemExit(f"[metrics_up][ERR] UAV endpoint missing model_name: {inst_id}")
    return model_name, pose_fallback(inst_id, inst)

def resolve_metrics_link(link: dict, source: str):
    if not link.get("enabled", True):
        return

    src = link.get("src")
    dst = link.get("dst")
    link_id = link.get("id")
    if not link_id:
        raise SystemExit(f"[metrics_up][ERR] {source} link missing id")
    if link_id in seen_link_ids:
        raise SystemExit(f"[metrics_up][ERR] duplicate metrics link id: {link_id}")
    if not src or not dst:
        raise SystemExit(f"[metrics_up][ERR] {source} link missing src/dst: {link_id}")

    metrics_file = link.get("metrics_file")
    if not metrics_file:
        raise SystemExit(f"[metrics_up][ERR] link missing metrics_file: {link_id}")

    src_model, src_fallback_pos = endpoint_model_and_fallback(src)
    dst_model, dst_fallback_pos = endpoint_model_and_fallback(dst)
    if src_model is None and dst_model is None:
        raise SystemExit(f"[metrics_up][ERR] link has no UAV endpoint: {link_id}")

    resolved_links.append({
        "link_id": link_id,
        "src": src,
        "dst": dst,
        "src_model_name": src_model,
        "dst_model_name": dst_model,
        "src_fallback_pos": src_fallback_pos,
        "dst_fallback_pos": dst_fallback_pos,
        "model_name": dst_model if src == gs_id else (src_model if dst == gs_id else dst_model),
        "metrics_file": metrics_file,
        "source": source,
    })
    seen_link_ids.add(link_id)

for link in links:
    resolve_metrics_link(link, "links")

for link in mesh_links:
    resolve_metrics_link(link, "mesh_links")

if not resolved_links:
    raise SystemExit("[metrics_up][ERR] no enabled metrics links resolved")

runtime = {
    "scenario_id": scenario_id,
    "world": world_name,
    "gz_partition": gz_partition,
    "gz_ip": gz_ip,
    "time_file": time_file,
    "tick_ms": tick_ms,
    "metrics_channel": "shm",
    "shared_metrics_file": shared_metrics_file,
    "legacy_file_tick_ms": legacy_file_tick_ms,
    "gs_pose": gs_fallback_pos,
    "link_simulation": link_simulation,
    "links": resolved_links,
}

for p in [runtime["time_file"], runtime["shared_metrics_file"], *[x["metrics_file"] for x in resolved_links]]:
    Path(p).parent.mkdir(parents=True, exist_ok=True)
    try:
        Path(p).unlink()
    except FileNotFoundError:
        pass

tmp = runtime_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(runtime, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, runtime_file)

print(f"[metrics_up] wrote runtime file: {runtime_file}")
print(f"[metrics_up] tick_ms={tick_ms}")
print(f"[metrics_up] metrics_channel=shm shared_metrics_file={shared_metrics_file}")
print(f"[metrics_up] legacy_file_tick_ms={legacy_file_tick_ms}")
print(f"[metrics_up] time_file={time_file}")
if link_simulation.get("enabled", False):
    obstacles = link_simulation.get("obstacles", [])
    obstacle_count = len(obstacles) if isinstance(obstacles, list) else 0
    print(f"[metrics_up] link_simulation={link_simulation.get('model', 'ns3_buildings_pathloss')} output=speed_distance_endpoint_positions obstacles={obstacle_count}")
for item in resolved_links:
    src_model = item.get("src_model_name") or "ground"
    dst_model = item.get("dst_model_name") or "ground"
    print(f"[metrics_up] link {item['link_id']}: {item['src']}({src_model}) -> {item['dst']}({dst_model}) -> {item['metrics_file']}")
PY

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "[metrics_up] dry-run runtime file:"
  cat "$RUNTIME_FILE"
  exit 0
fi

WORKER_CMD=()
case "$HELPER_BACKEND" in
  host)
    WORKER_CMD=("$PYTHON_BIN" "$WORKER_PY" --runtime-file "$RUNTIME_FILE")
    ;;
  docker)
    docker_cpuset_args=()
    mapfile -t docker_cpuset_args < <(ucs_docker_cpuset_args METRICS 0)
    WORKER_CMD=(
      docker run --rm
      --name "$METRICS_CONTAINER"
      --network host
      --user "$(id -u):$(id -g)"
      "${docker_cpuset_args[@]}"
      -v "${MESH_DIR}:${MESH_DIR}:ro"
      -v /tmp:/tmp
      -v /dev/shm:/dev/shm
      -e "GZ_PARTITION=${GZ_PARTITION}"
      -e "GZ_IP=${GZ_IP}"
      --entrypoint python3
      "$GZ_HELPER_IMAGE"
      "$WORKER_PY" --runtime-file "$RUNTIME_FILE"
    )
    ;;
esac
if [[ "$VERBOSE" -eq 1 ]]; then
  WORKER_CMD+=(--verbose)
fi
WORKER_RUN_CMD=("${WORKER_CMD[@]}")
if [[ "$HELPER_BACKEND" == "host" ]]; then
  WORKER_CPUSET="$(ucs_cpu_set METRICS 0 2>/dev/null || true)"
  if [[ -n "$WORKER_CPUSET" ]]; then
    WORKER_RUN_CMD=(taskset -c "$WORKER_CPUSET" "${WORKER_RUN_CMD[@]}")
  fi
fi

cleanup() {
  local rc=$?
  if [[ "$HELPER_BACKEND" == "docker" ]]; then
    docker rm -f "$METRICS_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -f "$PIDFILE" ]]; then
    PID="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${PID}" ]] && kill -0 "$PID" 2>/dev/null; then
      kill "$PID" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
  fi
  exit $rc
}

apply_metrics_cpuset() {
  [[ "$HELPER_BACKEND" == "docker" ]] || return 0
  local metrics_cpuset
  metrics_cpuset="$(ucs_cpu_set METRICS 0 2>/dev/null || true)"
  [[ -n "$metrics_cpuset" ]] || return 0
  if ucs_docker_wait_update_cpuset "$METRICS_CONTAINER" METRICS 0 30 0.2; then
    echo "[metrics_up] cpu affinity container ${METRICS_CONTAINER} = ${metrics_cpuset}"
  else
    echo "[metrics_up][WARN] cpu affinity container ${METRICS_CONTAINER} = skipped (docker update failed)" >&2
  fi
}

if [[ "$FOREGROUND" -eq 1 ]]; then
  trap cleanup INT TERM EXIT

  echo "[metrics_up] starting worker in foreground ..."
  "${WORKER_RUN_CMD[@]}" &
  WORKER_PID=$!
  echo "$WORKER_PID" > "$PIDFILE"
  apply_metrics_cpuset
  wait "$WORKER_PID"
else
  echo "[metrics_up] starting worker in background ..."
  if command -v setsid >/dev/null 2>&1; then
    setsid "${WORKER_RUN_CMD[@]}" >>"$LOGFILE" 2>&1 < /dev/null &
  else
    "${WORKER_RUN_CMD[@]}" >>"$LOGFILE" 2>&1 < /dev/null &
  fi
  WORKER_PID=$!
  echo "$WORKER_PID" > "$PIDFILE"
  apply_metrics_cpuset
  echo "[metrics_up] pid=${WORKER_PID}"
  echo "[metrics_up] log=${LOGFILE}"
fi
