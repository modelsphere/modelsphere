#!/usr/bin/env bash
# Load an offline bundle into the registry and chart repo of an air-gapped
# cluster. The other half of script/offline_bundle.sh.
#
#   script/offline_load.sh /mnt/usb/bundle \
#       --registry harbor.internal/infra \
#
# Run this on the target side, where the internal registry IS reachable and the
# internet is not. It does not talk to the cluster either -- it only fills the
# two addresses that environments/<name>.yaml then points helmfile at.
#
# ⚠️ The retag rule here and the addresses in the *-offline-images.yaml.gotmpl
#    files are the same rule written twice, and they have to stay that way:
#
#        <registry>/<upstream path>
#
#    quay.io/cilium/cilium  ->  <registry>/cilium/cilium
#
#    The upstream host is dropped. It was kept at first to stop images that
#    share a path on different hosts from colliding, but measured against the
#    real list that case does not arise: all 71 addresses stay distinct without
#    it, and every org in the list comes from exactly one host. Should a chart
#    ever move registry without changing its path, two internal copies would
#    collide silently -- so check for that when bumping charts.
#
#    An image already under <registry> is left alone rather than prefixed
#    again: our own images arrive as <registry>/autoconfig already, and
#    re-prefixing would push them to a nested path nothing ever pulls.
#
#    If you change this layout, change it in both places in the same commit --
#    a mismatch is silent until a pod cannot pull.
set -euo pipefail

BUNDLE=""
SOURCE_REGISTRY=""
# The site's own facts, written once (offline/site.env.example), so --registry
# is only needed to override it.
_ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$_ROOT/offline/site.env" ] && . "$_ROOT/offline/site.env"
REGISTRY=${REGISTRY:-}
DRY_RUN=false

usage() {
  cat <<'USAGE'
usage: script/offline_load.sh <bundle-dir> --registry <prefix>

  <bundle-dir>        the directory script/offline_bundle.sh produced
  --registry <p>      image prefix to push to, e.g. harbor.internal/infra
                      (this is the value environments/<name>.yaml sets as `registry`)
  --source-registry <p>
                      the `registry` value the bundle was BUILT with, e.g.
                      registry.example.com/team. Our own images carry it as
                      their prefix and the charts render them as
                      <registry>/<name>, so that whole prefix is replaced, not
                      just the host. Read from the bundle MANIFEST when omitted.
  --dry-run           print what would be pushed, change nothing

  Charts are NOT uploaded anywhere: they travel as .tgz and helmfile installs
  them from disk -- see chartsDir in environments/default.yaml.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --registry)   REGISTRY="${2:?--registry needs a value}"; shift 2 ;;
    --source-registry) SOURCE_REGISTRY="${2:?--source-registry needs a value}"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    *)            BUNDLE="$1"; shift ;;
  esac
done
# A bundle kept somewhere other than the repo's own offline/ carries its
# site.env with it, so look there too before giving up on REGISTRY.
if [ -z "$REGISTRY" ] && [ -n "$BUNDLE" ] && [ -f "$BUNDLE/site.env" ]; then
  . "$BUNDLE/site.env"
  REGISTRY=${REGISTRY:-}
fi
[ -n "$BUNDLE" ] && [ -n "$REGISTRY" ] || { usage >&2; exit 2; }
[ -d "$BUNDLE" ] || { echo "no such bundle directory: $BUNDLE" >&2; exit 1; }
[ -f "$BUNDLE/images.txt" ] || { echo "$BUNDLE has no images.txt -- not a bundle" >&2; exit 1; }

# The source registry decides how our own images are renamed, so a wrong or
# missing value is not a detail: it silently produces addresses one path segment
# away from what the cluster will ask for.
if [ -z "$SOURCE_REGISTRY" ] && [ -f "$BUNDLE/MANIFEST" ]; then
  SOURCE_REGISTRY=$(awk '/^source_registry:/{print $2}' "$BUNDLE/MANIFEST")
fi
# `unknown` is what offline_bundle.sh writes when it could not read the value
# off the render (it tolerates that failure). It is not empty, so it used to
# pass the guard below, and then matched nothing: our own images fell through
# to the host-stripping branch and were pushed as <registry>/<project>/x
# instead of <registry>/x -- one path segment away from what the cluster asks
# for, which is the silent mismatch this whole block exists to prevent.
[ "$SOURCE_REGISTRY" = unknown ] && SOURCE_REGISTRY=""
if [ -z "$SOURCE_REGISTRY" ]; then
  echo "no --source-registry given and none usable in $BUNDLE/MANIFEST." >&2
  echo "Pass the \`registry\` value the bundle was built with." >&2
  exit 2
