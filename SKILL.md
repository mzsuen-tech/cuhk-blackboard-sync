---
name: blackboard-course-download
description: Automate incremental syncing of CUHK Blackboard Learn Ultra course materials through the user's own logged-in Chrome — download only newly posted files (tracked by Blackboard fileId in a seen-registry), collect the latest announcements/notices, and check for newly posted quizzes/assessments and their due dates. Covers launching the browser-skill daemon, connecting the Chrome extension, logging in via CUHK OnePass SSO, walking the course folder tree, downloading new files via bbcswebdav URLs, organizing them into a local archive, and producing a per-course Markdown digest. Use this skill when the user asks to download, sync, back up, or archive Blackboard course materials, to collect/整理 the latest announcements, notices, or homework updates, or to check for newly posted quizzes/exams. Default strategy is incremental-only: never re-download or re-verify already-seen files.
agent_created: true
---

# CUHK Blackboard Sync

## What this does

End-to-end automation of Blackboard Learn Ultra syncing through the user's own logged-in Chrome:

1. **增量下载**——只抓新上传的课件，已下载的永不重复下载、永不覆盖。
2. **通知整理**——抓取每门课的公告，译成中文，汇总成一份Markdown。
3. **考核核查**——枚举线上测验/作业/考试及其到期时间，避免漏deadline。

Built on top of the `browser-skill` toolchain (`bsk` CLI + Chrome extension). This
skill adds the Blackboard-specific workflow and the non-obvious pitfalls.

**核心设计原则：增量而非全量。** 判断"是不是新内容"的基准是Blackboard的
`fileId` / `assessmentId`登记表，**不是文件名，也不是本地文件MD5**。理由见
Step 7。

---

## Prerequisites

### 1. browser-skill工具链

- **Chrome扩展BrowserSkill** — 从Chrome应用商店安装并启用；在`chrome://extensions`
  确认版本号。
