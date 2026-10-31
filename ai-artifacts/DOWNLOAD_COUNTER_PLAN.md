# conda.qiyuan.me 下载计数（2026-10-31 起）

一个 Cloudflare Worker 挂在 conda.qiyuan.me 前面：请求原样转给 R2；包文件成功下载一次，就在 D1 里给该包的计数加一；
有人打开频道首页时，现场给首页的表加一列 Downloads。

## 已定的事（owner 2026-10-31）

1. 计数显示在频道首页现有的表里（owner："频道首页本来就有一个列表，可以做进去吗？"——可以，Worker 用 HTMLRewriter 现场改写）。
2. 下载一个包算一个计数，精确到包（"精确到包就够了"）：每个包名一个累计数，包名 = 文件名去掉最后两段 `-版本-build`；
   只数包文件（`.conda`、`.tar.bz2`）的完整成功下载（HTTP 200）。
3. CI 的下载不计入（"不计入"）：来自 GitHub 托管 runner 的 IP 段（`https://api.github.com/meta` 的 `actions` 与 `actions_macos`）
   不计数；Worker 的 Cron Trigger 每天取一次名单存 D1。代价已告知：别人在 GitHub 托管机器上的安装、Azure 上的真实用户也不计入。
4. 代码放本仓库新目录 `worker/`，两个新文件已批准："两个新文件批准"：`worker/wrangler.toml`、`worker/index.js`
   （数据表在首次使用时自动建）。`RELEASE_CHECKLIST.md` "The channel host" 一节加一条说明。用 `wrangler` 部署；token 用
   `CLOUDFLARE_GOD_KEY` 临时铸、用完撤销。
5. 先在本机 `wrangler dev` 测，交 owner 看；上线三步，每步等 owner 下令：(1) 只挂 `conda.qiyuan.me/noarch/index.html`，验转发到 R2；
   (2) 挂一个小包文件的确切路径，验计数与转发；(3) 挂 `conda.qiyuan.me/*`，路由设超额放行（fail open），撤销 token。
6. 评审 wf_ca0f0840-66e 的两个 owner 问题（owner："M5 按你建议来"、"M2 按你建议来"）：
   - M5：路由留在 `wrangler.toml`；上线第 3 步设好 fail open 后、撤销 token 前再 `wrangler deploy` 一次，回看 fail mode 是否还在；
     还在就写进 RELEASE_CHECKLIST 的说明，被冲掉就回来找 owner（改为把路由移出 `wrangler.toml`，加 `workers_dev = false`）。
   - M2：爬虫抓包文件会被计数，眼下没有链接通向包文件，先不处理；首页子目录链接 404 的 bug 若修好，再回头考虑（届时用桶里的
     robots.txt，不用 User-Agent 白名单）。
7. 评审的其余修法 owner 不需讨论（"需要跟我讨论吗？不需要的话我不予置评"）；首页子目录链接 404："先记下，以后再说"。
8. 【取代第 3 条的机制】2026-10-31 owner 否决每天的定时任务（"唯独你这个定时任务，有点蠢"），并更正范围："我们要排除的，只是我们
   自己的部署流程中导致的下载，而非所有 GitHub Workers 导致的下载"。定案：
   - 一个计数开关，发布的人手动拨（owner："或者干脆你来手动开关好了，写进 RELEASE.md 里"），发布期间真实用户的下载也不计
     （"可接受"）。
   - 开关放在 D1：一张只有一行的表记"暂停到何时"；暂停写入"现在 + 6 小时"，恢复删掉这一行；计数那条 SQL 里加"暂停未到期就不计"。
     owner 同意（"同意"）；时长 6 小时（"那就 6 小时好了。就这么定了"；实测 Isabelle 本体发布 3.1–4.0 小时，组件包都在半小时内）。
     再执行一次暂停就从那一刻重新算 6 小时。
   - 用法写在 RELEASE_CHECKLIST "The channel host" 一处；§9、本仓库 `RELEASE.md` 第 3 步、补丁工具仓库 `RELEASE.md` 各一句指过去
     （后者请 git 会话加）。
   - 去掉：定时任务、`runner_ranges` 表、取 GitHub 名单的代码、IPv4 区间计算。拨开关的 token 只要 D1 Write。