fi
[ "$SOURCE_REGISTRY" = "$REGISTRY" ] || echo "==> our own images: $SOURCE_REGISTRY/<name> -> $REGISTRY/<name>"

echo "==> bundle contents"
[ -f "$BUNDLE/MANIFEST" ] && sed 's/^/    /' "$BUNDLE/MANIFEST"

# --------------------------------------------------------------------- images
IMAGES=$(grep -c . "$BUNDLE/images.txt" || true)
echo "==> images: $IMAGES listed"
# An empty images.txt is only an error when there is nothing else to load. It
# used to exit here unconditionally, which made the kubeadm block below
# unreachable for a bundle that carries only the control-plane images -- dead
# code that looked fine because the usual bundle has both.
if [ "$IMAGES" -eq 0 ] && [ ! -f "$BUNDLE/tools/kubeadm-images.txt" ]; then
  echo "    images.txt is empty and there are no kubeadm images either --" >&2
  echo "    the bundle was built wrong, refusing" >&2
  exit 1
fi

# Only the real push needs docker. --dry-run exists to show what the retag rule
# would produce, which is exactly the thing you want to check on a laptop that
# has no docker at all -- requiring it here made that impossible.
if [ "$DRY_RUN" = false ]; then
  command -v crane >/dev/null || {
    echo "crane not found. It ships in the bundle: script/offline_tools.sh install" >&2
    echo "puts it in /usr/local/bin." >&2; exit 1; }
fi

# An offline registry usually has no certificate. crane calls that --insecure
# (it means "plain HTTP or an untrusted cert here"), and the value is read the
# same way the chart push reads it -- a literal false must mean false.
case "${PLAIN_HTTP:-true}" in
  false|no|0|"") CRANE_INSECURE="" ;;
  *)             CRANE_INSECURE="--insecure" ;;
esac

# A bundle built before the move to crane holds *.tar from `docker save`, and
# every image in it would come back as MISSING one line at a time -- sixty-odd
# times, with nothing saying why. Name the actual problem once, up front.
if [ "$DRY_RUN" = false ] && [ -d "$BUNDLE/images" ]; then
  _tars=0; _ocis=0
  for _f in "$BUNDLE"/images/*.tar;   do [ -f "$_f" ] && _tars=$((_tars+1)); done
  for _d in "$BUNDLE"/images/*/;      do [ -f "$_d/oci-layout" ] && _ocis=$((_ocis+1)); done
  if [ "$_tars" -gt 0 ] && [ "$_ocis" -eq 0 ]; then
    echo "This bundle holds $_tars *.tar files and no OCI layouts: it was built by an" >&2
    echo "older offline_bundle.sh, which used \`docker save\`. This loader moves images" >&2
    echo "with crane and reads OCI layouts (MANIFEST says image_format: oci)." >&2
    echo "Rebuild it: script/offline_bundle.sh -o <dir> -e <env>" >&2
    exit 2
  fi
fi

# Where containerd asks a mirror for an image: host stripped, rest of the path
# kept. Under registryMode: mirror nothing rewrites the address, so this is the
# only name that works -- and for the images we build it is NOT the name the
# rewrite rule produces, because that one replaces the whole source prefix
# (registry.example.com/team/autoconfig -> <registry>/autoconfig, where a
# mirror asks for <registry>/<project>/autoconfig). Measured across a real
# 69-image list: 57 names agree, 12 -- every image we build -- do not.
_mirror_path() {
  _b=${1%@sha256:*}
  case "$_b" in
    */*)
      _h=${_b%%/*}
      case "$_h" in
        *.*|*:*|localhost) printf '%s\n' "${_b#*/}" ;;
        *)                 printf '%s\n' "$_b" ;;
      esac ;;
    *) printf '%s\n' "library/$_b" ;;
  esac
}

