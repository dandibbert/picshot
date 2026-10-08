#!/usr/bin/env python3
"""Run argv directly with a deadline, bounded streamed output and a JSON report.

Exit 124 means deadline exceeded, 128 + signal means external cancellation,
125 means a wrapper error, and 127 means the executable could not be started.
Otherwise preserve the command's exit status (or 128 + its terminating signal).
The log retains the first --max-log-bytes bytes; excess output is still drained.
The command and its descendants must not detach from their process group.
"""

import argparse
import datetime
import json
import math
import os
from pathlib import Path
import re
import select
import selectors
import signal
import subprocess
import sys
import tempfile
import time


GROUP_OBSERVATION_SECONDS = 0.5
MAX_GROUP_OBSERVATION_BYTES = 64 * 1024
MAX_GROUP_OBSERVATION_ROWS = 1024
# Apple ps/print.c: state plus ordered nice/traced/exit/wait/locked/session/TTY flags.
DARWIN_GROUP_ROW = re.compile(
    rb"[ \t]*([1-9][0-9]{0,9})[ \t]+([1-9][0-9]{0,9})[ \t]+"
    rb"(Z[<N]?X?V?L?s?\+?|[RUSITH][<N]?X?E?V?L?s?\+?)[ \t]*\n"
)


def positive_seconds(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return number


def positive_bytes(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return number


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout-seconds", type=positive_seconds, required=True)
    parser.add_argument("--grace-seconds", type=positive_seconds, default=5.0)
    parser.add_argument("--max-log-bytes", type=positive_bytes, default=8 * 1024 * 1024)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    if args.log.resolve() == args.report.resolve():
        parser.error("--log and --report must name different files")
    return args


def write_report(path, report):
    # A runner-level hard kill leaves the last complete 'running' or
    # 'terminating' report, instead of an empty or half-written JSON file.
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def darwin_group_snapshot(pgid):
    """Validate one non-atomic, group-specific snapshot with an unreaped anchor."""
    if type(pgid) is not int or not 0 < pgid <= 2147483647:
        raise ValueError("invalid owned process group")
    # A single -g selector takes KERN_PROC_PGRP; -x includes no-TTY children.
    # Do not add -A/-a/-p, which can broaden selection. Legacy mode ignores -g.
    # https://github.com/apple-oss-distributions/adv_cmds/blob/main/ps/ps.c
    # https://github.com/apple-oss-distributions/Libc/blob/main/gen/compat.5
    command = ["/bin/ps", "-x", "-g", str(pgid), "-o", "pid=,pgid=,stat="]
    environment = {**os.environ, "COMMAND_MODE": "unix2003", "LC_ALL": "C"}
    # File-backed capture avoids unbounded in-memory communicate() buffers.
    # The existing process timeout remains 0.5s; read at most the cap plus one.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        subprocess.run(command, stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                       env=environment, check=True, timeout=GROUP_OBSERVATION_SECONDS)
        errors.seek(0)
        if errors.read(1):
            # Some Darwin sysctl failures print stderr but return exit status 0.
            raise RuntimeError("Darwin process-group observation emitted a diagnostic")
        output.seek(0)
        data = output.read(MAX_GROUP_OBSERVATION_BYTES + 1)
    if not data or len(data) > MAX_GROUP_OBSERVATION_BYTES or not data.endswith(b"\n"):
        raise ValueError("empty, oversized or truncated process-group observation")
    rows = data.splitlines(keepends=True)
    if len(rows) > MAX_GROUP_OBSERVATION_ROWS:
        raise ValueError("too many process-group observation rows")
    members = {}
    for row in rows:
        match = DARWIN_GROUP_ROW.fullmatch(row) if len(row) <= 64 else None
        if match is None:
            raise ValueError("malformed or unknown process-group status")
        pid, group = int(match[1]), int(match[2])
        if pid > 2147483647 or group != pgid or pid in members:
            raise ValueError("wrong group, invalid PID or duplicate process-group row")
        members[pid] = match[3].decode("ascii")
    if pgid not in members:
        raise ValueError("unreaped process-group leader missing from observation")
    return members


def live_group_members(pgid):
    """Observe executable members; ambiguous/error observations never mean dead."""
    if sys.platform == "darwin":
        return any(not state.startswith("Z") for state in darwin_group_snapshot(pgid).values())
    # Preserve the portable fallback: Linux -g does not have Darwin semantics.
    result = subprocess.run(
        ["ps", "-A", "-o", "pgid=,stat="],
        stdin=subprocess.DEVNULL, capture_output=True, text=True,
        check=True, timeout=GROUP_OBSERVATION_SECONDS,
    )
    for line in result.stdout.splitlines():
        group, state = line.split()
        if int(group) == pgid and not state.startswith("Z"):
            return True
    return False


class ProcessGroup:
    """Keep the unreaped leader as an identity anchor until all signalling ends."""

    def __init__(self, process):
        self.process = process
        self.retired = False
        self.exited = False
        self.watcher = None
        self.observations = {
            "backend": "darwin-ps-pgrp" if sys.platform == "darwin" else "portable-ps-all",
            "timeout_seconds": GROUP_OBSERVATION_SECONDS,
            "count": 0, "failures": 0, "total_seconds": 0.0, "max_seconds": 0.0,
            "atomic_snapshot": False,
        }

    def observe_members(self):
        started = time.monotonic()
        self.observations["count"] += 1
        try:
            return live_group_members(self.process.pid)
        except Exception:
            self.observations["failures"] += 1
            raise
        finally:
            elapsed = time.monotonic() - started
            self.observations["total_seconds"] += elapsed
            self.observations["max_seconds"] = max(self.observations["max_seconds"], elapsed)

    def leader_exited(self):
        if not self.exited:
            if hasattr(os, "waitid"):
                self.exited = os.waitid(
                    os.P_PID, self.process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT
                ) is not None
            else:
                # Python before 3.13 does not expose waitid on macOS. A kqueue
                # exit watch observes the child without reaping/releasing its PID.
                if self.watcher is None:
                    self.watcher = select.kqueue()
                    try:
                        self.watcher.control([select.kevent(
                            self.process.pid, filter=select.KQ_FILTER_PROC,
                            flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                            fflags=select.KQ_NOTE_EXIT,
                        )], 0, 0)
                    except ProcessLookupError:
                        self.exited = True  # Our child exited before registration.
                if not self.exited:
                    self.exited = bool(self.watcher.control(None, 1, 0))
        return self.exited

    def alive(self):
        if self.retired:
            return False
        if not self.leader_exited():
            return True
        if self.observe_members():
            return True
        self.retired = True
        return False

    def send(self, signum):
        if self.retired:
            return False
        try:
            os.killpg(self.process.pid, signum)
            return True
        except ProcessLookupError:
            self.retired = True
            return False
        except PermissionError:
            # Darwin killpg1 filters out zombies and may return EPERM for a
            # zombie-only group. EPERM alone never proves the group is dead.
            # https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sig.c
            if self.observe_members():
                raise
            self.retired = True
            return False

    def close(self):
        # Never touch this numeric PGID after reaping releases the leader PID.
        self.retired = True
        if self.watcher is not None:
            self.watcher.close()


def run(args):
    args.log.parent.mkdir(parents=True, exist_ok=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    report = {
        "schema_version": 1,
        "status": "starting",
        "command": args.command,
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "timeout_seconds": args.timeout_seconds,
        "grace_seconds": args.grace_seconds,
        "max_log_bytes": args.max_log_bytes,
        "pid": None,
        "child_returncode": None,
        "exit_code": None,
        "cancel_signal": None,
        "sigterm_sent": False,
        "sigkill_sent": False,
        "descendant_cleanup": False,
        "output_bytes": 0,
        "log_bytes": 0,
        "log_truncated": False,
    }
    received_signals = []

    def cancel(signum, _frame):
        # Do I/O and process cleanup in the main loop, not in a signal handler.
        if len(received_signals) < 2:
            received_signals.append(signum)

    previous_handlers = {
        signum: signal.signal(signum, cancel)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    process = None
    group = None
    termination_started = None
    kill_at = None
    reason = None
    exit_code = 125
    try:
        write_report(args.report, report)
        with args.log.open("wb", buffering=0) as log, selectors.DefaultSelector() as selector:
            try:
                process = subprocess.Popen(
                    args.command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                    shell=False,
                )
            except OSError as error:
                report.update(status="spawn_error", error=str(error))
                exit_code = 127
            else:
                group = ProcessGroup(process)
                report.update(status="running", pid=process.pid)
                write_report(args.report, report)
                os.set_blocking(process.stdout.fileno(), False)
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    now = time.monotonic()
                    leader_exited = group.leader_exited()
                    if reason is None:
                        if received_signals:
                            reason = "cancelled"
                            report["cancel_signal"] = received_signals[0]
                        elif now - start >= args.timeout_seconds:
                            reason = "timeout"
                        elif leader_exited:
                            reason = "exited"
                            report["descendant_cleanup"] = group.alive()
                    if reason is not None and termination_started is None:
                        # Even a normally exiting parent may leave descendants
                        # holding the output pipe (or running with it closed).
                        termination_started = now
                        report["sigterm_sent"] = group.send(signal.SIGTERM)
                        report.update(status="terminating", termination_reason=reason)
                        write_report(args.report, report)
                    if termination_started is not None and kill_at is None:
                        if now - termination_started >= args.grace_seconds or len(received_signals) > 1:
                            report["sigkill_sent"] = group.send(signal.SIGKILL)
                            kill_at = now
                            write_report(args.report, report)

                    # Read at most one bounded chunk per tick so noisy commands
                    # cannot starve deadline or cancellation handling.
                    for key, _ in selector.select(timeout=0.05):
                        try:
                            data = os.read(key.fd, 64 * 1024)
                        except BlockingIOError:
                            continue
                        if not data:
                            selector.unregister(key.fileobj)
                            continue
                        report["output_bytes"] += len(data)
                        remaining = args.max_log_bytes - report["log_bytes"]
                        captured = data[:remaining]
                        if captured:
                            log.write(captured)
                            report["log_bytes"] += len(captured)
                            sys.stdout.buffer.write(captured)
                            sys.stdout.buffer.flush()
                        report["log_truncated"] = report["output_bytes"] > report["log_bytes"]

                    if reason is not None:
                        if group.leader_exited() and not selector.get_map() and not group.alive():
                            break
                        # Bound cleanup even for a detached pipe holder, but
                        # never claim success with observed live group members.
                        if kill_at is not None and time.monotonic() - kill_at >= 0.5:
                            if group.alive():
                                raise RuntimeError("process group still has live members after SIGKILL")
                            break
                group.close()
                report["child_returncode"] = process.wait(timeout=1)
                report["status"] = reason
                if reason == "timeout":
                    exit_code = 124
                elif reason == "cancelled":
                    exit_code = 128 + report["cancel_signal"]
                else:
                    code = report["child_returncode"]
                    exit_code = code if code >= 0 else 128 - code
    except Exception as error:
        report.update(status="wrapper_error", error=f"{type(error).__name__}: {error}")
        exit_code = 125
    finally:
        def cleanup_error(error):
            nonlocal exit_code
            message = f"{type(error).__name__}: {error}"
            report.setdefault("cleanup_errors", []).append(message)
            report.update(status="wrapper_error")
            report.setdefault("error", message)
            exit_code = 125

        # Each stage is independent: a failed probe/TERM must not prevent KILL,
        # a bounded wait, the final report, or restoration of signal handlers.
        if process is not None:
            if group is not None:
                if not group.retired and kill_at is None:
                    if termination_started is None:
                        termination_started = time.monotonic()
                        try:
                            report["sigterm_sent"] = group.send(signal.SIGTERM)
                        except Exception as error:
                            cleanup_error(error)
                    try:
                        while time.monotonic() - termination_started < args.grace_seconds:
                            if not group.alive():
                                break
                            time.sleep(0.05)
                    except Exception as error:
                        cleanup_error(error)
                    try:
                        report["sigkill_sent"] = group.send(signal.SIGKILL)
                    except Exception as error:
                        cleanup_error(error)
                try:
                    group.close()
                except Exception as error:
                    cleanup_error(error)
            try:
                report["child_returncode"] = process.wait(timeout=1)
            except Exception as error:
                cleanup_error(error)
            if process.stdout is not None:
                try:
                    process.stdout.close()
                except Exception as error:
                    cleanup_error(error)
        report.update(exit_code=exit_code, duration_seconds=round(time.monotonic() - start, 3))
        if group is not None and hasattr(group, "observations"):
            report["group_observation"] = group.observations
        try:
            try:
                write_report(args.report, report)
            except Exception as error:
                cleanup_error(error)
                report["exit_code"] = exit_code
            print("\n[bounded-command] " + json.dumps(report, sort_keys=True), file=sys.stderr, flush=True)
        finally:
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)
    return exit_code


if __name__ == "__main__":
    sys.exit(run(parse_args()))