9. 评审 wf_8b52893a-024 的两个 owner 问题（owner："1 (a)"、"2 按你建议来"）：
   - S1 (a)：线上 `downloads` 里现有的行都是我们自己的下载；第 3 步的检查一过，立刻用第 3 步的 token 执行
     `DELETE FROM downloads`（部署与清空之间几分钟里真实用户的下载一并丢掉，同发布暂停的代价）。
   - S3 (b)：本仓库 `RELEASE.md` 的指引不放第 3 步，放在第 1 步之前、整个流程的开头（偏离第 8 条原定位置，owner 已批）。
   - 补丁工具仓库 `RELEASE.md` 的指引：git 会话已原文加进 "Releasing a feature" 第 6 步开头（2026-10-31），随它的"发布工具不只认
     2025.2"主提交一起进，等 owner 说"提交"；推上 GitHub 后它会告知。【已落地】git 会话 2026-10-31 告知：c8b17aa（主改动）与 647afac
     已推上 GitHub，那句在 "Releasing a feature" 第 6 步开头。

## 已查的事实（2026-10-31）

- Workers Free 每天 10 万请求，超额返回 1027；路由可设 fail open（超额时绕过 Worker），`wrangler.toml` 没有这个字段，在 dashboard
  的路由设置里设。每次请求、每次 cron 都是 10 ms CPU，文档说偶尔超出有余地。
- 路由通配符只能在主机名开头或路径末尾，不能 `*.conda`。
- D1 Free：每天（整个账户）读 500 万行、写 10 万行，DELETE 也算写；超额后当天所有查询被拒，00:00 UTC 重置。每条语句最多绑 100
  个参数。Analytics Engine 只留三个月，不用。
- GitHub 每周更新一次 runner 名单；不带 token 的 REST API 每个 IP 每小时 60 次。
- wrangler 4.151.1：配置里只写 `database_name` 时，`wrangler deploy` 先按名字找已有的库，找不到就新建（自动建库默认开）；
  `wrangler.toml` 有注释时不把 id 写回去。

## 作者在实现时定的

开关版本（第 8 条，2026-10-31）：
- 表 `pause (id INTEGER PRIMARY KEY CHECK (id = 1), until INTEGER NOT NULL)` 与 `downloads` 一起首次使用时建；计数是一条
  `INSERT … SELECT ?1, 1 WHERE NOT EXISTS (SELECT 1 FROM pause WHERE until > unixepoch()) ON CONFLICT … DO UPDATE SET n = n + 1`，
  仍是一次往返。暂停 `INSERT OR REPLACE INTO pause VALUES (1, unixepoch() + 6 * 3600)`，恢复 `DELETE FROM pause`
  （RELEASE_CHECKLIST 与本机测试用的是同一字面）。`wrangler.toml` 去掉 `[triggers]`。
- 本机测试 27 项全过（`run-tests.sh` 的开关段：暂停中下载照常、不计数；暂停 6 小时；暂停中新包的第一次下载不建行；再暂停从头算；
  到期自动恢复；手动恢复）；14 个变异抓到 13 个（漏的是首页删 ETag）。测试文件改为 `isabelle-ai-0.3.0-h4616a5c_2.conda`，
  不在任何路由上（评审 wf_8b52893a-024 S1），dev.log 里对第 2 步试验路由的请求为 0。

以下是 IP 名单版本（已被第 8 条取代，交评审 wf_ca0f0840-66e，按其裁定改过）：