loaded=0; pushed=0; skipped=0; failed=0
while read -r img; do
  [ -z "$img" ] && continue
  case "$img" in */*:*) ;; *) skipped=$((skipped+1)); continue ;; esac

  dir="$BUNDLE/images/$(echo "$img" | tr '/:@' '___')"

  # Same rule as the *-offline-images.yaml.gotmpl files, and it has two halves:
  #
  #   ours       <source-registry>/autoconfig  ->  <registry>/autoconfig
  #   upstream   quay.io/cilium/cilium         ->  <registry>/cilium/cilium
  #
  # Ours keep no path of their own, because the charts render them as
  # `{{ .Values.registry }}/<name>` -- so the WHOLE source prefix goes, host and
  # project both. Stripping only the host pushed them to
  # <registry>/<project>/autoconfig, one segment away from the address the
  # cluster asks for; that mismatch is invisible until a pod cannot pull, and it
  # only appears when the target registry differs from the source one.
  # The target carries the tag, not the digest. images.txt holds canonical refs
  # for the four cilium images -- `:v1.20.0@sha256:...`, which is how the chart
  # writes them -- and a destination cannot be both. Pushing to the tag is
  # right: the layout crane stored keeps the original manifest, so the image
  # answers to its digest in the target registry as well, and both the tag the
  # cluster asks for today and the digest a mirror would ask for resolve.
  #
  # A reference with a digest and NO tag leaves nothing to name the target
  # with, and it would land on :latest -- a tag nothing asks for. No chart here
  # pins that way today; one upstream bump makes it live, so it is refused
  # rather than silently renamed.
  case "$img" in
    *@sha256:*)
      _no_digest=${img%@sha256:*}
      case "$_no_digest" in
        */*:*) : ;;
        *)
          echo "    DIGEST-ONLY: $img has no tag -- pushing it would publish :latest" >&2
          echo "      and leave the digest the chart pins absent. Skipping." >&2
          skipped=$((skipped+1)); continue ;;
      esac ;;
  esac
  src_ref=${img%@sha256:*}
  # Match on the address with docker.io stripped. The render normalises our own
  # images to docker.io/4pdosc/<name> -- a docker.io short name written out in
  # full -- and the source-registry branch below looks for `4pdosc/`, which no
  # longer matches. Measured on a default-environment bundle: every component we
  # build got the mirror name and NOT <registry>/<name>, which is the one
  # registryMode: rewrite renders, so every one of them would have been an
  # ImagePullBackOff on a cluster with nothing to fetch from.
  _bare=${src_ref#docker.io/}
  case "$_bare" in
    "$REGISTRY"/*)
      target="$_bare" ;;                       # already where it needs to be
    "$SOURCE_REGISTRY"/*)
      target="$REGISTRY/${_bare#"$SOURCE_REGISTRY"/}" ;;
    *.*/*|*:*/*)
      target="$REGISTRY/${_bare#*/}" ;;        # strip the leading <host>/
    *)
      target="$REGISTRY/$_bare" ;;             # no host segment to strip
  esac

  mirror_target="$REGISTRY/$(_mirror_path "$src_ref")"
  if [ "$DRY_RUN" = true ]; then
    echo "    would push: $img -> $target"
    [ "$mirror_target" != "$target" ] && echo "    would push: $img -> $mirror_target (mirror name)"
    continue
  fi

  if [ ! -f "$dir/oci-layout" ]; then
    echo "    MISSING: no OCI layout at $dir -- skipping $img" >&2
    skipped=$((skipped+1))
    continue
  fi

  # crane push, not docker load/tag/push. The bundle holds the manifest the
  # image was published with, index and all, and this puts it back byte for
  # byte -- so an image a chart pins by digest resolves in the target registry
  # under that same digest. The docker path rewrote it (measured: a 17-entry
  # index came back as one manifest with a different digest), which is why
  # cni/overrides.yaml.gotmpl has to set useDigest: false on sixteen cilium
  # images. That workaround can go once every bundle is built this way.
  #
  # It also removes three special cases the docker path needed: a digest-only
  # reference that docker would publish as :latest, a canonical ref that
  # `docker tag` refuses, and an image loaded with no name at all.
  if crane push "$dir" "$target" $CRANE_INSECURE > /tmp/.push_out.$$ 2>&1; then
    loaded=$((loaded+1)); pushed=$((pushed+1))
  else
    echo "    PUSH FAILED: $target" >&2
    tail -2 /tmp/.push_out.$$ | sed 's/^/      /' >&2
    failed=$((failed+1))
  fi
  # And under the mirror name when that is a different one, so the bundle does
  # not have to know which mode the cluster will use -- same reasoning as the
  # kubeadm images below. The blobs are already here, so this uploads a
  # manifest and nothing else.
  if [ "$mirror_target" != "$target" ]; then
    if crane push "$dir" "$mirror_target" $CRANE_INSECURE > /tmp/.push_out.$$ 2>&1; then
      pushed=$((pushed+1))
    else
      echo "    PUSH FAILED: $mirror_target (mirror name)" >&2
      tail -2 /tmp/.push_out.$$ | sed 's/^/      /' >&2
      failed=$((failed+1))
    fi
  fi
  rm -f /tmp/.push_out.$$
