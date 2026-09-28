#!/usr/bin/env python3
"""
diff_seen.py — 把"本轮线上枚举结果"与"已见登记表"做差集，算出真正的新增内容。

为什么需要它（2026-09-27 策略调整）：
  用户明确要求**不再做全量 MD5 复校**，只下载新增文件，已下载的一律不管。
  但"新增"必须靠一个稳定基准判断，不能靠文件名（老师在 Blackboard 的显示名与本地
  归档名普遍不同），也不能靠本地 MD5（用户会在归档 PDF 上做高亮/批注，会改 MD5 →
  历史上曾把用户的批注误判成"老师重传"并覆盖掉）。

  因此基准 = 已见登记表 `seen_files.json`：以 Blackboard 的 **fileId / assessmentId**
  为键（这类 id 是稳定且唯一的）。每轮流程：

      ① scan_course_items.sh 枚举（不下载任何东西）
      ② diff_seen.py 比对 → 只输出"新增"
      ③ 只下载新增的那几个
      ④ 归档后 diff_seen.py --commit 登记

  好处：每轮成本从"下载 22 个文件 ≈5 分钟"降到"3 次枚举 ≈1 分钟"，且完全不写
  ~/Downloads、不触碰任何已归档文件。

用法：
  # 只检查，不写任何东西（默认）
  python3 diff_seen.py --registry <seen_files.json> scan1.json scan2.json ...

  # 登记新增项（应在下载+归档成功之后执行）
  python3 diff_seen.py --registry <seen_files.json> --commit scan1.json scan2.json ...

  # 归档完成后回填归档相对路径
  python3 diff_seen.py --registry <seen_files.json> --set-archive _7434387_1=习题/x.pdf

归档根目录（用于判断 MISSING_LOCAL）按以下顺序解析：
  --archive-root  >  --config 里的 archive_root  >  环境变量 BLACKBOARD_ARCHIVE_ROOT
  >  脚本同级 ../config.json 里的 archive_root  >  默认 ~/BlackboardArchive

输出（stdout，供调用方直接读取）：
  NEW_FILES <n> / NEW_ASSESSMENTS <n> / MISSING_LOCAL <n>，随后是各自的明细行。

退出码：0 正常；2 参数或文件问题。
"""

import argparse
import json
import os
import re
import sys
from datetime import date


def norm_items(paths):
    """合并多个 scan_course_items.sh 的输出，按 id 去重。"""
    items = {}
    for p in paths:
        try:
            arr = json.load(open(p, encoding='utf-8'))
        except Exception as e:
            sys.stderr.write(f'无法读取扫描结果 {p}: {e}\n')
            sys.exit(2)
        if not isinstance(arr, list):
            continue
        for x in arr:
            h = (x.get('h') or '').strip()
            m_course = re.search(r'/courses/(_[^/]+)/', h)
            course = m_course.group(1) if m_course else None
            # 显示名形如 "PDF，Lecture II" → 去掉类型前缀
            disp = re.split(r'[，,]', (x.get('t') or '').strip(), maxsplit=1)[-1].strip()
            fid = None
            if '/file/' in h:
                fid = h.split('/file/')[-1].split('?')[0].split('/')[0]
                key = ('file', fid)
            elif '/assessment/' in h:
                fid = h.split('/assessment/')[-1].split('/')[0]
                key = ('assessment', fid)
            else:
                continue
            if not fid or not course:
                continue
            items[key] = {
                'id': fid, 'course': course, 'display': disp,
                'kind': key[0], 'url': h,
            }
    return items