- 只存 GitHub runner 的 IPv4 段，IPv6 客户端一律计数：GitHub 托管 runner 没有 IPv6 出口（actions/runner-images#668，
  2026-09 仍有人抱怨）。顺带把刷新的 CPU 从 BigInt 版的热态 ~8 ms、冷态 ~20 ms（node 22）降到热态 ~2.6 ms、冷态 7–10 ms。
- 名单只由 cron 刷新，每天一次（`17 4 * * *`），下载路径不刷新（早先一版在第一次下载时刷新，CPU 超限可能掐断正在传的下载）。
  【更正】我曾把 cron 改成每小时一次，没有标为偏离第 3 条；每次刷新删 1973 行再写 1973 行，一天会用掉 D1 免费写额度的 95%。
  评审 M1 判回第 3 条的每天一次。
- 每个 D1 batch 由 `batch()` 在前面接上两条 `CREATE TABLE IF NOT EXISTS`（"首次使用时建表"），只返回调用者自己那几条的结果；
  `count` 是 async，计数出错只让 waitUntil 失败，牵连不到下载。计数是一条 INSERT … SELECT … WHERE NOT EXISTS（查 runner）
  … ON CONFLICT 的 upsert。
- runner 段合并成不相交区间（5630 段里有 8 个重复起点，不合并会违反主键），查"lo 不大于地址的最大那段"；刷新是一个 batch：
  DELETE 全表，再用一条 `INSERT … SELECT … FROM json_each(?1)` 写入整个名单（JSON 作为一个参数）。
- `wrangler.toml` 不写 `database_id`（评审 M4）。
- 本机测试：`/var/tmp/claude-wrangler/run-tests.sh`（不进仓库），变异结果 `/var/tmp/claude-wrangler/mutation-results.txt`。

## 上线步骤与每步的检查（每步等 owner 下令）

第 1 步：
- 铸临时 token；部署、`wrangler tail` 和 `d1 execute --remote` 用到了哪些权限组，以及 token 的 zone 范围（按 Cloudflare 的说法：
  All zones，或指定 zone qiyuan.me），记进 RELEASE_CHECKLIST 的 `CLOUDFLARE_GOD_KEY` 那条，并写明以后重新部署照此铸 token。
- 挂路由之前：`curl -s -o before.html https://conda.qiyuan.me/noarch/index.html`（不带 Accept-Encoding）。
- 在 `worker/` 里 `wrangler deploy --route conda.qiyuan.me/noarch/index.html`；部署日志应有 `Creating new D1 Database "conda-downloads"`。
- 另开一个终端跑 `wrangler tail conda-download-counter --format pretty`（不加 `--ip self`），再 `curl -s -D - -o after.html` 同一地址：
  tail 里必须出现这次 `GET .../noarch/index.html`（没出现就是路由还没生效，等一会再 curl）；出现了，再看没有 Content-Encoding、
  `after.html` 与 `before.html` 相同。过了，就说明转发能落到 R2、线上不会给不带 Accept-Encoding 的客户端压缩内容。
- cron 从这次部署起就生效：第一次刷新在之后的第一个 04:17 UTC（定时任务最多 15 分钟后才生效）。
- 【已做 2026-10-31 07:19–07:22 UTC，owner："我们继续"，并指明用 GOD KEY 申请临时 key】token 用 GOD KEY 铸，3 小时过期，账户级
  Workers Scripts Write、D1 Write、Workers Tail Read、Account Settings Read，zone 级 Workers Routes Write、Zone Read，范围是本账户
  所有 zone（选它是因为只限一个 zone 时 wrangler 改走逐条接口、不删旧路由，第 3 步的复查也测不到）；已记进 RELEASE_CHECKLIST。
  从 HEAD b9b4a60 的 `worker/` 副本（`/var/tmp/claude-wrangler/deploy`，免得仓库里多出 `.wrangler/`）部署：日志有
  `Creating new D1 Database "conda-downloads"`，路由只有 `conda.qiyuan.me/noarch/index.html`，schedule `17 4 * * *`，
  Version ID c0828c96-be45-4665-8f35-f93dbfc2d7c0，没有 "Falling back"（走的是整表 PUT）。tail 里出现
  `GET https://conda.qiyuan.me/noarch/index.html - Ok`；不带 Accept-Encoding 时无 Content-Encoding；`after.html` 与 `before.html`
  逐字节相同（8626 字节）。`d1 execute --remote` 按名字可用。首页、repodata 不经 Worker。token 随即撤销（verify 返回
  Invalid API Token）。以后每一步各铸一个、做完就撤销，不留到第 3 步。

