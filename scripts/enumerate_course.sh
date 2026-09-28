#!/usr/bin/env bash
#
# enumerate_course.sh — 枚举一门 Blackboard Ultra 课程的全部文件链接。
#
# 用法: ./enumerate_course.sh <sessionId> <courseId> [host]
#   <sessionId>  活动 bsk session id
#   <courseId>   Blackboard 课程内部 id，如 _272226_1
#
# 输出: JSON 数组，每项 {"t": 显示名, "h": 文件预览页 URL}
#
# 关键点：Ultra 的课程内容区是**多层嵌套**且**懒加载**的——
#   1. 只有父文件夹被展开后，子项（含子文件夹）才进入 DOM；
#   2. 一次点击只能展开一层，且点开新的顶层文件夹后旧的会折叠；
#   3. 因此必须**反复**点击所有 aria-expanded=false 的文件夹按钮，直到没有可点的为止。
# 文件夹按钮的选择器是 button[aria-label^="文件夹"]（中文界面）。
# 展开完成后文件才是以 <a href=".../file/_xxx_1?courseId=..."> 形式存在。
#
# 依赖: bsk CLI；daemon 已启动；session 已建立且已登录；BSK_HOME 已 export。

set -u

SESSION_ID="${1:?usage: enumerate_course.sh <sessionId> <courseId> [host]}"
COURSE_ID="${2:?missing courseId}"
HOST="${3:-blackboard.cuhk.edu.hk}"

# 环境变量默认值：macOS 上 daemon 的 state 目录固定放 /tmp（沙箱限制下 ~/.bsk 写入会失败）。
# 脚本自带默认值，不依赖调用者先 export，避免"静默扫到 0 项"。
: "${BSK_HOME:=/tmp/bsk_home}"
: "${BSK_AUTO_START:=0}"
export BSK_HOME BSK_AUTO_START

BSK=(bsk)
[ -n "${BSK_HOME:-}" ] && BSK=(env BSK_HOME="$BSK_HOME" bsk)
[ -n "${BSK_AUTO_START:-}" ] && BSK=(env BSK_HOME="${BSK_HOME:-}" BSK_AUTO_START="$BSK_AUTO_START" bsk)

"${BSK[@]}" navigate "https://${HOST}/ultra/courses/${COURSE_ID}/outline" \
  --session "$SESSION_ID" --timeout 30s >/dev/null 2>&1
sleep 6

# 反复展开所有未展开的文件夹，直到一轮点击数为 0
CLICK_ALL="var bs=Array.from(document.querySelectorAll('button[aria-label^=文件夹]')).filter(b=>b.getAttribute('aria-expanded')=='false'); bs.forEach(b=>b.click()); 'clicked '+bs.length"
for _round in 1 2 3 4 5 6 7 8 9 10 11 12; do
  out=$("${BSK[@]}" evaluate --session "$SESSION_ID" "$CLICK_ALL" 2>&1 | head -1)
  sleep 3
  case "$out" in *"clicked 0"*) break;; esac
done
sleep 3

"${BSK[@]}" evaluate --session "$SESSION_ID" \
  "JSON.stringify(Array.from(document.querySelectorAll('a')).filter(a=>a.href.includes('/file/')).map(a=>({t:(a.getAttribute('aria-label')||a.textContent.trim()),h:a.href})))" 2>&1 | head -1
