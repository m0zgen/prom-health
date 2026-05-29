#!/usr/bin/env bash
set -euo pipefail

PROM_URL="http://127.0.0.1:9090"
SERVICE_NAME="prometheus"
SHOW_ALL=0

usage() {
  cat <<EOF
Usage:
  $0 [options]

Options:
  -u, --url URL          Prometheus URL. Default: http://127.0.0.1:9090
  -s, --service NAME     systemd service name. Default: prometheus
  -a, --all              Show all targets, not only unhealthy
  -h, --help             Show help

Examples:
  $0
  $0 -u http://127.0.0.1:9090
  $0 -s prompp
  $0 --all
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)
      PROM_URL="${2:-}"
      shift 2
      ;;
    -s|--service)
      SERVICE_NAME="${2:-}"
      shift 2
      ;;
    -a|--all)
      SHOW_ALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1"
    exit 1
  fi
}

human_bytes() {
  local bytes="${1:-0}"

  awk -v b="$bytes" '
    function human(x) {
      split("B KiB MiB GiB TiB", u)
      i=1
      while (x >= 1024 && i < 5) {
        x /= 1024
        i++
      }
      return sprintf("%.2f %s", x, u[i])
    }
    BEGIN { print human(b) }
  '
}

need_cmd curl
need_cmd jq
need_cmd awk

echo "=== Prometheus Health Check ==="
echo "URL:     $PROM_URL"
echo "Service: $SERVICE_NAME"
echo

# ------------------------------------------------------------
# API health
# ------------------------------------------------------------

if ! curl -fsS "$PROM_URL/-/ready" >/dev/null 2>&1; then
  echo "READY:   ❌ not ready or unreachable"
else
  echo "READY:   ✅ ready"
fi

if ! curl -fsS "$PROM_URL/-/healthy" >/dev/null 2>&1; then
  echo "HEALTHY: ❌ not healthy or unreachable"
else
  echo "HEALTHY: ✅ healthy"
fi

echo

# ------------------------------------------------------------
# Runtime info
# ------------------------------------------------------------

runtime_json="$(curl -fsS "$PROM_URL/api/v1/status/runtimeinfo" 2>/dev/null || true)"

if [[ -n "$runtime_json" ]] && echo "$runtime_json" | jq -e '.status == "success"' >/dev/null 2>&1; then
  echo "=== Runtime ==="
  echo "$runtime_json" | jq -r '
    .data |
    "Start time:     \(.startTime)",
    "CWD:            \(.CWD)",
    "Goroutines:     \(.goroutineCount)",
    "GOMAXPROCS:     \(.GOMAXPROCS)",
    "GOGC:           \(.GOGC)",
    "GODEBUG:        \(.GODEBUG)"
  '
  echo
fi

# ------------------------------------------------------------
# Process memory
# ------------------------------------------------------------

echo "=== Process Memory ==="

pid=""

if command -v systemctl >/dev/null 2>&1; then
  pid="$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || true)"
fi

if [[ -z "$pid" || "$pid" == "0" ]]; then
  pid="$(pgrep -xo prometheus || true)"
fi

if [[ -z "$pid" || "$pid" == "0" ]]; then
  pid="$(pgrep -xo prompp || true)"
fi

if [[ -n "$pid" && "$pid" != "0" && -r "/proc/$pid/status" ]]; then
  rss_kb="$(awk '/VmRSS:/ {print $2}' "/proc/$pid/status")"
  vms_kb="$(awk '/VmSize:/ {print $2}' "/proc/$pid/status")"
  threads="$(awk '/Threads:/ {print $2}' "/proc/$pid/status")"

  rss_bytes=$((rss_kb * 1024))
  vms_bytes=$((vms_kb * 1024))

  echo "PID:            $pid"
  echo "RSS memory:     $(human_bytes "$rss_bytes")"
  echo "Virtual memory: $(human_bytes "$vms_bytes")"
  echo "Threads:        $threads"
else
  echo "Process not found via systemd/pgrep or /proc not readable."
fi

echo

# ------------------------------------------------------------
# Prometheus self metrics memory, if available
# ------------------------------------------------------------

echo "=== Self Metrics ==="

resident_json="$(curl -fsS --get "$PROM_URL/api/v1/query" \
  --data-urlencode 'query=process_resident_memory_bytes' 2>/dev/null || true)"

go_alloc_json="$(curl -fsS --get "$PROM_URL/api/v1/query" \
  --data-urlencode 'query=go_memstats_alloc_bytes' 2>/dev/null || true)"

go_sys_json="$(curl -fsS --get "$PROM_URL/api/v1/query" \
  --data-urlencode 'query=go_memstats_sys_bytes' 2>/dev/null || true)"

