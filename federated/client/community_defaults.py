"""Адрес сервера «Помочь обучить» и открытый ключ подписи общего адаптера, зашитые в приложение.

Адрес пишет процесс деплоя сервера приёма (.github/workflows/federated-worker.yml), ключ — он же из секрета
FL_MODEL_SIGNING_KEY. Пока адреса нет, «Помочь обучить» честно пишет, что сервер обучения ещё не настроен.
"""
SERVER_URL = "https://velikiy-moguchiy-train.velikiy-moguchiy.workers.dev"
MODEL_SIGNING_PUBLIC_KEY = "WJr/HHGK6TlaVUkYBAUtDmHgfThkPbSTAUpzOCKztwQ="
# signed adapter versions (hub/registry.py layout); empty = download them through SERVER_URL
MODELS_URL = "https://huggingface.co/z1gansh1n/velikiy-moguchiy-lips/resolve/main"

# channels whose owners asked to be left out (data-governance/exclusions); videos of these channels are skipped
EXCLUSIONS_URL = "https://raw.githubusercontent.com/zigansh1n/velikiy-moguchiy/main/data-governance/exclusions/channels.tsv"

# The front-end checkpoint goes through torch.load, so only these files are accepted, whatever the server says.
VENC_SHA256 = frozenset({
    "5d3d2808d7f2ca462c9ae8851d8b2114f3dc6937887f57c0ceeddf19d91f16cf",  # lips-0.1
})
