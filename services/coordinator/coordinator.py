#!/usr/bin/env python3
"""Координатор стенда v0.

Делает ровно то, что описано в ТР, в минимальном виде:
  * health-проверки мастера и реплики каждого шарда;
  * после N неудач подряд — promote реплики (pg_ctl promote);
  * инкремент epoch и печать карты маршрутов;
  * перевод шарда в деградированный режим, если реплика пропала.

Запуск:
    python3 coordinator.py --config stand.json
"""

import argparse
import json
import os
import subprocess
import sys
import time


def pg_bindir() -> str:
    out = subprocess.run(["pg_config", "--bindir"], capture_output=True, text=True)
    return out.stdout.strip() or "."


def is_alive(port: int) -> bool:
    """pg_isready — дешёвая проверка «процесс принимает подключения»."""
    r = subprocess.run(
        [os.path.join(pg_bindir(), "pg_isready"), "-h", "127.0.0.1", "-p", str(port)],
        capture_output=True,
        text=True,
    )
    return r.returncode == 0


def is_in_recovery(port: int) -> bool:
    """True — узел в режиме реплики (только чтение), False — мастер."""
    r = subprocess.run(
        ["psql", "-h", "127.0.0.1", "-p", str(port), "-U", "postgres",
         "-tAc", "select pg_is_in_recovery();"],
        capture_output=True, text=True,
    )
    return r.stdout.strip() == "t"


def load_state(path: str) -> dict:
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_state(path: str, state: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


def degrade_mode(port: int, enable: bool) -> None:
    """Деградированный режим: писать, не дожидаясь реплики.

    enable=True  -> synchronous_commit=local, пустой synchronous_standby_names
    enable=False -> возвращаем remote_apply и имя реплики
    """
    if enable:
        sql = ("alter system set synchronous_commit = 'local'; "
               "alter system set synchronous_standby_names = ''; "
               "select pg_reload_conf();")
    else:
        sql = ("alter system set synchronous_commit = 'remote_apply'; "
               "alter system set synchronous_standby_names = 'replica_1'; "
               "select pg_reload_conf();")
    subprocess.run(["psql", "-h", "127.0.0.1", "-p", str(port), "-U", "postgres",
                    "-c", sql], capture_output=True, text=True)


def promote(shard: dict) -> bool:
    r = subprocess.run(
        [os.path.join(pg_bindir(), "pg_ctl"), "-D", shard["replica_datadir"], "promote"],
        capture_output=True, text=True,
    )
    print(f"  pg_ctl promote -> {r.returncode}: {r.stdout.strip() or r.stderr.strip()}")
    return r.returncode == 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as f:
        cfg = json.load(f)

    state = load_state(cfg["state_file"])
    for shard in cfg["shards"]:
        state.setdefault(shard["name"], {"epoch": 0, "failed_checks": 0, "degraded": False})

    print("координатор запущен, Ctrl-C для остановки")
    try:
        while True:
            for shard in cfg["shards"]:
                name = shard["name"]
                st = state[name]
                master_alive = is_alive(shard["master_port"])
                replica_alive = is_alive(shard["replica_port"])

                # 1. Мастер пропал: считаем неудачи, после порога — failover.
                if not master_alive:
                    st["failed_checks"] += 1
                    if st["failed_checks"] >= cfg["failures_before_promote"] and replica_alive:
                        if not is_in_recovery(shard["replica_port"]):
                            print(f"[{name}] реплика уже мастер, promote не нужен")
                        elif promote(shard):
                            st["epoch"] += 1
                            st["failed_checks"] = 0
                            st["degraded"] = True
                            # после promote новый мастер пишет без второго узла
                            degrade_mode(shard["replica_port"], enable=True)
                            print(f"[{name}] epoch={st['epoch']} state=degraded "
                                  f"(новый мастер: порт {shard['replica_port']})")
                        continue
                    print(f"[{name}] master=down replica={'up' if replica_alive else 'down'} "
                          f"failed_checks={st['failed_checks']} epoch={st['epoch']} state=waiting")
                else:
                    st["failed_checks"] = 0
                    # 2. Мастер жив, реплика пропала: деградированный режим,
                    #    иначе синхронный COMMIT зависнет.
                    if not replica_alive and not st["degraded"]:
                        degrade_mode(shard["master_port"], enable=True)
                        st["degraded"] = True
                        print(f"[{name}] replica=down -> деградированный режим (synchronous_commit=local)")
                    # 3. Реплика вернулась — возвращаем синхронность.
                    elif replica_alive and st["degraded"]:
                        degrade_mode(shard["master_port"], enable=False)
                        st["degraded"] = False
                        print(f"[{name}] replica=up -> синхронный режим восстановлен")
                    else:
                        print(f"[{name}] master=up replica={'up' if replica_alive else 'down'} "
                              f"epoch={st['epoch']} state={'degraded' if st['degraded'] else 'healthy'}")

                save_state(cfg["state_file"], state)
            time.sleep(cfg["check_interval"])
    except KeyboardInterrupt:
        save_state(cfg["state_file"], state)
        print("\n остановлен, состояние сохранено")
    return 0


if __name__ == "__main__":
    sys.exit(main())
