#!/usr/bin/env bash
# Where the deployment stands: each instance's engine, the routing layer, and the
# address to call.
#
#   ./status.sh
#
# Exit status 0 when every instance serves and the routing layer is running, 1
# otherwise -- so `until ./status.sh >/dev/null; do sleep 30; done` waits for it.
# Read-only: it starts and stops nothing.
set -uo pipefail
cd "$(dirname "$0")"

ENV_FILE=${ENV_FILE:-.env}
case "$ENV_FILE" in /*|./*|../*) ENV_PATH=$ENV_FILE ;; *) ENV_PATH=./$ENV_FILE ;; esac
[ -f "$ENV_PATH" ] || { echo "status: no $ENV_FILE" >&2; exit 2; }
set -a; . "$ENV_PATH"; set +a
# What is deployed: up.sh's record of its last successful run, else the latest render
# (a run that has not finished yet). Not the render first: ./render.sh alone rewrites
# it, and a preview of a changed hosts or MODEL_NAME would then report on engines
# that do not exist. The route is read, not re-derived, so there is one naming rule.
if [ -f generated/.applied-manifest ] && [ -f generated/.applied-route ]; then
    MANIFEST=generated/.applied-manifest
    ROUTE=$(cat generated/.applied-route)
elif [ -f generated/manifest ] && [ -f generated/route ]; then
    MANIFEST=generated/manifest
    ROUTE=$(cat generated/route)
else
    echo "status: nothing has been deployed from this directory; run ./up.sh" >&2; exit 2
fi
CLI=${CTR_CLI:-docker}
COMPOSE="docker compose --env-file $ENV_PATH -p $(printf 'ms-%s' "$ROUTE" | tr '.' '-')"
NS=""; [ "$CLI" = nerdctl ] && NS="--namespace ${CTR_NAMESPACE:-default}"

is_this_machine() {   # is_this_machine <address>: loopback or one of our own IPv4s
    case "$1" in 127.*|localhost) return 0 ;; esac
    ip -4 -o addr show 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' | grep -qxF "$1"
}
on() {   # on <target> <command>: run it here or over ssh
    if is_this_machine "$1"; then bash -c "$2"
    # shellcheck disable=SC2086
    else ssh ${SSH_OPTS:-} "${SSH_USER:-root}@$1" "$2" < /dev/null; fi
}

ok=1 n_total=0 n_ready=0
echo "=== engines"
while read -r target script instance role; do
    [ -n "${target:-}" ] || continue
    addr=${script#engine-}; addr=${addr%.sh}
    # "<status> <started-at>" of the engine container, empty when there is none.
    c=$(on "$target" "$CLI $NS inspect -f '{{.State.Status}} {{.State.StartedAt}}' engine-$ROUTE 2>/dev/null" 2>/dev/null)
    cstat=${c%% *}; since=${c#* }; since=${since%%.*}
    case "$role" in rank0-serves:*) port=${role#rank0-serves:}; where=$addr:$port; n_total=$(( n_total + 1 )) ;;
                    *)              port="";                    where=$addr ;; esac
    if [ -z "$c" ]; then
        state="not running"; detail="no engine container on this server"
    elif [ "$cstat" != running ]; then
        state="stopped"; detail="container $cstat -- $CLI logs engine-$ROUTE"
    elif [ -z "$port" ]; then
        state="running"; detail="up since $since (holds shards; rank 0 serves)"
    elif curl -fs -m 10 "http://$addr:$port/v1/models" >/dev/null 2>&1; then
        state="serving"; detail="up since $since"
    else
        state="loading"; detail="up since $since"
    fi
    case "$state" in serving) n_ready=$(( n_ready + 1 )) ;; running) ;; *) ok=0 ;; esac
    printf '  %-4s %-21s %-12s %s\n' "$instance" "$where" "$state" "$detail"
done < "$MANIFEST"

echo "=== routing layer"
running=$($COMPOSE ps --status running --services 2>/dev/null)
for svc in openresty cart; do
    if printf '%s\n' "$running" | grep -qx "$svc"; then echo "  $svc  running"
    else echo "  $svc  NOT running"; ok=0; fi
done
case "${GATEWAY_PORT:-8080}" in *:*) LOCAL_GW=$GATEWAY_PORT ;; *) LOCAL_GW=127.0.0.1:${GATEWAY_PORT:-8080} ;; esac
health=$(curl -s -m 5 "http://$LOCAL_GW/$ROUTE/_health_status" 2>/dev/null)
if [ -n "$health" ]; then
    # One line per peer the gateway routes to: address, banned or not, requests in flight.
    peers=$(printf '%s' "$health" | grep -oE '"[0-9.]+:[0-9]+":\{[^}]*\}' \
        | sed -E 's/"([^"]+)":\{.*"banned":(true|false).*/\1 \2/; s/ true$/ BANNED/; s/ false$/ ok/')
    printf '%s\n' "$peers" | sed 's/^/  peer /'
    # A banned peer is being skipped by the gateway (it failed recent health probes);
    # right after an engine finishes loading this clears within a probe interval.
    printf '%s\n' "$peers" | grep -q ' BANNED$' && ok=0
else
    echo "  gateway not answering on $LOCAL_GW"; ok=0
fi

case "${GATEWAY_PORT:-8080}" in
    *:*) GW=${GATEWAY_PORT} ;;
    *)   ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p'); GW=${ip:-127.0.0.1}:${GATEWAY_PORT:-8080} ;;
esac
echo "=== model service"
echo "  endpoint   http://$GW/$ROUTE/v1        (OpenAI-compatible)"
echo "  model      $MODEL_NAME"
echo "  instances  $n_ready of $n_total serving"
[ "$ok" = 1 ] && [ "$n_ready" = "$n_total" ]
