"""Чтение чекпойнта torch.save (zip) без torch и без выполнения кода: pickle разбирается с белым списком
(OrderedDict, _rebuild_tensor_v2 и хранилища чисел), тензоры становятся массивами numpy. Всё остальное — отказ.
"""
from __future__ import annotations

import collections
import io
import pickle
import zipfile
from pathlib import Path

import numpy as np

STORAGES = {"FloatStorage": "<f4", "DoubleStorage": "<f8", "HalfStorage": "<f2", "LongStorage": "<i8",
            "IntStorage": "<i4", "ShortStorage": "<i2", "CharStorage": "i1", "ByteStorage": "u1", "BoolStorage": "?"}


class _Storage(str):
    pass


def _rebuild(storage, offset, size, stride, requires_grad=False, backward_hooks=None, metadata=None):
    item = storage.itemsize
    return np.lib.stride_tricks.as_strided(storage[offset:], shape=tuple(size),
                                           strides=tuple(s * item for s in stride)).copy()


class _Unpickler(pickle.Unpickler):
    def __init__(self, data: bytes, zf: zipfile.ZipFile, prefix: str):
        super().__init__(io.BytesIO(data))
        self.zf, self.prefix = zf, prefix

    def find_class(self, module, name):
        if (module, name) == ("collections", "OrderedDict"):
            return collections.OrderedDict
        if (module, name) == ("torch._utils", "_rebuild_tensor_v2"):
            return _rebuild
        if module == "torch" and name in STORAGES:
            return _Storage(STORAGES[name])
        raise pickle.UnpicklingError(f"класс {module}.{name} в чекпойнте не разрешён")

    def persistent_load(self, pid):
        kind, storage_type, key, _location, numel = pid
        if kind != "storage" or not isinstance(storage_type, _Storage):
            raise pickle.UnpicklingError("неизвестное хранилище в чекпойнте")
        raw = self.zf.read(f"{self.prefix}/data/{key}")
        arr = np.frombuffer(raw, dtype=str(storage_type))
        if arr.size < numel:
            raise pickle.UnpicklingError("хранилище короче заявленного")
        return arr


def load(data: bytes | Path):
    raw = Path(data).read_bytes() if isinstance(data, Path) else data
    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        pkl = next(n for n in zf.namelist() if n.endswith("/data.pkl"))
        return _Unpickler(zf.read(pkl), zf, pkl.rsplit("/", 1)[0]).load()
