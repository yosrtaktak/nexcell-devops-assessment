#!/usr/bin/env bash
set -uo pipefail

API_URL="${API_URL:-http://localhost:8000}"
TIMEOUT=5
FAILED=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

# --- Check 1: Liveness ---
echo "--- Checking liveness (/health) ---"
if response=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$API_URL/health"); then
    if [ "$response" = "200" ]; then
        pass "liveness (HTTP $response)"
    else
        fail "liveness (HTTP $response)"
    fi
else
    fail "liveness (no response / timeout)"
fi

# --- Check 2: Readiness ---
echo "--- Checking readiness (/ready) ---"
if body=$(curl -s --max-time "$TIMEOUT" "$API_URL/ready"); then
    if echo "$body" | grep -q '"status":"ready"'; then
        pass "readiness ($body)"
    else
        fail "readiness ($body)"
    fi
else
    fail "readiness (no response / timeout)"
fi

# --- Check 3: Redis ---
echo "--- Checking Redis ---"
if redis_response=$(timeout "$TIMEOUT" docker compose exec -T redis redis-cli ping 2>/dev/null); then
    if [ "$redis_response" = "PONG" ]; then
        pass "redis ($redis_response)"
    else
        fail "redis (unexpected response: $redis_response)"
    fi
else
    fail "redis (no response / timeout)"
fi

# --- Check 4: Worker ---
echo "--- Checking worker ---"
TEST_JOB="smoke-test-$(date +%s)"
docker compose exec -T redis redis-cli RPUSH jobs "$TEST_JOB" > /dev/null 2>&1

sleep 2

queue_len=$(timeout "$TIMEOUT" docker compose exec -T redis redis-cli LLEN jobs 2>/dev/null | tr -d '\r')

if docker compose ps worker 2>/dev/null | grep -q "Up"; then
    if [ "$queue_len" = "0" ]; then
        pass "worker (container running, test job consumed)"
    else
        fail "worker (container running, but job still in queue: $queue_len remaining)"
    fi
else
    fail "worker (container not running)"
fi


echo "---------------------------------"
if [ "$FAILED" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
else
    echo "ONE OR MORE CHECKS FAILED"
    exit 1
fi