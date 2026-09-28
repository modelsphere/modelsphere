#!/usr/bin/env bash
#
# helm_status.sh — what helmfile DECLARES vs what helm actually HAS in the cluster.
#
# `helmfile list` only reads helmfile.yaml.gotmpl; it never talks to the cluster,
# so it cannot tell you that a release is missing, stuck in `failed`, running an
# older chart, or that somebody helm-installed something this repo does not know
# about. This joins the two lists on <namespace>/<name> and prints one row per
# release with a verdict.
#
# Scope: presence, chart version and helm release status — i.e. "is the right
# chart there at all". It does NOT compare rendered values; that is `make
# helm-diff`, which is the deeper (and slower) check.
#
# Usage — normally via `make helm-status`, or directly with helmfile's own flags:
#   script/helm_status.sh -f helmfile.yaml.gotmpl -e default
#   script/helm_status.sh -f helmfile.yaml.gotmpl -e default -l tier=gpu
#   script/helm_status.sh --json -f helmfile.yaml.gotmpl -e default | jq '...'
#
# Needs: helmfile, helm, jq, GNU coreutils/util-linux, and a reachable cluster
# (current kubectl context). Runs on the Linux admin host, like every script here.
#
# Verdicts:
#   missing    declared and enabled, but helm has no such release  -> helm-apply
#   drift      deployed chart version != the version declared      -> helm-apply
#   <status>   present but helm status is not `deployed`
#              (failed / pending-upgrade / ...)                    -> investigate
#   extra      installed:false here, but still in the cluster      -> helm-apply
#                                                                     uninstalls it
#   unmanaged  in the cluster, absent from helmfile entirely       -> adopt or remove
#   ok         declared, deployed, versions agree
#   off        installed:false and absent — as intended
#
set -euo pipefail

output=table
args=()
for a in "$@"; do
    case "$a" in
        --json) output=json ;;
        *) args+=("$a") ;;
    esac
done

for bin in helmfile helm jq; do
    command -v "$bin" >/dev/null || { echo "helm_status.sh: $bin not found in PATH" >&2; exit 1; }
done

# Bare mktemp: GNU mktemp rejects `-t helm_status` ("too few X's in template").
err=$(mktemp)
trap 'rm -f "$err"' EXIT

# A selector narrows the DECLARED side only, so everything filtered out would
# come back as "unmanaged". Suppress that noise instead of lying.
selected=false
for a in "${args[@]+"${args[@]}"}"; do
    case "$a" in -l|--selector|-l*|--selector=*) selected=true ;; esac
done

# --skip-charts: name/namespace/version all come from the state file, so there is
# no reason to pull charts just to list them.
if ! desired=$(helmfile "${args[@]+"${args[@]}"}" list --skip-charts --output json 2>"$err"); then
    cat "$err" >&2
    echo "helm_status.sh: helmfile list failed" >&2
    exit 1
fi
# helmfile prints nothing when a selector matches no release; that is a valid
# (empty) desired state, not a parse error for jq to choke on.
[ -n "$desired" ] || desired='[]' 
# Ask for failed/pending/uninstalling explicitly: a bare `helm list` hides some of
# them, and a half-finished upgrade is exactly the row worth seeing. Not `--all`,
# which Helm 4 dropped — these per-status flags exist in both helm 3 and 4, and
# they also leave out the superseded/uninstalled history rows.
if ! actual=$(helm list --all-namespaces --deployed --failed --pending --uninstalling \
        --output json 2>"$err"); then
    cat "$err" >&2
    echo "helm_status.sh: helm list failed — is the cluster reachable? (kubectl config current-context)" >&2
    exit 1
fi
[ -n "$actual" ] || actual='[]' 

rows=$(jq -n --argjson desired "$desired" --argjson actual "$actual" --argjson selected "$selected" '
  # helm reports chart as "<name>-<version>", with both halves free to contain
  # dashes. Anchor on the version: greedy prefix, then backtrack until the tail
  # parses as a semver, so "rook-ceph-v1.20.6" and "chart-1.2.3-rc.1" both split.
  def chartver:
    . as $c
    | ((capture("^(?<n>.+)-(?<v>v?[0-9]+\\.[0-9]+\\.[0-9]+.*)$") | .v) // $c);

  def key: .namespace + "/" + .name;

  ($desired | map({key: key, value: .}) | from_entries)                    as $D
  | ($actual
      # Belt and braces: history rows must never count as "what is running now".
      | map(select(.status != "superseded" and .status != "uninstalled"))
      | map({key: key, value: .}) | from_entries)                          as $A
  | (($D | keys) + ($A | keys) | unique)
  | map(
      . as $k
      | $D[$k] as $d | $A[$k] as $a
      | (($d.version // "") | tostring)          as $want
      | (($a.chart // "") | chartver)            as $have
      | {
          key: $k,
          namespace: ($d.namespace // $a.namespace),
          name: ($d.name // $a.name),
          chart: ($d.chart // $a.chart),
          declared: (if $d == null then "-" else $want end),
          deployed: (if $a == null then "-" else $have end),
          helm_status: ($a.status // "-"),
          revision: (($a.revision // "-") | tostring),
          updated: (($a.updated // "-") | sub("\\.[0-9]+.*$"; "")),
          verdict:
            (if   $d == null            then "unmanaged"
             elif ($d.installed | not)  then (if $a == null then "off" else "extra" end)
             elif $a == null            then "missing"
             elif $a.status != "deployed" then $a.status
             elif $want != $have        then "drift"
             else "ok" end)
        }
    )
  | map(select(($selected | not) or (.verdict != "unmanaged")))
  # Worst first: the rows that need a decision, then the boring ones.
  | (["missing","drift","failed","extra","unmanaged","ok","off"]) as $rank
  | sort_by((.verdict as $v | $rank | index($v)) // 2.5, .namespace, .name)
')

if [ "$output" = json ]; then
    echo "$rows"
    exit 0
fi

table() {
    printf 'VERDICT\tNAMESPACE\tNAME\tDECLARED\tDEPLOYED\tSTATUS\tREV\tUPDATED\n'
    echo "$rows" | jq -r '.[] | [.verdict, .namespace, .name, .declared, .deployed, .helm_status, .revision, .updated] | @tsv'
}

# `column` lives in util-linux on most distros but in bsdextrautils on Debian,
# where a minimal image may not have it. Fixed widths are a fine fallback.
if command -v column >/dev/null; then
    table | column -t -s "$(printf '\t')"
else
    table | awk -F'\t' '{printf "%-16s %-24s %-22s %-10s %-10s %-16s %-4s %s\n", $1,$2,$3,$4,$5,$6,$7,$8}'
fi

echo
echo "$rows" | jq -r '
  (group_by(.verdict) | map("\(length) \(.[0].verdict)") | join(", ")) as $sum
  | "summary: " + $sum'
if [ "$selected" = true ]; then
    echo "note: a selector was given, so releases outside it are not reported as unmanaged."
fi
echo "note: presence/version only — run \`make helm-diff\` to compare values."
