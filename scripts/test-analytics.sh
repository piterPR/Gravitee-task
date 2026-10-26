#!/usr/bin/env bash
# Prints what the gateway has stored in Elasticsearch. Run `make test` first to generate traffic.
set -euo pipefail

CTX="${CTX:-kind-gravitee}"
k() { kubectl --context "$CTX" -n gravitee "$@"; }

PW="$(k get secret elasticsearch -o jsonpath='{.data.password}' | base64 -d)"
es() { k exec statefulset/elasticsearch -- curl -sS -u "elastic:$PW" -H 'Content-Type: application/json' "$@"; }

INDEX='localhost:9200/gravitee-v4-metrics-*'

count="$(es "$INDEX/_count" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
if [ "${count:-0}" -le 0 ]; then
  echo "FAIL: no request metrics in gravitee-v4-metrics-* (run 'make test' first, the gateway flushes every 5s)" >&2
  exit 1
fi

echo "== indices"
es 'localhost:9200/_cat/indices/gravitee-*?v&h=index,docs.count,store.size'

echo
echo "== summary of $count requests"
es "$INDEX/_search?size=0&pretty" -d '{
  "aggs": {
    "requests_per_api":       { "terms": { "field": "api-name" } },
    "requests_per_uri":       { "terms": { "field": "uri" } },
    "requests_per_status":    { "terms": { "field": "status" } },
    "gateway_response_ms":    { "percentiles": { "field": "gateway-response-time-ms", "percents": [50, 95, 99] } },
    "avg_backend_response_ms": { "avg": { "field": "endpoint-response-time-ms" } },
    "response_bytes_total":   { "sum": { "field": "response-content-length" } }
  }
}' | sed -n '/"aggregations"/,$p'

echo
echo "== latest 5 requests"
es "$INDEX/_search?size=5&sort=@timestamp:desc&pretty&_source_includes=@timestamp,api-name,uri,status,gateway-response-time-ms,endpoint-response-time-ms,remote-address,user-agent" \
  | sed -n '/"hits" : \[/,$p'
