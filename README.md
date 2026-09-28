# CUHK Blackboard Sync

把港中大Blackboard Learn Ultra上的课件、课程公告、测验与作业截止日期自动同步到本地，**只下载新增内容**，已下载的永不重复下载、永不覆盖。

Syncing CUHK Blackboard Ultra course materials through your own logged-in Chrome. Incremental-only: never re-download, never overwrite.

这是一个面向香港中文大学经济系同学的Skill，配合支持Skill的AI Agent客户端（如WorkBuddy）使用。

---

## 能做什么

| 能力 | 说明 |
|---|---|
| 增量下载课件 | 按Blackboard的fileId建立登记表，只抓新上传的文件，一轮同步通常零下载、约1分钟 |
| 自动归档分类 | 按你配置的规则自动分到`讲义`/`大纲`/`数据`/`习题`等子目录 |
| 整理课程公告 | 抓取每门课的announcements，译成中文，汇总成一份Markdown |
| 核查考核项 | 枚举线上测验/作业/考试及到期时间、满分、剩余尝试次数，避免漏deadline |
| 不碰你的批注 | 你在PDF上做的高亮/批注不会被覆盖（详见"设计取舍"） |

## 不能做什么（能力边界，请先读）

- **不能代替你登录**。首次登录需要你的CUHK OnePass账号与密码，以及手机上的DUO Push确认。
- **不能答题、不能交作业**。本工具只做资料同步，不生成任何可提交的作业内容。
- **不能保证抓到所有内容**。只同步Blackboard上真实存在的内容；老师在课堂上口述、或纸面发放的材料不会被抓到。
- **有验证码/风控的页面可能失效**。学校若调整登录页或Ultra前端结构，脚本需要用相同思路重新适配。
- **不做全量校验**。这是刻意的设计选择，不是缺陷——见下文"设计取舍"。

---

## 前置条件

### 1. 一个支持Skill的AI Agent客户端

本仓库是一份Skill，需要由Agent加载执行。目前使用WorkBuddy验证通过；Claude Code等支持Skill机制的客户端理论上可用，但未做验证。

### 2. browser-skill工具链

