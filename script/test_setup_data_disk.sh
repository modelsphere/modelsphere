#!/usr/bin/env bash
#
# test_setup_data_disk.sh — setup_data_disk.sh 的场景测试(本机跑,不碰真盘)。
#
# 手法:造一批假的 blkid / parted / mkfs.xfs / mount / mountpoint / findmnt /
#   systemctl / lsblk / du / mv 放进 PATH 最前面,盘的状态存成临时目录里的文件;
#   被测脚本设 TESTROOT 后把 fstab、/var/lib 也挪进临时目录,于是「探签名 → 决定
#   格式化与否 → 停服务 → 搬数据 → bind → 起服务」这条链能在 macOS 上真跑一遍。
#   真格式化的那一步是假的,**要不要格式化的判断是真的** —— 这正是要守住的地方。
#
# 用法:bash script/test_setup_data_disk.sh
#
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/setup_data_disk.sh"
PASS=0; FAIL=0

# ── 假工具:全部读写 $ST 下的状态文件 ──
make_shims() {
  mkdir -p "$BIN"
  cat > "$BIN/blkid" <<'EOF'
#!/bin/sh
# blkid [-p] -s TYPE|PTTYPE|UUID -o value DEV
what=""; dev=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) what="$2"; shift 2 ;;
    -p|-o) [ "$1" = "-o" ] && shift; shift ;;
    *) dev="$1"; shift ;;
  esac
done
key=$(printf '%s' "$dev" | tr '/' '_')
case "$what" in
  TYPE)   f="$ST/fs/$key" ;;
  PTTYPE) f="$ST/pt/$key" ;;
  UUID)   f="$ST/uuid/$key" ;;
esac
[ -s "$f" ] || exit 2
cat "$f"
EOF
  cat > "$BIN/parted" <<'EOF'
#!/bin/sh
# parted [-s] [-a optimal] <dev> <mklabel gpt | mkpart primary 0% 100%>
dev=""; op=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--script)    shift ;;
    -a|--align)     shift 2 ;;
    mklabel|mkpart) op="$1"; shift ;;
    *)              [ -z "$dev" ] && [ -z "$op" ] && dev="$1"; shift ;;
  esac
done
key=$(printf '%s' "$dev" | tr '/' '_')
if [ "$op" = mklabel ]; then echo gpt > "$ST/pt/$key"; echo "parted mklabel $dev" >> "$ST/log"; fi
if [ "$op" = mkpart ]; then : > "${dev}p1"; echo "parted mkpart $dev" >> "$ST/log"; fi
EOF
  cat > "$BIN/mkfs.xfs" <<'EOF'
#!/bin/sh
dev="$1"; key=$(printf '%s' "$dev" | tr '/' '_')
echo xfs > "$ST/fs/$key"; echo "UUID-$key" > "$ST/uuid/$key"
printf 'UUID-%s\t%s\n' "$key" "$dev" >> "$ST/uuidmap"
echo "mkfs.xfs $dev" >> "$ST/log"
EOF
  cat > "$BIN/mount" <<'EOF'
#!/bin/sh
# mount <path> —— 照 fstab 里那一行挂;这一步顺带验证脚本写进 fstab 的行是能用的
target="$1"
line=$(awk -v p="$target" '$0 !~ /^[[:space:]]*#/ && NF >= 2 && $2 == p' "$TESTROOT/etc/fstab" | tail -1)
[ -n "$line" ] || { echo "mount: $target 不在 fstab 里" >&2; exit 1; }
src=$(echo "$line" | awk '{print $1}')
case "$src" in
  UUID=*) u=${src#UUID=}
          src=$(awk -F'\t' -v u="$u" '$1 == u {d = $2} END {print d}' "$ST/uuidmap") ;;
esac
[ -n "$src" ] || { echo "mount: fstab 里的 UUID 找不到对应设备" >&2; exit 1; }
printf '%s\t%s\n' "$src" "$target" >> "$ST/mounted"
echo "mount $src -> $target" >> "$ST/log"
EOF
  cat > "$BIN/mountpoint" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
awk -F'\t' -v p="$1" '$2 == p {found=1} END {exit !found}' "$ST/mounted"
EOF
  cat > "$BIN/findmnt" <<'EOF'
#!/bin/sh
for a in "$@"; do p="$a"; done
awk -F'\t' -v p="$p" '$2 == p {s=$1} END {if (s == "") exit 1; print s}' "$ST/mounted"
EOF
  cat > "$BIN/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
  is-active) shift; [ "$1" = "--quiet" ] && shift
             grep -qx "$1" "$ST/units" ;;
  stop)  grep -vx "$2" "$ST/units" > "$ST/units.t" || true; mv "$ST/units.t" "$ST/units"
         echo "stop $2" >> "$ST/log" ;;
  start) echo "$2" >> "$ST/units"; echo "start $2" >> "$ST/log" ;;
