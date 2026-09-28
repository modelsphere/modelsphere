.PHONY: help setup-k8s-online setup-k8s-offline setup-disk setup-mirror setup-offline-node audit-gpu gpu-prep setup-all \
        helm-deps helm-bootstrap helm-diff helm-apply helm-template helm-list helm-status \
        offline-bundle offline-load

INVENTORY ?= inventory.ini
LIMIT ?= all

# helmfile: which environment (environments/<ENV>.yaml) and, optionally, which
# releases. SELECTOR is passed straight through as -l, e.g.
#   make helm-diff SELECTOR=tier=gpu
#   make helm-apply SELECTOR=name=descheduler
ENV ?= default
SELECTOR ?=
SKIP_REFRESH ?= 1
# Air-gapped installs pass SKIP_DEPS=1. helmfile runs `helm repo add
# --force-update` for every declared repository before it renders anything, and
# on a node with no outbound network that fails the whole run -- even when every
# chart resolves to a .tgz under chartsDir and no repository is needed at all.
# Measured: "looks like https://modelsphere.github.io/helm-charts is
# not a valid chart repository or cannot be reached", at README step 6, with all
# twenty charts sitting on local disk.
SKIP_DEPS ?=
# Which model services to deploy, as files of `models:` entries -- see
# models/examples/sglang-qwen.yaml. Not in the environment files on purpose: the
# models a site runs are not a property of its cluster. Several are allowed,
# later ones winning: MODELS="a.yaml b.yaml". With none, no model is installed.
MODELS ?=
# Air-gapped node config: which registryMode the cluster renders with.
MODE ?= mirror
INTERACTIVE ?= true
# setup-all runs online + offline. The data disk and the registry mirrors are
# per-site decisions -- a node may have no spare disk, and setup-mirror with no
# mirror configured points every registry at a public third-party cache -- so
# setup-all includes them only when asked:
#   make setup-all SETUP_DISK=1 SETUP_MIRROR=1
SETUP_DISK ?=
SETUP_MIRROR ?=
HELMFILE_ARGS = -f helmfile.yaml.gotmpl -e $(ENV) $(if $(filter true 1 yes,$(INTERACTIVE)),--interactive,) $(if $(SELECTOR),-l $(SELECTOR),) $(if $(SKIP_REFRESH),--skip-refresh,) $(if $(SKIP_DEPS),--skip-deps,) $(foreach f,$(MODELS),--state-values-file $(f))

help:
	@echo "Available commands:"
	@echo "  make setup-k8s-online   - Run K8s setup tasks requiring outbound network access"
	@echo "  make setup-k8s-offline  - Run K8s local/offline configuration tasks"
	@echo "  make setup-offline-node REGISTRY=<host:port> MODE=<mirror|rewrite> - Configure nodes for an air-gapped registry"
	@echo "  make setup-disk         - Format and mount data disks for container storage"
	@echo "  make audit-gpu          - Audit GPU components, probe readiness, verify gpu-prep (read-only)"
	@echo "  make gpu-prep           - RDMA + nvidia_peermem prep on GPU nodes (mutating)"
	@echo "  make setup-all          - Run online + offline (SETUP_DISK=1 also mounts the data disk)"
	@echo ""
	@echo "Cluster add-ons (helmfile, see docs/helmfile-deploy.md):"
	@echo "  make helm-deps          - Install the helm plugins helmfile needs (once per machine)"
	@echo "  make helm-bootstrap     - Gateway API CRDs + PriorityClasses (kubectl, run before helm-apply)"
	@echo "  make helm-diff          - Show what helm-apply would change"
	@echo "  make helm-apply         - Converge the cluster onto helmfile.yaml.gotmpl"
	@echo "  make helm-template      - Render every chart locally, no cluster needed"
	@echo "  make helm-list          - List the releases this repo declares (file only, no cluster)"
	@echo "  make helm-status        - Compare that list with the releases helm has in the cluster"
	@echo ""
	@echo "Air-gapped install (see docs/offline-install.md), in order:"
	@echo "  make offline-tools      - Fetch the binaries and the registry image (where the internet is)"
	@echo "  make offline-bundle     - Pull every chart and image into BUNDLE=   (where the internet is)"
	@echo "  make offline-install-tools - Put those binaries in place            (on the isolated side)"
	@echo "  make offline-registry   - Start the bundle's registry               (on the isolated side)"
	@echo "  make offline-load       - Push a bundle into REGISTRY=              (on the isolated side)"
	@echo "                            ARGS='--source-registry 4pdosc' if the bundle has no MANIFEST"
	@echo ""
	@echo "Options:"
	@echo "  LIMIT=node1,node2       - Limit execution to specific hosts (default: all)"
	@echo "  ENV=<name>              - helmfile environment (default: default)"
	@echo "  SELECTOR=tier=gpu       - Limit helm-* to matching releases (labels: tier, name)"
	@echo "  SKIP_REFRESH=           - Re-enable 'helm repo update' (skipped by default)"
	@echo "  SKIP_DEPS=1             - Skip 'helm repo add' entirely; required with no outbound network"
	@echo "  MODELS=<file>           - Model services to deploy, e.g. models/examples/sglang-qwen.yaml"
	@echo "  MODE=mirror|rewrite     - registryMode for setup-offline-node (default: mirror)"
	@echo "  SETUP_DISK=1            - setup-all also runs setup-disk (off by default)"
	@echo "  BUNDLE=<dir>            - Bundle directory for offline-bundle / offline-load"
	@echo "  REGISTRY=<prefix>       - Internal image prefix, e.g. harbor.internal/infra"

