# Isabelle + AoA 打包发布方案(实证版)

> **本文档地位**:这是打包发布的**权威参考**。2026-07-11/12 的一轮工作把此前的设计**推翻重写**了
> —— 旧方案(复用用户已装的 Isabelle + conda post-link 写全局 settings)已作废,理由见 §9。
> 本文档中的每条结论都标注了**证据来源**;凡标「实测」的都是在真机/真 CI 上跑出来的,不是推断。

---

## 1. 目标

把 `contrib/` 下的 AoA 工具链(`Isa-Mini`、`Isa-REPL`、`Isabelle_RPC`、`Semantic_Embedding`、
`Performant_Isabelle_ML`、`auto_sledgehammer`)发布出去,让用户能装上并在 Isabelle 里 `by aoa`。

前置事实:AoA 依赖的 Isabelle **必须打过 `my_better_isabelle_prover` 的补丁**
(`register_thy` 是 Isa-REPL 的硬依赖,`pide_control` 是 Isabelle-MCP 的硬依赖)。
所以「发布 AoA」不可避免地要「发布一个打过补丁的 Isabelle」。

---

## 2. 核心决策

**我们自己跑一条「打补丁版 Isabelle」的官方级发布流水线,产出各平台完整包,再发到 conda。**

- 从**官方 hg 仓库**取某个 release 的精确 changeset;
- 打上我们的补丁并 **`hg commit`**;
- 跑**官方的 `Admin/build_release`**(不重造轮子);
- 每平台产出与官方同构的 bundle(含**预建的、打过补丁的 HOL heap**);
- 用 GitHub CI 自动化;
- 打成 conda 包发到自建 channel。

三个支撑这个决策的硬事实(详见 §3):
1. **conda 要能干净管理,文件就必须打进包**——post-link 下载的东西 conda 根本不跟踪。
2. **heap 每平台各异、不能共享**,且**官方发行包本来就自带预建 HOL heap**——要做到官方级体验,
   就得自己每平台 build 一遍打过补丁的 heap。
3. **补丁改了 Pure/ML 与 Scala**,必须经 `scala_build` 与 `build_heaps` 才能生效——
   而 `build_release` 天然会做这两件事。

---

## 3. 实证事实清单(本方案的地基)

### 3.1 conda 机制

| 事实 | 证据 |
|---|---|
| post-link **不能交互** | `Popen(stdout=PIPE)` + `communicate()`,`stdin=None`(`conda/gateways/subprocess.py:58,62`) |
| post-link **成功时 stdout 不可靠显示** | conda-build 文档明令「除非出错,不要写 stdout/stderr」 |
| **post-link 在 `$PREFIX` 新建的文件,conda 不跟踪** | 不在包的 `info/files` → `conda remove` 不删、`conda list` 不见、不可复现 |
| **pre-unlink 不保证执行** | 用户直接删 env 目录时不会逐包跑 → 外部副作用可能永久残留 |
| ⇒ **「conda 干净管理」⟺「文件打进包」** | 这是机制,不是政策 |
| **业界已弃用「post-link 下载」** | `cudatoolkit-dev`(post-link 下载)**已于 2025-10-01 归档**;现代 CUDA 全部把文件打进包,用 `outputs` 拆包 + 元包聚合 |
| conda-build 对 post-link 的规定 | 「能不用就不用」「只碰正在安装的文件」「只依赖 rm/cp/mv/ln」 |
| conda-forge 约束 | 无网构建 + SHA256 锁定 + 频道不可删改(可复现) |

### 3.2 conda 命名与版本

- 包标识 = **`name-version-build`** 三段,以 `-` 分隔 ⇒ **version 里不能有 `-`**。
- ⇒ **`Isabelle2025-2` 必须写成 conda version `2025.2`**。
- 精确上游 changeset(`89701cf1768e`)与补丁信息放 **build string**,不进 version。
- **同版本改内容 ⇒ bump build number**(`_0` → `_1`);别原地 `--force` 覆盖(客户端按文件名缓存,用户会吃旧包)。
- 排序:conda 自己的 VersionOrder(数字段按数值比;`dev` 特殊;epoch `N!` 优先级最高)。
- **包名 `isabelle` 完全空着**(anaconda.org API 实测:`conda-forge/isabelle` → 404;全站搜 `name=isabelle`
  只有 `isabelle-client`,是另一个名字)。而且 conda 包名是**按 channel 的命名空间**,不存在全局占用。

### 3.3 conda channel —— **我们自建,托管在 Cloudflare R2**

- **只有 channel 拥有者能上传**。要让多人发布 ⇒ 建 **Organization**,把维护者加为成员。
- **别人无需你的许可**就能在自己的 channel 发包并依赖你的包。但 **conda 依赖按包名解析、不绑 channel** ⇒
  **安装者必须能看到你的 channel**(`-c 你的channel` 或写进 `.condarc`),否则 `PackagesNotFoundError`。
  下游作者**无法在包里焊死依赖来源**——channel 可发现性是最终用户的责任。

#### ❌ anaconda.org 托管不了我们(已查证)
- **免费账号只有 3 GB 包存储**(官方 FAQ 原文:"up to 3GB of storage space for any packages you upload")。
- **付费也没有自助扩容通道**:pricing 页的 FREE / $15 / $50 / Custom 里,那些存储数字(5/10/20 GB)
  **是"云笔记本存储",不是 anaconda.org 的包托管额度**;官方文档**完全没提**付费能加包存储。
- 我们的需求:`isabelle` 包 **~1 GB × 4 平台 ≈ 4 GB / 每个版本**,且**按版本与 build number 累积**。
  ⇒ **3 GB 连一个版本都放不下,上线即爆。**

#### ✅ 定案:自建 channel,静态托管在 R2
conda channel 本质就是**一棵静态文件树 + 各平台的 `repodata.json`**,任何 HTTP 服务器都能当 channel。

| 项 | 值 |
|---|---|
| **R2 bucket** | **`conda`**(专用新 bucket,公开读) |
| **S3 API endpoint** | `https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com`(bucket 名 `conda`) |
| **channel 域名(用户用的)** | **`https://conda.qiyuan.me`**(R2 custom domain → bucket 根) |
| **用户命令** | `conda install -c https://conda.qiyuan.me isabelle` |
| **CI 凭据** | `CONDA_R2_ACCESS_KEY_ID` / `CONDA_R2_SECRET_ACCESS_KEY` / `CONDA_R2_TOKEN_VALUE`(本机在 `secret.sh`,**已 gitignore**;CI 里放 GitHub secrets) |
| **上传** | 任何 S3 兼容客户端(`aws s3 --endpoint-url=…` / `rclone` / boto3) |
| **索引** | 每次上传后跑 `conda index`(或 `rattler-index`)重新生成各 `repodata.json` 再传上去 |

channel 的目录结构(= bucket 根):
```
conda.qiyuan.me/
├── noarch/          repodata.json + *.conda
├── linux-64/        repodata.json + *.conda
├── linux-aarch64/
├── win-64/
├── osx-64/
└── osx-arm64/
```

**为什么用子域名而不是 `qiyuan.me/conda`**:R2 的 custom domain 是 **主机名 → bucket 根** 的映射;
顶级路径要额外写 Cloudflare Worker 做路径路由,多一个会坏的活动部件。

**为什么用专用 bucket**:CI 需要**写**权限 —— 它的 token 只应能写这个 bucket,
**绝不能有权写 semantic DB 那个生产 bucket**(最小权限);而且 conda 包按版本累积,
生命周期/保留策略与 DB 完全不同。

#### ✅ 已端到端打通(实测)
```
$ conda create -n smoke -c https://conda.qiyuan.me --override-channels channel-smoke-test
  channel-smoke-test  0.1.1  h4616a5c_0     ← 从我们自己的 channel 解析、下载、安装成功
```
自定义域名**即时生效**;Content-Type / 压缩协商 / CORS **都不用管**;**R2 multipart 上传可用**(1GB 大包 OK)。
`channel-smoke-test` **留在 channel 里当长期健康探针**——任何时候能装上,就说明链路是好的。

#### CDN 缓存:**是传播延迟,不是正确性问题**(措辞已修正)

**只影响 manifest,不影响包本体**(实测):Cloudflare **按文件扩展名**决定缓存 ⇒

| 文件 | Cloudflare 行为 |
|---|---|
| `repodata.json` | **DYNAMIC(不缓存)** |
| **`repodata.json.zst`** | **HIT,`max-age=14400`(4h)** ← 唯一被缓存的 |
| `*.conda`(包本体) | **DYNAMIC(不缓存)** |

conda 优先取 `.zst` ⇒ **新发布的版本最多 4 小时后才被看到**(实测:发了 0.1.1,干净的 conda 装到 0.1.0)。

**这不是"发错包",是延迟**:包文件**不可变**(名字含 version+build)、**旧包我们不删** ⇒
用户拿到陈旧索引只会装到一个**真实存在、能用的旧版本**,不会损坏。
边缘节点之间短暂不一致,在包生态里(conda-forge / PyPI 都有 CDN)是**常态**,用户本来也不会同时更新。

**延迟有多长**(实测 + 机制推断):单层 TTL **4h**;**conda 客户端自己也缓存 repodata 4h**
(它遵守 `cache-control`)⇒ 叠加起来**理论最长 ~8h**(若开了 Tiered Cache 再 +4h)。
实践中常远短于此(低流量对象在边缘会被较快淘汰)。

**唯一真正的正确性风险**:如果哪天**删/撤回**一个包,陈旧索引会指向已消失的文件 → 404。
⇒ **规避:永不删包,改内容只 bump `build_number`**(本来就是我们的规矩)。

#### ✅ 正确的解法:Cloudflare 的默认对我们是**反的**,用两条 Cache Rule 纠正

| | 应该怎样 | Cloudflare 默认 |
|---|---|---|
| **manifest**(`repodata*`)—— **可变** | **不该缓存** | ❌ 偏偏缓存 4h |
| **包**(`*.conda`)—— **不可变** | **正该缓存**(用户下载快、少打源站) | ❌ 偏偏没缓存 |

