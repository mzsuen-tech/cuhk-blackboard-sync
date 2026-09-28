#!/usr/bin/env bash
#
# fetch_assessments.sh — 抓取一门 Blackboard Ultra 课程的全部线上评估事项（小测/作业/考试）详情。
#
# 用法: ./fetch_assessments.sh <sessionId> <courseId> [host]
#   <sessionId>  活动 bsk session id
#   <courseId>   Blackboard 课程内部 id，如 _123456_1
#
# 输出: Markdown 表格（标题 / 到期时间 / 满分 / 剩余尝试 / 链接）
#       课程内没有线上评估时明确输出"无线上评估项"。
#
# 用途: 回答"这门课有没有布置小测/考试、什么时候到期"这类问题。
#       到期时间是最要紧的字段 —— 实测 ECON5012 的 Quiz 1 到期于 26/9/25 9:00，
#       若只扫文件会完全看不到这条deadline。
#
# 依赖: bsk CLI；daemon 已启动；session 已建立且已登录；BSK_HOME 已 export；
#       同目录下的 scan_course_items.sh。

set -u

SESSION_ID="${1:?usage: fetch_assessments.sh <sessionId> <courseId> [host]}"
COURSE_ID="${2:?missing courseId}"
HOST="${3:-blackboard.cuhk.edu.hk}"

DIR="$(cd "$(dirname "$0")" && pwd)"

# 环境变量默认值：macOS 上 daemon 的 state 目录固定放 /tmp（沙箱限制下 ~/.bsk 写入会失败）。
# 脚本自带默认值，不依赖调用者先 export，避免"静默扫到 0 项"。
: "${BSK_HOME:=/tmp/bsk_home}"
: "${BSK_AUTO_START:=0}"
export BSK_HOME BSK_AUTO_START

BSK=(bsk)
[ -n "${BSK_HOME:-}" ] && BSK=(env BSK_HOME="$BSK_HOME" bsk)
[ -n "${BSK_AUTO_START:-}" ] && BSK=(env BSK_HOME="${BSK_HOME:-}" BSK_AUTO_START="$BSK_AUTO_START" bsk)

ITEMS=$("$DIR/scan_course_items.sh" "$SESSION_ID" "$COURSE_ID" "$HOST" 2>/dev/null | tail -1)

TMP=$(mktemp)
printf '%s' "$ITEMS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for x in d:
    if isinstance(x, dict) and x.get('type') == 'assessment':
        print(x['h'])
" > "$TMP"

N=$(wc -l < "$TMP" | tr -d ' ')

if [ "$N" = "0" ]; then
  echo "### 课程 ${COURSE_ID}：无线上评估项（无测验/线上作业）"
  rm -f "$TMP"
  exit 0
fi

echo "### 课程 ${COURSE_ID}：共 ${N} 项线上评估"
echo ""
echo "| 标题 | 到期时间 | 满分 | 剩余尝试 | 链接 |"
echo "| --- | --- | --- | --- | --- |"

while IFS= read -r u <&3; do
  [ -z "$u" ] && continue
  "${BSK[@]}" navigate "$u" --session "$SESSION_ID" --timeout 30s >/dev/null 2>&1
  sleep 7
  "${BSK[@]}" evaluate --session "$SESSION_ID" \
    "(document.body.innerText||'').replace(/\n{3,}/g,'\n')" 2>&1 | U="$u" python3 -c "
import sys, re, os
t = sys.stdin.read()
lines = [l.strip() for l in t.split('\n') if l.strip()]
# 结构: [0]跳至主要内容 [1]课程名 [2]评估标题 [3]评估标题(重复) [4]详细信息 ...
title = lines[2] if len(lines) > 2 else (lines[1] if len(lines) > 1 else '?')
due = score = att = ''
for i, l in enumerate(lines):
    if '到期日期' in l and i + 1 < len(lines) and not due:
        due = lines[i + 1]
    if '最高分数' in l and i + 1 < len(lines) and not score:
        score = lines[i + 1]
    m = re.search(r'(剩余\s*\d+\s*次尝试|无剩余尝试|不限制)', l)
    if m and not att:
        att = m.group(1)
print('| %s | %s | %s | %s | %s |' % (title, due or '-', score or '-', att or '-', os.environ['U']))
"
done 3< "$TMP"

rm -f "$TMP"
