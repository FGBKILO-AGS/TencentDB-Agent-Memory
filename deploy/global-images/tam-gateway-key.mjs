// 管理面 key 与"本机身份三要素"的唯一取值口：env 优先，其次现读被 gitignore 的
// 本地文件（key 走 .memory-core-config/tdai-gateway.yaml，身份走 .env）。
// 故意**不留内联默认值** —— 把真实 key 或 team/agent/user id 抄进可入库的脚本，
// 等于把它们推进 git 历史（2026-10-11 推前审计就是在 3 个 tam-* 里各逮到一组）。
// 取不到就抛错，让调用方出声，而不是拿着空 Bearer 打出一串 401 再猜原因。
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
export const GATEWAY_YAML = process.env.TDAI_GATEWAY_YAML || join(HERE, ".memory-core-config", "tdai-gateway.yaml");
export const ENV_FILE = process.env.TDAI_ENV_FILE || join(HERE, ".env");

export function gatewayKey() {
  const fromEnv = (process.env.TDAI_GATEWAY_KEY || "").trim();
  if (fromEnv) return fromEnv;
  if (!existsSync(GATEWAY_YAML)) {
    throw new Error(`拿不到管理面 key：既没设 TDAI_GATEWAY_KEY，也找不到 ${GATEWAY_YAML}`);
  }
  // 只认 llm: 段内的 apiKey，避免以后别处新增同名键时取错。
  let inLlm = false;
  for (const raw of readFileSync(GATEWAY_YAML, "utf8").split(/\r?\n/)) {
    if (/^llm:\s*$/.test(raw)) { inLlm = true; continue; }
    if (/^[^\s]/.test(raw)) inLlm = false;
    if (inLlm) {
      const m = raw.match(/^\s+apiKey:\s*["']?([^"'\s]+)["']?\s*$/);
      if (m) return m[1];
    }
  }
  throw new Error(`${GATEWAY_YAML} 的 llm: 段里没有 apiKey —— key 只能由 TDAI_GATEWAY_KEY 提供`);
}

// 身份三要素（team / agent / user）+ 可选的 agent 列表。缺任何一项就抛错点名缺哪个，
// 不静默回退到"上一次那台机器"的身份 —— 那会让清理脚本打到别人的记忆空间上。
export function identity() {
  const fileVals = new Map();
  if (existsSync(ENV_FILE)) {
    for (const line of readFileSync(ENV_FILE, "utf8").split(/\r?\n/)) {
      const m = /^\s*(?:export\s+)?(TDAI_[A-Z_]+)\s*=\s*(.*)$/.exec(line);
      if (m) fileVals.set(m[1], m[2].replace(/^["']|["']$/g, "").trim());
    }
  }
  const pick = (k) => (process.env[k] || fileVals.get(k) || "").trim();
  const team = pick("TDAI_TEAM"), agent = pick("TDAI_AGENT"), user = pick("TDAI_USER");
  const agents = (pick("TDAI_AGENTS") || agent).split(",").map((s) => s.trim()).filter(Boolean);
  const missing = [["TDAI_TEAM", team], ["TDAI_AGENT", agent], ["TDAI_USER", user]]
    .filter(([, v]) => !v).map(([k]) => k);
  if (missing.length) {
    throw new Error(`身份不全：${missing.join(" / ")} 未设置 —— 写进 ${ENV_FILE}（已被 gitignore）或导出同名环境变量`);
  }
  return { team, agent, user, agents };
}

// 直接调用时的两种取值：默认打 key；`--identity` 打制表符分隔的四段供 shell 侧读。
if (process.argv[1] && process.argv[1].endsWith("tam-gateway-key.mjs")) {
  try {
    if (process.argv.includes("--identity")) {
      const i = identity();
      process.stdout.write([i.team, i.agent, i.user, i.agents.join(",")].join("\t"));
    } else {
      process.stdout.write(gatewayKey());
    }
  } catch (e) {
    process.stderr.write(String(e.message) + "\n");
    process.exit(2);
  }
}
