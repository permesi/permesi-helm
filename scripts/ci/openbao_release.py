"""Pin the OpenBao and PostgreSQL dependency images in the release lock.

Every release replaces the lock's dependency entries with
scripts/quickstart/openbao-images.json, so the two files cannot drift.
"""
import json


def promote(root):
    pins = json.loads((root / "scripts/quickstart/openbao-images.json").read_text())
    lock_path = root / "scripts/quickstart/lock.json"
    lock = json.loads(lock_path.read_text())
    lock["images"].update(pins)
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
