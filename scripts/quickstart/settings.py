#!/usr/bin/env python3
"""Resolve only public quickstart settings from Helm's merged release values.

Standalone and umbrella releases share this boundary. Credential-bearing input
is never printed; malformed or ambiguous configuration fails before use in URLs.
"""
import argparse
from dataclasses import asdict, dataclass
import json
import re
import sys


@dataclass(frozen=True)
class Settings:
    postgres_name: str
    postgres_host: str
    postgres_port: int
    vault_name: str
    vault_address: str
    oidc_enabled: bool


def dns_label(value):
    """Reject values that cannot name a Kubernetes Service or namespace."""
    if not isinstance(value, str) or len(value) > 63 or not re.fullmatch(
            r"[a-z0-9](?:[-a-z0-9]*[a-z0-9])?", value):
        raise ValueError("invalid Kubernetes DNS label")
    return value


def service(values, component, fullname, namespace):
    """Resolve chart defaults and validate URL/DSN endpoint components."""
    config = values[component]["service"]
    if not isinstance(config["name"], str):
        raise ValueError("invalid Service name")
    name = dns_label(config["name"] or fullname + "-" + component)
    port = config["port"]
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("invalid Service port")
    return name, f"{name}.{namespace}.svc", port


def resolve(values, fullname, namespace):
    """Accept exactly one known helper layout; never guess an OIDC default."""
    dns_label(fullname)
    dns_label(namespace)
    candidates = [value for value in (values, values.get("quickstart"))
                  if isinstance(value, dict) and "bootstrap" in value]
    if len(candidates) != 1:
        raise ValueError("expected one standalone or umbrella quickstart configuration")
    helper = candidates[0]
    enabled = helper["bootstrap"]["oidcSigning"]["enabled"]
    if type(enabled) is not bool:
        raise ValueError("OIDC enablement must be boolean")
    pg_name, pg_host, pg_port = service(helper, "postgresql", fullname, namespace)
    vault_name, vault_host, vault_port = service(helper, "vault", fullname, namespace)
    return Settings(pg_name, pg_host, pg_port, vault_name,
                    f"http://{vault_host}:{vault_port}", enabled)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fullname", required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--lines", action="store_true", help="Print validated fields in dataclass order")
    args = parser.parse_args()
    try:
        values = json.load(sys.stdin)
        if not isinstance(values, dict):
            raise ValueError("expected merged Helm values")
        settings = asdict(resolve(values, args.fullname, args.namespace))
    except (KeyError, TypeError, ValueError):
        parser.exit(2, "settings.py: invalid effective quickstart configuration; values withheld\n")
    if args.lines:
        for value in settings.values():
            print(str(value).lower() if isinstance(value, bool) else value)
    else:
        print(json.dumps(settings))


if __name__ == "__main__":
    main()
