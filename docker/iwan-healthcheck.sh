#!/bin/sh
set -eu

IWAN_TUN="${IWAN_TUN:-iwan0}"

has_process() {
    name="$1"
    for comm in /proc/[0-9]*/comm; do
        [ -r "$comm" ] || continue
        [ "$(cat "$comm")" = "$name" ] && return 0
    done
    return 1
}

listens_on() {
    port="$1"
    ss -ltn | grep -Eq "[.:]${port}[[:space:]]"
}

has_process iwan-client-oid || {
    echo "iwan-client-oidc is not running" >&2
    exit 1
}

has_process 3proxy || {
    echo "3proxy is not running" >&2
    exit 1
}

ip -4 addr show dev "$IWAN_TUN" 2>/dev/null | grep -q 'inet ' || {
    echo "$IWAN_TUN has no IPv4 address" >&2
    exit 1
}

ip route show default dev "$IWAN_TUN" | grep -q '^default ' || {
    echo "default route does not use $IWAN_TUN" >&2
    exit 1
}

listens_on 1080 || {
    echo "SOCKS5 port 1080 is not listening" >&2
    exit 1
}

listens_on 8888 || {
    echo "HTTP proxy port 8888 is not listening" >&2
    exit 1
}
