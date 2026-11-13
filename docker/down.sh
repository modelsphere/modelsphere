#!/usr/bin/env bash
# Stop the engines and the routing layer.
#
#   ./down.sh                  # everything
#   SKIP_ENGINES=1 ./down.sh   # routing layer only, leave the engines loaded
#   KEEP_ROUTER=1 ./down.sh    # engines only -- the gateway stays up and answers
#                              #  503 for the route until they are back
#
# Engines go down per instance, not per container: the machines of one instance share
# a rendezvous, so stopping one of them leaves the others waiting instead of serving.
set -uo pipefail
cd "$(dirname "$0")"

ENV_FILE=${ENV_FILE:-.env}
GRACE=${GRACE:-60}

[ -f generated/manifest ] || ./render.sh
# Sourcing needs care: a bare name would be looked up in PATH, and "./$name" breaks
# an absolute path. ENV_FILE may be either.
case "$ENV_FILE" in /*|./*|../*) ENV_PATH=$ENV_FILE ;; *) ENV_PATH=./$ENV_FILE ;; esac
set -a; . "$ENV_PATH"; set +a

is_this_machine() {   # is_this_machine <address>: loopback or one of our own IPv4s
    case "$1" in 127.*|localhost) return 0 ;; esac
    ip -4 -o addr show 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' | grep -qxF "$1"
}

if [ "${SKIP_ENGINES:-0}" != "1" ]; then
    while read -r target script instance role; do
        [ -n "${target:-}" ] || continue
        echo "---- stop $instance / $target ($role)"
        # -t: the engine gets that long to finish what it is streaming before it is
        # killed.
        # A target that is this machine runs here, not over ssh to ourselves (see up.sh).
        RUN="ssh ${SSH_OPTS:-} ${SSH_USER:-root}@$target"
        is_this_machine "$target" && RUN="bash -c"
        # shellcheck disable=SC2086
        $RUN \
            "CLI=${CTR_CLI:-docker}; NS=''; [ \"\$CLI\" = nerdctl ] && NS='--namespace ${CTR_NAMESPACE:-default}'; \
             \$CLI \$NS stop -t $GRACE engine-$ROUTE >/dev/null 2>&1; \
             \$CLI \$NS rm -f engine-$ROUTE >/dev/null 2>&1; echo '     removed engine-$ROUTE'" < /dev/null
    done < generated/manifest
fi

if [ "${KEEP_ROUTER:-0}" != "1" ]; then
    echo "---- routing layer"
    # --profile so the listener is removed too when it was started; `down` on its own
    # leaves a profile's container behind and then calls it an orphan.
    docker compose --profile bodylog down
fi