```
1)  path contains "repodata"   → Bypass cache            （manifest 永远新鲜）
2)  path ends with ".conda"    → Cache, Edge TTL 1 month （包不可变，缓存 100% 安全，纯赚）
```
设了第 1 条,**`--no-zst` 就完全不需要**。`conda index --no-zst` 只是**没有 zone 权限时的替代品**
(效果相同:不产生 `.zst` → conda 回落到本来就不缓存的 `.json`)。
我们的 repodata 只有**几 KB**(对照 conda-forge 的 linux-64 有 ~200MB),压不压缩无所谓。

#### 工具链(实测定案)
| 环节 | 工具 | 说明 |
|---|---|---|
| 建包 | **`rattler-build`** | 单个 Rust 二进制,~2 秒;直接产现代 `.conda`;conda-build 已进维护模式 |
| 索引 | **`conda-index`** | 官方实现,带 sqlite 增量缓存(`<channel>/<subdir>/.cache/`),对 1GB 大包友好 |
| 上传 | **`rclone` ≥1.74**(conda-forge 版) | ⚠️ **Ubuntu 自带的 1.60 对 R2 有两个 bug**:不加 `--s3-no-check-bucket` → 403;**每个 PUT 首次必失败**(1GB 包等于传两遍) |

```bash
# 凭据(环境变量配 remote,不落盘)
source secret.sh
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare RCLONE_CONFIG_R2_REGION=auto
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$CONDA_R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$CONDA_R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT=https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com

rattler-build build --recipe recipe/recipe.yaml --output-dir output
python -m conda_index $CH --no-zst --no-bz2 --channeldata --channel-name conda.qiyuan.me
rclone sync $CH R2:conda/ --s3-no-check-bucket --exclude '.cache/**' \
       --s3-chunk-size 64M --s3-upload-concurrency 4 --transfers 2 --progress
```

**大包注意**:
- **必须保留一份与 bucket 一致的本地 channel 目录** —— `conda index` 只索引本地文件,而
  `rclone sync` 会**删掉 bucket 里本地没有的文件**。发布前先 `rclone sync R2:conda/ $CH/` 拉回。
- **保留本地 `.cache/`(sqlite 增量索引)**,但**上传时排除它**。
- 包文件**不可变**:改内容就 **bump `build_number`**,别复用文件名(用户 pkgs 缓存 + CDN 都会给陈旧副本)。
- **egress 免费**(R2),1GB 包分发无带宽成本。

### 3.4 Isabelle 的发布机制(源码级,`src/Pure/Admin/build_release.scala`)

- **`Isabelle2025-2` = hg changeset `89701cf1768e`**(`.hgtags`;与发行版 `etc/ISABELLE_ID` 吻合)。
- **精确源只能走官方 hg**(`https://isabelle.in.tum.de/repos/isabelle`);
  GitHub 镜像 `isabelle-prover/mirror-isabelle` 的 **git tag 只到 2021**,拿不到 2025-2 的树
  (它的 master 是 2025-2 之后的开发线,别用)。
- **⚠️ `build_release` 从「已提交的 hg rev」做 archive,不是工作区**(`hg.archive(rev=id)`,
  build_release.scala:439-453)。**改了工作区不 commit,补丁会被整个丢掉。** 这是最容易踩的坑。
- **阶段一 `build_release_archive`**:`hg archive` → `other_isabelle.init`
  (= 下载 native 组件 + **`scala_build`**(把补丁编进 `lib/classes/isabelle.jar`))
  → **`build_doc -a`(需要完整 TeX Live)** → purge 掉 `Admin/`/`heaps`/`.hg` → 打出
  **通用源码 archive `Isabelle2025-2.tar.gz`**(带编译好的 Scala,无 heap)。
- **阶段二**:对每个平台 → 从官方 component 仓库(**`https://isabelle.sketis.net/components`**)
  **下载**预编译 native 组件(polyml/jdk/E/Z3/cygwin…,版本以**该 rev 自带的 `Admin/components/main`** 为准,
  **别用镜像 tip 的**,它已漂到 polyml-5.9.2-4/jdk-25)→ **`build_heaps`** → 按平台组包。
- **`build_heaps` 不能跨架构**:本机 family ≠ 目标平台且没配 `build_host_<platform>` SSH 主机 ⇒ **直接报错**。
  官方模型 = 一台协调机 + 每平台一台 SSH 构建主机。
- **`-b SESSIONS` 默认为空**;官方发布清单(`Admin/Release/CHECKLIST`)实际传 **`-b HOL`** ⇒ 官方包**带 HOL heap**。
- **`-S ARCHIVE`**:跳过阶段一(**连带跳过 hg、TeX、scala_build**),直接进平台组包 ⇒ **各平台 job 可复用同一份 archive**。
  - 【实测】`build_release_archive` 若发现已存在的 archive 会**复用并跳过整段 build_doc**(省 ~30 分钟)。
- **平台差异**:linux/linux_arm → `.tar.gz`;**macOS 是单个 universal 包**(一台 Apple Silicon 上
  `ML_system_apple` false/true 双 build,同时产出 x86_64-darwin + arm64-darwin 两套 heap);
  windows → launch4j `.exe` + 7z 自解压。**Isabelle 不发布 arm64-windows** ⇒ 「5 个架构」在 Isabelle 口径下是 **4 个 bundle**。
- **bootstrap**:裸 hg checkout 用 `Admin/init`(`components -I` → `components -a` → `scala_build`)即可,
  靠 repo 自带的 `isabelle_setup.jar` 引导,**不需要预装 Isabelle**。

### 3.5 heap(实测,下载 pristine 官方包比对)

- heap 存在 `heaps/<ML_IDENTIFIER>/`,**`ML_IDENTIFIER` 编码 polyml 版本 + 架构 + OS**:

  | 平台 | ML_IDENTIFIER |
  |---|---|
  | Linux x64 | `polyml-5.9.2_x86_64_32-linux` |
  | Linux ARM | `polyml-5.9.2_arm64_32-linux` |
  | Windows x64 | `polyml-5.9.2_x86_64_32-windows` |

- **三平台 Pure heap 的 sha256 全不同**;连**同架构不同 OS**(Linux-x64 vs Windows-x64,都是 `x86_64_32`)
  也不同。Poly/ML saved state(`POLYSAVE` 魔数)本质是架构+OS 固有。
  ⇒ **heap 不能跨平台共享,必须每平台各 build。**
- **官方 pristine bundle 自带预建的 `Pure` 和 `HOL` heap**(HOL ~208MB)。
- heap **可再分发、不内嵌 `ISABELLE_HOME` 绝对路径**(用户确认)⇒ 可以随包分发。

#### ⭐ heap 是**层级增量(delta)**,不是完整镜像

子 session 的 heap **只存相对父 session 的差量**;运行时由 Poly/ML 的
`SaveState.loadHierarchy ["Pure", "HOL", ...]` 按层级串起来加载。实测(同一台机、同一 ML_IDENTIFIER):

| heap | 大小 |
|---|---|
| `Pure` | 31 MB |
| `HOL`(父 = Pure) | 336 MB |
| **`Main`(父 = HOL)** | **3.8 MB** |

**这条改变了成本估算**:
- **加 `Main` 几乎免费**(+3.8 MB,构建时间近乎瞬时——它只是 HOL 之上的一个 `Main_Doc` theory)。
- 同理,**我们自己的 AoA session heap(`Minilang_Agent` 链)也是 delta,不是几百 MB 的完整镜像** ⇒
  将来若想预建它们让用户开箱即用,**包体积不是障碍**,真正的代价只是 **CI 构建时长**(要跑完
  Auto_Sledgehammer / Semantic_Embedding / Isa_REPL / Minilang 那条链)。

#### `Main` 是一个真实 session(别被 `(doc)` 误导)
`src/Doc/ROOT:310`:`session Main (doc) in "Main" = HOL +`,含 theory `Main_Doc`。
`isabelle sessions -a` 里有它,`isabelle sessions -b Main` 给出依赖链 `Pure → HOL → Main`。
**我们的工具链用 `Main` 作默认 session**(官方发布只 `-b HOL`,不带 `Main`)⇒
**我们必须 `-b HOL,Main`。**

#### 🔴🔴 `heaps/*/log/<S>.db` **必须随 heap 一起发**(2026-07-12 实测,差点让整条流水线白做)

`log/` 这个名字骗人:**`log/<S>.db` 不是日志,是 session 数据库**。
`isabelle build` 判断"某 session 已建好且是最新的",**查的是这个 db,不是 heap 文件在不在**。
官方 bundle 里就带着这些文件。

CI 的 Job B–E 曾在上传 heap artifact 前 `rm -rf heaps/*/log`,后果:

| | 装上包后第一次真实 build |
|---|---|
| **缺** `log/*.db` | `Building HOL ...` → **整整 20 分钟重编 HOL** |
| **带** `log/*.db` | `Finished (0:00:01)` → **10 秒,直接加载 heap** |

两种情况下包都能正常安装、`isabelle version` 都能跑 —— **那 350MB 的 heap 只是死重**。

⚠️ **`isabelle build -n` 是个假阳性检查,不能用来验收**:缺 db 时它照样报告"无需构建",
而真 build 立刻重编 HOL。**验收必须真跑一个建在 `Main` 之上的 session,并在看到 `Building HOL` 时判失败。**

### 3.6 Windows(真 Win11 VM + GitHub CI 实测)

- `bin/isabelle` 是**无扩展名的 Cygwin bash 脚本**;`cmd /c isabelle` → **9009 not recognized**。
  ⇒ 必须提供 `isabelle.bat` 包装器:
  ```bat
  @echo off
  setlocal
  set "ISABELLE_HOME=<Isabelle 根目录>"
  set "HOME=%HOMEDRIVE%%HOMEPATH%"
  set "LANG=en_US.UTF-8"
  set "CHERE_INVOKING=true"
  set "CYGWIN=nodosfilewarning"
  set "PATH=%ISABELLE_HOME%\bin;%PATH%"
  "%ISABELLE_HOME%\contrib\cygwin\bin\bash.exe" --login -c "exec isabelle \"$@\"" isabelle %*
  endlocal
  ```
