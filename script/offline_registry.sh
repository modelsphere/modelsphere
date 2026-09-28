#!/usr/bin/env bash
# Step 2 of an air-gapped install: stand up the registry that holds everything
# else. One `registry:3` container serves both halves -- images under their
# upstream paths, charts under a prefix of their own.
#
#   script/offline_registry.sh up                      # start it
#   script/offline_registry.sh status                  # is it serving?
#   script/offline_registry.sh down                    # stop it, keep the data
#
# Why one container and not Harbor: Harbor's own offline installer is a
# multi-gigabyte payload with its own database to carry and keep alive, and the
# only thing this step needs is a registry that speaks the v2 API plus OCI --
# which registry:3 does, and which helm and helmfile both speak. registry:3 is
# also what the pull-through caches in registry-mirror/ run, so there is one
# registry version in play and not two. Measured: a
# chart pushed with `helm push oci://` resolves through helmfile exactly as an
# https index does.
#
# ⚠️ Charts MUST keep a path prefix of their own. A chart and an image sharing
#    one OCI path overwrite each other, and the symptom points nowhere near the
#    cause: `helm pull` reports "manifest does not contain minimum number of
#    descriptors".
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The bundle is normally the repo's own offline/, but BUNDLE= may put it
# anywhere -- and then site.env and the registry image travel with it, not with
# the repo.
BUNDLE=${BUNDLE:-$REPO_ROOT/offline}
# The site's own facts, written once (offline/site.env.example). The port is
# taken from REGISTRY so that the registry listens where everything else has
# been told to look.
[ -f "$BUNDLE/site.env" ] && . "$BUNDLE/site.env"
NAME=${NAME:-offline-registry}
# REGISTRY may be unset: site.env is optional, and `set -u` turns a bare
# ${REGISTRY##*:} into an abort before anything runs. The port is also taken
# from the host:port part alone, so a REGISTRY with a path (10.0.0.9:5001/infra)
# does not yield "5001/infra" and silently fall back to a port nothing was told
# to use.
_reg=${REGISTRY:-}
_hostport=${_reg%%/*}
case "$_hostport" in *:*) _port_from_reg=${_hostport##*:} ;; *) _port_from_reg="" ;; esac
PORT=${PORT:-$_port_from_reg}
case "$PORT" in ''|*[!0-9]*) PORT=5000 ;; esac
DATA=${DATA:-/var/lib/offline-registry}
IMAGE_TAR=${IMAGE_TAR:-$BUNDLE/tools/registry.tar}
IMAGE=${IMAGE:-registry:3}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

# docker when the host has it -- a registry an earlier run started with docker
# must stay visible to `status` and `down` -- otherwise nerdctl, which
# `offline_tools.sh install` puts next to the containerd it installs.
# RUNTIME=docker|nerdctl overrides the choice.
runtime() {
  local rt=${RUNTIME:-}
  if [ -z "$rt" ]; then
    if command -v docker >/dev/null 2>&1; then rt=docker
    elif command -v nerdctl >/dev/null 2>&1; then rt=nerdctl
    else echo "no docker or nerdctl on this host -- run step 1 (offline_tools.sh install), which installs nerdctl" >&2; exit 1
    fi
  fi
  command -v "$rt" >/dev/null 2>&1 || { echo "RUNTIME=$rt, but $rt is not on this host" >&2; exit 1; }
  if [ "$rt" = nerdctl ]; then
    # nerdctl 2.x needs containerd >= 1.7. Against docker's bundled 1.6 it gets
    # as far as `load` and dies with "unknown service
    # containerd.services.streaming.v1.Streaming", which names nothing useful.
    local v
    v=$(nerdctl version --format '{{range .Server.Components}}{{if eq .Name "containerd"}}{{.Version}}{{end}}{{end}}' 2>/dev/null)
    v=${v#v}
    [ -n "$v" ] || { echo "nerdctl cannot reach containerd (is it running? CONTAINERD_ADDRESS?)" >&2; exit 1; }
    case "$v" in
      0.*|1.[0-6]|1.[0-6].*|1.[0-6]-*)
        echo "containerd $v is too old for nerdctl (needs 1.7+). Use the containerd from step 1, or RUNTIME=docker." >&2
        exit 1 ;;
    esac
  fi
  echo "$rt"
}

case "${1:-}" in
  up)
    RT=$(runtime)
    if ! $RT image inspect "$IMAGE" >/dev/null 2>&1; then
      [ -f "$IMAGE_TAR" ] || {
        echo "$IMAGE is not loaded and $IMAGE_TAR does not exist." >&2
        echo "It comes from script/offline_tools.sh fetch, not from the bundle." >&2
        exit 1; }
      echo "==> loading $IMAGE from $IMAGE_TAR"
      $RT load -i "$IMAGE_TAR"
    fi
    mkdir -p "$DATA"
    if $RT ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
      echo "==> $NAME exists, starting it"
      $RT start "$NAME" >/dev/null
    else
      # Host networking on purpose: a bridge network is one more thing that can
      # collide with the site's own addressing, and this container has exactly
      # one port to expose.
      echo "==> starting $NAME on :$PORT, data in $DATA"
      $RT run -d --name "$NAME" --restart always --network host \
        -e REGISTRY_HTTP_ADDR=0.0.0.0:$PORT \
        -v "$DATA":/var/lib/registry "$IMAGE" >/dev/null
    fi
    # Plain HTTP on a non-loopback address has to be allowed where something
    # pulls from it, and every refusal reads the same unhelpful way ("server
    # gave HTTP response to HTTPS client"):
    #
    #   containerd  a hosts.toml under certs.d, which is what the kubelet pulls
    #               through.
    #   docker      insecure-registries in /etc/docker/daemon.json -- only when
    #               docker runs this registry, so a `docker pull` on the same
    #               host works too. offline_load.sh pushes with crane, which
    #               needs neither. On a host running nerdctl there is no docker
    #               to configure, and this used to write a daemon.json there anyway.
    #
    # Only done when the registry is addressed by something other than
    # localhost, since that case already works.
    if [ -n "${REGISTRY:-}" ] && [ "${REGISTRY#127.0.0.1}" = "$REGISTRY" ] && [ "${REGISTRY#localhost}" = "$REGISTRY" ]; then
      _hp=${REGISTRY%%/*}
      if [ "$RT" = docker ] && ! docker info 2>/dev/null | grep -q "^  $_hp\$"; then
        echo "==> allowing plain HTTP to $_hp"
        python3 - "$_hp" <<'PY'
import json, os, sys
hp = sys.argv[1]
p = "/etc/docker/daemon.json"
d = {}
if os.path.exists(p):
    # NOT `except: d = {}`. That replaced an unparseable daemon.json -- a
    # trailing comma is enough -- with a file holding only insecure-registries,
    # dropping data-root, exec-opts (the cgroup driver!), registry-mirrors and
    # log-opts, and then the caller restarted docker onto it. Refuse instead:
    # the operator can fix one file, but cannot recover what was overwritten.
    try:
        d = json.load(open(p))
    except Exception as e:
        sys.exit("    %s is not valid JSON (%s) -- refusing to rewrite it.\n"
                 "    Add %s to insecure-registries by hand." % (p, e, hp))
    if not isinstance(d, dict):
        sys.exit("    %s is not a JSON object -- refusing to rewrite it." % p)
ir = d.setdefault("insecure-registries", [])
if hp not in ir:
    ir.append(hp)
    json.dump(d, open(p, "w"), indent=4)
    print("    daemon.json: insecure-registries += %s" % hp)
else:
    print("    daemon.json already lists %s" % hp)
PY
        systemctl reload docker 2>/dev/null || systemctl restart docker
        sleep 3
      fi
      mkdir -p "/etc/containerd/certs.d/$_hp"
      cat > "/etc/containerd/certs.d/$_hp/hosts.toml" <<EOF
server = "http://$_hp"

[host."http://$_hp"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
      echo "    containerd: /etc/containerd/certs.d/$_hp/hosts.toml"
      # The value has to be non-empty: containerd's own generated default
      # carries `config_path = ""`, which means certs.d is NOT consulted, and a
      # bare `grep -q config_path` matches it -- passing exactly when the file
      # just written is inert.
      grep -qE 'config_path[[:space:]]*=[[:space:]]*"[^"]+"' /etc/containerd/config.toml 2>/dev/null \
        || echo "    ⚠️  containerd config.toml has no non-empty registry config_path -- the hosts.toml just written is inert" >&2
      systemctl restart containerd 2>/dev/null || true
    fi

    for _ in $(seq 1 30); do
      code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v2/" || true)
      if [ "$code" = "200" ]; then
        # Say the address the operator chose, not one guessed from the host:
        # `hostname -I` lists every address, and on a GPU node the first is the
        # InfiniBand one, which the other nodes cannot reach. This address gets
        # copied into site.env and kubeadm's --image-repository, so guessing it
        # wrong builds a cluster whose workers cannot pull.
        if [ -n "$_reg" ]; then
          echo "==> serving: http://${_reg%%/*}"
        else
          echo "==> serving on port $PORT, at whichever of these the other nodes can reach:"
          hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sed "s|^|      http://|;s|$|:$PORT|"
          echo "    set REGISTRY in $BUNDLE/site.env to the right one"
        fi
        exit 0
      fi
      sleep 2
    done
    echo "registry did not answer /v2/ within 60s -- check \`$RT logs $NAME\`" >&2
    exit 1 ;;

  status)
    RT=$(runtime)
    $RT ps --filter "name=$NAME" --format '{{.Names}} {{.Status}}' || true
    # curl prints 000 itself on failure; the `|| echo 000` that used to follow
    # appended a second one and reported 000000.
    code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v2/" 2>/dev/null) || true
    code=${code:-000}
    echo "/v2/ -> $code   (200 = serving, 000 = not answering)"
    echo "catalog:"
    curl -s -m 5 "http://127.0.0.1:$PORT/v2/_catalog" || echo "  (no answer)"
    echo ;;

  down)
    RT=$(runtime)
    $RT stop "$NAME" >/dev/null && echo "==> stopped $NAME (data kept in $DATA)" ;;

  *) usage >&2; exit 2 ;;
esac
