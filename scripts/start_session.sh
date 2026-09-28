#!/usr/bin/env bash
#
# start_session.sh — 一键启动 Blackboard 抓取环境：daemon + Chrome + session。
#
# 用法: SID=$(./start_session.sh)
#       输出只有一行 session_id（如 "mwiz"），可直接赋值给变量。
#       失败时向 stderr 输出原因并返回非零。
#
# 说明: 每次 Blackboard 任务都要重复 daemon start → open Chrome →
#       browsers 检查 → session start 四步，本脚本把它们合并。
#       用完后记得调用 stop_session.sh 清理。

set -u

export BSK_HOME=/tmp/bsk_home BSK_AUTO_START=0

rm -rf /tmp/bsk_home
bsk daemon start >/dev/null 2>&1
sleep 3

open -a "Google Chrome" 2>/dev/null
sleep 4

if ! bsk browsers --json 2>/dev/null | grep -q '"instance_id"'; then
  echo "扩展未连接。请确认 Chrome 中 BrowserSkill 扩展已安装并点击扩展图标完成连接。" >&2
  exit 1
fi

SID=$(bsk session start --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['session_id'])" 2>/dev/null)

# session start 偶发超时（尤其刚唤醒 Chrome 后），重试一次
if [ -z "$SID" ]; then
  sleep 2
  SID=$(bsk session start --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['session_id'])" 2>/dev/null)
fi

if [ -z "$SID" ]; then
  echo "session 创建失败（重试后仍超时）。可手动执行 bsk session start 排查。" >&2
  exit 1
fi

echo "$SID"
