# shellcheck shell=bash
# Sourced by offline_tools.sh and offline_bundle.sh: where to fetch an image or
# an OCI chart from under BUNDLE_FETCH_MIRRORS. One copy, because the three
# that came before it disagreed -- a bare `4pdosc/x` went to the docker.io
# mirror in one and to the docker.io/4pdosc one in another, and `registry:3`
# gained `library/` in one and not in the other.
#
#   BUNDLE_FETCH_MIRRORS="docker.io/4pdosc=tcr.example/4pdosc docker.io=mirror.example"
#   fetch_via 4pdosc/console:0.2.2   ->  tcr.example/4pdosc/console:0.2.2
#   fetch_via registry:3             ->  mirror.example/library/registry:3
#   fetch_via quay.io/x/y:1          ->  quay.io/x/y:1   (no rule: unchanged)
#
# The name is matched FULLY QUALIFIED: a docker.io short name has no host at
# all (`4pdosc/hang-watcher:0.1.22`, as the sglang chart writes its sidecars),
# and matched literally, a docker.io/4pdosc rule could never win for it. The
# LONGEST matching upstream wins, so the order of the rules does not matter.
# The replacement keeps the rest of the path; a name no rule matches is printed
# as it was given. Entries without `=` are ignored, with a warning on stderr.
fetch_via() {
  local img=$1 full m up best="" via=""
  case "$img" in
    */*) case "${img%%/*}" in
           *.*|*:*|localhost) full=$img ;;                # has a registry host
           *)                 full="docker.io/$img" ;;
         esac ;;
    *)   full="docker.io/library/$img" ;;               # `registry:3`
  esac
  for m in ${BUNDLE_FETCH_MIRRORS:-}; do
    case "$m" in *=*) ;; *) echo "ignoring BUNDLE_FETCH_MIRRORS entry $m (want upstream=replacement)" >&2; continue ;; esac
    up=${m%%=*}
    case "$full" in
      "$up"/*) if [ ${#up} -gt ${#best} ]; then best=$up; via=${m#*=}; fi ;;
    esac
  done
  if [ -n "$best" ]; then echo "$via/${full#"$best"/}"; else echo "$img"; fi
}
