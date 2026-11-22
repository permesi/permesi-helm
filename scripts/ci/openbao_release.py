"""Promote the published 0.5 defaults to the OpenBao contract on the first 0.6 release."""
import json
import shutil

import yaml


def scalars(path, changes):
    """Replace named YAML scalars by source span, retaining Helm comments and managed markers."""
    text = path.read_text()
    node = yaml.compose(text)
    spans = []
    for keys, value in changes.items():
        item = node
        for key in keys.split("."):
            item, = [child for name, child in item.value if name.value == key]
        spans.append((item.start_mark.index, item.end_mark.index, json.dumps(value)))
    for start, end, value in sorted(spans, reverse=True):
        text = text[:start] + value + text[end:]
    path.write_text(text)


def promote(root):
    pins = json.loads((root / "scripts/quickstart/openbao-images.json").read_text())
    bao = pins["openbao"]
    helper = root / "scripts/quickstart/chart/values.yaml"
    fields = {"secretsProvider": "openbao"}
    for name, dependency in (("vault", bao), ("postgresql", pins["postgresql"])):
        fields.update({f"{name}.image.{k}": v for k, v in dependency.items()})
    scalars(helper, fields)
    for service in ("permesi", "genesis"):
        fields = {"secretsProvider": "openbao", **{f"vault.agent.image.{k}": v for k, v in bao.items()}}
        if service == "permesi":
            fields.update({"admission.paserkUrl": "", "vault.agent.paserkCa.enabled": False})
        elif "admissionSigningVersion" not in yaml.safe_load((root / "charts/genesis/values.yaml").read_text()):
            path = root / "charts/genesis/values.yaml"
            path.write_text(path.read_text().replace("\nsecretsProvider:", "\nadmissionSigningVersion: 1\nsecretsProvider:", 1))
        scalars(root / f"charts/{service}/values.yaml", fields)
    lock_path = root / "scripts/quickstart/lock.json"
    lock = json.loads(lock_path.read_text())
    lock["images"].pop("vault", None)
    lock["images"].update(pins)
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")
    examples = root / "charts/permesi-stack/examples"
    shutil.copyfile(examples / "quickstart-openbao.yaml", examples / "quickstart.yaml")
