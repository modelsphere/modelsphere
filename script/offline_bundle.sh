#!/usr/bin/env bash
# Build an offline bundle: every chart and every image this helmfile installs,
# in one directory that can be carried to a cluster with no outbound network.
#
#   script/offline_bundle.sh -e <cluster> -o /tmp/bundle
#   script/offline_load.sh /tmp/bundle          # on the other side
#
# Run this where the internet IS reachable. It does not talk to the cluster.
#
# "Reachable" has two halves that are configured separately, and each fails
# differently. Behind a proxy:
#
#   dockerd   /etc/systemd/system/docker.service.d/http-proxy.conf, then
#             `systemctl restart docker` -- the daemon does the pulling, so the
#             shell's own HTTPS_PROXY does nothing for it.
#   helm      HTTPS_PROXY in this script's environment. helm does not read
#             docker's config, and an OCI chart pull that cannot reach its
#             registry fails silently -- no message at all, just a non-zero exit.
#
# registry.k8s.io redirects to *.pkg.dev, so a host that reaches the first and
# not the second looks like it is online and is not.
#
# The image list is DERIVED, never written by hand: the charts are rendered with
# registryMode: upstream and the addresses are read out of the result. A
# hand-kept list
# drifts from the values files the first time a chart is bumped, and the way you
# find out is a pod stuck on ImagePullBackOff in an air-gapped room.
#
# What it does not cover, on purpose:
#   - images referenced by workloads rather than by this helmfile (inference
#     engines, anything under gateway-api/);
#   - components whose chart values leave them disabled. Rendering only sees
#     what is switched on, so turning a feature on later means rebuilding the
#     bundle. cilium is the one exception, rendered separately below: it is off
#     in every environment because it is installed before helmfile runs, and an
#     air-gapped cluster needs its CNI before it needs anything else here.
set -euo pipefail

ENVIRONMENT=default
OUT=""
SKIP_IMAGES=false
EXTRA=()        # passed through to every helmfile invocation, see --set

