# The VictoriaLogs Grafana datasource plugin, as files for an init container to
# copy -- NOT a Grafana image. Grafana itself stays the upstream one, so a
# Grafana upgrade does not drag this along.
#
# It exists for air-gapped installs only. Online, grafana.plugins lets Grafana
# fetch the plugin itself (observability/prom-stack/overrides.yaml.gotmpl), but
# that becomes GF_PLUGINS_PREINSTALL_SYNC and a closed cluster would then fail
# to start Grafana at all. The offline bundle's only channel a pod can read is
# the registry -- charts are read from the installer's disk, and a ConfigMap
# caps at 1MiB against a 26MB backend binary -- so the plugin travels as an
# image and rides the bundle/rewrite/mirror machinery with every other image.
#
# Built by hand, like the other images with no source repository of their own.
# See README.md in this directory.

FROM --platform=$BUILDPLATFORM alpine:3.21 AS fetch
ARG VERSION=0.32.0
# The fetch stage is pinned to the build platform on purpose: it is the only
# stage that RUNs anything, so a multi-arch build needs no qemu.
RUN apk add --no-cache curl unzip \
 && curl -fsSL -o /tmp/p.zip \
      "https://github.com/VictoriaMetrics/victorialogs-datasource/releases/download/v${VERSION}/victoriametrics-logs-datasource-v${VERSION}.zip" \
 && unzip -q /tmp/p.zip -d /out \
 && ls -d /out/victoriametrics-logs-datasource \
 && du -sh /out/victoriametrics-logs-datasource

# Unpacked as released, all 212MB of it. The release carries a ~25MB backend
# binary for each of eight platforms and a cluster runs one of them, so dropping
# the other seven is the obvious thing to do -- and it breaks the plugin.
# MANIFEST.txt is signed and lists every file, so a missing one makes the
# signature `modified` and Grafana refuses to load it. Measured, with the image
# that had been trimmed to 55MB:
#
#   plugins.signature  "Plugin file listed in the manifest was not found"
#                      path=victoriametrics_logs_backend_plugin_linux_s390x
#   plugins.validation "plugin ... has an modified signature"
#
# and the datasource answered "Unable to find datasource plugin". Leave it whole.

FROM alpine:3.21
# Nothing runs here; the image is a carrier. The init container that copies
# /plugin out of it needs a shell, which is why this is alpine and not scratch.
COPY --from=fetch /out/victoriametrics-logs-datasource /plugin/victoriametrics-logs-datasource
