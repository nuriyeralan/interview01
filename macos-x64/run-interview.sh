#!/usr/bin/env bash
# Local dry-run of the evaluation. Start your orchestrator first, then run this to drive one or
# more PRACTICE scenarios against it and print your score(s). This mirrors how you are evaluated,
# but the real evaluation uses different, hidden scenarios.
#
# Usage:   ./run-interview.sh [scenarios-csv]
#   e.g.   ./run-interview.sh
#          ./run-interview.sh warmup-01,smoke-01
# Env overrides: ORCHESTRATOR_URL, MOCK_ADO_URL, MINUTE_MILLIS, BUFFER_MINUTES
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$DIR/MockAdo.Server"
MOCK="${MOCK_ADO_URL:-http://localhost:5080}"
ORCH="${ORCHESTRATOR_URL:-http://localhost:5090}"
MM="${MINUTE_MILLIS:-250}"
BUF="${BUFFER_MINUTES:-30}"
SCENARIOS="${1:-sample-easy,sample-moderate,sample-hard,sample-brutal}"

command -v curl >/dev/null 2>&1 || { echo "curl is required."; exit 1; }
[ -f "$SERVER" ] || { echo "MockAdo.Server not found next to this script ($SERVER)."; exit 1; }
chmod +x "$SERVER" 2>/dev/null || true

SRVPID=""
cleanup() { [ -n "$SRVPID" ] && kill "$SRVPID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Start the simulator if it isn't already answering.
if ! curl -sf "$MOCK/sim/clock" >/dev/null 2>&1; then
  echo "Starting mock ADO server..."
  "$SERVER" --urls "$MOCK" >/dev/null 2>&1 &
  SRVPID=$!
  for _ in $(seq 1 60); do curl -sf "$MOCK/sim/clock" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -sf "$MOCK/sim/clock" >/dev/null 2>&1 || { echo "server did not become ready at $MOCK"; exit 1; }
fi
echo "  mock ADO server is up at $MOCK"

curl -sf "$ORCH" >/dev/null 2>&1 || echo "WARNING: nothing answering at $ORCH — start your orchestrator first."

curl -sf -X POST "$MOCK/sim/config" -H 'Content-Type: application/json' \
  -d "{\"orchestratorUrl\":\"$ORCH\"}" >/dev/null

HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1
TOTAL=0

IFS=',' read -ra NAMES <<< "$SCENARIOS"
for name in "${NAMES[@]}"; do
  echo ""
  echo "=== $name ==="
  curl -sf -X POST "$MOCK/sim/load-embedded?name=$name" >/dev/null
  curl -sf -X POST "$ORCH/episode/start" -H 'Content-Type: application/json' -d "{\"scenario\":\"$name\"}" >/dev/null 2>&1 || true
  SCORE="$(curl -sf -X POST "$MOCK/sim/run?minuteMillis=$MM&extraMinutes=$BUF" --max-time 7200)"
  curl -sf -X POST "$ORCH/episode/end" -H 'Content-Type: application/json' -d "$SCORE" >/dev/null 2>&1 || true
  if [ "$HAVE_PY" = 1 ]; then
    echo "$SCORE" | python3 -c 'import sys,json
s=json.load(sys.stdin)
print("  POINTS %s   completed %s/%s  rlHits %s  missed %s  unfulfilled %s" % (s["pointsEarned"], s["completed"], s["totalRequests"], s.get("rateLimitedRequests",0), s["missed"], s["unfulfilled"]))'
    P="$(echo "$SCORE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["pointsEarned"])')"
    TOTAL="$(python3 -c "print(round($TOTAL + $P, 1))")"
  else
    echo "$SCORE"
  fi
done

echo ""
echo "================= SUMMARY ================="
[ "$HAVE_PY" = 1 ] && echo "Total points: $TOTAL"

# Save your orchestrator's HTML report if it serves one at GET /report.
if curl -sf "$ORCH/report" -o "$DIR/report.html" 2>/dev/null; then
  echo "Saved your orchestrator report -> report.html"
fi
