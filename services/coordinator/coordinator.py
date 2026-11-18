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

os.environ.setdefault("PGUSER", "postgres")

def pg_bindir() -> str:
    out = subprocess.run(["pg_config", "--bindir"], capture_output=True, text=True)
    return out.stdout.strip() or "."


def is_alive(port: int) -> bool:
    """pg_isready — дешёвая проверка «процесс принимает подключения»."""
    r = subprocess.run(
        [os.path.join(pg_bindir(), "pg_isready"), "-h", "127.0.0.1", "-p", str(port), "-U", "postgres"],
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

def node_role(port: int):
    """'f' — мастер, 't' — реплика, None — узел недоступен или запрос не прошёл.
    В отличие от is_alive (pg_isready) и is_in_recovery: None означает
    «не знаю», а не «не в recovery» — триггер не сработает на полуподнятом узле."""
    try:
        r = subprocess.run(
            [os.path.join(pg_bindir(), "psql"), "-h", "127.0.0.1", "-p", str(port),
             "-U", "postgres", "-tAc", "select pg_is_in_recovery();"],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return None
    if r.returncode != 0:
        return None
    out = r.stdout.strip()
    return out if out in ("t", "f") else None

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


def promote_dir(datadir: str) -> bool:
    """Promote по каталогу данных: после failover эффективная реплика
    может лежать в master_datadir — роли в конфиге инвертируются."""
    r = subprocess.run(
        [os.path.join(pg_bindir(), "pg_ctl"), "-D", datadir, "promote"],
        capture_output=True, text=True,
    )
    print(f"  pg_ctl promote -> {r.returncode}: {r.stdout.strip() or r.stderr.strip()}")
    return r.returncode == 0

def effective_roles(shard: dict, epoch: int):
    """Чётный epoch → мастер = master_port (5433).
    Нечётный epoch → мастер = replica_port (5434).
    Возвращает (master_port, replica_port, каталог_реплики)."""
    if epoch % 2 == 0:
        return shard["master_port"], shard["replica_port"], shard["replica_datadir"]
    return (shard["replica_port"], shard["master_port"],
            shard.get("master_datadir", shard["replica_datadir"]))

def return_old_master(shard: dict, cfg: dict, m_port: int, r_port: int, r_dir: str) -> bool:
    """Возврат r_dir (r_port) как реплики действующего мастера m_port (п. 4.4).
    Вывод — по мере выполнения; чтение пайпа идёт в фоновом потоке,
    основной цикл завершается вместе с процессом powershell, а не с EOF
    пайпа (иначе postgres, унаследовавший пайп, подвешивает координатора)."""
    import queue, threading
    script = cfg.get("return_script")
    if not script or not r_dir or not os.path.isfile(script):
        print("  return_script/master_datadir не заданы — возврат вручную")
        return False
    inner = (
        f"& '{script}' -NewMasterPort {m_port} -OldNodePort {r_port} "
        f"-OldNodeDir '{r_dir}' "
        f"-SlotName '{cfg.get('return_slot', 'replica_1')}' "
        f"-BinDir '{cfg.get('pg_bin', 'D:\\Postgre\\bin')}' -EnableSync *>&1"
    )
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
           "-Command",
           "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " + inner]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True,
                                encoding="utf-8", errors="replace")
    except Exception as e:
        print(f"  запуск return_node.ps1 не удался: {e}")
        return False

    q = queue.Queue()

    def _drain():
        try:
            for line in proc.stdout:
                q.put(line)
        except Exception:
            pass
        q.put(None)

    threading.Thread(target=_drain, daemon=True).start()

    deadline = time.time() + 600
    while time.time() < deadline:
        try:
            line = q.get(timeout=1)
        except queue.Empty:
            line = None
        if line is not None:
            print("  | " + line.rstrip())
            continue
        # тишина: если процесс уже кончился — дочитать остаток и выйти
        if proc.poll() is not None:
            for _ in range(5):
                try:
                    line = q.get(timeout=0.2)
                except queue.Empty:
                    break
                if line is None:
                    break
                print("  | " + line.rstrip())
            break

    if proc.poll() is None:
        proc.kill()
        proc.wait(timeout=10)
        print("  превышен таймаут 600 с — скрипт убит")
        return False
    return proc.returncode == 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as f:
        cfg = json.load(f)

    state = load_state(cfg["state_file"])
    for shard in cfg["shards"]:
        state.setdefault(shard["name"], {"epoch": 0, "failed_checks": 0, "degraded": False})
        state[shard["name"]].setdefault("return_last_try", 0.0)
        state[shard["name"]].setdefault("return_attempts", 0)

    print("координатор запущен, Ctrl-C для остановки")
    try:
        while True:
            for shard in cfg["shards"]:
                name = shard["name"]
                st = state[name]

                # После failover (epoch > 0) роли инвертируются:
                # реплика из конфига — действующий мастер.
                m_port, r_port, r_dir = effective_roles(shard, st["epoch"])

                master_alive = is_alive(m_port)
                replica_alive = is_alive(r_port)

                # 0. Возврат узла (4.4): старый мастер вернулся отдельным
                #    мастером при активном epoch — это split-brain, чиним скриптом.
                                # 0. Возврат узла (4.4): старый узел вернулся и ДОСТОВЕРНО
                #    мастер (node_role вернул 'f') при активном epoch.
                #    Повтор каждые 30 с, максимум 10 попыток — после фейла
                #    координатор не «замолкает навсегда», а ретраит.
                role = node_role(r_port)
                if role == "f":
                    now = time.time()
                    last = st.get("return_last_try", 0.0)
                    attempts = st.get("return_attempts", 0)
                    if attempts < 10 and (now - last) >= 30:
                        st["return_last_try"] = now
                        st["return_attempts"] = attempts + 1
                        print(f"[{name}] узел {r_port} (реплика) вернулся самостоятельным "
                              f"мастером -> возврат в реплику "
                              f"(попытка {st['return_attempts']}/10)")
                        ok = return_old_master(shard, cfg, m_port, r_port, r_dir)
                        print(f"[{name}] возврат "
                              f"{'выполнен' if ok else 'не удался, повтор через 30 с'}")
                    elif attempts >= 10:
                        print(f"[{name}] возврат не удаётся (10/10) — запусти "
                              f"return_node.ps1 вручную")
                    else:
                        left = max(0, int(30 - (now - last)))
                        print(f"[{name}] жду возврата узла {r_port} "
                              f"(попытка {attempts}/10, следующая через {left} с)")
                    save_state(cfg["state_file"], state)
                    continue

                # 1. Действующий мастер пропал: считаем неудачи, после порога — failover.
                if not master_alive:
                    st["failed_checks"] += 1
                    if st["failed_checks"] >= cfg["failures_before_promote"] and replica_alive:
                        if not is_in_recovery(r_port):
                            print(f"[{name}] реплика уже мастер, promote не нужен")
                        elif promote_dir(r_dir):
                            st["epoch"] += 1
                            st["failed_checks"] = 0
                            st["degraded"] = True
                            st["return_last_try"] = 0.0
                            st["return_attempts"] = 0
                            degrade_mode(r_port, enable=True)
                            print(f"[{name}] epoch={st['epoch']} state=degraded "
                                  f"(новый мастер: порт {r_port})")
                        continue
                    print(f"[{name}] master=down replica={'up' if replica_alive else 'down'} "
                          f"failed_checks={st['failed_checks']} epoch={st['epoch']} state=waiting")
                else:
                    st["failed_checks"] = 0
                    # 2. Мастер жив, реплика пропала: деградированный режим.
                    if not replica_alive and not st["degraded"]:
                        degrade_mode(m_port, enable=True)
                        st["degraded"] = True
                        print(f"[{name}] replica=down -> деградированный режим (synchronous_commit=local)")
                    # 3. Реплика вернулась — возвращаем синхронность.
                    elif replica_alive and st["degraded"]:
                        degrade_mode(m_port, enable=False)
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
