#!/usr/bin/env bash
#
# setup_data_disk.sh — 数据盘初始化 + 容器存储搬迁(每台一次,幂等)。
#
# 铁律:**绝不覆盖已有数据**。
#   blkid -p 直接探设备(不读 cache),-s TYPE 只报文件系统签名 —— 光有 GPT/MBR
#   分区表是探不出 TYPE 的,所以「探到东西」就等于「盘上已经有文件系统」:
#     xfs/ext4/btrfs/...      → 原样复用,不分区、不格式化、按实际类型挂载;
#     LVM2_member / linux_raid_member / crypto_LUKS / swap / zfs_member
#                             → 有主的盘,直接报错退出,要清盘请人工 wipefs;
#     整盘既无签名也无分区表  → 才建 GPT 单分区 + mkfs.$MKFS。
#   整盘文件系统(无分区表,直接 mkfs 在 /dev/nvme0n1 上)是合法布局,认它,
#   不会拿 GPT 盖上去。
#
# 搬迁:docker/containerd 已经在跑、数据还在根盘 /var/lib 下时,
#   先停服务(带上 docker.socket,否则 socket activation 会把 dockerd 半路拉起来,
#   一边搬一边写),整目录 mv 到 $MOUNT,再 bind mount 回 /var/lib,最后按停的
#   逆序起回来(containerd 先于 docker)。/var/lib/xxx 是空的也要停 —— bind mount
#   会把正在运行的 dockerd 手里的目录盖掉,它会继续往被遮住的旧目录写。
#
# 两边都有数据($MOUNT/xxx 非空,/var/lib/xxx 也非空):常见于盘上本来就有文件系统、
#   装过一轮又重装的机器。这时候**根盘那份才是活的** —— bind 还没建立,跑着的
#   daemon 用的就是 /var/lib 下那份;数据盘上那份既然没被 bind 上去,就不可能在用。
#   所以默认把数据盘上的旧目录整个挪到 xxx.stale.<时间戳>(只改名,不删),
#   让活数据搬进来,旧的留给人工处置。ON_CONFLICT=fail 可以回到「停下等人工」。
#
# 用法(节点本机 root 执行,或由 setup_k8s.yaml --tags disk 下发):
#   DISK=/dev/nvme0n1 MOUNT=/mnt/disk0 bash setup_data_disk.sh
#   DRY_RUN=1 DISK=/dev/nvme1n1 bash setup_data_disk.sh      # 只探测 + 打印计划,不动手
#   ON_CONFLICT=fail DISK=/dev/nvme1n1 bash setup_data_disk.sh  # 两边都有数据时停下,不自动挪开
#
set -eu

DISK="${DISK:-/dev/nvme0n1}"
MOUNT="${MOUNT:-/mnt/disk0}"
MKFS="${MKFS:-xfs}"                     # 只在「确实要新建文件系统」时才用得上
DIRS="${DIRS:-docker containerd}"
DRY_RUN="${DRY_RUN:-}"
# 数据盘上目标目录非空、根盘也还有数据时怎么办(见文件头「两边都有数据」):
#   park(默认)= 把数据盘上那份改名挪开,继续搬;fail = 停下等人工确认。
ON_CONFLICT="${ON_CONFLICT:-park}"
# 唯一的测试钩子:script/test_setup_data_disk.sh 会设 TESTROOT,把 fstab / var/lib 挪进
# 临时目录,并允许普通文件冒充块设备(配合同目录下的假 blkid/parted/systemctl shim),
# 这样这套判断逻辑能在没有 Linux 盘的机器上真跑一遍。生产环境不要设。
TESTROOT="${TESTROOT:-}"
FSTAB="$TESTROOT/etc/fstab"
VARLIB="$TESTROOT/var/lib"

# 停的顺序;起的时候反过来。docker.socket 见文件头说明。
UNITS="docker.socket docker.service containerd.service"
# 有主签名:blkid 能探到,但不是能直接 mount 的文件系统 → 一律拒绝动手。
UNSAFE="LVM2_member linux_raid_member crypto_LUKS swap zfs_member"

CHANGED=0
log() { printf '[disk] %s\n' "$*"; }
die() { printf '[disk] ERROR: %s\n' "$*" >&2; exit 1; }

# 所有会改机器状态的动作都走 run:DRY_RUN 下只打印,平时留一行执行痕迹,
# 顺便把「这台机器到底改没改」记进 CHANGED(最后一行输出给 ansible 判 changed)。
run() {
  if [ -n "$DRY_RUN" ]; then printf '[disk] DRY-RUN 将执行: %s\n' "$*"; return 0; fi
  printf '[disk] + %s\n' "$*"
  "$@"
  CHANGED=1
}

