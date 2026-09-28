VERSION ?= "87.21.0"

diff:
	helm diff upgrade --namespace monitoring \
		     kube-prometheus-stack oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version ${VERSION} -f ./overrides.yaml

setup:
	helm upgrade --install --namespace monitoring --create-namespace \
		     kube-prometheus-stack oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version ${VERSION} -f ./overrides.yaml

# LLM 业务告警规则(PrometheusRule,不属于 chart,单独 apply)
# alerts/ 下按业务域一个文件;系统层告警(node/etcd/kubelet 等)来自 chart 自带规则,
# 在 overrides.yaml 里配,不放这里。目录内新增文件无需再改本 Makefile。
rules:
	kubectl apply -f ./alerts/

rules-dry:
	kubectl apply -f ./alerts/ --dry-run=server

# LLM 推理 Grafana dashboard(ConfigMap,label grafana_dashboard=1,由 grafana sidecar 加载,不属于 chart)
# dashboards/ 下 kustomization.yaml 把每个 JSON 生成一个 ConfigMap。server-side apply 避免
# last-applied-configuration 注解超 256KiB。改面板见 dashboards/README.md。
# 改完 dashboards/build_dash.py 先 dashboards-gen 重新生成 JSON(部署的是 JSON,两者一起提交)。
dashboards-gen:
	python3 ./dashboards/build_dash.py

dashboards:
	kubectl apply --server-side --field-manager=inference-stack-k8s -k ./dashboards/

dashboards-dry:
	kubectl apply --server-side --field-manager=inference-stack-k8s -k ./dashboards/ --dry-run=server

dashboards-diff:
	kubectl diff --server-side --field-manager=inference-stack-k8s -k ./dashboards/
