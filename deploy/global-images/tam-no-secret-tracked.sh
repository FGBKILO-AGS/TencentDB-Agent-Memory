#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 只检查一件事：被 git 跟踪的文件里不许出现明文密钥。
#
# 起因（2026-10-10）：三个自检脚本写着 `env || "sk-…真实值"` 的内联默认值，把生产
# key 抄进了**会被跟踪**的文件；同一轮"清理副本明文密钥"却漏掉了它们。配置本体在
# .gitignore 覆盖的 .proxy-config/ / .memory-core-config/ 里，本来不需要内联默认值。
#
# 只看跟踪文件：工作区里没 add 的草稿不算（那是本机临时物，不进仓库就不泄露）。
# 输出全部脱敏 —— 闸自己把命中值打进日志，等于往另一份日志里再漏一次。
#
# 用法: bash tam-no-secret-tracked.sh          # exit 0=干净  1=有命中  2=跑不动
#       bash tam-no-secret-tracked.sh --selftest   # 红绿自证（见文件末尾）
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 密钥形状：sk- 后接 ≥12 位 base62。占位符（sk-xxxx、sk-your-key、REPLACE_ME）凑不满 12。
# 为什么是 12 不是原来的 24：2026-10-11 实测漏过一把真 key —— 全长 22（`sk-` + 19），
# 当时 {24,} 对它零命中，闸恒绿。宽度只在"已被证明存在的那把 key"上下调，不猜更短。
SECRET_RE='sk-[A-Za-z0-9]{12,}'

scan() {
  local hits
  hits="$(cd "$REPO_DIR" && git grep -nIE "$SECRET_RE" 2>/dev/null)"
  local rc=$?
  if [ -z "$hits" ]; then
    if [ "$rc" -ge 2 ]; then
      echo "  [FAIL] git grep 本身失败 (rc=$rc) —— 空命中不等于干净"
      return 2
    fi
    echo "  [PASS] 被跟踪文件里没有明文密钥（形状 $SECRET_RE 零命中）"
    return 0
  fi
  printf '%s\n' "$hits" | while IFS= read -r line; do
    printf '  [FAIL] %s\n' "$(printf '%s' "$line" | sed -E "s/$SECRET_RE/sk-****(redacted)/")"
  done
  return 1
}

if [ "${1:-}" = "--selftest" ]; then
  # 红绿自证：闸必须能在真密钥上响，否则它只是一条恒绿的装饰。
  # 两株样本各代表一个宽度档 —— 长档 {24,} 就能抓到，短档只有收窄到 {12,} 才抓得到，
  # 而短档正是 2026-10-11 真实漏掉的那把 key 的形状（全长 22）。少一株都算自证不完整。
  FIX_LONG="deploy/global-images/__secret_fixture_long_$$.mjs"
  FIX_SHORT="deploy/global-images/__secret_fixture_short_$$.mjs"
  echo "== 绿：当前仓库 =="
  scan; GREEN=$?
  echo "== 红：塞两株含密钥的跟踪态样本（git add -N）=="
  # 构造真实形状的假值（不是任何在用 key）
  printf 'export const K = "sk-%s";\n' "0123456789abcdefABCDEF0011" > "$REPO_DIR/$FIX_LONG"   # 26 位
  printf 'export const K = "sk-%s";\n' "0123456789abcdefghij" > "$REPO_DIR/$FIX_SHORT"        # 20 位
  (cd "$REPO_DIR" && git add -N -- "$FIX_LONG" "$FIX_SHORT")
  scan; RED=$?
  # 两株都得各自命中，否则"红"可能只由长档撑起，短档仍是盲区
  HITS_LONG="$(cd "$REPO_DIR" && git grep -cIE "$SECRET_RE" -- "$FIX_LONG" 2>/dev/null | awk -F: '{print $NF}')"
  HITS_SHORT="$(cd "$REPO_DIR" && git grep -cIE "$SECRET_RE" -- "$FIX_SHORT" 2>/dev/null | awk -F: '{print $NF}')"
  (cd "$REPO_DIR" && git reset -q -- "$FIX_LONG" "$FIX_SHORT") 2>/dev/null
  rm -f "$REPO_DIR/$FIX_LONG" "$REPO_DIR/$FIX_SHORT"
  echo "== 复绿：样本撤掉后 =="
  scan; GREEN2=$?
  echo "  分株命中 long=${HITS_LONG:-0} short=${HITS_SHORT:-0}（两者都必须 >=1）"
  if [ "$GREEN" = 0 ] && [ "$RED" = 1 ] && [ "$GREEN2" = 0 ] \
     && [ "${HITS_LONG:-0}" -ge 1 ] && [ "${HITS_SHORT:-0}" -ge 1 ]; then
    echo "SELFTEST PASS  绿→红→绿 三态都对且两档各自命中，闸可响可收"
    exit 0
  fi
  echo "SELFTEST FAIL  green=$GREEN red=$RED green2=$GREEN2 long=${HITS_LONG:-0} short=${HITS_SHORT:-0} —— 这条闸不可信，别当它存在"
  exit 1
fi

scan
exit $?
