#!/usr/bin/env bash
#
# node_prep_rdma.sh — GPU 节点初始化的 RDMA 部分(每台一次,幂等)。
#
# 为什么需要:
#   ① rdma-shared-dev-plugin 给 HCA 建 device spec 时要求全套 char 设备
#      (uverbs + rdma_cm + umad),缺 rdma_cm/umad 就 "missing RDMA device spec"。
#      inbox 驱动默认可能没 load rdma_ucm/ib_umad(measured once)→ 这里 load + 持久化。
#   ② kimi 部署要「无脑 kubectl apply、零 env」。但 NCCL_IB_HCA 必须挑「好 IB 口」:
#        - plugin selector 挑不出来(实测:ifNames 需 netdev 而 IB 口常无 IPoIB netdev;
#          deviceIDs 上 IB 与 200G-RoCE 同为 ConnectX-6 0x101b 分不开;linkTypes 字符串不匹配)
#        - 所以在**节点侧**按 /sys/class/infiniband 状态静态算出本机好口,写进
#          /etc/gpu-node/nccl-ib.env(NCCL_IB_HCA=...)。kimi manifest 所有节点一样、
#          启动时 source 这个 hostPath 文件即可,部署不再逐机探测。
#   好口判定:link_layer=<FABRIC> && state=ACTIVE && rate>=RATE_MIN(默认 100),
#            → 自动排除 down 口、非本 fabric 口、以及**降级速率的口**(调 RATE_MIN)。
#
# FABRIC(默认 ib):
#   ib   —— 只挑 InfiniBand 口(本集群验证过的路径)。
#   roce —— 挑 Ethernet 口(RoCE)。⚠️ caveat:以太口无法可靠区分「GPU fabric 口」与
#           other high-speed Ethernet ports (a 200G Ethernet port is not a GPU
#           fabric port, even though it looks like one by speed alone).
#           roce 模式下 rate 过滤挡不住这种同速非 fabric 口 → 需要时用 IFNAMES 白名单显式指定。
#   → 纯 IB 机群保持默认 ib;上量若有 RoCE-fabric 机器,对那些机器传 FABRIC=roce(必要时 IFNAMES=...)。
#
# 用法(在节点本机 root 执行;或 ssh <host> bash < node_prep_rdma.sh):
#   RATE_MIN=100 FABRIC=ib bash node_prep_rdma.sh
#   FABRIC=roce IFNAMES="enp234s0np0" bash node_prep_rdma.sh   # RoCE 机器显式列 fabric 口名
#
set -eu
RATE_MIN="${RATE_MIN:-100}"
FABRIC="${FABRIC:-ib}"
IFNAMES="${IFNAMES:-}"
# The only test hook: script/test_node_prep_rdma.sh sets TESTROOT so the sysfs
# tree and the two files written below live in a temporary directory, letting
# the port-selection logic run for real on a machine with no RDMA hardware.
# Do not set it in production.
TESTROOT="${TESTROOT:-}"
SYSFS="$TESTROOT/sys/class/infiniband"
MODCONF="$TESTROOT/etc/modules-load.d/rdma.conf"
GPUNODE="$TESTROOT/etc/gpu-node"
case "$FABRIC" in
  ib)   LL_WANT="InfiniBand" ;;
  roce) LL_WANT="Ethernet" ;;
  none) echo "[node_prep_rdma] FABRIC=none: no RDMA fabric on this node, nothing to do"; exit 0 ;;
  *) echo "ERROR: FABRIC must be ib, roce or none (got '$FABRIC')" >&2; exit 1 ;;
esac

# ── ① RDMA 内核模块:load + 开机自持久化 ──
# These are what the RDMA device plugin needs, they are the same set for
# InfiniBand and RoCE, and they do not depend on the port list built below --
# so they go in first and unconditionally. They used to come after, which meant
# a node whose fabric this script guessed wrong got no modules either.
mkdir -p "$(dirname "$MODCONF")"
printf '%s\n' rdma_ucm ib_umad ib_uverbs > "$MODCONF"
modprobe rdma_ucm ib_umad ib_uverbs 2>/dev/null || true

# ── ② 生成本机「好 IB 口」清单 → /etc/gpu-node/nccl-ib.env ──
hcas=""

