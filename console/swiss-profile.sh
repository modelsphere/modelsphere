#!/bin/sh
# Give swissd a site profile pointing at catalog-mirror -- once. A postsync hook
# on the swissd release, used where catalog-mirror is on.
#
# Only when the profile does not exist yet. swissd owns the profile from then
# on: it is edited from the web, and a helmfile run that rewrote it would undo
# those edits. Without this, a fresh swissd offers its setup form pre-filled
# with the public catalog and chart repository, which an offline cluster
# cannot reach, and nothing can be deployed until someone fixes both by hand.
#
#   console/swiss-profile.sh <namespace> <configmap> <profile yaml, base64>
#
# base64 because helmfile renders a hook's arguments as a template again when
# it runs the hook, and swiss's own {{name}} placeholders in the profile would
# be taken for template calls.
set -eu
NS=$1; CM=$2
PROFILE=$(printf '%s' "$3" | base64 -d) || { echo "swiss-profile.sh: the profile argument is not base64" >&2; exit 1; }
if kubectl -n "$NS" get configmap "$CM" >/dev/null 2>&1; then
  echo "site profile $NS/$CM exists -- left as it is (swissd owns it; edit it from the web)"
  # Left alone, but not silently: lines this environment would write that the
  # stored profile does not have -- a profile saved before catalog-mirror was
  # on, a registry that moved, an autoconfig upgrade the sidecars did not follow.
  # Compared without quotes and indentation: a profile saved from the web is
  # re-serialised by swissd, which drops the quotes this hook wrote and omits
  # an empty mirror altogether -- neither is a difference.
  norm() { sed -e 's/"//g' -e "s/'//g" -e 's/^ *//' -e 's/ *$//'; }
  HAVE=$(kubectl -n "$NS" get configmap "$CM" -o jsonpath='{.data.profile\.yaml}' | norm)
  printf '%s\n' "$PROFILE" | grep -E 'chartRepo:|url:|mirror:|autoconfig-(hagate|reload)|repository:' | norm \
    | while IFS= read -r line; do
        case "$line" in *: ) continue ;; esac          # an empty value: nothing to compare
        printf '%s\n' "$HAVE" | grep -qxF -- "$line" \
          || echo "  WARNING: the profile lacks \"$line\" -- update it from the console if this environment is right"
      done
  exit 0
fi
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$PROFILE" > "$TMP"
kubectl -n "$NS" create configmap "$CM" --from-file=profile.yaml="$TMP"
echo "site profile $NS/$CM written: catalog and charts from catalog-mirror"
