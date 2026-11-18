# -*- coding: utf-8 -*-
"""Демо: consistent hashing -> реальное распределение юзеров по двум шардам.

Что делает:
  1. Считает для 12 тестовых юзеров их шард через HashRing (кольцо).
  2. На ОБОИХ шардах создаёт таблицу routing_probe и пишет строку
     ТОЛЬКО в тот шард, куда указало кольцо (INSERT = «api-gateway»).
  3. Выборкой с обоих портов показывает, где кто лежит, и доказывает,
     что юзер из shard1 НЕ виден на shard2 (и наоборот).

Запуск (PowerShell, каталог с hashring.py):
    python routing_demo.py

Порта — МАСТЕРСКИЕ (запись идёт только на мастер). Подставь свои.
После демо: python routing_demo.py --drop   (удалит таблицы-пробы)
"""
import subprocess
import sys

from hashring import HashRing

PSQL = r"D:\Postgre\bin\psql.exe"
# МАСТЕРА шардов (реплики read-only, запись туда невозможна)
PORTS = {"shard1": 5433, "shard2": 6433}
USERS = [f"user_{i}" for i in range(12)]


def psql(port: int, sql: str, tuples_only: bool = False) -> str:
    """Выполнить SQL на порту и вернуть вывод (stderr тоже — для ошибок).
    tuples_only=True -> флаги -tA: только строки результата, без заголовка
    колонки (иначе строка 'user_id' цепляется за фильтр startswith('user_'))."""
    cmd = [PSQL, "-h", "127.0.0.1", "-p", str(port), "-U", "postgres",
           "-d", "postgres"]
    if tuples_only:
        cmd += ["-t", "-A"]
    cmd += ["-c", sql]
    r = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return (r.stdout + r.stderr).strip()


def main() -> None:
    ring = HashRing(list(PORTS))          # КОЛЬЦО: статика, без сети
    drop = "--drop" in sys.argv

    if drop:
        for shard, port in PORTS.items():
            print(f"[{shard}] {psql(port, 'drop table if exists routing_probe;')}")
        return

    # --- 1. Маршруты: только кольцо, БД ещё не участвует -------------
    routes = {u: ring.get(u) for u in USERS}
    print("=== 1. Что говорит кольцо (hashring.py) ===")
    for u, s in routes.items():
        print(f"  {u:8} -> {s}  (порт {PORTS[s]})")

    # --- 2. Запись: как это сделает api-gateway ----------------------
    print("\n=== 2. INSERT через порт, который указало кольцо ===")
    for shard, port in PORTS.items():
        psql(port, "create table if not exists routing_probe "
                   "(user_id text primary key, routed_to text);")
    for u, shard in routes.items():
        port = PORTS[shard]
        psql(port, f"insert into routing_probe (user_id, routed_to) "
                   f"values ('{u}', '{shard}') on conflict do nothing;")
        print(f"  {u:8} -> connect:{port} -> INSERT ... on conflict do nothing")

    # --- 3. Проверка выборкой с обоих шардов -------------------------
    print("\n=== 3. Проверка: SELECT с каждого шарда ===")
    ok = True
    for shard, port in PORTS.items():
        rows = psql(port, "select user_id from routing_probe "
                          f"where routed_to = '{shard}' order by user_id;",
                    tuples_only=True)
        expected = {u for u, s in routes.items() if s == shard}
        got = {l.strip() for l in rows.splitlines() if l.strip()}
        print(f"\n  [{shard}] порт {port}, ждут своё ({len(expected)}): "
              f"{', '.join(sorted(expected))}")
        print(f"  [{shard}] реально лежат        ({len(got)}): "
              f"{', '.join(sorted(got))}")
        # сравниваем как МНОЖЕСТВА: SQL сортирует строково (user_10 между
        # user_1 и user_4), а порядок routes — порядок создания юзеров
        if got != expected:
            ok = False
            print(f"  [{shard}] !!! РАСХОЖДЕНИЕ: {got ^ expected}")

    # главный момент: чужих юзеров НЕ видно
    print("\n=== 4. Доказательство изоляции (на каждом шарде чужих 0) ===")
    for shard, port in PORTS.items():
        out = psql(port, f"select count(*) from routing_probe "
                         f"where routed_to <> '{shard}';",
                   tuples_only=True)
        count = [l.strip() for l in out.splitlines() if l.strip().isdigit()]
        print(f"  [{shard}] чужих строк: {count[0] if count else '?'}")

    print("\nИТОГ:", "маршруты и данные совпадают — кольцо работает"
          if ok else "ЕСТЬ РАСХОЖДЕНИЕ — смотри !!! выше")
    print("Убрать таблицы-пробы: python routing_demo.py --drop")


if __name__ == "__main__":
    main()