# ── 优先复用生产 env(scripts/check_ib.sh 实测生成)──
# ~/deploy/env 的 NCCL_IB_HCA 是 scripts/check_ib.sh 两机对测生成的:逐口 ib_write_bw 带宽实测,
# <100Gb/s 的口(协商上但 PCIe/线缆/热问题)判 ✗ 排除 —— 这是"看着健康但吞吐不达标"口的过滤点,
# sysfs 的 link_layer/ACTIVE/rate=200 全绿也看不出。两边 HCA 数不等时,多出来的口也会对已验证好口
# 补测(用满所有健康口,不再静默丢弃)。所以有 env 就直接用它(k8s 与 docker 完全一致),没有才回退 sysfs。
#   (实测:一台有 4 个 IB 口、另一台只 3 个 → check_ib 前 3 对下标配对 + 第 4 个 mlx5_3 对另一台的 mlx5_0
#    补测 153Gb/s ✓ 纳入 → 前者用满 4 口 mlx5_0-3,后者用 3 口。)
DEPLOY_ENV="${DEPLOY_ENV:-/root/deploy/env}"
if [ -z "${NO_REUSE_DEPLOY_ENV:-}" ] && [ -f "$DEPLOY_ENV" ]; then
  hcas=$(grep -hoE 'NCCL_IB_HCA=[^[:space:]]+' "$DEPLOY_ENV" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')
  [ -n "$hcas" ] && echo "[node_prep_rdma] 复用已验证名单 $DEPLOY_ENV → NCCL_IB_HCA=$hcas"
fi

# ── 回退:sysfs 探测(未经 ib_write 验证)──
if [ -z "$hcas" ]; then
  for d in "$SYSFS"/*; do
    [ -e "$d" ] || continue
    dev=$(basename "$d")
    ll=$(cat "$d"/ports/1/link_layer 2>/dev/null || echo "")
    st=$(cat "$d"/ports/1/state 2>/dev/null | awk '{print $2}')
    rt=$(cat "$d"/ports/1/rate 2>/dev/null | awk '{print $1}')
    nd=$(ls "$d"/device/net 2>/dev/null | head -1)
    [ "$ll" = "$LL_WANT" ] || continue
    [ "$st" = "ACTIVE" ] || continue
    [ "${rt:-0}" -ge "$RATE_MIN" ] 2>/dev/null || continue
    # IFNAMES 白名单(可选):给了就只收 netdev 名在白名单里的口(RoCE 机器排非 fabric 口用)
    if [ -n "$IFNAMES" ]; then case ",$IFNAMES," in *",$nd,"*) ;; *) continue ;; esac; fi
    hcas="${hcas:+$hcas,}$dev"
  done
  [ -n "$hcas" ] && echo "⚠️ [node_prep_rdma] 无 $DEPLOY_ENV,回退 sysfs 探测:NCCL_IB_HCA=$hcas —— 未经 ib_write 验证,建议实测吞吐后确认(sysfs ACTIVE+rate 认不出协商上但吞吐不达标的口)"
fi
# No usable port is not a failure. The list is a convenience for workloads that
# want to pin themselves to the fabric ports; the modules above are what the
# node actually needs, and they are already in place. Failing here used to take
# the whole play down on a host whose FABRIC was guessed wrong -- most often a
# RoCE fabric, which looks like InfiniBand from /sys/class/infiniband alone.
# An existing list is left as it is rather than emptied.
if [ -z "$hcas" ]; then
  echo "⚠️ [node_prep_rdma] no usable $LL_WANT port (checked link/rate>=$RATE_MIN${IFNAMES:+, ifnames∈$IFNAMES}); RDMA modules are in place, port list not written" >&2
  exit 0
fi
mkdir -p "$GPUNODE"
# NCCL_SOCKET_IFNAME 固定 eth0(k8s Flannel pod 网,所有节点一致),这里只写 IB_HCA
echo "NCCL_IB_HCA=$hcas" > "$GPUNODE/nccl-ib.env"
echo "[node_prep_rdma] $(hostname): NCCL_IB_HCA=$hcas  (FABRIC=$FABRIC rate>=$RATE_MIN)"
echo "[node_prep_rdma] /dev/infiniband: $(ls /dev/infiniband 2>/dev/null | tr '\n' ' ')"
