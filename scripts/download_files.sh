#!/usr/bin/env bash
#
# Download a list of Blackboard Ultra course files via the browser-skill (bsk) backend.
#
# Usage:
#   ./download_files.sh <courseId> <sessionId> [host] <<'EOF'
#   _7420435_1	EAA Lecture 2 and 3 No sol.pdf
#   _7420393_1	EAA R Questions 1.pdf
#   EOF
#
#   <courseId>   the numeric Blackboard course id, e.g. _234567_1
#   <sessionId>  the active bsk session id (from `bsk session start --json`)
#   [host]       optional Blackboard host, default blackboard.cuhk.edu.hk
#
# Each input line is "<fileId><TAB><filename>". The fileId is the part after
# /file/ in a file link, e.g. _7420435_1.
#
# Requirements:
#   - bsk CLI on PATH, daemon running, session started, user logged in.
#   - BSK_HOME exported if the daemon uses a custom home (e.g. /tmp/bsk_home on macOS).
#
# Output: one status line per file ("OK", "NOIFRAME", or "NODOWNLOAD").
# Files land in the browser's default download directory (~/Downloads).

set -u

COURSE_ID="${1:?usage: download_files.sh <courseId> <sessionId> [host]}"
SESSION_ID="${2:?missing sessionId}"
HOST="${3:-blackboard.cuhk.edu.hk}"

# Reusable env prefix for bsk. Keep BSK_HOME/BSK_AUTO_START if already exported.
# 环境变量默认值：macOS 上 daemon 的 state 目录固定放 /tmp（沙箱限制下 ~/.bsk 写入会失败）。
# 脚本自带默认值，不依赖调用者先 export，避免"静默扫到 0 项"。
: "${BSK_HOME:=/tmp/bsk_home}"
: "${BSK_AUTO_START:=0}"
export BSK_HOME BSK_AUTO_START

BSK=(bsk)
[ -n "${BSK_HOME:-}" ] && BSK=(env BSK_HOME="$BSK_HOME" bsk)
[ -n "${BSK_AUTO_START:-}" ] && BSK=(env BSK_HOME="${BSK_HOME:-}" BSK_AUTO_START="$BSK_AUTO_START" bsk)

dl_one() {
  local fid="$1" name="$2"
  local preview="https://${HOST}/ultra/courses/${COURSE_ID}/file/${fid}?courseId=${COURSE_ID}"

  "${BSK[@]}" navigate "$preview" --session "$SESSION_ID" --timeout 20s >/dev/null 2>&1
  sleep 8

  local src
  src=$("${BSK[@]}" evaluate --session "$SESSION_ID" \
    "Array.from(document.querySelectorAll('iframe')).map(f=>f.src).find(s=>s.includes('bbcswebdav'))||''" 2>&1 \
    | grep -oE 'https://[^"?]*bbcswebdav[^"?]*' | head -1)

  if [ -z "$src" ]; then
    echo "NOIFRAME  $name"
    return 1
  fi

  local dl="${src}?xythos-download=true"
  "${BSK[@]}" navigate "$dl" --session "$SESSION_ID" --timeout 15s >/dev/null 2>&1
  sleep 2
  echo "OK  $name"
}

# Read "<fileId><TAB><name>" lines from stdin.
while IFS=$'\t' read -r fid name; do
  [ -z "$fid" ] && continue
  dl_one "$fid" "$name"
done
