#!/usr/bin/env node
// L3 对账：把 persona.md 的 Scene Navigation 与「实际存在的 L2 场景」对齐，删掉悬空块。
//
// 为什么需要它：上游 `POST /v3/scenario/rm` 只刷 .metadata/scene_index.json，
// 不刷 persona.md 里那段导航；而 /v3/core/read 是把 persona.md 原样吐出来的
// （实测逐字符相等），所以删过 L2 之后，悬空条目会继续被注入到真实会话里。
// persona.md 的重写只由 PersonaTrigger 阈值（triggerEveryN）驱动，没有 HTTP 入口。
//
// 用法:  node tam-l3-reconcile.mjs            # 只报告
//        node tam-l3-reconcile.mjs --apply    # 落盘修复并复验
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, rmSync } from "node:fs";

const CORE = process.env.TDAI_CORE || "http://127.0.0.1:8420";
const KEY = process.env.TDAI_GATEWAY_KEY || "REPLACE_ME";
const TEAM = process.env.TDAI_TEAM || "team-LOCALTEAM";
const AGENT = process.env.TDAI_AGENT || "agt-LOCALAGENT";
const USER = process.env.TDAI_USER || "usr-LOCALUSER";
const CONTAINER = process.env.TDAI_CORE_CONTAINER || "tdai-memory-core";
const PROFILE = `/data/tdai-memory/profiles/team%3A${TEAM}%7Cagent%3A${AGENT}`;
const APPLY = process.argv.includes("--apply");

const H = {
  "content-type": "application/json",
  authorization: "Bearer " + KEY,
  "x-tdai-service-id": "default",
  "x-tdai-team-id": TEAM,
  "x-tdai-agent-id": AGENT,
  "x-tdai-user-id": USER,
};
const rpc = async (p, b) => {
  const r = await fetch(CORE + p, { method: "POST", headers: H, body: JSON.stringify(b ?? {}) });
  const j = await r.json();
  if (j.code !== 0) throw new Error(`${p} 返回 code=${j.code} ${j.message}`);
  return j.data;
};
const sh = (args) => execFileSync("docker", args, { encoding: "utf8", maxBuffer: 64 << 20 });

const actual = new Set((await rpc("/v3/scenario/ls", {})).entries.map((e) => e.path));
const tmp = `tam-l3-${process.pid}.persona.md`;
sh(["cp", `${CONTAINER}:${PROFILE}/persona.md`, tmp]);
const src = readFileSync(tmp, "utf8");

const MARK = "\n### Path: ";
const cut = src.indexOf(MARK);
const head = cut < 0 ? "" : src.slice(0, cut + 1);
const blocks = (cut < 0 ? src : src.slice(head.length)).split(/(?=^### Path: )/m).filter((b) => b.trim());
const pathOf = (b) => (b.match(/^### Path: (.+)$/m) || [, ""])[1].trim().replace(/^scene_blocks\//, "");

const kept = [], dangling = [];
for (const b of blocks) (actual.has(pathOf(b)) ? kept : dangling).push(b);

console.log(`实际 L2=${actual.size} | persona.md 索引块=${blocks.length} | 悬空=${dangling.length}`);
dangling.forEach((b) => console.log(`  悬空: ${pathOf(b)}`));

if (dangling.length === 0) {
  rmSync(tmp);
  console.log("PASS  L3 与 L2 一致，无需修复");
  process.exit(0);
}
if (!APPLY) {
  rmSync(tmp);
  console.log("FAIL  存在悬空索引（会被注入真实会话）—— 加 --apply 修复");
  process.exit(1);
}

const out = head + kept.join("");
writeFileSync(tmp, out);
sh(["cp", tmp, `${CONTAINER}:${PROFILE}/persona.md`]);

const back = (await rpc("/v3/core/read", {})).content || "";
const nowBlocks = [...back.matchAll(/^### Path: (.+)$/gm)].map((m) => m[1].trim().replace(/^scene_blocks\//, ""));
const stillDangling = nowBlocks.filter((p) => !actual.has(p));
const missing = [...actual].filter((p) => !nowBlocks.includes(p));
rmSync(tmp);

if (stillDangling.length === 0 && missing.length === 0 && nowBlocks.length === actual.size) {
  console.log(`PASS  已修复并复验：索引块 ${nowBlocks.length} == 实际 L2 ${actual.size}，双向差集为空`);
  process.exit(0);
}
console.log(`FAIL  修复后仍不闭合：悬空=${JSON.stringify(stillDangling)} 缺失=${JSON.stringify(missing)}`);
process.exit(1);
