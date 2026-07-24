#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PATH="$ROOT_DIR/dist/codex_会话管理.app"
OUTPUT_ROOT="$ROOT_DIR/dist/p0-acceptance-macos-$(date -u +%Y%m%dT%H%M%SZ)"
SAMPLE_INTERVAL=5
SAMPLE_COUNT=12

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="$2"
      shift 2
      ;;
    --output)
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --sample-interval)
      SAMPLE_INTERVAL="$2"
      shift 2
      ;;
    --sample-count)
      SAMPLE_COUNT="$2"
      shift 2
      ;;
    --soak)
      if [[ "$2" != "24h" ]]; then
        echo "Only --soak 24h is supported." >&2
        exit 1
      fi
      SAMPLE_INTERVAL=60
      SAMPLE_COUNT=1440
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! "$SAMPLE_INTERVAL" =~ ^[1-9][0-9]*$ || ! "$SAMPLE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Sample interval and count must be positive integers." >&2
  exit 1
fi

cd "$ROOT_DIR"
swift test --filter 'SessionBackupStreamerTests|IncrementalRecoveryRestorerTests|BackupAgentTests'
if [[ ! -d "$APP_PATH" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
fi
codesign --verify --deep --strict "$APP_PATH"

BINARY="$APP_PATH/Contents/MacOS/CodexSessionVault"
PID="$(pgrep -f "^$BINARY" | head -n 1 || true)"
if [[ -z "$PID" ]]; then
  open "$APP_PATH"
  for _ in {1..20}; do
    PID="$(pgrep -f "^$BINARY" | head -n 1 || true)"
    [[ -n "$PID" ]] && break
    sleep 0.5
  done
fi
if [[ -z "$PID" ]]; then
  echo "Unable to find the packaged app process." >&2
  exit 1
fi

mkdir -p "$OUTPUT_ROOT"
CSV_PATH="$OUTPUT_ROOT/resource-samples.csv"
printf 'timestamp,stage,rssBytes,cpuPercent,fileDescriptors,processCount\n' > "$CSV_PATH"
for ((index = 1; index <= SAMPLE_COUNT; index += 1)); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "Packaged app exited during resource sampling." >&2
    exit 1
  fi
  read -r rss_kib cpu_percent <<<"$(ps -o rss=,%cpu= -p "$PID")"
  fd_count="$(lsof -p "$PID" 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s,idle,%s,%s,%s,1\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$((rss_kib * 1024))" \
    "$cpu_percent" \
    "$fd_count" >> "$CSV_PATH"
  if (( index < SAMPLE_COUNT )); then sleep "$SAMPLE_INTERVAL"; fi
done

python3 - "$OUTPUT_ROOT" "$SAMPLE_COUNT" "$SAMPLE_INTERVAL" <<'PY'
import csv
import datetime
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
sample_count = int(sys.argv[2])
sample_interval = int(sys.argv[3])
with (output / "resource-samples.csv").open(newline="", encoding="utf-8") as handle:
    samples = list(csv.DictReader(handle))
rss = [int(sample["rssBytes"]) for sample in samples]
cpu = [float(sample["cpuPercent"]) for sample in samples]
report = {
    "version": 1,
    "kind": "codex-session-keeper-p0-acceptance",
    "platform": "darwin",
    "completedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "automatedSwiftRegression": "pass",
    "resourceSampling": {
        "sampleCount": sample_count,
        "sampleIntervalSeconds": sample_interval,
        "peakRssBytes": max(rss),
        "rssGrowthBytes": rss[-1] - rss[0],
        "averageCpuPercent": sum(cpu) / len(cpu),
    },
    "manualGates": {
        "threeRealNasUploads": "pending",
        "largeRealNasRestore": "pending",
        "loginRestart": "pending",
        "silentBackgroundLaunch": "pending",
        "dockReopen": "pending",
        "explicitQuit": "pending",
        "wakeCatchup": "pending",
        "actualNasReconnect": "pending",
        "twentyFourHourSoak": "pending" if sample_count < 1440 or sample_interval < 60 else "measured-needs-review",
    },
    "automatedPass": True,
    "releaseReady": False,
    "contentLogged": False,
}
(output / "p0-acceptance-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(output / "summary.txt").write_text(
    "Codex Session Keeper macOS P0 验收摘要\n\n"
    "Swift 回归与应用资源采样已完成。\n"
    "真实 NAS 三次上传、287 MiB 恢复、登录启动、后台常驻、唤醒、重连和 24 小时门槛仍待人工验收。\n"
    "当前不得标记为正式发布就绪。报告不记录会话正文。\n",
    encoding="utf-8",
)
PY

echo "$OUTPUT_ROOT/p0-acceptance-report.json"
echo "$CSV_PATH"
echo "$OUTPUT_ROOT/summary.txt"