done < "$BUNDLE/images.txt"

if [ "$DRY_RUN" = false ]; then
  echo "    loaded=$loaded pushed=$pushed skipped=$skipped failed=$failed"
  if [ "$skipped" -gt 0 ]; then
    echo "    ^ skipped entries are NOT in the registry. An apply will fail on" >&2
    echo "      them; add them to the bundle rather than pushing by hand." >&2
  fi
  # A push that failed used to print its line and leave the exit code at 0, so a
  # registry that was down, unauthenticated or misspelled produced a full screen
  # of FAILED lines, the "Next, in environments/..." success text underneath,
  # and `make offline-load` reporting success. The gap then surfaced on site as
  # ImagePullBackOff -- the exact failure this pair exists to prevent.
  if [ "$failed" -gt 0 ]; then
    echo "    ^ $failed image(s) did not reach $REGISTRY. Fix and re-run: the" >&2
    echo "      load is idempotent, already-pushed layers are skipped." >&2
    exit 1
  fi
fi

# ------------------------------------------------------------- kubeadm images
# The distribution's own control-plane images are not in images.txt: that list
# is derived from a helm render, and kube-apiserver belongs to no chart. They
# also do NOT follow the host-stripping rule -- kubeadm asks for exactly what
# `kubeadm config images list --image-repository <registry>` prints, and for
# coredns that is <registry>/coredns, while stripping the host from
# registry.k8s.io/coredns/coredns would give <registry>/coredns/coredns. One
# segment apart, and the cluster never comes up.
#
# So the names are not computed here. kubeadm is asked for both lists and they
# are paired line by line, which is only valid if they are the same length --
# checked, because a silent mismatch would push images under names nothing
# pulls.
KUBEADM_LIST="$BUNDLE/tools/kubeadm-images.txt"
KUBEADM_BIN="$BUNDLE/tools/kubeadm"
if [ ! -f "$KUBEADM_LIST" ]; then
  # Silence here is expensive: the list lives in offline/tools/, which
  # offline_tools.sh fetch fills and offline_bundle.sh does not, so a bundle
  # built into its own directory has no kubeadm images and used to say nothing
  # at all. The operator finds out when `kubeadm init` cannot pull
  # kube-apiserver, in the room with no network.
  echo "==> kubeadm control-plane images: none ($KUBEADM_LIST absent)" >&2
  echo "    kubeadm init will have nothing to pull from $REGISTRY. They come" >&2
  echo "    from script/offline_tools.sh fetch, into offline/tools/." >&2