# fstab 幂等写入:同一挂载点已有行就**原地替换**,没有才追加到末尾。
# 必须原地替换而不是「删掉再追加」—— 数据盘那行要排在两条 bind 之前,
# 否则 mount -a 会在 $MOUNT 挂上之前先 bind /var/lib/docker,把根盘上那个空目录
# bind 过去,dockerd 起来看到的是空的。顺带:内容没变就一个字节都不写,
# 也就不会每跑一次多攒一个 .bak。有改动返回 0,没改返回 1。
fstab_set() { # $1=what $2=where $3=fstype $4=opts
  _new="$1 $2 $3 $4 0 0"
  _tmp=$(mktemp)
  awk -v p="$2" -v new="$_new" '
    $0 !~ /^[[:space:]]*#/ && NF >= 2 && $2 == p { if (!done) { print new; done = 1 } ; next }
    { print }
    END { if (!done) print new }
  ' "$FSTAB" > "$_tmp"
  if cmp -s "$_tmp" "$FSTAB"; then rm -f "$_tmp"; return 1; fi
  if [ -n "$DRY_RUN" ]; then
    printf '[disk] DRY-RUN 将写 %s: %s\n' "$FSTAB" "$_new"
    rm -f "$_tmp"; return 0
  fi
  cp -a "$FSTAB" "$FSTAB.bak.$(date +%Y%m%d-%H%M%S)"
  cat "$_tmp" > "$FSTAB"        # 覆盖内容而不是 mv,保住原 inode 和权限
  rm -f "$_tmp"
  CHANGED=1
  log "$FSTAB ← $_new"
  return 0
}

isblk()     { if [ -n "$TESTROOT" ]; then [ -e "$1" ]; else [ -b "$1" ]; fi; }
probe()     { blkid -p -s TYPE   -o value "$1" 2>/dev/null || true; }
probe_pt()  { blkid -p -s PTTYPE -o value "$1" 2>/dev/null || true; }
is_unsafe() { case " $UNSAFE " in *" $1 "*) return 0 ;; esac; return 1; }

if [ -z "$TESTROOT" ]; then [ "$(id -u)" = 0 ] || die "要 root"; fi
isblk "$DISK" || die "$DISK 不是块设备"

# nvme/loop/mmcblk 的分区名是 p1 后缀,sd*/vd* 是直接跟 1
case "$DISK" in
  *nvme*|*loop*|*mmcblk*) PART="${DISK}p1" ;;
  *)                      PART="${DISK}1"  ;;
esac

# ── ① 探盘:决定用哪个设备,以及要不要建文件系统 ──
disk_fs=$(probe "$DISK")
part_fs=""
if isblk "$PART"; then part_fs=$(probe "$PART"); fi

if [ -n "$disk_fs" ]; then
  if is_unsafe "$disk_fs"; then
    die "$DISK 上是 $disk_fs 签名(不是能挂的文件系统)。这盘有主,拒绝动它;
       确认要清盘请人工 wipefs -a $DISK,或把 k8s_data_disk 指到别的盘。"
  fi
  TARGET="$DISK"; TARGET_FS="$disk_fs"
  log "$DISK 整盘已是 $disk_fs 文件系统 → 复用,不分区不格式化"
elif [ -n "$part_fs" ]; then
  if is_unsafe "$part_fs"; then
    die "$PART 上是 $part_fs 签名(不是能挂的文件系统)。这盘有主,拒绝动它;
       确认要清盘请人工 wipefs -a $PART,或把 k8s_data_disk 指到别的盘。"
  fi
  TARGET="$PART"; TARGET_FS="$part_fs"
  log "$PART 已是 $part_fs 文件系统 → 复用,不格式化"
else
  # 走到这里说明整盘和 $PART 上都没有文件系统签名 —— 只有这种情况才动分区表/mkfs
  if ! isblk "$PART"; then
    disk_pt=$(probe_pt "$DISK")
    [ -z "$disk_pt" ] || die "$DISK 上已有 $disk_pt 分区表却没有 $PART,盘上可能是别的布局;人工确认后再跑"
    busy=$(lsblk -nro MOUNTPOINT "$DISK" 2>/dev/null | grep -v '^$' || true)
    [ -z "$busy" ] || die "$DISK 上有已挂载的分区($(echo "$busy" | tr '\n' ' ')),拒绝分区"
    log "$DISK 整盘干净(无文件系统、无分区表)→ 建 GPT 单分区"
    run parted -s "$DISK" mklabel gpt
    run parted -s -a optimal "$DISK" mkpart primary 0% 100%
    run udevadm settle
    if [ -z "$DRY_RUN" ] && ! isblk "$PART"; then die "分区建完了但 $PART 没出现"; fi
  fi
  log "$PART 上没有任何文件系统签名 → mkfs.$MKFS"
  run "mkfs.$MKFS" "$PART"
  TARGET="$PART"; TARGET_FS="$MKFS"
