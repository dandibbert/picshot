#!/usr/bin/env python3
"""Read one source/PID/path/time-bound .ips after the text gate's first failure.

Diagnostic only: never launches/signals a process, changes sandbox policy, or
turns a failed native gate into acceptance. No raw crash report is copied.
"""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import sys
import time
import uuid

NAME = 'PicShotTextScriptHelper'
RELATIVE = 'Contents/Helpers/' + NAME
POLL_SECONDS = 15
REPORT_LIMIT = 1024 * 1024
OUTPUT_LIMIT = 256 * 1024
MAX_CANDIDATES = 32
MAX_READS = 64


def need(value, reason):
    if not value:
        raise ValueError(reason)


def open_directory(path):
    """Open every component without following symlinks (also avoids TOCTOU)."""
    path = Path(os.path.abspath(path))
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY |
                              os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_at(directory_fd, name, limit):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK |
                 os.O_CLOEXEC, dir_fd=directory_fd)
    try:
        before = os.fstat(fd)
        need(stat.S_ISREG(before.st_mode) and before.st_size <= limit,
             'unsafe-or-oversized-file')
        chunks, size = [], 0
        while size <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        after = os.fstat(fd)
        need(size <= limit and size == before.st_size == after.st_size and
             before.st_mtime_ns == after.st_mtime_ns, 'changed-or-oversized-file')
        return b''.join(chunks)
    finally:
        os.close(fd)


def read(path, limit):
    fd = open_directory(Path(path).parent)
    try:
        return read_at(fd, Path(path).name, limit)
    finally:
        os.close(fd)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pairs(items):
    result = {}
    for key, value in items:
        need(key not in result, 'duplicate-json-key')
        result[key] = value
    return result


def decode(data):
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda _: need(False, 'nonfinite-json'))


def timestamp(value):
    need(isinstance(value, str) and len(value) < 100, 'invalid-timestamp')
    normalized = re.sub(r' ([+-]\d{2})(\d{2})$', r'\1:\2', value)
    result = dt.datetime.fromisoformat(normalized.replace('Z', '+00:00'))
    need(result.tzinfo is not None, 'timestamp-needs-timezone')
    return result.astimezone(dt.timezone.utc)


def macho_uuid(data):
    # The gate builds one native arm64 executable, not a universal/fat binary.
    need(len(data) >= 32 and data[:4] == b'\xcf\xfa\xed\xfe', 'not-thin-mach-o64')
    count, command_bytes = struct.unpack_from('<II', data, 16)
    need(count <= 1024 and 32 + command_bytes <= len(data), 'invalid-mach-o-commands')
    offset, found = 32, []
    for _ in range(count):
        need(offset + 8 <= 32 + command_bytes, 'truncated-mach-o-command')
        command, size = struct.unpack_from('<II', data, offset)
        need(size >= 8 and offset + size <= 32 + command_bytes, 'invalid-mach-o-command')
        if command == 0x1B:
            need(size == 24, 'invalid-lc-uuid')
            found.append(str(uuid.UUID(bytes=data[offset + 8:offset + 24])).upper())
        offset += size
    need(len(found) == 1 and offset == 32 + command_bytes, 'missing-or-ambiguous-lc-uuid')
    return found[0]


