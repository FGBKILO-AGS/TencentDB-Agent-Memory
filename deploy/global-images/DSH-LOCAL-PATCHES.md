# dsh × TDAI 本机改动持久性台账

> 这份文件的存在理由：本机的"能用"不是纯净部署，而是 **7 个源码覆盖 + 5 个面板 dist 补丁
> + 1 处 L3 落盘物改动 + 2 份配置**。这些各自靠不同机制落地，**丢法也不同**（重建容器丢一批、
> 重建镜像丢另一批）。以前这些信息散在被 `.gitignore` 盖住的 `.proxy-config/NOTES-*.md` 里，
> 换台机器或重新 clone 就等于没有。

判据口径：**"已实测"= 本轮量到的读数；"未核"= 只是推断或历史结论，摘改前必须自己复量。**

---

## 1. MemoryProxy 源码覆盖（7 个文件）

落地机制：`.env` 的 `PROXY_SRC_MOUNTS`（`host:container` 空格分隔）→ `start-proxy.sh`
在 `docker run` 时逐条 `-v`。**镜像用 tsx 直跑 TS，挂文件即生效，无需 rebuild。**

| # | 文件 | 性质 | 上游有没有 | 摘掉的条件 |
|---|---|---|---|---|
| 1 | `anthropicHandler.ts` | §0.2 五修复之 #5（dsh 流式帧尾） | 远端 10-09 镜像里有，但**换了位置**：该文件被重构掉，逻辑在 `pipeline/runners/anthropic.ts` 的 `stageResponseTailFix` | 换新镜像后**必须摘**——继续挂是挂到不存在的文件上，反而把修复丢掉 |
| 2 | `session/dsh/form.ts` | §0.2 之 #1（anthropic SSE builder）+ #2 | 远端 10-09 镜像已含（`THINKING_SIGNATURE_PLACEHOLDER` 命中） | 换新镜像后可摘 |
| 3 | `session/codebuddy/cleaner.ts` | §0.2 之 #3（认 anthropic `role:"user"+tool_result`） | 远端 10-09 镜像已含 | 换新镜像后可摘 |
| 4 | `agent-adapters/dsh.ts` | §0.2 之 #4（认 anthropic content block array）+ **本机改的取文本方向** | 远端已含前一半；**方向语义相反**：上游 `extractLastUserText` 从后往前取，本机取第一个非空（0.1.7 把 `<system-reminder>` 追加进同一条 user 消息，反向会取到 reminder ⇒ mem 命令判未知） | **不能盲摘**。摘完第一件事实测 `mem:help` |
| 5 | `session/index.ts` | dsh 分支重渲染 `result.response` | **未核** | 摘前单独验一次表单回路 |
| 6 | `credit-reporter.ts` | 空 `creditReport.url` 守卫（关掉每请求刷 ERROR 的上报） | **本机自建**，远端未含 | 一直保留，或上游加同款守卫后再摘 |
| 7 | `routes/whitelist.ts` | `AGENT_PREFIX_RE` 补 `dsh`（救活 dsh 已注册却恒本地 404 的 aux 端点） | **未核**——远端 10-09 镜像是否已含 dsh 一项，我没 grep 过 | 摘前 `grep AGENT_PREFIX_RE` 看含不含 `dsh`，再跑 §3 的第 10/9 节 |

⚠ 第 7 项差点永久丢失：它一度**只靠 `docker cp` 进容器**（第 2 节那种落法），
重建容器即丢。2026-10-10 已把它加进 `PROXY_SRC_MOUNTS`（第 6→7 条），并**真实重建过一次
容器复验**：`tam-health.sh` 第 9 节三条 aux 断言照旧 200。

## 2. 面板补丁（3 个文件在可写层，另外 2 个此前被我错记成"补丁"）

admin 在 Chat_Memory 读不到 dsh 记忆的修复，源码侧在提交 `91bf4c2`，但**线上跑的是镜像里的
构建产物**，所以补丁打在容器可写层：
`/app/panel/dist/panel/http/app.js`、`/app/panel/dist/panel/http/routes/chat-memory.js`、
`/app/panel/web/dist/assets/main-CdwHEhgx.js`。

2026-10-11 用"容器那份 vs 镜像那份逐字节比"实测后，**纠正两条旧记录**：

