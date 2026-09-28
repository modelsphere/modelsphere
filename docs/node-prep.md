# Node prep, in detail

[README step 2](../README.md#2-node-prep-ansible) has the table of what lands on
a node and the command that puts it there. This document is for when one of
those tasks does something you did not expect, and for the knobs that are not
worth putting in the README.


## The kernel

`setup-k8s-online` installs an HWE kernel only where the running kernel is below
`k8s_min_kernel` (default `5.10`), and it takes effect on reboot.
`k8s_install_hwe_kernel` is `auto` (default), `always` or `never`.

**That floor exists for Cilium**, whose 1.20 datapath needs 5.10 or newer --
below it the agent crash-loops with `requirements failed`. The helper it names
is usually `bpf_get_current_cgroup_id()`, which landed in 4.18, so the message
understates the kernel it actually wants: `CheckRequirements()` also demands
`bpf_redirect_neigh()` and `bpf_redirect_peer()`, both 5.10, and reports
whichever check fails first. Ubuntu 22.04's own 5.15 is already fine, so
the task usually reports `no HWE kernel needed, skipped`. **On a cluster running
a different CNI this requirement does not apply**; whatever that CNI asks for
does, and you can lower or disable the floor accordingly.

Two things make it worth getting right rather than discovering later:

- **A new kernel needs an NVIDIA module built for it.** With a `.run` driver
  installed without `--dkms`, nothing rebuilds it and the node reboots with no
  GPU -- so the task refuses to install a kernel on such a node. Reinstall the
  driver with DKMS, or build `nvidia.ko` yourself and set
  `k8s_hwe_nvidia_ack=true` for that host.
- **A crash-looping Cilium agent does not look like a CNI problem.** Cilium
  taints the node `node.cilium.io/agent-not-ready:NoSchedule` until the agent is
  up, so pods sit `Pending` -- including later releases' hook Jobs, which makes
  `helmfile apply` hang with nothing pointing at the kernel.

## The data disk

`setup-disk` mounts a spare disk and moves `/var/lib/docker` and
`/var/lib/containerd` onto it, so images do not fill the root filesystem.

Two inventory variables drive it, per host or per group:

| variable | default | what it is |
|---|---|---|
| `k8s_data_disk` | `/dev/nvme0n1` | the disk to use |
| `data_mount` | `/mnt/disk0` | where it is mounted |

```ini
[gpu-h100]
node-1 k8s_data_disk=/dev/nvme1n1 data_mount=/mnt/data
```

The disk is reused rather than reformatted where possible: one that already
carries a filesystem is mounted as it is, and only one with neither a
filesystem nor a partition table gets a GPT and `mkfs`. A device carrying an
LVM, RAID, LUKS, swap or ZFS signature belongs to something else, so the task
refuses it and stops the run. Moving the two directories does stop `docker` and
`containerd`, so the task is not free on a busy node.

A different `data_mount` also means setting two values that name paths under
it, in the environment file and in the model file — they are not derived from
`data_mount`:

| value | default in this repo | what it is |
|---|---|---|
| `llmGateway.hostPath` | `/mnt/disk0/bodylog-sinks` | where bodylog writes |
| `model.localPath` (a `MODELS=` file) | `/mnt/disk0/models/<org>/<model>` | where the weights are |

This disk is for container images. It is **not** the Ceph OSD disk — those are
named separately under `ceph.nodes` in the environment file, and must be
different devices.

A node with a single disk holding the root filesystem skips the task: leave
`SETUP_DISK` unset for `setup-all`, and keep the node out of a `make
setup-disk` with `LIMIT`. Container storage then stays on the root filesystem.

## Older distributions

On Ubuntu 22.04 or newer these three are already satisfied; on anything older
each has to be arranged by hand:

- **cgroup v2** -- kubeadm's preflight refuses to run on v1. Check with
  `stat -fc %T /sys/fs/cgroup` (`cgroup2fs` is v2).
- **A kernel Cilium's datapath accepts** -- 5.10 or newer. Check with
  `uname -r`.
- **A containerd from Docker's apt repo.** `setup-k8s-online` pins
  `containerd.io=2.3.5-1~ubuntu.<version>~<codename>` (override with
  `k8s_containerd_version`), and Docker builds that package per Ubuntu
  release -- so on a release it no longer publishes for, the pinned install
  has nothing to fetch and you bring your own containerd. 1.7 is the real
  floor, which is what nerdctl needs; the pin sits higher only to keep a
  fleet on one version.

The first two report the same error either way -- `Require support for
bpf_get_current_cgroup_id()` -- so satisfying one tells you nothing about the
other.

A node that is not Ubuntu at all -- a vendor OS, possibly aarch64, with its own
accelerator -- runs the same playbook with `k8s_install_method=binary`, which
takes the Kubernetes binaries from upstream releases instead of apt. See
[add-ascend-node.md](add-ascend-node.md).

## GPU nodes

`gpu-prep` puts these in place on each GPU node:

| action | why | skipped when |
|---|---|---|
| RDMA modules loaded, and on boot | GPUDirect RDMA | `rdma_fabric=none` |
| `nvidia_peermem` loaded, and on boot | lets an HCA DMA straight into GPU memory | `rdma_fabric=none`, or the running driver does not ship it (warns) |
| GPU persistence mode enabled | — | — |
| `nvidia-fabricmanager` enabled and running | NVSwitch / HGX hosts need it | no fabricmanager binary on the host |
| `nvidia-cdi-refresh.service` disabled | it conflicts with the GPU Operator | already disabled |
| PCIe ACS redirect cleared | it routes peer-to-peer DMA through the IOMMU and destroys GPUDirect throughput | — |

ACS is cleared by `disable-acs.service`, a oneshot, because the register it
writes resets on every boot -- so there is nothing to rerun after a reboot.
`make audit-gpu` checks both halves: `acs_srcvalid=0` now, and the unit enabled.

`rdma_fabric` decides whether the RDMA rows run at all, and usually needs no
setting. `auto`, the default, runs them when the node has any RDMA device and
skips them when `/sys/class/infiniband` is empty -- a GPU node on plain
Ethernet. The rest of the table runs either way, the ACS unit included, which
GPU-to-GPU P2P over PCIe needs as much as GPUDirect RDMA does; `audit-gpu`
marks the RDMA checks not applicable there.

**A ConnectX NIC used only for Ethernet still appears under
`/sys/class/infiniband`**, so `auto` runs the RDMA rows on such a host. They
cost little and break nothing; `rdma_fabric=none` skips them:

```ini
[gpu-h100]
10.0.0.41 rdma_fabric=none
```

### Auditing

`audit-gpu` runs three read-only scripts per node and **reports through exit
codes**, so it is usable from CI without grepping text:

| Script | Exit 1 when |
|---|---|
| `script/check_gpu_prep.sh` | any `gpu-prep` item is not in place |
| `nvidia/audit_node.sh` | NVIDIA driver not loaded, `nvidia-cdi-refresh.service` enabled, or an HCA has no netdev |
| `script/probe_nodes.sh` | never — it describes the box, it has no notion of a required state |

When you add a prep action, add its check to `check_gpu_prep.sh`. It is the one
file that keeps prep and audit in sync.
