#!/bin/sh
# Container replacement for the EC2 crontab (scripts/ec2-cron-*.sh):
#   every 5 min  -> POST /api/cron/host-submit-worker
#   every 15 min -> POST /api/cron/sweep
set -eu

: "${CRON_SECRET:?CRON_SECRET must be set}"
APP_INTERNAL_URL="${APP_INTERNAL_URL:-http://web:3000}"

call() {
  path="$1"
  timeout="$2"
  echo "$(date -Iseconds) POST $path"
  curl -sS --max-time "$timeout" -X POST \
    -H "Authorization: Bearer ${CRON_SECRET}" \
    "${APP_INTERNAL_URL}${path}" || echo "$(date -Iseconds) $path failed"
  echo
}

echo "$(date -Iseconds) waiting for ${APP_INTERNAL_URL}/api/health"
until curl -sf "${APP_INTERNAL_URL}/api/health" >/dev/null; do sleep 5; done
echo "$(date -Iseconds) app is up; starting schedule"

tick=0
while true; do
  call /api/cron/host-submit-worker 280
  if [ $((tick % 3)) -eq 0 ]; then
    call /api/cron/sweep 240
  fi
  tick=$((tick + 1))
  sleep 300
done