第 2 步：
- `wrangler deploy --route conda.qiyuan.me/noarch/isabelle-ai-0.2.0-h4616a5c_0.conda`；经 Worker 下载它一次，sha256 与
  https://conda.qiyuan.me/noarch/repodata.json 里该文件的 `sha256` 相符（同第 3 步的检查；挂了路由以后"直接下载"也经过 Worker，
  不能拿来比）；`SELECT * FROM downloads` 里 isabelle-ai 为 1。
- 【已做 2026-10-31 07:38–07:40 UTC，owner："继续"】部署日志 `env.DB (inherited)`，路由只剩这个包文件（PUT 替换了第 1 步的路由：
  之后取 `noarch/index.html` 不再出现在 tail 里），Version ID 66a1262d-e890-47ae-ab68-a4554f068f7a。tail 里有这次
  `GET .../isabelle-ai-0.2.0-h4616a5c_0.conda - Ok`；`200 4056`，sha256 7de57ef2…f380 与 repodata 相同；`downloads` 为
  `[{isabelle-ai, 1}]`；`runner_ranges` 为 0（第一次 cron 在 2026-11-01 04:17 UTC）。token 已撤销。
  【事故】第一次铸 token 时我的脚本里 Python 引号写错，POST 已发出、token 没存下（07:37 签发、09:37 过期）；用 GOD KEY 列出后
  撤销了它（之后列表里没有残留）。脚本已改成单独的 `save_token.py`，失败与成功两条路径都先用假响应试过。

第 3 步之前：开关版本（第 8 条）提交后，仍挂在第 2 步那个包文件上部署它：
- 部署：IP 名单版本留下的 `17 4 * * *`，wrangler 不会自己删（`triggers`/`crons` 没写时，已部署的 Cron Trigger 保留；空列表才删除，
  wrangler 源码 `resolveCronTriggers` / `triggersDeploy`，评审 S6）。所以只在这一次部署时，给部署副本
  （`/var/tmp/claude-wrangler/deploy`）的 `wrangler.toml` 末尾加 `[triggers]` / `crons = []`，仓库里的不改；然后
  `wrangler deploy --route conda.qiyuan.me/noarch/isabelle-ai-0.2.0-h4616a5c_0.conda`。之后 dashboard 的 Triggers 里不应再有
  Cron Trigger（最多 15 分钟后生效）。`DROP TABLE IF EXISTS runner_ranges`。
- 先经 Worker 下载那个包一次：isabelle-ai 加 1（说明新版本在计数，这次下载也建出了 `pause` 表；新版本收到第一个请求之前，暂停会报
  `no such table: pause`，评审 S2）。然后另铸一个只有 D1 Write 的 token，照 RELEASE_CHECKLIST 的字面暂停，再下载一次：不变；
  恢复，再下载一次：加 1；撤销这个 token。D1 Write 不够用就回来找 owner，不擅自加权限（评审 S7）。
