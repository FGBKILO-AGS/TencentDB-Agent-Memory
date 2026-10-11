#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# TencentDB Agent Memory × DeepSeek Harness  全链路自检
#
# 用法:  bash tam-health.sh
#
# 检查项:
#   1) 三件套容器是否 healthy
#   2) 端口是否通 (proxy 8096 / core 8420 / hub 8125,8424)
#   3) DSH 桌面版进程是否在跑
#   4) DSH 生效配置是否为 tdai、且没有致命的 reasoningEffort
#   5) 记忆注入是否真的发生 (带 x-deepseek-harness-session-id 打一针探针)
#   6) L0 回写 / pipeline 是否在工作，并自清理本次探针的 L0
#   7) 真实桌面会话（只认 session-<uuid>）是否被注入
#   8) L3 persona 索引与 L2 实际场景是否对得上（有无悬空）
#   9) aux 端点是否真的可达（agent 前缀表漏人时只有这里会响）
#  10) 被跟踪文件里有没有明文密钥
#
# 配套: tam-cleanup-residue.mjs  清自检/探针残留（四层）
#       tam-l3-reconcile.mjs      只修 L3 悬空索引
#
# 退出码: 0=全绿  1=有 FAIL
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIN_HOME="$(cd "$HOME" && pwd -W 2>/dev/null || echo "$HOME")"
CREDS="$HOME/.dsh/.credentials.yaml"
PATCH="$HOME/.dsh/profiles/desktop/cordis.patch.yml"

# 记忆内核管理面坐标（与 tam-l3-reconcile.mjs / tam-cleanup-residue.mjs 同一套）
# key 不许内联明文：它只活在 gitignored 的 .memory-core-config/tdai-gateway.yaml。
# 取值口统一在 tam-gateway-key.mjs（env 优先，其次现读那份配置，取不到就报错）；
# 静默回退到内联默认值等于把生产 key 抄进可入库的文件 —— 这条已经踩过一次。
CORE_KEY="${TDAI_GATEWAY_KEY:-$(node "$REPO_DIR/tam-gateway-key.mjs" 2>/dev/null)}"
if [ -z "$CORE_KEY" ]; then
  echo "!! 拿不到管理面 key：export TDAI_GATEWAY_KEY=…，或确认 node 在 PATH 且 $REPO_DIR/.memory-core-config/tdai-gateway.yaml 存在"
  exit 1
fi
# 身份三要素同样不许内联默认值：写死一组 team/agent/user 会让工具在"上一次那台机器"
# 的记忆空间上跑，而且把 id 抄进可入库文件就等于把它推进公开历史
# （2026-10-11 推前审计在 3 个 tam-* 里各逮到一组）。取值口与 key 同一个模块。
IDENT="$(node "$REPO_DIR/tam-gateway-key.mjs" --identity 2>/dev/null)"
if [ -z "$IDENT" ]; then
  echo "!! 拿不到身份三要素：export TDAI_TEAM/TDAI_AGENT/TDAI_USER，或写进 $REPO_DIR/.env（已被 gitignore）"
  exit 1
fi
IFS=$'\t' read -r TDAI_TEAM TDAI_AGENT TDAI_USER TDAI_AGENTS <<<"$IDENT"

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
head2() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

head2 "1. 记忆服务三件套"
need_tdai=(tdai-proxy tdai-memory-core tdai-memory-hub)
for c in "${need_tdai[@]}"; do
  st="$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)"
  rp="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)"
  if [ "$st" = "healthy" ]; then
    if [ "$rp" = "unless-stopped" ]; then ok "$c healthy (重启策略 $rp)"
    else warn "$c healthy 但重启策略=$rp，电脑重启后不会自拉起" ; fi
  elif [ -z "$st" ]; then bad "$c 不存在"
  else bad "$c 状态=$st" ; fi
done

