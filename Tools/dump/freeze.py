#!/usr/bin/env python3
"""建冻结数据集：cc-switch 库的 `.backup` 快照 + 抽样的 Claude / Oh My Pi 会话日志。

用法：python3 Tools/dump/freeze.py <输出目录>

全程只读 ~/.cc-switch、~/.claude/projects、~/.omp/agent/sessions，所有东西写进 <输出目录>。
输出目录里是真实对话日志和用量，**绝不能进仓库**（放临时目录）。

库快照按 session_log_sync 三态（见 SessionOverlay.SyncCursor）派生几个变体，让游标的每条分支都被走到：
  live        原样（只把路径改成冻结目录），B / C 态并存
  byteNull    字节游标全清成 NULL，一半已消化文件改成「行号只到一半、mtime 比游标新」——B 态续读
  noByteCol   整列删掉——A 态（schema < 18）
  byteZero    字节游标全写 0——C 态的合法 0 不能被当成「没有字节游标」
  byteMid     字节游标落在文件中间（多半是半行）或越界——回看窗口丢半行、越界钳到 EOF
选文件按路径哈希取样，同一份源数据每次选中的相同。
"""
import hashlib
import os
import shutil
import sqlite3
import subprocess
import sys

HOME = os.path.expanduser("~")
DB = f"{HOME}/.cc-switch/cc-switch.db"
PROJECTS = f"{HOME}/.claude/projects"
OMP = f"{HOME}/.omp/agent/sessions"
MB = 1 << 20


def walk_jsonl(root):
    out = []
    for dirpath, _, names in os.walk(root):
        out += [os.path.join(dirpath, n) for n in names if n.endswith(".jsonl")]
    return out


def stable(path):
    return hashlib.sha256(path.encode()).hexdigest()


def take(paths, count, max_bytes):
    picked = [p for p in sorted(paths, key=stable) if os.path.getsize(p) <= max_bytes]
    return picked[:count]


def copy_tree_file(src, root, dest_root):
    dest = os.path.join(dest_root, os.path.relpath(src, root))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copy2(src, dest)   # copy2 保留纳秒 mtime：游标比较靠它
    return dest


def classify(path, sync):
    rel = path[len(PROJECTS) + 1:]
    layer = "wf" if "/workflows/" in rel else "sub" if "/subagents/" in rel else "main"
    cursor = sync.get(path)
    if cursor is None:
        return layer, "none"
    state = "C" if cursor[2] is not None else "B"
    done = "consumed" if os.stat(path).st_mtime_ns <= cursor[0] else "partial"
    return layer, f"{state}-{done}"


def pick_claude(sync):
    buckets = {}
    for p in walk_jsonl(PROJECTS):
        buckets.setdefault(classify(p, sync), []).append(p)
    quota = {
        ("main", "C-partial"): (33, 12 * MB), ("main", "none"): (40, 12 * MB),
        ("sub", "B-partial"): (5, 12 * MB), ("sub", "none"): (20, 8 * MB),
        ("main", "B-consumed"): (20, 4 * MB), ("main", "C-consumed"): (15, 4 * MB),
        ("sub", "B-consumed"): (15, 2 * MB), ("sub", "C-consumed"): (10, 4 * MB),
        ("wf", "B-consumed"): (15, 2 * MB),
    }
    picked = []
    for key, (count, limit) in quota.items():
        picked += take(buckets.get(key, []), count, limit)
    return picked


def build_variants(out, mapping):
    base = f"{out}/db/live.db"
    # 改路径：只保留抽到的文件的游标，别的文件冻结目录里没有，留着也只是噪音。
    con = sqlite3.connect(base)
    con.execute("CREATE TEMP TABLE keep(old TEXT PRIMARY KEY, new TEXT)")
    con.executemany("INSERT INTO keep VALUES(?,?)", mapping.items())
    con.execute("DELETE FROM session_log_sync WHERE file_path NOT IN (SELECT old FROM keep)")
    con.execute("UPDATE session_log_sync SET file_path=(SELECT new FROM keep WHERE old=file_path)")
    con.commit()
    con.close()

    def variant(name, *statements):
        path = f"{out}/db/{name}.db"
        shutil.copy2(base, path)
        c = sqlite3.connect(path)
        for sql in statements:
            c.execute(sql)
        c.commit()
        c.close()

    variant("byteNull",
            "UPDATE session_log_sync SET last_byte_offset=NULL",
            "UPDATE session_log_sync SET last_modified=last_modified/2, last_line_offset=last_line_offset/2 "
            "WHERE rowid%2=0")
    variant("noByteCol", "ALTER TABLE session_log_sync DROP COLUMN last_byte_offset")
    variant("byteZero",
            "UPDATE session_log_sync SET last_byte_offset=0, last_modified=last_modified/2")
    path = f"{out}/db/byteMid.db"
    shutil.copy2(base, path)
    c = sqlite3.connect(path)
    for rowid, name in c.execute("SELECT rowid, file_path FROM session_log_sync").fetchall():
        size = os.path.getsize(name) if os.path.exists(name) else 0
        offset = size * 3 if rowid % 5 == 0 else size * 2 // 3 + 1
        c.execute("UPDATE session_log_sync SET last_byte_offset=?, last_modified=last_modified/2 WHERE rowid=?",
                  (offset, rowid))
    c.commit()
    c.close()


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = os.path.abspath(sys.argv[1])
    if os.path.exists(out):
        sys.exit(f"{out} 已存在：冻结数据集建好就不再动，要重建先自己删")
    os.makedirs(f"{out}/db")
    subprocess.run(["sqlite3", f"file:{DB}?mode=ro", f".backup '{out}/db/live.db'"], check=True)

    con = sqlite3.connect(f"{out}/db/live.db")
    sync = {r[0]: r[1:] for r in con.execute(
        "SELECT file_path, last_modified, last_line_offset, last_byte_offset FROM session_log_sync")}
    con.close()

    mapping = {}
    for src in pick_claude(sync):
        mapping[src] = copy_tree_file(src, PROJECTS, f"{out}/claude/projects")
    omp = take(walk_jsonl(OMP), 40, 6 * MB)
    for src in omp:
        copy_tree_file(src, OMP, f"{out}/omp/sessions")
    build_variants(out, mapping)

    # 逐 tick 回放用：挑几个真实大文件（新近、不在 session_log_sync 里，回放时按块往临时目录追加）。
    os.makedirs(f"{out}/replay/claude")
    os.makedirs(f"{out}/replay/omp")
    fresh = [p for p in walk_jsonl(PROJECTS) if p not in sync]
    big = sorted([p for p in fresh if 2 * MB <= os.path.getsize(p) <= 24 * MB], key=stable)[:6]
    for i, src in enumerate(big):
        shutil.copy2(src, f"{out}/replay/claude/{i}.jsonl")
    ompbig = sorted([p for p in walk_jsonl(OMP) if MB <= os.path.getsize(p) <= 12 * MB], key=stable)[:4]
    for i, src in enumerate(ompbig):
        shutil.copy2(src, f"{out}/replay/omp/{i}.jsonl")

    total = sum(os.path.getsize(p) for p in walk_jsonl(out))
    print(f"claude {len(mapping)} 个，omp {len(omp)} 个，回放 {len(big)}+{len(ompbig)} 个，共 {total / MB:.0f} MB")


if __name__ == "__main__":
    main()
