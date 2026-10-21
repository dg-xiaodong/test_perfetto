#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# perfetto-service.sh — manage the Perfetto tracing service this fixture needs.
#
# The SDK producer (pf-demo-x5) and the heapprofd preload client both connect to
# the *system* producer socket. tracebox in its default mode creates private
# sockets in its own directory, which the SDK cannot reach; captures therefore
# always use `tracebox --system-sockets` (see scripts/trace.sh) and the service
# is a normal `traced` listening on /tmp/perfetto-producer.
#
# The script is idempotent and never kills a service it did not start.
set -u

D=$(cd "$(dirname "$0")/.." && pwd)
BIN="$D/bin/perfetto"
FALLBACK="/userdata/bin"

find_bin() {
    name="$1"
    for candidate in "$BIN/$name" "$FALLBACK/$name"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

traced_pid() {
    ps -o pid,comm 2>/dev/null | awk '$2 == "traced" {print $1}' | head -n 1
}

probes_pid() {
    ps -o pid,comm 2>/dev/null | awk '$2 == "traced_probes" {print $1}' | head -n 1
}

wait_sockets() {
    i=0
    while [ "$i" -lt 50 ]; do
        if [ -S /tmp/perfetto-consumer ] && [ -S /tmp/perfetto-producer ]; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

start_traced() {
    pid=$(traced_pid)
    if [ -n "$pid" ]; then
        echo "traced already running (pid=$pid)"
        return 0
    fi
    bin=$(find_bin traced) || {
        echo "ERROR: traced binary not found in $BIN or $FALLBACK" >&2
        return 1
    }
    echo "starting $bin --background"
    "$bin" --background >/dev/null 2>&1 || true
    if wait_sockets; then
        echo "traced up (pid=$(traced_pid))"
        return 0
    fi
    echo "ERROR: tracing sockets did not appear" >&2
    return 1
}

start_probes() {
    pid=$(probes_pid)
    if [ -n "$pid" ]; then
        echo "traced_probes already running (pid=$pid)"
        return 0
    fi
    bin=$(find_bin traced_probes) || {
        echo "traced_probes not deployed; captures via tracebox still work"
        return 0
    }
    echo "starting $bin --background"
    "$bin" --background >/dev/null 2>&1 || true
    sleep 1
    echo "traced_probes pid=$(probes_pid)"
    return 0
}

cmd="${1:-status}"
case "$cmd" in
    ensure)
        start_traced || exit 1
        start_probes || true
        ;;
    start)
        start_traced || exit 1
        start_probes || true
        ;;
    stop)
        pid=$(probes_pid)
        if [ -n "$pid" ]; then
            kill -TERM "$pid" 2>/dev/null
            echo "stopped traced_probes pid=$pid"
        fi
        pid=$(traced_pid)
        if [ -n "$pid" ]; then
            kill -TERM "$pid" 2>/dev/null
            echo "stopped traced pid=$pid"
        fi
        ;;
    status)
        echo "traced        : pid=$(traced_pid)"
        echo "traced_probes : pid=$(probes_pid)"
        if [ -S /tmp/perfetto-consumer ]; then
            echo "sockets       : /tmp/perfetto-consumer /tmp/perfetto-producer OK"
        else
            echo "sockets       : MISSING"
        fi
        for name in tracebox perfetto traced traced_probes; do
            bin=$(find_bin "$name") && echo "binary $name : $bin ($("$bin" --version 2>&1 | head -n 1))"
        done
        ;;
    *)
        echo "usage: $0 {ensure|start|stop|status}" >&2
        exit 2
        ;;
esac
