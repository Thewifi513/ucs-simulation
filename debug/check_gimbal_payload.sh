#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
TOPOLOGY_FILE="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"
VERIFY_LIVE=0

usage() {
  cat <<'USAGE'
Usage:
  check_gimbal_payload.sh [--topology FILE] [--verify-live]

Checks that the BMv2 topology is configured to spawn the PX4/Gazebo
x500_gimbal payload model and prints the expected camera/gimbal topics.

Options:
  --topology FILE  Topology JSON to inspect.
  --verify-live    Also compare expected camera topics with `gz topic -l`.
USAGE
}

die() {
  echo "[gimbal-check][ERR] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || die "--topology requires a file"
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --verify-live)
      VERIFY_LIVE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -f "$TOPOLOGY_FILE" ]] || die "topology file not found: $TOPOLOGY_FILE"

EXPECTED_TOPICS_FILE="$(mktemp /tmp/ucs_bmv2_gimbal_topics.XXXXXX)"
cleanup() {
  rm -f "$EXPECTED_TOPICS_FILE"
}
trap cleanup EXIT

"$PYTHON_BIN" - "$TOPOLOGY_FILE" "$EXPECTED_TOPICS_FILE" <<'PY'
import json
import sys
from pathlib import Path

topology_path = Path(sys.argv[1])
topics_path = Path(sys.argv[2])

with topology_path.open("r", encoding="utf-8") as handle:
    topo = json.load(handle)

globals_ = topo.get("globals", {})
payload = globals_.get("payload", {})
flows = globals_.get("business_flows", {})
world = globals_.get("px4_gz_world_name", "")
px4_model = globals_.get("px4_sim_model_name", "")
payload_model = payload.get("gazebo_model", "x500_gimbal")
camera_link = payload.get("camera_link", "camera_link")
camera_sensor = payload.get("camera_sensor", "camera")

if px4_model != "gz_x500_gimbal":
    raise SystemExit(
        f"[gimbal-check][ERR] globals.px4_sim_model_name={px4_model!r}, expected 'gz_x500_gimbal'"
    )

uavs = [item for item in topo.get("instances", []) if item.get("type") == "uav"]
if not uavs:
    raise SystemExit("[gimbal-check][ERR] no UAV instances in topology")

expected_topics = []
print(f"[gimbal-check] topology={topology_path}")
print(f"[gimbal-check] world={world} px4_model={px4_model} payload={payload.get('profile', '')}")

control = flows.get("control", {})
video = flows.get("video", {})
mavsdk = control.get("mavsdk", {}) if isinstance(control, dict) else {}
print(
    "[gimbal-check] control_flow="
    f"enabled={bool(control.get('enabled', False))} "
    f"ports={control.get('port_source', 'instances[].qgc_port')} "
    f"mavsdk={mavsdk.get('mavsdk_url_rule', 'udpin://0.0.0.0:<gs_remote_port>')} "
    f"class={control.get('traffic_class', 'control')}"
)
print(
    "[gimbal-check] video_flow="
    f"enabled={bool(video.get('enabled', False))} "
    f"port_rule={video.get('port_rule', '5600 + instances[].idx')} "
    f"class={video.get('traffic_class', 'video')} "
    f"encoding={video.get('encoding', 'rtp_h264')} "
    f"source={video.get('source', payload_model + ' camera')}"
)

for inst in sorted(uavs, key=lambda item: int(item.get("idx", 0))):
    idx = int(inst.get("idx", 0))
    uav_id = inst.get("id", f"uav{idx:02d}")
    model_name = str(inst.get("model_name", ""))
    expected_model = f"{payload_model}_{idx:02d}"
    if model_name != expected_model:
        raise SystemExit(
            f"[gimbal-check][ERR] {uav_id} model_name={model_name!r}, expected {expected_model!r}"
        )
    camera_topic = (
        f"/world/{world}/model/{model_name}/link/{camera_link}/sensor/{camera_sensor}/image"
    )
    video_port = int(video.get("port_base", 5600)) + idx
    qgc_port = int(inst.get("qgc_port", 0))
    mavsdk_remote_port = int(inst.get("mavsdk_remote_port", int(mavsdk.get("gs_remote_port_base", 14600)) + idx))
    mavsdk_local_port = int(inst.get("mavsdk_local_port", int(mavsdk.get("uav_local_port_base", 18600)) + idx))
    expected_topics.append(camera_topic)
    print(
        f"[gimbal-check] {uav_id}: model={model_name} "
        f"qgc_udp={qgc_port} mavsdk_udp={mavsdk_local_port}->:{mavsdk_remote_port} "
        f"video_udp={video_port} camera_topic={camera_topic}"
    )

topics_path.write_text("\n".join(expected_topics) + "\n", encoding="utf-8")
PY

if [[ "$VERIFY_LIVE" -eq 0 ]]; then
  exit 0
fi

command -v gz >/dev/null 2>&1 || die "gz command not found; cannot verify live topics"

GZ_PARTITION="$(
"$PYTHON_BIN" - "$TOPOLOGY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    topo = json.load(f)
print(topo.get("globals", {}).get("gz_partition", "ucs"))
PY
)"
if [[ -z "${GZ_IP:-}" ]]; then
  command -v ip >/dev/null 2>&1 || die "ip command not found; cannot infer GZ_IP"
  command -v awk >/dev/null 2>&1 || die "awk command not found; cannot infer GZ_IP"
  command -v cut >/dev/null 2>&1 || die "cut command not found; cannot infer GZ_IP"
  GZ_IP="$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1 || true)"
fi
[[ -n "${GZ_IP:-}" ]] || die "GZ_IP is empty and docker0 has no IPv4 address"

TOPIC_LIST="$(env GZ_PARTITION="$GZ_PARTITION" GZ_IP="$GZ_IP" gz topic -l 2>/dev/null || true)"
if [[ -z "$TOPIC_LIST" ]]; then
  die "no Gazebo topics visible; is the world running? GZ_PARTITION=${GZ_PARTITION} GZ_IP=${GZ_IP}"
fi

missing=0
while IFS= read -r topic; do
  [[ -n "$topic" ]] || continue
  if grep -Fx -- "$topic" <<<"$TOPIC_LIST" >/dev/null; then
    echo "[gimbal-check] live topic ok: $topic"
  else
    echo "[gimbal-check][MISSING] $topic" >&2
    missing=1
  fi
done < "$EXPECTED_TOPICS_FILE"

if [[ "$missing" -ne 0 ]]; then
  die "one or more expected camera topics are missing"
fi

echo "[gimbal-check] live camera topics verified"