| 文件 | 与镜像 | 真相 |
|---|---|---|
| `app.js`、`chat-memory.js`、`main-CdwHEhgx.js` | **不等** | 本机补丁确实在位 |
| `routes/knowledge/common.js` | **相等** | 镜像自带 `isCallerSystemAdmin`/`system_admin`/`owner_user_id` ⇒ 那一项**不需要本机补丁**，原先把它列进"打了补丁的 5 个文件"是错的 |
| `web/dist/index.html` | **相等** | 它引用的入口名 `assets/main-CdwHEhgx.js` 就是**原名**——"不许改名"这条本来就没被违反，列进补丁清单也是错的 |

- 落地机制：`docker cp` 进 **hub 容器可写层** → **重建 hub 容器就没了**，`docker restart` 不丢。
- 改名禁忌：入口 bundle **不能换文件名**（懒加载 chunk 按名静态引用入口 ⇒ 换名＝两份 React/store）。
- 备份：本机任务目录下的 `panel-live-20261010\`（绝对路径不写进仓库，见 `tam-prepush-audit.sh` 的 WORK_PATH 一类）。
- 闸：`tam-panel-patch-present.sh`（`tam-health.sh` 第 11 节调用）。判据是哈希不等=补丁在位；
  参照物 `routes/auth.js` 必须与镜像**相等**，否则整条比对链路作废。
  ⚠ 这个闸自己一开始是坏的：参照物填了 `routes/agents.js`，那个文件容器和镜像里**都不存在**，
  `sha256sum` 那侧回的是 `MISSING …` 文本，两侧截前 64 字符完全相同 ⇒ "比对链路可信"照样打 PASS。
  现在取哈希一律校验 `^[0-9a-f]{64}$`，拿不到真哈希就 FAIL。

## 3. L3 落盘物

`persona.md` 的 Scene Navigation 不随 `/v3/scenario/rm` 刷新（上游缺口，见 issue 草稿第 1 条），
删过 L2 场景后要靠 `node tam-l3-reconcile.mjs --apply` 用 `docker cp` 修。
判据在第 8 节；数据在 `tdai-memory-core-data` named volume，重建容器不丢。

## 4. 配置（两份，都是生成物，注释别写进去）

| 文件 | 由谁生成 | 手动改会怎样 |
|---|---|---|
| `.proxy-config/config.yaml` | `start-proxy.sh` 每次启动从 `.env` 重渲染 | **下次重启被冲掉**（2026-10-10 实测冲掉过一批注释）。要留说明写在 `.env` |
| `.memory-core-config/tdai-gateway.yaml` | `start-memory-core.sh` 同上 | 同上 |

`debugForceIdentity` / `skipAssetConfirm` / `PROXY_SRC_MOUNTS` / 上游 URL 等全部以 `.env` 为准；
管理面 key 也只在 `.env` + 被忽略的 yaml 里，脚本一律不内联（闸：`tam-no-secret-tracked.sh`）。

## 5. 客户端（dsh 桌面）配置

生效文件 `~/.dsh/profiles/desktop/cordis.patch.yml`，官方姿势已落：
`baseURL: http://127.0.0.1:8096/dsh/default`（**不带 `/v1`**，适配器自己追加 `/v1/messages`）、
`reasoningEffort: high`（适配器支持 `off|low|high|max`，`UNSUPPORTED_REASONING_EFFORT` 只在取值
越界时于发请求前抛）。切换器 `tam-apply-official-config.mjs` 版本硬闸读
**壳自带** `resources/runtime/primary-runtime/runtime.json`（`~/.dsh/dsh-runtimes/**` 那份是首次
运行的依赖沙箱记录，壳升级不刷新，别当判据）。改前自动备份 `cordis.patch.yml.bak-official-*`。

## 6. 丢了怎么发现（现有闸的覆盖面与缺口）

| 丢什么 | 哪节会响 |
|---|---|
| 7 个源码覆盖任一失效（帧尾/表单/取文本/aux 路由） | 第 9 节 aux 可达性 + 第 5 节注入 token 数 + 真客户端 `mem:help` |
| `config.yaml` 开关被冲回默认（auth/sessionInit/tdai 关掉） | 第 4 节配置判读（读 `.env` 侧的 provider/baseURL/effort） |
| 明文 key 进被跟踪文件 | 第 10 节 |
| L3 悬空 | 第 8 节 |
| **面板可写层补丁被重建冲掉** | 第 11 节（`tam-panel-patch-present.sh`，逐字节比镜像 + 参照物） |
| 上游把 `isCallerSystemAdmin` 那项改没了 | 第 11 节的 B 类标记断言 |
| 有人把入口 bundle 改名（双模块图事故） | 第 11 节：`index.html` 引用的入口名必须真实存在 |