本Skill依赖[BrowserSkill](https://github.com/Tencent/BrowserSkill)在你的Chrome里执行操作：

```bash
curl -fsSL https://raw.githubusercontent.com/Tencent/BrowserSkill/main/install.sh | sh
```

再从Chrome应用商店安装BrowserSkill扩展并启用。

**版本要求**：`bsk`CLI与扩展的字面版本号不必须相等，但协议版本必须一致。在`chrome://extensions`查看扩展版本，运行`bsk --version`查看CLI版本，并用下面这条命令确认协议匹配：

```bash
bsk browsers --json    # 期望看到 "version_skew": false
```

若扩展始终连不上，多半是协议版本不一致。

### 3. Chrome已登录CUHK

你的Chrome需要能正常访问<https://blackboard.cuhk.edu.hk>，且手机上已启用DUO Push（设备上勾选过Remember me，登录才会自动通过）。

>注意：如果你的网络无法直连`github.com`，clone本仓库和使用`gh`可能受影响，但这不影响本Skill本身的运行（它只访问CUHK域名）。

---

## 安装

```bash
git clone https://github.com/mzsuen-tech/cuhk-blackboard-sync.git
cd cuhk-blackboard-sync
./install.sh                      # 默认装到 ~/.workbuddy/skills/
```

或手动复制：

```bash
mkdir -p ~/.workbuddy/skills/blackboard-course-download
cp -r SKILL.md config.example.json scripts references \
      ~/.workbuddy/skills/blackboard-course-download/
```

装好后重启Agent客户端，Skill即生效。

---

## 快速开始

### 第一步：写配置

```bash
cp config.example.json config.json
```

编辑`config.json`，把`courses`改成你的课程，把`archive_root`改成你想归档的位置：

```json
{
  "archive_root": "~/BlackboardArchive",
  "courses": {
    "ECON5012": "Micro Economics",
    "ECON5022": "Macro Economics"
  }
}
```

`config.json`已在`.gitignore`里，不会被提交。

### 第二步：找到每门课的courseId

打开课程，看浏览器地址栏：

```
https://blackboard.cuhk.edu.hk/ultra/courses/_272211_1/outline
                                          ^^^^^^^^^ 
```

`_272211_1`就是courseId。把它填进`config.json`的`course_ids`。这一步只影响`scan_all_courses.sh`（一次扫完全部课程），不填也能逐门课跑。

### 第三步：跑一次

最简单的用法是直接对Agent说：

>帮我同步一下Blackboard的课件和最新通知

Agent会加载本Skill并按流程执行。若你想手动跑，流程是：

```bash
cd ~/.workbuddy/skills/blackboard-course-download

SID=$(./scripts/start_session.sh)          # 启动daemon + Chrome + session
./scripts/login.sh "$SID"                  # 登录（已有有效Cookie时自动跳过）

./scripts/scan_course_items.sh "$SID" _272211_1 > /tmp/econ5012.json
python3 scripts/diff_seen.py \
    --registry ~/BlackboardArchive/.blackboard_sync/seen_files.json \
    /tmp/econ5012.json                     # 看NEW_FILES有几项，通常是0

./scripts/fetch_announcements.sh "$SID" > "最新通知_$(date +%F).md"

./scripts/stop_session.sh "$SID"           # 收尾
```

`scan_course_items.sh`必须传入课程ID，逐个课程跑。

---

## 每日自动同步（可选）

如果你用的客户端支持定时任务（WorkBuddy的automation），可以配成每晚自动跑一轮。要点是把下面这些信息**显式写进任务描述**，因为定时任务运行时看不到当前对话：

- 归档根目录的绝对路径
- 每门课的Blackboard课程代码与courseId的对应关系
- 账号（密码建议通过客户端的安全凭据机制提供，不要明文写进任务描述）
- 产出要求：通知文件必须包含`测验与作业提醒`一节，列出所有线上评估项的到期时间

---

## 目录结构

```
cuhk-blackboard-sync/
├── SKILL.md                        # Skill主文件：完整工作流与踩坑记录
├── README.md                       # 本文件
├── config.example.json             # 配置模板，复制为config.json
├── install.sh                      # 安装脚本
├── scripts/
│   ├── start_session.sh            # 一键启动/停止环境
│   ├── stop_session.sh
│   ├── login.sh                    # OnePass登录（凭据不落盘）
│   ├── scan_course_items.sh        # 全量枚举（文件+评估项）
│   ├── diff_seen.py                # 增量判定核心
│   ├── organize_files.py           # 分类归档
│   ├── enumerate_course.sh         # 仅枚举文件
│   ├── download_files.sh           # 批量下载
│   ├── fetch_assessments.sh        # 评估项详情
│   ├── scan_all_courses.sh         # 一次扫完全部课程
│   ├── assessment_attachments.sh   # 评估项附件
│   └── fetch_announcements.sh      # 公告汇总
└── references/
    └── troubleshooting.md          # 详细排错手册
```

---

## 设计取舍

### 为什么"已下载过"的基准是fileId，而不是文件名或本地MD5

这是本项目最重要的一条设计决定，也是踩过坑之后的结论。

| 候选基准 | 为什么不能用 |
|---|---|
| 文件名 | 老师在Blackboard的显示名和你本地归档名普遍不同（`Lecture III`归档成了`lecture3.pdf`），用文件名比对会把全部历史文件误判为"缺失"，然后重新下载一遍 |
| 本地文件MD5 | **你会用自己的PDF阅读器在课件上做高亮和批注，本地MD5必然变化**，用MD5比对会把你的批注误判成"老师重传"，进而覆盖掉你自己的笔记 |
| Blackboard的`fileId` | 稳定且唯一，新增内容必然带新id，差集即新增 |

代价是：不做全量校验，理论上无法发现"老师原地替换了某个文件的内容但没换id"这种极罕见情况。权衡下来，保护你的批注远比捕捉这种情况重要。

**保护规则**：归档时若目标同名文件含有注释对象（`page.annots()`非空），一律不覆盖、不改名，线上新版另存为`<主名>_线上更新<日期>.<ext>`。

### 为什么password走环境变量/交互输入而不是配置文件

Skill本身不存储任何凭据。`login.sh`从环境变量或`read -s`交互读取，用完即丢。这样即使你误把整个目录提交上去，也不会泄露账号。

---

## 常见问题

| 现象 | 原因与处理 |
|---|---|
| `bsk daemon start`报`write daemon.json` | macOS沙箱限制。所有`scripts/*.sh`已内置`BSK_HOME=/tmp/bsk_home`绕开；手动执行`bsk`命令时需自行加此前缀 |
| 扩展连不上，`bsk browsers`为空 | 协议版本不一致。检查`chrome://extensions`与`bsk --version` |
| 扫描结果为空 | 通常是漏了`BSK_HOME`（脚本会静默扫到0项而非报错）。用`scripts/*.sh`而非手敲命令 |
| 下载后文件夹里没有文件 | `navigate`报`net::ERR_ABORTED`是下载成功的正常信号；真失败是`NOIFRAME`，重跑一次即可 |
| 归档报`MISSING` | 你传的文件名是Blackboard的显示名，但落盘用的是服务器真实文件名。以`~/Downloads`里的实际文件名为准 |
| 成绩簿显示"未评分" | **不代表没有考试**。未开始/未提交的评估根本不出现在成绩簿，判断有无考核必须用`scan_course_items.sh` |
| 登录卡在DUO页面不动 | 重新`navigate`一次那个DUO页面，会被重定向回ADFS，约8秒后自动落到Blackboard。详见`SKILL.md` |

更多症状与根因见`references/troubleshooting.md`。

---

## 安全与合规（请务必阅读）

**关于你的账号**

- 本Skill走的是你自己的浏览器会话，用你自己的账号访问你自己有权访问的课程内容，不涉及任何绕过认证的手段。
- 请只同步你本人已注册的课程。不要用它获取他人课程的材料。
- 不要把`config.json`、`seen_files.json`或任何含凭据的文件提交到公开仓库。本仓库的`.gitignore`已默认忽略。

**关于学术诚信**

- 本工具只做**资料同步与整理**，不生成、不辅助生成任何可提交的作业答案。
- 请自行遵守课程大纲中对AI工具的使用规定。多数课程对"用AI生成答案提交"是明确禁止的；部分课程要求使用AI时提交声明。
- 自动同步下来的测试题、样卷属于教师提供的课程材料，请勿外传。

**关于学校IT政策**

- 本工具通过浏览器自动化模拟正常用户操作，请求频率很低（一轮同步通常只有几次页面访问），不对学校服务器造成额外负担。
- 使用前请自行确认不违反港中大关于计算资源使用的相关规定。

**免责声明**

本项目为个人开源工具，与香港中文大学无任何关联，未获校方认可或背书。使用者需自行承担因使用本工具产生的一切后果。作者不对数据丢失、账号异常或违反校规等情况负责。

---

## 贡献

欢迎提Issue反馈适配问题。由于Blackboard Ultra的前端结构会不定期变动，如果某天脚本突然失效，大概率是DOM结构变了，`SKILL.md`里的"信息读取三层模型"提供了定位思路。

## License

[MIT](LICENSE)
