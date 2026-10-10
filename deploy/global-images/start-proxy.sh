#!/usr/bin/env bash
# 单独拉起 proxy（context-proxy，端口 8096）。
#
# proxy 的转发上游走 PROXY_UPSTREAM_URL（与 memory 组的 MEMORY_LLM_* 独立）。
# proxy 会调 memory:8420 做鉴权 / skill / tdai memory 注入；调 memory-hub:8125
# 做 sessionInit control plane。可以单跑 proxy 但相关能力会降级 / 关闭。
#
# 用法：
#   ./start-proxy.sh
#
# 需要以下 proxy 组参数（写在 .env）：
#   PROXY_UPSTREAM_URL / PROXY_UPSTREAM_API_KEY / PROXY_UPSTREAM_MODEL

set -euo pipefail
# MSYS/Git Bash 会把 `-v <host>:<dest>:ro` 里的冒号当路径分隔符，把 /data/config.yaml
# 改写成 D:\...\data\config.yaml，结果容器挂不到配置、静默回退内置默认值。
# 本机实测踩过（容器起来但 /health 里 upstream 是占位域名）。
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_env
require_vars \
  PROXY_IMAGE PROXY_PORT \
  PROXY_UPSTREAM_URL PROXY_UPSTREAM_API_KEY PROXY_UPSTREAM_MODEL

# 与 memory-core 保持一致的 gateway 内部凭据（默认 local，仅本地体验）
MEMORY_CORE_GATEWAY_API_KEY="${MEMORY_CORE_GATEWAY_API_KEY:-local}"

CONTAINER=tdai-proxy
NETWORK=tdai-memory-stack

if ! $DOCKER network inspect "$NETWORK" >/dev/null 2>&1; then
  info "创建 docker 网络 $NETWORK"
  $DOCKER network create "$NETWORK" >/dev/null
fi

# 依赖检查（不阻塞，仅提醒）
if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "tdai-memory-core"; then
  warn "memory-core 容器未运行，proxy 的 auth / tdai memory / skill 注入将全部降级。"
fi
if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "tdai-memory-hub"; then
  warn "memory-hub 容器未运行，proxy 的 sessionInit control plane 不可达。"
fi

pull_image "$PROXY_IMAGE"
rm_container_if_exists "$CONTAINER"

# proxy 只从 YAML 读上游 URL / API key（不认 PROXY_UPSTREAM_URL 环境变量），
# 所以我们从 .env 生成一个最小 config.yaml 挂到容器 /data/config.yaml。
# 容器 CMD 已经是 [--config /data/config.yaml]。
CONFIG_DIR="${PROXY_CONFIG_DIR:-$SCRIPT_DIR/.proxy-config}"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

# ── 三大能力开关（默认最小可用；打开时自动串联依赖）──
# PROXY_ENABLE_AUTH        : 客户端凭 x-tdai-user-key 走内核 auth/verify → user_id
# PROXY_ENABLE_SESSION_INIT: 首轮弹表单选 team/agent/task；依赖 auth+tdai
# PROXY_ENABLE_TDAI        : L2/L3 记忆注入 + L1 召回；依赖 memory-core
#
# 便捷开关 PROXY_FULL_STACK=1 一键把三个都开。
if [[ "${PROXY_FULL_STACK:-0}" == "1" ]]; then
  PROXY_ENABLE_AUTH=1
  PROXY_ENABLE_TDAI=1
  PROXY_ENABLE_SESSION_INIT=1
fi
PROXY_ENABLE_AUTH="${PROXY_ENABLE_AUTH:-0}"
PROXY_ENABLE_TDAI="${PROXY_ENABLE_TDAI:-0}"
PROXY_ENABLE_SESSION_INIT="${PROXY_ENABLE_SESSION_INIT:-0}"

# sessionInit 依赖 auth 拿 user_id；开 sessionInit 时自动补 auth
if [[ "$PROXY_ENABLE_SESSION_INIT" == "1" && "$PROXY_ENABLE_AUTH" != "1" ]]; then
  warn "PROXY_ENABLE_SESSION_INIT=1 需要 auth；自动打开 PROXY_ENABLE_AUTH"
  PROXY_ENABLE_AUTH=1
