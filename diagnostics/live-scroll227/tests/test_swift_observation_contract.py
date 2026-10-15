"""Static Linux-side contract checks. A passing result is not a macOS compile proof."""
import hashlib
import json
import os
from pathlib import Path
import re
import unittest

PAYLOAD = Path(__file__).resolve().parents[1]
ROOT = PAYLOAD / "overlay"
BASELINE_PATH = Path(os.environ.get("PICSHOT_ALLOCATION_BASE_FIXTURE", "dist/allocation227/original-fixture.swift"))
FIXTURE = (ROOT / "Sources/PicShot/LiveScrollResourceFixture.swift").read_text()
BASELINE = BASELINE_PATH.read_text()
assert hashlib.sha256(BASELINE.encode()).hexdigest() == "4457ce7cf6543746d0064e474db6d0b89552279e50fe1f0f4f28d49860214f06"
HELPER = (ROOT / "Sources/PicShot/LiveScrollAllocationDiagnostic.swift").read_text()
LAUNCHER = (ROOT / "scripts/launch-smoke-app.swift").read_text()


def section(text, begin, end):
    return text[text.index(begin):text.index(end)]


class SwiftObservationContract(unittest.TestCase):
    def test_only_allowed_runtime_files_are_overlaid(self):
        actual = {str(p.relative_to(ROOT)) for p in (ROOT / "Sources").rglob("*.swift")}
        self.assertEqual(actual, {
            "Sources/PicShot/LiveScrollResourceFixture.swift",
            "Sources/PicShot/LiveScrollAllocationDiagnostic.swift",
        })
        self.assertTrue((ROOT / "scripts/launch-smoke-app.swift").is_file())

    def test_entire_original_session_and_assertions_unchanged(self):
        begin, end = "    private static func runSession(", "    private static func sleepUntil("
        self.assertEqual(section(FIXTURE, begin, end), section(BASELINE, begin, end))
        begin = "    private static func assess("
        self.assertEqual(FIXTURE[FIXTURE.index(begin):], BASELINE[BASELINE.index(begin):])

    def test_original_cleanup_and_sampler_preserved(self):
        begin, end = "    private static func runCycle(", "    private static func runSession("
        patched = section(FIXTURE, begin, end)
        patched = patched.replace(", diagnostic: LiveScrollAllocationDiagnostic?) async", ") async", 1)
        patched = patched.replace("Cycle(ordinal: ordinal, diagnostic: diagnostic)", "Cycle()", 1)
        addition = '''            do { try diagnostic?.observeCheckpoint(ordinal: ordinal, phase: "released-plus-1000ms") }
            catch {
                context.report["allocationDiagnosticError"] = error.localizedDescription
                if cycleError == nil { cycleError = error }
            }
'''
        self.assertIn(addition, patched)
        patched = patched.replace(addition, "", 1)
        self.assertEqual(patched, section(BASELINE, begin, end))
        self.assertLess(FIXTURE.index('context.report["providerAfterClose"]'), FIXTURE.index(addition))
        self.assertLess(FIXTURE.index('context.report["observed1000msElapsedSeconds"]'), FIXTURE.index(addition))

    def test_exact_heavy_schedule_and_budget(self):
        rows = re.findall(r'\((\d+), "([a-z0-9-]+)"\)', section(HELPER, "static let checkpoints:", "static let perturbation"))
        self.assertEqual(rows, [
            ("4", "released-plus-1000ms"), ("5", "pre-finish-pending-edge"),
            ("5", "released-plus-1000ms"), ("8", "released-plus-1000ms"),
            ("9", "finish-image-alive-before-png"), ("9", "png-finalized-image-alive"),
            ("9", "released-plus-1000ms"), ("10", "released-plus-1000ms"),
        ])
        self.assertEqual(HELPER.count("holdSeconds: 15, calibration: calibration"), 2)
        self.assertIn('holdSeconds: 10, calibration: nil', HELPER)
        self.assertIn('"maximumTotalRequestedHoldSeconds": 110', HELPER)
        self.assertIn('let warmups = 2, measured = 8', FIXTURE)
        self.assertIn('deadline = started + 590', FIXTURE)
        self.assertIn('ProcessInfo.processInfo.systemUptime + 180', FIXTURE)
        self.assertIn('? 900 : 600', LAUNCHER)
        self.assertLess(FIXTURE.index('try diagnostic?.calibrateBeforeFirstCycle()'), FIXTURE.index('for ordinal in 1...count'))

    def test_full_logging_applies_only_to_owned_app(self):
        self.assertIn('!environment.keys.contains(where: { $0.hasPrefix("Malloc") })', LAUNCHER)
        self.assertIn('settings["MallocStackLogging"] == "full"', LAUNCHER)
        self.assertIn('environment["MallocStackLogging"] == "full"', HELPER)
        self.assertNotIn('environment["MallocStackLogging"] == "1"', HELPER)
        self.assertIn('"configuration.json", O_RDONLY | O_NOFOLLOW', LAUNCHER)
        self.assertIn('Set(config.keys) == Set(["schemaVersion", "protocol", "runToken", "mallocEnvironment"])', LAUNCHER)
        self.assertIn('for (key, value) in allocationDiagnostic.receivedMallocEnvironment { configuration.environment[key] = value }', LAUNCHER)
        self.assertNotIn('ALLOCATION_DIAGNOSTIC_LOG_DIRECTORY', LAUNCHER)

    def test_publication_and_cleanup_identity_contract(self):
        for source in (HELPER, LAUNCHER):
            self.assertIn('renameatx_np(', source)
            self.assertIn('UInt32(RENAME_EXCL)', source)
        self.assertNotIn('guard linkat(', HELPER)
        reply_reader = section(HELPER, '    private func readReplyIfPresent(', '    private func validate(')
        self.assertIn('(info.st_mode & 0o077) == 0', reply_reader)
        self.assertIn('verifyOwnedProcessBeforeCleanup(launched, phase: "before-terminate")', LAUNCHER)
        self.assertIn('verifyOwnedProcessBeforeCleanup(launched, phase: "before-force-terminate")', LAUNCHER)
        self.assertIn('current?.launchDate == ownedAppLaunchDate', LAUNCHER)
        self.assertIn('current?.executableURL?.resolvingSymlinksInPath().path == expectedExecutable', LAUNCHER)

    def test_calibration_is_owned_and_released_before_second_request(self):
        body = section(HELPER, '    func calibrateBeforeFirstCycle()', '    func observeCheckpoint(')
        self.assertIn('let byteCount = 65_537', body)
        self.assertIn('defer { if ownsBlock { free(block) } }', body)
        self.assertLess(body.index('kind: "calibration-live"'), body.index('free(block); ownsBlock = false'))
        self.assertLess(body.index('free(block); ownsBlock = false'), body.index('kind: "calibration-released"'))
        self.assertNotIn('malloc_zone_pressure_relief', HELPER)

    def test_protocol_doc_and_reply_schema_agree(self):
        doc = (PAYLOAD / 'PROTOCOL.md').read_text()
        self.assertIn('Maximum requested app hold time is110s', doc)
        reply_keys = re.search(r'let keys: Set<String> = \[(.*?)\]', HELPER).group(1)
        actual = set(re.findall(r'"(\w+)"', reply_keys))
        self.assertEqual(actual, {'schemaVersion', 'protocol', 'runToken', 'sequence', 'requestID',
                                  'identity', 'status', 'completedUptimeSeconds', 'errorCode'})


if __name__ == '__main__':
    unittest.main(verbosity=2)
