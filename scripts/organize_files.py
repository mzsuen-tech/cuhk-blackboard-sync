#!/usr/bin/env python3
"""organize_files.py — 按配置分类归档已下载的课件，支持增量同步（跳过重复）。

用法:
  organize_files.py --config config.json --course ECON5022 [文件名...]
  organize_files.py --config config.json --course ECON5022 < 文件列表.txt

参数:
  --config config.json   归档配置（含 courses 映射 + rules 分类规则）
  --course CODE          Blackboard 课程代码（如 ECON5022）
  --download-dir DIR     课件下载目录（默认 ~/Downloads）
  --dry-run              只打印将要执行的动作，不实际移动
  文件名列表              作为位置参数传入，或从 stdin 逐行读入

增量逻辑:
  目标归档目录下若已存在"同大小 + 同扩展名"的文件，视为重复，跳过不覆盖。
  这样用户已手动整理/重命名的文件（如 EAA with sol.pdf -> EAA Lecture 1 with
  solutions.pdf）不会被重复归档。

仅依赖 Python 标准库。
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys


def expand(path: str) -> str:
    return os.path.expanduser(path)


def load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def classify(name: str, rules: list, fallback: str) -> str:
    """按顺序匹配 rules（关键词或扩展名），命中即返回对应 folder。"""
    low = name.lower()
    for rule in rules:
        folder = rule["folder"]
        keywords = rule.get("keywords", [])
        extensions = rule.get("extensions", [])
        if any(k in low for k in keywords):
            return folder
        if any(low.endswith(e.lower()) for e in extensions):
            return folder
    return fallback


def strip_collision_suffix(name: str) -> str:
    """去掉 Chrome 下载重名时追加的 ' (1)' 后缀。"""
    stem, ext = os.path.splitext(name)
    m = re.match(r"^(.*) \(\d+\)$", stem)
    if m:
        return m.group(1) + ext
    return name


def file_md5(path: str, chunk: int = 8192) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def find_duplicate(course_root: str, src_path: str, ext: str):
    """在课程归档目录下递归查找内容相同的文件（同扩展名 + 同大小 + 同 MD5）。

    返回其路径或 None。用 MD5 确认，避免"不同文件恰好同大小"被误判为重复。
    """
    if not os.path.isdir(course_root):
        return None
    size = os.path.getsize(src_path)
    src_hash = file_md5(src_path)
    for root, _dirs, files in os.walk(course_root):
        for f in files:
            if f.lower().endswith(ext.lower()):
                fp = os.path.join(root, f)
                try:
                    if os.path.getsize(fp) == size and file_md5(fp) == src_hash:
                        return fp
                except OSError:
                    continue
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", required=True, help="归档配置文件路径")
    ap.add_argument("--course", required=True, help="Blackboard 课程代码")
    ap.add_argument("--download-dir", default="~/Downloads")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("files", nargs="*", help="文件名（也可从 stdin 逐行读入）")
    args = ap.parse_args()

    cfg = load_config(args.config)
    archive_root = expand(cfg["archive_root"])
    course_map = cfg.get("courses", {})
    course_dir_name = course_map.get(args.course, args.course)
    course_root = os.path.join(archive_root, course_dir_name)
    rules = cfg.get("rules", [])
    fallback = cfg.get("fallback_folder", "其他")
    dl_dir = expand(args.download_dir)

    files = args.files
    if not files:
        files = [line.strip() for line in sys.stdin if line.strip()]

    for name in files:
        src = os.path.join(dl_dir, name)
        if not os.path.isfile(src):
            print(f"MISSING  {name}")
            continue

        clean = strip_collision_suffix(name)
        folder = classify(clean, rules, fallback)
        dest_dir = os.path.join(course_root, folder)
        dest = os.path.join(dest_dir, clean)
        ext = os.path.splitext(clean)[1]

        dup = find_duplicate(course_root, src, ext)
        if dup:
            print(f"DUP      {name}  (已有 {os.path.relpath(dup, course_root)})")
            continue

        rel = os.path.relpath(dest, archive_root)
        if args.dry_run:
            print(f"WOULD    {name} -> {rel}")
        else:
            os.makedirs(dest_dir, exist_ok=True)
            shutil.move(src, dest)
            print(f"MOVED    {name} -> {rel}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
