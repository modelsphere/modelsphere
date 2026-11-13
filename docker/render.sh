#!/usr/bin/env bash
# Turn .env + hosts into everything that actually runs.
#
# ./up.sh renders before it applies, so you do not normally run this. Run it alone
# to see what WOULD be applied, and read generated/ before applying it.
#
# Writes, all under generated/ (overwritten every time -- never edit it):
#
#   route.conf          the route openresty serves
#   cart.yaml           the cache-aware router's config (its workers = the instances)
#   engine-<host>.sh    the exact container command for one machine (the engine's own
#                       command line comes from ENGINE_CMD when that is set)
#   manifest            <ssh target> <script> <instance> <role>, for up.sh/down.sh
#
# Both halves come out of the same two files on purpose: the route's peer list and
# the engines' rendezvous addresses cannot drift apart. There is no operator watching
# the backends here, so re-render and re-apply whenever hosts changes.
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=${ENV_FILE:-.env}
HOSTS_FILE=${HOSTS_FILE:-hosts}
OUT=${OUT:-generated}

die() { echo "render: $*" >&2; exit 1; }

[ -f "$ENV_FILE" ]   || die "no $ENV_FILE (start from one of examples/: cp examples/<name>.env .env)"
[ -f "$HOSTS_FILE" ] || die "no $HOSTS_FILE (cp hosts.example hosts)"
# Sourcing needs care: a bare name would be looked up in PATH, and "./$name" breaks
# an absolute path. ENV_FILE may be either.
case "$ENV_FILE" in /*|./*|../*) ENV_PATH=$ENV_FILE ;; *) ENV_PATH=./$ENV_FILE ;; esac
set -a; . "$ENV_PATH"; set +a

: "${MODEL_NAME:?set MODEL_NAME}" "${MODEL_PATH:?set MODEL_PATH}"

# The route -- the first path segment clients call, /<route>/v1/... -- is the model name
# unless ROUTE overrides it: the part after the last '/', lower-cased, with anything the
# gateway's dispatcher does not accept ([a-z0-9._-]) turned into '-'.
#   glm-5.3-flash              -> /glm-5.3-flash/
#   Qwen/Qwen2.5-72B-Instruct  -> /qwen2.5-72b-instruct/
if [ -z "${ROUTE:-}" ]; then
    ROUTE=$(printf '%s' "${MODEL_NAME##*/}" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9._-]+/-/g')
fi
printf '%s' "$ROUTE" | grep -qE '^[a-z0-9._-]+$' \
    || die "ROUTE '$ROUTE' must match [a-z0-9._-]+ -- the gateway routes nothing else, every request would get 502"
# Largest request body, in bytes, for the route and CART alike (CART_MAX_BODY_SIZE is
# the older name).
MAX_BODY=${MAX_BODY_SIZE:-${CART_MAX_BODY_SIZE:-209715200}}
RATE_LIMIT=${RATE_LIMIT:-false}
case "$RATE_LIMIT" in
    true|false) ;;
    *) die "RATE_LIMIT must be true or false, got '$RATE_LIMIT'" ;;
esac
case "$MAX_BODY" in ''|*[!0-9]*) die "MAX_BODY_SIZE must be a number of bytes, got '$MAX_BODY'" ;; esac
# The same name as an nginx variable, which allows only [A-Za-z0-9_].
ROUTE_VAR=$(printf '%s' "$ROUTE" | sed -E 's/[^A-Za-z0-9_]/_/g')
: "${ENGINE_IMAGE:?set ENGINE_IMAGE}" "${ENGINE_PORT:?set ENGINE_PORT}"

ENGINE=${ENGINE:-sglang}
# With ENGINE_CMD set, ENGINE is only a label (it names the cache directory): the
# command is yours, so this script has no business insisting on an engine it knows.
if [ -z "${ENGINE_CMD:-}" ]; then
    case "$ENGINE" in sglang|vllm) ;; *) die "ENGINE must be sglang or vllm, got '$ENGINE'" ;; esac
fi

TP=${TP:-1} PP=${PP:-1}
DEVICES_PER_NODE=${DEVICES_PER_NODE:-1}
NODES_PER_INSTANCE=${NODES_PER_INSTANCE:-1}

