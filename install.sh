#!/usr/bin/env bash
#
# install.sh — 把本Skill安装到Agent客户端的skills目录。
#
# 用法:
#   ./install.sh                          # 默认装到 ~/.workbuddy/skills/
#   ./install.sh ~/.claude/skills         # 指定其它skills目录
#
# 行为:
#   - 复制 SKILL.md / scripts / references / config.example.json
#   - 已存在的 config.json **不会被覆盖**（避免破坏你已有的课程配置）
#   - 已存在的同名Skill目录会先备份为 <目录>.bak.<时间戳>

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
SKILL_NAME="blackboard-course-download"
DEST_ROOT="${1:-$HOME/.workbuddy/skills}"
DEST="$DEST_ROOT/$SKILL_NAME"

echo "源目录:   $SRC"
echo "目标目录: $DEST"
echo

if [ ! -d "$DEST_ROOT" ]; then
  echo "创建 $DEST_ROOT"
  mkdir -p "$DEST_ROOT"
fi

if [ -d "$DEST" ]; then
  BAK="${DEST}.bak.$(date +%Y%m%d-%H%M%S)"
  echo "目标已存在，备份为 $(basename "$BAK")"
  mv "$DEST" "$BAK"
  # 把旧配置带过来，避免用户重配一次
  if [ -f "$BAK/config.json" ]; then
    echo "检测到已有的 config.json，将保留它"
    KEEP_CONFIG="$BAK/config.json"
  fi
fi

mkdir -p "$DEST"
cp "$SRC/SKILL.md" "$SRC/config.example.json" "$DEST/"
cp -R "$SRC/scripts" "$SRC/references" "$DEST/"
chmod +x "$DEST"/scripts/*.sh

if [ -n "${KEEP_CONFIG:-}" ]; then
  cp "$KEEP_CONFIG" "$DEST/config.json"
  echo "已恢复 config.json"
elif [ -f "$SRC/config.json" ]; then
  cp "$SRC/config.json" "$DEST/config.json"
  echo "已复制现有 config.json"
else
  echo "提示: 还没有 config.json，请执行 cp \"$DEST/config.example.json\" \"$DEST/config.json\" 后按自己的课程修改"
fi

echo
echo "安装完成。重启Agent客户端后本Skill即生效。"
echo
echo "★ 硬性前提提醒：本Skill不能独立运行，还需要 browser-skill（① browser-skill技能"
echo "  （WorkBuddy通常内置）② bsk CLI ③ Chrome上的BrowserSkill扩展）。"
echo "  缺哪一项，用 ./scripts/doctor.sh 一跑就知道。"
echo
echo "下一步:"
echo "  1. cd \"$DEST\" && cp config.example.json config.json"
echo "  2. 编辑 config.json，填入你的课程与归档目录"
echo "  3. ./scripts/doctor.sh   # 环境自检"
echo "  4. 对Agent说: 帮我同步一下Blackboard的课件和最新通知"
