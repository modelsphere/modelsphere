#!/usr/bin/env bash
# Step 1 of an air-gapped install: the tools, because nothing can be assumed to
# be on the target host -- not helm, not containerd, not even a registry to put
# the rest into.
#
#   script/offline_tools.sh fetch     # online side: download into offline/tools
#   script/offline_tools.sh verify    # either side: is the payload complete?
#   script/offline_tools.sh install   # target side: put the binaries in place
#
# Versions live in offline/versions.env, and are overridable per call:
#   KUBE_VERSION=v1.36.4 script/offline_tools.sh fetch
#
# `install` lays down binaries and systemd units and nothing else -- it does not
# run kubeadm. Making a cluster is a decision with a topology behind it; this
# only makes it possible.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The bundle is normally the repo's own offline/, but BUNDLE= may put it
# anywhere; versions.env, site.env and the tools all travel inside it.
BUNDLE=${BUNDLE:-$REPO_ROOT/offline}
TOOLS=${TOOLS:-$BUNDLE/tools}
# shellcheck disable=SC1091
. "$BUNDLE/versions.env"
# The site's own facts, written once. install needs REGISTRY to stamp
# containerd's sandbox image; fetch does not need it at all.
[ -f "$BUNDLE/site.env" ] && . "$BUNDLE/site.env"

# crane names architectures the way Go's release tooling does, not the way
# Kubernetes does: x86_64 where everything else here says amd64. Everything
# else in the manifest below uses $ARCH directly.
case "$ARCH" in
  amd64) CRANE_ARCH=x86_64 ;;
  *)     CRANE_ARCH=$ARCH ;;
esac

# name|url|kind   kind: bin (chmod +x), tar (unpack on install), image (docker load)
manifest() {
  cat <<EOF
kubeadm|https://dl.k8s.io/release/$KUBE_VERSION/bin/linux/$ARCH/kubeadm|bin
kubelet|https://dl.k8s.io/release/$KUBE_VERSION/bin/linux/$ARCH/kubelet|bin
kubectl|https://dl.k8s.io/release/$KUBE_VERSION/bin/linux/$ARCH/kubectl|bin
runc|https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$ARCH|bin
containerd.tar.gz|https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/containerd-$CONTAINERD_VERSION-linux-$ARCH.tar.gz|tar
cni-plugins.tgz|https://github.com/containernetworking/plugins/releases/download/$CNI_PLUGINS_VERSION/cni-plugins-linux-$ARCH-$CNI_PLUGINS_VERSION.tgz|tar
helm.tar.gz|https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz|tar
helmfile.tar.gz|https://github.com/helmfile/helmfile/releases/download/v$HELMFILE_VERSION/helmfile_${HELMFILE_VERSION}_linux_$ARCH.tar.gz|tar
helm-diff.tgz|https://github.com/databus23/helm-diff/releases/download/$HELM_DIFF_VERSION/helm-diff-linux-$ARCH.tgz|tar
crane.tar.gz|https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/go-containerregistry_Linux_$CRANE_ARCH.tar.gz|tar
nerdctl.tar.gz|https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_VERSION/nerdctl-$NERDCTL_VERSION-linux-$ARCH.tar.gz|tar
containerd.service|https://raw.githubusercontent.com/containerd/containerd/v$CONTAINERD_VERSION/containerd.service|unit
kubelet.service|https://raw.githubusercontent.com/kubernetes/release/$KUBE_RELEASE_TOOLS/cmd/krel/templates/latest/kubelet/kubelet.service|unit
10-kubeadm.conf|https://raw.githubusercontent.com/kubernetes/release/$KUBE_RELEASE_TOOLS/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf|unit
EOF
}

