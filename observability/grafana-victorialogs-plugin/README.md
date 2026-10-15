# grafana-victorialogs-plugin

The [VictoriaLogs datasource plugin](https://github.com/VictoriaMetrics/victorialogs-datasource)
packaged as files. `bodylog-victorialogs` provisions the datasource; Grafana
cannot use a datasource whose plugin it does not have, so
`observability/prom-stack/overrides.yaml.gotmpl` copies these files in with an
init container.

## Why an image, and why in every mode

`grafana.plugins` would do the job online — Grafana fetches the plugin itself —
but it becomes `GF_PLUGINS_PREINSTALL_SYNC`, which downloads from grafana.com at
startup and synchronously: a closed cluster would not start Grafana at all. So
it cannot be the air-gapped answer.

Using it online and an image offline is worse than either. The offline bundle
collects image addresses by rendering with `registryMode: upstream`
(`script/offline_bundle.sh`) — the mode that would not have named the image — so
the bundle would come out without it, and the install that needs it is the one
that could not pull it. One path for all three modes instead.

The plugin has to be an image rather than a file in the bundle because the
bundle fills two addresses, a registry and a chart directory, and only the
registry is readable from a pod: charts are read by helmfile on the installer's
filesystem, and a ConfigMap stops at 1MiB against a 26MB backend binary. As an
image it rides the bundle, `rewrite` and `mirror` with no new code.

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

**Re-pushing a tag does not reach a node that already has it.** Image pull policy
is IfNotPresent for a tag that is not `latest`, so a node holding the old layers
keeps using them and the fix looks like it did not work. Either give the rebuild
a new tag, or clear the old one from the nodes (`crictl rmi <image>:<tag>`)
before testing.

**Do not trim the release.** It carries a ~25MB backend binary for each of eight
platforms, 212MB unpacked, and a cluster uses one of them — but MANIFEST.txt is
signed and lists every file. Delete the seven a cluster will never run and
Grafana reports the signature as `modified` and declines to load the plugin,
while the files sit there looking installed. That is what the first build of this
image did; the Dockerfile has the log lines.
