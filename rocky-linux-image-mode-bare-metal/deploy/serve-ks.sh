#!/usr/bin/env bash
# Serve deploy/state/www (ks.cfg only) over HTTP for Anaconda: inst.ks=http://10.0.2.2:8000/ks.cfg
#   serve-ks.sh start|stop|status
source "$(dirname "$0")/lib.sh"
PIDFILE="$STATE_DIR/http.pid"
HTTPLOG="$STATE_DIR/http.log"

running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "${1:-start}" in
  start)
    [[ -f "$WWW_DIR/ks.cfg" ]] || "$DEPLOY_DIR/render-ks.sh"
    if running; then log "http.server already running (pid $(cat "$PIDFILE"))"; exit 0; fi
    # -I: isolated mode, nothing imported from the served directory.
    nohup python3 -I -m http.server "$KS_PORT" --bind "$KS_BIND" --directory "$WWW_DIR" \
      >> "$HTTPLOG" 2>&1 &
    echo $! > "$PIDFILE"
    for _ in $(seq 20); do
      curl -fsS -o /dev/null "http://127.0.0.1:$KS_PORT/ks.cfg" 2>/dev/null && break
      sleep 0.5
    done
    curl -fsS -o /dev/null "http://127.0.0.1:$KS_PORT/ks.cfg" || die "http.server did not come up (see $HTTPLOG)"
    log "serving $WWW_DIR on $KS_BIND:$KS_PORT (pid $(cat "$PIDFILE"))"
    ;;
  stop)
    if running; then kill "$(cat "$PIDFILE")"; log "http.server stopped"; fi
    rm -f "$PIDFILE"
    ;;
  status)
    if running; then echo "running (pid $(cat "$PIDFILE"))"; else echo "stopped"; exit 1; fi
    ;;
  *) die "usage: $0 start|stop|status" ;;
esac
