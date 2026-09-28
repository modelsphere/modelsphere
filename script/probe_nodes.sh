#!/usr/bin/env bash
#
# probe_nodes.sh — 体检候选节点
#
# 用途：部署前确认这两台机器是否可用（GPU 空闲、模型在位、IB 状态、
#       是否已有生产容器、OS/内核、是否已装 k8s 组件）。只读，不改任何东西。
#
# 用法（在跳板上跑，串行探测，不 fan-out）：
#   bash probe_nodes.sh [host1 host2 ...]
#
set -u
echo "-- hostname / os --"
hostname; . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"; uname -r
echo "-- host ip (non-docker) --"
ip -4 addr show | grep 'inet ' | grep -vE '127.0.0|172.1[78].0|docker|br-|cali|veth' | awk '{print $2}'
echo "-- gpu (count / model / free mem) --"
nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo "NO nvidia-smi"
echo "-- gpu compute processes (should be empty if free) --"
nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv,noheader 2>/dev/null || true
echo "-- docker containers (running) --"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || echo "NO docker"
echo "-- models on /mnt/disk0/models --"
ls -1 /mnt/disk0/models/ 2>/dev/null | grep -iE 'kimi|glm' || echo "  (none matching kimi/glm)"
echo "-- disk /mnt/disk0 --"
df -h /mnt/disk0 2>/dev/null | tail -1
echo "-- infiniband (dev / state / rate / link_layer) --"
for dev in $(ls /sys/class/infiniband/ 2>/dev/null); do
  st=$(cat /sys/class/infiniband/$dev/ports/1/state 2>/dev/null)
  rt=$(cat /sys/class/infiniband/$dev/ports/1/rate 2>/dev/null)
  ll=$(cat /sys/class/infiniband/$dev/ports/1/link_layer 2>/dev/null)
  echo "  $dev  state=$st  rate=$rt  link=$ll"
done
echo "-- cached NCCL_IB_HCA (/root/deploy/env) --"
grep '^NCCL_IB_HCA=' /root/deploy/env 2>/dev/null || echo "  (not cached)"
echo "-- k8s components already installed? --"
for b in kubeadm kubelet kubectl crictl containerd; do
  p=$(command -v $b 2>/dev/null); echo "  $b: ${p:-NOT installed}"
done
systemctl is-active kubelet 2>/dev/null | sed 's/^/  kubelet.service: /'
echo "-- host-level prereqs (ACS / peermem / persistence) --"
echo "  acs_srcvalid_count=$(lspci -vvv 2>/dev/null | grep -c 'ACSCtl.*SrcValid+')"
# 读 /proc/modules 而不是 `lsmod | grep -q`:pipefail 下 grep -q 命中即退出会让 lsmod
# 吃 SIGPIPE(141),管道判假 → 刚 modprobe 上的模块被误报成 NOT loaded。
grep -q '^nvidia_peermem ' /proc/modules && echo "  nvidia_peermem: loaded" || echo "  nvidia_peermem: NOT loaded"
nvidia-smi -q 2>/dev/null | grep -m1 'Persistence Mode' | sed 's/^ */  /'
echo "-- cpu / mem --"
echo "  cpus=$(nproc)  mem=$(free -g | awk '/Mem:/{print $2"G"}')"
