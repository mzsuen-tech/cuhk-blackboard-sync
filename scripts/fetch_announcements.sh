#!/usr/bin/env bash
#
# fetch_announcements.sh — 抓取各门课的 Blackboard 公告，汇总成 Markdown。
#
# 用法:
#   ./fetch_announcements.sh <sessionId> [host] <<'EOF'
#   _272226_1	Econometric Analysis and Applications (ECON5122)
#   _272216_1	Macroeconomic Analysis and Applications (ECON5022)
#   EOF
#
#   <sessionId>  活动的 bsk session id（`bsk session start --json` 返回）
#   [host]       可选 Blackboard 主机，默认 blackboard.cuhk.edu.hk
#   每行输入     "<courseId><TAB><课程名>"（courseId 见课程 URL 的 /courses/_<id>_1）
#
# 输出: Markdown 汇总（课程分组 + 每个公告的标题/日期/正文），打印到 stdout。
# 可重定向保存，例如:
#   ./fetch_announcements.sh elgd > "最新通知_$(date +%F).md"
#
# 依赖: bsk CLI 在 PATH；daemon 已启动；session 已建立且已登录。
#       BSK_HOME 若 daemon 用自定义 home（macOS 常为 /tmp/bsk_home）需先 export。

set -u

SESSION_ID="${1:?usage: fetch_announcements.sh <sessionId> [host]}"
HOST="${2:-blackboard.cuhk.edu.hk}"

# 复用环境里的 BSK_HOME / BSK_AUTO_START
# 环境变量默认值：macOS 上 daemon 的 state 目录固定放 /tmp（沙箱限制下 ~/.bsk 写入会失败）。
# 脚本自带默认值，不依赖调用者先 export，避免"静默扫到 0 项"。
: "${BSK_HOME:=/tmp/bsk_home}"
: "${BSK_AUTO_START:=0}"
export BSK_HOME BSK_AUTO_START

BSK=(bsk)
[ -n "${BSK_HOME:-}" ] && BSK=(env BSK_HOME="$BSK_HOME" bsk)
[ -n "${BSK_AUTO_START:-}" ] && BSK=(env BSK_HOME="${BSK_HOME:-}" BSK_AUTO_START="$BSK_AUTO_START" bsk)

# 抓取公告的 JS：从公告 grid 提取每行的 标题 / 日期 / 正文
GRAB_JS="JSON.stringify(Array.from(document.querySelectorAll('main [role=row]')).map(row=>{const a=row.querySelector('a');const p=row.querySelector('p');const cells=row.querySelectorAll('[role=gridcell],td');return {title:a?a.textContent.trim():'',date:cells.length>1?cells[1].textContent.trim():'',content:p?p.textContent.trim().replace(/\s+/g,' '):''};}).filter(x=>x.title||x.content))"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
i=0
while IFS=$'\t' read -r cid cname; do
  [ -z "$cid" ] && continue

  "${BSK[@]}" navigate "https://${HOST}/ultra/courses/${cid}/announcements" \
    --session "$SESSION_ID" --timeout 20s >/dev/null 2>&1
  sleep 6

  json=$("${BSK[@]}" evaluate --session "$SESSION_ID" "$GRAB_JS" 2>&1 | head -1)

  # 首次访问公告页可能加载慢，抓空则等待后重试一次
  if [ "$json" = "[]" ] || [ -z "$json" ]; then
    sleep 4
    json=$("${BSK[@]}" evaluate --session "$SESSION_ID" "$GRAB_JS" 2>&1 | head -1)
  fi

  # 每门课写一行 NDJSON 到临时文件（course + 公告数组）
  python3 - "$cname" "$json" "$TMP/c$i.json" <<'PY'
import json, sys
cname, raw, out = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    anns = json.loads(raw)
except Exception:
    anns = []
with open(out, "w", encoding="utf-8") as f:
    json.dump({"course": cname, "announcements": anns}, f, ensure_ascii=False)
PY

  i=$((i+1))
done

# 汇总生成 Markdown
python3 - "$TMP" <<'PY'
import json, sys, glob, os
from datetime import datetime
tmp = sys.argv[1]
courses = []
for f in sorted(glob.glob(os.path.join(tmp, "c*.json"))):
    try:
        courses.append(json.load(open(f, encoding="utf-8")))
    except Exception:
        continue

print("# 最新通知汇总（%s）" % datetime.now().strftime("%Y-%m-%d"))
print()
for c in courses:
    anns = c.get("announcements", [])
    if not anns:
        continue
    print("## %s" % c.get("course", ""))
    print()
    for a in anns:
        title = a.get("title") or "（无标题）"
        date = a.get("date") or ""
        content = a.get("content") or ""
        print("### %s%s" % (title, ("（" + date + "）") if date else ""))
        print()
        if content:
            print(content)
            print()
PY

# 注意：实际 Markdown 已由上方 python3 打印到 stdout