usage() {
  cat <<'USAGE'
usage: script/offline_bundle.sh -o <dir> [-e <environment>] [--charts-only]

  -o <dir>        where to build the bundle (required; created if absent)
  -e <env>        helmfile environment to render (default: default)

A bundle is NOT built for a particular cluster's registry. `default` renders the
public addresses -- 4pdosc for what we build, the real upstream host for
everything else -- and offline_load.sh puts them wherever the site's registry
is. Rendering a cluster whose `registry` is private bakes that prefix into the
image list instead, and the second
name each image is pushed under (the one a mirror asks for) would then be
<registry>/<project>/<name>, which is wrong for any cluster that keeps the
public `registry` value -- which is the case registryMode: mirror exists for.

⚠️ Three of our charts are not published publicly yet (alert-webhook,
condition2taint, llm-canary-operator), so the chart half of a `default` render
needs the internal repo until they are:

  script/offline_bundle.sh -o /tmp/bundle \
      --set chartRepo=https://charts.example.com/team

That changes where CHARTS come from and nothing about the image addresses.
  --set k=v       passed to helmfile as --state-values-set; repeatable
  --charts-only   skip the image copy, write the image list only

The bundling host has to supply the target environment's cluster facts, because
the environment files do not carry them: node names and disk paths are not in
the environment file, while bodylog and bodylog-exporter hard-fail at
template time without llmGateway.node and llmGateway.hostPath. Rendering is how
the image list is derived, so a render that stops there produces no bundle:

  script/offline_bundle.sh -o /tmp/bundle -e wlcb \
      --set llmGateway.node=<a node in that cluster> \
      --set llmGateway.hostPath=/mnt/disk0/bodylog-sinks \
      --set alertWebhook.urls.WEBHOOK_URL=<that cluster's alert target>

alert-webhook is the same shape and was missing from this list: wlcb enables it
and no environment file carries its urls, so a render without that --set stops
before any image is collected. Switching it off instead (--set
enabled.alertWebhook=false) builds a bundle that quietly lacks its two images.

Produces:
  <dir>/charts/*.tgz     every chart, at the version the environment pins
  <dir>/images.txt       one image address per line, derived from the render
  <dir>/images/<name>/   an OCI layout per image, copied with crane so the
                         manifest -- and the digest charts pin -- is unchanged
  <dir>/mirror-hosts.txt every upstream host in that list, for the mirror mode
                         that leaves image addresses alone

Environment:
  BUNDLE_PLATFORMS       platforms to fetch for, default linux/amd64. An image
                         the charts pin by digest ignores this and keeps its
                         full index -- stripping it would change the digest.
  BUNDLE_FETCH_MIRRORS   space-separated upstream=replacement pairs, used ONLY
                         to fetch; images are stored under their real names.
                         For a build host that reaches a registry through a
                         pull-through cache, since crane does not read
                         /etc/docker/daemon.json. e.g.
                             BUNDLE_FETCH_MIRRORS="docker.io=docker.1ms.run"
  BUNDLE_FETCH_INSECURE  true to allow plain HTTP when fetching through a
                         mirror above. Never applied to an upstream address.
  DOCKER_CONFIG          where crane looks for registry credentials.
  <dir>/MANIFEST         what was built, from what, when
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -e) ENVIRONMENT="$2"; shift 2 ;;
    --set) EXTRA+=(--state-values-set "$2"); shift 2 ;;
    --charts-only) SKIP_IMAGES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { usage >&2; exit 2; }

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

# One build per output directory -- two concurrent runs corrupt each other
# silently. docs/offline-install.md, "One build per output directory".
mkdir -p "$OUT"
LOCK="$OUT/.lock"
# mkdir, not flock: flock does not exist on macOS. The pid inside makes a lock
# left by a killed run recoverable rather than permanent.
if mkdir "$LOCK" 2>/dev/null; then
  echo $$ > "$LOCK/pid"
else
  _holder=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$_holder" ] && kill -0 "$_holder" 2>/dev/null; then
    echo "another build (pid $_holder) is already writing $OUT -- refusing." >&2
    echo "Two runs share the image directories and corrupt each other: measured," >&2
    echo "two crane processes wrote one .part directory and both appended to the" >&2
    echo "same log. Neither failed; the bundle was simply wrong." >&2
    exit 1
  fi
  echo "==> taking over a lock left by pid ${_holder:-?}, which is no longer running"
  echo $$ > "$LOCK/pid"
fi
trap 'rm -rf "$LOCK"' EXIT

command -v helmfile >/dev/null || { echo "helmfile not found" >&2; exit 1; }
command -v helm     >/dev/null || { echo "helm not found" >&2; exit 1; }

mkdir -p "$OUT/charts" "$OUT/images"

echo "==> rendering $ENVIRONMENT with registryMode: upstream (upstream addresses)"
RENDER="$OUT/.render.yaml"
# Every render re-runs `helm repo add --force-update` for six public chart
# repositories, which on a build host behind a slow proxy is most of the time a
# render takes -- and one run died there outright, on helm.cilium.io, after the
# images were already on disk. The indexes do not change between a failed run
# and the retry, so try with --skip-deps first and only pay for the refresh
# when that fails (a first run on a host with no repos added, or a chart whose
# version moved).
SKIP_DEPS=--skip-deps
# Values that every cluster must set and no cluster shares: the environment
# files guard them and stop a render that has none, which is right for a deploy
# and wrong here -- a bundle is built before any of them is known, and not one
# of them changes which images a release asks for. A site's own values still win,
# since EXTRA comes after these.
RENDER_PLACEHOLDERS=(
  --state-values-set cilium.k8sServiceHost=bundle.invalid
  --state-values-set llmGateway.node=bundle.invalid
  --state-values-set llmGateway.hostPath=/bundle
)

render_with() {
  helmfile -f helmfile.yaml.gotmpl -e "$ENVIRONMENT" \
    --state-values-set registryMode=upstream \
    --state-values-set cilium.serviceMonitors=false \
    "${RENDER_PLACEHOLDERS[@]}" \
    ${EXTRA[@]+"${EXTRA[@]}"} \
    ${1:+"$1"} template --skip-tests
}
# cilium.serviceMonitors=false on every render here, not just the dedicated one
# below. The cilium chart hard-fails at template time when it is asked for
# ServiceMonitors and monitoring.coreos.com/v1 is not among the capabilities,
# which is always the case for a plain `template` -- no cluster is being asked.
# That used to be somebody else's problem because enabled.cilium was false; the
# day it defaulted to true, every bundle build died on it. No image is lost:
# a ServiceMonitor is a CR and carries none.
# registryMode: upstream on purpose. The bundle has to contain the images at their
# UPSTREAM addresses -- those are what `docker pull` can fetch here, and
# offline_load.sh applies the same rewrite the values files do when it pushes.
if ! render_with "$SKIP_DEPS" > "$RENDER" 2>"$OUT/.render.err"; then
  echo "    render with --skip-deps failed; retrying with a repo refresh"
  SKIP_DEPS=""
  if ! render_with "" > "$RENDER" 2>"$OUT/.render.err"; then
    echo "render FAILED -- the bundle would be incomplete, refusing to continue" >&2
    tail -20 "$OUT/.render.err" >&2
    exit 1
  fi
fi
echo "    rendered $(wc -l < "$RENDER" | tr -d ' ') lines"

# ─────────────────────────────────────────────────────────────────── cilium
# enabled.cilium is false in environments/default.yaml: cilium is a bootstrap
# concern, installed bare before this helmfile can usefully run. That is a
# deploy-order decision, not a packaging one -- an air-gapped cluster needs the
# CNI FIRST, so the bundle has to carry it even though the main render omits it.
#
# Rendered separately, with serviceMonitors off: the chart hard-fails at
# template time when it asks for ServiceMonitors and monitoring.coreos.com/v1
# is not among the capabilities, which is the case for a plain `template`.
echo "==> rendering cilium separately (off in the environment, needed offline)"
CILIUM_RENDER="$OUT/.cilium.yaml"
if helmfile -f helmfile.yaml.gotmpl -e "$ENVIRONMENT" \
     --state-values-set registryMode=upstream \
     "${RENDER_PLACEHOLDERS[@]}" \
     --state-values-set enabled.cilium=true \
     --state-values-set cilium.serviceMonitors=false \
     ${EXTRA[@]+"${EXTRA[@]}"} \
     ${SKIP_DEPS:+"$SKIP_DEPS"} \
     -l name=cilium template --skip-tests > "$CILIUM_RENDER" 2>"$OUT/.cilium.err"; then
  echo "    rendered $(wc -l < "$CILIUM_RENDER" | tr -d ' ') lines"
else
  echo "cilium render FAILED -- an air-gapped cluster cannot install its CNI" >&2
  echo "from this bundle, so the bundle is not usable. Refusing to continue." >&2
  tail -20 "$OUT/.cilium.err" >&2
  exit 1
fi

# ──────────────────────────────────────────────────── what did NOT get rendered
# A release switched off for this run contributes no objects, so its images are
# absent from the list -- and nothing said so. alert-webhook is the live
# example: it hard-fails at template time unless webhook.urls is supplied, so
# it gets disabled to make the bundle build, and the bundle then quietly lacks
# its two images. Name them instead of letting the count come up short.
echo "==> collecting images from the render"
# Images do NOT all live on an `image:` key. Measured against a full wlcb
# render, four shapes carry them, and three of those are not pod specs at all
# -- they are inputs an operator reads and pulls from later, so a pod-spec-only
# scrape ships a bundle that passes every check and still deadlocks offline:
#
#   1. image: <full address>                     ordinary pod specs
#   2. repository: + image: + version:/tag:      gpu-operator's ClusterPolicy
#   3. a full address as a plain scalar value    rook's csi ConfigMap, the
#                                                network-operator's env vars,
#                                                prometheus-operator's --flags
#   4. the same, inside a container env `value:`
#
# CustomResourceDefinition documents are scraped for shapes 1-2 only. Their
# `description:` prose cites example addresses ("such as quay.io/ceph/ceph:<tag>",
# "For example, quay.io/ceph/nvmeof:1.5") and scraping those puts an image in
# the bundle that nothing installs -- one of them is a literal `<tag>`.
python3 - "$RENDER" "$CILIUM_RENDER" "$OUT/images.txt" <<'PY'
import re, sys

renders, dest = sys.argv[1:-1], sys.argv[-1]

# A pullable address: a dotted host (or host:port), a path, and a tag, a digest,
# or BOTH. cilium writes `quay.io/cilium/cilium:v1.20.0@sha256:383968...` --
# tag and digest together -- and an either/or pattern silently matches none of
# it. That dropped all four cilium images while the totals still agreed with
# themselves (66 from the main render, 66 after adding cilium's), so nothing
# looked wrong. The angle brackets of a documentation placeholder still fail
# this on purpose.
ADDR = re.compile(
    r'^(?P<host>[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:\d+)?)'
    r'/[A-Za-z0-9._\-/]+'
    r'(:[A-Za-z0-9._\-]+)?(@sha256:[0-9a-f]{64})?$')

def _has_version(tok):
    """Reject a bare repository: the regex above now makes both parts optional."""
    path = tok.split('/', 1)[1] if '/' in tok else ''
    return '@sha256:' in tok or ':' in path

# An image reference with no registry host is an implicit docker.io one, and a
# single-segment name lives under library/: `busybox:1.37` is
# `docker.io/library/busybox:1.37`. The ADDR pattern demands a dotted host, so
# these matched nothing and were dropped without being counted or reported --
# alert-webhook's init container is exactly that, and it went missing from the
# list in silence. Expanded here so the bundle holds what a cluster will pull.
SHORT = re.compile(r'^[a-z0-9]+(?:[._-][a-z0-9]+)*'
                   r'(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*'
                   r'(?::[A-Za-z0-9._-]+)?(?:@sha256:[0-9a-f]{64})?$')

def expand_short(tok):
    """docker.io-relative reference -> its full address, or None."""
    if not SHORT.match(tok):
        return None
    name = tok.split('@')[0]
    if ':' in name.rsplit('/', 1)[-1]:
        name = name.rsplit(':', 1)[0]
    if '.' in name.split('/')[0] or ':' in name.split('/')[0]:
        return None                      # already carries a registry host
    prefix = 'docker.io/library/' if '/' not in name else 'docker.io/'
    return prefix + tok

def addr(tok):
    tok = tok.strip().strip('"').strip("'").rstrip(',')
    if ADDR.match(tok) and _has_version(tok):
        return tok
    return None

# Same shape as ADDR but with the tag optional. Such an address IS pullable --
# omitting the tag means `:latest`, which is exactly how
# `ghcr.io/.../sriov-network-metrics-exporter` reaches a cluster, as a bare env
# value. What it is not is pinned: whatever `latest` points at when the bundle
# is built may not be what the cluster would have pulled. Bundling it silently
# would therefore decide a version on the chart's behalf, so it is reported
# instead and left to a deliberate choice. Restricted to hosts that appeared on
# a tagged image so that apiVersion strings (monitoring.coreos.com/v1) are not
# mistaken for registries.
NOTAG = re.compile(r'^(?P<host>[a-z0-9.\-]+\.[a-z]{2,}(:\d+)?)/[A-Za-z0-9._\-/]+$')

images, untagged = set(), set()
os_suffixed = set()   # ClusterPolicy kernel-module images, see shape 2 below
scalars = []          # (host-bearing token, source path) seen without a tag
per_render = {}       # path -> how many addresses it YIELDED (not how many
                      # it added: a render whose images another render already
                      # carries contributes zero new ones and is still fine.
                      # cilium is rendered twice on purpose -- see below -- and
                      # counting new images made the guard below abort a good
                      # bundle the moment enabled.cilium became true by default.)

for path in renders:
    yielded = 0
    kind = None
    lines = open(path, errors='replace').read().split('\n')
    for i, line in enumerate(lines):
        if line.startswith('---'):
            kind = None
            continue
        m = re.match(r'^kind:\s*(\S+)', line)
        if m:
            kind = m.group(1)
            continue
        in_crd = (kind == 'CustomResourceDefinition')

        # shape 1
        m = re.match(r'^\s*-?\s*image:\s*(\S.*)$', line)
        if m:
            raw = m.group(1).strip().strip('"').strip("'").rstrip(',')
            # A ClusterPolicy writes the name half of a repository/image/version
            # triple as a bare `image: driver`, which is a short name by shape
            # and nothing by itself. Expanding those invents addresses that
            # exist nowhere -- measured, fifteen of them. Shape 2 below
            # assembles the triples properly.
            #
            # Gated on the document kind rather than on finding a sibling
            # repository:, because vgpuManager has no repository at all (the
            # chart ships it empty) and slipped through that test as
            # docker.io/library/vgpu-manager. Every image: in a ClusterPolicy
            # is half of a triple; a full address there would still be caught
            # by addr() above.
            a = addr(raw)
            if not a and kind != 'ClusterPolicy':
                # Only here, never in shapes 3 and 4: those scan every token on
                # a line, where an apiVersion (monitoring.coreos.com/v1) or an
                # annotation key (app.kubernetes.io/name) has the same shape as
                # a short name and would be swept in by the hundred.
                a = expand_short(raw)
            if a:
                images.add(a)
                yielded += 1
                continue

        # shape 2: repository + sibling image + sibling version/tag
        m = re.match(r'^(\s*)repository:\s*(\S+)\s*$', line)
        if m:
            ind, repo = m.group(1), m.group(2).strip('"')
            name = ver = None
            # Stop at the end of the block. Scanning ten lines regardless walks
            # into the NEXT component -- every component in a ClusterPolicy has
            # its keys at the same indent -- and assembles an address out of one
            # component's repository and another's image/version, which exists
            # nowhere and is then pulled as if it had been derived.
            for j in range(i + 1, min(i + 10, len(lines))):
                raw = lines[j]
                if not raw.strip() or raw.strip().startswith('#'):
                    continue
                cur = len(raw) - len(raw.lstrip())
                if cur < len(ind):
                    break                      # dedent: the block ended
                mm = re.match(r'^(\s*)(image|version|tag):\s*(\S+)\s*$', raw)
                if not mm or len(mm.group(1)) != len(ind):
                    continue
                k, v = mm.group(2), mm.group(3).strip('"')
                if k == 'image' and name is None:
                    name = v
                elif k in ('version', 'tag') and ver is None:
                    ver = v
            cand = '%s/%s:%s' % (repo, name, ver) if name and ver else \
                   ('%s:%s' % (repo, ver) if ver and not name else None)

            # The kernel-module components of a ClusterPolicy do not carry a
            # complete address. Their `version` is a base version only; the
            # operator appends the node's OS at run time, so the real tag is
            # 580.126.20-ubuntu22.04, v2.5.2-rhcos4.16 and so on. Measured
            # against NGC: nvidia/driver has 7533 tags and not one of them is
            # the bare version, likewise gdrdrv (167) and nvidia-fs (253).
            # Assembling the three fields here therefore invents an address
            # that exists nowhere, and the bundle fails on it.
            #
            # Filtering on `enabled` instead does NOT work, measured: driver
            # renders enabled=true (it is held off by the node label
            # nvidia.com/gpu.deploy.driver=pre-installed, not by the chart),
            # while dcgm and nodeStatusExporter render enabled=false yet share
            # addresses that other, enabled components pull.
            comp = None
            for j in range(i - 1, max(i - 40, -1), -1):
                cm = re.match(r'^(\s*)([A-Za-z][A-Za-z0-9]*):\s*$', lines[j])
                if cm and len(cm.group(1)) < len(ind):
                    comp = cm.group(2)
                    break
            if comp in ('driver', 'gdrcopy', 'gds') and cand:
                os_suffixed.add('%s  (component %s)' % (cand, comp))
                continue

            a = addr(cand) if cand else None
            if a:
                images.add(a)
                yielded += 1
            else:
                untagged.add(repo)
            continue

        if in_crd:
            continue   # prose below this point; see the note above

        # shapes 3 and 4: a full address as a scalar, an env value, or a
        # --flag=<address>. Take the last '=' separated field so that
        # `- --prometheus-config-reloader=quay.io/...:v0.92.1` resolves.
        for tok in re.findall(r'[A-Za-z0-9._\-/:@]+', line.split('#')[0]):
            cand = tok.split('=')[-1].strip().strip('"').strip("'").rstrip(',')
            a = addr(cand)
            if a:
                images.add(a)
                yielded += 1
            elif NOTAG.match(cand):
                scalars.append(cand)

    per_render[path] = yielded

# A scalar with no tag counts only when its host actually serves images in this
# render. Derived rather than hardcoded: an apiVersion (monitoring.coreos.com/v1)
# has the shape of an address, and the thing that separates it from a registry
# is that no tagged image ever came from that host.
hosts = {x.split('/')[0] for x in images}
untagged |= {s for s in scalars if s.split('/')[0] in hosts}

with open(dest, 'w') as fh:
    for x in sorted(images):
        fh.write(x + '\n')

print("    %d distinct images" % len(images))
if os_suffixed:
    print("    NOTE: %d ClusterPolicy kernel-module images were NOT bundled."
          % len(os_suffixed))
    print("          Their `version` is a base version; the operator appends")
    print("          the node's OS at run time, so no complete address exists")
    print("          in the render. The GPU nodes of every cluster here run")
    print("          Ubuntu 22.04, making the suffix -ubuntu22.04 (one Kylin")
    print("          a V10 node is the exception). Mirror these by")
    print("          hand, at the suffix their nodes call for, before")
    print("          enabling them:")
    for u in sorted(os_suffixed):
        print("            %s" % u)

if untagged:
    print("    NOTE: %d addresses name no version and were NOT bundled."
          % len(untagged))
    print("          They are still pullable -- no tag means :latest -- but")
    print("          bundling one would pin a version on the chart's behalf,")
    print("          so the choice is left to you. Push each into the internal")
    print("          registry by hand before whatever uses it is enabled:")
    for u in sorted(untagged):
        print("            %s" % u)
if not images:
    sys.exit("extraction found nothing -- the extractor is broken, not the render")

# Per render, not just in total. A render that carries `image:` lines and yields
# nothing is a broken extractor, and checking only the combined set hides it
# behind whichever render did work: cilium contributed 0 of its 4 images while
# the total stayed at 66 and every count agreed with itself.
for path, n in per_render.items():
    if n:
        continue
    with open(path, errors='replace') as fh:
        has_image_lines = any(re.match(r'^\s*-?\s*image:\s*\S', l) for l in fh)
    if has_image_lines:
        sys.exit("%s has image: lines but yielded no addresses -- the extractor "
                 "does not understand a shape in it" % path)
PY

COUNT=$(grep -c . "$OUT/images.txt" || true)
[ "$COUNT" -gt 0 ] || exit 1

echo "==> pulling charts"
# Same versions the environment pins: ask helmfile rather than re-deriving them.
#
# enabled.cilium=true for the same reason the render above sets it: the bundle
# carries the CNI even though the environment installs it before helmfile runs.
# Without it the bundle ends up holding cilium's images and not its chart, which
# fails only on the far side, where nothing can be downloaded to repair it.
#
# The failure output is kept. It used to go to /dev/null under `|| true`, which
# left the python below reporting "could not read the release list" with the
# actual reason discarded.
if ! helmfile -f helmfile.yaml.gotmpl -e "$ENVIRONMENT" \
     "${RENDER_PLACEHOLDERS[@]}" \
       --state-values-set registryMode=upstream \
       --state-values-set enabled.cilium=true \
       --state-values-set cilium.serviceMonitors=false \
       ${EXTRA[@]+"${EXTRA[@]}"} \
       list --output json > "$OUT/.releases.json" 2>"$OUT/.releases.err"; then
  echo "could not list releases -- charts cannot be pulled:" >&2
  tail -20 "$OUT/.releases.err" >&2
  exit 1
fi

# `if !` rather than a bare call: with `set -e` a non-zero exit here ends the
# run at this line with no further output, which reads as the script simply
# stopping after the chart list. Measured -- a build died exactly so,
# the log's last entry the FAILED chart and nothing saying the run was over.
if ! python3 - "$OUT/.releases.json" "$OUT/charts" <<'PY'
import json, subprocess, sys, os
path, dest = sys.argv[1], sys.argv[2]
try:
    releases = json.load(open(path))
except Exception as e:
    print("    could not read the release list (%s); charts not pulled" % e)
    print("    this is a failure, not an empty result -- fix it before shipping")
    sys.exit(1)
# Which releases are switched off, while the list is already open. A disabled
# release contributes no objects, so its images are absent from the bundle and
# nothing said so -- alert-webhook is the live example, disabled to make the
# build run at all.
off = [r for r in releases if str(r.get("installed")).lower() != "true"
       and r.get("name") != "cilium"]          # cilium is rendered separately
if off:
    print("    %d release(s) are switched off for this run. Their images are NOT"
          % len(off))
    print("    in the bundle; a cluster that later enables one has nothing to pull:")
    for r in off:
        print("      %-24s chart %s" % (r.get("name"), r.get("chart")))

seen, failed, have = set(), [], 0
for r in releases:
    chart, version = r.get("chart"), r.get("version")
    if not chart or (chart, version) in seen:
        continue
    seen.add((chart, version))
    # A chart already in the directory is left alone. That makes a re-run cheap,
    # and it is the only way to finish a bundle whose last chart cannot be
    # reached from this host: fetch that one .tgz elsewhere, drop it in, run
    # again. Without this the re-run pulls it afresh, fails again, and the
    # advice to "drop it in" is simply untrue.
    if version and os.path.exists(os.path.join(dest, "%s-%s.tgz" % (chart.split("/")[-1], version))):
        have += 1
        continue
    cmd = ["helm", "pull", chart, "--destination", dest]
    if version:
        cmd += ["--version", version]
    if subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
        failed.append("%s@%s" % (chart, version))
print("    %d charts pulled, %d already present, %d failed" % (
      len(seen) - len(failed) - have, have, len(failed)))
for f in failed:
    print("      FAILED %s" % f)
if failed:
    sys.exit(1)
PY
then
  echo "a chart could not be pulled, so the bundle would be missing a release on" >&2
  echo "the far side, where nothing can be downloaded to repair it. Refusing to" >&2
  echo "continue. Fetch that chart on a host that can reach it, drop the .tgz into" >&2
  echo "$OUT/charts, and run this again -- charts already there are kept." >&2
  exit 1
fi

# This environment's `registry` -- the prefix our own images are named with. It
# is needed twice: in the MANIFEST, and above, to write the second spelling of
# the images a model's chart pins. Computed here, before either, because a
# version of this that computed it only at the end left that second spelling
# empty and the bundle silently short.
SOURCE_REGISTRY=$(helmfile -f "$REPO_ROOT/helmfile.yaml.gotmpl" -e "$ENVIRONMENT" \
                    ${EXTRA[@]+"${EXTRA[@]}"} build 2>/dev/null \
                  | awk '/^ +registry: /{print $2; exit}' || true)
[ -n "$SOURCE_REGISTRY" ] || echo "    ⚠️  could not read the environment's registry -- MANIFEST will say unknown," >&2
[ -n "$SOURCE_REGISTRY" ] || echo "       and offline_load.sh will need --source-registry" >&2

# The engine charts. A model release only exists when someone passes a file of
# `models:` entries on the command line (MODELS=), and a bundle is built before
# anyone knows which models the site will run -- so pull them at the versions
# `versions:` pins, like every other chart here.
#
# Measured: without them, README step 8 installed the model from a
# copy an earlier run had left in ~/.cache/helm, and would have failed on a node
# without that leftover -- the "works here, breaks in the room with no network"
# failure a bundle exists to prevent.
python3 - "$OUT/charts" <<'PY' | while read -r _n _v; do
import sys, yaml
try:
    d = yaml.safe_load(open("environments/default.yaml")) or {}
except Exception as e:
    sys.exit(0)
# The engines are pinned in `versions:` with every other chart -- there is no
# separate list of them to drift from it.
v = d.get("versions") or {}
for name in ("sglang", "vllm"):
    if v.get(name):
        print("%s %s" % (name, v[name]))
PY
  [ -z "$_n" ] && continue
  if [ -f "$OUT/charts/$_n-$_v.tgz" ]; then
    echo "    engine chart: have $_n-$_v.tgz"
  elif helm pull "modelsphere/$_n" --version "$_v" --destination "$OUT/charts" >/dev/null 2>&1; then
    echo "    engine chart: pulled $_n-$_v.tgz"
  else
    echo "    engine chart: FAILED to pull $_n $_v -- a cluster that declares" >&2
    echo "    this engine will have no chart for it and cannot fetch one" >&2
  fi
done

img_failed=0
# Inference engine images. They are not helmfile releases -- each workload
# installs its own from the sglang/vllm charts -- so no render names them and no
# rule can infer which ones a site runs. The list is written by hand
# (offline/engine-images.txt, copied from the .example) and is optional: a
# bundle for the platform stack alone is a legitimate thing to build.
#
# ⚠️ One engine image is ~19 GB compressed, more than the other 68 together.
ENGINE_LIST=${ENGINE_LIST:-$REPO_ROOT/offline/engine-images.txt}
ENGINE_COUNT=0
if [ -f "$ENGINE_LIST" ]; then
  # `|| [ -n "$eimg" ]`: a hand-written file often has no trailing newline, and
  # read then returns non-zero having already set eimg -- silently dropping the
  # last engine, which is the single most expensive thing to discover missing.
  while read -r eimg || [ -n "$eimg" ]; do
    case "$eimg" in ''|'#'*) continue ;; esac
    if grep -qxF "$eimg" "$OUT/images.txt"; then continue; fi
    echo "$eimg" >> "$OUT/images.txt"
    COUNT=$((COUNT+1)); ENGINE_COUNT=$((ENGINE_COUNT+1))
  done < "$ENGINE_LIST"
  [ "$ENGINE_COUNT" -gt 0 ] && echo "    + $ENGINE_COUNT engine image(s) from $(basename "$ENGINE_LIST")"
else
  echo "    no $ENGINE_LIST -- no engine images in this bundle"
  echo "      (the platform stack only; copy engine-images.txt.example to add them)"
fi

# The address in engine-images.txt has to be the one a `models:` entry gives the
# chart -- the same string, not the same image. A bundle carrying an engine
# under one address while the file the site deploys names another builds
# cleanly, loads cleanly, and then leaves the model pod in ImagePullBackOff
# against a registry that holds the image under a different name. The models
# files in the repo are the ones we can see, so check those; a site's own file
# is its own business, but the rule is the same and saying it here is cheap.
if [ -d "$REPO_ROOT/models" ]; then
  python3 - "$ENGINE_LIST" "$REPO_ROOT/models" <<'PY'
import os, re, sys
listed, models_dir = sys.argv[1], sys.argv[2]
have = set()
if os.path.exists(listed):
    have = {l.strip() for l in open(listed) if l.strip() and not l.startswith('#')}
# `image:` with a repository/tag pair under it, which is how a models file names
# the engine. Anything else in these files belongs to the chart, not to us.
pat = re.compile(r'repository:\s*(\S+)\s*\n\s*tag:\s*(\S+)')
missing = {}
for root, _, files in os.walk(models_dir):
    for f in files:
        if not f.endswith(('.yaml', '.yml')) or f.endswith('.gotmpl'):
            continue
        p = os.path.join(root, f)
        for repo, tag in pat.findall(open(p).read()):
            repo, tag = repo.strip('"\''), tag.strip('"\'')
            if 'sglang' not in repo and 'vllm' not in repo:
                continue
            addr = f'{repo}:{tag}'
            if addr not in have:
                missing.setdefault(addr, []).append(os.path.relpath(p, models_dir))
for addr, files in sorted(missing.items()):
    print(f'    ⚠️  {addr}')
    print(f'        named by {", ".join(sorted(set(files)))}, not in {os.path.basename(listed)}')
    print('        -- a cluster deploying that file has no engine image')
PY
fi

# The `helm test` probe for alert-webhook. The render is made with --skip-tests,
# on purpose -- test hooks are not part of what a cluster runs -- so this
# address is in the list today only because grafana's initChownData happens to
# want the same tag. Naming it here makes that deliberate.
# helmfile.yaml.gotmpl points the hook at this exact image when offline; the two
# are the same decision written twice, so change them together.
# The images a model's chart pins INSIDE ITSELF: the hang-watcher, CART, and
# CART's two sidecars. No render here names them -- a model release comes from a
# MODELS file on the command line, and a bundle is built before anyone knows
# which models the site will run -- the same reason the engine charts are pulled
# above.
#
# Read out of the chart archive, not guessed:
#   - a rewrite replaces only the REPOSITORY for hangWatcher and cart.image, so
#     the tag on the pod is the chart's own. A list of tags kept beside this
#     said hang-watcher 0.1.25 while the chart pinned 0.1.22, and the pod
#     asked for 0.1.22 against a registry that only had 0.1.25.
#   - cart.image.tag is empty on purpose and means "the CART subchart's
#     appVersion", which is inside the archive too.
for _ec in "$OUT"/charts/sglang-*.tgz "$OUT"/charts/vllm-*.tgz; do
  [ -f "$_ec" ] || continue
  # The list goes through a file, not a pipe: the right side of a pipe is a
  # subshell, so the COUNT increment below would be lost and the run would
  # report fewer images than images.txt actually holds.
  # THIS environment's file, then default.yaml under it -- not default.yaml
  # alone. The two used to be the same thing because no cluster environment
  # set `versions:`; they are not any more (wlcb, test and b300 pin the six
  # charts whose API groups moved). Reading default.yaml for a `-e wlcb` build
  # put autoconfig-hagate:0.4.0 in images.txt while that environment renders
  # :0.3.47 -- the bundle carrying a tag nobody asks for and missing the one
  # they do, which is the ImagePullBackOff this block exists to prevent.
  python3 - "$_ec" "environments/$ENVIRONMENT.yaml" environments/default.yaml > "$OUT/.sidecars" <<'PY'
import sys, tarfile, yaml

chart, envfiles = sys.argv[1], sys.argv[2:]
values, subapp = {}, {}
with tarfile.open(chart) as t:
    for m in t.getmembers():
        parts = m.name.split("/")
        if len(parts) == 2 and parts[1] == "values.yaml":
            values = yaml.safe_load(t.extractfile(m)) or {}
        # <chart>/charts/<sub>/Chart.yaml -- where an empty tag comes from
        if len(parts) == 4 and parts[1] == "charts" and parts[3] == "Chart.yaml":
            subapp[parts[2]] = (yaml.safe_load(t.extractfile(m)) or {}).get("appVersion")
# First file that answers wins, which is how helmfile layers them: the
# environment's own values over default.yaml's.
env = {}
for f in envfiles:
    try:
        e = yaml.safe_load(open(f)) or {}
    except Exception:
        continue
    if (e.get("versions") or {}).get("autoconfig"):
        env = e
        break
# cart.ha and cart.reload are autoconfig's sidecars and track its version --
# the same value helmfile.yaml.gotmpl writes into them.
autoconfig_ver = (env.get("versions") or {}).get("autoconfig")

# Exactly what helmfile.yaml.gotmpl renders for a `models:` entry, or the
# bundle carries a tag nobody asks for. hangWatcher and cart keep the CHART's
# tag, because only their repository is replaced; ha and reload are one
# repository:tag string replaced whole, so their tag is autoconfig's chart
# version -- the chart's own pin for them is stale by design, since it cannot
# know which autoconfig the cluster runs.
out = []
hw = (values.get("hangWatcher") or {}).get("image") or {}
if hw.get("repository") and hw.get("tag"):
    out.append("%s:%s" % (hw["repository"].rsplit("/", 1)[-1], hw["tag"]))
cart = values.get("cart") or {}
ci = cart.get("image") or {}
tag = ci.get("tag") or subapp.get("cart")
if ci.get("repository") and tag:
    out.append("%s:%s" % (ci["repository"].rsplit("/", 1)[-1], tag))
for name in ("autoconfig-hagate", "autoconfig-reload"):
    if autoconfig_ver:
        out.append("%s:%s" % (name, autoconfig_ver))
for a in out:
    print(a)
PY
  while read -r _img; do
    # Under THIS environment's registry, not the chart's own address. The
    # chart pins a private registry for these four on purpose, but helmfile points them at
    # `registry` in both offline modes -- they are our images, and they belong
    # where the rest of ours are. Carrying that spelling would put images
    # in the bundle that no render ever asks for, and would drag that host into
    # the list of hosts the nodes have to mirror.
    _a="$SOURCE_REGISTRY/$_img"
    if [ -n "$SOURCE_REGISTRY" ] && ! grep -qxF "$_a" "$OUT/images.txt"; then
      echo "$_a" >> "$OUT/images.txt"
      COUNT=$((COUNT+1))
      echo "    + $_a ($(basename "$_ec") pins this; no render names it)"
    fi
  done < "$OUT/.sidecars"
  rm -f "$OUT/.sidecars"
done

if ! grep -q '^docker.io/library/busybox:1.38.0$' "$OUT/images.txt"; then
  echo 'docker.io/library/busybox:1.38.0' >> "$OUT/images.txt"
  COUNT=$((COUNT+1))
  echo "    + docker.io/library/busybox:1.38.0 (alert-webhook's helm test probe)"
fi

# ───────────────────────────────────────── where each image lands in the mirror
# Both modes put an image at the same place in the registry -- host stripped,
# path kept -- because that is also the path containerd asks a mirror for:
# quay.io/cilium/cilium is fetched as GET /v2/cilium/cilium/... plus
# `?ns=quay.io`. Measured: a plain registry IGNORES that ns parameter, so two
# upstreams whose path is identical are one repository in the registry and the
# second push overwrites the first. Nothing downstream would say so -- the pod
# pulls, gets the other project's image, and fails somewhere else entirely.
#
# So check here, where the whole list is in hand, and emit the host list the
# mirror needs while at it. Deriving the hosts beats a hardcoded seven: the
# registry a cluster keeps its own images under is one of them, and it differs
# per environment.
python3 - "$OUT/images.txt" "$OUT/mirror-hosts.txt" <<'PY' || exit 1
import sys, collections
src, hosts_out = sys.argv[1], sys.argv[2]

def split(ref):
    """(host, path) by containerd's rule: a first segment with a dot or a
    colon is a host, anything else is a docker.io short name."""
    body = ref.split("@")[0]
    head = body.split("/")[0]
    if "/" in body and ("." in head or ":" in head or head == "localhost"):
        return head, body.split("/", 1)[1]
    if "/" not in body:
        return "docker.io", "library/" + body
    return "docker.io", body

paths, hosts = collections.defaultdict(set), set()
for line in open(src):
    ref = line.strip()
    if not ref:
        continue
    host, path = split(ref)
    hosts.add(host)
    paths[path].add(host)

# Two TAGS of one repository are not a collision -- they are two tags. Two
# HOSTS serving the same path are.
clash = {p: v for p, v in paths.items() if len(v) > 1}
if clash:
    print("    COLLISION: these upstream addresses share one path in the registry,")
    print("    so the second push would overwrite the first:")
    for p, v in sorted(clash.items()):
        print("      %s  <-  %s" % (p, ", ".join(sorted(v))))
    print("    Refusing to build a bundle that cannot be loaded correctly.")
    sys.exit(1)

open(hosts_out, "w").write("".join(h + "\n" for h in sorted(hosts)))
print("    %d distinct repository:tag paths, each from one upstream host" % len(paths))
print("    upstream hosts a mirror has to answer for: %s" % ", ".join(sorted(hosts)))
PY

if [ "$SKIP_IMAGES" = false ]; then
  command -v crane >/dev/null || {
    echo "crane not found (use --charts-only, or install it: it is in offline/tools" >&2
    echo "after script/offline_tools.sh fetch, and on a build host a single binary" >&2
    echo "from github.com/google/go-containerregistry releases)" >&2; exit 1; }
  # crane reads a docker config even when it needs no credentials, and a file
  # it cannot open is a hard error on every single pull -- measured, that is
  # ~/.docker/config.json owned by another uid, and the message ("loading
  # config file: permission denied") arrives 68 times, once per image, long
  # after the run started. Say it once, here.
  _dc="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
  if [ -e "$_dc" ] && [ ! -r "$_dc" ]; then
    echo "$_dc exists but is not readable by this user. crane reads it on every" >&2
    echo "pull and fails on all of them. Point DOCKER_CONFIG at a directory you own:" >&2
    echo "    DOCKER_CONFIG=\$(mktemp -d) $0 ..." >&2
    exit 1
  fi

  echo "==> copying images into OCI layouts"
  n=0
  while read -r img; do
    [ -z "$img" ] && continue
    case "$img" in */*:*) ;; *) continue ;; esac   # skip bare repositories
    n=$((n+1))
    dir="$OUT/images/$(echo "$img" | tr '/:@' '___')"
    # Idempotent, because this step is long enough to be interrupted: 68 images
    # and 12 GB, measured, and a first run here was cut off at 51. Without this
    # a resume re-fetches everything.
    if [ -f "$dir/oci-layout" ] && [ -s "$dir/index.json" ]; then
      printf '    [%d/%d] have %s\n' "$n" "$COUNT" "$img"
      continue
    fi
    printf '    [%d/%d] %s\n' "$n" "$COUNT" "$img"
    # A digest-pinned image keeps its full index; everything else is fetched
    # for BUNDLE_PLATFORMS only. Why, and what it costs, is in
    # docs/offline-install.md under "Why crane, and why the full index".
    # Into .part first: an interrupted copy leaves a directory the `have`
    # check above would otherwise accept as finished.
    case "$img" in
      *@sha256:*) _plat="" ;;
      *)          _plat="--platform ${BUNDLE_PLATFORMS:-linux/amd64}" ;;
    esac
    # Fetch through a mirror where the build host needs one. crane does NOT
    # read /etc/docker/daemon.json, so a host that reaches docker.io only
    # through registry-mirrors -- on such a host registry-1.docker.io answers 000
    # there while quay, ghcr, nvcr and registry.k8s.io all answer -- loses
    # every docker.io image the moment this script stopped using `docker pull`.
    #
    # Storing under the ORIGINAL name is what makes this safe, and it is only
    # correct because a pull-through cache serves the publisher's own manifest
    # bytes: measured through two public pull-through caches,
    # library/busybox:1.38.0 and 4pdosc/autoconfig-hagate:0.3.47 both came back
    # with the same digest a host with direct access reads, and a tag nobody
    # published failed through both. A mirror that rebuilt manifests would
    # change the digest, so check that before adding one here.
    _fetch="$img"
    # Match against the FULLY QUALIFIED name. A docker.io short name has no
    # host at all (`4pdosc/hang-watcher:0.1.22`, as the sglang chart writes its
    # sidecars), and matching that literally meant a path-prefix entry like
    # docker.io/4pdosc=<private>... could never win -- the bare name fell through
    # to the plain docker.io entry and was fetched from a mirror that has no
    # 4pdosc. The symptom is not an error: the pull fails, the fallback goes to
    # docker.io through the proxy, and the build sits there.
    case "${img%%/*}" in
      *.*|*:*|localhost) _full="$img" ;;
      *)                 _full="docker.io/$img" ;;
    esac
    for _m in ${BUNDLE_FETCH_MIRRORS:-}; do
      case "$_m" in *=*) ;; *) echo "      ignoring BUNDLE_FETCH_MIRRORS entry $_m (want upstream=replacement)" >&2; continue ;; esac
      _up=${_m%%=*}; _via=${_m#*=}
      case "$_full" in
        "$_up"/*) _fetch="$_via/${_full#"$_up"/}" ;;
      esac
      [ "$_fetch" != "$img" ] && break
    done
    # A pull-through cache on the internal network is plain HTTP, and crane
    # refuses that by default ("server gave HTTP response to HTTPS client").
    # Only applied to a mirrored fetch: an upstream must stay on TLS.
    _ins=""
    if [ "$_fetch" != "$img" ]; then
      printf '            via %s\n' "${_fetch%%/*}"
      [ "${BUNDLE_FETCH_INSECURE:-false}" = true ] && _ins="--insecure"
    fi
    rm -rf "$dir.part"
    # A mirror is an optimisation; the upstream address is the truth. Measured:
    # the internal docker.io cache answers MANIFEST_UNKNOWN for our own
    # repositories (4pdosc/*) while serving library/* fine, so nine images --
    # every component we build -- failed outright and the bundle would have
    # been shipped incomplete. Fall back to the real address before giving up.
    # Whether crane SUCCEEDED has to be carried forward: it writes oci-layout
    # and index.json before any blob, so a killed pull leaves a directory that
    # looks finished. docs/offline-install.md, "An empty layout is not an image".
    _ok=false
    if crane pull --format=oci $_plat $_ins "$_fetch" "$dir.part" >/dev/null 2>&1; then
      _ok=true
    elif [ "$_fetch" != "$img" ] && crane pull --format=oci $_plat "$img" "$dir.part" >/dev/null 2>&1; then
      _ok=true
      printf '            (mirror did not have it; came from %s)\n' "${img%%/*}"
    fi
    if [ "$_ok" = true ] && [ -f "$dir.part/oci-layout" ] && [ -s "$dir.part/index.json" ]; then
      rm -rf "$dir"; mv "$dir.part" "$dir"
    else
      rm -rf "$dir.part"
      if [ "$_fetch" != "$img" ]; then
        echo "      COPY FAILED: $img (fetched as $_fetch)" >&2
      else
        echo "      COPY FAILED: $img" >&2
      fi
      img_failed=$((img_failed+1))
    fi
  done < "$OUT/images.txt"
  # A bundle that is missing images must say so and fail. It used to warn and
  # exit 0, leaving MANIFEST claiming "saved" -- and the gap surfaced only on
  # the far side, as a MISSING line from offline_load.sh, which also exited 0.
  # That is precisely the ImagePullBackOff-in-an-air-gapped-room this script
  # exists to prevent.
  [ "$img_failed" -eq 0 ] || echo "    $img_failed image(s) could not be saved" >&2
fi

# source_registry is not decoration: offline_load.sh renames our own images by
# replacing this exact prefix, because the charts render them as
# <registry>/<name> with no path of their own. Stripping only the host instead
# lands them one segment deep and nothing can pull them.
# ${EXTRA[@]+...} like every other helmfile call here: bash < 4.4 (macOS 3.2)
# aborts on an unbound empty array. `|| true` because this runs under pipefail
# with set -e, and a failure here would exit BEFORE the MANIFEST is written --
# after the charts and every image tarball are already on disk, with nothing
# saying why, and offline_load.sh then refusing to run without --source-registry.
# versions.env pins what the target installs (containerd, kubeadm, crane...) and
# offline_tools.sh reads it from the bundle. It is a repo file, so a bundle
# built into the repo's own offline/ already has it and a bundle built
# elsewhere does not -- and "carry $OUT across" is then not true: the first
# step on the isolated side dies on a file that stayed behind.
[ -f "$OUT/versions.env" ] || cp "$REPO_ROOT/offline/versions.env" "$OUT/versions.env" 2>/dev/null || true

# The tools are fetched by their own command, into the repo's offline/tools
# unless told otherwise, so a bundle built with -o <dir> has an empty tools/
# and nothing says so until the target host has no containerd to install.
TOOL_COUNT=$(find "$OUT/tools" -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')

# Which commit this bundle came from. A build host that received the repo as
# files rather than as a clone has no .git, and the line then read "unknown" --
# on the one artifact whose whole purpose is to be carried somewhere that
# cannot look anything up. REPO_COMMIT lets the copier say what git cannot.
_commit=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "")
[ -n "$_commit" ] || _commit=${REPO_COMMIT:-unknown}

cat > "$OUT/MANIFEST" <<EOF
built:       $(date -u +%Y-%m-%dT%H:%M:%SZ)
repo:        $_commit
environment: $ENVIRONMENT
source_registry: ${SOURCE_REGISTRY:-unknown}
image_format: oci            # crane OCI layouts, one directory per image.
                             # Bundles built before this said nothing here and
                             # hold *.tar from \`docker save\`; offline_load.sh
                             # cannot read those and says so by name.
charts:      $(ls "$OUT/charts" | wc -l | tr -d ' ')
images:      $COUNT ($( [ "$SKIP_IMAGES" = true ] && echo "list only" || echo "saved"))
engines:     $ENGINE_COUNT (named in engine-images.txt, not derived)
tools:       $TOOL_COUNT (binaries and units for the isolated side)
EOF
rm -f "$RENDER" "$OUT/.render.err" "$OUT/.releases.json" \
      "$CILIUM_RENDER" "$OUT/.cilium.err" "$OUT/.releases.err"
echo
cat "$OUT/MANIFEST"
echo
echo "carry $OUT to the target side, then: script/offline_load.sh $OUT"
if [ "$TOOL_COUNT" -eq 0 ]; then
  echo
  echo "This bundle carries no tools. The isolated side has no containerd, no"
  echo "kubeadm and no registry image to start step 1 with -- and the failure"
  echo "happens there, not here. Fill them in before carrying it across:"
  echo "    TOOLS=$OUT/tools script/offline_tools.sh fetch"
fi
if [ "${img_failed:-0}" -ne 0 ]; then
  echo
  echo "INCOMPLETE: $img_failed image(s) are listed in images.txt with no tarball." >&2
  echo "Mirror them by hand or fix the pull, then re-run -- this bundle will not" >&2
  echo "install cleanly on a host with no outbound network." >&2
  exit 1
fi
