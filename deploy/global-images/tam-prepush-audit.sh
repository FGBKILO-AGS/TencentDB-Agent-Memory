#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 推之前问一件事：要带出去的**对象**（不只是最终树）里有没有明文密钥、
# 本机身份、绝对路径。历史里"加了又删"的字节同样会被推上去，所以扫的是
# rev-list 的 blob 集合，不是工作区。
#
# 本脚本自身只写**形状**，绝不写具体 id / 具体 key —— 否则它一提交就把
# 它想拦的东西发布出去了（这条是被自己的第一版逼出来的）。
#
# 用法: bash tam-prepush-audit.sh [基线ref]      默认 origin/feat/server_team
#       退出码 0=全部形状零命中  1=有命中（逐条看）  2=跑不动
# ---------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null || { echo "ABORT: 找不到仓库根"; exit 2; }
BASE="${1:-origin/feat/server_team}"

git rev-parse --verify "$BASE" >/dev/null 2>&1 || { echo "ABORT: 基线 ref 不存在（$BASE）—— 空集不等于干净"; exit 2; }

TMP="$(mktemp)" || { echo "ABORT: mktemp 失败"; exit 2; }
trap 'rm -f "$TMP"' EXIT

git rev-list --objects "$BASE..HEAD" | awk '{print $1}' | while read -r o; do
  [ "$(git cat-file -t "$o" 2>/dev/null)" = blob ] && echo "$o"
done > "$TMP"

NBLOBS=$(grep -c . "$TMP")
NCOMMIT=$(git rev-list --count "$BASE..HEAD")
echo "commits=$NCOMMIT blobs_to_scan=$NBLOBS base=$BASE"
[ "$NBLOBS" -gt 0 ] || { echo "ABORT: 扫到 0 个 blob —— 判据没跑，不算通过"; exit 2; }
[ "$NCOMMIT" -gt 0 ] || { echo "ABORT: 0 个提交，没有可推的东西"; exit 2; }

FAIL=0
while IFS='|' read -r label ere; do
  hits="$(while read -r o; do
            git cat-file blob "$o" 2>/dev/null | grep -nE "$ere" | sed "s|^|${o:0:8} |"
          done < "$TMP")"
  c=0; [ -n "$hits" ] && c="$(printf '%s\n' "$hits" | grep -c .)"
  printf '  %-18s %s\n' "$label" "$c"
  if [ "$c" -gt 0 ]; then
    FAIL=1
    printf '%s\n' "$hits" | head -5 | sed -E \
      -e 's/sk-[A-Za-z0-9]{12,}/sk-****(redacted)/g' \
      -e 's/(team|usr|agt)-[a-z0-9]{8,}/\1-****/g' \
      -e 's#[A-Za-z]:\\\\?[Uu]sers\\\\[^"'"'"' :]+#<HOME>\\****#g' \
      -e 's#[A-Za-z]:\\[A-Za-z0-9_]+\\#<DRIVE>\\***\\#g' \
      -e 's#^/#[blob]/#' \
      -e 's/^/      /'
  fi
done <<'PATTERNS'
SECRET_SHAPE|sk-[A-Za-z0-9]{12,}
USERKEY_FIELD|PROXY_USER_KEY|x-tdai-user-key
LOCAL_ID_SHAPE|(team|usr|agt)-[a-z0-9]{10}
HOME_PATH|[A-Za-z]:\\Users\\
WORK_PATH|[A-Za-z]:\\code_idea
PATTERNS

echo "== 结论 =="
if [ "$FAIL" = 0 ]; then
  echo "PASS  五类形状在 $NBLOBS 个 blob 上全部零命中"
  exit 0
fi
echo "REVIEW  上面列出的命中要先人肉判一遍（形状命中 ≠ 一定是秘密，比如字段名本来就公开）"
exit 1