case "${1:-}" in
  fetch)
    command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }
    mkdir -p "$TOOLS"
    echo "==> tools -> $TOOLS"
    while IFS='|' read -r name url _; do
      [ -z "$name" ] && continue
      # Idempotent: a partial download is the thing you least want to carry to a
      # site with no way to re-fetch, so an existing non-empty file is kept and
      # a failed one is removed rather than left behind.
      # Keyed on the version, not just the filename. `have kubeadm` was true
      # for a kubeadm fetched at any version, so KUBE_VERSION=v1.36.4 (which
      # this script's own header advertises) kept the old binary while
      # regenerating kubeadm-images.txt for the new one -- a payload whose
      # binaries and control-plane images disagree, reported as missing=0.
      _stamp="$TOOLS/.versions/$name"
      _want=$(printf '%s' "$url" | md5sum 2>/dev/null | cut -d' ' -f1 || printf '%s' "$url" | md5)
      if [ -s "$TOOLS/$name" ] && [ "$(cat "$_stamp" 2>/dev/null)" = "$_want" ]; then
        echo "    have $name"; continue
      fi
      if [ -s "$TOOLS/$name" ]; then
        echo "    re-fetching $name -- its source URL changed (a version bump)" >&2
      fi
      printf '    %-22s' "$name"
      if curl -fsSL -o "$TOOLS/$name.part" "$url"; then
        mv "$TOOLS/$name.part" "$TOOLS/$name"
        mkdir -p "$TOOLS/.versions" && printf '%s' "$_want" > "$_stamp"
        echo "$(du -h "$TOOLS/$name" | cut -f1)"
      else
        rm -f "$TOOLS/$name.part"; echo "FAILED  $url" >&2
      fi
    done < <(manifest)

    # The registry image is a tool, not a workload: step 2 cannot start without
    # it, and there is nothing to pull it from once you are on site.
    # docker when the fetch host has it, as before; otherwise crane, whose
    # default tarball is the same docker-archive shape and loads with either
    # `docker load` or `nerdctl load`. The fetch host no longer needs docker.
    if [ ! -s "$TOOLS/registry.tar" ]; then
      echo "    registry image ($REGISTRY_IMAGE)"
      # BUNDLE_FETCH_MIRRORS, the same variable offline_bundle.sh takes: a build
      # host that reaches a pull-through cache but crawls to Docker Hub fetches
      # this one image the same way as the other seventy. Measured: registry:3
      # direct from Docker Hub on such a host runs at a few KB/s, while the
      # internal cache serves it in seconds -- and a bundle without this image
      # cannot be loaded at all, because there is nothing to load it into.
      _src=$REGISTRY_IMAGE
      for _m in ${BUNDLE_FETCH_MIRRORS:-}; do
        case "$REGISTRY_IMAGE" in
          "${_m%%=*}"/*) _src="${_m#*=}/${REGISTRY_IMAGE#"${_m%%=*}"/}"; break ;;
          # An unqualified name is docker.io, which is how REGISTRY_IMAGE is
          # written (`registry:3`, not `docker.io/library/registry:3`).
          *) case "${_m%%=*}" in
               docker.io) case "$REGISTRY_IMAGE" in */*) ;; *) _src="${_m#*=}/library/$REGISTRY_IMAGE"; break ;; esac ;;
             esac ;;
        esac
      done
      [ "$_src" = "$REGISTRY_IMAGE" ] || echo "      via $_src"
      if command -v crane >/dev/null 2>&1; then
        _plat=${BUNDLE_PLATFORMS:-linux/amd64}
        _ins=""; [ "${BUNDLE_FETCH_INSECURE:-}" = true ] && _ins="--insecure"
        if crane pull --platform "${_plat%%,*}" $_ins "$_src" "$TOOLS/registry.tar.part"; then
          # The tarball carries the name it was fetched under, and a mirror's
          # name is not the one the target runs: loaded as
          # <cache>/library/registry:3, `docker run registry:3` finds nothing.
          # So put the canonical name back before it leaves this host.
          python3 - "$TOOLS/registry.tar.part" "$REGISTRY_IMAGE" <<'RETAG'
import io, json, os, sys, tarfile
src, want = sys.argv[1], sys.argv[2]
tmp = src + ".retag"
with tarfile.open(src) as t:
    mf = json.loads(t.extractfile("manifest.json").read())
    for e in mf:
        e["RepoTags"] = [want]
    with tarfile.open(tmp, "w") as o:
        for m in t.getmembers():
            if m.name == "manifest.json":
                data = json.dumps(mf).encode()
                m.size = len(data)
                o.addfile(m, io.BytesIO(data))
            else:
                o.addfile(m, t.extractfile(m) if m.isfile() else None)
