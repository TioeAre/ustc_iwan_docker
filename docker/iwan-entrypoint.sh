#!/bin/sh
set -eu

CONFIG_DIR="${IWAN_CONFIG_DIR:-/config}"
SERVER_INDEX_FILE="${IWAN_SERVER_INDEX_FILE:-${CONFIG_DIR}/server_index}"
IWAN_TUN="${IWAN_TUN:-iwan0}"
IWAN_SERVER_INDEX="${IWAN_SERVER_INDEX:-}"
IWAN_PROXY_CIDR="${IWAN_PROXY_CIDR:-0.0.0.0/0}"
IWAN_PROXY_IP="${IWAN_PROXY_IP:-}"
IWAN_PROXY_DOMAIN="${IWAN_PROXY_DOMAIN:-}"
IWAN_ENCRYPT="${IWAN_ENCRYPT:-1}"
IWAN_HEALTHCHECK_URL="${IWAN_HEALTHCHECK_URL:-https://api.llm.ustc.edu.cn}"
IWAN_WATCHDOG_INTERVAL="${IWAN_WATCHDOG_INTERVAL:-5}"
IWAN_WATCHDOG_RETRIES="${IWAN_WATCHDOG_RETRIES:-2}"
IWAN_RECONNECT_DELAY="${IWAN_RECONNECT_DELAY:-2}"
IWAN_STATUS_LOG_INTERVAL="${IWAN_STATUS_LOG_INTERVAL:-60}"
THREEPROXY_CONFIG="${THREEPROXY_CONFIG:-/etc/3proxy/3proxy.cfg}"

mode="auto"
iwan_pid=""
proxy_pid=""
EXTRA_ARGS=""
server_index=""
stopping=0
connection_attempt=0
reconnect_reason="startup"

log() {
    category="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$category" "$*"
}

if [ "$#" -gt 0 ]; then
    case "$1" in
        --fetch) mode="fetch"; shift ;;
        --list) mode="list"; shift ;;
        --connect) mode="connect"; shift ;;
        --auto) mode="auto"; shift ;;
        fetch|list|connect|auto) mode="$1"; shift ;;
        *) mode="command" ;;
    esac
fi

EXTRA_ARGS="$*"

run_simple_mode() {
    case "$mode" in
        fetch)
            exec iwan-client-oidc --config-dir "$CONFIG_DIR" --fetch "$@"
            ;;
        list)
            exec iwan-client-oidc --config-dir "$CONFIG_DIR" --list "$@"
            ;;
        command)
            exec "$@"
            ;;
    esac
}

ensure_config() {
    if [ -s "$CONFIG_DIR/servers.json" ]; then
        return
    fi

    if [ "$mode" = "auto" ]; then
        log "SUPERVISOR" "missing $CONFIG_DIR/servers.json; starting OIDC login"
        iwan-client-oidc --config-dir "$CONFIG_DIR" --fetch
    fi

    if [ ! -s "$CONFIG_DIR/servers.json" ]; then
        echo "missing $CONFIG_DIR/servers.json; start this container interactively once" >&2
        exit 1
    fi
}

choose_server() {
    if [ -n "$IWAN_SERVER_INDEX" ]; then
        server_index="$IWAN_SERVER_INDEX"
    elif [ -s "$SERVER_INDEX_FILE" ]; then
        server_index="$(tr -cd '0-9' < "$SERVER_INDEX_FILE")"
    else
        iwan-client-oidc --config-dir "$CONFIG_DIR" --list
        printf '  Select server to save for this container: '
        read -r server_index
        server_index="$(printf '%s' "$server_index" | tr -cd '0-9')"
        [ -n "$server_index" ] || {
            echo "invalid server selection" >&2
            exit 1
        }
        printf '%s\n' "$server_index" > "$SERVER_INDEX_FILE"
    fi

    if [ -z "$server_index" ]; then
        echo "empty server selection; remove $SERVER_INDEX_FILE and start interactively again" >&2
        exit 1
    fi
}

build_iwan_command() {
    set -- iwan-client-oidc \
        --config-dir "$CONFIG_DIR" \
        --connect \
        --tun "$IWAN_TUN" \
        --encrypt "$IWAN_ENCRYPT"

    [ -n "$IWAN_PROXY_CIDR" ] && set -- "$@" --proxy-cidr "$IWAN_PROXY_CIDR"
    [ -n "$IWAN_PROXY_IP" ] && set -- "$@" --proxy-ip "$IWAN_PROXY_IP"
    [ -n "$IWAN_PROXY_DOMAIN" ] && set -- "$@" --proxy-domain "$IWAN_PROXY_DOMAIN"

    IWAN_COMMAND="$*"
}

start_iwan() {
    build_iwan_command
    # IWAN_COMMAND and EXTRA_ARGS are simple CLI fragments controlled by env vars.
    printf '%s\n' "$server_index" | sh -c 'exec "$@"' sh $IWAN_COMMAND $EXTRA_ARGS &
    iwan_pid="$!"
    log "SUPERVISOR" "started iwan-client-oidc pid=$iwan_pid server_index=$server_index"
}

