#!/usr/bin/env bash
# 検証時間帯の Cloud Logging / Monitoring インシデントを JSON で書き出す
# 使い方: ./export-logs.sh <PROJECT_ID> <START_UTC> <END_UTC> [OUT_DIR]
#   例:  ./export-logs.sh miumosh-sb-test01 2026-11-10T17:10:00Z 2026-11-10T18:35:00Z
set -euo pipefail
P=${1:?project}; S=${2:?start}; E=${3:?end}
OUT=${4:-"$(cd "$(dirname "$0")" && pwd)/$(date -u -d "$S" +%Y%m%dT%H%MZ)"}
mkdir -p "$OUT"
T="timestamp>=\"$S\" AND timestamp<=\"$E\""

dump() { # name filter
  echo "exporting $1 ..." >&2
  gcloud logging read "$2 AND $T" --project "$P" --order=asc --limit=100000 --format=json > "$OUT/$1.json"
  echo "  $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$OUT/$1.json") entries" >&2
}

dump healthcheck        "logName=\"projects/$P/logs/compute.googleapis.com%2Fhealthchecks\""
dump lb-request         "resource.type=\"internal_http_lb_rule\" AND logName=\"projects/$P/logs/loadbalancing.googleapis.com%2Frequests\""
dump scheduler          "resource.type=\"cloud_scheduler_job\""
dump audit-compute      "logName=\"projects/$P/logs/cloudaudit.googleapis.com%2Factivity\" AND protoPayload.serviceName=\"compute.googleapis.com\" AND protoPayload.methodName=~\"compute\\.instances\\.(start|stop)$\""
dump audit-system-event "logName=\"projects/$P/logs/cloudaudit.googleapis.com%2Fsystem_event\""
dump monitoring-events  "logName=~\"projects/$P/logs/monitoring.googleapis.com%2FViolation\""

echo "exporting incidents (Monitoring API) ..." >&2
curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://monitoring.googleapis.com/v3/projects/$P/alerts" \
  --data-urlencode "pageSize=200" --data-urlencode "orderBy=open_time asc" > "$OUT/incidents.json"

echo "done: $OUT" >&2