os.replace(tmp, src)
RETAG
          mv "$TOOLS/registry.tar.part" "$TOOLS/registry.tar"
        else
          rm -f "$TOOLS/registry.tar.part"
        fi
      elif command -v docker >/dev/null 2>&1; then
        docker pull -q "$REGISTRY_IMAGE" >/dev/null && docker save "$REGISTRY_IMAGE" -o "$TOOLS/registry.tar"
      else
        echo "    registry image NOT saved: neither docker nor crane on this host" >&2
      fi
    fi

    # kubeadm names its own control-plane images, and they are NOT in the
    # helmfile render -- the bundle derives its image list from charts, and
    # kube-apiserver belongs to no chart. Ask the kubeadm we just downloaded
    # rather than keeping a list by hand.
    if [ -s "$TOOLS/kubeadm" ]; then
      chmod +x "$TOOLS/kubeadm"
      if "$TOOLS/kubeadm" config images list --kubernetes-version "$KUBE_VERSION" \
           > "$TOOLS/kubeadm-images.txt" 2>/dev/null; then
        echo "    kubeadm images: $(grep -c . "$TOOLS/kubeadm-images.txt") listed"
        # Listing them is not carrying them. These belong to no chart, so
        # offline_bundle.sh -- which saves what the render names -- never sees
        # them, and an air-gapped kubeadm init would find nothing to pull.
        # crane, into OCI layouts -- the same shape offline_bundle.sh produces
        # and the only one offline_load.sh can push. This half was left on
        # `docker pull` + `docker save` when the rest moved to crane, and the
        # two then disagreed about both format and location: load looked for
        # <bundle>/images/<name>/oci-layout while this wrote
        # <tools>/images/<name>.tar, so every control-plane image was reported
        # MISSING and skipped, and an air-gapped kubeadm init had nothing to
        # pull -- which is the one thing the tool bundle exists to prevent.
        if command -v crane >/dev/null 2>&1; then
          mkdir -p "$TOOLS/images"
          ka_saved=0; ka_failed=0
          while read -r img; do
            [ -z "$img" ] && continue
            d="$TOOLS/images/$(echo "$img" | tr '/:@' '___')"
            [ -f "$d/oci-layout" ] && { ka_saved=$((ka_saved+1)); continue; }
            rm -rf "$d.part"
            if crane pull --format=oci --platform "${BUNDLE_PLATFORMS:-linux/amd64}" "$img" "$d.part" >/dev/null 2>&1; then
              rm -rf "$d"; mv "$d.part" "$d"; ka_saved=$((ka_saved+1))
            else
              rm -rf "$d.part"; ka_failed=$((ka_failed+1))
              echo "      COPY FAILED: $img" >&2
            fi
          done < "$TOOLS/kubeadm-images.txt"
          echo "    kubeadm images saved: $ka_saved, failed: $ka_failed"
          [ "$ka_failed" -gt 0 ] && echo "    ^ an air-gapped kubeadm init cannot pull what is missing" >&2
        else
          echo "    kubeadm images NOT saved: no crane on this host. It is in this" >&2
          echo "    same payload -- run `install` first, then fetch again." >&2
        fi
      else
        rm -f "$TOOLS/kubeadm-images.txt"
        echo "    kubeadm images: NOT LISTED (kubeadm would not run here)" >&2
      fi
    fi
    "$0" verify ;;

  verify)
    miss=0
    while IFS='|' read -r name _ _; do
      [ -z "$name" ] && continue
      if [ -s "$TOOLS/$name" ]; then printf '  OK   %-22s %s\n' "$name" "$(du -h "$TOOLS/$name" | cut -f1)"
      else printf '  MISS %s\n' "$name"; miss=$((miss+1)); fi
    done < <(manifest)
    for extra in registry.tar kubeadm-images.txt; do
      if [ -s "$TOOLS/$extra" ]; then printf '  OK   %-22s %s\n' "$extra" "$(du -h "$TOOLS/$extra" | cut -f1)"
      else printf '  MISS %s\n' "$extra"; miss=$((miss+1)); fi
    done
    # The kubeadm images themselves, not just the list naming them. verify used
    # to check only the list, and reported missing=0 over an empty images/
    # directory -- the one shape that makes an air-gapped kubeadm init fail.
    if [ -s "$TOOLS/kubeadm-images.txt" ]; then
      while read -r img; do
        [ -z "$img" ] && continue
        d="$TOOLS/images/$(echo "$img" | tr '/:@' '___')"
        if [ -f "$d/oci-layout" ]; then printf '  OK   %-22s %s\n' "$(basename "$d" | cut -c1-22)" "$(du -sh "$d" | cut -f1)"
        else printf '  MISS %s (kubeadm)\n' "$img"; miss=$((miss+1)); fi
      done < "$TOOLS/kubeadm-images.txt"
    fi
    echo "  missing=$miss"
    [ "$miss" -eq 0 ] ;;

  install)
    [ "$(id -u)" = 0 ] || { echo "install needs root" >&2; exit 1; }
    "$0" verify >/dev/null || { echo "payload incomplete -- run verify" >&2; exit 1; }
    install -m0755 "$TOOLS/kubeadm" "$TOOLS/kubelet" "$TOOLS/kubectl" /usr/local/bin/
    install -m0755 "$TOOLS/runc" /usr/local/sbin/runc
    tar -C /usr/local -xzf "$TOOLS/containerd.tar.gz"
    mkdir -p /opt/cni/bin && tar -C /opt/cni/bin -xzf "$TOOLS/cni-plugins.tgz"
    tmp=$(mktemp -d)
    tar -C "$tmp" -xzf "$TOOLS/helm.tar.gz" && install -m0755 "$tmp"/*/helm /usr/local/bin/helm
    tar -C "$tmp" -xzf "$TOOLS/helmfile.tar.gz" && install -m0755 "$tmp"/helmfile /usr/local/bin/helmfile
    rm -rf "$tmp"

    # crane: the loader moves images with it rather than docker, so the bundle
    # keeps the manifests it was built from -- digests included.
    tmp2=$(mktemp -d)
    tar -C "$tmp2" -xzf "$TOOLS/crane.tar.gz" crane 2>/dev/null && install -m0755 "$tmp2/crane" /usr/local/bin/crane
    rm -rf "$tmp2"

    # nerdctl: what step 2 (offline_registry.sh) runs the registry with when
    # the host has no docker. It talks to the containerd installed above.
    tmp3=$(mktemp -d)
    tar -C "$tmp3" -xzf "$TOOLS/nerdctl.tar.gz" nerdctl && install -m0755 "$tmp3/nerdctl" /usr/local/bin/nerdctl
    rm -rf "$tmp3"

    # helm-diff, which `helmfile apply` and `helmfile diff` both shell out to.
    # `make helm-deps` installs it by cloning GitHub, which an air-gapped site
    # cannot do -- and that is the whole documented path for step 7, so without
    # this `make helm-deps` (README step 1) stops with a git error. Unpacked rather than
    # installed through `helm plugin install`: the release tarball already holds
    # the built binary, while the plugin hook it would run is not in the tarball
    # at all, so that path errors out (and still leaves a working plugin, which
    # is worse -- a non-zero exit nobody should have to interpret).
    plugins=$(helm env HELM_PLUGINS 2>/dev/null | tr -d '"')
    plugins=${plugins:-$HOME/.local/share/helm/plugins}
    mkdir -p "$plugins" && tar -C "$plugins" -xzf "$TOOLS/helm-diff.tgz"

    # The units ship separately from the binaries they start: containerd's
    # release tarball holds bin/ and nothing else, and kubelet has no unit of
    # its own at all. Installing only the binaries leaves a host where nothing
    # starts -- which is what this step used to do while its own comment
    # claimed otherwise.
    install -m0644 "$TOOLS/containerd.service" /usr/local/lib/systemd/system/containerd.service 2>/dev/null \
      || { mkdir -p /etc/systemd/system && install -m0644 "$TOOLS/containerd.service" /etc/systemd/system/containerd.service; }
    install -m0644 "$TOOLS/kubelet.service" /etc/systemd/system/kubelet.service
    mkdir -p /etc/systemd/system/kubelet.service.d
    install -m0644 "$TOOLS/10-kubeadm.conf" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

    # kubeadm refuses a containerd whose cgroup driver is not systemd, and the
    # default config does not set it. Generated rather than shipped, because the
    # default differs between containerd versions.
    # `-s`, not `-f`: a previous run that died here -- containerd refusing to
    # start on an old glibc, or an interrupted install -- left a zero-byte
    # config.toml behind, created by the redirection before containerd ran. The
    # next run then said "exists, left alone", SystemdCgroup was never set, and
    # kubeadm refused the node with a config nobody had written.
    if [ ! -s /etc/containerd/config.toml ]; then
      mkdir -p /etc/containerd
      # Into a temp file first, so a failure cannot leave an empty one in place.
      _cfg=$(mktemp)
      if ! /usr/local/bin/containerd config default > "$_cfg" 2>/dev/null || [ ! -s "$_cfg" ]; then
        rm -f "$_cfg"
        echo "    ⚠️  containerd could not print a default config -- not writing one" >&2
        echo "       (an old glibc is the usual cause; see offline/versions.env)" >&2
        exit 1
      fi
      mv "$_cfg" /etc/containerd/config.toml
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
        && echo "    /etc/containerd/config.toml written (SystemdCgroup = true)" \
        || echo "    ⚠️  could not set SystemdCgroup in /etc/containerd/config.toml" >&2
    else
      echo "    /etc/containerd/config.toml exists, left alone"
    fi

    # The sandbox image is the third address nobody thinks of. It is neither
    # helm's (`registry:`) nor kubeadm's (`--image-repository`): containerd
    # holds it as a literal, asks for it by that name, and without a mirror --
    # which this flow deliberately does not use -- an air-gapped node cannot
    # pull it. Every pod then sits in ContainerCreating while kubeadm's own
    # images are all present, which points nowhere near the cause.
    #
    # The version is read from the kubeadm list rather than chosen, so it is
    # the pause the bundle already carries and the one kubeadm's preflight
    # expects to see.
    stamp_sandbox() {
      local reg=$1 pause_ver cfg=/etc/containerd/config.toml
      pause_ver=$(awk -F: '/\/pause:/{print $NF}' "$TOOLS/kubeadm-images.txt" 2>/dev/null)
      [ -n "$pause_ver" ] || { echo "    ⚠️  no pause version in kubeadm-images.txt -- sandbox image left alone" >&2; return 1; }
      if grep -q 'pinned_images' "$cfg"; then
        # containerd 2.x: [plugins."io.containerd.cri.v1.images".pinned_images] sandbox = "..."
        sed -i "/pinned_images/,/^\s*\[/ s#^\( *sandbox *= *\).*#\1\"$reg/pause:$pause_ver\"#" "$cfg"
      elif grep -q 'sandbox_image' "$cfg"; then
        # containerd 1.x
        sed -i "s#^\( *sandbox_image *= *\).*#\1\"$reg/pause:$pause_ver\"#" "$cfg"
      else
        echo "    ⚠️  neither pinned_images nor sandbox_image in $cfg -- check it by hand" >&2; return 1
      fi
      grep -qE "sandbox(_image)? *= *\"$reg/pause:$pause_ver\"" "$cfg" \
        && echo "    sandbox image -> $reg/pause:$pause_ver" \
        || { echo "    ⚠️  sandbox image NOT set -- check $cfg" >&2; return 1; }
    }
    if [ -n "${REGISTRY:-}" ]; then
      stamp_sandbox "$REGISTRY" || true
    else
      echo "    ⚠️  REGISTRY unset (offline/site.env) -- containerd will ask an"
      echo "        upstream registry for its sandbox image, which an air-gapped"
      echo "        node cannot answer. Set it and re-run, or edit config.toml." >&2
    fi

    systemctl daemon-reload
    systemctl enable --now containerd
    systemctl enable kubelet     # started by kubeadm, not here

    echo "==> installed:"
    for b in kubeadm kubelet kubectl helm helmfile containerd runc crane nerdctl; do
      printf '    %-10s %s\n' "$b" "$(command -v $b || echo MISSING)"
    done
    printf '    %-10s %s\n' containerd.svc "$(systemctl is-active containerd)"
    printf '    %-10s %s\n' kubelet.svc "$(systemctl is-enabled kubelet 2>/dev/null)"
    echo
    echo "Not installed here, and needed on GPU nodes: nvidia-container-toolkit."
    echo "It is distro packages rather than a binary, so it does not fit this"
    echo "shape -- carry the .deb/.rpm set separately." ;;

  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