head2 "2. 端口连通性"
check_port() {
  local name="$1" port="$2" url="$3"
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null)"
  case "$code" in
    200|401|404|405) ok "$name :$port 已在监听 (HTTP $code)" ;;
    *) bad "$name :$port 无响应 (code=$code)"; return 1 ;;
  esac
}
check_port "proxy       " 8096 "http://127.0.0.1:8096/dsh/default/chat/completions" || true
check_port "memory-core " 8420 "http://127.0.0.1:8420/" || true
check_port "memory-hub  " 8125 "http://127.0.0.1:8125/" || true

head2 "3. DeepSeek Harness 桌面版"
n="$(tasklist 2>/dev/null | grep -ci 'DeepSeek Harness')"
if [ "$n" -gt 0 ]; then ok "桌面版运行中 (进程数 $n)"; else warn "桌面版未运行" ; fi

head2 "4. DSH 生效配置 (真正读的是 profiles/desktop/cordis.patch.yml)"
if [ ! -f "$PATCH" ]; then
  bad "找不到 $PATCH"
else
  # ★ 关键：默认 provider 必须是 deepseek-official（内置 llm-deepseek 模块的原生 provider）。
  #   只有原生链路才会携带 x-deepseek-harness-session-id，Proxy 据此建立 conversationId 才会注入记忆。
  #   若走 llm-pi-ai 下的自定义 provider，用的是通用 SDK（x-stainless-* 指纹），
  #   不带 session-id → conversationId=null → injectedSkipped=true → 记忆被整体跳过。
  PROV="$(sed -n '/^- id: agent-default-model$/,/^- id: /p' "$PATCH" | sed -n 's/^[[:space:]]*provider:[[:space:]]*//p' | tr -d '\r' | head -1)"
  if [ "$PROV" = "deepseek-official" ]; then ok "默认 provider = deepseek-official（原生链路，会带 session-id）"
  else bad "默认 provider = [$PROV]，应为 deepseek-official（否则不带 dsh 指纹头，记忆被跳过）" ; fi

  # llm-deepseek 原生段的 baseURL 必须被劫持到本地 Proxy
  if grep -q 'http://127.0.0.1:8096/dsh/default' "$PATCH"; then ok "llm-deepseek baseURL 已指向本地 Proxy 8096"; else bad "baseURL 未指向 8096" ; fi

  # reasoningEffort 的雷不在"有没有"，在"取值是否被适配器认识"。
  # 从 app.asar 内 llm-deepseek 适配器自带文档抽出支持的档位是 off|low|high|max
  # （官方模板写的就是 high）；不在集合内的取值会在**发出网络请求之前**抛
  # UNSUPPORTED_REASONING_EFFORT，配置静默回退官方直连 → 记忆不注入（历史"AI 失忆"根因）。
  EFF="$(grep -E '^[[:space:]]+reasoningEffort:' "$PATCH" | sed -n 's/.*reasoningEffort:[[:space:]]*//p' | tr -d '\r"'"'"'' | head -1)"
  if [ -z "$EFF" ]; then
    warn "未设 reasoningEffort（能跑，但不吃官方模板的 reasoning 档位）"
  elif printf '%s' "$EFF" | grep -qE '^(off|low|high|max)$'; then
    ok "reasoningEffort=$EFF（适配器支持档位）"
  else
    bad "reasoningEffort=$EFF 不在支持集合 off|low|high|max —— 请求发出前即 UNSUPPORTED_REASONING_EFFORT，静默回退官方直连"
  fi
fi

head2 "5. 记忆注入实测"
UK=""
if [ -f "$CREDS" ]; then
  UK="$(sed -n 's/^[[:space:]]*PROXY_USER_KEY:[[:space:]]*//p' "$CREDS" | tr -d '\r"' | head -1)"
fi
if [ -z "$UK" ]; then
  bad "无法从 $CREDS 读取 PROXY_USER_KEY"
