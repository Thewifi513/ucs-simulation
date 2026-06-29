#!/usr/bin/env bash
set -Eeuo pipefail

# UCS mesh PX4 launcher (single UAV instance, parameterized)
# 只负责启动单架 UAV 的容器/PX4，不启动 world。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"

WORLD_SDF="${WORLD_SDF:-$PX4_DIR/Tools/simulation/gz/worlds/default.sdf}"
PROFILE_SH="${MESH_DIR}/fleet/uav_profile.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"
TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
PID_DIR="${PID_DIR:-}"
NO_TERMINAL="${UCS_MESH_NO_TERMINALS:-0}"
UCS_MESH_PX4_ULOG="${UCS_MESH_PX4_ULOG:-0}"

IDX_INPUT="${IDX:-1}"

usage() {
  cat <<EOF2
Usage: $(basename "$0") [idx] [--idx N] [--topology FILE] [--no-terminal] [--help]

idx             Optional positional UAV index, e.g. 1 / 2 / 3 ...
--idx N         Explicit UAV index.
--topology FILE JSON topology file.
--no-terminal   Start PX4 in the background and write a log under PID_DIR/cache.
--help          Show this help.

Examples:
  $(basename "$0")
  $(basename "$0") 2
  $(basename "$0") --idx 2
  $(basename "$0") --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --idx 2
EOF2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[ERR] --topology requires a path"; exit 1; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --idx)
      [[ $# -ge 2 ]] || { echo "[ERR] --idx requires a value"; exit 1; }
      IDX_INPUT="$2"
      shift 2
      ;;
    --no-terminal)
      NO_TERMINAL=1
      shift
      ;;
    --terminal)
      NO_TERMINAL=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        IDX_INPUT="$1"
        shift
      else
        echo "[ERR] Unknown argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[ERR] '$1' not found."; exit 1; }; }
need_cmd ip
need_cmd awk
need_cmd cut
need_cmd docker
need_cmd "$PYTHON_BIN"

[[ -f "$PROFILE_SH" ]] || { echo "[ERR] uav_profile.sh not found: $PROFILE_SH"; exit 1; }
[[ -f "$TOPOLOGY_FILE" ]] || { echo "[ERR] topology file not found: $TOPOLOGY_FILE"; exit 1; }

TOPOLOGY_FILE="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TOPOLOGY_FILE")"

# shellcheck disable=SC1090
source "$PROFILE_SH" --topology "$TOPOLOGY_FILE" --idx "$IDX_INPUT"

if command -v gnome-terminal >/dev/null 2>&1; then
  TERMINAL="gnome-terminal"
elif command -v x-terminal-emulator >/dev/null 2>&1; then
  TERMINAL="x-terminal-emulator"
else
  echo "[ERR] No supported terminal launcher found (need gnome-terminal or x-terminal-emulator)."
  exit 1
fi

open_terminal() {
  local title="$1"
  local script_path="$2"
  local pidfile="${3:-}"
  local pid_prefix=""

  if [[ -n "$pidfile" ]]; then
    mkdir -p "$(dirname -- "$pidfile")"
    pid_prefix="echo \$\$ > '$pidfile'; "
  fi

  local cmd="${pid_prefix}source '$script_path'; rc=\$?; echo; echo \"[$title] exit \$rc\"; exec bash --noprofile --norc -i"

  if [[ "$TERMINAL" == "gnome-terminal" ]]; then
    gnome-terminal --title="$title" -- bash --noprofile --norc -lc "$cmd"
  else
    x-terminal-emulator -T "$title" -e bash --noprofile --norc -lc "$cmd"
  fi
}

start_background() {
  local title="$1"
  local script_path="$2"
  local pidfile="${3:-}"
  local logfile="${4:-}"

  if [[ -z "$logfile" ]]; then
    logfile="$CACHE_DIR/${title}.log"
  fi
  mkdir -p "$(dirname -- "$logfile")"

  UCS_MESH_PX4_DOCKER_TTY=0 nohup "$script_path" >"$logfile" 2>&1 &
  local pid="$!"
  if [[ -n "$pidfile" ]]; then
    mkdir -p "$(dirname -- "$pidfile")"
    printf '%s\n' "$pid" > "$pidfile"
  fi
  echo "[OK] Started ${title} in background pid=${pid}"
  echo "     log: ${logfile}"
}

