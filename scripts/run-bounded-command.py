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
import selectors
import signal
import subprocess
import sys
import time


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


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False


def signal_group(pgid, signum):
    try:
        os.killpg(pgid, signum)
        return True
    except ProcessLookupError:
        return False


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
                report.update(status="running", pid=process.pid)
                write_report(args.report, report)
                os.set_blocking(process.stdout.fileno(), False)
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    now = time.monotonic()
                    returncode = process.poll()
                    if reason is None:
                        if received_signals:
                            reason = "cancelled"
                            report["cancel_signal"] = received_signals[0]
                        elif now - start >= args.timeout_seconds:
                            reason = "timeout"
                        elif returncode is not None:
                            reason = "exited"
                            report["descendant_cleanup"] = group_exists(process.pid)
                    if reason is not None and termination_started is None:
                        # Even a normally exiting parent may leave descendants
                        # holding the output pipe (or running with it closed).
                        termination_started = now
                        report["sigterm_sent"] = signal_group(process.pid, signal.SIGTERM)
                        report.update(status="terminating", termination_reason=reason)
                        write_report(args.report, report)
                    if termination_started is not None and kill_at is None:
                        if now - termination_started >= args.grace_seconds or len(received_signals) > 1:
                            report["sigkill_sent"] = signal_group(process.pid, signal.SIGKILL)
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
                        if process.poll() is not None and not selector.get_map() and not group_exists(process.pid):
                            break
                        # Zombies may retain a process-group ID until reaped by
                        # their new parent. Never wait indefinitely for them, or
                        # for a pipe inherited by a process that detached itself.
                        if kill_at is not None and time.monotonic() - kill_at >= 0.5:
                            break
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
        # Also clean up after an I/O/reporting error. Preserve TERM -> KILL even
        # if the leader has already exited but its children are still alive.
        if process is not None:
            if group_exists(process.pid):
                if termination_started is None:
                    termination_started = time.monotonic()
                    report["sigterm_sent"] = signal_group(process.pid, signal.SIGTERM)
                if kill_at is None:
                    while group_exists(process.pid) and time.monotonic() - termination_started < args.grace_seconds:
                        process.poll()
                        time.sleep(0.05)
                    report["sigkill_sent"] = signal_group(process.pid, signal.SIGKILL)
                else:
                    signal_group(process.pid, signal.SIGKILL)
            try:
                report["child_returncode"] = process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                report.update(status="wrapper_error", error="child did not exit after SIGKILL")
                exit_code = 125
            if process.stdout is not None:
                process.stdout.close()
        report.update(exit_code=exit_code, duration_seconds=round(time.monotonic() - start, 3))
        try:
            write_report(args.report, report)
            print("\n[bounded-command] " + json.dumps(report, sort_keys=True), file=sys.stderr, flush=True)
        finally:
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)
    return exit_code


if __name__ == "__main__":
    sys.exit(run(parse_args()))
