"""Pin the OpenBao dependency images in the release lock on every 0.6+ release.

The charts and the quickstart helper are OpenBao-only in source, so the release
replaces the lock's dependency entries (the 0.5 HashiCorp Vault and PostgreSQL 18
ones, or older OpenBao/PostgreSQL pins) with scripts/quickstart/openbao-images.json.
"""
import json


def promote(root):
    pins = json.loads((root / "scripts/quickstart/openbao-images.json").read_text())
    lock_path = root / "scripts/quickstart/lock.json"
    lock = json.loads(lock_path.read_text())
    lock["images"].pop("vault", None)
    lock["images"].update(pins)
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