model_instance_name() {
  printf '%s' "${PX4_MODEL_INSTANCE}"
}

export TOPOLOGY_FILE SCENARIO_ID
export PX4_DIR GZ_ENV_SH WORLD_SDF PX4_GZ_MODELS PX4_GZ_WORLDS
export GZ_PARTITION_NAME PX4_GZ_WORLD_NAME PX4_SIM_MODEL_NAME
export IDX UAV_NUM UAV_ID UAV_NAME UAV_CONTAINER CONTAINER_NAME
export PX4_INSTANCE PX4_MODEL_INSTANCE
export MAV_SYS_ID UXRCE_DDS_KEY
export GS_IP TAP_LEFT UAV_IP UAV_IP_ADDR
export QGC_PORT QGC_TARGET QGC_RATE_BYTES_PER_SEC
export MAVSDK_CONTROL_ENABLED MAVSDK_LOCAL_PORT MAVSDK_REMOTE_PORT MAVSDK_REMOTE_IP MAVSDK_URL
export MAVSDK_RATE_BYTES_PER_SEC PX4_DEFAULT_OFFBOARD_RATE_BYTES_PER_SEC
export UCS_BMV2_DISABLE_GCS_FAILSAFE UCS_BMV2_NAV_DLL_ACT UCS_BMV2_COM_DLL_EXCEPT UCS_BMV2_COM_DL_LOSS_T
export TAP_RIGHT BRIDGE VETH_HOST VETH_CT
export NS3_METRICS_FILE NS3_TIME_FILE
export SPAWN_X SPAWN_Y SPAWN_Z SPAWN_ROLL SPAWN_PITCH SPAWN_YAW PX4_GZ_MODEL_POSE
export PID_DIR NO_TERMINAL UCS_MESH_PX4_ULOG

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ucs-mesh"
mkdir -p "$CACHE_DIR"
[[ -n "$PID_DIR" ]] && mkdir -p "$PID_DIR"

C_SH="$CACHE_DIR/px4-C-${UAV_NAME}.sh"

cat >"$C_SH" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail

model_instance_name() {
  printf '%s' "${PX4_MODEL_INSTANCE}"
}

if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "[C][ERR] container not found: $CONTAINER_NAME"
  exit 1
fi

echo "[C] docker start $CONTAINER_NAME"
docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "[C] patch container runtime for $(model_instance_name) + --instance ..."
docker exec -i "$CONTAINER_NAME" python3 - <<'PY'
import re
from pathlib import Path

p = Path('/px4/etc/init.d-posix/px4-rc.gzsim')
s = p.read_text()

needle = '# Start gz_bridge - either spawn a model or connect to existing one'
if 'export px4_instance' not in s and needle in s:
    s = s.replace(
        needle,
        'export px4_instance\n\n# Start gz_bridge - either spawn a model or connect to existing one',
        1
    )

desired = 'MODEL_NAME_INSTANCE="${MODEL_NAME}_$(printf "%02d" "$((px4_instance + 1))")"'
candidates = [
    'MODEL_NAME_INSTANCE="${MODEL_NAME}_${px4_instance}"',
    'MODEL_NAME_INSTANCE="${MODEL_NAME}_$(printf "%02d" "${px4_instance}")"',
    desired,
]
for old in candidates:
    if old in s and old != desired:
        s = s.replace(old, desired, 1)
        break

p.write_text(s)

wrapper = Path('/usr/local/bin/gz_bridge')
wrapper.write_text(
    '#!/bin/sh\n'
    'set -eu\n'
    '\n'
    'INSTANCE="${PX4_INSTANCE:-${px4_instance:-0}}"\n'
    'echo "[gz_bridge wrapper] INSTANCE=$INSTANCE args:$*" >> /tmp/gz_bridge.wrapper.log\n'
    '\n'
    'exec /px4/bin/px4-gz_bridge --instance "$INSTANCE" "$@"\n'
)
wrapper.chmod(0o755)

