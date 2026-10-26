#!/usr/bin/env python3
"""Process-level edge cases for owned forwarding readiness (no Kubernetes required)."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('verify_runtime', Path(__file__).resolve().parents[1] / 'verify-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class PortForwardTests(unittest.TestCase):
    def child(self, source):
        return [sys.executable, '-u', '-c', source]

    def test_split_announcement_returns_actual_child_listener(self):
        child = self.child("import socket,sys,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); "
                           "print('Forwarding from 127.0.0.1:',end='',flush=True); time.sleep(.05); "
                           "print(str(s.getsockname()[1])+' -> 8080',flush=True); time.sleep(30)")
        forward = runtime.PortForward(child, 'ignored')
        try:
            with runtime.socket.create_connection(('127.0.0.1', forward.port), timeout=1):
                pass
            forward.check()
        finally:
            forward.close()
        self.assertIsNotNone(forward.process.returncode)

    def test_unrelated_listener_cannot_satisfy_readiness(self):
        with runtime.socket.socket() as old:
            old.bind(('127.0.0.1', 0))
            old.listen()
            with self.assertRaisesRegex(RuntimeError, 'announced its own'):
                runtime.PortForward(self.child('import time; time.sleep(30)'), 'ignored', timeout=.1)
            self.assertEqual(old.getsockopt(runtime.socket.SOL_SOCKET, runtime.socket.SO_ACCEPTCONN), 1)

    def test_timeout_reaps_child_and_rejects_nonloopback_announcement(self):
        with tempfile.TemporaryDirectory() as tmp:
            pid = Path(tmp) / 'pid'
            source = (f'import os,time; open({str(pid)!r},"w").write(str(os.getpid())); '
                      'print("Forwarding from 0.0.0.0:12345 -> 8080",flush=True); time.sleep(30)')
            with self.assertRaisesRegex(RuntimeError, 'announced its own'):
                runtime.PortForward(self.child(source), 'ignored', timeout=.5)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid.read_text()), 0)

    def test_exit_after_readiness_is_detected(self):
        forward = runtime.PortForward(self.child('import time; print("Forwarding from 127.0.0.1:12345 -> 8080",flush=True); time.sleep(.1)'), 'ignored')
        try:
            forward.process.wait(timeout=2)
            with self.assertRaisesRegex(RuntimeError, 'owned port-forward exited'):
                forward.check()
        finally:
            forward.close()


if __name__ == '__main__':
    unittest.main()
