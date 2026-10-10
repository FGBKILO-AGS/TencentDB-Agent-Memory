// 管理面 key 的唯一取值口：env TDAI_GATEWAY_KEY 优先，其次现读被 gitignore 的
// .memory-core-config/tdai-gateway.yaml 里 llm.apiKey。
// 故意**不留内联默认值** —— 把真实 key 抄进可入库的脚本，等于把密钥推进 git 历史。
// 取不到就抛错，让调用方出声，而不是拿着空 Bearer 打出一串 401 再猜原因。
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
export const GATEWAY_YAML = process.env.TDAI_GATEWAY_YAML || join(HERE, ".memory-core-config", "tdai-gateway.yaml");

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

// 直接 `node tam-gateway-key.mjs` 调用时把 key 打到 stdout，供 shell 侧取值。
if (process.argv[1] && process.argv[1].endsWith("tam-gateway-key.mjs")) {
  try {
    process.stdout.write(gatewayKey());
  } catch (e) {
    process.stderr.write(String(e.message) + "\n");
    process.exit(2);
  }
}