esac
EOF
  cat > "$BIN/lsblk" <<'EOF'
#!/bin/sh
for a in "$@"; do dev="$a"; done
awk -F'\t' -v d="$dev" 'index($1, d) == 1 {print $2}' "$ST/mounted"
EOF
  cat > "$BIN/udevadm" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat > "$BIN/du" <<'EOF'
#!/bin/sh
printf '42G\t%s\n' "$2"
EOF
  # macOS 的 mv 没有 GNU 的 -t,节点上是 GNU coreutils;这里翻译一下
  cat > "$BIN/mv" <<'EOF'
#!/bin/sh
if [ "$1" = "-t" ]; then
  dst="$2"; shift 2; [ "$1" = "--" ] && shift
  for f in "$@"; do /bin/mv "$f" "$dst/"; done
else
  exec /bin/mv "$@"
fi
EOF
  chmod +x "$BIN"/*
}

# ── 每个场景一套干净的假机器 ──
setup_env() {
  TESTROOT=$(mktemp -d); ST="$TESTROOT/.state"; BIN="$TESTROOT/.bin"
  export TESTROOT ST
  mkdir -p "$ST/fs" "$ST/pt" "$ST/uuid" "$TESTROOT/etc" "$TESTROOT/var/lib" "$TESTROOT/mnt" "$TESTROOT/dev"
  : > "$ST/mounted"; : > "$ST/units"; : > "$ST/log"; : > "$ST/uuidmap"
  printf '%s\n' \
    '# /etc/fstab 原有内容' \
    'UUID=root-uuid / ext4 defaults 0 1' \
    'UUID=boot-uuid /boot ext4 defaults 0 2' > "$TESTROOT/etc/fstab"
  make_shims
  PATH="$BIN:$PATH"
}
dev()      { : > "$TESTROOT/dev/$1"; }                                   # 造一个"块设备"
sig()      { k=$(printf '%s' "$TESTROOT/dev/$1" | tr '/' '_')
             echo "$2" > "$ST/fs/$k"; echo "UUID-$1" > "$ST/uuid/$k"
             printf 'UUID-%s\t%s\n' "$1" "$TESTROOT/dev/$1" >> "$ST/uuidmap"; }
pt()       { echo "$2" > "$ST/pt/$(printf '%s' "$TESTROOT/dev/$1" | tr '/' '_')"; }
active()   { for u in "$@"; do echo "$u" >> "$ST/units"; done; }
data()     { mkdir -p "$TESTROOT/var/lib/$1"; echo payload > "$TESTROOT/var/lib/$1/$2"; }
sut()      { TESTROOT="$TESTROOT" DISK="$TESTROOT/dev/$1" MOUNT="$TESTROOT/mnt/disk0" \
             PATH="$BIN:$PATH" bash "$SUT" 2>&1; }

ok()   { PASS=$((PASS+1)); printf '    ✓ %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '    ✗ %s\n' "$1"; }
has()  { case "$OUT" in *"$1"*) ok "$2" ;; *) no "$2 —— 输出里没有 '$1'" ;; esac; }
hasnt(){ case "$OUT" in *"$1"*) no "$2 —— 输出里不该有 '$1'" ;; *) ok "$2" ;; esac; }
logis(){ got=$(tr '\n' '|' < "$ST/log"); [ "$got" = "$1" ] && ok "$2" || no "$2 —— 实际: $got"; }
scen() { printf '\n== %s ==\n' "$1"; }

# ────────────────────────────────────────────────────────────────────
scen "① 全新空盘:建 GPT + mkfs + 挂载 + 建 bind"
setup_env; dev nvme0n1
OUT=$(sut nvme0n1); rc=$?
[ $rc = 0 ] && ok "退出码 0" || no "退出码 $rc"
has "整盘干净" "识别为空盘"
has "mkfs.xfs" "格式化了"
has "RESULT: changed=yes" "上报 changed"
grep -q "disk0 xfs defaults,noatime" "$TESTROOT/etc/fstab" && ok "fstab 有数据盘条目" || no "fstab 缺数据盘条目"
grep -q "var/lib/docker none bind" "$TESTROOT/etc/fstab" && ok "fstab 有 docker bind 条目" || no "fstab 缺 bind 条目"
# 数据盘那行必须排在 bind 之前,否则 mount -a 会 bind 到还没挂盘的空目录上
[ "$(grep -n 'disk0 xfs' "$TESTROOT/etc/fstab" | cut -d: -f1)" -lt \
  "$(grep -n 'none bind' "$TESTROOT/etc/fstab" | head -1 | cut -d: -f1)" ] \
  && ok "fstab 里数据盘排在 bind 之前" || no "fstab 顺序反了,开机 bind 会挂到空目录"

scen "② 盘上已有 ext4 分区:不许格式化"
setup_env; dev nvme0n1; dev nvme0n1p1; pt nvme0n1 gpt; sig nvme0n1p1 ext4
OUT=$(sut nvme0n1)
has "已是 ext4 文件系统 → 复用" "认出已有文件系统"
hasnt "mkfs" "没有格式化"
hasnt "parted" "没有动分区表"
grep -q "disk0 ext4 defaults,noatime" "$TESTROOT/etc/fstab" && ok "按 ext4 而不是 xfs 挂载" || no "挂载类型不对"

scen "③ 整盘文件系统(无分区表):认它,不拿 GPT 盖上去"
setup_env; dev nvme0n1; sig nvme0n1 xfs
OUT=$(sut nvme0n1)
has "整盘已是 xfs 文件系统 → 复用" "认出整盘文件系统"
hasnt "mkfs" "没有格式化"
hasnt "parted" "没有动分区表"

scen "④ LVM/RAID/LUKS 成员盘:拒绝动手"
for s in LVM2_member linux_raid_member crypto_LUKS; do
  setup_env; dev nvme0n1; sig nvme0n1 "$s"
  OUT=$(sut nvme0n1); rc=$?
  [ $rc != 0 ] && ok "$s → 非零退出" || no "$s → 竟然退出 0"
  has "这盘有主,拒绝动它" "$s → 报错说清楚"
  hasnt "mkfs" "$s → 没有格式化"
done

scen "⑤ docker/containerd 在跑、数据还在根盘:停 → 搬 → bind → 起"
setup_env; dev nvme0n1
active docker.socket docker.service containerd.service
data docker image-blob; data docker .hidden-state; data containerd meta.db
OUT=$(sut nvme0n1)
has "在跑的容器运行时" "发现服务在跑"
logis "parted mklabel $TESTROOT/dev/nvme0n1|parted mkpart $TESTROOT/dev/nvme0n1|mkfs.xfs $TESTROOT/dev/nvme0n1p1|mount $TESTROOT/dev/nvme0n1p1 -> $TESTROOT/mnt/disk0|stop docker.socket|stop docker.service|stop containerd.service|mount $TESTROOT/mnt/disk0/docker -> $TESTROOT/var/lib/docker|mount $TESTROOT/mnt/disk0/containerd -> $TESTROOT/var/lib/containerd|start containerd.service|start docker.service|start docker.socket|" \
      "顺序:挂盘 → 停(socket 先)→ bind → 逆序起(containerd 先)"
[ -f "$TESTROOT/mnt/disk0/docker/image-blob" ] && ok "数据搬到了数据盘" || no "数据没搬过去"
[ -f "$TESTROOT/mnt/disk0/docker/.hidden-state" ] && ok "隐藏文件也搬了" || no "隐藏文件漏了"
[ -f "$TESTROOT/mnt/disk0/containerd/meta.db" ] && ok "containerd 数据也搬了" || no "containerd 数据没搬"
[ -z "$(ls -A "$TESTROOT/var/lib/docker")" ] && ok "/var/lib/docker 腾空了(能 bind)" || no "/var/lib/docker 还有东西"

scen "⑥ 已经装好的机器再跑一遍:幂等,不停服务"
# 承接场景 ⑤ 的那台机器(盘已挂、bind 已在、服务已起)
OUT=$(sut nvme0n1)
has "已经是挂载点 → 跳过" "认出 bind 已就位"
has "RESULT: changed=no" "上报没改动"
hasnt "stop docker" "没有再停服务"
hasnt "mkfs" "没有再格式化"
before=$(md5 -q "$TESTROOT/etc/fstab" 2>/dev/null || md5sum "$TESTROOT/etc/fstab")
OUT=$(sut nvme0n1)
after=$(md5 -q "$TESTROOT/etc/fstab" 2>/dev/null || md5sum "$TESTROOT/etc/fstab")
[ "$before" = "$after" ] && ok "fstab 一个字节都没动" || no "fstab 被重复改写"
[ -z "$(ls "$TESTROOT"/etc/fstab.bak.* 2>/dev/null)" ] && ok "没攒出多余的 .bak" || no "重复跑攒 .bak 了"
[ "$(grep -n 'disk0 xfs' "$TESTROOT/etc/fstab" | cut -d: -f1)" -lt \
  "$(grep -n 'none bind' "$TESTROOT/etc/fstab" | head -1 | cut -d: -f1)" ] \
  && ok "反复跑也没打乱 fstab 顺序" || no "重复跑把数据盘挪到 bind 后面了"

scen "⑦ 两边都有数据:把盘上那份挪开,活数据搬进来"
# 盘上本来就有文件系统、装过一轮又重装的机器会落到这里。bind 还没建立,
# 说明跑着的 daemon 用的是根盘那份 —— 数据盘上那份不可能在用。
setup_env; dev nvme0n1; sig nvme0n1 ext4
data docker old-blob
mkdir -p "$TESTROOT/mnt/disk0/docker"; echo x > "$TESTROOT/mnt/disk0/docker/stale-blob"
OUT=$(sut nvme0n1); rc=$?
[ $rc = 0 ] && ok "退出码 0(不再中止)" || no "退出码 $rc"
has "旧数据改名挪到" "说清楚挪开了什么"
[ -f "$TESTROOT/mnt/disk0/docker/old-blob" ] && ok "活数据搬上了数据盘" || no "活数据没搬过去"
[ -z "$(ls -A "$TESTROOT/var/lib/docker")" ] && ok "/var/lib/docker 腾空了(能 bind)" || no "/var/lib/docker 还有东西"
grep -qx x "$TESTROOT"/mnt/disk0/docker.stale.*/stale-blob 2>/dev/null \
  && ok "旧数据改名保留,内容完整" || no "旧数据没保住"

