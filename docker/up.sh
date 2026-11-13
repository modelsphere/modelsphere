#!/usr/bin/env bash
# Bring the model up: render the configuration, start the engine on every machine,
# start the routing layer.
#
#   ./up.sh                  # all of it; returns once every instance serves
#   ./up.sh --no-wait        # start everything and return at once (or WAIT=0);
#                            #   follow the loading with ./status.sh
#   SKIP_ENGINES=1 ./up.sh   # routing layer only -- a limit change, a new address
#   FORCE_ENGINES=1 ./up.sh  # recreate every engine, even one running unchanged
#
# An engine already running with exactly the rendered spec is kept, so adding a
# machine to `hosts` and re-running starts only the new one.
#
# Rendering is part of starting, so there is no separate step to forget. To see what
# would be applied without applying it, run ./render.sh and read generated/.
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=${ENV_FILE:-.env}
WAIT=${WAIT:-1}
for a in "$@"; do
    case "$a" in
        --no-wait) WAIT=0 ;;
        *) echo "up.sh: unknown argument '$a' (only --no-wait)" >&2; exit 2 ;;
    esac
done
# A large model can take tens of minutes to load; the Kubernetes charts budget 90
# for the same reason.
WAIT_TIMEOUT=${WAIT_TIMEOUT:-5400}

# What the last successful run deployed: servers dropped from `hosts` (or a changed
# route name) leave engines behind that this run has to stop. Recorded at the end of a
# run that got that far, not taken from generated/manifest, which every render
# overwrites -- a run that fails half-way must not make the next one forget them.
PREV_MANIFEST=""; PREV_ROUTE=""
[ -f generated/.applied-manifest ] && PREV_MANIFEST=$(cat generated/.applied-manifest)
[ -f generated/.applied-route ] && PREV_ROUTE=$(cat generated/.applied-route)