# The machines, in file order. Column 1 is how we log in; column 2, when present, is
# the address the routers and the instance's other machines use.
hosts=$(awk '/^[[:space:]]*#/ {next} {sub(/#.*/,"")} NF >= 1 {print $1, ($2 == "" ? $1 : $2)}' "$HOSTS_FILE")
nhosts=$(echo "$hosts" | grep -c . || true)
[ "$nhosts" -gt 0 ] || die "$HOSTS_FILE has no machines in it"
# Each address gets its own generated engine-<address>.sh, so a repeated one would
# silently overwrite the first and leave one server without an engine.
dup=$(echo "$hosts" | awk '{print $2}' | sort | uniq -d | tr '\n' ' ')
[ -z "$dup" ] || die "$HOSTS_FILE lists the same address more than once: $dup"

# Two arithmetic checks. Both failures otherwise surface as something else entirely:
# a leftover machine silently serves nothing, and a wrong TP x PP makes the engine
# exit at startup with a complaint that never mentions these files.
[ $(( nhosts % NODES_PER_INSTANCE )) -eq 0 ] \
    || die "$nhosts machine(s) do not divide into instances of $NODES_PER_INSTANCE"
# Skipped with ENGINE_CMD set: TP and PP then describe nothing this script wrote,
# so checking them would reject a correct override.
want=$(( TP * PP ))
have=$(( DEVICES_PER_NODE * NODES_PER_INSTANCE ))
if [ -z "${ENGINE_CMD:-}" ] && [ "$want" != "$have" ] && [ "${ALLOW_SHAPE_MISMATCH:-0}" != "1" ]; then
    die "TP($TP) x PP($PP) = $want but an instance is $NODES_PER_INSTANCE machine(s) x $DEVICES_PER_NODE device(s) = $have"
fi

mkdir -p "$OUT/routes"
# The two mounted files -- routes/route.conf and cart.yaml -- are overwritten in
# place and never deleted, and the route lives in its own directory that is mounted
# as a directory. Both matter: a single-file bind mount follows the INODE, so a
# delete-and-recreate leaves the running container reading the old file, and
# replacing a mounted directory leaves it reading a deleted one. Either way the host
# shows the new config while the container serves the old, with nothing to see.
rm -f "$OUT"/engine-*.sh 2>/dev/null || true
: > "$OUT/manifest"
# up.sh and down.sh name the engine containers after it.
printf '%s\n' "$ROUTE" > "$OUT/route"