fi

bool() { [[ "$1" == "1" ]] && echo "true" || echo "false"; }

# ── 本地适配可选面（.env 驱动；未设置时渲染成与旧版本等价的 YAML）──
# PROXY_EXTERNAL_GATEWAY_URL          : 注入块里 curl 配方的基址（不配则容器回退成自己网卡 IP）
# PROXY_SESSION_INIT_SKIP_ASSET_CONFIRM: 跳过 asset_confirm 首轮表单
# PROXY_FORCE_TEAM_ID / PROXY_FORCE_AGENT_ID: sessionInit 强制身份（本地单 agent 绕开表单）
# PROXY_STORAGE_ENABLED               : 开启 sqlite 存储，使会话绑定活过容器重启
# PROXY_DATA_VOLUME                   : proxy 数据卷名（空 = 不开卷，行为与旧版一致）
# PROXY_BIND_HOST                     : 宿主端口绑定地址（默认 0.0.0.0 保持旧行为）
SESSION_INIT_EXTRA=""
if [[ "${PROXY_SESSION_INIT_SKIP_ASSET_CONFIRM:-0}" == "1" ]]; then
  SESSION_INIT_EXTRA+=$'\n  skipAssetConfirm: true'
fi
if [[ -n "${PROXY_FORCE_TEAM_ID:-}" && -n "${PROXY_FORCE_AGENT_ID:-}" ]]; then
  SESSION_INIT_EXTRA+=$'\n  debugForceIdentity:'
  SESSION_INIT_EXTRA+=$'\n'"    team_id: \"$PROXY_FORCE_TEAM_ID\""
  SESSION_INIT_EXTRA+=$'\n'"    agent_id: \"$PROXY_FORCE_AGENT_ID\""
fi
INJECTION_EXTRA=""
if [[ -n "${PROXY_EXTERNAL_GATEWAY_URL:-}" ]]; then
  INJECTION_EXTRA=$'\n  externalGatewayUrl: "'"${PROXY_EXTERNAL_GATEWAY_URL}"'"'
fi
STORAGE_YAML=""
if [[ "${PROXY_STORAGE_ENABLED:-0}" == "1" ]]; then
  STORAGE_YAML=$'\nstorage:\n  enabled: true\n  backend: sqlite'
fi
# PROXY_CREDIT_REPORT_DISABLED=1 → 空 url + 不超时，配合 credit-reporter 里的
# 空串守卫彻底关掉上报（默认值是个占位域名，不关则每请求刷一条 ERROR）。
CREDIT_YAML=""
if [[ "${PROXY_CREDIT_REPORT_DISABLED:-0}" == "1" ]]; then
  CREDIT_YAML=$'\ncreditReport:\n  url: ""\n  timeoutMs: 0'
fi
RUN_VOLUME_ARGS=()
if [[ -n "${PROXY_DATA_VOLUME:-}" ]]; then
  RUN_VOLUME_ARGS+=( -v "${PROXY_DATA_VOLUME}:/data/tdai-memory-proxy" )
fi
# 开发验证用：可把本地改过的 proxy 源码文件挂进镜像（镜像用 tsx 直跑 TS，无需 rebuild）。
# 空格分隔的 "host路径:容器路径" 列表；未设则行为与旧版一致。
SRC_MOUNT_ARGS=()
if [[ -n "${PROXY_SRC_MOUNTS:-}" ]]; then
  for _spec in ${PROXY_SRC_MOUNTS}; do
    SRC_MOUNT_ARGS+=( -v "$_spec" )
  done
  info "源码覆盖挂载: ${PROXY_SRC_MOUNTS}"
