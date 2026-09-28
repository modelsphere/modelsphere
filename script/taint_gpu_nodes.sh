#!/usr/bin/env bash
#
# taint_gpu_nodes.sh — 给集群里所有加速卡节点打 compute-only 污点
#                      (默认 NVIDIA;RESOURCE 可指向别的加速卡资源名)
#
# 污点：nvidia.com/gpu=compute-only:NoSchedule
#       没有对应 toleration 的 Pod 不会再被调度到 GPU 节点上（已在跑的不动）。
#
# 识别 GPU 节点用两个信号取并集：
#   ① .status.capacity["nvidia.com/gpu"] > 0   —— device-plugin 已上报
#   ② label nvidia.com/gpu.present=true        —— NFD/gpu-operator 打的，
#      device-plugin 还没起来的节点只有这个，漏了会导致污点打不全
#
# 用法：
#   bash script/taint_gpu_nodes.sh            # dry-run，只列出会动哪些节点
#   bash script/taint_gpu_nodes.sh --apply    # 真正打污点（幂等，--overwrite）
#   bash script/taint_gpu_nodes.sh --remove   # 摘掉污点（回滚用）
#
set -euo pipefail

# RESOURCE is any accelerator's extended-resource name -- not just NVIDIA's, and
# not just today's two. It doubles as the taint key and as the `<key>.present`
# label, which is how NVIDIA's, Huawei's and (presumably) the next vendor's
# operators all spell it. Override it for a non-NVIDIA node pool; everything
# below is written in terms of it, none of it NVIDIA- or Ascend-specific:
#   RESOURCE=huawei.com/Ascend910 bash script/taint_gpu_nodes.sh --apply
TAINT_KEY="${RESOURCE:-nvidia.com/gpu}"
TAINT_VALUE="compute-only"
TAINT_EFFECT="NoSchedule"
# jsonpath/custom-columns need the dots in the key escaped, the rest do not.
TAINT_KEY_ESC=${TAINT_KEY//./\\.}

mode="dry-run"
case "${1:-}" in
"") ;;
--apply) mode="apply" ;;
--remove) mode="remove" ;;
*)
    echo "用法: $0 [--apply|--remove]" >&2
    exit 2
    ;;
esac

# 先探一下集群通不通。不然 kubectl 连不上时两个查询都静默返回空，
# 会被下面误报成"集群里没有 GPU 节点"。
if ! kubectl get nodes -o name >/dev/null 2>&1; then
    echo "连不上集群（context: $(kubectl config current-context 2>/dev/null || echo unknown)）" >&2
    exit 1
fi

# 两个信号各查一次，合并去重取并集。
# 任一条查询失败（如 label 不存在）都不应中断脚本，所以各自 || true。
nodes_by_label=$(kubectl get nodes -l "${TAINT_KEY}.present=true" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

# capacity 里的 key 带点号，用 custom-columns + 转义点号取，比 jsonpath filter 稳。
# 没上报的节点该列是 <none>。
nodes_by_capacity=$(kubectl get nodes --no-headers \
    -o custom-columns="NAME:.metadata.name,GPU:.status.capacity.${TAINT_KEY_ESC}" 2>/dev/null |
    awk '$2 != "<none>" && $2 != "0" && $2 != "" {print $1}' || true)

gpu_nodes=$(printf '%s\n%s\n' "$nodes_by_label" "$nodes_by_capacity" | sed '/^$/d' | sort -u)

if [ -z "$gpu_nodes" ]; then
    echo "没找到任何 ${TAINT_KEY} 节点（label ${TAINT_KEY}.present / capacity ${TAINT_KEY} 都为空）"
    exit 1
fi

echo "${TAINT_KEY} 节点 ($(echo "$gpu_nodes" | wc -l | tr -d ' ') 个):"
echo "$gpu_nodes" | sed 's/^/  /'
echo ""

case "$mode" in
dry-run)
    echo "[dry-run] 将执行："
    echo "$gpu_nodes" | while read -r n; do
        echo "  kubectl taint nodes $n ${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT} --overwrite"
    done
    echo ""
    echo "确认无误后加 --apply 真正执行。"
    ;;
apply)
    echo "$gpu_nodes" | while read -r n; do
        kubectl taint nodes "$n" "${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT}" --overwrite
    done
    ;;
remove)
    echo "$gpu_nodes" | while read -r n; do
        # key=value:effect- 只摘掉完全匹配的那条，节点上没有时 kubectl 会报 not found，忽略。
        kubectl taint nodes "$n" "${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT}-" 2>/dev/null ||
            echo "  $n: 没有该污点，跳过"
    done
    ;;
esac
