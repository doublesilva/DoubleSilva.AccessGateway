"""Auxiliar do teste de concorrência (tests/sqlite-concurrency-test.sh).

  init   <db> <wal|delete>   cria o banco com o invariante COUNT(a) == COUNT(b) == contador.n
  writer <db> <segundos>     escreve transações sem parar por N segundos (outro container, montagem rw)
  check  <snapshot>          valida integrity_check e o invariante no snapshot (imprime as linhas)
"""
import os
import sqlite3
import sys
import time


def init(db, mode):
    conn = sqlite3.connect(db, isolation_level=None)
    conn.execute(f"PRAGMA journal_mode={mode}")
    conn.executescript("""
        CREATE TABLE a (id INTEGER PRIMARY KEY, payload TEXT NOT NULL);
        CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER NOT NULL REFERENCES a(id));
        CREATE TABLE contador (n INTEGER NOT NULL);
        INSERT INTO contador VALUES (0);
    """)
    conn.close()


def writer(db, seconds):
    conn = sqlite3.connect(db, timeout=30, isolation_level=None)
    payload = os.urandom(256).hex()
    end = time.time() + seconds
    n = 0
    while time.time() < end:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("INSERT INTO a(payload) VALUES (?)", (payload,))
        conn.execute("INSERT INTO b(a_id) VALUES (last_insert_rowid())")
        conn.execute("UPDATE contador SET n = n + 1")
        conn.execute("COMMIT")
        n += 1
    conn.close()
    print(n)


def check(snapshot):
    conn = sqlite3.connect(f"file:{snapshot}?mode=ro", uri=True)
    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    a = conn.execute("SELECT COUNT(*) FROM a").fetchone()[0]
    b = conn.execute("SELECT COUNT(*) FROM b").fetchone()[0]
    n = conn.execute("SELECT n FROM contador").fetchone()[0]
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    conn.close()
    if integrity != "ok" or not (a == b == n) or mode != "delete":
        print(f"INCONSISTENTE integrity={integrity} a={a} b={b} n={n} journal={mode}")
        return 1
    print(a)
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "init":
        init(sys.argv[2], sys.argv[3])
    elif cmd == "writer":
        writer(sys.argv[2], float(sys.argv[3]))
    elif cmd == "check":
        sys.exit(check(sys.argv[2]))
