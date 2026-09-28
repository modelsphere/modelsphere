# CloudNativePG。三层,刻意分开装:
#
#   setup         operator 本体(上游 OCI chart,同 observability/prom-stack 的做法)
#   plugin        barman-cloud 备份插件(CNPG-I,依赖集群里已有的 cert-manager 签发 mTLS 证书)
#   cluster       数据库实例本身(我们自己的 manifest,在 cluster/)
#
# 分开的理由:operator 升级、插件升级、数据库变更(实例数/资源/备份策略)是三件
# 互不相干的事。塞进一个 helm release 会导致改一行资源就顺带滚 operator。
#
# 首次安装顺序: setup → plugin → app-secret → cluster

VERSION        ?= 0.29.0     # operator chart(appVersion 1.30.0)
PLUGIN_VERSION ?= 0.8.0      # barman-cloud plugin chart(appVersion v0.15.0)
NS             ?= cnpg-system
DB_NS          ?= middleware
CL             ?= cnpg       # Cluster 名(与 cluster/cluster.yaml 一致)
CL_SECRET      ?= cnpg-rw    # bootstrap 凭证,故意与 RW Service 同名(见 cluster.yaml)
# 首个使用者是 H3。要加别的业务:改这两个变量再跑 app-secret,库本身在
# cluster.yaml 的 bootstrap.initdb 里声明(或用 Database CRD 增量加)。
APP_USER       ?= h3
APP_DB         ?= minimaxh3

# 目录名 cluster/ 跟 target 名 cluster 撞车,不声明 .PHONY 的话 make 会认为
# 「目标已存在且比依赖新」直接跳过,输出 "make: 'cluster' is up to date." —— 踩过。
.PHONY: install setup plugin cluster cluster-dry status backup-now

# ── operator ──────────────────────────────────────────────────────────

# operator 和插件顺序固定、装的时候总是一起跑,合一个入口省事;
# 但仍保留两个独立 target —— 之后单独升级插件时用得上。
install: setup plugin

setup:
	helm upgrade --install --namespace ${NS} --create-namespace \
	     cnpg oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg --version ${VERSION} -f ./overrides.yaml

# ── 备份插件 ──────────────────────────────────────────────────────────
# 装在 operator 同 ns:插件的 Service 名和证书 SAN 是写死的,operator 按固定
# 名字找它。
plugin:
	helm upgrade --install --namespace ${NS} \
	     barman-cloud oci://ghcr.io/cloudnative-pg/charts/plugin-barman-cloud --version ${PLUGIN_VERSION}

# ── 业务账号 ──────────────────────────────────────────────────────────
# CNPG bootstrap 用的 h3 凭证。Secret 名【故意】等于 RW Service 名(cnpg-rw):
# H3 chart 用同一个字段表示「去哪读密码」和「连哪个主机」,同名之后它不用改 chart
# 就能指过来。
#
# 密码来源:显式传入 > 随机生成。
#   APP_PASSWORD=xxx make app-secret     # 已有业务要沿用原密码时用
#   make app-secret                       # 全新部署,随机生成
#
# 不要加"从集群里某个已有 Secret 复制"这种分支 —— 名字撞上不相干的 Secret 时
# 会静默复用别人的密码,而且看不出来。要沿用就显式传。
#
# 幂等:已存在就不动。initdb 之后改这个 Secret **不会**改动库里的密码,
# 那样只会让 Secret 和库分叉、业务认证失败。
#
# ⚠️ 这个 Secret 是业务拿密码的唯一出口,别手滑删掉。真删了要进库
#    `ALTER ROLE h3 PASSWORD '...'` 重设,再把新密码写回来。
.PHONY: app-secret
app-secret:
	@if kubectl -n ${DB_NS} get secret ${CL_SECRET} >/dev/null 2>&1; then \
	  echo "${CL_SECRET} 已存在,跳过(initdb 后改它不会改库里的密码)"; \
	else \
	  pw="$${APP_PASSWORD}"; src="显式传入"; \
	  if [ -z "$$pw" ]; then \
	    pw=$$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 24); \
	    src="随机生成"; \
	  fi; \
	  kubectl -n ${DB_NS} create secret generic ${CL_SECRET} \
	    --type=kubernetes.io/basic-auth \
	    --from-literal=username=${APP_USER} \
	    --from-literal=password="$$pw" >/dev/null; \
	  echo "${CL_SECRET} 已创建(user=${APP_USER}),密码来源: $$src"; \
	fi

.PHONY: app-uri
app-uri:
	@echo "postgresql://${APP_USER}:$$(kubectl -n ${DB_NS} get secret ${CL_SECRET} -o jsonpath='{.data.password}' | base64 -d)@${CL}-rw.${DB_NS}.svc.cluster.local:5432/${APP_DB}"

# ── 数据库实例 ────────────────────────────────────────────────────────
# 先 dry 看一眼再 apply(服务端 dry-run 会跑 CRD 校验和 webhook,能提前发现
# 废弃字段告警)。目录内新增文件无需改本 Makefile。
cluster-dry:
	kubectl apply -n ${DB_NS} -f ./cluster/ --dry-run=server

cluster:
	kubectl apply -n ${DB_NS} -f ./cluster/

status:
	kubectl -n ${DB_NS} get cluster,pod,pvc -l cnpg.io/cluster=cnpg
	@echo
	kubectl -n ${DB_NS} get objectstore,scheduledbackup,backup

# 手工触发一次基础备份(验证归档链路、或下线前留一份时用)。
# 用 create 而不是 apply:Backup 用 generateName,每次要一个新对象。
backup-now:
	kubectl -n ${DB_NS} create -f ./backup-now.yaml
