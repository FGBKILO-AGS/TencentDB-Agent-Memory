#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 面板补丁在场性检查（只读）
#
# 两类断言，别混：
#   A) 必须"与镜像不等"：本机补丁打在容器可写层上，重建 hub 容器就回到镜像那份。
#      不等 == 补丁还在；**逐字节相等 == 补丁丢了**。
#   B) 必须"含某个标记"：镜像自带就已满足的项（不靠本机补丁），要盯的是
#      **上游别把它改没了**；对它做 A 类断言会把正确状态误报成丢补丁。
#
# 为什么 A 类不能只看"文件里有没有 isAdmin 这个词"：镜像自带代码里也可能有同名符号，
# 那种断言恒绿。真正不可伪造的判据是容器那份 vs 镜像那份的哈希差。
# 另配一个参照物（确定没被本机改过的文件）：它必须"相等"，若它都不等，说明两侧根本
# 不同源，本次所有 A 类 PASS 作废。
#
# 用法: bash tam-panel-patch-present.sh              # 0=都对  1=有问题  2=跑不动
#       bash tam-panel-patch-present.sh --selftest   # 红绿自证
# ---------------------------------------------------------------------------
set -uo pipefail

HUB="${TDAI_HUB_CONTAINER:-tdai-memory-hub}"
# 单行空格分隔：多行会把换行带进容器侧 `for f in ...`，dash 直接语法错
# （本机实测报 `word unexpected (expecting "do")`）。

# A 类：容器里这份必须 != 镜像里那份
PATCHED_FILES="/app/panel/dist/panel/http/routes/chat-memory.js /app/panel/dist/panel/http/app.js /app/panel/web/dist/assets/main-CdwHEhgx.js"

# B 类：现网那份必须含标记（file:fixed-string 一对多）
MARKER_FILES="/app/panel/dist/panel/http/routes/knowledge/common.js@isCallerSystemAdmin"
MARKER_INDEX="/app/panel/web/dist/index.html"

# 参照物：确定没被本机改过、且**实测存在**的面板文件，用来证明"相等"这个状态本身可测。
# ⚠ 这里曾经踩过一条恒绿：Control 填了 routes/agents.js —— 那个文件在容器和镜像里
# 都不存在，`sha256sum` 那侧回的是 "MISSING …" 文本，两侧截出来的前 64 字符一模一样，
# 于是"参照物与镜像相等（比对链路可信）"照样打 PASS。所以取值必须校验是 64 位十六进制。
CONTROL="/app/panel/dist/panel/http/routes/auth.js"

if ! docker ps --format '{{.Names}}' | grep -qx "$HUB"; then
  echo "  [FAIL] $HUB 没在跑，无法判读面板补丁在场性"; exit 2
fi
IMG="$(docker inspect "$HUB" --format '{{.Config.Image}}')"
[ -n "$IMG" ] || { echo "  [FAIL] 取不到 $HUB 的镜像名"; exit 2; }

hashes_in() {  # $1=执行环境(docker exec 容器名 | docker run 镜像) 之后是 file list
  local mode="$1"; shift
  if [ "$mode" = exec ]; then
    docker exec "$HUB" sh -c "for f in $1; do [ -f \"\$f\" ] && sha256sum \"\$f\" || echo \"MISSING \$f\"; done" 2>/dev/null
  else
    docker run --rm --entrypoint sh "$IMG" -c "for f in $1; do [ -f \"\$f\" ] && sha256sum \"\$f\" || echo \"MISSING \$f\"; done" 2>/dev/null
  fi
}

is_hash() { printf '%s' "${1:-}" | grep -Eq '^[0-9a-f]{64}$'; }

hash_of() { # $1=多行 sha 输出 $2=路径；只有真正的 64 位十六进制才算取到
  local v
  v="$(printf '%s\n' "$1" | grep -F " $2" | head -1 | cut -c1-64)"
  if is_hash "$v"; then printf '%s' "$v"; else printf 'BAD:%s' "$v"; fi
}

