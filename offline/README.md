# offline/ — the payload of an offline install

This directory is the agreed place for everything an offline site needs and
cannot download. It ships **empty**: the payload is built by
`make offline-bundle` on a host that has the internet, carried here, and
loaded by `make offline-load`.

Committed: this file, the directory structure, the `.gitignore`, `versions.env`,
`site.env.example`, `engine-images.txt.example` and `units/`. The payload is not -- it is
about 6 GB for the default x86 bundle without engine images (about 3 GB for an
all-Ascend arm64 one), and an engine image adds 8-20 GB on top of that.

```
offline/
  engine-images.txt   engines this site installs BY HAND. A model declared as a
                      `models:` entry is an ordinary release and its images come
                      from the render like everything else -- this file is only
                      for the other kind, and is usually empty.
  units/    the systemd files for containerd and kubelet (and kubeadm's
            drop-in), at the versions in versions.env -- committed, so the
            build does not fetch them; refresh them when bumping those
  images/   one OCI layout per image, copied with crane so the manifest, and
            the digest a chart pins, survive the trip
  charts/   chart tarballs (.tgz), ours and upstream's
  catalog-snapshot.tar.gz  the model catalog and the engine charts, served to
            swissd in the cluster by catalog-mirror (catalogSnapshot)
  swiss-engine-images.txt  every engine image in the bundle, which
            offline_load.sh pushes again under the name swiss asks for
  tools/    binaries and their images: registry, helm, helmfile, kubectl,
            kubeadm, kubelet, containerd, runc, the CNI plugins, helm-diff,
            and the kubeadm control-plane images
  MANIFEST  what was built, from which commit, with which source registry
```

## The steps

**1. Distribute the tools.** Nothing on an offline host can be assumed --
not helm, not containerd, not even a registry to hold the rest. `offline/tools/`
carries them, and `make offline-install-tools` puts them in place -- nerdctl
included, so step 2 needs no docker on the registry host.

**2. Stand up the offline registry, and load it.** One `registry:3` container
holds the images. `make offline-registry` starts it from the saved image, with
docker if the host has it and nerdctl otherwise (`RUNTIME=` picks one);
`make offline-load` fills it. The charts do not go into the registry: they stay
as the `.tgz` files in `charts/`, and the environment's `chartsDir` points helm
at them.

**3. Point everything at it.** Two ways, and what was loaded in step 2 serves
either -- every image went in under both the rewritten name and the one a mirror
asks for, since for our own components those differ. Pick per cluster. Both
need `chartsDir` in `environments/<cluster>.yaml`, and every node gets
`make setup-offline-node REGISTRY=<registry> MODE=<mirror|rewrite> BUNDLE=<this dir>`
before it joins.

`registryMode: rewrite` writes the registry into every address: `registry` in
the environment file, plus the distribution's own flag, because
`kube-apiserver`, `etcd` and `pause` belong to no chart and helm never sees
them: `kubeadm --image-repository <registry>` or
`k3s --system-default-registry <registry>`. Those two naming schemes differ
where you would least expect; `offline_load.sh` asks kubeadm for the names
rather than computing them.

`registryMode: mirror` leaves the addresses upstream and redirects on the node.
`registry` stays as it is online, and so does `kubeadm init`. The charts'
pinned digests survive this mode; `rewrite` drops them.

The rule, and the rest of this in detail, is in `docs/offline-install.md` --
this file is the short version that travels with the payload.

What neither mode does is point the nodes at a caching proxy of the public
registries, the way `make setup-mirror` does. Such a mirror keeps a fallback to
the real upstream, so an image the bundle is MISSING succeeds quietly off the
internet -- the install passes in a room that still has a network and fails in
the room that does not. The mirror written here has no fallback.

**4. Install.** `make helm-bootstrap` and `make helm-apply` with `ENV=<cluster>
SKIP_DEPS=1`: unchanged from an online cluster, except that helmfile must not
refresh chart repositories it cannot reach.