mavlink = Path('/px4/etc/init.d-posix/px4-rc.mavlink')
if mavlink.exists():
    ms = mavlink.read_text()
    marker = '# UCS BMv2 dedicated MAVSDK control link'
    ms = re.sub(
        r'mavlink start -x -u \$udp_gcs_port_local -r \S+ -f',
        'mavlink start -x -u $udp_gcs_port_local -r ${UCS_BMV2_QGC_RATE_BPS:-20000} -f',
        ms,
        count=1,
    )
    ms = re.sub(
        r'mavlink start -x -u \$udp_offboard_port_local -r \S+ -f -m onboard -o \$udp_offboard_port_remote',
        'mavlink start -x -u $udp_offboard_port_local -r ${UCS_BMV2_OFFBOARD_RATE_BPS:-20000} -f -m onboard -o $udp_offboard_port_remote',
        ms,
        count=1,
    )
    block = (
        f'{marker}\n'
        'if [ "${UCS_BMV2_MAVSDK_ENABLED:-0}" = "1" ] && '
        '[ -n "${UCS_BMV2_MAVSDK_LOCAL_PORT:-}" ] && '
        '[ -n "${UCS_BMV2_MAVSDK_REMOTE_PORT:-}" ] && '
        '[ -n "${UCS_BMV2_MAVSDK_REMOTE_IP:-}" ]; then\n'
        '\tmavlink start -x -u "$UCS_BMV2_MAVSDK_LOCAL_PORT" '
        '-r "${UCS_BMV2_MAVSDK_RATE_BPS:-20000}" -f -m onboard '
        '-t "$UCS_BMV2_MAVSDK_REMOTE_IP" -o "$UCS_BMV2_MAVSDK_REMOTE_PORT" -p\n'
        'fi\n'
    )
    failsafe_marker = '# UCS BMv2 datalink failsafe policy'
    failsafe_block = (
        f'{failsafe_marker}\n'
        'if [ "${UCS_BMV2_DISABLE_GCS_FAILSAFE:-1}" = "1" ]; then\n'
        '\tparam set NAV_DLL_ACT "${UCS_BMV2_NAV_DLL_ACT:-0}"\n'
        '\tparam set COM_DLL_EXCEPT "${UCS_BMV2_COM_DLL_EXCEPT:-4}"\n'
        '\tparam set COM_DL_LOSS_T "${UCS_BMV2_COM_DL_LOSS_T:-30}"\n'
        'fi\n'
        'param set COM_OF_LOSS_T "${UCS_BMV2_COM_OF_LOSS_T:-5}"\n'
        'param set COM_OBL_RC_ACT "${UCS_BMV2_COM_OBL_RC_ACT:-5}"\n'
    )
    ms = re.sub(
        rf'\n*{re.escape(failsafe_marker)}\n.*?(?=\n# GCS link|\Z)',
        '\n',
        ms,
        count=0,
        flags=re.S,
    )
    if marker in ms:
        ms = re.sub(
            rf'{re.escape(marker)}\nif \[ "\$\{{UCS_BMV2_MAVSDK_ENABLED:-0\}}" = "1" \].*?fi\n',
            block,
            ms,
            count=1,
            flags=re.S,
        )
    else:
        ms = ms.rstrip() + '\n\n' + block
    if '# GCS link' in ms:
        ms = ms.replace('# GCS link', failsafe_block + '\n# GCS link', 1)
    else:
        ms = failsafe_block + '\n' + ms.lstrip()
    mavlink.write_text(ms)
    print('[patched]', mavlink)