- 【已做 2026-10-31 10:11–10:14 UTC，owner："好，我下令"】从 HEAD 5923bd0 的部署副本（仅这一次加 `crons = []`）部署，
  Version ID 1838b497-916b-4d81-a7a7-af028c3afed1，日志里不再有 schedule；API `GET …/schedules` 返回 `{'schedules': []}`。
  删表前有 `downloads`、`runner_ranges`，删后只剩 `downloads`；基准 isabelle-ai 103（第 2 步 1 次 + 本机测试 102 次，与评审 S1
  的估计相符）。部署 token 随即撤销。经 Worker 下载一次（200 4056，sha256 相符）。另铸只有 D1 Write 的 token：头两次调用被拒
  （`Authentication error [code: 10000]`），几秒后同一 token 正常——新 token 要几秒才生效，不是权限不够。暂停后剩 21598 秒；
  暂停中下载 200 4056，计数仍 104（说明第一次下载已计入、并建出了 `pause` 表）；恢复后下载，105。token 撤销，账户里无残留。
（原来的"`runner_ranges` 不能是 0"一项随第 8 条作废。）
【事故，评审 wf_8b52893a-024 S1 查出】`wrangler dev --local` 把请求转给 `wrangler.toml` 第一条路由的主机，即线上频道；本机测试的
主要下载文件恰是第 2 步挂上路由的那个包，所以第 2 步之后每跑一轮测试（含变异）就经线上 Worker 下载它约 6 次、被计数。线上
isabelle-ai 的计数估计已有约 90–100 次是我们自己的（推断，未读线上 D1）。本地测试服务器已停；改测试文件之前不再跑。

第 3 步：
- 在 `worker/` 里 `wrangler deploy`（`wrangler.toml` 的路由 `conda.qiyuan.me/*`）。紧接着：`https://conda.qiyuan.me/` 和
  `https://conda.qiyuan.me/noarch/` 都是 200；`curl -s https://conda.qiyuan.me/ | grep -c '<th class="s">Downloads</th>'` 是 1；
  RELEASE_CHECKLIST §11 的 repodata 命令能跑；经 Worker 下载 1 GB 的 `isabelle` 包，sha256 与 repodata 相符。任何一项不过，立刻删路由。
- 这些检查一过，立刻用第 3 步的 token 执行 `wrangler d1 execute conda-downloads --remote --command "DELETE FROM downloads"`
  （第 9 条 S1 (a)：此前的行全是我们自己的——第 2 步的核对、经第 2 步路由的本机测试、第 3 步之前的检查、第 3 步的 1 GB 核对）。
- 在 dashboard 的 Worker 路由列表里只留 `conda.qiyuan.me/*`（token 只限 zone qiyuan.me 时 wrangler 不删第 1、2 步的路由，部署
  日志的 "Previously deployed routes" 会列出它们，删掉），再把它设成 fail open；用同一个 token 再 `wrangler deploy` 一次（日志里
  不应再有 "Previously deployed routes"），回看 fail mode：还在，就在说明里写明范围，英文如 "a redeploy with a token whose zone
  resources are <scope> keeps it, checked <date>"；被冲掉，就回来找 owner（第 6 条 M5）。
- 撤销 token；RELEASE_CHECKLIST "A Worker counts downloads" 那条开头括号里的上线状态（"being rolled out: …"）改成部署日期，
  如 "deployed 2026-11-xx"。

- 【已做 2026-10-31 10:17–10:22 UTC，owner："下令"】第一次 `wrangler deploy` 在铸 token 后一秒内发出，失败（"Unable to get
  membership roles"，新 token 未生效所致，线上未变）；等 token verify 通过后重发成功，Version ID 6e7d4a15-…，路由只剩
  `conda.qiyuan.me/*`（第 2 步的被 PUT 替换）。`/`、`/noarch/`、`/linux-64/` 都是 200；首页 Downloads 表头 1 个；§11 命令出 JSON；
  经 Worker 下载 `linux-64/isabelle-2025.2-0.conda` 770243724 字节用 22.6 秒，sha256 与 repodata 相符。随后 `DELETE FROM downloads`
  （删前 isabelle-ai 105、isabelle 1，全是我们自己的），删后为空，`pause` 为空。
  fail mode：路由 API（`/zones/<zone>/workers/routes`）本身返回 `request_limit_fail_open`，默认 `false`（即 fail closed）。用 API
  PUT 设成 `true` 后读回为 true；用同一 token（本账户所有 zone）再 `wrangler deploy` 一次，路由被重建（id dd3369… → 22da52…），
  `request_limit_fail_open` 回到 false——**重新部署会冲掉 fail open**。已按第 6 条 M5 回来找 owner；在 owner 决定前用 API 重新
  设回 true（读回 true），token 已撤销。同一 zone 里另有一条不相干的路由 `aoa.qiyuan.me/usage_counter*`（Worker aoa-usage-count），
  未动。