fi

# ── ② 挂 $MOUNT(按实际文件系统类型,不是写死 xfs)──
uuid=""
if [ -z "$DRY_RUN" ] || isblk "$TARGET"; then uuid=$(blkid -s UUID -o value "$TARGET" 2>/dev/null || true); fi
if [ -z "$uuid" ]; then
  [ -n "$DRY_RUN" ] || die "拿不到 $TARGET 的 UUID"
  uuid="<新建后才有>"
fi
[ -d "$MOUNT" ] || run mkdir -p "$MOUNT"

if mountpoint -q "$MOUNT"; then
  cur=$(findmnt -no SOURCE "$MOUNT")
  [ "$cur" = "$TARGET" ] || die "$MOUNT 现在挂的是 $cur,不是 $TARGET;人工确认后再跑"
  log "$MOUNT 已挂载($TARGET, $TARGET_FS)"
  fstab_set "UUID=$uuid" "$MOUNT" "$TARGET_FS" "defaults,noatime" || true
else
  fstab_set "UUID=$uuid" "$MOUNT" "$TARGET_FS" "defaults,noatime" || true
  run mount "$MOUNT"
fi

# ── ③ 容器存储:停服务 → 搬数据 → bind mount → 起服务 ──
if [ -z "$DRY_RUN" ] && ! mountpoint -q "$MOUNT"; then die "$MOUNT 没挂上,后面的搬迁会写进根盘,中止"; fi

need_bind=""    # 还不是挂载点 → 这轮要新建 bind mount
need_move=""    # 数据还在根盘的 /var/lib 下 → bind 之前必须先搬走
for d in $DIRS; do
  src="$VARLIB/$d"
  if mountpoint -q "$src"; then log "$src 已经是挂载点 → 跳过"; continue; fi
  need_bind="$need_bind $d"
  if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then need_move="$need_move $d"; fi
done

running=""
if [ -n "$need_bind" ]; then
  for u in $UNITS; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then running="$running $u"; fi
  done
  if [ -n "$running" ]; then
    log "在跑的容器运行时:$running → 先停"
    for u in $running; do run systemctl stop "$u"; done
  fi
fi

for d in $need_move; do
  src="$VARLIB/$d"; dst="$MOUNT/$d"
  if [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
    # 不合并 —— 两份 containerd/docker 状态混在一起会烂得很难看,而且同名子目录
    # 撞上时 GNU mv 会中途报 "Directory not empty" 停在半路。要么挪开,要么停。
    [ "$ON_CONFLICT" = park ] || \
      die "$dst 非空,而 $src 里还有数据 —— ON_CONFLICT=$ON_CONFLICT,停下等人工确认哪份要留"
    stale="$dst.stale.$(date +%Y%m%d-%H%M%S)"
    log "$dst 非空;但 bind 还没建立,在用的是 $src → 旧数据改名挪到 $stale(不删)"
    run mv "$dst" "$stale"
  fi
  [ -d "$dst" ] || run mkdir -p "$dst"
  log "搬迁 $src → $dst($(du -sh "$src" 2>/dev/null | cut -f1))"
  # find -mindepth 1 把隐藏文件也带上(mv src/* 会漏掉 .xxx)
  run find "$src" -mindepth 1 -maxdepth 1 -exec mv -t "$dst" -- {} +
done

for d in $need_bind; do
  src="$VARLIB/$d"; dst="$MOUNT/$d"
  [ -d "$dst" ] || run mkdir -p "$dst"
  [ -d "$src" ] || run mkdir -p "$src"
  fstab_set "$dst" "$src" none bind || true
  run mount "$src"
done

if [ -n "$running" ]; then
  rev=""; for u in $running; do rev="$u $rev"; done      # 逆序:containerd 先于 docker
  log "起回来:$rev"
  for u in $rev; do run systemctl start "$u"; done
fi

# ── ④ 结果 ──
log "数据盘:$TARGET($TARGET_FS, UUID=$uuid)→ $MOUNT"
if mountpoint -q "$MOUNT" 2>/dev/null; then df -h "$MOUNT" | tail -1 | sed 's/^/[disk] /'; fi
for d in $DIRS; do
  if mountpoint -q "$VARLIB/$d" 2>/dev/null; then
    log "$VARLIB/$d ← $(findmnt -no SOURCE "$VARLIB/$d")"
  else
    log "$VARLIB/$d 未挂载${DRY_RUN:+(DRY-RUN)}"
  fi
done
if [ -n "$DRY_RUN" ]; then echo "RESULT: changed=no (dry-run)"
elif [ "$CHANGED" = 1 ]; then echo "RESULT: changed=yes"
else echo "RESULT: changed=no"; fi
