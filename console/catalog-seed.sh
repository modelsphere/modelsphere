#!/bin/sh
# Hand the bundle's catalog seed to catalog-mirror: a ConfigMap holding
# catalog-seed.tar.gz, created or replaced before the release syncs (a
# presync hook in helmfile.yaml.gotmpl).
#
# Server-side apply: the seed is several hundred KiB, and a client-side apply
# would copy all of it into the last-applied annotation, which holds 256 KiB.
#
#   console/catalog-seed.sh <namespace> <catalog-seed.tar.gz>
set -eu
NS=$1; SEED=$2
[ -s "$SEED" ] || { echo "catalogSeed: $SEED does not exist or is empty -- the bundle carries it as catalog-seed.tar.gz" >&2; exit 1; }
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create configmap catalog-mirror-seed --from-file=seed.tar.gz="$SEED" \
  --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts --field-manager=modelsphere-helmfile -f -
