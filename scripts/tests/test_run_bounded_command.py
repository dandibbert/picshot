"""Portable stdlib coverage for the POSIX CI command runner.

Run: python3 -m unittest discover -s scripts/tests -p test_run_bounded_command.py -v
"""

import argparse
import contextlib
import errno
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock


RUNNER = Path(__file__).resolve().parents[1] / "run-bounded-command.py"
SPEC = importlib.util.spec_from_file_location("bounded_command", RUNNER)
BOUNDED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOUNDED)


@unittest.skipUnless(os.name == "posix", "the macOS CI runner needs POSIX process groups")
class BoundedCommandTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.log = self.root / "nested" / "command.log"
        self.report = self.root / "nested" / "command.json"
        self.processes = []
        self.addCleanup(self.cleanup_processes)

    def cleanup_processes(self):
        for process in self.processes:
            if process.poll() is None:
                # Let the wrapper clean its owned group while its child identity
                # is still anchored. A completed report's PID may now be reused.
                process.terminate()
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=3)

    def start(self, code=None, *, command=None, timeout=4, grace=0.15, cap=4096):
        argv = [
            sys.executable, str(RUNNER),
            "--timeout-seconds", str(timeout), "--grace-seconds", str(grace),
            "--max-log-bytes", str(cap), "--log", str(self.log),
            "--report", str(self.report), "--",
        ]
        argv.extend(command if command is not None else [sys.executable, "-u", "-c", code])
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        return process

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=8)
        report = json.loads(self.report.read_text())
        self.assertEqual(process.returncode, report["exit_code"], stderr.decode(errors="replace"))
        self.assertNotEqual(report["status"], "wrapper_error",
                            json.dumps(report, sort_keys=True) + "\n" + stderr.decode(errors="replace"))
        self.assertLessEqual(self.log.stat().st_size, report["max_log_bytes"])
        self.assertEqual(self.log.stat().st_size, report["log_bytes"])
        self.assertIn(b"[bounded-command]", stderr)
        return report, stdout

    def await_path(self, path):
        until = time.monotonic() + 3
        while time.monotonic() < until:
            if path.exists() and path.stat().st_size:
                return
            time.sleep(0.01)
        self.fail(f"command did not write {path}")

    def assert_not_running(self, pid):
        # kill(pid, 0) also succeeds for an already-killed orphan zombie on Linux.
        # Both macOS and Linux ps expose Z; zombies cannot execute or hold pipes.
        state = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, check=False
        ).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), f"PID {pid} is still running: {state}")

    def test_success_streams_merged_output_and_reports_exit(self):
        report, stdout = self.finish(self.start("import sys; print('out'); print('err', file=sys.stderr)"))
        self.assertEqual(report["status"], "exited")
        self.assertEqual(report["exit_code"], 0)
        self.assertEqual(report["child_returncode"], 0)
        self.assertEqual(stdout, b"out\nerr\n")
        self.assertEqual(self.log.read_bytes(), stdout)
        self.assertFalse(report["log_truncated"])
        self.assertFalse(report["sigterm_sent"])
        observations = report["group_observation"]
        self.assertGreater(observations["count"], 0)
        self.assertEqual(observations["failures"], 0)
        self.assertEqual(observations["timeout_seconds"], 0.5)
        self.assertGreaterEqual(observations["total_seconds"], observations["max_seconds"])
        self.assertFalse(observations["atomic_snapshot"])

    def test_failure_preserves_exit_status(self):
        report, _ = self.finish(self.start("import sys; print('failure'); sys.exit(23)"))
        self.assertEqual(report["status"], "exited")
        self.assertEqual(report["exit_code"], 23)

    def test_child_signal_preserves_conventional_exit_status(self):
        report, _ = self.finish(self.start("import os, signal; os.kill(os.getpid(), signal.SIGTERM)"))
        self.assertEqual(report["status"], "exited")
        self.assertEqual(report["child_returncode"], -signal.SIGTERM)
        self.assertEqual(report["exit_code"], 128 + signal.SIGTERM)

    def test_missing_command_writes_spawn_error_report(self):
        report, _ = self.finish(self.start(command=[str(self.root / "missing-command")]))
        self.assertEqual(report["status"], "spawn_error")
        self.assertEqual(report["exit_code"], 127)
        self.assertIsNone(report["pid"])

    def test_arguments_are_not_interpreted_by_a_shell(self):
        marker = self.root / "must-not-exist"
        argument = f"$(touch {marker}); echo hacked | cat > {marker}"
        report, stdout = self.finish(self.start(command=[
            sys.executable, "-c", "import sys; print(sys.argv[1])", argument,
        ]))
        self.assertEqual(report["exit_code"], 0)
        self.assertEqual(stdout.decode().strip(), argument)
        self.assertFalse(marker.exists())

    def test_log_and_console_are_capped_while_output_is_drained(self):
        report, stdout = self.finish(self.start(
            "import os; os.write(1, b'x' * 200000); os.write(2, b'y' * 200000)", cap=1031
        ))
        self.assertEqual(report["exit_code"], 0)
        self.assertEqual(report["output_bytes"], 400000)
        self.assertEqual(report["log_bytes"], 1031)
        self.assertTrue(report["log_truncated"])
        self.assertEqual(stdout, b"x" * 1031)

    def test_exact_log_limit_is_not_truncated(self):
        report, stdout = self.finish(self.start("import os; os.write(1, b'a' * 31)", cap=31))
        self.assertEqual(stdout, b"a" * 31)
        self.assertFalse(report["log_truncated"])

    def test_log_and_running_report_exist_before_completion(self):
        process = self.start("import time; print('started', flush=True); time.sleep(0.3)")
        self.await_path(self.log)
        self.assertIsNone(process.poll())
        self.assertEqual(self.log.read_bytes(), b"started\n")
        self.assertEqual(json.loads(self.report.read_text())["status"], "running")
        self.finish(process)

    def test_deadline_terminates_command(self):
        report, _ = self.finish(self.start("import time; print('waiting'); time.sleep(30)", timeout=0.2))
        self.assertEqual(report["status"], "timeout")
        self.assertEqual(report["exit_code"], 124)
        self.assertTrue(report["sigterm_sent"])
        self.assertLess(report["duration_seconds"], 2)
        self.assert_not_running(report["pid"])

    def test_noisy_command_cannot_starve_deadline(self):
        # Exercise the real runner loop with output ready from its first tick.
        # A fresh Python child's startup can legitimately consume the entire
        # 0.2s deadline before writing anything. Real process startup/deadline,
        # streaming caps, and group cleanup remain covered by adjacent tests.
        args = argparse.Namespace(
            log=self.log, report=self.report, command=["continuously-readable-test-child"],
            timeout_seconds=0.2, grace_seconds=0.15, max_log_bytes=17,
        )
        clock = SimpleNamespace(now=0.0, reads=0, polls=0)
        state = SimpleNamespace(killed=False, registered=False)
        sent = []
        pipe = SimpleNamespace(fileno=lambda: 43210, close=mock.Mock())
        process = SimpleNamespace(pid=43210, stdout=pipe, wait=mock.Mock(return_value=-signal.SIGKILL))
        group = SimpleNamespace(
            retired=False, leader_exited=lambda: state.killed, alive=lambda: not state.killed,
        )

        def send(signum):
            sent.append((signum, clock.now))
            if signum == signal.SIGKILL:
                state.killed = True
            return True  # This child deliberately ignores SIGTERM.

        def close_group():
            group.retired = True

        def read(_fd, limit):
            clock.reads += 1
            # Independent fixture bound: a regression draining forever must
            # fail this test rather than hang the suite waiting for a deadline.
            if clock.reads > 200:
                raise RuntimeError("runner starved its deadline while output remained ready")
            clock.now += 0.01
            if state.killed:
                return b""
            return b"x" * min(limit, 65536)

        def sleep(seconds):
            clock.now += seconds

        group.send = send
        group.close = close_group
        selector = mock.MagicMock()
        selector.__enter__.return_value = selector
        selector.register.side_effect = lambda *_: setattr(state, "registered", True)
        selector.unregister.side_effect = lambda *_: setattr(state, "registered", False)
        key = SimpleNamespace(fd=43210, fileobj=pipe)

        def select_events(**_):
            clock.polls += 1
            if clock.polls > 200:
                raise RuntimeError("runner did not finish bounded output cleanup")
            if state.registered:
                return [(key, 1)]
            clock.now += 0.01
            return []

        selector.select.side_effect = select_events
        selector.get_map.side_effect = lambda: {43210: key} if state.registered else {}
        console = io.BytesIO()
        with mock.patch.object(BOUNDED.subprocess, "Popen", return_value=process), mock.patch.object(
            BOUNDED, "ProcessGroup", return_value=group
        ), mock.patch.object(BOUNDED.selectors, "DefaultSelector", return_value=selector), mock.patch.object(
            BOUNDED.os, "set_blocking"
        ), mock.patch.object(BOUNDED.os, "read", side_effect=read), mock.patch.object(
            BOUNDED, "time", SimpleNamespace(monotonic=lambda: clock.now, sleep=sleep)
        ), mock.patch.object(BOUNDED.sys, "stdout", SimpleNamespace(buffer=console)), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(BOUNDED.run(args), 124)
        report = json.loads(self.report.read_text())
        self.assertEqual(report["status"], "timeout")
        self.assertEqual(report["exit_code"], 124)
        self.assertEqual(console.getvalue(), b"x" * 17)
        self.assertEqual(self.log.read_bytes(), b"x" * 17)
        self.assertEqual(report["log_bytes"], 17)
        self.assertGreater(report["output_bytes"], 65536)
        self.assertTrue(report["log_truncated"])
        self.assertEqual([signum for signum, _ in sent], [signal.SIGTERM, signal.SIGKILL])
        term_at, kill_at = (stamp for _, stamp in sent)
        self.assertGreaterEqual(term_at, args.timeout_seconds)
        self.assertLessEqual(term_at, args.timeout_seconds + 0.010001)
        self.assertGreaterEqual(kill_at - term_at, args.grace_seconds)
        self.assertLessEqual(kill_at - term_at, args.grace_seconds + 0.010001)
        self.assertTrue(report["sigterm_sent"])
        self.assertTrue(report["sigkill_sent"])
        self.assertEqual(report["child_returncode"], -signal.SIGKILL)
        self.assertTrue(group.retired)
        self.assertLess(report["duration_seconds"], 2)

    def child_tree(self, *, parent_exits=False, close_child_output=False):
        marker = self.root / "grandchild.pid"
        # Fork a real descendant without a second interpreter startup consuming
        # the 0.4s deadline. It inherits SIGTERM-ignore and the owned group.
        # Only the descendant writes its PID; readiness follows the closed file.
        code = (
            "import os, signal, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "ready_read, ready_write = os.pipe()\n"
            "if os.fork() == 0:\n"
            "    os.close(ready_read)\n"
            + ("    sink = os.open(os.devnull, os.O_WRONLY)\n"
               "    os.dup2(sink, 1); os.dup2(sink, 2); os.close(sink)\n"
               if close_child_output else "")
            + f"    with open({str(marker)!r}, 'w') as marker:\n"
            "        marker.write(str(os.getpid()))\n"
            "    os.write(ready_write, b'1')\n"
            "    os.close(ready_write)\n"
            "    time.sleep(30)\n"
            "    os._exit(0)\n"
            "os.close(ready_write)\n"
            "if os.read(ready_read, 1) != b'1': raise RuntimeError('grandchild was not ready')\n"
            "os.close(ready_read)\n"
            + ("os._exit(0)\n" if parent_exits else "time.sleep(30)\n")
        )
        return code, marker

    def test_timeout_kills_sigterm_ignoring_parent_and_grandchild(self):
        code, marker = self.child_tree()
        report, _ = self.finish(self.start(code, timeout=0.4))
        self.assertEqual(report["status"], "timeout")
        self.assertEqual(report["exit_code"], 124)
        self.assertTrue(report["sigterm_sent"])
        self.assertTrue(report["sigkill_sent"])
        self.assert_not_running(report["pid"])
        self.assert_not_running(int(marker.read_text()))
        self.assertLess(report["duration_seconds"], 2)

    def test_external_cancellation_cleans_process_group_and_writes_report(self):
        code, marker = self.child_tree()
        process = self.start(code)
        self.await_path(marker)
        process.send_signal(signal.SIGTERM)
        report, _ = self.finish(process)
        self.assertEqual(report["status"], "cancelled")
        self.assertEqual(report["cancel_signal"], signal.SIGTERM)
        self.assertEqual(report["exit_code"], 128 + signal.SIGTERM)
        self.assertTrue(report["sigkill_sent"])
        self.assert_not_running(report["pid"])
        self.assert_not_running(int(marker.read_text()))

    def test_normal_parent_exit_cleans_lingering_children_and_inherited_pipes(self):
        for close_output in (False, True):
            with self.subTest(close_child_output=close_output):
                code, marker = self.child_tree(parent_exits=True, close_child_output=close_output)
                marker.unlink(missing_ok=True)
                report, _ = self.finish(self.start(code))
                self.assertEqual(report["status"], "exited")
                self.assertEqual(report["exit_code"], 0)
                self.assertTrue(report["descendant_cleanup"])
                self.assertTrue(report["sigkill_sent"])
                self.assert_not_running(int(marker.read_text()))

    def test_invalid_limits_and_missing_argv_are_rejected(self):
        for flags in (
            ["--timeout-seconds", "nan"], ["--timeout-seconds", "inf"],
            ["--timeout-seconds", "0"], ["--timeout-seconds", "-1"],
            ["--timeout-seconds", "1", "--max-log-bytes", "0"],
            ["--timeout-seconds", "1", "--grace-seconds", "0"],
            ["--timeout-seconds", "1"],
        ):
            with self.subTest(flags=flags):
                result = subprocess.run(
                    [sys.executable, str(RUNNER), "--log", str(self.log), "--report", str(self.report), *flags],
                    capture_output=True, timeout=3,
                )
                self.assertEqual(result.returncode, 2)

    def test_log_cannot_overwrite_report(self):
        result = subprocess.run([
            sys.executable, str(RUNNER), "--timeout-seconds", "1", "--log", str(self.log),
            "--report", str(self.log), "--", sys.executable, "-c", "pass",
        ], capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 2)


@unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
class ProcessGroupTests(unittest.TestCase):
    def group(self):
        return BOUNDED.ProcessGroup(SimpleNamespace(pid=43210))

    def test_group_scan_distinguishes_zombies_and_live_members(self):
        for output, expected in (
            ("43210 Z\n43210 Z+\n123 S\n", False),
            ("43210 Z\n43210 S\n", True),
            ("123 S\n", False),
        ):
            with self.subTest(output=output), mock.patch.object(BOUNDED.sys, "platform", "linux"), mock.patch.object(
                BOUNDED.subprocess, "run", return_value=SimpleNamespace(stdout=output)
            ) as probe:
                self.assertEqual(BOUNDED.live_group_members(43210), expected)
                self.assertEqual(probe.call_args.kwargs["timeout"], 0.5)
                self.assertTrue(probe.call_args.kwargs["check"])

    def test_group_scan_failure_never_means_dead(self):
        for failure in (
            subprocess.TimeoutExpired("ps", 0.5),
            subprocess.CalledProcessError(1, "ps"),
        ):
            with self.subTest(failure=failure), mock.patch.object(
                BOUNDED.subprocess, "run", side_effect=failure
            ), self.assertRaises(type(failure)):
                BOUNDED.live_group_members(43210)
        with mock.patch.object(BOUNDED.sys, "platform", "linux"), mock.patch.object(
            BOUNDED.subprocess, "run", return_value=SimpleNamespace(stdout="invalid")
        ), self.assertRaises(ValueError):
            BOUNDED.live_group_members(43210)

    def darwin_probe(self, output, errors=b""):
        def run(command, **kwargs):
            self.assertEqual(command, ["/bin/ps", "-x", "-g", "43210", "-o", "pid=,pgid=,stat="])
            self.assertEqual(kwargs["timeout"], 0.5)
            self.assertTrue(kwargs["check"])
            self.assertEqual(kwargs["env"]["COMMAND_MODE"], "unix2003")
            self.assertEqual(kwargs["env"]["LC_ALL"], "C")
            self.assertNotEqual(kwargs["stdout"], subprocess.PIPE)
            self.assertNotEqual(kwargs["stderr"], subprocess.PIPE)
            kwargs["stdout"].write(output)
            kwargs["stderr"].write(errors)
            return SimpleNamespace(returncode=0)
        return mock.patch.object(BOUNDED.subprocess, "run", side_effect=run)

    def test_darwin_group_query_is_targeted_and_overrides_only_child_mode(self):
        for output, expected in (
            (b"43210 43210 Zs\n", False),
            (b"43210 43210 Zs\n43211 43210 Z+\n", False),
            (b"43210 43210 Zs\n43211 43210 S\n", True),
            (b"43210 43210 R<s\n", True),
        ):
            with self.subTest(output=output), mock.patch.object(BOUNDED.sys, "platform", "darwin"), \
                 mock.patch.dict(BOUNDED.os.environ, {"COMMAND_MODE": "legacy", "LC_ALL": "invalid-locale"}), \
                 self.darwin_probe(output):
                self.assertEqual(BOUNDED.live_group_members(43210), expected)
                self.assertEqual(BOUNDED.os.environ["COMMAND_MODE"], "legacy")
                self.assertEqual(BOUNDED.os.environ["LC_ALL"], "invalid-locale")

    def test_darwin_observation_rejects_ambiguous_malformed_and_truncated_records(self):
        anchor = b"43210 43210 Zs\n"
        invalid = [b"", b"\n", b"43211 43210 Z\n", b"43210 99 Z\n", anchor + anchor,
                   b"43210 43210 Z", anchor + b"43211 43210", b"43210 43210 ?\n",
                   b"43210 43210 Zunknown\n", b"43210 43210 ZE\n", b"43210 43210 Z\x00\n",
                   b"43210 43210 Z\r\n", b"43210 43210 Z\xff\n", b"0 43210 Z\n",
                   b"-1 43210 Z\n", b"43210 43210 Z extra\n", b"2147483648 43210 Z\n" + anchor,
                   anchor + b"1 43210 Z" + b" " * 65 + b"\n",
                   anchor + b"x" * BOUNDED.MAX_GROUP_OBSERVATION_BYTES,
                   anchor + b"".join(f"{n} 43210 Z\n".encode() for n in range(1, 1025)),
                   b"43210 43210 S\nmalformed\n"]
        for output in invalid:
            with self.subTest(output=output[:80]), mock.patch.object(BOUNDED.sys, "platform", "darwin"), \
                 self.darwin_probe(output), self.assertRaises(ValueError):
                BOUNDED.live_group_members(43210)

    def test_darwin_diagnostic_even_with_zero_exit_never_retires_owned_group(self):
        group = self.group()
        group.exited = True
        with mock.patch.object(BOUNDED.sys, "platform", "darwin"), \
             self.darwin_probe(b"43210 43210 Zs\n", b"Failure calling sysctl: permission denied\n"), \
             self.assertRaises(RuntimeError):
            group.alive()
        self.assertFalse(group.retired)

    def test_darwin_query_failures_and_invalid_group_ids_fail_closed(self):
        for failure in (subprocess.TimeoutExpired("ps", 0.5), subprocess.CalledProcessError(1, "ps"),
                        PermissionError(errno.EPERM, "observation denied"), FileNotFoundError("/bin/ps")):
            with self.subTest(failure=failure), mock.patch.object(BOUNDED.sys, "platform", "darwin"), \
                 mock.patch.object(BOUNDED.subprocess, "run", side_effect=failure), self.assertRaises(type(failure)):
                BOUNDED.live_group_members(43210)
        for pgid in (0, -1, True, "43210", 43210.0, 2147483648):
            with self.subTest(pgid=pgid), mock.patch.object(BOUNDED.subprocess, "run") as probe, \
                 self.assertRaises(ValueError):
                BOUNDED.darwin_group_snapshot(pgid)
            probe.assert_not_called()

    def test_observer_timings_include_failed_attempts_without_changing_deadline(self):
        group = self.group()
        with mock.patch.object(BOUNDED.time, "monotonic", side_effect=[1.0, 1.1, 2.0, 2.3]), \
             mock.patch.object(BOUNDED, "live_group_members", side_effect=[True, subprocess.TimeoutExpired("ps", 0.5)]):
            self.assertTrue(group.observe_members())
            with self.assertRaises(subprocess.TimeoutExpired):
                group.observe_members()
        self.assertEqual(group.observations["count"], 2)
        self.assertEqual(group.observations["failures"], 1)
        self.assertAlmostEqual(group.observations["total_seconds"], 0.4)
        self.assertAlmostEqual(group.observations["max_seconds"], 0.3)
        self.assertEqual(group.observations["timeout_seconds"], 0.5)
        self.assertFalse(group.retired)

    @unittest.skipUnless(sys.platform == "darwin", "requires the actual Darwin ps selector and zombie semantics")
    def test_native_darwin_selector_keeps_zombie_anchor_and_finds_no_tty_descendant(self):
        for descendant in (False, True):
            with self.subTest(descendant=descendant), tempfile.TemporaryDirectory() as tmp:
                marker = Path(tmp) / "descendant.pid"
                descendant_code = ("import os,signal,time; from pathlib import Path; "
                                   "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                                   f"Path({str(marker)!r}).write_text(str(os.getpid())); time.sleep(30)")
                code = ("import os,sys,subprocess,time; from pathlib import Path\n"
                        "try: fd=os.open('/dev/tty',os.O_RDONLY)\n"
                        "except OSError: pass\n"
                        "else: os.close(fd); sys.exit(77)\n")
                if descendant:
                    code += (f"subprocess.Popen([sys.executable,'-c',{descendant_code!r}])\n"
                             f"while not Path({str(marker)!r}).exists(): time.sleep(0.01)\n")
                code += "sys.exit(23)\n"
                child = subprocess.Popen([sys.executable, "-c", code], start_new_session=True,
                                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                group = BOUNDED.ProcessGroup(child)
                try:
                    until = time.monotonic() + 3
                    while not group.leader_exited() and time.monotonic() < until:
                        time.sleep(0.01)
                    self.assertTrue(group.leader_exited())
                    self.assertIsNone(child.returncode)  # Leader is still unreaped.
                    snapshot = BOUNDED.darwin_group_snapshot(child.pid)
                    self.assertTrue(snapshot[child.pid].startswith("Z"))
                    self.assertEqual(group.observe_members(), descendant)
                    if descendant:
                        self.assertFalse(snapshot[int(marker.read_text())].startswith("Z"))
                        self.assertTrue(group.send(signal.SIGKILL))
                        until = time.monotonic() + 3
                        while group.alive() and time.monotonic() < until:
                            time.sleep(0.01)
                        self.assertFalse(group.alive())
                    print("[darwin-group-acceptance] " + json.dumps({
                        "descendant": descendant, "snapshot": snapshot, "observations": group.observations,
                        "leaderUnreapedDuringObservation": child.returncode is None,
                    }, sort_keys=True))
                    group.close()
                    self.assertEqual(child.wait(timeout=1), 23)
                    with mock.patch.object(BOUNDED.os, "killpg") as kill:
                        self.assertFalse(group.send(signal.SIGKILL))
                        kill.assert_not_called()
                finally:
                    try:
                        if not group.retired:
                            group.send(signal.SIGKILL)
                    finally:
                        group.close()
                        child.wait(timeout=1)
    def test_permission_error_requires_proof_of_no_live_members(self):
        for signum in (signal.SIGTERM, signal.SIGKILL):
            for live in (False, True):
                with self.subTest(signum=signum, live=live):
                    group = self.group()
                    denied = PermissionError(errno.EPERM, "not permitted")
                    with mock.patch.object(BOUNDED.os, "killpg", side_effect=denied), mock.patch.object(
                        BOUNDED, "live_group_members", return_value=live
                    ) as probe:
                        if live:
                            with self.assertRaises(PermissionError) as raised:
                                group.send(signum)
                            self.assertIs(raised.exception, denied)
                            self.assertFalse(group.retired)
                        else:
                            self.assertFalse(group.send(signum))
                            self.assertTrue(group.retired)
                        probe.assert_called_once_with(43210)

    def test_permission_error_with_failed_probe_does_not_retire_group(self):
        group = self.group()
        with mock.patch.object(BOUNDED.os, "killpg", side_effect=PermissionError(errno.EPERM, "denied")), mock.patch.object(
            BOUNDED, "live_group_members", side_effect=subprocess.TimeoutExpired("ps", 0.5)
        ), self.assertRaises(subprocess.TimeoutExpired):
            group.send(signal.SIGKILL)
        self.assertFalse(group.retired)

    def test_retired_group_is_never_signalled_again(self):
        group = self.group()
        with mock.patch.object(BOUNDED.os, "killpg", side_effect=ProcessLookupError) as kill:
            self.assertFalse(group.send(signal.SIGTERM))
            self.assertFalse(group.send(signal.SIGKILL))
            self.assertFalse(group.alive())
            kill.assert_called_once()
        group = self.group()
        group.close()
        with mock.patch.object(BOUNDED.os, "killpg") as kill:
            self.assertFalse(group.send(signal.SIGKILL))
            kill.assert_not_called()

    def test_exit_observation_keeps_leader_unreaped_until_cleanup_ends(self):
        child = subprocess.Popen([sys.executable, "-c", "import sys; sys.exit(23)"], start_new_session=True)
        group = BOUNDED.ProcessGroup(child)
        try:
            until = time.monotonic() + 3
            while not group.leader_exited() and time.monotonic() < until:
                time.sleep(0.01)
            self.assertTrue(group.leader_exited())
            self.assertIsNone(child.returncode)
            self.assertFalse(group.alive())
            group.close()
            self.assertEqual(child.wait(timeout=1), 23)
            with mock.patch.object(BOUNDED.os, "killpg") as kill:
                self.assertFalse(group.send(signal.SIGKILL))
                kill.assert_not_called()
        finally:
            group.close()
            if child.poll() is None:
                child.kill()
            child.wait(timeout=1)

    def test_older_macos_kqueue_observes_exit_without_polling_child(self):
        for early_exit in (False, True):
            with self.subTest(early_exit=early_exit):
                group = self.group()
                watcher = mock.Mock()
                watcher.control.side_effect = (ProcessLookupError() if early_exit else [[], [], [object()]])
                backend = SimpleNamespace(
                    kqueue=mock.Mock(return_value=watcher), kevent=mock.Mock(),
                    KQ_FILTER_PROC=1, KQ_EV_ADD=2, KQ_EV_ONESHOT=4, KQ_NOTE_EXIT=8,
                )
                with mock.patch.object(BOUNDED, "os", SimpleNamespace()), mock.patch.object(BOUNDED, "select", backend):
                    if not early_exit:
                        self.assertFalse(group.leader_exited())
                    self.assertTrue(group.leader_exited())
                    self.assertTrue(group.leader_exited())
                    group.close()
                backend.kqueue.assert_called_once()
                watcher.close.assert_called_once()

    def test_cleanup_errors_still_kill_child_write_report_and_restore_handlers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = argparse.Namespace(
                log=root / "command.log", report=root / "command.json",
                command=[sys.executable, "-c", "import time; time.sleep(30)"],
                timeout_seconds=3, grace_seconds=0.05, max_log_bytes=4096,
            )
            handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
            write_report = BOUNDED.write_report
            send = BOUNDED.ProcessGroup.send

            def fail_running_report(path, report):
                if report["status"] == "running":
                    raise OSError("injected report failure")
                write_report(path, report)

            def fail_term(group, signum):
                if signum == signal.SIGTERM:
                    raise RuntimeError("injected TERM failure")
                return send(group, signum)

            stderr = io.StringIO()
            with mock.patch.object(BOUNDED, "write_report", side_effect=fail_running_report), mock.patch.object(
                BOUNDED.ProcessGroup, "send", fail_term
            ), mock.patch.object(BOUNDED.ProcessGroup, "alive", side_effect=subprocess.TimeoutExpired("ps", 0.5)), contextlib.redirect_stderr(stderr):
                self.assertEqual(BOUNDED.run(args), 125)
            report = json.loads(args.report.read_text())
            self.assertEqual(report["status"], "wrapper_error")
            self.assertEqual(report["exit_code"], 125)
            self.assertIn("injected report failure", report["error"])
            self.assertEqual(len(report["cleanup_errors"]), 2)
            self.assertTrue(report["sigkill_sent"])
            self.assertEqual(report["child_returncode"], -signal.SIGKILL)
            self.assertLess(report["duration_seconds"], 2)
            self.assertIn("[bounded-command]", stderr.getvalue())
            for sig, handler in handlers.items():
                self.assertIs(signal.getsignal(sig), handler)

    def test_live_group_after_kill_is_reported_as_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = argparse.Namespace(
                log=root / "command.log", report=root / "command.json",
                command=[sys.executable, "-c", "import time; time.sleep(30)"],
                timeout_seconds=0.05, grace_seconds=0.05, max_log_bytes=4096,
            )
            with mock.patch.object(BOUNDED.ProcessGroup, "alive", return_value=True), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(BOUNDED.run(args), 125)
            report = json.loads(args.report.read_text())
            self.assertEqual(report["status"], "wrapper_error")
            self.assertIn("live members after SIGKILL", report["error"])
            self.assertLess(report["duration_seconds"], 2)

    def test_live_permission_denial_reports_bounded_cleanup_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = argparse.Namespace(
                log=root / "command.log", report=root / "command.json",
                command=[sys.executable, "-c", "import time; time.sleep(30)"],
                timeout_seconds=0.05, grace_seconds=0.05, max_log_bytes=4096,
            )
            children = []
            popen = subprocess.Popen

            def capture_child(*args, **kwargs):
                child = popen(*args, **kwargs)
                children.append(child)
                return child

            try:
                with mock.patch.object(BOUNDED.subprocess, "Popen", side_effect=capture_child), mock.patch.object(
                    BOUNDED.os, "killpg", side_effect=PermissionError(errno.EPERM, "injected live denial")
                ), mock.patch.object(BOUNDED, "live_group_members", return_value=True), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(BOUNDED.run(args), 125)
                report = json.loads(args.report.read_text())
                self.assertEqual(report["status"], "wrapper_error")
                self.assertEqual(report["exit_code"], 125)
                self.assertIn("PermissionError", report["error"])
                self.assertFalse(report["sigterm_sent"])
                self.assertFalse(report["sigkill_sent"])
                self.assertIsNone(report["child_returncode"])
                self.assertLess(report["duration_seconds"], 3)
                self.assertIsNone(children[0].poll())  # Denial was not reported as successful cleanup.
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=1)


if __name__ == "__main__":
    unittest.main()