wait_for_tun() {
    for _ in $(seq 1 60); do
        if ! kill -0 "$iwan_pid" 2>/dev/null; then
            reap_iwan
            reconnect_reason="iwan-client-oidc exited before $IWAN_TUN was ready"
            return 1
        fi
        if ip -4 addr show dev "$IWAN_TUN" 2>/dev/null | grep -q 'inet '; then
            tun_ip="$(ip -4 -o addr show dev "$IWAN_TUN" | awk '{print $4}' | head -n 1)"
            log "TUNNEL" "connected tun=$IWAN_TUN ip=$tun_ip"
            return 0
        fi
        sleep 1
    done

    reconnect_reason="timed out waiting for $IWAN_TUN"
    return 1
}

start_proxy() {
    3proxy "$THREEPROXY_CONFIG" &
    proxy_pid="$!"
    log "PROXY" "listening pid=$proxy_pid socks5=1080 http=8888"
}

reap_iwan() {
    [ -n "$iwan_pid" ] || return 0
    if wait "$iwan_pid" 2>/dev/null; then
        iwan_status=0
    else
        iwan_status="$?"
    fi
    log "SUPERVISOR" "iwan-client-oidc exited status=$iwan_status"
    iwan_pid=""
}

reap_proxy() {
    [ -n "$proxy_pid" ] || return 0
    if wait "$proxy_pid" 2>/dev/null; then
        proxy_status=0
    else
        proxy_status="$?"
    fi
    log "SUPERVISOR" "3proxy exited status=$proxy_status"
    proxy_pid=""
}

monitor_connection() {
    failures=0
    ever_healthy=0
    last_status_log="$(date +%s)"

    while true; do
        if ! kill -0 "$iwan_pid" 2>/dev/null; then
            reap_iwan
            reconnect_reason="iwan-client-oidc exited"
            return 1
        fi
        if ! kill -0 "$proxy_pid" 2>/dev/null; then
            reap_proxy
            reconnect_reason="3proxy exited"
            return 1
        fi

        if health_output="$(iwan-healthcheck 2>&1)"; then
            if [ "$failures" -gt 0 ]; then
                log "WATCHDOG" "recovered url=$IWAN_HEALTHCHECK_URL"
            elif [ "$ever_healthy" -eq 0 ]; then
                log "WATCHDOG" "healthy url=$IWAN_HEALTHCHECK_URL"
            fi
            failures=0
            ever_healthy=1
        else
            failures=$((failures + 1))
            health_output="$(printf '%s' "$health_output" | tr '\n' ' ')"
            log "WATCHDOG" "failed attempt=$failures/$IWAN_WATCHDOG_RETRIES reason=$health_output"
            if [ "$failures" -ge "$IWAN_WATCHDOG_RETRIES" ]; then
                reconnect_reason="endpoint watchdog failed $failures times"
                return 1
            fi
        fi

        now="$(date +%s)"
        if [ "$failures" -eq 0 ] && [ $((now - last_status_log)) -ge "$IWAN_STATUS_LOG_INTERVAL" ]; then
            log "WATCHDOG" "healthy url=$IWAN_HEALTHCHECK_URL"
            last_status_log="$now"
        fi
        sleep "$IWAN_WATCHDOG_INTERVAL"
    done
}

stop_children() {
    if [ -n "$proxy_pid" ]; then
        kill "$proxy_pid" 2>/dev/null || true
        reap_proxy
    fi
    if [ -n "$iwan_pid" ]; then
        kill -INT "$iwan_pid" 2>/dev/null || true
        for _ in $(seq 1 25); do
            kill -0 "$iwan_pid" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$iwan_pid" 2>/dev/null; then
            log "SUPERVISOR" "iwan-client-oidc did not stop gracefully; sending SIGTERM"
            kill -TERM "$iwan_pid" 2>/dev/null || true
        fi
        reap_iwan
    fi
}

shutdown() {
    signal="$1"
    stopping=1
    log "SHUTDOWN" "received $signal"
    stop_children
    exit 0
}

trap 'shutdown SIGINT' INT
trap 'shutdown SIGTERM' TERM

run_simple_mode "$@"
ensure_config
choose_server

while [ "$stopping" -eq 0 ]; do
    connection_attempt=$((connection_attempt + 1))
    log "SUPERVISOR" "starting connection attempt=$connection_attempt"
    start_iwan

    if wait_for_tun; then
        start_proxy
        monitor_connection || true
    fi

    [ "$stopping" -eq 0 ] || break
    stop_children
    log "RECONNECT" "reason=$reconnect_reason delay=${IWAN_RECONNECT_DELAY}s"
    sleep "$IWAN_RECONNECT_DELAY"
done
