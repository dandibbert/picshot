#!/usr/bin/env python3
"""Early, separate real SwiftPM/XCTest ownership test; never product acceptance."""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('native_observer', Path(__file__).with_name('native-test-diagnostics.py'))
D = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(D)
BUILD_SECONDS = 120
RUN_SECONDS = 20
NORMAL_RUN_SECONDS = 40
TIMEOUT_SECONDS = 12
DISCOVERY_SECONDS = 10
WRAPPER_ALLOWANCE = 10
SELF_TEST_SECONDS = 300
PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PicShotObserverSelfTest", platforms: [.macOS(.v14)],
    targets: [.testTarget(name: "ObserverSelfTestTests")])
'''
TEST = '''import Foundation
import XCTest
import Darwin
final class ObserverOwnershipTests: XCTestCase {
    func testWaitForGate() throws {
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment["PICSHOT_OBSERVER_SELF_TEST_GATE"])
        let gate = URL(fileURLWithPath: value)
        // Only cancellation/timeout fixtures ignore their own SIGTERM.
        if ProcessInfo.processInfo.environment["PICSHOT_OBSERVER_SELF_TEST_SURVIVE_TERM"] == "1" {
            _ = Darwin.signal(SIGTERM, SIG_IGN)
        }
        try Data("ready\\n".utf8).write(to: gate.appendingPathExtension("ready"), options: .atomic)
        let end = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: gate.path) && Date() < end {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: gate.path), "Self-test gate watchdog expired")
    }
}
'''
FIXTURES = {'Package.swift': PACKAGE, 'Tests/ObserverSelfTestTests/ObserverOwnershipTests.swift': TEST}


def need(value, message):
    if not value:
        raise ValueError(message)


def save(path, value):
    data = (json.dumps(value, indent=2) + '\n').encode()
    need(len(data) <= 2 * 1024 * 1024, 'Self-test metadata cap exceeded')
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_bytes(data)
    temporary.replace(path)


def fixture(package, archive):
    records = {}
    for name, content in FIXTURES.items():
        for root in (package, archive):
            path = root/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        records[name] = {'bytes': len(content.encode()), 'sha256': hashlib.sha256(content.encode()).hexdigest()}
    return records


def fixture_executable(package):
    # SwiftPM may expose .build/debug as a symlink to the architecture directory.
    # Canonical paths deduplicate that alias without accepting an external file.
    paths = {path.resolve() for path in package.glob('.build/**/*.xctest/Contents/MacOS/*') if path.is_file()}
    need(len(paths) == 1, 'Temporary XCTest executable identity is ambiguous')
    path = next(iter(paths))
    need(path.is_relative_to(package.resolve()), 'Temporary XCTest executable escaped its package')
    return path


def wrapper_command(command, seconds, prefix, grace_seconds=None):
    grace = [] if grace_seconds is None else ['--grace-seconds', str(grace_seconds)]
    return [sys.executable, str(Path(__file__).with_name('run-bounded-command.py').resolve()),
            '--timeout-seconds', str(seconds), '--log', str(prefix.with_suffix('.log')),
            '--report', str(prefix.with_suffix('.runner.json')), *grace, '--', *command]


def final_envelope(prefix, returncode, seconds):
    valid, report = D.cleanup_evidence(prefix.with_suffix('.runner.json'), returncode, seconds)
    need(valid, 'Self-test wrapper completion is unproven')
    return report


def require_snapshot(snapshot, wrapper, leader):
    need(snapshot.get('complete') is True and snapshot.get('anchorValidated') is True,
         'Incomplete owned descendant census')
    need(snapshot['wrapper'] == wrapper and snapshot['leader'] == leader, 'Changed self-test anchor')
    target = snapshot['target']
    need(snapshot.get('xcodeDeveloperDirectory') == D.xcode_developer_directory(leader)
         and D.is_xctest(target, snapshot.get('xcodeDeveloperDirectory')),
         'Self-test XCTest executable is outside the selected Xcode allowlist')
    need(target['pid'] in snapshot['candidatePIDs'] and len(snapshot['candidatePIDs']) == 1,
         'Ambiguous self-test XCTest candidate')
    need(target['groupID'] != leader['groupID'], 'Self-test did not exercise the real separate XCTest process group')
    members = {member['pid']: member for member in snapshot['members']}
    seen = set()
    node = target
    while node['pid'] != leader['pid']:
        need(node['pid'] not in seen and node['parentPID'] in members, 'Unproven self-test parent edge')
        seen.add(node['pid'])
        node = members[node['parentPID']]
    need(leader['parentPID'] == wrapper['pid'], 'Self-test native command is not wrapper-owned')
    return target


class Harness:
    def __init__(self, directory, source, identify):
        self.directory, self.source, self.identify = directory, source, identify
        self.started = time.monotonic()
        self.cancelled = []
        self.processes = []
        self.targets = []
        self.census_uncertain = False
        self.census_evidence = dict(totalCensusCount=0, uncertainCensusCount=0,
            retainedUncertainCount=0, omittedUncertainCount=0,
            firstUncertain=None, latestUncertain=None)
        self.report = dict(schemaVersion=1, sourceCommit=source, diagnosticOnly=True, installerAcceptance=False,
            status='running', realSwiftPM=True, scenarios=[], temporaryPackageRemoved=False, censusUncertain=False,
            cleanupConfirmed=False, allOwnedTargetsRetired=False, originalNativeProcessSeconds=420,
            selfTestBuildSeconds=BUILD_SECONDS, selfTestRunSeconds=RUN_SECONDS,
            selfTestNormalRunSeconds=NORMAL_RUN_SECONDS, samplerTimeoutSeconds=D.SAMPLE_TIMEOUT,
            selfTestTimeoutScenarioSeconds=TIMEOUT_SECONDS, selfTestBudgetSeconds=SELF_TEST_SECONDS)
        self.report['censusEvidence'] = self.census_evidence
        self.report['discoveryErrors'] = dict(totalCount=0, retainedCount=0, omittedCount=0,
                                             retainedPerScenarioLimit=16)
        self.package = None

    def checkpoint(self):
        need(not self.cancelled, 'Self-test cancelled')
        need(time.monotonic() - self.started < SELF_TEST_SECONDS, 'Self-test orchestration deadline exceeded')

    def launch(self, command, seconds, prefix, env=None, grace_seconds=None):
        self.checkpoint()
        process = subprocess.Popen(wrapper_command(command, seconds, prefix, grace_seconds), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
        self.processes.append(process)
        return process

    def wait(self, process, seconds):
        until = time.monotonic() + seconds
        while process.poll() is None:
            self.checkpoint()
            need(time.monotonic() < until, 'Self-test wrapper exceeded its bounded completion allowance')
            time.sleep(0.05)
        return process.returncode

    def remember_census(self, census, error=None, context=None):
        if not isinstance(census, dict):
            return
        D.remember_vanished_children(self.report, census)
        self.census_evidence['totalCensusCount'] += 1
        reasons = []
        if census.get('complete') is not True or census.get('anchorValidated') is not True:
            if census.get('complete') is not True:
                reasons.append('incomplete-census')
            if census.get('anchorValidated') is not True:
                reasons.append('unvalidated-anchor')
            candidates = []
        else:
            candidates = [member for member in census['members']
                          if member['pid'] in census['candidatePIDs']
                          and D.is_xctest(member, census.get('xcodeDeveloperDirectory'))]
            if len(candidates) != len(census['candidatePIDs']):
                reasons.append('unrecognized-candidate-identity')
            if len(candidates) > 1:
                reasons.append('ambiguous-candidates')
        if reasons:
            self.census_uncertain = True
            self.report['censusUncertain'] = True
            evidence = self.census_evidence
            evidence['uncertainCensusCount'] += 1
            evidence['retainedUncertainCount'] = min(2, evidence['uncertainCensusCount'])
            evidence['omittedUncertainCount'] = max(0, evidence['uncertainCensusCount'] - 2)
            record = dict(censusIndex=evidence['totalCensusCount'], context=context,
                elapsedSeconds=round(time.monotonic() - self.started, 6), reasons=reasons,
                error=str(error)[:2048] if error is not None else None, census=copy.deepcopy(census))
            if evidence['firstUncertain'] is None:
                evidence['firstUncertain'] = record
            evidence['latestUncertain'] = record
        for target in candidates:
            if not any(D.identity_key(target) == D.identity_key(old) for old in self.targets):
                self.targets.append(target)

    def target(self, process, prefix, ready, binding, expected_command, timeout_seconds):
        until = time.monotonic() + DISCOVERY_SECONDS
        leader = None
        attempts = []
        save(prefix.with_suffix('.wrapper-binding.json'), binding.record)
        while process.poll() is None and time.monotonic() < until:
            self.checkpoint()
            try:
                report_path = prefix.with_suffix('.runner.json')
                raw = (json.loads(D.NATIVE.bounded_text(report_path, D.METADATA_CAP))
                       if report_path.exists() else None)
                try:
                    wrapper = binding.observe(raw, expected_command, timeout_seconds)
                finally:
                    save(prefix.with_suffix('.wrapper-binding.json'), binding.record)
                if wrapper is None:
                    time.sleep(0.05)
                    continue
                # SwiftPM may exec swift -> swift-test during startup. Pin only
                # the fully revalidated leader returned with a real XCTest.
                snapshot = D.owned_target(process.pid, raw['pid'], self.identify,
                    expected_wrapper=wrapper, expected_leader=leader)
                leader = snapshot['leader']
                self.remember_census(snapshot, context=str(prefix))
                save(prefix.with_suffix('.identity.json'), snapshot)
                save(self.directory/'self-test-report.json', self.report)
                require_snapshot(snapshot, wrapper, leader)
                if ready.is_file():
                    return snapshot
            except Exception as error:
                census = getattr(error, 'census', None)
                self.remember_census(census, error=error, context=str(prefix))
                counts = self.report['discoveryErrors']
                counts['totalCount'] += 1
                if len(attempts) < 16:
                    attempts.append({'error': str(error), 'census': census,
                                     'elapsedSeconds': round(time.monotonic() - self.started, 6)})
                    counts['retainedCount'] += 1
                    save(prefix.with_suffix('.discovery-attempts.json'), attempts)
                counts['omittedCount'] = counts['totalCount'] - counts['retainedCount']
                save(self.directory/'self-test-report.json', self.report)
                if binding.record.get('status') == 'blocked':
                    raise ValueError('Owned wrapper readiness binding rejected') from error
            time.sleep(0.05)
        raise ValueError('Real owned SwiftPM XCTest discovery/readiness was not proven')

    def sample(self, request, prefix, wrong_birth=False):
        snapshot = copy.deepcopy(request)
        if wrong_birth:
            snapshot['target']['birthSeconds'] += 1
        request_path = prefix.with_suffix('.request.json')
        output = prefix.with_suffix('.txt')
        save(request_path, snapshot)
        command = [sys.executable, str(Path(__file__).with_name('native-test-diagnostics.py').resolve()),
                   'sample', '--request', str(request_path), '--output', str(output)]
        process = self.launch(command, D.SAMPLE_TIMEOUT, prefix, grace_seconds=D.SAMPLE_GRACE)
        code = self.wait(process, D.SAMPLE_TIMEOUT + WRAPPER_ALLOWANCE)
        report = final_envelope(prefix, code, D.SAMPLE_TIMEOUT)
        current = self.identify(request['target']['pid'])
        need(D.identity_key(current) == D.identity_key(request['target']), 'Sample target identity changed')
        if wrong_birth:
            need(code != 0 and report['status'] == 'exited' and not output.exists(),
                 'Wrong birth identity was not rejected before sampling')
            return dict(rejected=True, targetIdentityUnchanged=True, wrapper=report)
        need(code == 0 and report['status'] == 'exited' and output.is_file()
             and not output.is_symlink() and 0 < output.stat().st_size <= D.SAMPLE_FILE_CAP,
             'Real owned stack sample is missing or incomplete')
        stack = output.read_text(errors='replace')
        need('ObserverOwnershipTests' in stack, 'Stack sample does not identify the generated XCTest fixture')
        return dict(captured=True, targetIdentityUnchanged=True, targetIdentityAfter=current,
                    sampleBytes=output.stat().st_size, sampleSHA256=hashlib.sha256(output.read_bytes()).hexdigest(),
                    fixtureFrameObserved=True, wrapper=report)

    def scenario(self, name):
        root = self.directory/name
        root.mkdir()
        gate = self.package/(name+'-gate')
        survives_term = name in ('cancellation', 'timeout')
        environment = dict(os.environ, PICSHOT_OBSERVER_SELF_TEST_GATE=str(gate),
            PICSHOT_OBSERVER_SELF_TEST_SURVIVE_TERM='1' if survives_term else '0')
        seconds = {'normal': NORMAL_RUN_SECONDS, 'cancellation': RUN_SECONDS, 'timeout': TIMEOUT_SECONDS}[name]
        command = ['swift', 'test', '--skip-build', '--package-path', str(self.package),
                   '--filter', 'ObserverSelfTestTests.ObserverOwnershipTests/testWaitForGate']
        prefix = root/'native'
        record = dict(name=name, command=command, expectedOutcome=name, cleanupConfirmed=False,
            gatePath=str(gate), readyPath=str(gate.with_suffix('.ready')),
            fixtureSignalPolicy='ignore-own-SIGTERM' if survives_term else 'unchanged',
            fixtureEnvironment={'PICSHOT_OBSERVER_SELF_TEST_SURVIVE_TERM': '1' if survives_term else '0'})
        self.report['scenarios'].append(record)
        expected_executable = self.identify(os.getpid())['executable']
        record['expectedWrapperExecutable'] = expected_executable
        process = self.launch(command, seconds, prefix, environment)
        record['wrapperPID'] = process.pid
        binding = D.WrapperBinding(process, self.identify, expected_executable)
        record['wrapperBinding'] = binding.record
        save(prefix.with_suffix('.wrapper-binding.json'), binding.record)
        save(self.directory/'self-test-report.json', self.report)
        request = self.target(process, prefix, gate.with_suffix('.ready'), binding, command, seconds)
        record['identity'] = request
        target = request['target']
        if name == 'normal':
            record['wrongBirthSample'] = self.sample(request, root/'wrong-birth', wrong_birth=True)
            # A mismatched executable must never be signalled even while its PID lives.
            forged = dict(target, executable=target['executable']+'.wrong-identity')
            rejection = D.retire_targets([forged], self.identify, budget_seconds=0.1)
            need(not rejection['confirmed'] and all(not row['signals'] for row in rejection['targets'])
                 and D.identity_key(self.identify(target['pid'])) == D.identity_key(target),
                 'Wrong executable identity was not rejected before signalling')
            record['wrongIdentityRetirement'] = rejection
            record['sample'] = self.sample(request, root/'owned-sample')
            gate.write_text('release\n')
        elif name == 'cancellation':
            process.send_signal(signal.SIGTERM)
            record['wrapperCancellationSignal'] = int(signal.SIGTERM)
        code = self.wait(process, seconds + WRAPPER_ALLOWANCE)
        record['wrapper'] = final_envelope(prefix, code, seconds)
        expected = {'normal': ('exited', 0), 'timeout': ('timeout', 124), 'cancellation': ('cancelled', 143)}[name]
        need((record['wrapper']['status'], code) == expected, 'Unexpected self-test native wrapper outcome')
        # Wrapper success alone is insufficient: inspect and retire the actual retained descendant.
        record['targetStateAfterWrapper'] = D.target_state(target, self.identify)
        record['retirement'] = D.retire_targets([target], self.identify)
        record['cleanupConfirmed'] = record['retirement']['confirmed']
        need(record['cleanupConfirmed'], 'Actual owned XCTest retirement is unproven')
        if name in ('timeout', 'cancellation'):
            need(record['targetStateAfterWrapper']['state'] == 'live'
                 and int(signal.SIGKILL) in record['retirement']['targets'][0]['signals'],
                 'Self-test did not prove SIGKILL retirement of its TERM-resistant owned descendant')
        save(root/'result.json', record)
        save(self.directory/'self-test-report.json', self.report)

    def run(self):
        self.package = Path(tempfile.mkdtemp(prefix='picshot-observer-self-test-', dir=os.environ.get('RUNNER_TEMP'))).resolve()
        self.report['temporaryPackagePath'] = str(self.package)
        self.report['fixtureSources'] = fixture(self.package, self.directory/'fixture-source')
        save(self.directory/'self-test-report.json', self.report)
        prefix = self.directory/'fixture-build'
        command = ['swift', 'build', '--build-tests', '--package-path', str(self.package)]
        process = self.launch(command, BUILD_SECONDS, prefix)
        code = self.wait(process, BUILD_SECONDS + WRAPPER_ALLOWANCE)
        self.report['build'] = final_envelope(prefix, code, BUILD_SECONDS)
        need(code == 0 and self.report['build']['status'] == 'exited', 'Temporary SwiftPM XCTest compile failed')
        executable = fixture_executable(self.package)
        self.report['fixtureExecutable'] = dict(path=str(executable), bytes=executable.stat().st_size,
            sha256=hashlib.sha256(executable.read_bytes()).hexdigest())
        for name in ('normal', 'cancellation', 'timeout'):
            self.scenario(name)
        self.report.update(ancestryVerified=True, separateXCTestProcessGroupObserved=True,
            stackIdentityVerified=True, wrongBirthRejected=True, wrongIdentitySignalRejected=True,
            normalExitVerified=True, cancellationVerified=True, timeoutRetirementVerified=True)

    def finish(self):
        cleanup_errors = []
        for process in self.processes:
            if process.poll() is None:
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass
                except OSError as error:
                    cleanup_errors.append({'wrapperPID': process.pid, 'reason': str(error)})
                try:
                    process.wait(timeout=WRAPPER_ALLOWANCE)
                except (subprocess.TimeoutExpired, OSError) as error:
                    cleanup_errors.append({'wrapperPID': process.pid, 'reason': str(error)})
        try:
            need(not cleanup_errors and all(process.poll() is not None for process in self.processes),
                 'Cannot retire descendants while wrapper completion is uncertain')
            retirement = D.retire_targets(self.targets, self.identify)
        except Exception as error:
            retirement = dict(confirmed=False, error=str(error), targets=[])
        self.report['finalRetirement'] = retirement
        self.report['unconfirmedWrappers'] = cleanup_errors
        self.report['allOwnedTargetsRetired'] = retirement['confirmed']
        self.report['censusUncertain'] = self.census_uncertain
        self.report['cleanupConfirmed'] = (bool(self.targets) and retirement['confirmed']
            and not cleanup_errors and not self.census_uncertain)
        if self.report['cleanupConfirmed'] and self.package is not None:
            try:
                shutil.rmtree(self.package)
                self.report['temporaryPackageRemoved'] = not self.package.exists()
            except OSError as error:
                self.report['temporaryPackageCleanupError'] = str(error)
        self.report['durationSeconds'] = round(time.monotonic() - self.started, 6)
        self.report['cancelSignals'] = self.cancelled
        required = ('ancestryVerified', 'separateXCTestProcessGroupObserved', 'stackIdentityVerified',
                    'wrongBirthRejected', 'wrongIdentitySignalRejected', 'normalExitVerified',
                    'cancellationVerified', 'timeoutRetirementVerified', 'cleanupConfirmed',
                    'allOwnedTargetsRetired', 'temporaryPackageRemoved')
        self.report['status'] = 'passed' if not self.cancelled and not self.report.get('error') and all(self.report.get(key) is True for key in required) else 'failed'
        save(self.directory/'self-test-report.json', self.report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--expected-source', required=True)
    args = parser.parse_args()
    need(sys.platform == 'darwin', 'The real SwiftPM observer self-test requires macOS')
    need(len(args.expected_source) == 40 and all(c in '0123456789abcdef' for c in args.expected_source), 'Invalid source SHA')
    args.directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    harness = Harness(args.directory.resolve(), args.expected_source, D.ProcessIdentity())
    previous = {sig: signal.signal(sig, lambda number, frame: harness.cancelled.append(number))
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        try:
            harness.run()
        except Exception as error:
            harness.report['error'] = f'{type(error).__name__}: {error}'
        finally:
            harness.finish()
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    print(json.dumps(harness.report, sort_keys=True))
    return 0 if harness.report['status'] == 'passed' else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('Native observer self-test failed: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
