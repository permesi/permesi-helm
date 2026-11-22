#!/usr/bin/env python3
"""Render the operator-owned admission policies for qualified core image digests.

Install independently of the application Helm release. The Deployment check
makes a legacy Helm rollback fail synchronously. Pod admission also covers
already-existing replica sets and restarts. Existing pods must be drained.
"""
import argparse
import json
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--deployment", required=True)
    parser.add_argument("--service-account", required=True)
    parser.add_argument("--image", required=True, action="append")
    args = parser.parse_args()
    for name in [args.namespace, args.deployment, args.service_account]:
        if len(name) > 63 or not re.fullmatch(r"[a-z0-9](?:[-a-z0-9]*[a-z0-9])?", name):
            parser.error("expected a Kubernetes DNS label")
    if not all(re.fullmatch(r"[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}", i) for i in args.image):
        parser.error("supply complete repository@sha256 references")
    resources = []
    for kind, group, spec in [("deployments", "apps", "object.spec.template.spec"),
                              ("pods", "", "object.spec")]:
        name = ".".join(["core-digests", args.namespace, args.deployment, kind])
        base = dict(apiVersion="admissionregistration.k8s.io/v1", metadata={"name": name})
        account = json.dumps(args.service_account)
        target = f'({spec}.containers.exists(c, c.name == "permesi") || (has({spec}.serviceAccountName) && {spec}.serviceAccountName == {account}))'
        if group:
            target = f'(object.metadata.name == {json.dumps(args.deployment)} || {target})'
        approved = json.dumps(sorted(set(args.image)))
        resources.append(dict(base, kind="ValidatingAdmissionPolicy", spec={
            "failurePolicy": "Fail",
            "matchConstraints": {"resourceRules": [{"apiGroups": [group], "apiVersions": ["v1"],
                "resources": [kind], "operations": ["CREATE", "UPDATE"]}]},
            "matchConditions": [{"name": "core", "expression": target}],
            "validations": [{"expression": f'{spec}.containers.exists(c, c.name == "permesi" && c.image in {approved})',
                             "message": "Permesi requires an operator-qualified image digest."}]}))
        resources.append(dict(base, kind="ValidatingAdmissionPolicyBinding", spec={
            "policyName": name, "validationActions": ["Deny"],
            "matchResources": {"namespaceSelector": {"matchLabels": {
                "kubernetes.io/metadata.name": args.namespace}}}}))
    print(json.dumps({"apiVersion": "v1", "kind": "List", "items": resources}, indent=2))


if __name__ == "__main__":
    main()