print_metric_bytes() {
  local name="$1"
  local json="$2"

  local val
  val="$(echo "$json" | jq -r '
    if .status == "success" and (.data.result | length) > 0
    then .data.result[0].value[1]
    else empty
    end
  ' 2>/dev/null || true)"

  if [[ -n "$val" ]]; then
    printf "%-24s %s\n" "$name:" "$(human_bytes "${val%.*}")"
  else
    printf "%-24s %s\n" "$name:" "n/a"
  fi
}

print_metric_bytes "process RSS metric" "$resident_json"
print_metric_bytes "Go alloc" "$go_alloc_json"
print_metric_bytes "Go sys" "$go_sys_json"

echo

# ------------------------------------------------------------
# TSDB status
# ------------------------------------------------------------

tsdb_json="$(curl -fsS "$PROM_URL/api/v1/status/tsdb" 2>/dev/null || true)"

if [[ -n "$tsdb_json" ]] && echo "$tsdb_json" | jq -e '.status == "success"' >/dev/null 2>&1; then
  echo "=== TSDB ==="
  echo "$tsdb_json" | jq -r '
    .data.headStats |
    "Series:          \(.numSeries)",
    "Label pairs:     \(.numLabelPairs)",
    "Chunks:          \(.chunkCount)",
    "Min time:        \(.minTime)",
    "Max time:        \(.maxTime)"
  '
  echo
fi

# ------------------------------------------------------------
# Targets health
# ------------------------------------------------------------

targets_json="$(curl -fsS "$PROM_URL/api/v1/targets" 2>/dev/null || true)"

if [[ -z "$targets_json" ]]; then
  echo "ERROR: cannot fetch targets from $PROM_URL/api/v1/targets"
  exit 2
fi

if ! echo "$targets_json" | jq -e '.status == "success"' >/dev/null 2>&1; then
  echo "ERROR: Prometheus API returned non-success status"
  echo "$targets_json" | jq .
  exit 2
fi

echo "=== Targets Summary ==="

total="$(echo "$targets_json" | jq '.data.activeTargets | length')"
up="$(echo "$targets_json" | jq '[.data.activeTargets[] | select(.health == "up")] | length')"
down="$(echo "$targets_json" | jq '[.data.activeTargets[] | select(.health == "down")] | length')"
unknown="$(echo "$targets_json" | jq '[.data.activeTargets[] | select(.health != "up" and .health != "down")] | length')"

echo "Total active targets: $total"
echo "UP:                   $up"
echo "DOWN:                 $down"
echo "UNKNOWN/OTHER:        $unknown"
echo

if [[ "$down" -gt 0 || "$unknown" -gt 0 ]]; then
  echo "=== Unhealthy Targets ==="

  echo "$targets_json" | jq -r '
    .data.activeTargets[]
    | select(.health != "up")
    | [
        (.labels.job // "-"),
        (.labels.instance // "-"),
        .health,
        (.lastError // "-"),
        (.lastScrape // "-"),
        (.scrapeUrl // "-")
      ]
    | @tsv
  ' | awk -F'\t' '
    BEGIN {
      printf "%-24s %-32s %-10s %-40s %-25s %s\n", "JOB", "INSTANCE", "HEALTH", "LAST_ERROR", "LAST_SCRAPE", "SCRAPE_URL"
      printf "%-24s %-32s %-10s %-40s %-25s %s\n", "---", "--------", "------", "----------", "-----------", "----------"
    }
    {
      err=$4
      if (length(err) > 38) err=substr(err,1,37)"…"
      printf "%-24s %-32s %-10s %-40s %-25s %s\n", $1, $2, $3, err, $5, $6
    }
  '

  echo
else
  echo "No unhealthy targets found."
  echo
fi

if [[ "$SHOW_ALL" -eq 1 ]]; then
  echo "=== All Targets ==="

  echo "$targets_json" | jq -r '
    .data.activeTargets[]
    | [
        (.labels.job // "-"),
        (.labels.instance // "-"),
        .health,
        (.lastError // "-"),
        (.lastScrape // "-")
      ]
    | @tsv
  ' | awk -F'\t' '
    BEGIN {
      printf "%-24s %-32s %-10s %-40s %s\n", "JOB", "INSTANCE", "HEALTH", "LAST_ERROR", "LAST_SCRAPE"
      printf "%-24s %-32s %-10s %-40s %s\n", "---", "--------", "------", "----------", "-----------"
    }
    {
      err=$4
      if (length(err) > 38) err=substr(err,1,37)"…"
      printf "%-24s %-32s %-10s %-40s %s\n", $1, $2, $3, err, $5
    }
  '

  echo
fi

# ------------------------------------------------------------
# Exit code for monitoring
# ------------------------------------------------------------

if [[ "$down" -gt 0 || "$unknown" -gt 0 ]]; then
  exit 1
fi

exit 0