#!/usr/bin/env bash
#
# doctor.sh — 环境自检：逐项检查本Skill的运行条件，并给出明确的修复建议。
#
# 用法: ./doctor.sh [--config <path>]
#
# 检查项:
#   1. bsk CLI 是否安装
#   2. daemon 是否在运行、浏览器扩展是否连接、协议版本是否一致
#   3. config.json 是否存在、JSON 是否合法、archive_root 是否可写、
#      course_ids 是否已换成真实课程ID
#   4. 凭据方式（环境变量 / 交互式）
#
# 退出码: 0 = 无失败项（警告不算失败）；1 = 有失败项。
# 本脚本只读检查，不修改任何东西（最多创建/验证目录可写性）。

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="$(cd "$DIR/.." && pwd)"
CONFIG="$BASE/config.json"
[ "${1:-}" = "--config" ] && CONFIG="${2:-$CONFIG}"

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); printf "  [OK]   %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  [FAIL] %s\n" "$1"; }
warn() { WARN=$((WARN+1)); printf "  [WARN] %s\n" "$1"; }

echo "== 1. bsk CLI =="
if command -v bsk >/dev/null 2>&1; then
  ok "bsk 已安装: $(bsk --version 2>/dev/null | head -1)"
else
  bad "未找到 bsk（本技能不能独立运行，bsk 是硬依赖）。安装: curl -fsSL https://raw.githubusercontent.com/Tencent/BrowserSkill/main/install.sh | sh"
  warn "同时确认你的客户端里有 browser-skill 技能（WorkBuddy 通常内置；没有则从技能市场安装）"
fi

echo "== 2. daemon 与浏览器扩展 =="
export BSK_HOME="${BSK_HOME:-/tmp/bsk_home}" BSK_AUTO_START="${BSK_AUTO_START:-0}"
if bsk status --json >/dev/null 2>&1; then
  ok "daemon 已在运行"
  if bsk browsers --json 2>/dev/null | grep -q '"instance_id"'; then
    ok "浏览器扩展已连接"
    if bsk browsers --json 2>/dev/null | grep -qE '"version_skew":\s*true'; then
      warn "CLI 与扩展协议版本不一致（version_skew=true），扩展会静默连不上——对齐版本"
    else
      ok "协议版本一致"
    fi
  else
    warn "扩展未连接。打开 Chrome，点击工具栏 BrowserSkill 图标，等弹窗显示 connected"
  fi
else
  warn "daemon 未运行。用 scripts/start_session.sh 一键启动"
fi

echo "== 3. 配置文件 =="
if [ -f "$CONFIG" ]; then
  ok "找到配置: $CONFIG"
  if python3 -c "import json;json.load(open('$CONFIG'))" 2>/dev/null; then
    ok "JSON 格式合法"
    ROOT=$(python3 -c "import json,os;print(os.path.expanduser(json.load(open('$CONFIG')).get('archive_root','')))" 2>/dev/null)
    if [ -z "$ROOT" ]; then
      warn "archive_root 未配置"
    elif [ -d "$ROOT" ]; then
      [ -w "$ROOT" ] && ok "归档根目录可写: $ROOT" || bad "归档根目录不可写: $ROOT"
    else
      P=$(dirname "$ROOT")
      [ -w "$P" ] && ok "归档根目录尚不存在，但可创建: $ROOT" || bad "归档根目录不存在且父目录不可写: $ROOT"
    fi
    IDS=$(python3 -c "import json;print(len(json.load(open('$CONFIG')).get('course_ids',{})))" 2>/dev/null)
    if [ "${IDS:-0}" -gt 0 ] 2>/dev/null; then
      if python3 -c "import json,sys;v=list(json.load(open('$CONFIG')).get('course_ids',{}).values());sys.exit(0 if any(x=='_000000_1' for x in v) else 1)"; then
        warn "course_ids 里还有 _000000_1 占位符，请换成真实课程ID（看课程页地址栏 /ultra/courses/_xxx_1）"
      else
        ok "course_ids 已配置 $IDS 门课且无占位符"
      fi
    else
      warn "course_ids 为空（scan_all_courses.sh 不可用；逐门课跑不受影响）"
    fi
  else
    bad "config.json 不是合法 JSON——检查逗号/引号"
  fi
else
  warn "未找到 config.json。执行: cp \"$BASE/config.example.json\" \"$CONFIG\" 后按自己的课程修改"
fi

echo "== 4. 凭据方式 =="
if [ -n "${BLACKBOARD_USER:-}" ]; then
  ok "BLACKBOARD_USER 已设置"
  if [ -n "${BLACKBOARD_PASS:-}" ]; then
    warn "BLACKBOARD_PASS 在环境里（会留在进程环境与 shell 历史，建议改用 login.sh 的交互式输入）"
  else
    ok "密码走交互式输入（推荐）"
  fi
else
  warn "BLACKBOARD_USER 未设置（login.sh 运行时会交互式询问）"
fi

echo
echo "结果: $PASS 通过 / $WARN 警告 / $FAIL 失败"
[ "$FAIL" -eq 0 ]