setup-k8s-online:
	ansible-playbook -i $(INVENTORY) setup_k8s.yaml --tags online --limit $(LIMIT)

setup-k8s-offline:
	ansible-playbook -i $(INVENTORY) setup_k8s.yaml --tags offline --limit $(LIMIT)


setup-mirror:
	ansible-playbook -i $(INVENTORY) network_accesslator.yaml --tags mirror --limit $(LIMIT)

# The air-gapped counterpart of setup-mirror: the same certs.d files, pointed at
# the bundle's own registry instead of a public cache, and without the upstream
# fallback. They overwrite each other -- run this one LAST on an air-gapped
# cluster, and not setup-mirror again. REGISTRY is the address offline-load
# pushed to; MODE is the environment's `registryMode` (both modes need node
# config, `rewrite` to trust a plain-HTTP registry and `mirror` to redirect the
# upstreams); BUNDLE is read on this host for mirror-hosts.txt.
setup-offline-node:
	@test -n "$(REGISTRY)" || { echo "REGISTRY=<host>:<port> is required"; exit 1; }
	ansible-playbook -i $(INVENTORY) offline_node.yaml --limit $(LIMIT) \
	  -e offline_registry=$(REGISTRY) -e registry_mode=$(MODE) \
	  -e bundle_dir=$(abspath $(BUNDLE))

setup-disk:
	ansible-playbook -i $(INVENTORY) setup_k8s.yaml --tags disk --limit $(LIMIT)

audit-gpu:
	ansible-playbook -i $(INVENTORY) nvidia_audit.yaml --tags audit --limit $(LIMIT)

gpu-prep:
	ansible-playbook -i $(INVENTORY) nvidia_audit.yaml --tags gpu-prep --limit $(LIMIT)

setup-all: setup-k8s-online setup-k8s-offline \
           $(if $(filter true 1 yes,$(SETUP_DISK)),setup-disk,) \
           $(if $(filter true 1 yes,$(SETUP_MIRROR)),setup-mirror,)
	@$(if $(filter true 1 yes,$(SETUP_DISK)),:,echo "setup-all: setup-disk not run -- SETUP_DISK=1 to include it")