def resolve_archive_root(args):
    """按 参数 > 环境变量 > config.json > 默认值 的顺序确定归档根目录。"""
    if args.archive_root:
        return os.path.expanduser(args.archive_root)

    cfg_path = args.config
    if cfg_path is None:
        sibling = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               os.pardir, 'config.json')
        if os.path.exists(sibling):
            cfg_path = sibling
    if cfg_path:
        try:
            cfg = json.load(open(os.path.expanduser(cfg_path), encoding='utf-8'))
            if cfg.get('archive_root'):
                return os.path.expanduser(cfg['archive_root'])
        except Exception:
            pass

    env = os.environ.get('BLACKBOARD_ARCHIVE_ROOT')
    if env:
        return os.path.expanduser(env)
    return os.path.expanduser('~/BlackboardArchive')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--registry', required=True, help='seen_files.json 路径')
    ap.add_argument('--config', default=None,
                    help='config.json 路径（用于读取 archive_root；缺省会自动找脚本同级的 ../config.json）')
    ap.add_argument('--archive-root', default=None,
                    help='直接指定归档根目录，优先级最高')
    ap.add_argument('--commit', action='store_true', help='把新增项登记进登记表')
    ap.add_argument('--set-archive', action='append', default=[],
                    metavar='ID=相对路径', help='回填某 fileId 的归档相对路径，可重复')
    ap.add_argument('--today', default=None, help='覆盖登记日期（YYYY-MM-DD）')
    ap.add_argument('scans', nargs='*', help='scan_course_items.sh 输出的 JSON 文件')
    args = ap.parse_args()

    today = args.today or date.today().isoformat()
    reg_path = os.path.expanduser(args.registry)
    reg = json.load(open(reg_path, encoding='utf-8')) if os.path.exists(reg_path) else {}
    reg.setdefault('files', {})
    reg.setdefault('assessments', {})
    reg.setdefault('courses', {})
    archive_root = resolve_archive_root(args)

    changed = False

    # --- 回填归档路径 ---
    for pair in args.set_archive:
        if '=' not in pair:
            sys.stderr.write(f'--set-archive 需要 ID=相对路径 形式，收到: {pair}\n')
            sys.exit(2)
        fid, rel = pair.split('=', 1)
        entry = reg['files'].get(fid)
        if entry is None:
            sys.stderr.write(f'警告：{fid} 不在登记表中，跳过回填\n')
            continue
        entry['archive_rel'] = rel
        entry['local_exists'] = os.path.exists(os.path.join(
            archive_root, reg['courses'].get(entry.get('course'), {}).get('archive', ''), rel))
        changed = True

    if args.scans:
        items = norm_items(args.scans)

        new_files = [v for k, v in items.items()
                     if k[0] == 'file' and v['id'] not in reg['files']]
        new_assess = [v for k, v in items.items()
                      if k[0] == 'assessment' and v['id'] not in reg['assessments']]

        # 登记表里有、但本地归档文件已不在（被移动/删除）→ 需要补下
        missing_local = []
        for fid, e in reg['files'].items():
            rel = e.get('archive_rel')
            course = reg['courses'].get(e.get('course'), {})
            if not rel or not course.get('archive'):
                continue
            p = os.path.join(archive_root, course['archive'], rel)
            e['local_exists'] = os.path.exists(p)
            if not e['local_exists']:
                missing_local.append((fid, e))

        print(f'NEW_FILES {len(new_files)}')
        for v in sorted(new_files, key=lambda x: x['id']):
            print(f"  {v['id']}\t{v['course']}\t{v['display']}\t{v['url']}")

        print(f'NEW_ASSESSMENTS {len(new_assess)}')
        for v in sorted(new_assess, key=lambda x: x['id']):
            print(f"  {v['id']}\t{v['course']}\t{v['display']}\t{v['url']}")

        print(f'MISSING_LOCAL {len(missing_local)}')
        for fid, e in sorted(missing_local):
            print(f"  {fid}\t{e.get('archive_rel')}\t{e.get('display')}")

        print(f'SEEN_TOTAL {len(reg["files"])} 线上文件条目 / '
              f'{len(reg["assessments"])} 评估项条目')

        if args.commit:
            for v in new_files:
                reg['files'][v['id']] = {
                    'course': v['course'], 'display': v['display'],
                    'archive_rel': None, 'local_exists': False,
                    'first_seen': today,
                }
                changed = True
            for v in new_assess:
                reg['assessments'][v['id']] = {
                    'course': v['course'], 'display': v['display'],
                    'due': None, 'first_seen': today,
                }
                changed = True
            print(f'COMMITTED {len(new_files)} 个文件 + {len(new_assess)} 个评估项')

    if changed:
        reg['updated'] = today
        with open(reg_path, 'w', encoding='utf-8') as f:
            json.dump(reg, f, ensure_ascii=False, indent=1)
        print(f'REGISTRY_WRITTEN {reg_path}')

    return 0


if __name__ == '__main__':
    sys.exit(main())
