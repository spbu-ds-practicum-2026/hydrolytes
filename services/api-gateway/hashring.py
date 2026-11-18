"""Хеш-кольцо (consistent hashing) для маршрутизации ключей по шарам.

Задача: стабильно отобразить ключ (user_id / email) на имя шарда так,
чтобы при добавлении/удалении шарда переехала только часть ключей.

Использование в API:
    from hashring import HashRing
    ring = HashRing(["shard1", "shard2"])
    shard = ring.get(user_id)          # -> 'shard1' | 'shard2'
    # адрес и живость шарда — у координатора (host, port, epoch)
"""
import hashlib
from bisect import bisect_right


class HashRing:
    """Кольцо 0..2^128: каждый узел represented vnodes точками на кольце.
    Ключ идёт «по часовой» до первой встречной точки — это его шард."""

    def __init__(self, nodes, vnodes: int = 64):
        if not nodes:
            raise ValueError("нужен хотя бы один узел")
        self.vnodes = vnodes
        points = []
        for node in nodes:
            for i in range(vnodes):
                points.append((self._hash(f"{node}#{i}"), node))
        points.sort()
        self._pts = [p for p, _ in points]
        self._names = [n for _, n in points]

    @staticmethod
    def _hash(s: str) -> int:
        # md5 здесь — не про безопасность, а про стабильное распределение:
        # одинаковая функция во всех сервисах = одинаковые маршруты.
        return int(hashlib.md5(s.encode("utf-8")).hexdigest(), 16)

    def get(self, key) -> str:
        h = self._hash(str(key))
        i = bisect_right(self._pts, h)
        if i == len(self._pts):      # за последней точкой — заворачиваем в 0
            i = 0
        return self._names[i]

    def nodes(self) -> list:
        """Уникальные узлы в кольце (для отчёта/логов)."""
        return list(dict.fromkeys(self._names))


if __name__ == "__main__":
    ring = HashRing(["shard1", "shard2"])
    print("кольцо:", ring.nodes())
    for uid in range(1, 11):
        print(f"  user_{uid} -> {ring.get(f'user_{uid}')}")