scen "⑦b ON_CONFLICT=fail:回到停下等人工"
setup_env; dev nvme0n1; sig nvme0n1 ext4
data docker old-blob
mkdir -p "$TESTROOT/mnt/disk0/docker"; echo x > "$TESTROOT/mnt/disk0/docker/stale-blob"
OUT=$(ON_CONFLICT=fail sut nvme0n1); rc=$?
unset ON_CONFLICT
[ $rc != 0 ] && ok "非零退出" || no "竟然退出 0"
has "停下等人工确认" "报错说清楚"
[ -f "$TESTROOT/var/lib/docker/old-blob" ] && ok "原数据原地未动" || no "原数据被动了"
[ -f "$TESTROOT/mnt/disk0/docker/stale-blob" ] && ok "盘上那份也原地未动" || no "盘上那份被动了"

scen "⑧ DRY_RUN:只说不做"
setup_env; dev nvme0n1; active docker.service
data docker blob
OUT=$(DRY_RUN=1 sut nvme0n1); rc=$?
[ $rc = 0 ] && ok "退出码 0" || no "退出码 $rc"
has "DRY-RUN 将执行" "打印了计划"
has "RESULT: changed=no (dry-run)" "上报没改动"
[ ! -s "$ST/log" ] && ok "一个真动作都没执行" || no "居然动手了:$(cat "$ST/log")"
grep -q disk0 "$TESTROOT/etc/fstab" && no "fstab 被改了" || ok "fstab 没被改"

printf '\n通过 %d,失败 %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
