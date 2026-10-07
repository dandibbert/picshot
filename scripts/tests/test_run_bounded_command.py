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
        report, stdout = self.finish(self.start(
            "import os\nwhile True: os.write(1, b'x' * 65536)", timeout=0.2, cap=17
        ))
        self.assertEqual(report["status"], "timeout")
        self.assertEqual(report["exit_code"], 124)
        self.assertEqual(stdout, b"x" * 17)
        self.assertTrue(report["log_truncated"])
        self.assertLess(report["duration_seconds"], 2)

    def child_tree(self, *, parent_exits=False, close_child_output=False):
        marker = self.root / "grandchild.pid"
        child_code = (
            "import os, signal, time; from pathlib import Path; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            f"Path({str(marker)!r}).write_text(str(os.getpid())); time.sleep(30)"
        )
        code = (
            "import signal, subprocess, sys, time; from pathlib import Path; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            f"subprocess.Popen([sys.executable, '-c', {child_code!r}]"
            + (", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL" if close_child_output else "")
            + "); "
            f"marker = Path({str(marker)!r})\n"
            "while not marker.exists(): time.sleep(0.01)\n"
            + ("sys.exit(0)\n" if parent_exits else "time.sleep(30)\n")
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
            with self.subTest(output=output), mock.patch.object(
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
        with mock.patch.object(BOUNDED.subprocess, "run", return_value=SimpleNamespace(stdout="invalid")):
            with self.assertRaises(ValueError):
                BOUNDED.live_group_members(43210)

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