fi
info "可选面: gateway_url=${PROXY_EXTERNAL_GATEWAY_URL:-<未设>} skip_asset_confirm=${PROXY_SESSION_INIT_SKIP_ASSET_CONFIRM:-0} force=${PROXY_FORCE_TEAM_ID:-<未设>}/${PROXY_FORCE_AGENT_ID:-<未设>} storage=${PROXY_STORAGE_ENABLED:-0} volume=${PROXY_DATA_VOLUME:-<none>} bind=${PROXY_BIND_HOST:-0.0.0.0}"

info "生成 proxy config → $CONFIG_FILE  (auth=$(bool $PROXY_ENABLE_AUTH) session-init=$(bool $PROXY_ENABLE_SESSION_INIT) tdai=$(bool $PROXY_ENABLE_TDAI))"
cat > "$CONFIG_FILE" <<YAML
# 由 start-proxy.sh 自动生成 —— 每次启动覆盖，请不要手动改。
server:
  host: 0.0.0.0
  port: 8096
  forwardTimeoutMs: 600000

upstream:
  url: "${PROXY_UPSTREAM_URL}"
  apiKey: "${PROXY_UPSTREAM_API_KEY}"

log:
  file: ""
  level: info
  backend: console

# tdai 内核对接（用于 injection / skill / auth 拉取）
tdai:
  enabled: $(bool $PROXY_ENABLE_TDAI)
  endpoint: "http://memory-core:8420"
  apiKey: "${MEMORY_CORE_GATEWAY_API_KEY}"
  serviceId: default
  memory:
    enabled: true
    inject: true
    writeL0: true
    recallL1: true
    injectL2L3: true

skill:
  endpoint: "http://memory-core:8420"
  serviceToken: "${MEMORY_CORE_GATEWAY_API_KEY}"

# knowledge 注入器的注册门槛（shouldRegisterKnowledgeInjector）：
# injectors 含 knowledge + knowledge.enabled + knowledge.serviceToken 三者同时满足。
# 缺了这一段时注入器静默不注册，<knowledge_tools> 永远不会出现。
knowledge:
  enabled: $(bool $PROXY_ENABLE_TDAI)
  endpoint: "http://memory-core:8420"
  serviceToken: "${MEMORY_CORE_GATEWAY_API_KEY}"
  serviceId: default

auth:
  enabled: $(bool $PROXY_ENABLE_AUTH)
  url: "http://memory-core:8420"
  timeoutMs: 5000

sessionInit:
  enabled: $(bool $PROXY_ENABLE_SESSION_INIT)
  maxRetries: 3
  injectAgentContext: true
  injectTaskContext: true${SESSION_INIT_EXTRA}
  headerAutoSelect:
    enabled: true
    teamHeader: "x-team-id"
    agentHeader: "x-agent-id"
    taskHeader: "x-task-id"
    onMismatch: "form"

costGuard:
  enabled: false

# 打开 skill + knowledge + tdai-memory 三个注入器；
# knowledge 依赖 memory-hub 起来，否则 hook 内部会降级为空块。
injection:
  enabled: true
  injectors:
    - skill
    - knowledge
    - tdai-memory${INJECTION_EXTRA}

redis:
  enabled: false${STORAGE_YAML}${CREDIT_YAML}
YAML

info "启动 proxy (image=$PROXY_IMAGE, port=$PROXY_PORT)"
$DOCKER run -d --name "$CONTAINER" \
  --restart "${PROXY_RESTART_POLICY:-unless-stopped}" \
  --network "$NETWORK" \
  --network-alias proxy \
  --add-host=host.docker.internal:host-gateway \
  -p "${PROXY_BIND_HOST:-0.0.0.0}:${PROXY_PORT}:8096" \
  -v "$CONFIG_FILE:/data/config.yaml:ro" \
  "${SRC_MOUNT_ARGS[@]+"${SRC_MOUNT_ARGS[@]}"}" \
  "${RUN_VOLUME_ARGS[@]+"${RUN_VOLUME_ARGS[@]}"}" \
  "$PROXY_IMAGE" >/dev/null

wait_healthy "$CONTAINER" 90
ok "proxy 已启动 → http://localhost:${PROXY_PORT}/"
ok "  用法：把 coding agent 的 API base 指向 http://localhost:${PROXY_PORT}"
