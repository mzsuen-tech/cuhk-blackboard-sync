#!/usr/bin/env bash
#
# scan_all_courses.sh — 一次性抓取 config.json 中所有课程的线上评估事项（小测/作业/考试）。
#
# 用法: ./scan_all_courses.sh <sessionId> [host]
#   <sessionId>  活动 bsk session id
#
# 输出: 每门课一节 Markdown（标题/到期时间/满分/剩余尝试）。
#
# 用途: 回答"这周有哪些 quiz/exam 要到期"——把"有没有布置小测/考试"变成常规动作，
#       而不是等用户问起、或只看文件列表而漏掉评估项。
#
# 依赖: bsk CLI；daemon 与 session 已就绪；同目录下的 fetch_assessments.sh；
#       ../config.json 中已配置 course_ids。

set -u

SESSION_ID="${1:?usage: scan_all_courses.sh <sessionId> [host]}"
HOST="${2:-blackboard.cuhk.edu.hk}"

DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CONFIG:-$DIR/../config.json}"

if [ ! -f "$CONFIG" ]; then
  echo "找不到配置文件: $CONFIG" >&2
  exit 1
fi

TMP=$(mktemp)
python3 -c "
import json, sys
cfg = json.load(open('$CONFIG'))
ids = cfg.get('course_ids', {})
if not ids:
    sys.stderr.write('config.json 中缺少 course_ids\n')
    sys.exit(1)
for code, cid in ids.items():
    name = cfg.get('courses', {}).get(code, code)
    print('%s\t%s\t%s' % (code, cid, name))
" > "$TMP" || { rm -f "$TMP"; exit 1; }

TOTAL=0
while IFS=$'\t' read -r code cid name <&3; do
  [ -z "$cid" ] && continue
  TOTAL=$((TOTAL + 1))
  echo "## ${code}　${name}"
  echo ""
  "$DIR/fetch_assessments.sh" "$SESSION_ID" "$cid" "$HOST" 2>&1
  echo ""
done 3< "$TMP"

rm -f "$TMP"
echo "（已扫描 ${TOTAL} 门课程）"