scan() {
  local ALL="$PATCHED_FILES $CONTROL"
  local LIVE IMGH f lh ih rc=0 pair pfile pmark refbundle
  LIVE="$(hashes_in exec "$ALL")"
  IMGH="$(hashes_in run  "$ALL")"
  { [ -n "$LIVE" ] && [ -n "$IMGH" ]; } || { echo "  [FAIL] 取哈希失败（容器或镜像起不来）"; return 2; }

  for f in $PATCHED_FILES; do
    lh="$(hash_of "$LIVE" "$f")"; ih="$(hash_of "$IMGH" "$f")"
    case "$lh$ih" in
      BAD:*|BAD*|*BAD:*) echo "  [FAIL] $(basename "$f") 没拿到真哈希（文件不存在或输出被改）：live=$lh image=$ih"; rc=1; continue ;;
    esac
    if [ "$lh" = "$ih" ]; then
      echo "  [FAIL] $(basename "$f") 与镜像自带那份逐字节相等 => 本机补丁不在（hub 容器被重建过？）"
      rc=1
    else
      echo "  [PASS] $(basename "$f") 与镜像那份不同 => 本机补丁在位"
    fi
  done

  # 参照物必须"存在且与镜像相等"
  cl="$(hash_of "$LIVE" "$CONTROL")"; ci="$(hash_of "$IMGH" "$CONTROL")"
  case "$cl$ci" in
    BAD:*|*BAD:*) echo "  [FAIL] 参照物 $(basename "$CONTROL") 取不到哈希 —— 它不存在，这条断言没对象"; rc=1 ;;
    *)
      if [ "$cl" = "$ci" ]; then
        echo "  [PASS] 参照物 $(basename "$CONTROL") 与镜像相等（比对链路可信）"
      else
        echo "  [FAIL] 参照物与镜像不等 —— 比对两侧不同源，上面 A 类 PASS 全部作废"; rc=1
      fi ;;
  esac

  # B 类：标记在场
  for pair in $MARKER_FILES; do
    pfile="${pair%%@*}"; pmark="${pair##*@}"
    if docker exec "$HUB" sh -c "grep -qF -- '$pmark' '$pfile'" 2>/dev/null; then
      echo "  [PASS] $(basename "$pfile") 含 $pmark（该项由镜像自带，非本机补丁）"
    else
      echo "  [FAIL] $(basename "$pfile") 里找不到 $pmark —— 上游回归或换构建把它改没了"; rc=1
    fi
  done

  # B 类：index.html 引用的入口 bundle 必须真实存在（守"绝不改名"那条）
  refbundle="$(docker exec "$HUB" sh -c "grep -o 'assets/main-[A-Za-z0-9_-]*\.js' $MARKER_INDEX | sort -u" 2>/dev/null | head -1)"
  if [ -z "$refbundle" ]; then
    echo "  [FAIL] $MARKER_INDEX 里抽不到入口 bundle 名"; rc=1
  elif docker exec "$HUB" sh -c "[ -f /app/panel/web/dist/$refbundle ]" 2>/dev/null; then
    echo "  [PASS] index.html 引用的 $refbundle 确实存在（改名会在这里暴露）"
  else
    echo "  [FAIL] index.html 引用 $refbundle，但该文件不存在 —— 就是'改名导致双模块图'那类事故"; rc=1
  fi

  return $rc
}

if [ "${1:-}" = "--selftest" ]; then
  echo "== 正常态（期望 0）=="
  scan; NORM=$?
  echo
  echo "== 红态1：A 类塞一个'本就与镜像相等'的真实文件 task.js（必须判补丁丢了）=="
  PF_BAK="$PATCHED_FILES"; CT_BAK="$CONTROL"
  PATCHED_FILES="/app/panel/dist/panel/http/routes/task.js"
  CONTROL="/app/panel/dist/panel/http/routes/auth.js"
  scan; REDA=$?
  PATCHED_FILES="$PF_BAK"; CONTROL="$CT_BAK"
  echo
  echo "== 红态2：路径根本不存在（必须出声，不许两侧都'MISSING 文本相等'蒙成绿）=="
  PF_BAK="$PATCHED_FILES"
  PATCHED_FILES="/app/panel/dist/panel/http/routes/no_such_route.js"
  scan; REDMISS=$?
  PATCHED_FILES="$PF_BAK"
  echo
  echo "== 红态3：B 类标记换成一个不存在的串（必须 FAIL）=="
  MF_BAK="$MARKER_FILES"; MARKER_FILES="/app/panel/dist/panel/http/routes/knowledge/common.js@this_marker_does_not_exist_zzz"
  scan; REDB=$?
  MARKER_FILES="$MF_BAK"
  echo
  echo "== 结论 normal=$NORM redA=$REDA redMissing=$REDMISS redB=$REDB（期望 0 / 非0 / 非0 / 非0）=="
  if [ "$NORM" = 0 ] && [ "$REDA" != 0 ] && [ "$REDMISS" != 0 ] && [ "$REDB" != 0 ]; then
    echo "SELFTEST PASS  相等判丢、缺失出声、标记缺失判坏 —— 三种坏法都能响"
    exit 0
  fi
  echo "SELFTEST FAIL  这条闸不可信，别当它存在"
  exit 1
fi

scan
exit $?