def bind(directory, source, command_path):
    need(re.fullmatch('[0-9a-f]{40}', source), 'invalid-source-commit')
    paths = [directory / 'build-identity.json',
             directory / 'evidence/text-script-gate-report.json', command_path]
    raw = [read(path, 1024 * 1024) for path in paths]
    build, native, command = map(decode, raw)
    need(build['schemaVersion'] == native['schemaVersion'] == command['schema_version'] == 1,
         'unsupported-receipt-schema')
    need(build['sourceCommit'] == native['sourceSHA'] == source and
         native['generatedInputsOnly'] is True and native['passed'] is False,
         'source-or-failed-native-gate-mismatch')
    app = directory / 'PicShotTextScriptGate.app'
    need(build['appPath'] == str(app) and build['architecture'] == 'arm64' and
         build['appSignatureVerified'] is True and
         build['helperEntitlementsVerifiedAfterOuterSigning'] is True,
         'signed-build-identity-mismatch')
    helpers = [h for h in build['helpers'] if h['identifier'] == 'com.picshot.TextScriptHelper']
    need(len(helpers) == 1, 'ambiguous-helper-identity')
    helper = helpers[0]
    need(helper['path'] == RELATIVE and helper['observedIdentifier'] == helper['identifier'] and
         helper['entitlements'] == {'com.apple.security.app-sandbox': True},
         'unexpected-signed-helper')
    helper_bytes = read(app / RELATIVE, 32 * 1024 * 1024)
    need(sha(helper_bytes) == helper['sha256'] and len(helper_bytes) == helper['bytes'],
         'signed-helper-bytes-mismatch')
    checks = native['checks']
    need(len(checks) == 2 and checks[0]['name'] == 'signed-source-identity' and
         checks[0]['passed'] is True and checks[1]['name'] == 'unicode-normalization' and
         checks[1]['subject'] == 'actual-helper' and checks[1]['passed'] is False,
         'not-the-first-owned-helper-failure')
    metrics = checks[1]['metrics']
    need(type(metrics['childPID']) is int and metrics['childPID'] > 1 and
         metrics['childLaunched'] is True and metrics['outcome'] == 'abnormalExit' and
         metrics['terminationReason'] == 'uncaughtSignal' and
         all(metrics[k] is True for k in ['childExitConfirmed', 'pipesDrained', 'admissionReleased']),
         'owned-abnormal-exit-or-cleanup-unconfirmed')
    signature = metrics['signature']
    need(signature['appIdentifier'] == 'com.picshot.TextScriptGate' and
         signature['helperIdentifier'] == helper['identifier'] and
         signature['helperCDHash'] == helper['observedCDHash'] and
         signature['helperEntitlements'] == ['com.apple.security.app-sandbox'] and
         signature['appAndHelperStrictlyValidated'] is True, 'launch-signature-mismatch')
    expected_command = [str(app / 'Contents/MacOS/PicShotTextScriptGate'), '--app', str(app),
                        '--output', str(directory / 'evidence'), '--source', source]
    duration = command['duration_seconds']
    need(command['command'] == expected_command and command['status'] == 'exited' and
         command['exit_code'] == command['child_returncode'] == 1 and
         type(command['pid']) is int and command['pid'] > 1 and
         type(duration) in (int, float) and math.isfinite(duration) and 0 < duration <= 180 and
         command['sigterm_sent'] is False and command['sigkill_sent'] is False,
         'native-command-receipt-mismatch')
    start = timestamp(command['started_at'])
    end = start + dt.timedelta(seconds=duration)
    return {'sourceCommit': source, 'childPID': metrics['childPID'], 'parentPID': command['pid'],
            'processName': NAME, 'expectedProcPath': str(app / RELATIVE),
            'helperSHA256': helper['sha256'], 'helperCDHash': helper['observedCDHash'],
            'helperMachOUUID': macho_uuid(helper_bytes), 'nativeTerminationSignal': metrics['terminationStatus'],
            'nativeCommandStart': start.isoformat(), 'nativeCommandEnd': end.isoformat(),
            'captureDelayAllowanceSeconds': POLL_SECONDS,
            'inputSHA256': {path.name: sha(data) for path, data in zip(paths, raw)}}


def parse_ips(data):
    # Apple .ips files have a one-line metadata JSON object then a report object.
    first, separator, rest = data.partition(b'\n')
    need(separator and len(first) <= 65536, 'missing-ips-header')
    header, body = decode(first), decode(rest)
    need(isinstance(header, dict) and isinstance(body, dict) and
         header.get('bug_type') == '309', 'not-an-ips-crash-report')
    return body


