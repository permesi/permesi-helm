#!/usr/bin/env python3
"""Pass/fail logic of the Genesis-outage check (no Kubernetes required)."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('genesis_outage', Path(__file__).with_name('genesis-outage.py'))
outage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(outage)


class Cluster:
    """Two or more replicas behind the same round-robin the real request helper uses."""

    def __init__(self, replicas=2):
        self.replicas, self.index, self.served, self.calls = replicas, 0, set(), []

    def request(self, flow, fail=None):
        replica = self.index % self.replicas
        self.index += 1
        self.served.add(replica)
        self.calls.append((flow, replica))
        if fail and fail(replica, len(self.calls)):
            raise RuntimeError("GET /v1/auth/session returned 503")

    def flows(self, *, fail=None, requests=None):
        requests = requests or {}

        def flow(name):
            def call():
                for _ in range(requests.get(name, 1)):
                    self.request(name, fail if name == "session" else None)
            return call
        return {name: flow(name) for name in ("session", "authorization_code", "refresh", "userinfo")}


class GenesisOutageTests(unittest.TestCase):
    def passed(self, flows, baseline, fault, replicas=2):
        return {message: ok for ok, message in outage.verdicts(flows, baseline, fault, replicas)}

    def test_every_flow_reaches_every_replica_in_both_phases(self):
        cluster = Cluster()
        flows = cluster.flows(requests={"authorization_code": 3})
        baseline = outage.exercise(flows, 2, cluster.served)
        fault = outage.exercise(flows, 2, cluster.served)
        for result in list(baseline.values()) + list(fault.values()):
            self.assertEqual((result["offered"], result["successes"], result["replicas"]), (4, 4, 2))
        verdicts = self.passed(flows, baseline, fault)
        self.assertEqual(len(verdicts), 8)
        self.assertTrue(all(verdicts.values()))
        # A three-request grant starts on both replicas and crosses between them.
        starts = [replica for flow, replica in cluster.calls if flow == "authorization_code"][0:12:3]
        self.assertEqual(set(starts), {0, 1})

    def test_one_failed_call_in_the_offline_phase_fails_only_that_flow_and_phase(self):
        cluster = Cluster()
        healthy = cluster.flows()
        baseline = outage.exercise(healthy, 2, cluster.served)
        broken = cluster.flows(fail=lambda replica, count: replica == 1)
        fault = outage.exercise(broken, 2, cluster.served)
        self.assertEqual(fault["session"]["successes"], 2)
        self.assertEqual(fault["session"]["failure_reasons"], {"GET /v1/auth/session returned 503": 2})
        verdicts = self.passed(healthy, baseline, fault)
        failed = [message for message, ok in verdicts.items() if not ok]
        self.assertEqual(failed, ["session succeeded on every core replica with Genesis offline"])

    def test_a_flow_that_never_reached_one_replica_fails_even_when_every_call_succeeded(self):
        cluster = Cluster()
        flows = cluster.flows()
        baseline = outage.exercise(flows, 2, cluster.served)
        fault = {key: dict(value, replicas=1) for key, value in baseline.items()}
        self.assertFalse(any(ok for ok, message in outage.verdicts(flows, baseline, fault, 2) if "offline" in message))

    def test_missing_or_short_results_never_pass(self):
        cluster = Cluster()
        flows = cluster.flows()
        baseline = outage.exercise(flows, 2, cluster.served)
        self.assertFalse(any(ok for ok, message in outage.verdicts(flows, baseline, {}, 2) if "offline" in message))
        short = {key: dict(offered=1, successes=1, failure_reasons={}, replicas=2) for key in flows}
        self.assertFalse(any(ok for ok, _ in outage.verdicts(flows, short, short, 2)))

    def test_unexpected_exceptions_are_not_swallowed(self):
        def boom():
            raise ZeroDivisionError
        with self.assertRaises(ZeroDivisionError):
            outage.exercise({"session": boom}, 2, set())


if __name__ == '__main__':
    unittest.main()
