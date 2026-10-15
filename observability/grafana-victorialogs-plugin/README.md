# grafana-victorialogs-plugin

The [VictoriaLogs datasource plugin](https://github.com/VictoriaMetrics/victorialogs-datasource)
packaged as files, for air-gapped clusters. `bodylog-victorialogs` provisions the
datasource; Grafana cannot use it without this plugin, and a closed cluster has
no way to download one.

Online installs do not need this image: `grafana.plugins` in
`observability/prom-stack/overrides.yaml.gotmpl` has Grafana fetch the plugin
itself. That value becomes `GF_PLUGINS_PREINSTALL_SYNC`, which downloads from
grafana.com at startup and synchronously — so it is set for `registryMode:
upstream` only, and the offline modes use this image instead.

## Why an image

The offline bundle fills two addresses: a registry and a chart directory.
Charts are read by helmfile on the installer's filesystem, which a pod cannot
see, and a ConfigMap stops at 1MiB against a 26MB backend binary. The registry
is the one channel into a pod, so the plugin travels as an image — and then the
bundle, `rewrite` and `mirror` all handle it with no new code.

## Build and push

No workflow: the plugin moves a few times a year, and the image is a carrier
with nothing of ours in it. Build it by hand, as with the other images that have
no source repository.

```sh
VERSION=0.32.0
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg VERSION=$VERSION \
  -t 4pdosc/grafana-victorialogs-plugin:$VERSION --push .
```

Then raise `versions.grafanaVictorialogsPlugin` in `environments/default.yaml`.
Both architectures carry both backend binaries: Grafana loads the one matching
its own, and which of the two it is depends on the node, not on the image.