else
  ok "已取得 user_key (长度 ${#UK})"
  SID="session-tamhealth-$(date +%s)"
  # 探针名必须以 session-tamhealth- 打头：check 7 靠"是不是 session-<uuid>"把它和
  # 真实桌面流量分开，清理脚本也靠这个前缀认出它是自检产物。
  # ★ upstream 与客户端路径必须**同协议对齐**，否则 404。实测对照：
  #   upstream=/anthropic + 客户端 /v1/messages        -> /anthropic/messages       200
  #   upstream=/anthropic + 客户端 /v1/chat/completions -> /anthropic/chat/completions 404
  #   upstream=/v1        + 客户端 /v1/chat/completions -> /v1/chat/completions      200
  #   upstream=/v1        + 客户端 /v1/messages        -> /v1/messages              404
  # 本机 DSH 原生通道走 Anthropic 协议，故 upstream=/anthropic，
  # 探针也必须发 /v1/messages（Anthropic 协议），不能用 /v1/chat/completions。
  RESP="$(curl -s -m 90 -X POST "http://127.0.0.1:8096/dsh/default/v1/messages" \
    -H "Authorization: Bearer $UK" -H "x-tdai-service-id: default" \
    -H "x-deepseek-harness-session-id: $SID" \
    -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -d '{"model":"deepseek-flash","max_tokens":64,"messages":[{"role":"user","content":"只回复两个字：收到"}],"tools":[{"name":"ask_user_question","description":"ask","input_schema":{"type":"object","properties":{}}}]}' 2>&1)"

  # Anthropic 协议的用量字段是 input_tokens；OpenAI 协议是 prompt_tokens。两者都兼容。
  PT="$(printf '%s' "$RESP" | python -c 'import sys,json
try:
    d=json.load(sys.stdin); u=d.get("usage",{}) or {}
    print(u.get("input_tokens") or u.get("prompt_tokens") or 0)
except Exception: print(-1)' 2>/dev/null)"
  if [ "$PT" = "-1" ]; then
    bad "探针请求失败（非 JSON 响应）"; printf '     响应片段: %.200s\n' "$RESP"
  elif [ "$PT" -gt 3000 ] 2>/dev/null; then
    ok "注入生效：prompt_tokens=$PT（>3000 说明记忆块进去了）"
  elif [ "$PT" -gt 0 ] 2>/dev/null; then
    bad "注入疑似失效：prompt_tokens=$PT（裸透传约 275）"
  else
    bad "未取得 usage: $RESP"
  fi

  head2 "6. 写入闭环"
  sleep 3
  if docker exec tdai-memory-core sh -c "grep -q '$SID' /data/tdai-memory/conversations/\$(date -u +%F).jsonl" 2>/dev/null; then
    ok "L0 已落盘 conversations/$(date -u +%F).jsonl"
  else
    warn "暂未在 conversations 中找到 $SID（可能异步延迟，稍后复查）"
  fi
  # 注意两处 Windows(Git Bash) 坑：
  #   1) MSYS 会把 /data/... 当成 MSYS 根路径做转换 -> 必须 MSYS_NO_PATHCONV=1
  #   2) docker exec 输出带 \r -> 需要 tr 清洗后才能当数字用
  WAL="$(MSYS_NO_PATHCONV=1 docker exec tdai-memory-core stat -c '%Y' /data/tdai-memory/vectors.db-wal 2>/dev/null | tr -d '\r\n ')"
  NOW="$(date -u +%s)"
  if [ -n "$WAL" ] && [ "$WAL" -gt 0 ] 2>/dev/null; then
    AGE=$(( NOW - WAL ))
    if [ "$AGE" -lt 600 ]; then
      ok "抽取 pipeline 活跃 (vectors.db-wal $AGE 秒前有写入)"
    else
      warn "vectors.db-wal 已 $AGE 秒未更新 —— 记忆可能没在沉淀"
    fi
  else
    warn "读不到 vectors.db-wal (raw=[$WAL])"
  fi

  # ── 自检产物自清理 ──
  # 探针会往 L0 落两条（user+assistant）。不删的话，每跑一次自检就多一条永久残留
  # （10-07 那批 healthcheck-* 就是这么攒下 7 个会话的）。
  # 注意：删 L0 不会阻止异步抽取，若探针正好凑满抽取窗口仍可能长出 L1/L2 ——
  # 那由第 8 项的 L3 对账闸兜住，清理走 tam-cleanup-residue.mjs。
  DEL="$(curl -s -m 15 -X POST "http://127.0.0.1:8420/v3/conversation/delete" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $CORE_KEY" \
    -H 'x-tdai-service-id: default' -H "x-tdai-team-id: $TDAI_TEAM" \
    -H "x-tdai-agent-id: $TDAI_AGENT" -H "x-tdai-user-id: $TDAI_USER" \
    -H "x-tdai-user-key: $UK" -d "{\"session_ids\":[\"$SID\"]}" 2>/dev/null)"
  case "$DEL" in
    *'"deleted_count"'*) ok "探针 L0 已自清理 ($SID)" ;;
    *) warn "探针 L0 自清理未确认: ${DEL:-无响应}" ;;
  esac
