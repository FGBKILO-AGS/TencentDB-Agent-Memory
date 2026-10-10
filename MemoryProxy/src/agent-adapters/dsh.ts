/**
 * deepseek-harness (dsh) 客户端适配器。
 *
 * 抓包实证(2026-08-14,mitmproxy 6 条真实包,详见
 * `docs/dsh-recon/2026-08-14-dsh-capture-analysis.md`):
 *
 *   - 协议:**标准 OpenAI Chat Completions**(`POST /chat/completions` + SSE),
 *     跟 codebuddy 同族;body/messages shape 100% 兼容(role:system/user/assistant/tool,
 *     tool_calls[] on assistant,单独 role=tool 消息带 tool_call_id)
 *   - 客户端指纹(强):`user-agent: deepseek-harness/*`(dsh attribution 不可关)
 *     + `x-deepseek-harness-user-id`(匿名 UUID 恒定) + `x-deepseek-harness-session-id`
 *     (session-<uuid>) + `x-deepseek-harness-compact:1`(仅 compaction 请求带)
 *   - session_id **只在 header**,body 不带 fallback 字段(跟 codex 的 client_metadata
 *     不同);proxy 侧 sid 提取 100% 依赖 header
 *   - assistant 回带 `reasoning_content`(dsh 特色,仅 tool_calls 轮回带),
 *     proxy 透传即可,不影响 messages parser
 *
 * # 三类请求的区分(main / title / compaction)
 *
 * dsh 主对话 / compaction / session-title 全部共用同一 `x-deepseek-harness-session-id`,
 * **仅 compaction 有独立 header**(compact:1),title 没有 —— 靠 body 特征区分:
 *
 * | 类别 | header 信号 | body 特征 |
 * |---|---|---|
 * | compaction | `x-deepseek-harness-compact: 1` | — |
 * | title-gen | 无 | tools 缺 + thinking.disabled + max_tokens<=128 + system 以 "Create a concise title..." 开头 |
 * | main | 无 | 其它 |
 *
 * classifyRequest 优先级:**compact header > title body-shape > main**;
 * title 判据必须**三合一都满足**才当 aux(单一特征易误判)。
 *
 * # 两个适配点
 *   - `classifyRequest`: 三重信号判(compact / title / main)
 *   - `extractUserText`: openai wire 的 content 是裸 str;anthropic wire 是
 *     `[{type:"text",text}]` block 数组 —— 两种形态都要认(数组走 default 兜底拼接)
 *
 * # 不同于 CB 的地方
 *   - dsh 主对话在 body.messages 里塞 4 条 role=user:真实用户输入 +
 *     `<system-reminder>` 工作区指令 + `runtime context` 快照 + `<available_skills>` 列表
 *     —— proxy 侧提取最后一条 user 的 str content 时,取"从后往前第一条"就够;
 *     实际用户输入通常在 messages[1](第一条 user)
 *   - dsh 用户输入本身**不带 CB/workbuddy 那种 `<user_query>` wrapper**,直接透传
 */

import type { AgentAdapter, RequestKind } from "./types.js";

// ── Title-gen body-shape detection ───────────────────────────────────────────

/**
 * dsh session-title-llm 请求的 system prompt 固定前缀。
 * 来源:`packages/session/session-title-llm/src/index.ts:252-260` +
 * 抓包 `fixtures/121918-*-9d056d.req.json` 实证。
 *
 * dsh 侧 prompt 完整开头:
 *   "Create a concise title for an AI coding-assistant session from the supplied human messages."
 *
 * 只取前缀做匹配,避免上游 prompt 微调(punctuation / 换行)后判据失效。
 */
const DSH_TITLE_SYSTEM_PROMPT_PREFIX =
  "Create a concise title for an AI coding-assistant session";

/**
 * dsh title-gen 请求的 max_tokens 上限。抓包实证 `max_tokens=64`;
 * 留 128 一点富余,避免上游微调后跟着漂。
 */
const DSH_TITLE_MAX_TOKENS_CEIL = 128;

/**
 * 取 system 文本，兼容两种 wire 形状。
 *
 * - OpenAI Chat Completions：system 是 `messages[0]`（role="system"，content: str）
 *   —— 抓包实证只覆盖了这一种形状。
 * - Anthropic Messages：system 在 **顶层 `body.system`**（string 或 content-block 数组），
 *   `messages` 里恒没有 system 角色。DSH 桌面版的 llm-deepseek provider 只能走这一条
 *   （实测抛 "protocol is not configurable"），所以只查 messages[0] 时 title-gen 永不命中。
 */
