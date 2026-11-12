#!/usr/bin/env bash
# Bring the model up: render the configuration, start the engine on every machine,
# start the routing layer.
#
#   ./up.sh                  # all of it
#   SKIP_ENGINES=1 ./up.sh   # routing layer only -- a limit change, a new address
#   WAIT=0 ./up.sh           # do not wait for the engines to finish loading
#
# Rendering is part of starting, so there is no separate step to forget. To see what
# would be applied without applying it, run ./render.sh and read generated/.
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=${ENV_FILE:-.env}
WAIT=${WAIT:-1}
# A large model can take tens of minutes to load; the Kubernetes charts budget 90
# for the same reason.
WAIT_TIMEOUT=${WAIT_TIMEOUT:-5400}

echo "=== render"
./render.sh
# Sourcing needs care: a bare name would be looked up in PATH, and "./$name" breaks
# an absolute path. ENV_FILE may be either.
case "$ENV_FILE" in /*|./*|../*) ENV_PATH=$ENV_FILE ;; *) ENV_PATH=./$ENV_FILE ;; esac
set -a; . "$ENV_PATH"; set +a

# One SSH per machine, with the script inlined base64. Not scp: some hosts force a
# TTY in ssh_config (without which non-interactive commands hang), and a forced TTY
# breaks scp and eats stdin -- `ssh host bash -s < file` then delivers nothing and
# still exits 0. Inlining avoids the whole class.
run_remote() {   # run_remote <ssh target> <local script>
    local target=$1 file=$2 b64
    b64=$(base64 < "$file" | tr -d '\n') || return 1
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS:-} "${SSH_USER:-root}@$target" \
        "echo $b64 | base64 -d > /tmp/.ms_engine_launch.sh; bash /tmp/.ms_engine_launch.sh" < /dev/null
}

if [ "${SKIP_ENGINES:-0}" != "1" ]; then
    echo
    echo "=== engines (one machine at a time)"
    while read -r target script instance role; do
        [ -n "${target:-}" ] || continue
        echo "---- $instance / $target ($role)"
        if ! run_remote "$target" "generated/$script"; then
            echo "!! $target did not start. The rest of $instance is pointless without it -- fix this first." >&2
            exit 1
        fi
    done < generated/manifest

    if [ "$WAIT" = "1" ]; then
        echo
        echo "=== waiting for each instance to serve /v1/models (up to $((WAIT_TIMEOUT / 60)) min)"
        # /v1/models answering is readiness, not the container being up: the
        # container starts in seconds and the weights load for minutes.
        deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
        while read -r target script instance role; do
            case "$role" in rank0-serves:*) ;; *) continue ;; esac
            addr=${script#engine-}; addr=${addr%.sh}; port=${role#rank0-serves:}
            printf '  %-10s %s:%s ' "$instance" "$addr" "$port"
            ok=0
            while [ "$(date +%s)" -lt "$deadline" ]; do
                if curl -fs -m 10 "http://$addr:$port/v1/models" >/dev/null 2>&1; then ok=1; break; fi
                printf '.'; sleep 20
            done
            [ "$ok" = 1 ] && echo " ready" \
                || echo " NOT READY -- on the machine: ${CTR_CLI:-docker} logs engine-$ROUTE"
        done < generated/manifest
    fi
fi

echo
echo "=== routing layer"
docker compose up -d

# A route change is a reload, not a restart: a restart cuts responses that are still
# streaming, and `up -d` leaves an already-running openresty alone -- so without
# this it would keep serving the previous route.
if docker compose ps --status running --services 2>/dev/null | grep -qx openresty; then
    echo "--- reload openresty onto the rendered route (graceful: in-flight streams kept)"
    docker compose exec -T openresty openresty -s reload \
        && echo "    reloaded" \
        || echo "    reload failed -- docker compose logs openresty"
fi

echo
echo "ready: curl http://127.0.0.1:8080/$ROUTE/v1/chat/completions \\"
echo "         -H 'Content-Type: application/json' \\"
echo "         -d '{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
echo "state: curl -s http://127.0.0.1:8080/$ROUTE/_health_status"
