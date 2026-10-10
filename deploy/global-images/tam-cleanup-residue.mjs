#!/usr/bin/env node
// 清理"脚本自检/探针"留下的记忆残留。默认只报告，--apply 才动手。
//
// 判据（不看时间，只看归属）：
//   desktop  = session-<uuid>            → 真实桌面会话，永不碰
//   seed     = skill-seed-*              → 种子记录，不是测试残留，永不碰
//   synthetic= 其余（healthcheck-* / test-sess-* / verify-sess-* / gui-sim-* /
//                session-probe-* / session-tamhealth-* / session-v* …）→ 脚本产物
//
// 四层账一起算：L0 按 session_ids 批删；L1 靠容器内 records/<date>.jsonl 的 sessionId
// 反查（API 不返回归属，按日期猜会把真实会话派生的一起删掉）；L2/L3 交给
// tam-l3-reconcile.mjs，本脚本只提示，不擅自删场景。
import { execFileSync } from "node:child_process";
import { gatewayKey } from "./tam-gateway-key.mjs";

const CORE = process.env.TDAI_CORE || "http://127.0.0.1:8420";
const KEY = gatewayKey();
const TEAM = process.env.TDAI_TEAM || "team-LOCALTEAM";
const USER = process.env.TDAI_USER || "usr-LOCALUSER";
const AGENTS = (process.env.TDAI_AGENTS || "agt-LOCALAGENT,agt-LOCALAGENT2,agt-LOCALAGENT3").split(",");
const CONTAINER = process.env.TDAI_CORE_CONTAINER || "tdai-memory-core";
const UK = process.env.TDAI_USER_KEY;
const APPLY = process.argv.includes("--apply");

if (!UK) {
  console.error("缺 TDAI_USER_KEY 环境变量（管理面写操作要 x-tdai-user-key）");
  process.exit(2);
}
const rpc = async (p, agent, b) => {
  const r = await fetch(CORE + p, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: "Bearer " + KEY,
      "x-tdai-service-id": "default",
      "x-tdai-team-id": TEAM,
      "x-tdai-agent-id": agent,
      "x-tdai-user-id": USER,
      "x-tdai-user-key": UK,
    },
    body: JSON.stringify(b ?? {}),
  });
  const j = await r.json();
  if (j.code !== 0) throw new Error(`${p} code=${j.code} ${j.message}`);
  return j.data;
};
const sh = (args, input) => execFileSync("docker", args, { encoding: "utf8", input, maxBuffer: 64 << 20 });

const isDesktop = (s) => /^session-[0-9a-f]{8}-[0-9a-f]{4}-/.test(s);
const isSeed = (s) => s.startsWith("skill-seed-");

// ── L0 清点 ──
const plan = [];
for (const agent of AGENTS) {
  const msgs = [];
  for (let off = 0; ; off += 100) {
    const d = await rpc("/v3/conversation/query", agent, { limit: 100, offset: off });
    msgs.push(...d.messages);
    if (msgs.length >= d.total || off >= 900) break;
  }
  const groups = new Map();
  for (const m of msgs) groups.set(m.session_id, (groups.get(m.session_id) || 0) + 1);
  const syn = [...groups].filter(([s]) => !isDesktop(s) && !isSeed(s));
  const keep = [...groups].filter(([s]) => isDesktop(s) || isSeed(s));
  console.log(`\n[${agent}] L0 共 ${msgs.length} 条 / ${groups.size} 个会话`);
  console.log(`  保留 ${keep.length} 个（桌面 uuid + 种子）: ${keep.map(([s, n]) => `${s.replace(/^session-/, "").slice(0, 12)}×${n}`).join(" ")}`);
  console.log(`  待删 ${syn.length} 个脚本产物: ${syn.map(([s, n]) => `${s}×${n}`).join(" ") || "(无)"}`);
  if (syn.length) plan.push({ agent, pairs: syn, sessions: syn.map(([s]) => s), held: [] });
}

// ── L1 反查归属 ──
// 关键教训：**会话名是脚本产物 ≠ 它的 L1 是噪声**。10-07 那批 verify-sess-*/test-sess-*/
// gui-sim-*/evolve-test-* 是"用脚本会话录进去的真实内容"（sk-mem- 前缀约定、proxy 代理模式、
// 禁直改 memory-core、DDL 前备份、STG 10-15 上线、称呼「老板」/禁 emoji/不可访问内容禁推测）。
// 按名字一刀切会把真记忆删掉。所以本脚本：
//   · 只删"没有任何派生 L1"的纯探针会话（healthcheck-* / session-probe-* 这种内容只有 hi 的）
//   · 有派生 L1 的会话一律保留 L0（它是那批记忆的原始出处，删了就无从对账）
//   · L1 永不自动删，只打清单给人过目
const js = `
const fs=require("fs");
const SYN_SESSIONS=${JSON.stringify(plan.flatMap((p) => p.sessions))};
const set=new Set(SYN_SESSIONS);
const out=[];
for(const f of fs.readdirSync("/data/tdai-memory/records").sort()){
  for(const l of fs.readFileSync("/data/tdai-memory/records/"+f,"utf8").split("\\n").filter(x=>x.trim())){
    const r=JSON.parse(l);
    if(set.has(r.sessionId)) out.push({id:r.id,session:r.sessionId,agent:r.agentId,type:r.type,at:(r.createdAt||"").slice(0,16),content:(r.content||"").slice(0,70)});
  }
}
console.log(JSON.stringify(out));
`;
const l1 = JSON.parse(sh(["exec", "-i", CONTAINER, "node", "-"], js).trim());
const withL1 = new Set(l1.map((a) => a.session));
for (const p of plan) {
  p.held = p.sessions.filter((s) => withL1.has(s));
  p.sessions = p.sessions.filter((s) => !withL1.has(s));
}
const heldTotal = plan.reduce((a, p) => a + p.held.length, 0);
for (const p of plan) {
  const n = new Map(p.pairs);
  p.count = p.sessions.reduce((a, s) => a + (n.get(s) || 0), 0);
}
console.log(`\nL1 反查：脚本会话派生的原子 ${l1.length} 条 —— 全部保留，逐条过目：`);
l1.forEach((a) => console.log(`  [留] ${a.at} ${a.session} ${a.type.padEnd(11)} ${a.content}`));
const l0Total = plan.reduce((a, p) => a + p.count, 0);
console.log(`\n纯探针（无派生 L1，可删）: ${plan.reduce((a, p) => a + p.sessions.length, 0)} 个会话`);
console.log(`有派生 L1 的脚本会话（保留 L0 作出处）: ${heldTotal} 个`);

if (!l0Total) {
  console.log("\nPASS  无纯探针残留可删");
  process.exit(0);
}
if (!APPLY) {
  console.log(`\nDRY-RUN  将删 L0 ${l0Total} 条 / ${plan.reduce((a, p) => a + p.sessions.length, 0)} 个纯探针会话；L1 ${l1.length} 条一律保留。加 --apply 执行`);
  process.exit(0);
}

for (const p of plan) {
  if (!p.sessions.length) continue;
  const d = await rpc("/v3/conversation/delete", p.agent, { session_ids: p.sessions });
  console.log(`L0 删除 [${p.agent}] ${p.sessions.length} 个纯探针会话（计划 ${p.count} 条）→ deleted_count=${d.deleted_count}`);
}
console.log("\nL1 未删（按上面清单人工过目）。若之后删过 L2 场景，再跑: node tam-l3-reconcile.mjs --apply");
