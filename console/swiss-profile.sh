#!/bin/sh
# Give swissd a site profile pointing at catalog-mirror -- once. A postsync hook
# on the swissd release, used where catalog-mirror is on.
#
# Only when the profile does not exist yet. swissd owns the profile from then
# on: it is edited from the web, and a helmfile run that rewrote it would undo
# those edits. Without this, a fresh swissd offers its setup form pre-filled
# with the public catalog and chart repository, which an air-gapped cluster
# cannot reach, and nothing can be deployed until someone fixes both by hand.
#
#   console/swiss-profile.sh <namespace> <configmap> <profile yaml>
set -eu
NS=$1; CM=$2; PROFILE=$3
if kubectl -n "$NS" get configmap "$CM" >/dev/null 2>&1; then
  echo "site profile $NS/$CM exists -- left as it is (swissd owns it; edit it from the web)"
  exit 0
fi
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$PROFILE" > "$TMP"
kubectl -n "$NS" create configmap "$CM" --from-file=profile.yaml="$TMP"
echo "site profile $NS/$CM written: catalog and charts from catalog-mirror"
