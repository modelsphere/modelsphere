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

is_this_machine() {   # is_this_machine <address>: loopback or one of our own IPv4s
    case "$1" in 127.*|localhost) return 0 ;; esac
    ip -4 -o addr show 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' | grep -qxF "$1"
}

# One SSH per machine, with the script inlined base64. Not scp: some hosts force a
# TTY in ssh_config (without which non-interactive commands hang), and a forced TTY
# breaks scp and eats stdin -- `ssh host bash -s < file` then delivers nothing and
# still exits 0. Inlining avoids the whole class.
run_remote() {   # run_remote <ssh target> <local script>
    local target=$1 file=$2 b64
    # A target that is this machine -- loopback, or one of its own addresses -- runs
    # here rather than over ssh to ourselves, which would need root's own key in its
    # authorized_keys for nothing.
    if is_this_machine "$target"; then bash "$file"; return; fi
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
# The image's framework config carries the two listener ports as literals, and host
# networking leaves no port mapping to change them with. So take that file out of the
# image being deployed, substitute the ports, and mount the result back over it.
# Extracted every run from THAT image, never a copy kept in this repo: a stored copy
# would quietly become a stale version of the framework the first time the image
# moved on. Each substitution asserts it matched exactly once, so an image that
# writes the directive differently fails here rather than serving the wrong thing.
echo "--- framework config: gateway on ${GATEWAY_PORT:-8080}, admin server off"
SB=/usr/local/openresty/nginx/conf/conf.d/session_base.conf
docker run --rm --entrypoint cat "${OPENRESTY_IMAGE:?}" "$SB" > generated/session_base.conf \
    || { echo "!! could not read $SB out of ${OPENRESTY_IMAGE}" >&2; exit 1; }
# The admin server (8090) serves /healthz, unauthenticated, and nothing here asks
# for it -- up.sh waits on the engine's /v1/models and the route's own status
# endpoints -- so it is always pointed at a unix socket: no TCP listener at all.
# A substitution rather than cutting the server block out of someone else's config:
# it keeps the single-match assertion, and there is no brace matching to get subtly
# wrong.
for pair in "8080:${GATEWAY_PORT:-8080}" "8090:unix:/usr/local/openresty/nginx/sock/admin.sock"; do
    from=${pair%%:*} to=${pair#*:}
    n=$(grep -cE "^[[:space:]]*listen ${from};" generated/session_base.conf)
    [ "$n" = 1 ] || { echo "!! expected one 'listen ${from};' in the image's config, found $n" >&2; exit 1; }
    [ "$from" = "$to" ] && continue
    sed -i -E "s|^([[:space:]]*)listen ${from};|\\1listen ${to};|" generated/session_base.conf
    echo "    listen ${from} -> ${to}"
done

# The ports, before starting: with host networking these bind here directly, and a
# port already taken means nginx fails to bind and the container exits -- visible
# otherwise only as a container that will not stay up.
busy=""
# An address:port value is allowed (127.0.0.1:8090 keeps the admin server local);
# the check wants the port part.
for p in "${GATEWAY_PORT:-8080}" "${CART_PORT:-8071}"; do
    p=${p##*:}
    case "$p" in ''|*[!0-9]*) continue ;; esac   # an address with no port
    ss -ltn 2>/dev/null | grep -q ":$p " && busy="$busy $p"
done
if [ -n "$busy" ]; then
    echo "!! port(s) in use on this machine:$busy" >&2
    for p in $busy; do ss -ltnp 2>/dev/null | grep ":$p " | sed 's/^/     /' >&2; done
    echo "   GATEWAY_PORT and CART_PORT in $ENV_FILE both move; free the port" >&2
    echo "   or change it there. The engines are unaffected either way." >&2
    exit 1
fi
# One switch, not two. Setting BODYLOG_LISTENER_HOST makes openresty build and send
# request records; the listener that receives them is a compose profile. Set the
# address without enabling the profile and openresty sends into nothing: the frames
# buffer in each worker and are then dropped, counted in drop_count and otherwise
# silent. So the address decides both.
PROFILE=""
[ -n "${BODYLOG_LISTENER_HOST:-}" ] && PROFILE="--profile bodylog"
# shellcheck disable=SC2086
docker compose $PROFILE up -d

# A route change is a reload, not a restart: a restart cuts responses that are still
# streaming, and `up -d` leaves an already-running openresty alone -- so without
# this it would keep serving the previous route.
if docker compose $PROFILE ps --status running --services 2>/dev/null | grep -qx openresty; then
    echo "--- reload openresty onto the rendered route (graceful: in-flight streams kept)"
    docker compose $PROFILE exec -T openresty openresty -s reload \
        && echo "    reloaded" \
        || echo "    reload failed -- docker compose logs openresty"
fi

echo
echo "ready: curl http://127.0.0.1:${GATEWAY_PORT:-8080}/$ROUTE/v1/chat/completions \\"
echo "         -H 'Content-Type: application/json' \\"
echo "         -d '{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
echo "state: curl -s http://127.0.0.1:${GATEWAY_PORT:-8080}/$ROUTE/_health_status"