fi

# 本节的 WARN 是"未判"而不是"坏了"，但只说"窗口内没有"会误导：分不清"没人用客户端"
# 和"客户端链路断了"。这里回到 24h 找最后一条真实桌面记录并算出年龄，
# 让操作者自己判断要不要补一发（年龄大于容器重建时间 ⇒ 重建后确实没验过）。
last_desktop_age() {
  local ts then now
  ts="$(docker logs --timestamps --since 24h tdai-proxy 2>&1 | tr -d '\r' \
        | grep 'injection-debug' | grep -E 'conversationId=session-[0-9a-f]{8}-' \
        | tail -1 | awk '{print $1}')"
  if [ -z "$ts" ]; then echo "24h 内无任何桌面记录"; return; fi
  then="$(printf '%s' "$ts" | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1Z/' | xargs -I{} date -d {} +%s 2>/dev/null)"
  if [ -z "$then" ]; then echo "最后一条桌面记录时间戳解析失败（原始值 $ts）"; return; fi
  now="$(date +%s)"
  echo "最后一条桌面记录在 $(( (now - then) / 3600 ))h$(( ((now - then) % 3600) / 60 ))m 前（$ts）"
}

head2 "7. 真实 DSH 客户端发的对话是否走了记忆（最近 30 分钟）"
# 从 Proxy 日志反查真实 GUI 请求：关键看 conversationId 是否为 null。
#   conversationId=<sid> 且配 non-null → 注入已生效
#   conversationId=null  且指纹是 x-stainless-* → 客户端没带 session-id，记忆被整体跳过
# 注意：日志里 injection-debug 有两类行（主记录 / initResult），只保留带 injectedSkipped 的主记录。
# 桌面真实会话的判据是 conversationId=session-<uuid>；自检探针用 session-tamhealth-* 前缀，
# 不会被当成客户端证据（三档：有桌面流量→判注入 / 只有 null→FAIL / 只有探针→WARN 未判）。
RECENT="$(docker logs --since 30m tdai-proxy 2>&1 | tr -d '\r' \
          | grep 'injection-debug' | grep 'injectedSkipped=' | tail -20)"
if [ -z "$RECENT" ]; then
  warn "最近 30 分钟 Proxy 未收到任何真实请求 —— 请在 DSH 里发一句话后重跑本脚本（$(last_desktop_age)）"