## 7. 升级到新镜像时的执行顺序（每步单独可退）

1. Docker 挂代理（`hub.docker.com` 直连在本机超时；Clash 实测只监听 7897）或改配
   `registry-mirrors`；先 `docker manifest inspect agentmemory/memory-proxy:latest` 通了再往下
2. 拉新 proxy，**只重建 proxy 容器，挂载先全留** → `bash tam-health.sh` 须全绿
3. 在**新镜像里**逐个 grep §1 表格的标记 → 据此摘除已上游化的项，**一次摘一项、摘一项跑一次自检**
4. 桌面已在 0.2.0-rc.2、官方配置已生效（2026-10-10 真客户端实测），无需再动
5. 表单确认可用后再考虑撤 `debugForceIdentity`（ptc 会话里伪造表单弹不出是本机实测行为；
   它引用的源码判据字面串在装机包里没复核到，要看行为别看那句代码）
6. core / hub 升级放最后，且 hub 动手前先重新取一次 §2 的 dist 快照

---

## 附录 A：为什么还没升级（唯一硬阻塞是 Docker 不走代理，2026-10-10 量出来的）

| 证据 | 读数 |
|---|---|
| 系统代理 | `ProxyEnable=1`，`127.0.0.1:7897`（Clash Verge 按 PID 查**只监听 7897 一个口**，7890/7891/7898/3128/1080 全无响应 ⇒ "换个端口"在本机没有对象） |
| Docker 代理 | `~/.docker/config.json` 的 `proxies: {}`，未登录任何 registry |
| 不挂代理直连 | `hub.docker.com` / `registry-1.docker.io` / `auth.docker.io` **全部超时** |
| 挂上 7897 直连 | auth 200、registry `/v2/` 401（=可达的正常未鉴权响应）、hub API 200 |
| 本地 `node:22-slim` | **不存在** ⇒ 连"本地 `docker build` proxy 镜像"这条退路也堵死（Dockerfile 两个 stage 都以它为基） |

改法：Docker Desktop → Settings → Resources → Proxies → `http://127.0.0.1:7897` → Apply & Restart。
⚠ `~/.docker/config.json` 的 `proxies` 段只注入**容器内**环境变量，**不影响 daemon 拉镜像**；
真正管用的是上面那个 UI 设置。Restart 会让三个容器一起重启。
不想依赖 Clash 的替代路是 `registry-mirrors`（要重启 daemon，且公共 mirror 可用性需先实测）。

## 附录 B：镜像新旧与"能不能摘挂载"的取证

| 组件 | 本机现状 | 可用目标 |
|---|---|---|
| proxy 镜像 | 本地 `agentmemory/memory-proxy:latest`，构建 **2026-09-07** | 远端推送 **2026-10-09 11:40** |
| memory-core 镜像 | 约 4 周前 | 远端 2026-10-09 11:40:47 |
| memory-hub 镜像 | 约 3 周前 | 远端 2026-10-09 11:40:58 |

取证方式（不碰本机 Docker）：经代理从 registry 单独取回新 proxy 镜像的源码层
（`COPY /app /app`，54MB）解包 grep；entrypoint 仍是 `node --import tsx/esm src/index.ts`
⇒ 需要时 bind-mount 机制依旧可用。
本轮另用同一方法把 §1 那 7 个文件与**当前部署的旧镜像**逐字节比过：7 个全部 DIFFERS
（旧镜像确实缺这些修复）。

## 附录 C：客户端侧曾经的两处版本受限结论（现已作废）

- `baseURL` 末尾**必须带 `/v1`** —— 作废。当前适配器自己追加 `/v1/messages`，且末尾严格等于
  `/v1` 的路径段会被直接复用，两种写法最终都打到 `/dsh/default/v1/messages`；官方姿势是不带。
- `reasoningEffort` **不能出现** —— 作废。适配器支持的档位是 `off|low|high|max`（官方模板即
  `high`），`UNSUPPORTED_REASONING_EFFORT` 只在取值越界时、于**发出网络请求之前**抛出。

