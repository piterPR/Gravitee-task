#!/usr/bin/env bash
# End-to-end check of the gateway.
set -euo pipefail

CTX="${CTX:-kind-gravitee}"
URL="${URL:-https://localhost:8443}"
CA="$(mktemp)"
trap 'rm -f "$CA"' EXIT

kubectl --context "$CTX" -n cert-manager get secret gravitee-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA"

run() {
  local want_status="$1" want_body="$2"
  shift 2
  echo "\$ curl -i $*"
  local out
  out="$(curl -sS -i --retry 10 --retry-delay 2 --retry-all-errors "$@")"
  echo "$out"
  echo
  local status body
  status="$(echo "$out" | head -1 | awk '{print $2}')"
  body="$(echo "$out" | tr -d '\r' | awk 'f{print} /^$/{f=1}')"
  if [ "$status" != "$want_status" ]; then
    echo "FAIL: expected HTTP $want_status, got $status" >&2
    exit 1
  fi
  if [ -n "$want_body" ] && [ "$body" != "$want_body" ]; then
    echo "FAIL: expected body '$want_body', got '$body'" >&2
    exit 1
  fi
}

echo "== 1. /ping over HTTPS, certificate verified against the local CA"
run 200 pong --cacert "$CA" "$URL/ping"

echo "== 2. /ping over HTTPS, certificate check skipped (-k)"
run 200 pong -k "$URL/ping"

echo "== 3. endpoint that is not exposed: the gateway must answer 404"
run 404 "" --cacert "$CA" "$URL/not-working"

echo "OK: all checks passed"
