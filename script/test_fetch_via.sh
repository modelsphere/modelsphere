#!/usr/bin/env bash
# Tests for script/fetch_via.sh, the BUNDLE_FETCH_MIRRORS mapping that
# offline_tools.sh and offline_bundle.sh share.
#   bash script/test_fetch_via.sh
set -u
. "$(cd "$(dirname "$0")" && pwd)/fetch_via.sh"
fail=0
check() {
  local got; got=$(fetch_via "$1" 2>/dev/null)
  if [ "$got" = "$2" ]; then printf 'ok   %-42s -> %s\n' "$1" "$got"
  else printf 'FAIL %-42s -> %s (want %s)\n' "$1" "$got" "$2"; fail=1; fi
}

export BUNDLE_FETCH_MIRRORS="docker.io/4pdosc=tcr/4pdosc docker.io=dao registry.k8s.io=k8sdao"
check registry:3                                dao/library/registry:3
check library/registry:3                        dao/library/registry:3
check docker.io/library/registry:3              dao/library/registry:3
check 4pdosc/cart:1                             tcr/4pdosc/cart:1
check docker.io/4pdosc/cart:1                   tcr/4pdosc/cart:1
check bitnami/redis:7                           dao/bitnami/redis:7
check registry.k8s.io/kube-apiserver:v1.36.3    k8sdao/kube-apiserver:v1.36.3
check registry.k8s.io/coredns/coredns:v1.12     k8sdao/coredns/coredns:v1.12
check quay.io/x/y:1                             quay.io/x/y:1
check localhost/a:1                             localhost/a:1
check localhost:5000/a:1                        localhost:5000/a:1
check quay.io/ascend/vllm-ascend@sha256:abc     quay.io/ascend/vllm-ascend@sha256:abc
check ghcr.io/modelsphere/charts/lws            ghcr.io/modelsphere/charts/lws

# The longest rule wins whatever the order.
export BUNDLE_FETCH_MIRRORS="docker.io=dao docker.io/4pdosc=tcr/4pdosc"
check 4pdosc/console:0.2.2                      tcr/4pdosc/console:0.2.2
# A rule must match a whole path segment.
export BUNDLE_FETCH_MIRRORS="docker.io/4pd=x"
check 4pdosc/console:0.2.2                      4pdosc/console:0.2.2
# Rules for OCI chart references.
export BUNDLE_FETCH_MIRRORS="registry.k8s.io=k8s.m.daocloud.io ghcr.io=ghcr.m.daocloud.io"
check registry.k8s.io/lws/charts/lws            k8s.m.daocloud.io/lws/charts/lws
check ghcr.io/prometheus-community/charts/kps   ghcr.m.daocloud.io/prometheus-community/charts/kps
# No rules, and a malformed entry.
export BUNDLE_FETCH_MIRRORS=""
check registry.k8s.io/pause:3.10                registry.k8s.io/pause:3.10
export BUNDLE_FETCH_MIRRORS="nonsense docker.io=dao"
check registry:3                                dao/library/registry:3
[ -n "$(fetch_via registry:3 2>&1 >/dev/null)" ] && echo "ok   malformed entry warned about" || { echo "FAIL malformed entry not warned about"; fail=1; }
exit $fail