def match(body, binding):
    need(type(body.get('pid')) is int and body['pid'] == binding['childPID'] and
         body.get('procName') == NAME, 'foreign-pid-or-name')
    if 'parentPid' in body:
        need(type(body['parentPid']) is int and body['parentPid'] == binding['parentPID'],
             'foreign-parent-pid')
    start, end = timestamp(binding['nativeCommandStart']), timestamp(binding['nativeCommandEnd'])
    launch, capture = timestamp(body.get('procLaunch')), timestamp(body.get('captureTime'))
    need(start <= launch <= end and launch <= capture <= end + dt.timedelta(seconds=POLL_SECONDS),
         'outside-owned-run-window')
    path = body.get('procPath')
    if path == binding['expectedProcPath']:
        return 'exact-pid-process-path-and-time'
    # A mismatched unredacted path must never be rescued by a matching image UUID.
    need(isinstance(path, str) and path.startswith('/') and path.endswith('/' + NAME) and
         ('/*/' in path or '/USER/' in path or '/???/' in path), 'foreign-process-path')
    images = body.get('usedImages', [])
    need(isinstance(images, list) and len(images) <= 4096, 'invalid-image-list')
    owned = [im for im in images if isinstance(im, dict) and im.get('name') == NAME and
             im.get('path') in (path, binding['expectedProcPath']) and
             str(im.get('uuid', '')).upper() == binding['helperMachOUUID']]
    need(len(owned) == 1, 'redacted-path-without-owned-mach-o-uuid')
    return 'exact-pid-name-time-and-signed-helper-uuid-with-redacted-path'


def bounded(value, budget=None, depth=0):
    """Keep diagnostic fields small even when Apple adds nested details."""
    budget = [4000] if budget is None else budget
    if depth > 4 or budget[0] <= 0:
        return '[omitted: diagnostic bound]'
    if isinstance(value, str):
        size = min(len(value), 1024, budget[0])
        budget[0] -= size
        return value[:size] + (' [truncated]' if size < len(value) else '')
    if value is None or type(value) in (bool, int, float):
        return value
    if isinstance(value, list):
        return [bounded(v, budget, depth + 1) for v in value[:16]]
    if isinstance(value, dict):
        return {str(k)[:96]: bounded(v, budget, depth + 1) for k, v in list(value.items())[:16]}
    return '[unsupported field]'


def extract(body):
    result = {key: bounded(body[key]) for key in
              ['exception', 'termination', 'asi', 'asiSignatures', 'applicationSpecificInformation'] if key in body}
    threads, images = body.get('threads', []), body.get('usedImages', [])
    need(isinstance(threads, list) and len(threads) <= 4096 and
         isinstance(images, list) and len(images) <= 4096, 'invalid-crash-arrays')
    index = body.get('faultingThread')
    if type(index) is not int or not 0 <= index < len(threads):
        triggered = [i for i, t in enumerate(threads) if isinstance(t, dict) and t.get('triggered') is True]
        index = triggered[0] if len(triggered) == 1 else None
    frames, used = [], set()
    if index is not None and isinstance(threads[index], dict):
        source_frames = threads[index].get('frames', [])
        need(isinstance(source_frames, list), 'invalid-crashed-thread-frames')
        for frame in source_frames[:32]:
            if not isinstance(frame, dict):
                continue
            frames.append({k: bounded(frame[k]) for k in
                           ['imageIndex', 'imageOffset', 'symbol', 'symbolLocation'] if k in frame})
            image_index = frame.get('imageIndex')
            if type(image_index) is int and 0 <= image_index < len(images):
                used.add(image_index)
        result['crashedThread'] = {'index': index, 'frames': frames,
                                   'framesTruncated': len(source_frames) > 32}
    result['imageIdentities'] = [dict(index=i, **{k: bounded(images[i][k]) for k in
                               ['name', 'uuid', 'arch'] if k in images[i]})
                               for i in sorted(used) if isinstance(images[i], dict)]
    result['reasonFieldsPresent'] = [k for k in ['exception', 'termination', 'asi', 'asiSignatures',
                                                'applicationSpecificInformation'] if body.get(k)]
    result['reasonStatus'] = 'observed' if result['reasonFieldsPresent'] else 'absent'
    return result