else
  # 只认桌面真实会话（conversationId=session-<uuid>）。自检/脚本探针的
  # session-tamhealth-* 不算客户端证据，否则本脚本会给自己发绿。
  GOOD="$(printf '%s\n' "$RECENT" | grep -E 'conversationId=session-[0-9a-f]{8}-' | tail -1)"
  TOTAL="$(printf '%s\n' "$RECENT" | wc -l | tr -d ' ')"
  NULLS="$(printf '%s\n' "$RECENT" | grep -c 'conversationId=null')"
  if [ -n "$GOOD" ]; then
    DESKTOP_SID="$(printf '%s' "$GOOD" | sed -n 's/.*conversationId=\([^ ]*\).*/\1/p')"
    SKIPPED="$(printf '%s' "$GOOD" | sed -n 's/.*injectedSkipped=\([^ ]*\).*/\1/p')"
    if [ "$SKIPPED" = "false" ]; then
      ok "真实对话已注入记忆：conversationId=$DESKTOP_SID injectedSkipped=false"
    else
      bad "真实对话带 session-id 但注入被跳过 (injectedSkipped=$SKIPPED)"
    fi
  elif [ "$NULLS" -gt 0 ]; then
    bad "$TOTAL 条请求里 $NULLS 条 conversationId=null 且无一条桌面会话 —— DSH 没带 session-id，记忆未注入"
    printf '     诊断: 默认 provider 必须是 deepseek-official（原生链路）；'
    printf 'llm-pi-ai 下的自定义 provider 走通用 SDK，不带 dsh 指纹头\n'
  else
    # 窗口里只有脚本/自检探针（本脚本自己的 session-tamhealth-* 也算）——
    # 这既不是"注入坏了"也不能拿来当客户端证据，只能算未判。
    warn "最近 30 分钟无桌面真实会话流量可判（$TOTAL 条全是脚本/自检探针）—— 在 DSH 里发一句话后重跑（$(last_desktop_age)）"
  fi
fi

head2 "8. L3 与 L2 对账（删过场景后 persona.md 会不会留悬空）"
# 上游 scenario/rm 只刷 scene_index.json，不刷 persona.md 的 Scene Navigation，
# 而 core/read 原样吐 persona.md ⇒ 悬空条目会被注入真实会话。这里做双向集合差。
L3OUT="$(node "$REPO_DIR/tam-l3-reconcile.mjs" 2>&1)"
case "$L3OUT" in
  *"PASS  L3 与 L2 一致"*) ok "L3 索引与实际 L2 场景一致" ;;
  *"悬空="*) warn "L3 有悬空索引，未自动改（会动 L3 落盘物）。修复: node tam-l3-reconcile.mjs --apply"
             printf '%s\n' "$L3OUT" | sed 's/^/       /' ;;
  *) bad "L3 对账跑不起来: $(printf '%s' "$L3OUT" | head -c 160)" ;;
esac

head2 "9. aux 端点路由可达性（防 agent 前缀表再次漏人）"
# 只为堵一类回归：whitelist.ts 的 AGENT_PREFIX_RE 少列某个 agent 段时，
# /<agent>/<space>/v1/* 归一化剥不掉前缀，handleAuxiliaryEndpoint 一律本地 404，
# 而 server.ts 里那些 aux 路由照样"注册成功"—— 启动无报错、主对话也正常，
# 只有真去打 count_tokens 才暴露（dsh 三条已注册 aux 端点就这么静默死了）。
# 正控制必须 200、负控制必须 404：只数正控制的话，把正则放宽成剥一切前缀也会全绿。
CT_DIR="$(mktemp -d 2>/dev/null || echo .)"
printf '%s' '{"model":"deepseek-flash","messages":[{"role":"user","content":"tam health aux probe"}]}' > "$CT_DIR/ct.json"
_aux_code() {
  curl -s -o "$CT_DIR/ct.out" -w '%{http_code}' -m 30 -X POST "http://127.0.0.1:8096/$1/default/v1/messages/count_tokens" \
    -H "Authorization: Bearer $UK" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
    --data-binary "@$CT_DIR/ct.json" 2>/dev/null
}
for AG in claude-code codebuddy dsh; do
  C="$(_aux_code "$AG")"
  if [ "$C" = "200" ] && grep -q 'input_tokens' "$CT_DIR/ct.out"; then
    ok "$AG 的 aux 端点可达 (count_tokens HTTP 200)"
  else
    bad "$AG 的 aux 端点 HTTP=$C body=$(head -c 90 "$CT_DIR/ct.out") —— 多半是 AGENT_PREFIX_RE 少了 $AG"
  fi
