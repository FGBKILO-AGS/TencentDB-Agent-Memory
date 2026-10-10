#!/usr/bin/env node
// 按官方 agents/dsh/README.md §1.1/§1.6.3 把桌面配置切到 v0.2+ 姿势。
//
// 为什么要有版本硬闸：0.1.7-rc.2 的 anthropic adapter 拼 `${baseURL}/messages`，
// 0.2.x 拼 `${baseURL}/v1/messages`。在旧版上去掉 /v1 会打到未登记的裸 /messages，
// proxy 回退成 /chat/completions → 上游 404（表现为"配了官方姿势反而坏了"）。
// 同理 reasoningEffort 在旧版会触发 UNSUPPORTED_REASONING_EFFORT 并回退官方直连。
// ⇒ 本脚本先验版本，不达标直接拒。
//
// 用法:
//   node tam-apply-official-config.mjs              # 只报告将要改什么
//   node tam-apply-official-config.mjs --apply      # 改 baseURL/加 reasoningEffort（需 ≥0.2.0）
//   node tam-apply-official-config.mjs --apply --drop-bypass   # 另把 proxy 的 debugForceIdentity 注释掉
import { readFileSync, writeFileSync, copyFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

const HOME = process.env.USERPROFILE || process.env.HOME;
const RUNTIME = `${HOME}/.dsh/dsh-runtimes/dsh-primary-runtime/runtime.json`;
const PATCH = `${HOME}/.dsh/profiles/desktop/cordis.patch.yml`;
const PROXY_CFG = new URL("../../deploy/global-images/.proxy-config/config.yaml", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");

const APPLY = process.argv.includes("--apply");
const DROP_BYPASS = process.argv.includes("--drop-bypass");

const die = (m) => { console.error("!! " + m); process.exit(2); };

// ── 1. 版本硬闸 ──
// ⚠ 判据不能读 ~/.dsh/dsh-runtimes/dsh-primary-runtime/runtime.json：
//   那是首次运行时铺下的 provisioning 记录，壳升级后**不会**刷新它（实测壳已 0.2.0-rc.2，
//   该文件仍写 0.1.7-rc.2，而两者 payloadDigest 相同 ⇒ 它记的是依赖沙箱，不是 dsh 代码）。
// 权威版本看两处：安装目录里壳自带的 runtime.json，以及主 exe 的 FileVersion。
const BUNDLED = "D:/DeepSeek-Harness/download/resources/runtime/primary-runtime/runtime.json";
let ver = null, src0 = null;
for (const [p, key] of [[BUNDLED, "壳自带 runtime.json"], [RUNTIME, "~/.dsh 缓存 runtime.json(仅参考)"]]) {
  if (!existsSync(p)) continue;
  const v = JSON.parse(readFileSync(p, "utf8")).desktopVersion;
  if (!ver && p === BUNDLED) { ver = v; src0 = key; }
  console.log(`  ${key}: ${v}`);
}
if (!ver) die(`读不到壳自带 runtime.json（${BUNDLED}）—— 请改 EXE 路径常量`);
const [maj, min] = String(ver).split(".").map(Number);
const ok = maj > 0 || (maj === 0 && min >= 2);
console.log(`\n权威 desktopVersion = ${ver}（来源：${src0}）→ 官方 §1.5 要求 ≥ 0.2.0-rc.1 : ${ok ? "满足" : "不满足"}`);
if (!ok) {
  console.log("   拒绝改配置。当前 baseURL 带 /v1 是 <0.2 的正确写法，不要手改。");
  process.exit(0);
}

// ── 2. 计划改动 ──
let src = readFileSync(PATCH, "utf8");
const i = src.indexOf("- id: llm-deepseek\n");
if (i < 0) die("cordis.patch.yml 里找不到 llm-deepseek 块");
let j = src.indexOf("\n- id: ", i + 5);
if (j < 0) j = src.length;
let blk = src.slice(i, j);

const hasV1 = /baseURL:\s*(\S*)\/v1\s*$/m.test(blk);
const hasEffort = /^\s*reasoningEffort:/m.test(blk);
console.log(`\nllm-deepseek 块（${blk.split("\n").length} 行）:`);
console.log(`  baseURL 带 /v1        : ${hasV1 ? "是 → 将去掉" : "否（已符合）"}`);
console.log(`  reasoningEffort 已存在: ${hasEffort ? "是（不动）" : "否 → 将加 high"}`);

let next = blk;
if (hasV1) next = next.replace(/(baseURL:\s*\S*?)\/v1(\s*)$/m, (_a, b, c) => b + c);
if (!hasEffort) next = next.replace(/^(\s*)apiKeyEnv:/m, (_a, sp) => `${sp}# 官方 §1.1：v0.2+ 才允许 reasoningEffort（旧版会 UNSUPPORTED_REASONING_EFFORT 回退直连）\n${sp}reasoningEffort: high\n${sp}apiKeyEnv:`);

// 改后自检：必须真的不带 /v1、且块行数变化可解释
if (/baseURL:\s*\S*\/v1\s*$/m.test(next)) die("改后 baseURL 仍带 /v1");
if (!/reasoningEffort: high/.test(next)) die("改后缺 reasoningEffort");
const drift = next.split("\n").length - blk.split("\n").length;
if (Math.abs(drift) > 3) die(`块行数漂移 ${drift} 超出预期（最多 +3 行注释/字段）`);

console.log("\n将写入的差异:");
console.log(blk.split("\n").map((l, n) => `  - ${n + 1}: ${l}`).join("\n"));
console.log(next.split("\n").map((l, n) => `  + ${n + 1}: ${l}`).join("\n"));

if (!APPLY) { console.log("\nDRY-RUN（未写盘）。加 --apply 执行"); process.exit(0); }

const ts = new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14);
copyFileSync(PATCH, `${PATCH}.bak-official-${ts}`);
writeFileSync(PATCH, src.slice(0, i) + next + src.slice(j));
console.log(`\nPASS 已写入 ${PATCH}\n     备份 ${PATCH}.bak-official-${ts}`);

// ── 3. 可选：撤 proxy 的强制身份绑定 ──
if (DROP_BYPASS && existsSync(PROXY_CFG)) {
  let pc = readFileSync(PROXY_CFG, "utf8");
  if (/^\s*debugForceIdentity:/m.test(pc)) {
    copyFileSync(PROXY_CFG, `${PROXY_CFG}.bak-official-${ts}`);
    pc = pc.replace(/^(\s*)(debugForceIdentity:)/m, "$1# $2").replace(/^(\s+)(team_id:.*|agent_id:.*)$/gm, "$1# $2");
    writeFileSync(PROXY_CFG, pc);
    console.log(`PASS 已注释 proxy 的 debugForceIdentity（备份 .bak-official-${ts}）→ 需 docker restart tdai-proxy`);
  } else console.log("proxy 的 debugForceIdentity 本就未启用");
}

console.log("\n复验: bash tam-health.sh   （应 17 PASS；桌面新开会话发 hi，表单应原生弹出）");
console.log("      再实测 mem:help —— 新镜像的 extractLastUserText 是反向取块，与本机 0.1.7 语义相反，必须验");
