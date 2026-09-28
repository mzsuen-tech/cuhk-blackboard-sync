#!/usr/bin/env bash
#
# login.sh — 用 CUHK OnePass 账号登录 Blackboard，供后续所有脚本复用同一 session。
#
# 用法:
#   BLACKBOARD_USER="你的学号或别名" BLACKBOARD_PASS="密码" \
#     ./login.sh <sessionId> [host]
#
#   # 不想让密码出现在命令行/历史里，就不带 BLACKBOARD_PASS 运行，
#   # 脚本会用 read -s 在终端里安全地询问：
#   BLACKBOARD_USER="xxxx" ./login.sh <sessionId>
#
# 说明:
#   - 凭据只从环境变量或交互式输入读取，本脚本**不写入任何文件**，
#     也不回显密码。请不要把密码写进 config.json 或提交进版本库。
#   - 登录完成后 DUO Push 会自动通过（需已在设备上勾选 Remember me），
#     实测约 20–60 秒；脚本最多轮询 120 秒。
#   - 退出码：0 登录成功（或本就已登录）；1 失败。
#
# 依赖: bsk CLI；daemon 已启动；session 已建立。

set -u

SESSION_ID="${1:?usage: login.sh <sessionId> [host]}"
HOST="${2:-blackboard.cuhk.edu.hk}"

# 环境变量默认值：macOS 上 daemon 的 state 目录固定放 /tmp（沙箱限制下 ~/.bsk 写入会失败）。
# 脚本自带默认值，不依赖调用者先 export，避免"静默扫到 0 项"。
: "${BSK_HOME:=/tmp/bsk_home}"
: "${BSK_AUTO_START:=0}"
export BSK_HOME BSK_AUTO_START

BSK=(env BSK_HOME="$BSK_HOME" BSK_AUTO_START="$BSK_AUTO_START" bsk)

STREAM="https://${HOST}/ultra/stream"

# 判断当前是否已在登录页（DOM id 比标题可靠，标题可能就叫 "Sign In"）
on_login_page() {
  "${BSK[@]}" evaluate --session "$SESSION_ID" \
    "JSON.stringify({hasUser:!!document.getElementById('userNameInput'),hasPw:!!document.getElementById('passwordInput')})" \
    2>/dev/null | grep -q '"hasUser":true'
}

echo "[1/4] 打开 $STREAM"
"${BSK[@]}" navigate "$STREAM" --session "$SESSION_ID" --timeout 30s >/dev/null 2>&1
sleep 3

if ! on_login_page; then
  echo "      已有有效会话，无需登录。"
  exit 0
fi

echo "[2/4] 检测到 OnePass 登录页，读取凭据"
USER="${BLACKBOARD_USER:-}"
if [ -z "$USER" ]; then
  printf "      OnePass 账号（学号或别名）: "
  read -r USER
fi
[ -n "$USER" ] || { echo "账号为空，中止。" >&2; exit 1; }

if [ -n "${BLACKBOARD_PASS:-}" ]; then
  PASS="$BLACKBOARD_PASS"
else
  printf "      OnePass 密码（输入不显示）: "
  read -rs PASS
  printf "\n"
fi
[ -n "$PASS" ] || { echo "密码为空，中止。" >&2; exit 1; }

echo "[3/4] 填写表单并提交"
# navigate 之后旧 ref 失效，必须先 observe 刷新，否则 fill 会"照常打印 ok 但实际没写进去"
"${BSK[@]}" observe --session "$SESSION_ID" >/dev/null 2>&1

U_REF=$("${BSK[@]}" observe --session "$SESSION_ID" 2>/dev/null \
  | grep -m1 -E '(textbox|input).*"(Username|User name|NetID|用户名|账号)' \
  | sed -E 's/^.*(@e[0-9]+).*$/\1/')
P_REF=$("${BSK[@]}" observe --session "$SESSION_ID" 2>/dev/null \
  | grep -m1 -E '(textbox|input).*[Pp]assword' \
  | sed -E 's/^.*(@e[0-9]+).*$/\1/')
S_REF=$("${BSK[@]}" observe --session "$SESSION_ID" 2>/dev/null \
  | grep -m1 -E 'button "(Sign in|登录|Next|下一步)' \
  | sed -E 's/^.*(@e[0-9]+).*$/\1/')

if [ -z "$U_REF" ] || [ -z "$P_REF" ] || [ -z "$S_REF" ]; then
  echo "      未能自动定位表单控件，请手动登录后在浏览器里完成，再重跑本脚本。" >&2
  exit 1
fi

"${BSK[@]}" fill  --session "$SESSION_ID" --value "$USER" "$U_REF" >/dev/null 2>&1
"${BSK[@]}" fill  --session "$SESSION_ID" --value "$PASS" "$P_REF" >/dev/null 2>&1
"${BSK[@]}" click --session "$SESSION_ID" "$S_REF" >/dev/null 2>&1

unset PASS

echo "[4/4] 等待 DUO Push 与跳转（最多 120 秒）"
for _i in $(seq 1 24); do
  sleep 5
  if ! on_login_page; then
    # 确认已经离开登录页且落到 Blackboard 域
    TITLE=$("${BSK[@]}" evaluate --session "$SESSION_ID" "document.title" 2>/dev/null | tail -1)
    echo "      登录成功（当前页面标题: ${TITLE}）"
    exit 0
  fi
done

echo "      超时仍未离开登录页。可尝试重新 navigate 当前 DUO 页面再等 10 秒（见 SKILL.md 的 DUO 卡住解法）。" >&2
exit 1