def collect(binding):
    roots = [('runner', Path.home() / 'Library/Logs/DiagnosticReports'),
             ('system', Path('/Library/Logs/DiagnosticReports'))]
    summary = {'status': 'absent', 'reason': 'no-matching-owned-ips-within-bound',
               'pollLimitSeconds': POLL_SECONDS, 'candidateLimit': MAX_CANDIDATES,
               'candidateReadLimit': MAX_READS, 'reportByteLimit': REPORT_LIMIT,
               'legacyCrashTextInspected': False, 'unifiedLogsCollected': False}
    start = time.monotonic()
    seen, candidates, reads = set(), set(), 0
    while time.monotonic() - start < POLL_SECONDS:
        for scope, directory in roots:
            try:
                fd = open_directory(directory)
            except OSError:
                continue
            try:
                with os.scandir(fd) as entries:
                    for count, entry in enumerate(entries):
                        if count >= 512 or time.monotonic() - start >= POLL_SECONDS:
                            break
                        name = entry.name
                        if not name.startswith(NAME + '-') or not name.endswith('.ips'):
                            continue
                        key = (scope, name)
                        if key not in candidates and len(candidates) >= MAX_CANDIDATES:
                            continue
                        candidates.add(key)
                        try:
                            info = entry.stat(follow_symlinks=False)
                            fingerprint = (key, info.st_ino, info.st_size, info.st_mtime_ns)
                            if fingerprint in seen or reads >= MAX_READS:
                                continue
                            seen.add(fingerprint)
                            reads += 1
                            data = read_at(fd, name, REPORT_LIMIT)
                            body = parse_ips(data)
                            method = match(body, binding)
                            details = extract(body)
                            summary.update(status='observed', reason='owned-helper-crash-record-observed',
                                           matchMethod=method,
                                           reportIdentity={'directoryScope': scope, 'name': name,
                                                           'bytes': len(data), 'sha256': sha(data)},
                                           procLaunch=body['procLaunch'], captureTime=body['captureTime'],
                                           details=details)
                            return summary
                        except (OSError, ValueError, TypeError, KeyError, RecursionError, OverflowError):
                            # Never copy foreign report contents or parser exceptions into evidence.
                            continue
            finally:
                os.close(fd)
        if reads >= MAX_READS:
            summary['reason'] = 'candidate-read-bound-reached-without-owned-ips'
            break
        time.sleep(min(0.5, max(0, POLL_SECONDS - (time.monotonic() - start))))
    return summary


def write_summary(directory, result):
    data = (json.dumps(result, ensure_ascii=True, indent=2, allow_nan=False) + '\n').encode()
    need(len(data) <= OUTPUT_LIMIT, 'diagnostic-output-limit')
    fd = open_directory(directory / 'evidence')
    try:
        out = os.open('owned-helper-crash.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                      os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)
        with os.fdopen(out, 'wb') as stream:
            stream.write(data)
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--command-report', required=True)
    args = parser.parse_args()
    directory = Path(os.path.abspath(args.directory))
    result = {'schemaVersion': 1, 'diagnosticOnly': True, 'installerAcceptance': False,
              'runtimeAcceptance': False, 'promotion': False, 'status': 'absent'}
    code = 0
    try:
        need(sys.platform == 'darwin', 'macos-only-diagnostic')
        result['binding'] = bind(directory, args.source, Path(os.path.abspath(args.command_report)))
        result.update(collect(result['binding']))
    except (OSError, ValueError, TypeError, KeyError, RecursionError, OverflowError):
        result['reason'] = 'input-binding-invalid-or-collection-unavailable'
        code = 1
    try:
        write_summary(directory, result)
    except (OSError, ValueError, TypeError):
        print('owned-helper-crash: unable to preserve bounded diagnostic', file=sys.stderr)
        return 1
    print(json.dumps({'status': result['status'], 'diagnosticOnly': True,
                      'reason': result.get('reason'), 'output': 'evidence/owned-helper-crash.json'}))
    return code


if __name__ == '__main__':
    sys.exit(main())
