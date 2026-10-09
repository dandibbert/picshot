"""Portable evidence-gate tests. Byte stubs are not native/media evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("derived_gate", ROOT / "scripts/check-recording-input-exports.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
COMMIT = "a" * 40


def helper():
    return dict(childLaunched=True, childExitConfirmed=True, temporaryDirectoryRemoved=True,
                configuredWallSeconds=300, configuredChildResidentLimitBytes=1_073_741_824)


def frames():
    return [dict(index=i, requestedSeconds=i / 20, actualSeconds=(i // 2) / 10,
                 sourceIndex=i // 2 + 1, delayMS=50,
                 regionMeanAbsoluteError={key: 0 for key in GATE.REGIONS}) for i in range(41)]


def packets(selected):
    items = [dict(rawPTS=i / 10, rawDuration=0.1,
                  outputPTS=(i - 1) / 10 if selected else i / 10,
                  outputDuration=0.05 if selected and i == 21 else 0.1,
                  trimStart=0, trimEnd=0.05 if selected and i == 21 else 0,
                  doNotDisplay=selected and i == 0) for i in range(22)]
    return dict(storedCount=22, presentedCount=21 if selected else 22,
                nonPresentedCount=1 if selected else 0, rawStart=0, rawEnd=2.2,
                presentationEnd=2.05 if selected else 2.2,
                finalPresentedDuration=0.05 if selected else 0.1, packets=items,
                rawTimeline="untrimmed sample PTS/duration",
                presentationTimeline="CoreMedia output PTS/duration after track edits and trims")


class RecordingInputExportEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "recording-input.mp4").write_bytes(b"unit stub, not playable media")
        self.original = dict(status="passed", decodedFrames=22, sourceCommit=COMMIT)
        self.fixture = dict(schemaVersion=1, status="exported-awaiting-independent-validation", sourceCommit=COMMIT,
            sourceSHA256=GATE.digest(self.root / "recording-input.mp4"), sourcePreserved=True,
            original159ReportPreserved=True, temporaryDirectoryRemoved=True, independentValidationRequired=True,
            captureStarted=False, permissionRequested=False, globalInputPosted=False, regionRelocationTested=False,
            typedTextCaptured=False, selectedStartSeconds=0.1, selectedEndSeconds=2.15, selectedDurationSeconds=2.05,
            expectedAnimationFrames=41, animationFrameRate=20, maximumMediaBytes=GATE.MEDIA_CAP,
            maximumReportBytes=GATE.REPORT_CAP, maximumStoredFrameObservations=84,
            maximumStoredPacketTimingsPerMovie=22, exports=[], destinationSentinels=[], cancellations=[])
        self.native = dict(schemaVersion=1, status="passed", sourceCommit=COMMIT,
            sourceSHA256=self.fixture["sourceSHA256"], sourcePreserved=True, webPDecoder="PSCodecAnimationNext",
            imageIOUsedForWebP=False, sourceFrames=22, selectedFrames=21, selectedDurationSeconds=2.05,
            maximumMediaBytes=GATE.MEDIA_CAP, maximumReportBytes=GATE.REPORT_CAP,
            maximumStoredPacketTimingsPerMovie=22, maximumFramesPerAnimation=41, maximumRGBABytesPerFrame=320 * 180 * 4, mediaHashes={})
        self.native["sourcePacketTiming"] = packets(False)
        self.native["selectedPacketTiming"] = packets(True)
        self.native["selectedRawPacketEndSeconds"] = 2.2
        self.fixture["sourceDecode"] = dict(frames=22, duration=2.2, rawPacketEnd=2.2, packetTiming=packets(False))
        self.fixture["selectedMP4"] = dict(frames=21, duration=2.05, rawPacketEnd=2.2, packetTiming=packets(True),
                                           sourceFrameIndices=list(range(1, 22)))
        self.native["selectedSourceFrameIndices"] = list(range(1, 22))
        self.native["verifiedLoopCounts"] = {"gif": 0, "webpLossless": 0, "webpLossy": 0}
        for route, name in GATE.MEDIA:
            (self.root / name).write_bytes(b"unit output, not decoded pixels: " + route.encode())
            item = dict(route=route, file=name, sha256=GATE.digest(self.root / name), bytes=(self.root / name).stat().st_size)
            if route != "mp4":
                item["process"] = helper()
                self.native[route] = frames()
            self.fixture["exports"].append(item)
            self.native["mediaHashes"][name] = item["sha256"]
            self.fixture["destinationSentinels"].append(dict(route=route, existingDestinationPreserved=True))
            for phase in (["trim-start"] if route == "mp4" else ["trim-start", "helper-progress", "before-publication"]):
                item = dict(route=route, phase=phase, destinationAbsent=True)
                if phase != "trim-start":
                    item["process"] = helper()
                self.fixture["cancellations"].append(item)

    def save(self):
        for name, value in [("recording-input.json", self.original), ("recording-input-export.json", self.fixture)]:
            (self.root / name).write_text(json.dumps(value))
        self.native["fixtureReportSHA256"] = GATE.digest(self.root / "recording-input-export.json")
        (self.root / "recording-input-export-independent.json").write_text(json.dumps(self.native))

    def validate(self):
        self.save()
        return GATE.validate(self.root, COMMIT)

    def test_complete_contract_passes_without_claiming_media_decode(self):
        self.assertEqual(self.validate()["status"], "passed")
        for variant in ("fully-trimmed", "no-preroll", "rebased", "decode-order"):
            timing = packets(True)
            if variant == "fully-trimmed":
                timing["packets"][0].update(doNotDisplay=False, outputPTS=0, outputDuration=0, trimStart=0.1)
            elif variant in ("no-preroll", "rebased"):
                timing.update(storedCount=21, nonPresentedCount=0, rawStart=0.1)
                timing["packets"] = timing["packets"][1:]
                if variant == "rebased":
                    timing.update(rawStart=0, rawEnd=2.05)
                    for packet in timing["packets"]:
                        packet.update(rawPTS=packet["outputPTS"], rawDuration=packet["outputDuration"], trimEnd=0)
            else:
                timing["packets"].reverse()
            with self.subTest(variant=variant):
                GATE.packet_timing(timing, True)
        self.save()
        # Match Swift's pretty-printed evidence and leave headroom under 128 KiB.
        self.assertLess(len(json.dumps(self.native, sort_keys=True, indent=2).encode()), GATE.REPORT_CAP)


    def test_first_frame_only_or_imageio_webp_cannot_pass(self):
        self.native["webpLossless"] = self.native["webpLossless"][:1]
        with self.assertRaisesRegex(ValueError, "not all frames"):
            self.validate()
        self.native["webpLossless"] = frames()
        self.native["imageIOUsedForWebP"] = True
        with self.assertRaisesRegex(ValueError, "native all-frame"):
            self.validate()

    def test_missing_expiry_resume_or_stop_sample_is_rejected(self):
        for source_index in (9, 13, 18, 20, 21):
            with self.subTest(source_index=source_index):
                changed = frames()
                for item in changed:
                    if item["sourceIndex"] == source_index:
                        item["sourceIndex"] -= 1
                        item["actualSeconds"] -= 0.1
                self.native["webpLossy"] = changed
                with self.assertRaises(ValueError):
                    self.validate()

    def test_wrong_timing_loop_evidence_and_pixel_scope_rejected(self):
        for key, value in (("storedCount", 23), ("presentedCount", 22), ("nonPresentedCount", 0),
                           ("presentationEnd", 2.2), ("finalPresentedDuration", 0.1),
                           ("rawTimeline", "playback")):
            timing = packets(True)
            timing[key] = value
            self.native["selectedPacketTiming"] = timing
            self.fixture["selectedMP4"]["packetTiming"] = copy.deepcopy(timing)
            with self.assertRaises(ValueError):
                self.validate()
        mutations = [lambda t: t.pop("packets"),
                     lambda t: t["packets"].pop(),
                     lambda t: t["packets"].append(copy.deepcopy(t["packets"][-1])),
                     lambda t: t["packets"][0].update(doNotDisplay=False),
                     lambda t: t["packets"][0].update(doNotDisplay="true"),
                     lambda t: t["packets"][0].update(outputPTS=float("nan")),
                     lambda t: t["packets"][0].update(trimStart=-0.1, trimEnd=0.1),
                     lambda t: t["packets"][0].update(outputDuration=0, doNotDisplay=False, outputPTS=0),
                     lambda t: t["packets"][4].update(rawPTS=0.42),
                     lambda t: t["packets"][4].update(rawPTS=0.38),
                     lambda t: t["packets"][4].update(outputPTS=0.32),
                     lambda t: t["packets"][4].update(outputPTS=0.28),
                     lambda t: t["packets"][-1].update(outputDuration=0.1, trimEnd=0),
                     lambda t: t.update(rawEnd=2.1),
                     lambda t: t.update(storedCount=True)]
        for index, mutate in enumerate(mutations):
            timing = packets(True)
            mutate(timing)
            with self.subTest(packetMutation=index), self.assertRaises(ValueError):
                GATE.packet_timing(timing, True)
        source = packets(False)
        source["packets"][0]["doNotDisplay"] = True
        with self.assertRaises(ValueError):
            GATE.packet_timing(source, False)
        self.native["selectedPacketTiming"] = packets(True)
        self.fixture["selectedMP4"]["packetTiming"] = packets(True)
        self.native["selectedSourceFrameIndices"][-1] = 20
        with self.assertRaisesRegex(ValueError, "source-frame mapping"):
            self.validate()
        self.native["selectedSourceFrameIndices"] = list(range(1, 22))
        self.fixture["selectedMP4"]["rawPacketEnd"] = 2.05
        with self.assertRaisesRegex(ValueError, "packet evidence"):
            self.validate()
        self.fixture["selectedMP4"]["rawPacketEnd"] = 2.2
        changes = [lambda f: f[2].update(delayMS=100),
                   lambda f: f[4].update(actualSeconds=-1),
                   lambda f: f[6].update(requestedSeconds=0.301),
                   lambda f: f[8]["regionMeanAbsoluteError"].pop("shortcut"),
                   lambda f: f[10]["regionMeanAbsoluteError"].update(scroll=100)]
        for change in changes:
            self.native["gif"] = frames()
            change(self.native["gif"])
            with self.assertRaises(ValueError):
                self.validate()
        self.native["gif"] = frames()
        self.native["verifiedLoopCounts"]["webpLossy"] = 1
        with self.assertRaisesRegex(ValueError, "looping"):
            self.validate()

    def test_unconfirmed_child_or_missing_cancellation_rejected(self):
        self.fixture["exports"][1]["process"]["childExitConfirmed"] = False
        with self.assertRaisesRegex(ValueError, "unconfirmed"):
            self.validate()
        self.fixture["exports"][1]["process"]["childExitConfirmed"] = True
        self.fixture["cancellations"].pop()
        with self.assertRaisesRegex(ValueError, "Cancellation coverage"):
            self.validate()

    def test_cap_increases_and_unbound_source_rejected(self):
        self.fixture["exports"][1]["process"]["configuredWallSeconds"] = 301
        with self.assertRaisesRegex(ValueError, "wall cap"):
            self.validate()
        self.fixture["exports"][1]["process"]["configuredWallSeconds"] = 300
        self.fixture["sourceSHA256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "Source bytes"):
            self.validate()

    def test_modified_media_and_replaced_manifest_are_rejected(self):
        self.save()
        (self.root / GATE.MEDIA[2][1]).write_bytes(b"replacement")
        with self.assertRaisesRegex(ValueError, "unbound output"):
            GATE.validate(self.root, COMMIT)
        self.save()
        (self.root / "recording-input-export.json").write_text(json.dumps(dict(self.fixture, extra="changed after decode")))
        with self.assertRaisesRegex(ValueError, "different fixture"):
            GATE.validate(self.root, COMMIT)

    def test_pending_native_failed_original_or_wrong_revision_rejected(self):
        original_fixture = copy.deepcopy(self.fixture)
        for key, value in [("status", "passed"), ("sourceCommit", "b" * 40), ("sourcePreserved", False)]:
            self.fixture = copy.deepcopy(original_fixture)
            self.fixture[key] = value
            with self.assertRaises(ValueError):
                self.validate()
        self.fixture = original_fixture
        self.original["status"] = "failed"
        with self.assertRaisesRegex(ValueError, "Original159"):
            self.validate()

    def test_duplicate_nonfinite_oversize_and_symlink_reports_rejected(self):
        path = self.root / "invalid.json"
        for text in ['{"status": "passed", "status": "failed"}', '{"time":NaN}', '{"time":Infinity}']:
            path.write_text(text)
            with self.assertRaises(ValueError):
                GATE.read(path)
        path.write_bytes(b"x" * (GATE.REPORT_CAP + 1))
        with self.assertRaises(ValueError):
            GATE.read(path)
        alias = self.root / "alias"
        alias.symlink_to(path)
        with self.assertRaises(ValueError):
            GATE.bounded(alias, GATE.MEDIA_CAP)


if __name__ == "__main__":
    unittest.main()