function readSystemText(body: Record<string, unknown>): string | null {
  const sys = body.system;
  if (typeof sys === "string" && sys.length > 0) return sys;
  if (Array.isArray(sys)) {
    const parts = sys
      .map((s) => (s as { text?: unknown })?.text)
      .filter((t): t is string => typeof t === "string" && t.length > 0);
    if (parts.length > 0) return parts.join("\n");
  }
  const messages = body.messages;
  if (Array.isArray(messages) && messages.length > 0) {
    const first = messages[0] as { role?: string; content?: unknown } | undefined;
    if (first && first.role === "system" && typeof first.content === "string") return first.content;
  }
  return null;
}

/**
 * 判定 dsh 请求是否为 title-gen(body 特征三合一)。
 *
 * 全部条件必须满足才当 aux。任一条不满足即返 false(避免误判 main)。
 */
function isDshTitleGen(body: Record<string, unknown>): boolean {
  // 条件 1: tools 缺失或空数组(主对话恒 25+ 个)
  const tools = body.tools;
  const hasTools = Array.isArray(tools) && tools.length > 0;
  if (hasTools) return false;

  // 条件 2: thinking.type === "disabled"
  const thinking = body.thinking as { type?: string } | undefined;
  if (thinking?.type !== "disabled") return false;

  // 条件 3: max_tokens <= 128
  const maxTokens = body.max_tokens;
  if (typeof maxTokens !== "number" || maxTokens > DSH_TITLE_MAX_TOKENS_CEIL) return false;

  // 条件 4: system 文本以 title prompt 前缀开头（OpenAI 与 Anthropic 两种形状都支持）
  const sysText = readSystemText(body);
  if (sysText === null || !sysText.startsWith(DSH_TITLE_SYSTEM_PROMPT_PREFIX)) return false;

  return true;
}

// ── User text extraction ─────────────────────────────────────────────────────

/**
 * dsh 的 user content 有两种 wire 形态，两种都要认：
 *   - openai wire(dsh v0.1.x `/chat/completions`)：content 是裸字符串
 *   - anthropic wire(dsh 桌面版 `/v1/messages`)：content 是 `[{type:"text",text}]` block 数组
 *
 * 早期"抓包实证 dsh 从不用 content-blocks 数组"的结论只在 openai wire 上成立；
 * 按那条结论只认 string 会让桌面端的 mem: 命令永远解析不出用户输入
 * （实测差分：同一 payload 仅把 content 换成 block 数组，命令就不被拦截、直接转上游）。
 *
 * 不做 CB 那种 `<user_query>` wrapper 剥离。但注意：dsh 的 `<system-reminder>`
 * 不是独立消息，而是追加在**同一条** user 消息、用户文本之后的 text block
 * （桌面端实测：`mem:help` 后面跟着 `<system-reminder> …`）。
 */
function extractDshUserText(content: unknown): string | null {
  if (typeof content === "string") return content.length > 0 ? content : null;
  if (!Array.isArray(content)) return null;
  // 只取第一个非空 text block。不能用 defaultAdapter 的"拼接所有 text block"：
  // 拼出来的 `mem:help <system-reminder> …` 带尾巴，命令解析器的严格匹配会
  // 判成未知命令（桌面端实测踩过）。
  for (const b of content) {
    if (!b || typeof b !== "object") continue;
    const block = b as Record<string, unknown>;
    if (block.type === "text" && typeof block.text === "string" && block.text.length > 0) {
      return block.text;
    }
  }
  return null;
}

// ── Adapter export ───────────────────────────────────────────────────────────

export const dshAdapter: AgentAdapter = {
  agentKind: "dsh",

  classifyRequest(
    body: Record<string, unknown>,
    _path?: string,
    headers?: Record<string, string>,
  ): RequestKind {
    // 信号 1(最强): compact header —— dsh source 硬编码在
    // `packages/llm/llm-deepseek/src/adapter.ts:290-293`,只在
    // `purpose:'compaction'` 时才塞,无歧义
    if (headers?.["x-deepseek-harness-compact"] === "1") return "auxiliary";

    // 信号 2: title-gen body 特征三合一(见 isDshTitleGen)
    if (isDshTitleGen(body)) return "auxiliary";

    // 其它一律 main
    return "main";
  },

  extractUserText(content: unknown): string | null {
    return extractDshUserText(content);
  },
};