# ---------------------------------------------------------------- cluster add-ons
# helm-diff is not optional: `helmfile apply` and `helmfile diff` both shell out
# to it, and without it they fail rather than degrade.
# helm-diff, which `helmfile apply` and `helmfile diff` shell out to. Three
# sources, in order, because the obvious one does not work everywhere:
#   1. already installed -- nothing to do;
#   2. $(BUNDLE)/tools/helm-diff.tgz (BUNDLE defaults to ./offline), put there
#      by script/offline_tools.sh fetch.
#      This is the only one that works on an air-gapped site: the plugin URL
#      below is a git clone, and a site with no outbound network fails here
#      with `unable to access 'https://github.com/...'` -- measured;
#   3. the network: plainly first, then with --verify=false.
#      Both attempts are needed and neither is guesswork. helm 3.21.3 rejects
#      the flag outright (`unknown flag: --verify`), while helm v4.3.0 REQUIRES
#      it for this plugin: `Error: plugin source does not support verification.
#      Use --verify=false to skip verification`. Measured on node-3 with helm
#      v4.3.0 -- and note `helm plugin install --help` there does NOT list
#      --verify, which is how an earlier pass here talked itself into deleting
#      this line. The error message is the authority, not the help text.
#      The first attempt's output is held back and printed only if the second
#      one fails too: on helm 4 it is an `Error:` line on every successful run,
#      and a first-time reader takes it for the failure it is not.
# No `|| true` anywhere: this failing silently is what left the next
# `helmfile apply` dying on a missing plugin with no hint why.
helm-deps:
	@if helm plugin list 2>/dev/null | grep -q '^diff'; then \
	  echo "helm-diff: already installed"; \
	elif [ -f $(BUNDLE)/tools/helm-diff.tgz ]; then \
	  p=$$(helm env HELM_PLUGINS 2>/dev/null | tr -d '"'); \
	  p=$${p:-$$HOME/.local/share/helm/plugins}; \
	  mkdir -p "$$p" && tar -C "$$p" -xzf $(BUNDLE)/tools/helm-diff.tgz && \
	  echo "helm-diff: unpacked from the offline bundle"; \
	else \
	  if first=$$(helm plugin install https://github.com/databus23/helm-diff 2>&1); then \
	    echo "$$first"; \
	  elif ! helm plugin install https://github.com/databus23/helm-diff --verify=false; then \
	    echo "$$first"; \
	    echo "helm-deps: could not install helm-diff. With no outbound network, run"; \
	    echo "  make offline-tools   (where the internet is) and carry offline/tools/ across"; \
	    exit 1; \
	  fi; \
	fi

# Raw manifests that have to exist before the charts, and that no chart owns.
# Both are idempotent, so re-running is free.
#   - Gateway API CRDs: cilium's gatewayAPI.enabled and the rook dashboard
#     HTTPRoute in ceph/ceph-cluster-override.yaml both need them present.
#   - PriorityClasses: a pod naming one that does not exist is rejected at
#     admission, so these go in before anything that references them.
helm-bootstrap:
	kubectl apply -f gateway-api/standard-install.yaml
	kubectl apply -f scheduler/priority-classes.yaml

helm-diff:
	helmfile $(HELMFILE_ARGS) diff

# --skip-diff-on-install always: helm-diff renders each release against the API
# as it is when the run starts, so a chart that references a CRD another release
# in the same run creates cannot render, and the apply stops before installing
# anything. Skipping the diff for releases that are NOT yet installed costs
# nothing -- a new release's diff is "all of it" -- and it is what makes the
# first run on a fresh cluster work with the same command as every later one.
# Releases already installed are still diffed.
helm-apply:
	helmfile $(HELMFILE_ARGS) apply --skip-diff-on-install

helm-template:
	helmfile $(HELMFILE_ARGS) template --skip-tests

helm-list:
	helmfile $(HELMFILE_ARGS) list

# helm-list reads the state file only. This joins it with `helm list -A` from the
# live cluster and flags each release: missing / drift / failed / extra /
# unmanaged / ok. Presence and chart version only — `helm-diff` compares values.
# Same ENV and SELECTOR as everything above; add ARGS=--json for machine output.
helm-status:
	script/helm_status.sh $(HELMFILE_ARGS) $(ARGS)

# ---------------------------------------------------------------- air-gapped
# Four steps across two machines. Build where the internet is reachable
# (offline-tools, offline-bundle); carry offline/ across; then, on the target,
# offline-install-tools -> offline-registry + offline-load -> the two address
# values plus the distribution's own registry flag -> the ordinary
# helm-bootstrap/helm-apply. See docs/offline-install.md and offline/README.md.
#
# The image list is derived from a render rather than kept by hand -- see the
# header of script/offline_bundle.sh. ENV picks which environment to render, so
# the bundle contains what that cluster actually installs. It is rendered with
# registryMode: upstream on purpose: the bundle holds upstream addresses, and
# offline-load applies the same rewrite the values files do when it pushes.
BUNDLE ?= ./offline
REGISTRY ?=

# --- build side
offline-tools:
	script/offline_tools.sh fetch

# ARGS passes the cluster facts the environment files do not carry -- bodylog
# and bodylog-exporter hard-fail at template time without llmGateway.node and
# hostPath, so without a passthrough this target could not build a bundle for
# any environment:
#   make offline-bundle ENV=<cluster> ARGS='--set llmGateway.node=n1 --set llmGateway.hostPath=/mnt/disk0/bodylog-sinks'
offline-bundle:
	script/offline_bundle.sh -o $(BUNDLE) -e $(ENV) $(ARGS)

# --- target side
# BUNDLE reaches both: the tools, the registry image and site.env all live in
# the bundle, wherever it was carried to.
offline-install-tools:
	BUNDLE=$(BUNDLE) script/offline_tools.sh install

offline-registry:
	BUNDLE=$(BUNDLE) script/offline_registry.sh up

offline-load:
# The script also reads REGISTRY from $(BUNDLE)/site.env, which is the whole
# point of that file -- so only insist on the variable when there is no site.env
# to read it from.
	@test -n "$(REGISTRY)" || test -f $(BUNDLE)/site.env || \
	  { echo "REGISTRY= is required (or write it into $(BUNDLE)/site.env), e.g. make offline-load REGISTRY=10.0.0.9:5000"; exit 2; }
# ARGS reaches the script -- `--source-registry <prefix>` for a bundle whose
# MANIFEST does not say which registry it was built with, `--dry-run` to see the
# retag rule without pushing.
# The flag only goes on when there is a value for it: `--registry` with an empty
# REGISTRY reaches the script as a flag whose argument is missing, and the
# site.env-only form the docs show dies on `$$2: unbound variable`.
	script/offline_load.sh $(BUNDLE) $(if $(REGISTRY),--registry $(REGISTRY)) $(ARGS)
