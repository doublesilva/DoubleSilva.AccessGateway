"""Prova de consistência do snapshot sob escrita concorrente.

Um processo escritor executa transações sem parar, cada uma mantendo o invariante
    COUNT(a) == COUNT(b) == contador.n
(insere uma linha em `a`, uma em `b` e incrementa o contador). Em paralelo, o snapshot é tirado N vezes.
Cada snapshot precisa ter integrity_check ok, o invariante intacto e contagens iguais às do manifesto; e o escritor
precisa ter avançado entre os snapshots (prova de concorrência real). Testa journal_mode DELETE (o do Authelia em
produção) e, por robustez, WAL com a origem gravável.

Uso: python stress_test.py [--rounds 30]
"""
import argparse
import multiprocessing as mp
import os
import sqlite3
import sys
import tempfile
import time

sys.path.insert(0, "/app")
from authelia_snapshot import snapshot  # noqa: E402


def writer(path, stop, progress):
    conn = sqlite3.connect(path, timeout=10, isolation_level=None)
    payload = os.urandom(512).hex()
    i = 0
    while not stop.is_set():
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("INSERT INTO a(payload) VALUES (?)", (payload,))
        conn.execute("INSERT INTO b(a_id) VALUES (last_insert_rowid())")
        conn.execute("UPDATE contador SET n = n + 1")
        conn.execute("COMMIT")
        i += 1
        progress.value = i
    conn.close()


def check_snapshot(path, manifest):
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        a = conn.execute("SELECT COUNT(*) FROM a").fetchone()[0]
        b = conn.execute("SELECT COUNT(*) FROM b").fetchone()[0]
        n = conn.execute("SELECT n FROM contador").fetchone()[0]
        integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    finally:
        conn.close()
    assert integrity == "ok", integrity
    assert a == b == n, f"invariante violado: a={a} b={b} n={n}"
    assert manifest["row_counts"]["a"] == a, "manifesto diverge do arquivo"
    return a


def run(mode, rounds):
    work = tempfile.mkdtemp(prefix=f"snap-{mode}-")
    src_dir, dst_dir = os.path.join(work, "src"), os.path.join(work, "dst")
    os.makedirs(src_dir)
    os.makedirs(dst_dir)
    db = os.path.join(src_dir, "db.sqlite3")
    conn = sqlite3.connect(db, isolation_level=None)
    conn.execute(f"PRAGMA journal_mode={mode}")
    conn.executescript("""
        CREATE TABLE a (id INTEGER PRIMARY KEY, payload TEXT NOT NULL);
        CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER NOT NULL REFERENCES a(id));
        CREATE TABLE contador (n INTEGER NOT NULL);
        INSERT INTO contador VALUES (0);
        CREATE TABLE migrations (id INTEGER PRIMARY KEY, version_before INTEGER, version_after INTEGER);
        INSERT INTO migrations(version_before, version_after) VALUES (0, 19);
    """)
    conn.close()

    stop, progress = mp.Event(), mp.Value("q", 0)
    proc = mp.Process(target=writer, args=(db, stop, progress), daemon=True)
    proc.start()
    while progress.value < 200:                      # banco com volume antes de começar
        time.sleep(0.01)

    seen, writes = [], []
    try:
        for i in range(rounds):
            before = progress.value
            manifest = snapshot_any(db, dst_dir, f"s{i:03d}.sqlite3", mode)
            rows = check_snapshot(os.path.join(dst_dir, f"s{i:03d}.sqlite3"), manifest)
            seen.append(rows)
            writes.append(progress.value - before)
            time.sleep(0.02)
    finally:
        stop.set()
        proc.join(10)

    assert all(x <= y for x, y in zip(seen, seen[1:])), "snapshots fora de ordem"
    assert sum(1 for w in writes if w > 0) >= rounds // 2, "escritor não avançou durante os snapshots"
    return f"{mode}: {rounds} snapshots ok, linhas {seen[0]}→{seen[-1]}, {progress.value} transações concorrentes"


def snapshot_any(db, dst_dir, name, mode):
    if mode != "wal":
        return snapshot(db, dst_dir, name)
    # WAL: mesma função, sem a recusa de -wal (só para o teste de robustez).
    import authelia_snapshot as s
    original = os.path.exists
    try:
        s.os.path.exists = lambda p: False if p.endswith("-wal") else original(p)
        return s.snapshot(db, dst_dir, name)
    finally:
        s.os.path.exists = original


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=30)
    args = parser.parse_args()
    results = [run("delete", args.rounds), run("wal", max(5, args.rounds // 3))]
    for r in results:
        print(r)
    print(f"{args.rounds} snapshots DELETE + WAL consistentes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