- **`bsk` CLI**：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/Tencent/BrowserSkill/main/install.sh | sh
  ```
  或从<https://github.com/Tencent/BrowserSkill/releases>下载对应平台二进制。
- **版本匹配**：CLI与扩展的字面版本号**不必须相等**（实测CLI 0.3.1 + 扩展0.3.0可用）。
  真正的判据是`bsk browsers --json`里的`version_skew: false`，且
  `extension_protocol_version`与`protocol_version`一致。协议版本不一致时扩展会**静默连不上**。

先加载`browser-skill` skill以获取`bsk`子命令（`daemon` / `session` / `navigate` /
`observe` / `click` / `evaluate` / `fill`）的完整参数参考。

### 2. 配置

```bash
cp config.example.json config.json   # 然后按自己的课程修改
```

`config.json`已在`.gitignore`中，不会被提交。

### 3. 凭据

**本skill不存储、不缓存任何凭据。** 账号密码只从环境变量或交互式输入读取，
由`scripts/login.sh`使用一次后即丢弃：

```bash
export BLACKBOARD_USER="你的学号或别名"
# 密码建议用交互式输入，不要 export，避免留在 shell 历史和进程环境里
```

**不要把密码写进`config.json`、任何脚本、任何提交进版本库的文件。**

---

## Workflow

### Step 0 — 一键启停会话

```bash
SID=$(./scripts/start_session.sh)   # 启动 daemon + Chrome + session，输出 session_id
./scripts/login.sh "$SID"           # 登录（若已有有效会话则自动跳过）
# ... 各步骤使用 --session "$SID"
./scripts/stop_session.sh "$SID"    # 收尾
```

`scripts/*.sh`均已内置`BSK_HOME=/tmp/bsk_home`与`BSK_AUTO_START=0`默认值，
**不需要**调用者export。若手动执行下述Step 1–3，则须自行export（原因见下）。

### Step 1 — 启动daemon

macOS上daemon在`~/.bsk`下写状态文件会因沙箱拦截原子`rename`而失败
（报`write daemon.json` / `Operation not permitted`）。**把`BSK_HOME`指向`/tmp`绕开：**

```bash
rm -rf /tmp/bsk_home
BSK_HOME=/tmp/bsk_home BSK_AUTO_START=0 bsk daemon start
BSK_HOME=/tmp/bsk_home BSK_AUTO_START=0 bsk status --json   # 确认 daemon_version / protocol_version
```

之后**每条** `bsk`命令都要带同样前缀（或`export`一次）。
Windows/Linux无此限制，可用默认`~/.bsk`。
> `/tmp`重启后清空，重启机器后需重建并重启daemon。

### Step 2 — 连接浏览器扩展

```bash
bsk browsers
```

若为空，请用户在Chrome工具栏点击BrowserSkill图标，等弹窗显示 "connected"，再复查。

### Step 3 — 建立会话

```bash
bsk session start --json   # 记下返回的 session_id
```

`session start`首跑偶发`session creation timed out waiting for extension`
（尤其刚唤醒Chrome后）——直接重试一次即可。`bsk session stop <id>`（id是**位置参数**，
不是`--session <id>`）同样可能报超时；只要随后`bsk daemon stop`成功且
`pgrep -f "bsk daemon"`无残留，会话就已终止。

### Step 4 — 登录Blackboard

```bash
./scripts/login.sh <sessionId>
```

脚本流程：`navigate`到`/ultra/stream` → 判断是否落在登录页 → 读取凭据 →
`fill`账号密码 → `click` Sign in → 轮询等待DUO（最多120秒）。

要点：

- **Cookie通常能维持数天**，但不是每次——实测3天后仍有效，相隔13小时后已失效。
  脚本会先直接navigate，只在确实落到登录页时才走认证。
- **DOM id是稳定的判据**：`userNameInput` / `passwordInput`存在即为登录页，
  比看标题可靠（标题可能就是 "Sign In"）。
- **DUO Push自动通过**（设备已勾选Remember me）。点Sign in后页面会跳到
  `api-*.duosecurity.com/prompt/...`，实测约55秒后才自动落到Blackboard。
  **轮询至少要等60–90秒，不要30秒就判失败。** 轮询期间`evaluate`偶发返回
  `pending user interrupt`之类的噪声属正常，继续下一轮即可。
- **DUO卡住的解法**：若超过3–4分钟仍停在DUO页，先看`#pwl-prompt-root`的
  `innerText`——若只剩Chrome更新横幅+ "Secured by Duo"（提示卡片没渲染，
  也没出现 "Check for a Duo Push"），说明**前端渲染卡住而服务端多半已认证完成**。
  此时**重新`navigate`那个DUO URL本身**：会被重定向回`sts.cuhk.edu.hk`（ADFS），
  再等约8秒即自动落到Blackboard活动页。**不要**因为停在duosecurity就判定
  "需要人工确认"而放弃。
- **`fill` / `click`的ref有时效性**：`@eN`绑定在某一次observe的tab快照上，
  `navigate`之后旧ref立即失效，报`ref @e1 unknown for tab <id>`。注意
  **`fill`会照常打印`fill ok`但字段实际没写进去**；`click`才会报错。
  凡fill/click前必须先`bsk observe`刷新ref。

#### 为什么不走Chrome自带密码自动填充（已实测证伪）

prompt / 环境变量携带明文 → `bsk fill --value`是本流程唯一可行的路径。以下四条
全部实测失败，**不要重复尝试**：

1. **Chrome有两套密码库，只看第一个会得出错误结论**。档案库`Default/Login Data`
   的`logins`表可能是0行，而Google账号同步库`Default/Login Data For Account`
   有条目。**先查`Login Data For Account`**。
2. **自动填充下拉是浏览器原生UI，CDP够不到**。bsk会给输入框标注`[has-submenu]`
   （说明有凭据可用），但下拉项不在页面DOM里，`observe`/`snapshot`看不到、
   `click`的ref与CSS选择器都点不到；实测5种键盘变体（ArrowDown+Enter、双击、
   连按两次方向键、Tab切框、对密码框操作）**全部失败**。
3. **Chrome要求生物识别才能释放密码**：`Default/Preferences`的
   `password_manager.biometric_authentication_filling = True`。Touch ID是OS级原生
   认证，注入的点击/按键无法代替手指；`chrome://password-manager/settings`这类
   chrome:// 页被Agent Window沙箱拒绝。
4. **直接解密也不行**。条目是`v10`格式（AES-128-CBC，`iv` = 16个空格，密钥=
   PBKDF2-HMAC-SHA1(钥匙串条目`Chrome Safe Storage`, salt=`saltysalt`, 1003轮,
   16字节)），读钥匙串必须授权，`security find-generic-password`会弹GUI对话框并
   **挂起不返回**。

另：**密码确为必填**——只填账号、密码留空提交，ADFS明确回
`alert "Enter your password."`，**不存在**无密码 / DUO-only / passwordless路径。

**不建议用`bsk request-help`兜底**：该弹窗会**占用页面**（用户无法同时操作登录表单），
无人值守时必然`outcome=timed_out`。仅在"密码确实无法取得且用户在场"时，才改用
"脚本先填好账号 → 请用户只补密码并点Sign in → 后台轮询检测登录完成"。

**结论：调用方没给密码值= 硬阻塞**，直接判定本轮跳过，不要浪费十几轮工具调用去试自动填充。

---

### Step 5 — 枚举课程与文件

1. 打开课程列表`/ultra/course`，找到目标课程链接；或打开课程后从地址栏读内部ID
   （`/ultra/courses/_<id>_1/outline`）。
2. 打开课程outline，**反复点击每个`button "文件夹，…"`展开文件夹**——Ultra懒加载，
   文件只有在父文件夹展开后才进入DOM。

   **文件夹可任意深嵌套。** 单次点击只展开一层，且点开新的顶层文件夹会折叠上一个。
   **必须循环**——反复点击所有`aria-expanded=false`的`button[aria-label^=文件夹]`，
   间隔3秒，直到某一轮点击数为0。做这一步必须在收集链接之前，否则文件列表是空的。

   直接用`scripts/enumerate_course.sh <sessionId> <courseId>`，它把
   navigate → 递归展开 → 收集 一次做完并打印文件JSON。

   ⚠️ **增量同步请改用`scripts/scan_course_items.sh`**（同一套展开逻辑，但抓取
   **全部**项目并标注`type`）——`enumerate_course.sh`只保留`/file/`，会静默丢掉
   评估项。二者二选一，不要都跑。

   > `/learn/api/v1/courses/<id>/contents`在该Ultra实例上返回**404**。
   >不要依赖Learn REST API枚举，要走DOM。

3. 收集文件链接（`enumerate_course.sh`内部就是这条evaluate）：

   ```bash
   bsk evaluate --session <id> "JSON.stringify(Array.from(document.querySelectorAll('a')).filter(a=>a.href.includes('/file/')).map(a=>({t:(a.getAttribute('aria-label')||a.textContent.trim()),h:a.href})))"
   ```

   每项的`h`形如`https://…/ultra/courses/<courseId>/file/<fileId>?courseId=<courseId>`。

### Step 6 — 下载文件

对每个文件（可靠且确定的方法）：

1. `navigate`到文件预览页
   `https://<host>/ultra/courses/<courseId>/file/<fileId>?courseId=<courseId>`
2. 等约8秒让预览iframe加载。
3. 读iframe的`src`（一个`bbcswebdav` URL），**只保留`?xythos-download=true`** 派生下载：

   ```bash
   SRC=$(bsk evaluate --session <id> "Array.from(document.querySelectorAll('iframe')).map(f=>f.src).find(s=>s.includes('bbcswebdav'))||''" | grep -oE 'https://[^"?]*bbcswebdav[^"?]*' | head -1)
   DL="${SRC}?xythos-download=true"
   bsk navigate "$DL" --session <id> --timeout 15s
   ```

   `navigate`会报`net::ERR_ABORTED` —— 这是**下载已开始的正常信号**，不是错误。
   文件落到浏览器默认下载目录（通常`~/Downloads`）。循环封装见`scripts/download_files.sh`。

### Step 7 — 归档（可配置+ 增量）

`scripts/organize_files.py`读`config.json`决定课程目录与子目录分类：

```bash
python3 scripts/organize_files.py --config config.json --course ECON5022 --dry-run
python3 scripts/organize_files.py --config config.json --course ECON5022 "Lecture 1.pdf" ...
```

- `courses` — Blackboard课程代码 → 本地归档目录名。
- `rules` — 有序的`keywords` / `extensions`分类规则，命中即停；未命中落入`fallback_folder`。

**增量模式（内置）**：归档目录下已存在**同大小+ 同扩展名+ 同MD5** 的文件时跳过，
不重复、不覆盖（也会剥掉Chrome的同名冲突后缀` (1)`）。先用`--dry-run`预览。

#### 增量同步策略（推荐默认）

**只下载新增文件，已下载的一律不管，不做全量复校。** 流程：

1. `scan_course_items.sh`枚举全部项目（**文件+ 评估项超集**），每门课一份JSON。
2. `diff_seen.py --registry <archive_root>/.blackboard_sync/seen_files.json <各课JSON>`
   做差集，输出`NEW_FILES` / `NEW_ASSESSMENTS` / `MISSING_LOCAL`。
3. **只下载`NEW_FILES`列出的fileId；为0时完全跳过下载环节**（这是常态）。
4. 用`organize_files.py`归档。归档前若目标同名文件是**含注释对象的PDF**
   （`page.annots()`非空）→ **不得覆盖**，另存`<主名>_线上更新_<日期>.<ext>`。
5. 归档成功后`diff_seen.py --commit --set-archive <fileId>=<相对路径>`登记。
   **未成功归档的不要登记**，否则下轮不再重试。
6. `MISSING_LOCAL`非0 = 登记过但本地文件已不在（被移动/删除）→ 补下载并归档。

#### 为什么基准必须是fileId登记表

| 候选基准 | 为什么不能用 |
|---|---|
| 文件名 | 老师的Blackboard显示名与本地归档名普遍不同（`Lecture III`→`lecture3.pdf`）→ 会把全部文件误判为"缺失" |
| 本地归档件MD5 | **用户会用自己的PDF阅读器在归档课件上做高亮/批注**，本地MD5必然变化 → 会把用户批注误判成"老师重传"，**覆盖掉用户的批注** |
| Blackboard `fileId` / `assessmentId` | **唯一稳定且唯一**的键。新增内容必然带新id → 差集即新增 |

**成本对比**：全量模式要下载全部文件（22个约294秒）；增量模式**只做3次枚举、
零下载，约1分钟**，且完全不写`~/Downloads`、不触碰任何已归档文件。

`seen_files.json`结构：
`{courses: {courseId: {code,name,archive}}, files: {fileId: {course,display,archive_rel,local_exists,first_seen}}, assessments: {assessmentId: {course,display,due,first_seen}}}`

> ⚠️ **不要把"本地MD5与下载件不同"当成老师重传的证据。** 历史上曾据此误判，
>把用户做过高亮的PDF副本改名成`xxx_旧版<日期>.pdf`，并用无注释的原始版覆盖了
>原文件。排除顺序是：① 看`page.annots()`（有注释 → 差异来自阅读器批注，
> PPT导出不可能产生PDF注释）；② 比内部`modDate`与`creationDate`
>（`creationDate`相同= 同一份源文件）；③ 重新下载线上版本比MD5才算数。
> **本地归档文件一旦被批注，任何一轮都不得覆盖或重命名。**

#### 已实测失败的"绕路下文件"方案（勿重复试错）

1. 页面内`fetch` bbcswebdav算SHA-256 → `TypeError: Failed to fetch`。
   Ultra的CSP `connect-src`拦截（对照组导航到`location.origin + '/favicon.ico'`
   返回200，可确认是CSP而非网络问题）。
2. 课程内容REST API：`/learn/api/public/v1/courses/{id}/contents`被拦、
   `/learn/api/v1/...`返回404。拿不到整门课的文件元数据。
3. 文件预览页只显示所在文件夹与文件名，**不暴露大小/修改时间**。唯一廉价信号是
   iframe src中的`rid-<number>`，但取它仍需1次navigate/文件。

#### 同名文件陷阱

本机`~/Downloads`里若已有用户自己的同名文件，新下载会被Chrome存成
`xxx (1).pdf`。**只能清理带` (1)`后缀的新文件，绝不能删无后缀的用户原件**——
清理脚本里应显式建立保护白名单。

### Step 8 — 抓取最新公告

老师把通知与作业提醒发在**每门课的announcements**，不在活动流里。用
`scripts/fetch_announcements.sh`遍历每门课的`/announcements`页并输出Markdown汇总：

```bash
./scripts/fetch_announcements.sh <sessionId> > "最新通知_$(date +%F).md" <<'EOF'
_123456_1	Course Name A (ECONXXXX)
_234567_1	Course Name B (ECONYYYY)
EOF
```

每行输入`<courseId><TAB><课程名>`。脚本navigate到
`https://<host>/ultra/courses/<courseId>/announcements`，从公告grid
（`main [role=row]` → `a` / `p` / gridcell）提取标题/日期/正文，按课程分组输出。

要点：

- 没有公告的课程会显示"还没有班级公告"，在汇总里跳过。
- 首次访问某课公告页可能很慢；脚本会sleep后抓空则重试一次。
- 作业通知也走公告（如 "Forming homework groups"），无需单独抓取。
- **通知文件必须另设"测验与作业提醒"一节**（测试类内容最容易漏）：列出各门课全部
  线上评估项的标题 / 到期时间 / 满分 / 剩余尝试，数据来自Step 9。单个课程无评估项时
  写"无"。这节与公告节并列。
- **翻译**：公告通常为英文。`translate_announcements_to_chinese`为true（默认）时，
  把正文译成简体中文，保留教师/助教姓名、课程名、日期与技术术语（R、RStudio、
  tutorial、DUO、Blackboard、lecture theatre等）。标题保留原文或双语，译文置于其下。

### Step 9 — 核查线上测验/考试（**每轮例行**）

**核心陷阱**：`enumerate_course.sh`只保留href含`/file/`的项，会**静默丢弃**
评估项（href形如`/ultra/courses/<id>/assessment/_xxx_1/overview`）。
**文件枚举全绿 ≠ 课程没有考试。**

**可靠做法（按优先级）**：

1. **`scripts/scan_course_items.sh <sessionId> <courseId>`** —— 展开全部文件夹后抓
   **全部**项目并标注`type`（`file` / `assessment` / `other`）。**这是唯一可靠的判据**：
   输出里一旦出现`"type":"assessment"`，课程就有线上测验。
2. **`scripts/fetch_assessments.sh <sessionId> <courseId>`** —— 进每个评估的overview页，
   取到期时间、满分、剩余尝试。
3. **`scripts/scan_all_courses.sh <sessionId>`** —— 读`config.json`的`course_ids`，
   一次扫完全部课程，用于回答"这周有哪些quiz/exam到期"。
4. **公告**（辅助印证）—— 老师常在公告里提"in-class quizzes"。但公告只说"课堂小测"时，
   线上评估**可能同时存在**，二者不互斥。

**⛔ 已被实测证伪的判据，不要再用**：

- **成绩簿`/grades`**：显示"未评分"**不代表**没有评估项——未开始/未提交的评估
  根本不在成绩簿出现。
- **只抓顶层`main a`**：Ultra内容懒加载，文件夹折叠时子项不在DOM里。必须先递归
  展开，否则只能抓到导航链接，会错误得出"无评估项"。

**评估详情页结构**：`/ultra/courses/<courseId>/assessment/<assessmentId>/overview`的
innerText为`[0]跳至主要内容 [1]课程名 [2]评估标题 [3]标题(重复) [4]详细信息…`，
字段含`评估到期日期`（最要紧）、`最高分数`、`剩余 N 次尝试`。

**与sample quiz的区别（易混）**：`sample_quiz1.docx`（**文件**，在Course Materials下）
是教师提供的**样卷**；`Quiz 1`（**assessment**）是**真正计分的小测**。
用户说"试卷"时通常指后者，先确认再下载。

#### 下载评估项里的题目附件（不在`/file/`链接里，Step 6方法不适用）

```bash
./scripts/assessment_attachments.sh <sessionId> <courseId>                       # 只列出
./scripts/assessment_attachments.sh <sessionId> <courseId> <host> --download     # 列出并下载
```

手动路径（即脚本实现原理）：

1. 打开`/ultra/courses/<courseId>/assessment/<assessmentId>/overview`
2. 点`link "查看说明"`展开说明区
3. 附件以`button "预览文件 <文件名>"` + `button "<文件名> 的更多选项 [has-submenu]"`
   控件形式存在。⚠️ **只看innerText只会看到一行附件文件名，会误以为那只是说明文字；
   必须看DOM（observe，第3层）才能发现这两个控件**。
4. 点"更多选项" → `menuitem "下载原始文件"` → 文件落到`~/Downloads`
5. 归档时按**真实扩展名**处理。

**下载链路实测踩坑**：

- **必须用bsk click（CDP真实点击），不能用JS的`element.click()`**：Chrome的下载
  策略要求真实用户手势，合成点击会被拦截，文件不落盘（表现为"点了但没反应"）。
- **菜单项文本是"下载原始文件"**：早期grep调试输出曾把它截断成"下载"，按"下载"
  精确匹配会找不到。匹配用`menuitem "[^"]*下载`模糊匹配。
- **BSD grep（macOS）不支持`-m1E`连写**：会把 "1E" 当作`-m`的参数报
  `Invalid argument`，必须分开写`-m1 -E`。
- **下载落盘有延迟（实测5–10秒）**：点击后立刻检查`~/Downloads`会误判为失败，
  应轮询等待。

#### docx题目里的公式必须单独提取

Word公式是OMML对象，`python-docx`的`paragraph.text` **读不到**，直接输出会造成
题目残缺。正确做法是绕开python-docx，直接解析XML：

```python
import zipfile, re
xml = zipfile.ZipFile(path).read('word/document.xml').decode('utf-8')
for m in re.findall(r'<m:oMath[^>]*>.*?</m:oMath>', xml, re.S):
    print(''.join(re.findall(r'<m:t[^>]*>(.*?)</m:t>', m, re.S)))
```

>更稳妥的写法是做**命名空间无关的遍历**（按localname取`oMath` / `t`）。
>注意上下标是`m:sSubSup`的`<m:e>/<m:sub>/<m:sup>`，纯文本拼接会丢掉层级
>（如`x1ρ`实为x₁^ρ）。

---

## 信息读取三层模型（排查"为什么没读到X"先看这个）

Blackboard的信息读取失败几乎都归入这三层。**按三层自顶向下检查**：

**第1层 · 项目枚举层 —— 课程里"有什么东西"**
课程内容是混合体：文件（`/file/`）、评估（`/assessment/`）、工具链接、出勤、消息等。
任何只取单一类型的枚举（如`enumerate_course.sh`只保留`/file/`）都会**静默丢掉**其它类型。
回答"有没有考试/作业"必须走全量枚举（`scan_course_items.sh`）。
>失败实例：只扫文件 → 漏掉Quiz（assessment）。

**第2层 · 页面结构层 —— 页面里"此刻渲染了什么"**
Ultra懒加载+ 折叠态：文件夹未展开时子项不在DOM；列表可能分页/滚动加载；
成绩簿只显示已开始的评估。**DOM快照 ≠ 全量内容**。
>失败实例：抓顶层`main a`（折叠态）→ 只剩导航链接，误判"无评估项"。

**第3层 · 控件语义层 —— 一段文本"是不是控件"**
`innerText`只能看到文字，看不到`button` / `aria-label` / `role`。说明区里的一行
`quiz1.docx`可能是纯文字，也可能是"预览文件"附件控件。
>失败实例：只看innerText → 把附件名当说明文字，漏掉题目文件。

**对应的工具选择**：
- 要"有什么" → `scan_course_items.sh`（第1层）
- 要"页面结构" → observe **全量**输出（第2层），不要head截断
- 要"可交互对象/附件" → observe的`@e`控件+ aria-label（第3层）

---

## Key Pitfalls（最常中断流程的几条）

完整清单见`references/troubleshooting.md`。

1. **macOS daemon沙箱** —— `~/.bsk`下`write daemon.json`失败；用`BSK_HOME=/tmp/bsk_home`。
2. **CLI / 扩展协议版本不一致** —— 扩展会静默连不上。
3. **下载URL参数** —— 保留`isInlineRender=true`或`render=inline`会打开文档查看器
   而非下载；**只保留`?xythos-download=true`**。
4. **懒加载+ 多层嵌套文件夹** —— 文件在父文件夹展开前不在DOM，且可嵌套数层。
   循环展开直到没有折叠的文件夹（见Step 5）。
5. **`download_files.sh`的name参数只是标签** —— Chrome用**服务器返回的真实文件名**
   保存（Blackboard显示`EAA no sol.pdf`，实际落盘`EAA Lecture 2 and 3 No sol.pdf`）。
   归档时要以`~/Downloads`里的**真实文件名**作为`organize_files.py`的参数，
   否则报`MISSING`。
6. **不要拿"下载件MD5 vs本地归档件MD5"判断是否有更新** —— 用户会在归档课件上
   做批注，本地MD5必然变化。更新判据一律是`diff_seen.py`的`NEW_FILES`。
   万一确实要归档同名新版，先查目标文件`page.annots()`，非空则**不得覆盖**。
   偶发的`NOIFRAME`重跑一次即可。
7. **"已下载过"的正确记录方式是fileId** —— 不是文件名也不是本地文件。用
   `<archive_root>/.blackboard_sync/seen_files.json`按fileId登记；只有**未登记**的
   id才是新增。
8. **`~/Downloads`里可能早有同名文件** —— Chrome会追加` (1)`，organizer会自动剥离。
   **但原有同名文件是用户数据，绝不能删。**
9. **`/file/`过滤器会吞掉评估项，成绩簿也不能当判据（最严重的一条）** —— 判断有无
   考核必须用`scan_course_items.sh`；且**成绩簿显示"未评分"不能作为"无评估项"的证据**。
10. **JS合成点击无法触发Chrome下载** —— `element.click()`会被"下载需用户手势"
    策略拦截。凡涉及下载的点击必须用bsk click（CDP真实点击）。
11. **工具链自身的坑** ——
    （a）BSD grep（macOS）不支持`-m1E`连写，须写`-m1 -E`；
    （b）grep调试输出可能截断长文本，控件文本以observe全量输出为准；
    （c）依赖调用者`export BSK_HOME`的脚本会**静默扫到0项**而非报错——
    所有`scripts/*.sh`已内置默认值，新写脚本务必保留该模式。

---

## 重复文件清理（仅在确实下载了文件时适用）

`NEW_FILES`为0的常态轮次没有任何待清理文件。只处理"本轮下载且已验证与归档副本
MD5一致"的文件：

1. 先`mv`到`~/Downloads/Blackboard_重复待清理_<日期>/`（可恢复的中间站）。
2. 逐个算MD5，必须在归档树里找到完全一致的版本才算通过；
   **未通过的一律保留并列出，绝不删除**。
3. 清理只用系统废纸篓，不用`rm`：首选
   `osascript -e 'tell application "Finder" to delete POSIX file "..."'`；
   若沙箱报`-10004`权限违例，改用`shutil.move(f, ~/.Trash/<name>)`。
   注意`~/.Trash`已存在，用`os.path.isdir`判断而不要`mkdir`（broker shim下会抛`EEXIST`）。
4. 清空后用`os.rmdir`移除空的待清理目录。

**绝对禁止**：`rm` / `rm -rf`这些文件；删除用户原有的同名文件；删除任何未通过MD5校验的文件。

---

## Resources

**默认增量流程只用这三个**：`scan_course_items.sh` → `diff_seen.py` → `organize_files.py`。

| 脚本 | 作用 |
|---|---|
| `scripts/doctor.sh` | 环境自检：bsk/daemon/扩展/config/凭据逐项检查并给修复建议 |
| `scripts/start_session.sh` | 一键启动daemon + Chrome + session，输出session_id；自带BSK_HOME默认值 |
| `scripts/stop_session.sh` | 停止会话与daemon，输出清理结果 |
| `scripts/login.sh` | OnePass登录（环境变量或交互式取密码，不落盘） |
| `scripts/scan_course_items.sh` | **全量**项目扫描：展开所有文件夹后抓file + assessment + other并标注`type`。判断有无小测/考试的唯一可靠手段 |
| `scripts/diff_seen.py` | **增量判定的核心**。与已见登记表做差集，输出`NEW_FILES` / `NEW_ASSESSMENTS` / `MISSING_LOCAL`；`--commit`登记，`--set-archive`回填归档位置 |
| `scripts/organize_files.py` | 按配置规则分类归档，内置增量（跳过重复） |
| `scripts/enumerate_course.sh` | 一次性课程文件枚举。⚠️ 只输出`/file/`，**不含评估项**；增量流程请用`scan_course_items.sh` |
| `scripts/download_files.sh` | 按`<fileId><TAB><name>`列表下载（CDP真实导航触发下载） |
| `scripts/fetch_assessments.sh` | 抓取课程内每个评估项的详情（到期 / 满分 / 剩余尝试），输出Markdown表 |
| `scripts/scan_all_courses.sh` | 读`config.json`的`course_ids`，一次扫完全部课程 |
| `scripts/assessment_attachments.sh` | 枚举（可选`--download`）评估项"作业说明"区的附件 |
| `scripts/fetch_announcements.sh` | 遍历各课公告页，输出Markdown汇总 |
| `references/troubleshooting.md` | 详细症状 / 根因 / 修复 |
| `config.example.json` | 归档配置模板；复制为`config.json`后修改 |