rc_logging = Path('/px4/etc/init.d/rc.logging')
if rc_logging.exists():
    rs = rc_logging.read_text()
    marker = '# UCS BMv2 optional PX4 ULog gate'
    if marker not in rs:
        old = (
            '#\n'
            '# Start logger if any logging backend is enabled\n'
            '#\n'
            'if ! param compare SDLOG_BACKEND 0\n'
            'then\n'
            '\tlogger start -b ${LOGGER_BUF} -t ${LOGGER_ARGS}\n'
            'fi\n'
        )
        new = (
            '#\n'
            '# Start logger if any logging backend is enabled\n'
            '#\n'
            f'{marker}\n'
            'if [ "${UCS_MESH_PX4_ULOG:-0}" = "1" ]\n'
            'then\n'
            '\tif ! param compare SDLOG_BACKEND 0\n'
            '\tthen\n'
            '\t\tlogger start -b ${LOGGER_BUF} -t ${LOGGER_ARGS}\n'
            '\tfi\n'
            'else\n'
            '\techo "[UCS] PX4 ULog disabled; set UCS_MESH_PX4_ULOG=1 to enable"\n'
            'fi\n'
        )
        if old in rs:
            rs = rs.replace(old, new, 1)
        else:
            raise SystemExit(f"[C][ERR] cannot patch logger gate in {rc_logging}")
        rc_logging.write_text(rs)
    print('[patched]', rc_logging)

print('[patched]', p)
print('[patched]', wrapper)
PY

echo "[C] container IP:"
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME" | sed 's/^/[C] /'

echo "[C] Enter container and run PX4 rcS (Standalone + Gazebo) ..."
echo "[C] TOPOLOGY_FILE=$TOPOLOGY_FILE"
echo "[C] SCENARIO_ID=$SCENARIO_ID"
echo "[C] UAV_NAME=$UAV_NAME"
echo "[C] UAV_CONTAINER=$UAV_CONTAINER"
echo "[C] PX4_INSTANCE=$PX4_INSTANCE"
echo "[C] MAV_SYS_ID=$MAV_SYS_ID"
echo "[C] UXRCE_DDS_KEY=$UXRCE_DDS_KEY"
echo "[C] expected model instance: $(model_instance_name)"
echo "[C] PX4_GZ_MODEL_POSE=$PX4_GZ_MODEL_POSE"
echo "[C] QGC target: $QGC_TARGET"
echo "[C] MAVSDK control: enabled=${MAVSDK_CONTROL_ENABLED:-0} local=${MAVSDK_LOCAL_PORT:-} remote=${MAVSDK_REMOTE_IP:-}:${MAVSDK_REMOTE_PORT:-} url=${MAVSDK_URL:-}"
echo "[C] MAVLink rates: qgc=${QGC_RATE_BYTES_PER_SEC:-20000} offboard=${PX4_DEFAULT_OFFBOARD_RATE_BYTES_PER_SEC:-20000} mavsdk=${MAVSDK_RATE_BYTES_PER_SEC:-20000} B/s"
echo "[C] GCS datalink failsafe policy: disable=${UCS_BMV2_DISABLE_GCS_FAILSAFE:-1} NAV_DLL_ACT=${UCS_BMV2_NAV_DLL_ACT:-0} COM_DLL_EXCEPT=${UCS_BMV2_COM_DLL_EXCEPT:-4} COM_DL_LOSS_T=${UCS_BMV2_COM_DL_LOSS_T:-30}"
echo "[C] Offboard failsafe policy: COM_OF_LOSS_T=${UCS_BMV2_COM_OF_LOSS_T:-5} COM_OBL_RC_ACT=${UCS_BMV2_COM_OBL_RC_ACT:-5}"