echo "=== render"
./render.sh
# Sourcing needs care: a bare name would be looked up in PATH, and "./$name" breaks
# an absolute path. ENV_FILE may be either.
case "$ENV_FILE" in /*|./*|../*) ENV_PATH=$ENV_FILE ;; *) ENV_PATH=./$ENV_FILE ;; esac
set -a; . "$ENV_PATH"; set +a
# The route name render.sh settled on (ROUTE, or derived from MODEL_NAME).
ROUTE=$(cat generated/route)
# The compose project is named after it, so deployments of different models on one
# control machine keep separate routing containers. Project names allow no dots.
project_of() { printf 'ms-%s' "$1" | tr '.' '-'; }
COMPOSE="docker compose -p $(project_of "$ROUTE")"

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
    # A private temp file on the far side: a fixed /tmp name left behind by another
    # user (root, say) is not writable for this one, and the launch would fail.
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS:-} "${SSH_USER:-root}@$target" \
        "f=\$(mktemp); echo $b64 | base64 -d > \$f; FORCE_ENGINES=${FORCE_ENGINES:-0} bash \$f; rc=\$?; rm -f \$f; exit \$rc" < /dev/null
}


# Engines this deployment no longer has. A server can be listed under another address
# (127.0.0.1 vs its own IP, a name vs an address), so before stopping anything its
# machine-id is compared with the servers still listed, and the same machine is kept.
# Never fails: an unreachable server (or one without /etc/machine-id) prints nothing,
# and callers read an empty id as unreachable. Under set -e a failing ssh here would
# end up.sh silently, after the route was already reloaded and before this run was
# recorded, so every later run would stop at the same server.
machine_id() {   # machine_id <target>
    if is_this_machine "$1"; then cat /etc/machine-id 2>/dev/null || true
    # shellcheck disable=SC2086
    else ssh ${SSH_OPTS:-} "${SSH_USER:-root}@$1" 'cat /etc/machine-id' < /dev/null 2>/dev/null || true; fi
}
stop_engines() {   # stop_engines <route> <keep-machine-ids> <target>...
    local route=$1 keep=$2 target id stop; shift 2
    for target in "$@"; do
        id=$(machine_id "$target")
        if [ -z "$id" ]; then echo "    $target: unreachable -- stop engine-$route there yourself"; continue; fi
        case " $keep " in *" $id "*) echo "    $target: still in hosts under another address -- kept"; continue ;; esac
        stop="CLI=${CTR_CLI:-docker}; NS=''; [ \"\$CLI\" = nerdctl ] && NS='--namespace ${CTR_NAMESPACE:-default}'; \$CLI \$NS stop -t 60 engine-$route >/dev/null 2>&1; \$CLI \$NS rm -f engine-$route >/dev/null 2>&1; true"
        if is_this_machine "$target"; then bash -c "$stop"
        # shellcheck disable=SC2086
        elif ! ssh ${SSH_OPTS:-} "${SSH_USER:-root}@$target" "$stop" < /dev/null; then
            echo "    $target: could not stop engine-$route -- stop it there yourself"; continue
        fi
        echo "    $target: engine-$route stopped and removed"
    done
}
prev_targets=$(printf '%s\n' "$PREV_MANIFEST" | awk 'NF {print $1}')

# A changed route name means a different engine container on the same ports: the old
# one has to go before the new one can bind, on every server it ran on.
if [ "${SKIP_ENGINES:-0}" != "1" ] && [ -n "$PREV_ROUTE" ] && [ "$PREV_ROUTE" != "$ROUTE" ]; then
    echo "=== route changed ($PREV_ROUTE -> $ROUTE): removing the previous deployment first"
    # shellcheck disable=SC2086
    stop_engines "$PREV_ROUTE" "" $prev_targets
    # Its routing layer too: a different project now, on the same ports.
    docker compose -p "$(project_of "$PREV_ROUTE")" down >/dev/null 2>&1 \
        && echo "    routing layer of $PREV_ROUTE removed"
fi

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
        n_total=0; n_ready=0; ready_addrs=""
        while read -r target script instance role; do
            case "$role" in rank0-serves:*) ;; *) continue ;; esac
            addr=${script#engine-}; addr=${addr%.sh}; port=${role#rank0-serves:}
            printf '  %-10s %s:%s ' "$instance" "$addr" "$port"
            ok=0
            while [ "$(date +%s)" -lt "$deadline" ]; do
                if curl -fs -m 10 "http://$addr:$port/v1/models" >/dev/null 2>&1; then ok=1; break; fi
                printf '.'; sleep 20
            done
            n_total=$(( n_total + 1 ))
            if [ "$ok" = 1 ]; then echo " ready"; n_ready=$(( n_ready + 1 )); ready_addrs="$ready_addrs $instance=$addr:$port"
            else echo " NOT READY -- on the machine: ${CTR_CLI:-docker} logs engine-$ROUTE"; fi
        done < generated/manifest

        # The first request on a fresh engine compiles kernels and can take a minute or
        # more -- measured: ~75s on Ascend 910B4, where /v1/models had long been answering.
        # Send each ready instance one tiny request now, in parallel, so a user's first
        # request does not pay for it.
        if [ -n "$ready_addrs" ]; then
            echo
            echo "=== warming up each instance (first request compiles kernels)"
            for e in $ready_addrs; do
                (
                    t0=$(date +%s)
                    code=$(curl -s -m 900 -o /dev/null -w '%{http_code}' "http://${e#*=}/v1/completions" \
                        -H 'Content-Type: application/json' \
                        -d "{\"model\":\"$MODEL_NAME\",\"prompt\":\"hello\",\"max_tokens\":1}" < /dev/null)
                    printf '  %-10s %s  warm-up -> %s in %ss\n' "${e%%=*}" "${e#*=}" "$code" "$(( $(date +%s) - t0 ))"
                ) &
            done
            wait
        fi
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
SB_TMP=generated/.session_base.conf.tmp
docker run --rm --entrypoint cat "${OPENRESTY_IMAGE:?}" "$SB" > "$SB_TMP" \
    || { echo "!! could not read $SB out of ${OPENRESTY_IMAGE}" >&2; exit 1; }
# The admin server (8090) serves /healthz, unauthenticated, and nothing here asks
# for it -- up.sh waits on the engine's /v1/models and the route's own status
# endpoints -- so it is always pointed at a unix socket: no TCP listener at all.
# A substitution rather than cutting the server block out of someone else's config:
# it keeps the single-match assertion, and there is no brace matching to get subtly
# wrong.
for pair in "8080:${GATEWAY_PORT:-8080}" "8090:unix:/usr/local/openresty/nginx/sock/admin.sock"; do
    from=${pair%%:*} to=${pair#*:}
    n=$(grep -cE "^[[:space:]]*listen ${from};" "$SB_TMP")
    [ "$n" = 1 ] || { echo "!! expected one 'listen ${from};' in the image's config, found $n" >&2; exit 1; }
    [ "$from" = "$to" ] && continue
    sed -i -E "s|^([[:space:]]*)listen ${from};|\\1listen ${to};|" "$SB_TMP"
    echo "    listen ${from} -> ${to}"
done
# Into the mounted file IN PLACE, never by replacing it: session_base.conf is a
# single-file bind mount, which follows the inode. `sed -i` (or mv) on the mounted path
# swaps in a new inode, the running container keeps reading the old one, and the next
# reload loads the UNsubstituted config -- measured: "bind() to 0.0.0.0:8080 failed
# (98: Address already in use)", the reload rejected, the old peers kept serving.
cat "$SB_TMP" > generated/session_base.conf && rm -f "$SB_TMP"

# The ports, before starting: with host networking these bind here directly, and a
# port already taken means nginx fails to bind and the container exits -- visible
# otherwise only as a container that will not stay up.
# Each port is skipped only while this deployment's own service on it is running: a
# re-apply (change .env, run ./up.sh again) finds them held by its own openresty and
# CART -- and with one of the two stopped, the other must not count as a stranger.
running=$($COMPOSE ps --status running --services 2>/dev/null)
busy=""
for pair in "openresty:${GATEWAY_PORT:-8080}" "cart:${CART_PORT:-8071}"; do
    svc=${pair%%:*} p=${pair##*:}   # an address:port value: the check wants the port
    case "$p" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$running" | grep -qx "$svc" && continue
    ss -ltn 2>/dev/null | grep -q ":$p " && busy="$busy $p"
done
if [ -n "$busy" ]; then
    echo "!! port(s) in use on this machine:$busy" >&2
    for p in $busy; do ss -ltnp 2>/dev/null | grep ":$p " | sed 's/^/     /' >&2; done
    echo "   GATEWAY_PORT and CART_PORT in $ENV_FILE both move; free the port" >&2
    echo "   or change it there. The engines are unaffected either way." >&2
    exit 1
fi
# The key directory is mounted whether or not it holds a key file (no file = no
# authentication). Create it here rather than let docker create it as root.
mkdir -p "${API_KEYS_DIR:-./keys}"
$COMPOSE up -d

# Applying a changed configuration to a routing layer that is already running:
#   - openresty: a graceful reload picks up the rendered route, peers included
#     (in-flight streams are kept). `up -d` leaves a running openresty alone, so without
#     the reload it would keep serving the previous route.
#   - CART re-reads its worker list only on SIGHUP. Without the signal it keeps routing
#     to the workers it started with (measured: "No available workers" after a machine
#     was readdressed) and the route falls through to the engines tier behind it.
if $COMPOSE ps --status running --services 2>/dev/null | grep -qx openresty; then
    echo "--- reload openresty onto the rendered route (graceful: in-flight streams kept)"
    $COMPOSE exec -T openresty openresty -s reload \
        && echo "    reloaded" \
        || echo "    reload failed -- $COMPOSE logs openresty"
fi
#   - CART's other fields (body limit, cache, timeouts) are rejected by that SIGHUP
#     handler, so a change there restarts CART instead.
no_workers() { awk '/^[[:space:]]*#/ {next} /^workers:/ {skip=1; next} skip && /^[^[:space:]-]/ {skip=0} !skip' "$1"; }
if $COMPOSE ps --status running --services 2>/dev/null | grep -qx cart && \
   [ -f generated/.applied-cart.yaml ] && ! cmp -s generated/.applied-cart.yaml generated/cart.yaml; then
    if [ "$(no_workers generated/.applied-cart.yaml)" != "$(no_workers generated/cart.yaml)" ]; then
        echo "--- CART's settings changed: restart CART (its SIGHUP accepts only the worker list)"
        $COMPOSE restart cart >/dev/null && echo "    restarted" \
            || echo "    restart failed -- $COMPOSE logs cart"
    else
        echo "--- CART's workers changed: SIGHUP so it re-reads them"
        $COMPOSE kill -s HUP cart >/dev/null && echo "    signalled" \
            || echo "    signal failed -- $COMPOSE logs cart"
    fi
fi
cp generated/cart.yaml generated/.applied-cart.yaml

# Servers dropped from `hosts`: stopped only now, after the route above stopped sending
# them traffic.
if [ "${SKIP_ENGINES:-0}" != "1" ] && [ -n "$PREV_ROUTE" ] && [ "$PREV_ROUTE" = "$ROUTE" ]; then
    gone=""
    for t in $prev_targets; do
        awk '{print $1}' generated/manifest | grep -qxF "$t" || gone="$gone $t"
    done
    if [ -n "$gone" ]; then
        keep=""
        for t in $(awk 'NF {print $1}' generated/manifest); do keep="$keep $(machine_id "$t")"; done
        echo "--- servers no longer in hosts"
        # shellcheck disable=SC2086
        stop_engines "$ROUTE" "$keep" $gone
    fi
fi
# What this run deployed, for the next one (see PREV_MANIFEST above).
if [ "${SKIP_ENGINES:-0}" != "1" ]; then
    cp generated/manifest generated/.applied-manifest
    cp generated/route generated/.applied-route
fi


# The address clients use. GATEWAY_PORT may be a bare port (every interface: show the
# address of the interface this machine's default route leaves by) or address:port.
case "${GATEWAY_PORT:-8080}" in
    *:*) GW=${GATEWAY_PORT} ;;
    *)   ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p')
         GW=${ip:-127.0.0.1}:${GATEWAY_PORT:-8080} ;;
esac
echo
echo "=== model service"
echo "  endpoint   http://$GW/$ROUTE/v1        (OpenAI-compatible)"
echo "  model      $MODEL_NAME"
if [ "${SKIP_ENGINES:-0}" = "1" ]; then
    echo "  instances  not checked (SKIP_ENGINES) -- see ./status.sh"
elif [ "$WAIT" != "1" ]; then
    echo "  instances  still loading -- follow with ./status.sh"
else
    echo "  instances  ${n_ready:-0} of ${n_total:-0} ready"
fi
echo "  try        curl http://$GW/$ROUTE/v1/chat/completions -H 'Content-Type: application/json' \\"
echo "               -d '{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":256}'"
if [ "$WAIT" = "1" ] && [ "${SKIP_ENGINES:-0}" != "1" ] && [ "${n_ready:-0}" -lt "${n_total:-0}" ]; then
    echo "!! not every instance is ready; the route serves only the ready ones" >&2
    exit 1
fi