- **【实测·截图确认】`isabelle.bat jedit` 真的弹出完整 GUI**:窗口标题 `Isabelle2025-2/HOL - Scratch.thy`、
  **`Prover: ready`**、Documentation 面板完整、HOL heap 已加载。**Windows 侧最大的未知数已关闭。**
#### ✅ `isabelle.bat` 已定稿(控制台挂起问题已修复并验收)

**原问题**:链路 `cmd → bash → bash → java` 全同步 ⇒ 控制台一直挂着,**关掉它就杀死 jEdit**
(java 挂在发起者的 console 上,收到 `CTRL_CLOSE_EVENT`)。

**最终方案:cygwin 的 `run.exe`**(GUI subsystem、隐藏 console)detach。
**文件:`/home/qiyuan/qemu-win/isabelle.bat`**。

> ### 🔴 未完成:**它必须放进 `<ISABELLE_HOME>\bin\` 并自定位**
> 当前版本**把路径写死了**(`set "ISABELLE_HOME=C:\isa\Isabelle2025-2"`)——那是测试期产物。
> **conda 装到每个用户/环境都不同的 `$PREFIX`,写死路径的版本根本用不了。**
>
> **必须改成**:
> - **位置:`<ISABELLE_HOME>\bin\isabelle.bat`**(与 Linux/macOS 的 `bin/isabelle` 同一位置
>   ⇒ 用户指引统一:"把 `<ISABELLE_HOME>/bin` 加进 PATH";Windows 靠 `PATHEXT` 把 `isabelle` 解析成 `.bat`)
> - **自定位**:`pushd "%~dp0.." && set "ISABELLE_HOME=%CD%" && popd` —— **不得写死任何绝对路径**
>
> **待验证的两点**(正在做):
> 1. **递归**:`bin/` 里会同时有 `isabelle`(Cygwin bash 脚本)和 `isabelle.bat`。
>    cmd 按 PATHEXT 命中 `.bat`;Cygwin bash **不认 PATHEXT**,应命中 bash 脚本 ⇒ **不会 `.bat`→bash→`.bat` 无限递归**。
>    **必须实测 `type -a isabelle` 确认。**
> 2. **可重定位**:把整棵树复制到另一个路径后,`isabelle.bat` 仍须全功能正常。**这是它能否进 conda 包的判据。**
>
> conda 包里的摆法:
> ```
> $PREFIX/opt/Isabelle2025-2/bin/isabelle.bat   ← 真身（自定位）
> $PREFIX/Scripts/isabelle.bat                  ← 一行转发器（conda 的 Windows bin 目录，activate 后在 PATH 上）
> ```

两个候选被**实测否决**:
- **`start "" /b` 否决**:探针(`GetConsoleProcessList`)证明 java **仍挂在同一个 console 上**
  (`VERDICT: ATTACHED`)→ 关窗口照样杀 jEdit。它只治"挂住",不治"被杀"。
- **launch4j `.exe` 不能替代 `isabelle jedit`**:`JEdit_Main.main` **没有任何选项解析**(只特判 `-init`),
  logic/session 来自 **bash 版 `jedit` 脚本从 `-l/-d/-R/-i` export 的环境变量** ⇒ exe 表达不了
  `-l HOL-Analysis`,也跳过 `scala_build`,更没有 `-b`;还配了 singleInstance mutex。

**GUI vs `jedit -b` 的判别:忠实复刻 `getopts` 规格**
(`src/Tools/jEdit/lib/Tools/jedit`:`getopts "A:BFD:J:R:bd:fi:j:l:m:no:p:su"`),**27/27 矩阵实测通过**。
naive 的"参数含 `-b` 就同步"**两头都会错**:
- `isabelle getenv -b ISABELLE_HOME` → 该同步,naive 会当 GUI;
- `isabelle jedit -d -b`(`-b` 是 `-d` 的值)→ 该 GUI,naive 会当同步。

**验收(全部实测)**:`jedit` **0.22s 返回** + GUI 弹出(截图 `Prover: ready`)+ **关掉发起的控制台后 jEdit 存活**
(探针 `VERDICT: DETACHED`);`jedit -b` 仍同步 exit=0;`getenv -b` exit=0;`build` 的 0/2 退出码正确透传。
逃生开关:`ISABELLE_BAT_SYNC=1`(强制同步,给 CI 兜底)、`ISABELLE_BAT_DRYRUN=1`(只打印 GUI/SYNC 决策)。

#### ⚠️ 顺带发现一个**上游 Isabelle bug**(不是我们的,但会咬用户)

`lib/scripts/getfunctions`:`platform_path() { cygpath -i -C UTF8 -w -p "$@"; }`
—— **`-p` 是"路径列表"模式**,`:` 被当作分隔符:
```
C:\isa\t\Probe_Arg.thy          →  C;C:\isa\t\Probe_Arg.thy    ← 被毁
/cygdrive/c/isa/t/Probe_Arg.thy →  C:\isa\t\Probe_Arg.thy      ← 正确
Probe_Arg.thy                   →  Probe_Arg.thy               ← 正确
```
⇒ **`isabelle jedit C:\绝对\路径.thy` 在 Isabelle2025-2 上本来就打不开文件**(开一个同名空 buffer + I/O error)。
**规避:传 POSIX 路径或相对路径。这条要写进用户文档。**
(讽刺的是 launch4j 的 `.exe` 反而没这问题——它绕过了 `platform_path`。)
- **⚠️ Session 0 陷阱**:SSH 进来的 shell 在 **Session 0(无桌面)**,真实桌面是 Session 1。后果:
  - 官方 SFX **无法在 SSH 下静默安装**(卡在无人应答的 GUI 提示框)⇒ 用 `7z x` 抽取 + 单独跑 `-init`;
  - **GUI 必须打进 Session 1**(`schtasks /it`);
  - **从 Session 0 枚举不到 Session 1 的窗口 ⇒ `MainWindowTitle` 全是空。
    窗口标题断言不可靠,截图才是 ground truth。** 这直接决定了 CI GUI 测试怎么设计(见 §7)。
- **一次性 `-init`**(恢复 Cygwin symlink + `rebaseall` + `postinstall`)必须先跑,否则 `isabelle` 会坏;
  headless 下**可无人值守完成**(实测)。conda/tar 安装绕过了 SFX 的 AutoInstall ⇒ **必须显式做这一步**
  (最省心:在真 Windows 构建机上 `-init` 之后再打包)。
- **环境变量形态**(原生 Windows Python 从 Isabelle settings 环境继承到的):
  ```
  ISABELLE_ROOT      = C:\isa\Isabelle2025-2                      [原生]
  CYGWIN_ROOT        = C:\isa\...\contrib\cygwin                  [原生]
  ISABELLE_HOME      = /cygdrive/c/isa/Isabelle2025-2             [POSIX]
  ISABELLE_HOME_USER = /cygdrive/c/Users/x/.isabelle/...          [POSIX]
  （不存在 *_WINDOWS 变体;ISABELLE_HOME_USER 没有原生形态的对应变量）
  ```
  实测 `cygpath -w $ISABELLE_HOME == $ISABELLE_ROOT`。
  ⇒ **Isabelle_RPC 的路径 bug 已修复**(`Isabelle_RPC_Host/paths.py`,commit `5b9580c`):
  `/cygdrive` 走纯字符串规则(不开子进程、不经 locale ⇒ 非 ASCII 用户名安全),
  cygpath 仅作 Cygwin 内部路径的兜底且读 bytes。

#### 🔴 **conda 安装路径不能含非 ASCII 字符**(上游缺陷,不是我们的锅)

装在 `C:\中文 目录\Isabelle 2025-2` 下时,`isabelle build` / `jedit -b` 报
**`could not find java.dll`**。`getenv -b ISABELLE_HOME` 本身是**对的**(自定位没问题),
炸的是 Isabelle 自带的 java 启动器。

**对照实验证明与我们无关**:完全绕过 `isabelle.bat`、直接用该树自己的 Cygwin bash 调
`bin/isabelle`,**报同样的错**。⇒ 上游 launcher 不支持非 ASCII 路径。
**必须写进用户文档:Windows 上 conda env 的路径不能有非 ASCII 字符。**
(路径**带空格**反而完全没问题,`C:\Program Files\Isabelle 2025-2` 实测通过。)

#### `isabelle.bat` 自定位:那个"一行版"写法是坏的
```bat
pushd "%~dp0.." && set "ISABELLE_HOME=%CD%" && popd     ← 错
```
cmd 在**解析整行时**就展开 `%CD%`,拿到的是 `pushd` **之前**的 cwd。实测(cwd=`C:\Windows`)
得到 `ISABELLE_HOME=C:\Windows`。**必须拆成三行。**
这坑很阴险:用户恰好在 ISABELLE_HOME 里敲命令时,它**看起来是对的**。

#### 🔴🔴🔴 **MAX_PATH:win-64 的包在默认 Windows 上装不上**(2026-07-13 真机实测,新发现)