- owner 问"为什么要开超额放行？我们不应该开啊"，解释（免费档超额不收费；放行 = 超额后绕过 Worker、频道照常，拒绝 = 1027、整天
  打不开）后答"好的，赞同 (b)"：路由留在 `wrangler.toml`，每次部署后用 API 把 `request_limit_fail_open` 设回 true；写进
  RELEASE_CHECKLIST "The channel host"。（理解为对上一条 M5 回访里 (a)/(b) 的 (b)；已在回复里说明这一理解。）

第 3 步之后：
- 下一次正式发布时照 RELEASE_CHECKLIST 暂停；暂停后 `curl -s https://conda.qiyuan.me/ > before-release.html`（首页的 Downloads
  列就是 `downloads` 表，不用 token）；发布跑完、恢复之前再取一次，所有包的 Downloads 都不应增加，以此确认暂停在实际发布里有效。
  增加了就停下来找 owner。

## 交接（2026-10-31 10:30 UTC 前后，压缩前写）

- 线上：Worker `conda-download-counter` 版本 67d107fc-3df0-4a65-affb-83351f3bc155（= HEAD 5923bd0 的 `worker/`），路由
  `conda.qiyuan.me/*`（id 22da52ecf59245b3bb34367acbdf0a78，`request_limit_fail_open: true`），无 Cron Trigger；D1
  `conda-downloads` 只有 `downloads`（10:19:51 UTC 清空过）与 `pause`（空）。账户里没有留下任何临时 token。
- 未提交：RELEASE_CHECKLIST.md（"live since 2026-10-31"、fail open 每次部署后用 API 设回、新 token 头几秒被拒要重试）——等
  owner 说"提交"。`ai-artifacts/` 的两份计划是新文件，owner 尚未逐个批准提交。
- 工具（都不进仓库）：wrangler 4.151.1 与 node 22 在 `/var/tmp/claude-wrangler/`（`env/`、`node_modules/`）；部署副本
  `/var/tmp/claude-wrangler/deploy/`（每次先从 HEAD 重取 `worker/` 两个文件）；本机测试 `/var/tmp/claude-wrangler/run-tests.sh`
  （端口 8787，状态 `state2`；跑之前确认测试文件不在任何线上路由上——第 3 步之后全站都在路由上，再跑就会被计数，先暂停计数或别跑）。
  token 脚本在本会话 scratchpad 的 `cf/`：`mint.sh <小时> [请求文件]`（默认部署 token 的 `token-request.json`，D1 专用
  `d1-token-request.json`）、`revoke.sh`、`wr.sh <wrangler 参数>`、`save_token.py`、`env.sh`（只读 secret.sh 的 GOD KEY 与账户 id）；
  zone id 存在 `cf/zone.id`。评审材料在 `/var/tmp/claude-review-counter/`（三轮：根目录、`re-review/`、`switch/`）。

## 待办

- 首页指向子目录的链接（conda-index 生成的 `href="noarch"` 等，没有结尾斜杠）打开是 404：那条 Transform Rule 只改写以 `/` 结尾的
  路径。owner："先记下，以后再说"。修好以后爬虫能顺着链接找到包文件，届时重看第 6 条 M2。
