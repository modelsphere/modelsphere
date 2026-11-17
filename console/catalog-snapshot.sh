#!/bin/sh
# Hand the bundle's catalog snapshot to catalog-mirror: a ConfigMap holding
# catalog-snapshot.tar.gz, created or replaced before the release syncs (a
# presync hook in helmfile.yaml.gotmpl).
#
# Server-side apply: the snapshot is several hundred KiB, and a client-side apply
# would copy all of it into the last-applied annotation, which holds 256 KiB.
#
#   console/catalog-snapshot.sh <namespace> <catalog-snapshot.tar.gz>
set -eu
NS=$1; SNAPSHOT=$2
[ -s "$SNAPSHOT" ] || { echo "catalogSnapshot: $SNAPSHOT does not exist or is empty -- the bundle carries it as catalog-snapshot.tar.gz" >&2; exit 1; }
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create configmap catalog-mirror-snapshot --from-file=snapshot.tar.gz="$SNAPSHOT" \
  --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts --field-manager=modelsphere-helmfile -f -