############################### the engine commands ###############################
# One script per machine. A script rather than more compose services because each
# machine runs exactly one container, with host networking, and its command differs
# by rank -- and because engine flags can contain JSON, which does not survive being
# quoted through YAML. A command you can read before it runs is worth more here.
render_engine() {   # render_engine <ssh target> <data addr> <rank> <leader data addr>
    local target=$1 addr=$2 rank=$3 leader=$4 dist="" headless=""

    if [ "$NODES_PER_INSTANCE" -gt 1 ]; then
        # Both engines rendezvous on the same address and port, and spell it
        # differently. vLLM additionally wants every rank but 0 told not to serve.
        case "$ENGINE" in
        sglang) dist="--nnodes $NODES_PER_INSTANCE --node-rank $rank --dist-init-addr $leader:${DIST_PORT:-29500}" ;;
        vllm)   dist="--distributed-executor-backend mp --nnodes $NODES_PER_INSTANCE --node-rank $rank --master-addr $leader --master-port ${DIST_PORT:-29500}"
                [ "$rank" = 0 ] || headless="--headless" ;;
        esac
    fi

    local pp_arg=""
    if [ "$PP" -gt 1 ]; then
        case "$ENGINE" in sglang) pp_arg="--pp-size $PP" ;; vllm) pp_arg="--pipeline-parallel-size $PP" ;; esac
    fi

    # {HOST} is this machine's own address, for anything that has to name it.
    # DOCKER_FLAGS is the single place extra container arguments come from -- devices,
    # -e, mounts, whatever this hardware needs. There is deliberately no second
    # variable for environment: two places to set -e is two places to look.
    local docker_flags pre bind
    docker_flags=${DOCKER_FLAGS:-}
    docker_flags=${docker_flags//\{HOST\}/$addr}
    pre=${PRE_START:-}
    pre=${pre//\{HOST\}/$addr}

    # What the engine binds its HTTP port to -- an optional override, not in the
    # examples, which leave it at every interface. The default is every interface, which is
    # what a private network wants and what makes a multi-machine instance work
    # without further thought -- but on a machine whose address is reachable from the
    # internet it publishes an engine that has no authentication of its own, since
    # authentication lives at the gateway. The engine is not behind the gateway; it is
    # beside it.
    #   ENGINE_BIND={HOST}   each engine binds its own data-network address rather
    #                        than every interface. Do NOT assume this keeps it off
    #                        the internet: measured on one Ascend 910B4 site, a
    #                        socket bound to the private data address was reachable
    #                        from the public IP, because the public address is NATed
    #                        onto it. Only loopback was unreachable there. Whether a
    #                        given address is exposed is a property of your network,
    #                        and the only way to know is to bind a throwaway listener
    #                        and try to reach it from outside.
    #   ENGINE_BIND=127.0.0.1  single-machine only, where control and engine are the
    #                        same box. Peers cannot reach a loopback.
    bind=${ENGINE_BIND:-0.0.0.0}
    bind=${bind//\{HOST\}/$addr}
    # A loopback engine is reachable only from its own machine, so the routers must
    # address it as 127.0.0.1 and there can be no second machine. Otherwise it loads
    # for twenty minutes and is then unreachable, with nothing in any log saying why.
    case "$bind" in 127.*|localhost)
        [ "$nhosts" = 1 ] && [ "$addr" = 127.0.0.1 ] \
            || die "ENGINE_BIND=$bind needs exactly one machine, written as 127.0.0.1 in $HOSTS_FILE (as hosts.example has it); got $nhosts machine(s), address $addr" ;;
    esac

    # The engine's own command line. ENGINE_CMD overrides it verbatim, for an image
    # that starts in its own way; the placeholders are the values only render.sh
    # knows -- above all {RANK} and {LEADER}, without which a multi-machine instance
    # cannot be expressed. Everything after this point is the same either way.
    local engine_cmd=""
    if [ -n "${ENGINE_CMD:-}" ]; then
        engine_cmd=$ENGINE_CMD
        engine_cmd=${engine_cmd//\{PORT\}/$ENGINE_PORT}
        engine_cmd=${engine_cmd//\{RANK\}/$rank}
        engine_cmd=${engine_cmd//\{NNODES\}/$NODES_PER_INSTANCE}
        engine_cmd=${engine_cmd//\{LEADER\}/$leader}
        engine_cmd=${engine_cmd//\{DIST_PORT\}/${DIST_PORT:-29500}}
        engine_cmd=${engine_cmd//\{MODEL_NAME\}/$MODEL_NAME}
        engine_cmd=${engine_cmd//\{TP\}/$TP}
        engine_cmd=${engine_cmd//\{PP\}/$PP}
        engine_cmd=${engine_cmd//\{HOST\}/$addr}
        engine_cmd=${engine_cmd//\{BIND\}/$bind}
    else

    case "$ENGINE" in
    sglang)
        engine_cmd="exec python3 -m sglang.launch_server \\
  --model-path /model \\
  --host $bind --port $ENGINE_PORT \\
  --served-model-name $MODEL_NAME \\
  --tp $TP${pp_arg:+ $pp_arg}${dist:+ \\
  $dist} \\
  --enable-metrics \\
  --enable-cache-report \\
  --stream-response-default-include-usage${ENGINE_EXTRA_ARGS:+ \\
  $ENGINE_EXTRA_ARGS}" ;;
    vllm)
        engine_cmd="exec vllm serve /model \\
  --host $bind --port $ENGINE_PORT \\
  --served-model-name $MODEL_NAME \\
  --tensor-parallel-size $TP${pp_arg:+ $pp_arg}${dist:+ \\
  $dist}${headless:+ $headless} \\
  --enable-prompt-tokens-details${ENGINE_EXTRA_ARGS:+ \\
  $ENGINE_EXTRA_ARGS}" ;;
    esac
    fi

    # A fingerprint of everything that defines this container, carried as a label, so a
    # re-run of ./up.sh leaves an engine that is running with this exact spec alone --
    # adding a machine then starts only the new one instead of reloading every instance.
    # For an instance spanning machines the label is the INSTANCE's fingerprint, filled
    # in below once all its ranks are rendered: the ranks share a rendezvous, so they
    # are kept or recreated together, never one alone. up.sh checks every rank of such
    # an instance before starting any of it.
    local spec
    spec=$(printf '%s\n' "$ENGINE_IMAGE" "$MODEL_PATH" "$ROUTE" "$ENGINE" "$docker_flags" "$pre" "$engine_cmd" | cksum | cut -d' ' -f1)
    rank_spec=$spec
    [ "$NODES_PER_INSTANCE" -gt 1 ] && spec=__INSTANCE_SPEC__

    cat > "$OUT/engine-$addr.sh" <<SCRIPT
#!/usr/bin/env bash
# Generated by render.sh -- do not edit. Change .env or hosts and re-run ./up.sh.
#
#   model      $MODEL_NAME on $ENGINE${ENGINE_CMD:+ (command from ENGINE_CMD)}, TP=$TP PP=$PP
#   machine    $addr, rank $rank of $NODES_PER_INSTANCE
#   serves     $([ "$rank" = 0 ] && echo "yes, on :$ENGINE_PORT -- the routers talk to this one" || echo "no -- holds shards, answers nothing")
set -uo pipefail

CLI="${CTR_CLI:-docker}"
NS=""
[ "\$CLI" = "nerdctl" ] && NS="--namespace ${CTR_NAMESPACE:-default}"
NAME="engine-$ROUTE"

[ -d "$MODEL_PATH" ] || { echo "weights not found: $MODEL_PATH"; exit 1; }
# The deploying user's home on that server (/root for root), not a fixed /root.
mkdir -p "\$HOME/.cache-$ROUTE-$ENGINE"

# Unchanged and running: keep it (FORCE_ENGINES=1 recreates it anyway).
SPEC=$spec
if [ "\${FORCE_ENGINES:-0}" != 1 ] && \
   [ "\$(\$CLI \$NS inspect -f '{{.State.Running}} {{index .Config.Labels "modelsphere.engine-spec"}}' "\$NAME" 2>/dev/null)" = "true \$SPEC" ]; then
    echo "\$NAME unchanged and running -- kept"
    exit 0
fi

\$CLI \$NS rm -f "\$NAME" >/dev/null 2>&1

ENGINE_CMD=\$(cat <<'ENGINE_EOF'
$pre
$engine_cmd
ENGINE_EOF
)

# --restart no on purpose. For a single-machine instance a restart would be fine,
# but for a multi-machine one a lone rank coming back waits at a rendezvous nobody
# else is attending: the container looks alive and serves nothing. Restart the
# instance, not the container -- ./down.sh then ./up.sh. (On Kubernetes,
# LeaderWorkerSet does this for you.)
set -x
exec \$CLI \$NS run -d --name "\$NAME" \\
  --label modelsphere.engine-spec=\$SPEC \\
  --restart no \\
  --network host \\
  --ipc=host \\
  --ulimit memlock=-1 --ulimit stack=67108864 \\
  -v "$MODEL_PATH":/model:ro \\
  -v "\$HOME/.cache-$ROUTE-$ENGINE":/root/.cache \\
  $docker_flags \\
  --entrypoint /bin/bash \\
  "$ENGINE_IMAGE" -c "\$ENGINE_CMD"
SCRIPT
    chmod +x "$OUT/engine-$addr.sh"
}

peers=""
workers=""
rank=0
instance=1
leader=""
inst_specs=""; inst_files=""
while read -r target addr; do
    [ -n "${target:-}" ] || continue
    [ -n "$leader" ] || leader=$addr          # first machine of this instance
    render_engine "$target" "$addr" "$rank" "$leader"

    if [ "$rank" = 0 ]; then
        # Only rank 0 serves, so only rank 0 is a peer and a CART worker.
        peers="$peers                    {\"$addr\", $ENGINE_PORT, \"i$instance\", 0, ${MAX_CONCURRENCY:-100}},
"
        workers="$workers  - url: \"http://$addr:$ENGINE_PORT\"
    max_load: ${CART_MAX_LOAD:-50}
"
        echo "$target engine-$addr.sh i$instance rank0-serves:$ENGINE_PORT" >> "$OUT/manifest"
    else
        echo "$target engine-$addr.sh i$instance rank$rank" >> "$OUT/manifest"
    fi

    inst_specs="$inst_specs $rank_spec"; inst_files="$inst_files $OUT/engine-$addr.sh"
    rank=$(( rank + 1 ))
    if [ "$rank" -ge "$NODES_PER_INSTANCE" ]; then
        if [ "$NODES_PER_INSTANCE" -gt 1 ]; then
            # One fingerprint for the instance: any rank's change changes all labels.
            ispec=$(printf '%s\n' $inst_specs | cksum | cut -d' ' -f1)
            for f in $inst_files; do
                sed "s/__INSTANCE_SPEC__/$ispec/" "$f" > "$f.tmp" && mv "$f.tmp" "$f" && chmod +x "$f"
            done
        fi
        inst_specs=""; inst_files=""
        rank=0; leader=""; instance=$(( instance + 1 ))
    fi
done <<< "$hosts"

#################################### the route ####################################
cart_cap=$(( ${MAX_CONCURRENCY:-100} * (instance - 1) ))
# Peers carry a priority and the router uses the highest tier that still has healthy
# members: CART at 1, the engines at 0. A CART that is down or still starting
# therefore costs cache affinity, not the model.
cat > "$OUT/routes/route.conf" <<CONF
# Generated by render.sh from .env + $HOSTS_FILE -- do not edit.
# Shared memory for this route. The names carry the route name.
# None below 1m: nginx allocates shared zones in pages, and on a 64 KiB-page host
# (common on aarch64) a 16k zone fails at startup with "ngx_slab_alloc() failed:
# no memory" and openresty restart-loops.
lua_shared_dict active_conns_$ROUTE 4m;
lua_shared_dict cluster_avg_$ROUTE  1m;
lua_shared_dict lc_locks_$ROUTE     1m;
lua_shared_dict bad_peers_$ROUTE    1m;
lua_shared_dict bodylog_ctl_$ROUTE  1m;
lua_shared_dict cch_ctl_$ROUTE      1m;

server {
    # The image's dispatcher on 8080 forwards /$ROUTE/ here; the socket name must be
    # the route name.
    listen unix:/usr/local/openresty/nginx/sock/$ROUTE.sock;
    # The image's own default is 10m; the same limit as CART, so neither cuts the other.
    client_max_body_size $MAX_BODY;
    server_name _;
    set \$route "$ROUTE";

    set_by_lua_block \$__${ROUTE_VAR}_init {
        _G.register_route("$ROUTE", function()
            return {
                peers = {
                    -- {host, port, name, priority, max_concurrency}
                    -- CART gets probe = "/health" explicitly: its /v1/models is a
                    -- cached endpoint that answers 200 with every worker down, so
                    -- the default probe would keep this peer "healthy" and the route
                    -- would never fall through to the engines below it. The engines
                    -- keep the default probe (/v1/models).
                    -- CART's cap is every instance's worth: it fans out to all of them.
                    {"127.0.0.1", ${CART_PORT:-8071}, "cart", 1, $cart_cap, probe = "/health"},
$peers                },
                -- The master switch for the three load-based 429s (concurrency, TTFT,
                -- decode rate). Off, those requests are let through; the measurements
                -- behind them, health checks and the 503 for an all-down pool still run.
                load_rate_limit      = $RATE_LIMIT,
                ttft_limit_ms        = ${TTFT_LIMIT_MS:-30000},
                tps_limit_tps        = ${TPS_LIMIT_TPS:-20},
                adaptive_cc          = ${ADAPTIVE_CC:-true},
                adaptive_cc_min_frac = ${ADAPTIVE_CC_MIN_FRAC:-0.4},
                -- Off in the engine by default, so a response says nothing about
                -- which instance served it. Useful while bringing a deployment up;
                -- leave it off on anything reachable from outside, since it names
                -- the backend's address.
                expose_routed_peer   = ${EXPOSE_ROUTED_PEER:-false},
            }
        end)
        return ""
    }

    include conf.d/router_locations.inc;
}
CONF

##################################### its CART ####################################
# Only `workers` is required; the rest are the defaults, written out so they are
# visible. SIGHUP reloads this file but accepts ONLY a changed worker list -- any
# other edit is rejected and needs the container restarted.
cat > "$OUT/cart.yaml" <<CONF
# Generated by render.sh from .env + $HOSTS_FILE -- do not edit.
server:
  # Loopback: CART shares the host's network namespace with openresty, which is its
  # only client, so there is no reason for it to answer other machines.
  host: "127.0.0.1"
  port: ${CART_PORT:-8071}

workers:
$workers
cache:
  threshold: 0.3
  match_abs_threshold: 8192
  eviction_interval_secs: 60

health:
  endpoint: "/health"
  interval_secs: 10
  failure_threshold: 3

proxy:
  # Long enough for a long completion; the connect timeout is short so a dead
  # backend fails over in seconds instead of tens of seconds.
  request_timeout_secs: 10000
  connect_timeout_secs: 2
  # A multimodal request carrying inline base64 image or video data easily passes
  # 10 MiB on its own, so the default is 200 MiB. The route above uses the same value.
  max_body_size: $MAX_BODY
CONF

echo "render: /$ROUTE/ -> $(( nhosts / NODES_PER_INSTANCE )) instance(s) of $NODES_PER_INSTANCE machine(s) x $DEVICES_PER_NODE device(s), $ENGINE TP=$TP PP=$PP"
echo "render: generated/{routes/route.conf,cart.yaml,engine-*.sh,manifest}"