fi
if [ -f "$KUBEADM_LIST" ]; then
  echo "==> kubeadm control-plane images"
  if [ ! -x "$KUBEADM_BIN" ]; then
    echo "    $KUBEADM_BIN is not executable -- cannot ask it for the target names" >&2
    echo "    (run script/offline_tools.sh fetch, which puts it there)" >&2
    exit 1
  fi
  KV=$(awk -F: '/kube-apiserver/{print $NF}' "$KUBEADM_LIST")
  "$KUBEADM_BIN" config images list --kubernetes-version "$KV" \
      --image-repository "$REGISTRY" > /tmp/.kubeadm_target.$$ 2>/dev/null || {
    echo "    kubeadm would not list images for $KV" >&2; exit 1; }
  # `|| true` on both: grep exits 1 on an empty file, and under `set -e` that
  # killed the script right after printing the section header, with no line
  # saying why. L107 had it right; this pair did not.
  n_src=$(grep -c . "$KUBEADM_LIST" || true); n_dst=$(grep -c . /tmp/.kubeadm_target.$$ || true)
  if [ "$n_src" -ne "$n_dst" ]; then
    echo "    list lengths differ ($n_src vs $n_dst) -- refusing to pair them" >&2
    rm -f /tmp/.kubeadm_target.$$; exit 1
  fi
  ka_ok=0; ka_bad=0
  while read -r src && read -r dst <&3; do
    [ -z "$src" ] && continue
    # These come from offline_tools.sh, which puts them under tools/images --
    # they are not in the render, so offline_bundle.sh never sees them. Falls
    # back to the bundle's own images/ for a bundle built the other way round.
    _n=$(echo "$src" | tr '/:@' '___')
    dir="$BUNDLE/tools/images/$_n"
    [ -f "$dir/oci-layout" ] || dir="$BUNDLE/images/$_n"
    if [ "$DRY_RUN" = true ]; then
      echo "    would push: $src -> $dst"
      _mir="$REGISTRY/${src#*/}"
      [ "$_mir" != "$dst" ] && echo "    would push: $src -> $_mir (mirror name)"
      continue
    fi
    if [ ! -f "$dir/oci-layout" ]; then
      echo "    MISSING: no OCI layout at $dir -- skipping $src" >&2; ka_bad=$((ka_bad+1)); continue
    fi
    if crane push "$dir" "$dst" $CRANE_INSECURE > /tmp/.push_out.$$ 2>&1; then ka_ok=$((ka_ok+1))
    else
      echo "    PUSH FAILED: $dst" >&2
      tail -2 /tmp/.push_out.$$ | sed 's/^/      /' >&2
      ka_bad=$((ka_bad+1))
    fi
    # And again under the host-stripped name, when that is a different one.
    # The two offline modes ask for these by different names: with
    # registryMode: rewrite the cluster is created with
    # `kubeadm --image-repository <registry>` and asks for <registry>/coredns,
    # while under mirror kubeadm asks registry.k8s.io for coredns/coredns and
    # containerd rewrites the HOST only, leaving the path -- <registry>/coredns
    # would be a 404 and the cluster never comes up.
    #
    # Pushing both is cheaper than choosing: the blobs are already in the
    # registry, so the second push uploads a manifest and nothing else, and one
    # bundle then serves either mode. Choosing at load time means a bundle that
    # is silently wrong for the mode somebody picks a week later.
    ka_mirror="$REGISTRY/${src#*/}"
    if [ "$ka_mirror" != "$dst" ]; then
      if crane push "$dir" "$ka_mirror" $CRANE_INSECURE > /tmp/.push_out.$$ 2>&1; then
        echo "    + $ka_mirror (the name a mirror asks for)"
      else
        echo "    PUSH FAILED: $ka_mirror" >&2
        tail -2 /tmp/.push_out.$$ | sed 's/^/      /' >&2
        ka_bad=$((ka_bad+1))
      fi
    fi
    rm -f /tmp/.push_out.$$
  done < "$KUBEADM_LIST" 3</tmp/.kubeadm_target.$$
  rm -f /tmp/.kubeadm_target.$$
  [ "$DRY_RUN" = false ] && echo "    pushed=$ka_ok failed=$ka_bad"
fi

# --------------------------------------------------------------------- charts
# Nothing to do. The charts travel as .tgz files and helmfile installs them
# from disk: environments/default.yaml sets chartsDir, and a chart found there
# is used instead of one from a repository. Uploading them into a registry was
# a whole moving part -- a path prefix so charts and images did not overwrite
# each other, helm's separate credential store, Harbor's /api/charts endpoint
# versus an OCI push -- to hand back files the site already has.
CHARTS=0
for _c in "$BUNDLE"/charts/*.tgz; do [ -f "$_c" ] && CHARTS=$((CHARTS+1)); done
echo "==> charts: $CHARTS tarballs in $BUNDLE/charts, installed from there"
echo "    (not uploaded anywhere: point chartsDir at that directory)"

cat <<EOF

Everything is in the registry under both names it can be asked for. Pick how
the cluster asks -- either mode works against what was just pushed.

A. registryMode: rewrite -- helm writes every address under the registry.

    # environments/<your-cluster>.yaml
    registry: $REGISTRY
    chartsDir: $BUNDLE/charts
    registryMode: rewrite

    # creating the cluster: the control-plane images are not helm's to rewrite
    kubeadm init --image-repository $REGISTRY          # or imageRepository: in
                                                       # the kubeadm config file
    k3s server --system-default-registry $REGISTRY

B. registryMode: mirror -- addresses stay upstream, the NODES redirect. Leave
   \`registry\` pointing wherever your own images are named, and configure
   containerd on every node, including the ones kubeadm runs on:

    # environments/<your-cluster>.yaml
    chartsDir: $BUNDLE/charts
    registryMode: mirror

    # every node, before kubeadm init
    make setup-offline-node REGISTRY=$REGISTRY MODE=<mirror|rewrite> BUNDLE=<this bundle>

   Charts come from the .tgz files either way: helm does not go through
   containerd, so a mirror would do nothing for a chart.

Then, on a host that can reach the cluster:

    helmfile -f helmfile.yaml.gotmpl -e <your-cluster> diff

Under A, check the diff shows every image under $REGISTRY before applying;
anything still naming quay.io, nvcr.io, ghcr.io or registry.k8s.io is a
component this bundle missed -- see the "What it does not cover" note in
offline_bundle.sh. Under B those hosts are expected in the diff, and what to
check instead is that each one has a /etc/containerd/certs.d entry on the node:
an image whose host is missing there is the same gap, one layer down.
EOF
