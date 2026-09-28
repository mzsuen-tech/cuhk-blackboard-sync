#!/usr/bin/env bash
#
# scan_course_items.sh — 全量扫描一门 Blackboard Ultra 课程的全部内容项目（文件 + 评估 + 其它）。
#
# 用法: ./scan_course_items.sh <sessionId> <courseId> [host]
#   <sessionId>  活动 bsk session id
#   <courseId>   Blackboard 课程内部 id，如 _123456_1
#
# 输出: JSON 数组，每项 {"t": 显示名, "type": file|assessment|other, "h": URL}
#
# ⚠️ 为什么需要这个脚本（血泪教训）：
#   enumerate_course.sh 只保留 href 含 "/file/" 的项，会**静默丢弃** Blackboard 的
#   评估项（小测/作业，href 形如 /ultra/courses/<id>/assessment/_xxx_1/overview）。
#   实测 ECON5012 的 "Quiz 1" 就这样被漏掉过 —— 文件枚举全绿 ≠ 课程没有考试。
#   本脚本保留全部项目并标注 type，确保 quiz / exam / test / assignment 不被吞掉。
#
# 依赖: bsk CLI；daemon 已启动；session 已建立且已登录；BSK_HOME 已 export。

set -u

SESSION_ID="${1:?usage: scan_course_items.sh <sessionId> <courseId> [host]}"
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

# 反复展开所有未展开的文件夹，直到一轮点击数为 0（Ultra 懒加载，且子文件夹多层嵌套）
CLICK_ALL="var bs=Array.from(document.querySelectorAll('button[aria-label^=文件夹]')).filter(b=>b.getAttribute('aria-expanded')=='false'); bs.forEach(b=>b.click()); 'clicked '+bs.length"
for _round in $(seq 1 15); do
  out=$("${BSK[@]}" evaluate --session "$SESSION_ID" "$CLICK_ALL" 2>&1 | head -1)
  sleep 3
  case "$out" in *"clicked 0"*) break;; esac
done
sleep 4

# 抓取 main 区域内**全部**链接，标注 type。排除通知 iframe 等噪声。
"${BSK[@]}" evaluate --session "$SESSION_ID" \
  "JSON.stringify((function(){
    var seen={}, out=[];
    Array.from(document.querySelectorAll('main a[href]')).forEach(function(a){
      var h=a.getAttribute('href')||'';
      if(!h||h.charAt(0)==='#'||/notif|websocket|developer\.blackboard\.com|ltiStorage/i.test(h))return;
      var t=(a.getAttribute('aria-label')||a.textContent||'').replace(/\s+/g,' ').trim().slice(0,90);
      var type = h.indexOf('/assessment/')>-1 ? 'assessment'
               : h.indexOf('/file/')>-1       ? 'file'
               : 'other';
      var k=type+'|'+h;
      if(seen[k])return; seen[k]=1;
      out.push({t:t,type:type,h:h});
    });
    return out;
  })())" 2>&1 | head -1