**这是当前 win-64 最严重的拦路虎。** 默认 Windows 11(`LongPathsEnabled = 0`)上:
```
InvalidArchiveError: [Errno 2] No such file or directory:
 'C:\Miniconda3\pkgs\isabelle-…\opt\Isabelle2025-2\contrib\vscodium-…\
  …\node_addon_api_except.lastbuildstate'          ← 262 字符 = MAX_PATH+2
conda create LASTEXITCODE=1  →  env 根本没建出来
```
- 载荷里**最长的 `$PREFIX` 相对路径 212 字符** —— 是 **vscodium 的 `node_modules` 里一个 MSBuild 垃圾文件(`.tlog`)**。
- **解压发生在 pkgs 缓存里,用户选个短 env 路径也躲不掉**:
  `C:\Users\bob\miniconda3\pkgs\isabelle-…\`(60)+ 212 = **272 > 260**。
- 删掉那一个文件不够:次长的是 195,对普通的
  `C:\Users\<name>\AppData\Local\miniconda3` 根目录**照样爆**。

**`LongPathsEnabled` 在 Windows 11 上默认是 `0`**([MS 文档](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)),
要**管理员改注册表 + 重启**,而且应用还得自己在 manifest 里 opt-in(Python 3.6+ 有)。

#### ❌ 用 conda 脚本提前设 `LongPathsEnabled` —— **不可能**(三个独立原因)
1. **时序上来不及**:conda 的顺序是 下载 → **解压到 pkgs 缓存** → link → post-link。
   **炸在"解压到 pkgs 缓存"**,发生在**任何脚本运行之前**。做前置依赖包也没用 ——
   conda 是先把**所有**包解压完再开始 link。
2. 要**管理员**权限(HKLM),conda 通常非提权运行。
3. 要**重启**才生效。

⇒ **唯一出路是把路径做短。** 这也正是 conda 生态的结论
([conda#7203](https://github.com/conda/conda/issues/7203),罪魁几乎总是 `node_modules`)。

#### ✅ 定案(用户 2026-07-13 批准):**保留 vscodium,只缩短我们能控制的路径**

**`isabelle vscode` 是主流,不能删**(用户明确否决了"剔除 vscodium")。
**也不要动 Isabelle 自己的树结构**(给 vscodium 组件改名的方案被否)。五条修改,全在
`pack.sh` / `conda/recipe.yaml` 里,对用户和 Isabelle **都不可见**:

| # | 改动 | 省 |
|---|---|---|
| 1 | **包内根 `opt/Isabelle2025-2/` → `isa/`**(只是我们把树放进 conda prefix 的哪个子目录) | 15 |
| 2 | **build string `isabelle-2025.2-68fdb1877e0c_0` → `isabelle-2025.2-0`**(changeset 挪进 metadata) | 12 |
| 3 | **剔掉 vscodium 的 `**/obj/**`**(MSBuild 的 `.tlog`/`.lastbuildstate`,运行时不读) | 那条 208 的 |
| 4 | 注入 `<ISABELLE_HOME>\bin\isabelle.bat` | — |
| 5 | 补回 83 个空目录 | — |

**结果:包内最长路径 180**(实测,`pack.sh` 里有全平台断言兜底)。

#### ✅✅ 真机复测通过(2026-07-14,`LongPathsEnabled = 0`,默认 Windows 11)

**先把 VM 的 `LongPathsEnabled` 关回 0 + 重启 + 确认**(测试前后各确认一次),否则是假通过。
env 建在 `C:\Users\isabelle\miniconda3\envs\isabelle\`(典型 "Just Me" 布局,**没有用短路径作弊**)。

| # | 检查 | 结果 |
|---|---|---|
| 1 | `conda create` 在**默认 Windows** 上 | ✅ **rc=0,85 秒**。落盘最长路径 **223 / 259,余量 36 字符** |
| 2 | activate 后 PowerShell `isabelle version` | ✅ `Isabelle2025-2`;`ISABELLE_HOME` 自定位到 env 内的 `…/isa` |
| 3 | **`isabelle vscode`** | ✅ **VSCodium 起来,Isabelle 扩展装好,`bad` 精确飘红、`good` 干净(⊗1 ⚠0)**。⇒ **剔掉 `obj/` 没有伤到 VSCode** |
| 4 | `isabelle jedit` | ✅ 截图:`Prover: ready`,坏 lemma 红点 + 红底 + 红波浪 |
| 5 | 预建 heap | ✅ 真 build 24 秒,**`Building HOL` 一次没出现** |
| 6 | `could not find /tmp` 警告 | ✅ **消失**(75 个空目录补回来的效果) |
| 7 | Cygwin 自愈 | ✅ marker 消失,**947/947** 符号链接全部恢复 |

**"75 不是 83" 的决定被实测证实:** `cygwin_init` 之后,`var/lib/rebase/*.d` 那 5 个目录
**由 `rebaseall` 自己建出来**,且**没有任何 `.conda-keep` 混进去**。当初若放了标记,
其内容就会被 `cat` 进 rebase 的 DLL 清单。

#### 🔴 剩余的三条(不是 blocker,但必须写进用户文档)

1. **env 路径前缀不能超过 79 字符**(余量 36,且卡死的那条是 VSCodium 自己的
   `textMateTokenizationWorker.workerMain.js`,我们控制不了)。env 名太长或建在很深的目录里
   仍会 `InvalidArchiveError`。**VSCodium 以后升级若把该路径加长一个字符,Windows 安装再次全崩** ——
   `pack.sh` 的断言会在 CI 里 30 秒内变红,而不是在用户的 `conda create` 里炸。
   (真要余量,还有 12 字符可拿:把 `contrib/vscodium-1.105.17075/` 改名成 `contrib/vscodium/`,
   `$COMPONENT` 是自引用的所以安全。**用户目前选择先不做。**)
2. **安装路径不能含非 ASCII 字符**(上游 JVM 启动器的限制,见上文)。
3. **🔴 Windows 上文件参数的路径约定是"分裂"的,而且两边都会静默出错**(独立复核时实测):

   | 命令 | 要什么路径 | 传错了会怎样 |
   |---|---|---|
   | **`isabelle vscode <file>`** | **原生 Windows**(`C:\...`) | 传 `/cygdrive/...` → **静默开出一个空的 Plain-Text 缓冲区** |
   | **`isabelle jedit <file>`** | **cygwin**(`/cygdrive/c/...`) | 传 `C:\...` → **静默开出一个空缓冲区**,路径被拼成 `%WINDIR%\System32\C;C:\...` |
   | **`isabelle build -d <dir>`** | **cygwin** | 传 `C:\...` → 硬报错 `*** Illegal character ":" in path element` |

   `vscode` 那条的根因是 `src/Tools/VSCode/src/vscode_main.scala:286`:`more_args` **原样**丢给
   vscodium,**上游不做路径转换**。**两条"静默开空文件"尤其危险** —— 用户会以为文件是空的。
   **这是 Isabelle 上游行为,不是我们包的缺陷**,但必须写进用户文档。

**首次调用慢是预期的**,但用户不知情会以为卡死,文档里要提一句:
首次任何 `isabelle` 调用约 90 秒(Cygwin 自愈);首次 `isabelle vscode` 约 3.5 分钟(装扩展)。

#### 🔴 conda 载荷**不含目录条目**,83 个空目录全丢了

conda 包里只有文件、没有目录条目 ⇒ 官方 bundle 里的 **83 个空目录**在安装后全部消失,
包括 `contrib/cygwin/{tmp, var/tmp, dev/shm, home}` 和 **`var/lib/rebase/*.d`(`rebaseall` 的状态目录)**。

后果:每次调 `isabelle` 都打印 `bash.exe: warning: could not find /tmp, please create!`(3–9 次)。
**不致命**(build 和 GUI 照样工作),但 `rebaseall` 的状态目录缺失不该带上线。
⇒ **recipe 的 build 脚本里要把空目录补回来**(`find -type d -empty` 重放)。

#### ✅ **Cygwin 会自愈 —— 不需要 post-link,问题不存在**(真机实测,推翻了之前的担忧)

之前认为"`build_release` 剥掉了 Cygwin 符号链接,得有东西在用户机上跑 `cygwin_init`,
而 conda 不跟踪 post-link 建的文件"是个**未决难题**。**实测证明它根本不是问题:**

| | 状态 |
|---|---|
| 第一次调 `isabelle` **之前** | `uninitialized` marker 在,**947 个符号链接全部缺失** |
| 跑 `isabelle version` | rc=0,**耗时 88.1 秒** |
| **之后** | marker **消失**,符号链接全部恢复成带 `System` 属性的 `!<symlink>…` |
| 第二次调用 | 20.8 秒 |

机理:`getsettings:118` 每次都跑 `isabelle.setup.Setup` → `Environment.init` → `cygwin_init`
→ 恢复符号链接 + `rebaseall` + `postinstall`。**第一次调用付约 90 秒,之后就好了。**

#### ✅ 递归安全 + 可重定位(真机实测)
- **递归**:本来是致命隐患 —— `getsettings:62` 把 `bin/` 放到 PATH **最前面**,而 `bin/isabelle`
  结尾是 `exec isabelle java …`(在 bash 里**再查一次 PATH**)。若 Cygwin 会补 `.bat`,
  每个内部工具都将无限递归。**但 Cygwin 只补 `.exe`,不补 `.bat`**
  ([Cygwin User's Guide](https://cygwin.com/cygwin-ug-net/using-specialnames.html):
  *"for programs that end in `.bat` and `.com`, you cannot omit the extension"*)。
  实测 `type -a isabelle` 只有一条,`isabelle version` rc=0。
- **可重定位**:整树 robocopy 到 `C:\other\`(29742 files / 2.342 GiB / 0 FAILED),
  四条验收全过,PATH 里 `C:\isa` 完全不出现。**这是 conda 包能成立的前提,已满足。**

### 3.7 CI runner(已确认)

| 目标平台 | 免费官方 runner | label |
|---|:--:|---|
| x86_64-linux | ✅ | `ubuntu-latest` |
| **arm64-linux** | ✅(2025-08 GA,public repo 免费) | `ubuntu-24.04-arm` |
| x86_64-windows | ✅ | `windows-latest` |
| macOS(universal,含两个 darwin 架构) | ✅ | `macos-14`/`macos-15`(Apple Silicon) |

⇒ **全部有免费官方 runner,不需要自建。**
⚠️ **GitHub 标准 runner 没有 KVM/嵌套虚拟化 ⇒ QEMU 进不了 CI**(本地 VM 只能是本地验证工具)。

---

## 4. 发布流水线(端到端蓝图)

```
① 取源      hg clone https://isabelle.in.tum.de/repos/isabelle   （--stream,实测 226MB / 108s）
            hg update -r Isabelle2025-2                          （= 89701cf1768e）

② 打补丁    my_better_isabelle_prover 的版本键控 diff(patches/Isabelle2025-2/…)
            patch -p1 -F0                                        （实测 13 个补丁干净应用）
            ⚠️ 裸 checkout 的 `isabelle version` 不是 "Isabelle2025-2"(ISABELLE_IDENTIFIER 未写)
               ⇒ 版本键要显式给,不能靠自动探测

③ 提交      hg commit -m "our patches"      → REV'
            ⚠️ 关键!build_release 从已提交 rev 做 archive,不 commit 就丢补丁

④ bootstrap Admin/init  （= components -I + components -a + scala_build)

⑤ 构建      Admin/build_release -r REV' -R Isabelle2025-2 -b HOL,Main -p <平台>
              阶段一 → scala_build 把 .scala 补丁编进 isabelle.jar
                     → build_doc(需完整 TeX)
                     → 通用源码 archive  Isabelle2025-2.tar.gz
              阶段二 → 下载 native 组件 + build_heaps(从打补丁的 .ML 建 HOL heap)+ 组包

⑥ 产物      Isabelle2025-2_linux.tar.gz / _linux_arm.tar.gz / _macos.tar.gz / .exe
            + Isabelle2025-2.tar.gz(通用源码 archive,供其它平台 -S 复用)

⑦ 打包      → conda 包(version 2025.2)→ 自建 channel
```

### ✅✅ 五平台验证状态(2026-07-15,全部"装上并真实运行"过)

| 平台 | 装上+CLI+heap真加载 | GUI(jEdit 真检查证明) | 怎么验的 |
|---|---|---|---|
| linux-64 | ✅ | ✅ | Job F(CI) |
| linux-aarch64 | ✅ | ✅ | Job H(CI) |
| win-64 | ✅ | ✅ jEdit + **VSCode** | 真 Windows VM,亲手复核(排除旧树污染) |
| osx-64(经 Rosetta) | ✅ **且断言真跑 x86** | 🔶 待接入 | macos-install-probe(CI);2b 断言 `ISABELLE_PLATFORM64=x86_64-darwin` |
| osx-arm64 | ✅ | 🔶 待接入 | macos-install-probe(CI) |

- **"装上并运行"= 真 `conda create` → `isabelle version` → 真 build 一个 `Main` 之上的 session、断言 `Building HOL` 不出现。**
  五平台**全部**过了 —— 不是"能打包",是"能跑"。
- macOS 的 GUI:runner 有窗口服务器已实测确认(见 §5.2),真 jEdit 截图检查**待接入**。
- ⚠️ 一次完整的 **A→H→publish→smoke 单轮全绿** 尚未发生过(各平台是分轮/旁路验的);发布那轮会是第一次端到端。

---

### ✅ 已实证(Linux,本机端到端跑通 —— 最早的单平台原型)

`hg clone` → 13 补丁 → `hg commit`(`5acc266a8fba`,parent = `89701cf1768e`)→
`Admin/build_release -b HOL -p linux` → **`BUILD_RELEASE_EXIT=0`**。

产出 **`Isabelle2025-2_linux.tar.gz`(895 MB)**,解包验证:

| 检查 | 结果 |
|---|---|
| `bin/isabelle version` | `Isabelle2025-2` ✓ |
| `etc/ISABELLE_ID` | `5acc266a8fba`(我们的补丁 commit)✓ |
| 补丁版 HOL heap | `heaps/polyml-5.9.2_x86_64_32-linux/HOL`(208MB)✓ |
| 补丁在成品**源码**树 | register_thy / show_types_nv / lsp.scala ✓ |
| 补丁编进 **`lib/classes/isabelle.jar`** | `theory_status`/`command_at_position`/`output_at_position`/`cancel_execution` 都在编译产物中 ✓ |

**⇒ 「Scala 补丁经 scala_build 进 jar、ML 补丁经 build_heaps 进 HOL heap」这条链路被完整证实。**

---

## 5. CI 矩阵(**已按实测重新设计**)

### 5.0 四条铁律(全部实测,它们唯一地决定了矩阵长相)

**① 打包只能在 Linux/macOS 上做 —— 包括 Windows 的 `.exe`。**
`Admin/build_release -p windows` **在 Windows 上跑不起来**,实机硬失败:
```
*** java.lang.IllegalArgumentException: requirement failed: Linux or macOS platform required
```
根因 `src/Pure/Admin/component_windows_app.scala:13-16`:
```scala
def tool_platform(): String = {
  require(Platform.is_unix, "Linux or macOS platform required")
```
`launch4j_jar()` 与 `seven_zip()` 都走它,而 Windows 分支两个都要用。
**铁证**:`windows_app` 组件解包后只有 `arm64-linux` / `x86_64-darwin` / `x86_64-linux`,
**没有 `x86_64-windows`** —— **造 `.exe` 的工具链根本没有 Windows 版**。
⇒ **`.exe` 是从 Linux 交叉打出来的。根本不存在"Windows 打包 job"。**
官方 `Admin/Release/CHECKLIST:82` 印证:*"on fast Linux machine, with access to build_host for each platform"*。

**② heap 只能在本平台原生构建**(§3.5,跨架构不可能)。

**③ GitHub runner 之间无法互相 SSH** ⇒ 官方的 `build_host_<platform>` 机制**在 GitHub 上用不了**。

**④ 🔴🔴 heap artifact 必须连 `heaps/*/log/<S>.db` 一起传 —— 少了它,heap 就是 350MB 死重。**
`log/` 这个名字**骗人**:`log/<S>.db` **不是日志,是 session 数据库**。`isabelle build` 判断
"某 session 已建好且最新",**查的是这个 db,不是 heap 文件在不在**。官方 bundle 里就带着它们。
CI 曾在上传前 `rm -rf heaps/*/log`,后果是包能装、`isabelle version` 能跑、
**连 `isabelle build -n` 都报告"无需构建"(假阳性)**,但真 build 立刻重编 HOL 20 分钟。
⇒ **验收绝不能用 `isabelle build -n`;必须真跑一个建在 `Main` 之上的 session,
看到 `Building HOL` 就判失败。**(详见 §3.5)

⇒ **打包与建 heap 必须解耦。**

### 5.1 矩阵

```
Job A  [ubuntu-latest]        取源 → 打补丁 → hg commit
                              Admin/build_release -r REV' -p linux,linux_arm,windows,macos
                                                  （不带 -b！）
                              → 通用源码 archive + 4 个平台 bundle（都不含 heap，含 Windows .exe）
                              ⚠️ 只有这个 job 需要 hg、TeX、Admin/

Job B [ubuntu-latest]     ┐
Job C [ubuntu-24.04-arm]  │   各自在原生 runner 上：
Job D [macos-14]          ├─  isabelle build -o system_heaps -b HOL,Main
Job E [windows-latest]    ┘   （macOS 跑两遍 ML_system_apple=false/true → 双架构）
                              → 上传 heaps/<ML_IDENTIFIER>/ 作为 artifact

Job F  [ubuntu-latest]        下载 4 个 bundle + 全部 heap
                              → 把 heap 注入各 bundle（tar 类直接塞；Windows 用 7zz 重造 SFX .exe）
                              → rattler-build 打 conda 包（per-platform）
                              → conda index --no-zst --no-bz2      ← 必需！见 §3.3 的 CDN 坑
                              → rclone sync → R2（conda.qiyuan.me）
```

- **`Admin/` 必须存在于跑 build_release 的那棵树里**(4 条独立实测理由):入口脚本本身在 `Admin/`;
  `isabelle build_release` **不是注册工具**(`*** Unknown Isabelle tool`);archive 里 `Admin/` **已被 purge**
  (条目数 = 0);Windows 打包读 `~~/Admin/Windows/{launch4j,Cygwin}`(`~~` = **构建机**的 ISABELLE_HOME);
  `build_host_*` 选项声明在 `Admin/etc/options`(没有它 `-b` 直接 "Unknown option")。
- `-S` **本身不需要 hg**(实测:guest 里根本没装 hg,`-S` 全程没碰 `Mercurial.self_repository()`)。
- 加速:`hg clone` 可缓存;`~/.isabelle/contrib`(native 组件)可缓存。
- ⚠️ **唯一还没验证的一环:Windows runner 上原生建 heap**(VM 里卡在 `build_heaps` 的 tar 步,但那是 QEMU 太慢;
  真 runner 上大概率可行,**未测**)。

### 5.1.1 🔴 三条源码级纠正(CI 实作时发现,**推翻了本文早前的写法**)

**① Job B–E 必须消费「平台 bundle」,不能用「通用源码 archive」**
早前写的"取通用 archive → `isabelle components -a`"**行不通**:
- `build_release` **把 `Admin/` 从 archive 里 purge 掉了**(`build_release.scala:540`)⇒ `components -I` 要写进 user settings 的
  `Admin/components/main` 目录**不存在** ⇒ `getfunctions:293` 报 **"Bad component catalog file" → exit 2**。
- archive 的 `etc/components` 里,bundled 组件只以**注释行**存在(`#bundled:polyml-…`,`record_bundled_components` 写的),
  而 `getfunctions:302` **跳过所有 `#` 行** ⇒ `ISABELLE_COMPONENTS_MISSING` 为空 ⇒
  **`isabelle components -a` 是个静默 no-op**(把注释变成真 `contrib/…` 条目的是 `activate_components`,
  它**只在 per-platform bundle 阶段**运行)。
- **⇒ 通用 archive 里没有 Poly/ML、没有 JDK,`isabelle build` 根本起不来。**

**正解**:各 heap job **解开自己平台的 bundle**(里面的 `contrib/` 已经是激活好的),直接 `isabelle build`。
⇒ **Job A 应为每个 bundle 上传独立 artifact**,让每个 heap job 只下载自己那份。

**② Windows:设 `TEMP`/`TMP`/`TMPDIR` **无效** —— 必须设 `LOCALAPPDATA`**
Cygwin 下 `lib/scripts/getsettings:30` **无条件覆盖**它们:
```bash
TMPDIR="$(cygpath -u "$LOCALAPPDATA")/Temp"     # ← 你设的 TMPDIR 被直接冲掉
```
而 `ISABELLE_TMP_PREFIX` 由此派生。**唯一能把 scratch 挪离 33GB C: 盘的杠杆是 `LOCALAPPDATA`**
(同理 `HOME`/`USER_HOME`,否则由 `$USERPROFILE` 派生)。
⇒ Job E 设这些,并在开跑前**断言 `ISABELLE_TMP_PREFIX` 确实落在 `D:`**。

**③ `ML_IDENTIFIER` 不是 settings 变量**
2025-2 里 `isabelle getenv ML_IDENTIFIER` **输出为空**(它在 Scala 侧计算)。
⇒ 要拿 heap 目录名,只能 `ls heaps/` 读。

**④ Windows 的 Cygwin bootstrap(Job E)**
7z 解开 SFX 后,用 `isabelle_setup.jar` 的 main class 触发 `Environment.cygwin_init()`
(其自身注释就是 *"init (e.g. after extraction via 7zip)"*)—— 恢复被剥掉的 symlink + 跑 `rebaseall`/`postinstall`,
之后一律经 `<cygwin>\bin\bash.exe` 构建(和 Isabelle 自己的做法一致)。

### 5.2 macOS(CI 实测,`macos-14`)

- **一台 `macos-14` 就够,零前置条件。Rosetta 2 已预装、开箱可用**(`arch -x86_64` 直接过,`oahd` 在跑)。
- **组件确实带双架构**:`polyml` 下有 4 个平台目录(`arm64-darwin`/`arm64_32-darwin`/`x86_64-darwin`/`x86_64_32-darwin`),
  四个 `poly` 在 arm 机上**全部实跑成功**。(z3 / vampire / spass 等只有 x86_64 → **靠 Rosetta**。)
- **🎯 单机双架构 heap 实测成功**:`ML_system_apple=false/true` 各跑一遍 → 两个不同 ML_IDENTIFIER、sha256 不同。
  **HOL ×2 = 1h44m**(x86 经 Rosetta 55m + arm 原生 50m;**Rosetta 惩罚只有 ~10%**)。远低于 6h 上限。
- ⚠️ ML_IDENTIFIER 是 **`_32` 变体**(`x86_64_32-darwin` / `arm64_32-darwin`),因为默认 `ML_system_64=false`;
  `ML_system_apple` 只切 apple/非 apple,**不切 32/64**。
- `macos-13` **事实上已死**(排队 1h50 无人认领)——但**不需要它**。
- 官方 macOS 包**本来就自带两套 heap** ⇒ 只重打包官方包的话不用重建;**但我们打了补丁,必须重建**。
- 实操坑:下载 dist **必须带 `?token=Isabelle`**(否则 403);**`isabelle getenv -o` 不存在**
  (照 build_release 的做法写 `$ISABELLE_HOME_USER/etc/preferences`);**`isabelle process` 在发行包里不存在**。

#### ✅ **macOS 的 GUI 在 CI 里测得了**(2026-07-15 探针实测,推翻了先前"测不了"的判断)

> 先前这里写"macOS runner 无头、GUI 测不了",依据是官方文档和 [#8951](https://github.com/actions/runner-images/issues/8951)。
> **那个判断对 `macos-14` 是错的。** Job G 的探针(`launchctl print gui/$(id -u)` + `screencapture -x`)
> 实测结果:
> ```
> RESULT: screencapture SUCCEEDED -> PNG image data, 1920 x 1080, 8-bit/color RGBA
> macOS runner HAS a usable window server
> ```
> **`macos-14` runner 有可用的窗口服务器,截图成功。** 所以像 Linux/Windows 一样做真 jEdit 截图检查是**可行的**。

**教训:先探测、后断言。** 那个探针被特意做成"永不让 job 变红、只打印实测结果",正是为了把
"未知"变成"已测量"——而它测出来的答案,和网上资料 + 我先前的推断**相反**。
若当初直接照文档写死"macOS GUI 不可测",就会永久漏掉一个本可覆盖的平台。

**已验证的**:macOS 的 CLI、两套 heap、真 build(断言 HOL 不重建)、osx-64 经 Rosetta 真跑 x86(§见 verify_install 的 2b 断言)。
**GUI**:runner 有窗口服务器已确认;真 jEdit 截图检查**待接入**(Linux 的 `verify_gui.sh` 驱动 Xvfb,
macOS 有真窗口服务器、不需要 Xvfb,启动路径要另写:jEdit 走 Quartz)。

### 5.4 CI vs 发布:架构定案(**方案 A**)

**原则:发布近乎不可逆**(包一旦上了 channel,用户可能已拉走;不能删、不能覆盖)
⇒ **发布绝不能是 push 的副作用,必须是一次深思熟虑的动作。**
但"深思熟虑"可以是"打一个 tag" —— 它依然跑在 Actions 里,只是**不由 push 触发**。

```
.github/workflows/
  build.yml    ← reusable（on: workflow_call）：定义 Job A–F。只定义一次。
  ci.yml       ← on: push / pull_request   → 调 build.yml → 本地验证 → 结束。**绝不碰 channel**
  release.yml  ← on: tag / workflow_dispatch → 调 build.yml → 本地验证
                 → 上传 R2 → 发布后校验 → GitHub Release
```

**为什么选"发布时重建"(方案 A)而不是"提升 CI 产物"(方案 B)**:
- 发布流程**自包含、无状态**,不依赖"某次 CI run 还在不在";
- 发出去的**一定是刚刚在同一个 run 里验证过的**字节;
- 重建 ~2 小时(主要是 macOS 的 HOL×2),对**一年几次**的发布节奏完全可接受;
- 这也是 PyPI/cargo 生态的**主流写法**。
- **什么时候改用 B**:发布变频繁,或重建的不确定性开始咬人。现在不必。

#### 验证拆成两半(**都不受 CDN 延迟影响**)
| 验什么 | 怎么验 | 在哪 |
|---|---|---|
| **包对不对**(recipe、依赖能解、装得上、`isabelle version` 能跑、heap 能加载) | **从本地 channel 目录装**:`conda create -c file:///.../channel` | **CI**(确定性,不碰网络) |
| **字节传对没有** | 直接 HTTP GET 那个 `.conda`,比对 sha256(**`.conda` 不进 CDN 缓存,永远新鲜**) | **发布流程** |
| channel 索引新不新 | 不用管,CDN 自己会追上(§3.3) | — |

#### 发布凭据
- **已把 `CONDA_R2_ACCESS_KEY_ID` / `CONDA_R2_SECRET_ACCESS_KEY` / `CONDA_R2_TOKEN_VALUE`
  设为 `isabelle-packaging-ci` 的 GitHub secrets**,`release.yml` 在 `ubuntu-latest` 上用它们 `rclone sync` 到 R2。
- 安全面:公开仓库 ⇒ **fork 的 PR 拿不到 secrets**(GitHub 强制);只有有写权限的人能打 tag/dispatch;
  该 R2 token **只能写 `conda` 这一个 bucket**。
- ⚠️ 不足:**Cloudflare R2 没有 GitHub OIDC 联邦**(AWS 有)⇒ 只能用**长期密钥**。缓解:最小权限 + 需要时轮换。

#### GitHub artifacts(实测/查证)
- **公开仓库的 Actions 与 artifact 免费**(官方:*"GitHub Actions usage is free for public repositories
  that use standard GitHub-hosted runners"*)⇒ GB 级产物不占付费配额。
- 默认**保留 90 天**(公开仓库可设 1–90 天)。

### 5.3 Runner 磁盘(CI 实测,2026-07)——**风险已解除**

我们的峰值需求:**`ISABELLE_TMP` 约 22 GB + 构建树约 8 GB ≈ 30 GB 同时占用**。

| Runner | 开箱可用 | 30 GB 峰值实测 | 处置 |
|---|---|---|---|
| `ubuntu-latest` | **89 GB**(145G 根盘) | ✅ 成功,还剩 59 GB | **什么都不用做** |
| `ubuntu-24.04-arm` | **110 GB** | ✅ 成功,还剩 80 GB | 不用腾;但**盘速慢 2.5 倍**(170 vs 430 MB/s) |
| `windows-latest` | C: 33.5 GB / **D: 147 GB** | RUNNER_TEMP 已在 D: | ⚠️ 见下方 🔴 —— **设 `TEMP`/`TMP`/`TMPDIR` 是无效的,必须设 `LOCALAPPDATA`** |
| `macos-14` | **仅 40 GB**(Xcode 占了 263 GB) | 只剩 10 GB,太险 | ⚠️ **必须删多余 Xcode**(实测 90 秒腾出 42 GB → 82 GB) |

**两个被实测推翻的流传说法:**
1. **"runner 只有 14 GB"** —— 那是 GitHub **保证的下限**,不是实际;现在根盘是 **145 GB**。
2. **"`/mnt` 是块 74 GB 独立临时盘"** —— **已过时**。`/mnt` 现在只是根分区上的一个空目录,`/dev/sdb1` 不存在。

**顺带解决了本机那个坑**:**runner 上 `/tmp` 就在 145 GB 的 ext4 根盘上,不是 tmpfs**
⇒ Linux 上 `ISABELLE_TMP_PREFIX` 硬编码到 `/tmp/isabelle-$USER` **在 CI 上不是问题,不用覆盖**。

**防御性措施**:GitHub 只承诺 14 GB ⇒ 开跑前加 `df` 断言,低于阈值才跑 cleanup
(手工 `rm -rf` 预装工具链实测 **25 秒腾 33 GB**,比 `jlumbroso/free-disk-space` 的 3–5 分钟快得多)。

**Larger runner 用不了也没必要**:个人账号不能用 + 公开仓库要收费,且规格 150 GB ≈ 标准 runner 的 145 GB。

⚠️ **`macos-14` 只有 3 核 / 7 GB 内存** —— 它还要跑 HOL heap 构建 ×2(双架构),**又慢又可能内存吃紧**。

---

## 6. conda 包结构(设计,未实现)

```
<元包>                          noarch,depends 下面全部（名字待定，不带 aoa 前缀）
├── isabelle                    per-platform,version 2025.2  ← 我们的补丁版 Isabelle(含预建 HOL heap)
├── <组件包>                     noarch generic  ← 六个仓库的 .thy/.ML/jar + 组件配置(名字待定)
├── isamini                     noarch python
├── isabelle-rpc               noarch python
├── isarepl                     noarch python
└── isabelle-semantic-embedding per-platform（唯一带原生 wheel 的）
```

- **channel**:`https://conda.qiyuan.me`(R2 bucket `conda`,见 §3.3)。
- **`isabelle` 包 = 方案 A(文件全打进包)**,不是 post-link 下载(见 §3.1)。
- version **`2025.2`**;上游 changeset + 补丁标识进 build string;改内容 bump build number。
- **预建的 heap**:`Pure` + `HOL` + **`Main`**(`-b HOL,Main`)。`Main` 只有 3.8 MB(heap 是层级 delta,见 §3.5)。
  **AoA 自己的 session heap(`Minilang_Agent` 链)暂不预建**——用户首次使用时自建(已确认可接受)。
  将来若要预建,**体积不是障碍**(同样是 delta),代价只是 CI 时长。
- 重原生依赖(torch/faiss/CUDA)从 conda-forge 拉,不是我们产出。
- ⚠️ **faiss 的 blas 变体坑**:conda solver 会随机装出缺 mkl 的 faiss build → import 崩。
  必须 pin `libblas=*=*openblas`(或装全 mkl)。(注:PyPI 的 `faiss-cpu` wheel 自带 openblas,没这个坑。)

### 6.1 备选发行形态:tarball(conda-pack / uv + venv-pack)

「vendor 一切 → 每平台一个 tar → 解压即用、免激活」也完全可行,而且**天然满足"不装 conda 也能用"**:
- Python 侧:**`uv`**(可带 standalone 可重定位 CPython)+ `venv-pack`;或 conda + `conda-pack`。
- 代价:**每平台一个 tar**(Python 原生扩展与 heap 都是平台相关的,躲不掉)。
- 与 conda 包**不冲突**:同一套构建产物可以既发 channel、又挂 release tar。

---

## 7. 已知坑与对策

| 坑 | 对策 | 状态 |
|---|---|---|
| **补丁不 commit 就被 `hg.archive` 丢掉** | 必须 `hg commit` 后用 `-r REV'` | 已固化进流程 |
| **`build_doc` 需要完整 TeX Live** | 只在 archive job 装(`texlive-science` 含 stmaryrd、`texlive-latex-extra`、`latexmk` …) | 已解决 |
| **`/tmp` 是 tmpfs、装不下 `ISABELLE_TMP`** | `build_heaps` 会把整个 bundle+contrib tar 到 `ISABELLE_TMP`,**峰值实测 22GB**。Linux 上 `ISABELLE_TMP_PREFIX` 硬编码为 `/tmp/isabelle-$USER`(`TMPDIR` 只对 Windows 生效)⇒ **在 user settings 里覆盖 `ISABELLE_TMP_PREFIX` 指向大盘** | 已解决 |
| **user-settings 冲突** | release 名会让 `other_isabelle` 的 `ISABELLE_HOME_USER` 撞上构建机上已装 Isabelle 的真配置 ⇒ 用**隔离 HOME**。干净的 CI runner 没这问题 | 已解决 |
| **组件版本漂移** | 必须用**该 rev 自带的 `Admin/components/main`**,别用镜像 tip | 已知 |
| **Windows `.bat` 控制台挂起** | `start ""` detach,或 GUI 走官方 launch4j exe | **待修** |
| **Windows 一次性 `-init`** | conda/tar 安装绕过 SFX AutoInstall ⇒ 必须显式做;最省心是在构建机 `-init` 后再打包 | 已知 |
| **Session 0:窗口标题断言不可用** | CI 的 GUI 测试**必须靠截图**;确定性断言只能查进程存活 | ✅ **已实现**(见 §7.10) |
| **Ubuntu 上没有 `7zz`** | `7zz` 是 7-Zip **上游**发行版的可执行名。Debian/Ubuntu 的 `7zip` 包(23.01+dfsg)装的是 **p7zip 风格的 `7z`**(`dpkg -L 7zip` → `/usr/bin/{7z,7za,7zr,p7zip}`,**无 `7zz`**)。⇒ 解 Windows SFX `.exe` 时**不要写死名字**:`SEVENZIP=$(command -v 7zz \|\| command -v 7z)` | 已解决 |
| **rattler-build 默认跑跨平台的 recipe 测试** | 默认 `--test native-and-emulated`。在 Linux 上打 **win-64** 时它会执行 `isabelle.bat version` → **127** → 把一个**完好的包隔离进 `broken/`**。⇒ **必须 `--test native`** | 已解决 |

### 🔴🔴 `cmd && echo ok` 在 `set -e` 下是个**永远不会失败的假守卫**

`build.yml` 里这句本意是"验证 7zz 可用":
```bash
7zz i > /dev/null && echo "7zz: $(7zz | head -2 | tail -1)"
```
**它做不到。** bash 的 `set -e` **豁免 `&&`/`||` 列表中除最后一个之外的所有命令**。
所以 `7zz` 不存在时,这一整行只是静默返回非零,**步骤照样绿**。

实际后果(run `29208082084`):`command not found` **在安装步骤里就打印出来了**,被咽掉;
真正的爆炸推迟到 **25 分钟后**的 `pack.sh` 才发生,而且此时前 4 个包已经打完(白干)。

**规则:守卫必须写成能让步骤失败的形式。**
```bash
command -v 7zz >/dev/null || command -v 7z >/dev/null || { echo "::error::no 7z binary"; exit 1; }
```
写 CI 检查时**先自问:这个检查在被检查项缺失时,真的会让步骤变红吗?** 不会的话它就是装饰。

**同一个病的另一种形态:跨平台的 recipe 测试要么致命,要么是假的。**
rattler-build 在 Linux 上打 **osx-64 / osx-arm64** 包时,测试走 unix 分支、**在 Linux 上**跑
macOS 包里的 bash 脚本。而 `isabelle version` 只是回显一个 settings 变量 ——
**根本不碰任何 Darwin 二进制就"通过"了**。CI 日志里那两个绿勾**什么都没证明**。
⇒ 用 `--test native`。真正的验收靠 Job F 自己那套(装进 conda env + 真 build 一个 session +
GUI 截图判定),那比 recipe 内测试强得多。

## 7.10 ✅ GUI 验证:Xvfb + jEdit + Claude Code 判截图(已实现并本机验证)

`scripts/verify_gui.sh`(CI repo)。**GUI 是唯一无头断言够不到的地方** ——
`isabelle version` 和 `isabelle build` 在"jEdit 一启动就死"的包上**照样全过**。

**判据不是"窗口出现了"(空窗口也满足)。** theory 里放**一个必过的 lemma + 一个必错的**
(`2+2=5`),要求错误标记**恰好落在该错的那一行**。这才把"界面渲染了"升级成
"prover 真的在通过 GUI 检查证明"。做过 negative control(空屏 → 模型答 `started: no`)。

- **鉴权只用 `CLAUDE_CODE_OAUTH_TOKEN`**(`claude setup-token`,走**订阅额度**)。
  🔴 **绝不要设 `ANTHROPIC_API_KEY`** —— 它在 Claude Code 的鉴权链里**优先级更高**,
  设了会静默把订阅换成按量计费。
- **限流不等于包坏了。** 订阅额度与用户交互式使用**共享同一个池子**(实测被打满过)。
  ⇒ **只有"模型给出了判断且判断是坏的"才能让 CI 变红;"模型没能给出判断"
  (限流/掉登录/API 故障)只 `::warning::`。** 真的 GUI 坏了永远以
  `structured_output.started = "no"` 的形式回来,所以判别力没有损失。
- **必须从包里的 heap 目录名反推 `ML_system_64` 并写进临时 HOME 的 preferences。**
  变体不匹配时 Isabelle **不报警,直接静默重建 HOL**,而 jEdit 是在 **GUI 对话框**里建的、
  输出**不进 `jedit.log`** ⇒ 截图检查会**全绿假通过**而包里的 heap 根本没被用。
  脚本另外断言 `Isabelle build` 对话框不许出现。
- 无头 build 的 `Building HOL` 检查与 GUI 截图检查**互补,不可互相替代**:
  前者确定性、不需要模型在环;后者覆盖 jEdit 那条路径。**两个都要留。**

---

## 7.9 ✅ 已定案:**只打 `user` 类补丁**(用户 2026-07-12 确认)

**定案**:发布的 Isabelle **只打 `my-better-isabelle-prover` 的 `user` category**。

- **`by aoa` 不需要 `register_thy`**(用户确认——早前"AoA 需要 register_thy"的推断是错的)。
- **`Isa-REPL` 的 conda 包会在自己的安装脚本里自动打 `register_thy` 补丁**(它的特殊处理,不是 isabelle 包的事)。
  ⚠️ 注意:那会改动 Pure 的 ML 源 ⇒ **heap 会失效并按需重建**(Isabelle 会自动处理,但用户首次要等 HOL 重建)。

### 🔴 CI 必须从 **git 源**安装补丁工具,不能用 PyPI

```
git log:  593f64b  expose_foreign     ← 在 0.2.0 之后加的
          666327c  Release 0.2.0      ← PyPI 上只有这个
本地:     0.3.0（有 categories.toml + --category）
```
⇒ **PyPI 的 0.2.0 既没有 `--category`,也没有 `expose_foreign`(user 三件套之一)。**
⇒ CI 里改成 **`pip install git+https://github.com/xqyww123/my_better_isabelle_prover`**
(拿到 0.3.0:categories + expose_foreign)。等 0.3.0 发到 PyPI 后可以换回。

### 🔴🔴 未决冲突:**别人正在把 `pide_control` + `perspective_eof_clamp` 从 2025-2 撤掉**

`my_better_isabelle_prover` 的本地工作区有**已 staged 但未提交的删除**——另一个 agent 在退役这两个 feature。
其提交 `37c2848` 明确写:在 Isabelle2025-2 上,默认 `patch` **"applies exactly one pure-ML patch, `expose_foreign`"**。

| 时点 | `user` 集合(2025-2) |
|---|---|
| **现在**(git remote HEAD) | `pide_control`(5 文件)+ `perspective_eof_clamp`(1)+ `expose_foreign`(1) = **7 个 patch** |
| **那个 agent 一旦推送退役** | **只剩 `expose_foreign`**(1 个纯 ML 补丁) |

**后果**:CI 的断言(检查 `theory_status`/`cancel_execution` 是否进了源码与 jar)**会突然失败、build 变红**
—— 这是**响亮的失败,不是静默出错**(好事),但**必须先决定哪个才是本意**:

- **(a)** 发布包带 `pide_control` + `perspective_eof_clamp` + `expose_foreign`
  ⇒ 需让那个 agent **别推退役**,或 CI **钉死一个 commit**。
- **(b)** 发布包**只带 `expose_foreign`**
  ⇒ **Isabelle-MCP 的 PIDE 扩展不再进发布包**;CI 的断言要相应改掉。

**⇒ 待用户拍板。**

### 类别表(`patches/categories.toml`)

| category | features | 用途(工具作者的原话) |
|---|---|---|
| **user** | `pide_control`、`perspective_eof_clamp`、`expose_foreign` | *"needed by the user-facing systems (Isabelle-MCP; Semantic_Embedding's SIMD FFI)"* |
| **dev** | `register_thy`、`show_types_nv`、`expose_map_syn` | *"needed only by developer/experiment infrastructure (Isa-REPL, Isa-Mini's translator, AoA agent injector)"* |

CLI:`--category {user,dev,all}`,**默认就是 `user`**(0.3.0 起)。

### 两个必须先解决的问题

**① PyPI 上只有 0.2.0,没有 category 功能**
CI 里 `pip install my-better-isabelle-prover` → 装到 **0.2.0** → **会把 6 个补丁全打上**。
⇒ 要只打 user,**必须先把 0.3.0 发到 PyPI**(该仓库由**别人**维护),**或** CI 改成从 git 源安装。

**② 只打 user ⇒ 发布的 Isabelle 不支持 `by aoa`**
`register_thy` 是 **dev** 类,而它是 **Isa-REPL 的硬依赖**;Isa-REPL 又在 AoA 链条里
(`Minilang_Agent = Minilang + Isa_REPL + …`)。
⇒ **只打 user 的包,面向的是 Isabelle-MCP + Semantic_Embedding 用户,而不是 AoA。**
AoA 用户需自己 `patch --category all`。

**⇒ 待用户确认:这是否是本意?** 若是,发布定位要相应调整(本文 §1「目标」写的是"让用户能 `by aoa`",与之矛盾)。

---

## 7.11 🔴 补丁工具**必须 pin**,以及**更新补丁集的完整流程**

**曾经的写法(错的)**:`pip install "git+https://github.com/xqyww123/my_better_isabelle_prover"`
—— **无 pin,取的是 HEAD**。后果:那个 repo 有人一推,**我们发布的 Isabelle 就悄悄变了**,
而包**还叫同一个名字**(见下)。构建不可复现。

**现在**:`build.yml` 里 `MBI_VERSION="0.3.0"`,装 **PyPI 的固定版本** —— PyPI 的版本**不可变**,
这正是发布需要的。(注意 `MLML` 里那个 submodule pin **CI 不看**;它是给本地开发用的。)

### 🔴 为什么"改补丁集"必须**同时** bump `build_number`

为了 MAX_PATH,conda 的 build string 从 `<hg-changeset>_<n>` 缩成了**纯 build number**
(`recipe.yaml:30-43`,省 12 字符)。⇒ **补丁集变了,包名仍然是 `isabelle-2025.2-0`。**
conda **看不出这是个新包**。

**兜底**:`release.yml` **拒绝覆盖已发布的文件名** ⇒ 忘了 bump 的话,**发布会大声失败**,
而不是静默给用户发旧字节。**这是设计,不是巧合。**

### 更新补丁集的完整流程 → **见 `RELEASE.md`**

一句话版:改补丁 → **发 PyPI 新版** → bump `MBI_VERSION` → bump `ISA_BUILD_NUMBER` → 触发 `release.yml`。

**唯一真正会咬人的失误:补丁只在本地改了,没发到 PyPI。**
CI 装的是 PyPI 的固定版本,**不看** MLML 的 submodule ⇒ 你本地好用的补丁,
**用户根本拿不到**,而 CI 全绿、包也照常发出去。经典的 "works on my machine"。
`RELEASE.md` 的第一条就是挡这个的。
(反过来"本地落后于已发布版本"**不是问题** —— 你是改动的源头。)

## 8. 待办清单

| # | 事项 | 状态 |
|---|---|---|
| A | 修 `isabelle.bat` 控制台挂起(detach) | ✅ **完成**(§3.6,`run.exe` + getopts 复刻,27/27 验收) |
| B | 测 Windows 的 `-S` build | ✅ **完成 —— 结论是"根本没有 Windows 打包 job"**(§5.0) |
| G | macOS 双架构验证 | ✅ **完成**(§5.2,单机 `macos-14`,HOL×2 = 1h44m) |
| — | GitHub runner 磁盘 | ✅ **完成**(§5.3,风险解除) |
| — | conda channel on R2 | ✅ **端到端打通**(§3.3,含 CDN 严重坑与解法) |
| **C** | **搭 CI**(§5.1 的 Job A–F + §5.4 的三件套) | 🔄 **Job A ✅ 已跑绿;Job B–F 待做** |
| C-A | **Job A(全平台 bundle,无 heap)—— ✅ 真 CI 上跑通并验证** | run [`29201707387`](https://github.com/xqyww123/isabelle-packaging-ci/actions/runs/29201707387) success **33m20s**,产物 **5.8 GB**;步骤 (8) 已验 `ISABELLE_ID` + **补丁进了 `isabelle.jar`** + **Windows `.exe` 从 Linux 交叉打出**;`hg clone` 已缓存(后续 run 跳过) |
| C1 | ⚠️ 唯一未验证:**Windows runner 上原生建 heap** | 待验(可在 Job E 里直接试) |
| **J** | 🔴 **`isabelle.bat` 改成自定位 + 挪进 `<ISABELLE_HOME>\bin\`**(现在写死路径,**进不了 conda 包**);实测递归与可重定位 | 🔄 **进行中** |
| E | conda recipe:`isabelle` 包(把 bundle 打进包)+ 组件包 + Python 包 + 元包 | 待做 |
| F | CI 的 GUI 截图测试(Session 0 ⇒ **窗口标题断言不可用,截图是 ground truth**;可选 Claude Code 判图,建议初期 advisory) | 待做 |
| H | AFP 在打包方案里还没处理 | 待做 |
| I | Cloudflare 面板:Browser Cache TTL → Respect Existing Headers;`repodata` 路径 Bypass cache(**需 zone 权限,得人工点**) | 待做 |

> **D(给 `my_better_isabelle_prover` 加 `build-release` 子命令)已取消** —— 那个仓库由**别人**维护。
> 编排写进**我们自己的** `isabelle-packaging-ci`,把补丁工具当**黑盒**调用
> (`pip install my-better-isabelle-prover` + `my-better-isabelle patch`)。

**基础设施(已就绪,可复用)**
- **Windows 11 QEMU VM**:`/home/qiyuan/qemu-win/`,`./run-win-vm.sh` → ~20 秒后
  `ssh -i ssh/id_win -p 2222 isabelle@localhost` 可非交互驱动;可截图(QEMU monitor `screendump`)。
  **CI 里做不到的真 GUI 验证,只能在这里做。**
- **CI 仓库**:`xqyww123/isabelle-packaging-ci`(长期保留)。
- **Linux 构建原型**:`/home/qiyuan/isa_release_proto/`(hg clone + 打补丁的树 + 产物)。

---

## 9. 被推翻的旧方案(存档 + 推翻理由)

> 旧方案:**不发布 Isabelle,而是复用用户已装的 Isabelle**;conda 包只带 AoA 组件,
> 由 post-link 把组件路径写进用户的全局 `$ISABELLE_HOME_USER/etc/settings`(`init_component`),
> 以便「不激活 conda 也能用」。

**为什么推翻:**

1. **conda 根本不跟踪这些副作用**:post-link 写到 `$PREFIX` 之外的东西,`conda remove` 不删、
   `conda list` 不见;而清理依赖的 `pre-unlink` **不保证执行**(删 env 目录时不跑)⇒
   用户的 Isabelle 可能被永久污染。业界已经用脚投票:post-link 下载的 `cudatoolkit-dev` **已归档弃用**。
2. **补丁躲不过去**:AoA 需要打过补丁的 Isabelle(`register_thy` 是 Isa-REPL 的硬依赖)。
   而**原地 patch 用户自己的 Isabelle**,不但是同一个「不跟踪的副作用」问题的更深版本
   (改外部源码树 + 需要重编译 + 需要重建 heap),而且**没有任何包管理器为这种事背书**——
   所有包管理器的「支持 patch」都指的是「**patch 我自己构建的源码**」(Nix/Homebrew/Debian/RPM/conda-build
   全都如此)。想要包管理器级别的干净,就只能**分发我们自己构建的、打过补丁的 Isabelle**。
3. **heap 也躲不过去**:官方包自带预建 HOL heap;我们改了 Pure/ML ⇒ 不能复用官方 heap ⇒
   必须自己每平台重建(§3.5)。这已经等价于「自己走一遍发布流程」了。

**结论**:「复用用户 Isabelle」看起来省事,实际上把最脏的活(原地改+重编+重建 heap+不可跟踪+不可靠清理)
全推给了 post-link;而「自己发布补丁版 Isabelle」把这些活挪到 **CI 的构建期**,产物是干净、
可跟踪、可复现的完整包。后者才是正路。

---

## 10. 相关文档

- `AOA_DESIGN.md`、`CONDA_ISABELLE_BRIDGE.md`、`RELEASE_PLAN.md` —— **探索期产物,均已被本文档取代**,仅供考古。
- `contrib/my_better_isabelle_prover/` —— 补丁的权威来源(版本键控 diff,幂等/可逆/状态可查)。
- `contrib/Isabelle_RPC/Isabelle_RPC_Host/paths.py` —— Windows 路径归一化(commit `5b9580c`)。