done
C_NEG="$(_aux_code workbuddy)"
if [ "$C_NEG" = "404" ]; then
  ok "workbuddy 维持 404（它没注册该端点，前缀表不该为它放宽）"
else
  bad "workbuddy count_tokens HTTP=$C_NEG，期望 404 —— 前缀表放宽过头，剥了不该剥的段"
fi
if [ "$CT_DIR" = "." ]; then rm -f ct.json ct.out; else rm -rf "$CT_DIR"; fi

head2 "10. 被跟踪文件里没有明文密钥"
# 与第 9 节同因：这类问题不会让任何接口报错，只在"下次有人把仓库推出去"时爆。
# 闸本体自带红绿自证（tam-no-secret-tracked.sh --selftest），这里只做日常复跑。
SECOUT="$(bash "$REPO_DIR/tam-no-secret-tracked.sh" 2>&1)"
SECRETCODE=$?
case "$SECRETCODE" in
  0) ok "$(printf '%s\n' "$SECOUT" | grep -o '没有明文密钥.*' | head -1)" ;;
  1) bad "$(printf '%s\n' "$SECOUT" | grep '\[FAIL\]' | head -3 | tr '\n' ' ')" ;;
  *) bad "密钥扫描没跑起来（rc=$SECRETCODE）：$(printf '%s' "$SECOUT" | head -c 140)" ;;
esac

head2 "11. 面板补丁在场性（hub 容器一重建就会丢的那几个文件）"
# 面板那 3 个补丁落在 hub 容器**可写层**（不在挂载列表里），所以现有检查一概看不见它们。
# 判据是"容器里那份 != 镜像里那份"，不是"文件里有没有某个词"——后者会恒绿。
PPOUT="$(bash "$REPO_DIR/tam-panel-patch-present.sh" 2>&1)"; PP=$?
case "$PP" in
  0) ok "$(printf '%s\n' "$PPOUT" | grep -c '\[PASS\]') 项面板补丁断言全过（含参照物链路校验）" ;;
  1) bad "$(printf '%s\n' "$PPOUT" | grep '\[FAIL\]' | head -2 | tr '\n' ' ')" ;;
  *) bad "面板补丁检查跑不起来（rc=$PP）：$(printf '%s' "$PPOUT" | head -c 120)" ;;
esac

printf '\n\033[1m===== 汇总: %d PASS / %d WARN / %d FAIL =====\033[0m\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n排障速查:\n'
  printf '  · 容器没起来   -> cd %s && ./start-all.sh\n' "$REPO_DIR"
  printf '  · 注入失效     -> docker logs --tail 50 tdai-proxy | grep injection-debug\n'
  printf '  · upstream 错  -> 必须为 https://api.deepseek.com/anthropic（.env 与 .proxy-config/config.yaml 两处同步）\n'
  printf '                   实测: /anthropic 只接 /messages；/v1 只接 /chat/completions；两者不通用\n'
  printf '  · DSH 报 404   -> 分两种：主 /v1/messages 通而 aux 不通 => whitelist.ts 的 AGENT_PREFIX_RE\n'
  printf '                   少了 dsh（第 9 节专抓这条）；主路径就 404 => 客户端 baseURL 写法。\n'
  printf '                   官方 llm-deepseek 适配器自己追加 /v1/messages，baseURL 末尾**不带** /v1；\n'
  printf '                   带了也通（末尾严格等于 /v1 的路径段会直接复用，不会拼成 /v1/v1）。\n'
  exit 1
fi
exit 0