docker_env_args=(
  -e GZ_PARTITION="$GZ_PARTITION_NAME"
  -e PX4_GZ_STANDALONE=1
  -e PX4_GZ_WORLD="$PX4_GZ_WORLD_NAME"
  -e PX4_GZ_MODELS="$PX4_GZ_MODELS"
  -e PX4_GZ_WORLDS="$PX4_GZ_WORLDS"
  -e PX4_SIM_MODEL="$PX4_SIM_MODEL_NAME"
  -e PX4_INSTANCE="$PX4_INSTANCE"
  -e PX4_GZ_MODEL_POSE="$PX4_GZ_MODEL_POSE"
  -e UCS_BMV2_MAVSDK_ENABLED="${MAVSDK_CONTROL_ENABLED:-0}"
  -e UCS_BMV2_MAVSDK_LOCAL_PORT="${MAVSDK_LOCAL_PORT:-}"
  -e UCS_BMV2_MAVSDK_REMOTE_PORT="${MAVSDK_REMOTE_PORT:-}"
  -e UCS_BMV2_MAVSDK_REMOTE_IP="${MAVSDK_REMOTE_IP:-}"
  -e UCS_BMV2_MAVSDK_URL="${MAVSDK_URL:-}"
  -e UCS_BMV2_QGC_RATE_BPS="${QGC_RATE_BYTES_PER_SEC:-20000}"
  -e UCS_BMV2_OFFBOARD_RATE_BPS="${PX4_DEFAULT_OFFBOARD_RATE_BYTES_PER_SEC:-20000}"
  -e UCS_BMV2_MAVSDK_RATE_BPS="${MAVSDK_RATE_BYTES_PER_SEC:-20000}"
  -e UCS_BMV2_DISABLE_GCS_FAILSAFE="${UCS_BMV2_DISABLE_GCS_FAILSAFE:-1}"
  -e UCS_BMV2_NAV_DLL_ACT="${UCS_BMV2_NAV_DLL_ACT:-0}"
  -e UCS_BMV2_COM_DLL_EXCEPT="${UCS_BMV2_COM_DLL_EXCEPT:-4}"
  -e UCS_BMV2_COM_DL_LOSS_T="${UCS_BMV2_COM_DL_LOSS_T:-30}"
  -e UCS_BMV2_COM_OF_LOSS_T="${UCS_BMV2_COM_OF_LOSS_T:-5}"
  -e UCS_BMV2_COM_OBL_RC_ACT="${UCS_BMV2_COM_OBL_RC_ACT:-5}"
  -e UCS_MESH_PX4_ULOG="${UCS_MESH_PX4_ULOG:-0}"
)

px4_attached_script='
set -Eeuo pipefail

CONT_IP=$(ip -4 addr show eth0 | awk "/inet /{print \$2}" | cut -d/ -f1)
if [[ -z "$CONT_IP" ]]; then
  echo "[C][ERR] Cannot get eth0 IPv4 inside container."
  ip -br -4 addr || true
  exit 1
fi

export GZ_IP="$CONT_IP"

env | grep -E "GZ_PARTITION|GZ_IP|PX4_GZ_STANDALONE|PX4_GZ_WORLD|PX4_SIM_MODEL|PX4_INSTANCE|PX4_GZ_MODEL_POSE" | sort
env | grep -E "UCS_BMV2" | sort || true

