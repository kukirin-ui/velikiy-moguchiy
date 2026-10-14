"""Fine-tune API helpers (Beijing native API). Never lists or touches files that are not ours."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from common import *

def upload(path, ki=0):
    with open(path, "rb") as f:
        r = requests.post(BASE + "/api/v1/files", headers=hdr(ki), data={"purpose": "fine-tune", "descriptions": "lipread-ru youtube clips probe"},
                          files={"files": (Path(path).name, f, "application/zip")}, timeout=300)
    return r.status_code, r.json() if r.headers.get("content-type", "").startswith("application/json") else r.text[:300]

def create(model, file_id, hp, training_type="efficient_sft", name=None, ki=0, val_id=None):
    body = {"model": model, "training_type": training_type, "hyper_parameters": hp,
            "training_datasets": [{"data_source_type": "file_id", "file_id": file_id}]}
    if val_id:
        body["validation_datasets"] = [{"data_source_type": "file_id", "file_id": val_id}]
    if name:
        body["job_name"] = name
    r = requests.post(BASE + "/api/v1/fine-tunes", headers={**hdr(ki), "Content-Type": "application/json"}, json=body, timeout=60)
    return r.status_code, r.json()

def job(jid, ki=0):
    return requests.get(BASE + f"/api/v1/fine-tunes/{jid}", headers=hdr(ki), timeout=30).json()

def logs(jid, ki=0):
    return requests.get(BASE + f"/api/v1/fine-tunes/{jid}/logs", headers=hdr(ki), timeout=30).json()
