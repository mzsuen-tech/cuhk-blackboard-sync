#!/usr/bin/env bash
#
# assessment_attachments.sh — 枚举（可选下载）一门课程所有评估项"作业说明"区里的附件。
#
# 用法:
#   ./assessment_attachments.sh <sessionId> <courseId> [host]            # 只列出附件
#   ./assessment_attachments.sh <sessionId> <courseId> [host] --download # 列出并下载到 ~/Downloads
#
# 输出: 每个评估一段：标题 + 附件名列表（或"无附件"）。
#
# ⚠️ 为什么需要这个脚本（血泪教训）：
#   评估项的题目文件不在 /file/ 链接里，而是挂在"作业说明"区，以
#   button "预览文件 <文件名>" / button "<文件名> 的更多选项 [has-submenu]"
#   两个控件的形式存在。只看 innerText 会把附件名当成说明文字而漏掉 ——
#   实测 ECON5012 的 quiz1.docx 就这样被漏过一轮。
#
# 依赖: bsk CLI；daemon 已启动；session 已建立且已登录；BSK_HOME 已 export；
#       同目录下的 scan_course_items.sh。

set -u

SESSION_ID="${1:?usage: assessment_attachments.sh <sessionId> <courseId> [host] [--download]}"
COURSE_ID="${2:?missing courseId}"
HOST="${3:-blackboard.cuhk.edu.hk}"
MODE="${4:-}"

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
  echo "课程 ${COURSE_ID}：无评估项"
  rm -f "$TMP"
  exit 0
fi

echo "课程 ${COURSE_ID}：${N} 个评估项"
echo ""

while IFS= read -r u <&3; do
  [ -z "$u" ] && continue
  "${BSK[@]}" navigate "$u" --session "$SESSION_ID" --timeout 30s >/dev/null 2>&1
  sleep 7

  # 展开"查看说明"
  "${BSK[@]}" evaluate --session "$SESSION_ID" \
    "(function(){var e=Array.from(document.querySelectorAll('a,button')).find(x=>(x.textContent||'').trim().indexOf('查看说明')>-1); if(e){e.click(); return 'ok'} return 'no-expand-link'})()" \
    >/dev/null 2>&1
  sleep 3

  # 抓评估标题（结构: [0]跳至主要内容 [1]课程名 [2]标题）
  TITLE=$("${BSK[@]}" evaluate --session "$SESSION_ID" \
    "(document.body.innerText||'').split('\n').map(s=>s.trim()).filter(s=>s)[2]||'?'" 2>&1 | tail -1)

  # 抓附件控件（aria-label 以"预览文件"开头的 button）
  ATT=$("${BSK[@]}" evaluate --session "$SESSION_ID" \
    "JSON.stringify(Array.from(new Set(Array.from(document.querySelectorAll('button')).map(b=>b.getAttribute('aria-label')||'').filter(l=>l.indexOf('预览文件')===0).map(l=>l.replace(/^预览文件\s*/,'')))))" \
    2>&1 | tail -1)

  echo "### ${TITLE}"
  if [ "$ATT" = "[]" ] || [ -z "$ATT" ]; then
    echo "（无附件）"
  else
    printf '%s' "$ATT" | python3 -c "
import sys, json
try:
    for name in json.load(sys.stdin):
        print('-', name)
except Exception:
    print('-', '(附件名解析失败)')
"

    if [ "$MODE" = "--download" ]; then
      FDTMP=$(mktemp)
      printf '%s' "$ATT" | python3 -c "
import sys, json
try:
    for name in json.load(sys.stdin):
        print(name)
except Exception:
    pass
" > "$FDTMP"
      while IFS= read -r fname <&4; do
        [ -z "$fname" ] && continue
        # ⚠️ 必须用 bsk click（CDP 真实点击）而非 JS 的 element.click()：
        # Chrome 的下载策略要求真实用户手势，合成点击会被拦截，文件不会落盘。
        # 路径：observe 找 "<文件名> 的更多选项"按钮 → bsk click 展开菜单 →
        #       observe 找 menuitem "下载" → bsk click 触发下载。
        MORE=$("${BSK[@]}" observe --session "$SESSION_ID" 2>&1 | grep -m1 "button \"${fname} 的更多选项" | sed -E 's/^.*(@e[0-9]+).*$/\1/')
        if [ -z "$MORE" ]; then
          echo "  ⚠ 未找到"更多选项"按钮: ${fname}"
          continue
        fi
        "${BSK[@]}" click --session "$SESSION_ID" "$MORE" >/dev/null 2>&1
        sleep 2
        # 菜单项文本实测是"下载原始文件"（早期调试输出曾把文本截断成"下载"，勿按"下载"精确匹配）
        # 注意：BSD grep（macOS）不支持 -m1E 连写（会把"1E"当作 -m 的参数报 Invalid argument），必须分开写 -m1 -E
        DL=$("${BSK[@]}" observe --session "$SESSION_ID" 2>&1 | grep -m1 -E 'menuitem "[^"]*下载' | sed -E 's/^.*(@e[0-9]+).*$/\1/')
        if [ -z "$DL" ]; then
          echo "  ⚠ 未找到"下载"菜单项: ${fname}"
          continue
        fi
        "${BSK[@]}" click --session "$SESSION_ID" "$DL" >/dev/null 2>&1
        # 下载落盘有延迟（实测 5-10 秒），固定 sleep 容易误判为失败，改为轮询
        ok=""
        for _i in $(seq 1 8); do
          sleep 2
          if [ -f "$HOME/Downloads/${fname}" ]; then ok=1; break; fi
        done
        if [ -n "$ok" ]; then
          echo "  已下载: ${fname}"
        else
          echo "  ⚠ 已触发下载但 ${fname} 未出现在 ~/Downloads"
        fi
      done 4< "$FDTMP"
      rm -f "$FDTMP"
    fi
  fi
  echo ""
done 3< "$TMP"

rm -f "$TMP"
