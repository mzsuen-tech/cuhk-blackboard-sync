#!/usr/bin/env bash
#
# stop_session.sh — 停止指定会话与 daemon，清理 Blackboard 抓取环境。
#
# 用法: ./stop_session.sh [sessionId]
#   有 sessionId 先停止该会话；随后无论成败都会停 daemon。
#   session stop 偶发报 timed out，只要 daemon 停掉、无残留进程即视为成功。

set -u

export BSK_HOME=/tmp/bsk_home BSK_AUTO_START=0

if [ -n "${1:-}" ]; then
  bsk session stop "$1" 2>/dev/null | tail -1
fi

bsk daemon stop 2>/dev/null | tail -1
sleep 1

if pgrep -f "bsk daemon" >/dev/null; then
  echo "警告：daemon 仍在运行，可手动执行 pkill -f 'bsk daemon'" >&2
  exit 1
fi
echo "环境已清理"