cd /px4
if [[ "${UCS_MESH_PX4_ULOG:-0}" != "1" ]]; then
  rm -rf /px4/log/*
  mkdir -p /px4/log
fi
exec ./bin/px4 -i "$PX4_INSTANCE" -s etc/init.d-posix/rcS
'

px4_detached_script='
set -Eeuo pipefail

CONT_IP=$(ip -4 addr show eth0 | awk "/inet /{print \$2}" | cut -d/ -f1)
if [[ -z "$CONT_IP" ]]; then
  echo "[C][ERR] Cannot get eth0 IPv4 inside container."
  ip -br -4 addr || true
  exit 1
fi

export GZ_IP="$CONT_IP"
log_file="/tmp/ucs-mesh-px4-${PX4_INSTANCE}.log"
pid_file="/tmp/ucs-mesh-px4-${PX4_INSTANCE}.pid"
rm -f "$pid_file"
exec >"$log_file" 2>&1

echo "[C] detached PX4 start"
env | grep -E "GZ_PARTITION|GZ_IP|PX4_GZ_STANDALONE|PX4_GZ_WORLD|PX4_SIM_MODEL|PX4_INSTANCE|PX4_GZ_MODEL_POSE" | sort
env | grep -E "UCS_BMV2" | sort || true

cd /px4
if [[ "${UCS_MESH_PX4_ULOG:-0}" != "1" ]]; then
  rm -rf /px4/log/*
  mkdir -p /px4/log
fi
echo $$ > "$pid_file"
exec ./bin/px4 -d -i "$PX4_INSTANCE" -s etc/init.d-posix/rcS
'

if [[ "${NO_TERMINAL:-0}" -eq 1 && "${UCS_MESH_PX4_DOCKER_DETACHED:-1}" != "0" ]]; then
  container_log="/tmp/ucs-mesh-px4-${PX4_INSTANCE}.log"
  container_pid="/tmp/ucs-mesh-px4-${PX4_INSTANCE}.pid"
  echo "[C] PX4 no-terminal mode: detached docker exec."
  echo "[C] Container log: ${container_log}"
  docker exec -d "${docker_env_args[@]}" "$CONTAINER_NAME" bash -lc "$px4_detached_script"

  verify_script="pid_file='${container_pid}'; [[ -s \"\$pid_file\" ]] && pid=\$(cat \"\$pid_file\") && kill -0 \"\$pid\" 2>/dev/null"
  for _attempt in {1..25}; do
    if docker exec "$CONTAINER_NAME" bash -lc "$verify_script" >/dev/null 2>&1; then
      echo "[C] PX4 detached process is running."
      exit 0
    fi
    sleep 0.2
  done

  echo "[C][ERR] PX4 detached process did not become visible."
  docker exec "$CONTAINER_NAME" bash -lc "tail -n 80 '${container_log}' 2>/dev/null || true" || true
  exit 1
else
  docker_exec_args=(-i)
  if [[ -t 0 && "${UCS_MESH_PX4_DOCKER_TTY:-1}" != "0" ]]; then
    docker_exec_args=(-it)
  fi
  if [[ "${NO_TERMINAL:-0}" -eq 1 ]]; then
    echo "[C] PX4 interactive output is suppressed in no-terminal mode."
  fi
  docker exec "${docker_exec_args[@]}" "${docker_env_args[@]}" "$CONTAINER_NAME" bash -lc "$px4_attached_script"
fi
EOF2
chmod +x "$C_SH"

PX4_PIDFILE=""
PX4_LOGFILE=""
if [[ -n "$PID_DIR" ]]; then
  PX4_PIDFILE="${PID_DIR}/px4-${UAV_NAME}.pid"
  PX4_LOGFILE="${PID_DIR}/px4-${UAV_NAME}.log"
fi

if [[ "$NO_TERMINAL" -eq 1 ]]; then
  start_background "mesh-px4-${UAV_NAME}" "$C_SH" "$PX4_PIDFILE" "$PX4_LOGFILE"
else
  open_terminal "mesh-px4-${UAV_NAME}" "$C_SH" "$PX4_PIDFILE"
fi

echo "[OK] Launched helper terminal(s)."
echo "     C: mesh-px4-${UAV_NAME}"
echo "     Helper scripts: $CACHE_DIR"
echo "     Topology file: $TOPOLOGY_FILE"
echo "     Scenario: $SCENARIO_ID"
echo "     IDX=$IDX"
echo "     UAV_NAME=$UAV_NAME"
echo "     UAV_CONTAINER=$UAV_CONTAINER"
echo "     PX4_INSTANCE=$PX4_INSTANCE"
echo "     Expected model: $(model_instance_name)"
echo "     PX4_GZ_MODEL_POSE=$PX4_GZ_MODEL_POSE"
echo "     PX4_GZ_MODELS=$PX4_GZ_MODELS"
echo "     QGC target: $QGC_TARGET"
echo "     MAVSDK control: enabled=${MAVSDK_CONTROL_ENABLED:-0} local=${MAVSDK_LOCAL_PORT:-} remote=${MAVSDK_REMOTE_IP:-}:${MAVSDK_REMOTE_PORT:-} url=${MAVSDK_URL:-}"
if [[ -n "$PID_DIR" ]]; then
  echo "     PID_DIR: $PID_DIR"
fi
