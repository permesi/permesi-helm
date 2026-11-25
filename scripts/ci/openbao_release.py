"""Pin the OpenBao dependency images in the release lock on the first 0.6 release.

The charts and the quickstart helper are OpenBao-only in source, so the release
only replaces the lock's 0.5 dependency entries (HashiCorp Vault, PostgreSQL 18)
with the pins in scripts/quickstart/openbao-images.json.
"""
import json


def promote(root):
    pins = json.loads((root / "scripts/quickstart/openbao-images.json").read_text())
    lock_path = root / "scripts/quickstart/lock.json"
    lock = json.loads(lock_path.read_text())
    lock["images"].pop("vault", None)
    lock["images"].update(pins)
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
