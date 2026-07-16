#!/bin/sh
set -eu

IWAN_HEALTHCHECK_URL="${IWAN_HEALTHCHECK_URL:-https://api.llm.ustc.edu.cn}"
IWAN_HEALTHCHECK_TIMEOUT="${IWAN_HEALTHCHECK_TIMEOUT:-10}"
HTTP_PROXY_URL="http://127.0.0.1:8888"

if output="$(
    curl -sS \
        --output /dev/null \
        --connect-timeout "$IWAN_HEALTHCHECK_TIMEOUT" \
        --max-time "$IWAN_HEALTHCHECK_TIMEOUT" \
        --proxy "$HTTP_PROXY_URL" \
        --write-out 'proxy_connect=%{http_connect} http=%{response_code} connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s' \
        "$IWAN_HEALTHCHECK_URL" 2>&1
)"; then
    curl_status=0
else
    curl_status="$?"
fi

output="$(printf '%s' "$output" | tr '\n' ' ')"
printf 'url=%s proxy=%s curl_exit=%s %s\n' \
    "$IWAN_HEALTHCHECK_URL" "$HTTP_PROXY_URL" "$curl_status" "$output"

[ "$curl_status" -eq 0 ]
