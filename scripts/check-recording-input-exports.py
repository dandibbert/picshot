#!/usr/bin/env python3
"""Fail-closed join of installed exports and independent native decode evidence.

This Python gate does not decode pixels and is never a replacement for the
separate AVFoundation/ImageIO/libwebp validator. No third-party Python modules.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

MEDIA = (
    ("mp4", "recording-input-selected.mp4"),
    ("gif", "recording-input-selected.gif"),
    ("webpLossless", "recording-input-lossless.webp"),
    ("webpLossy", "recording-input-lossy.webp"),
)
REGIONS = {"click", "scroll", "shortcut", "camera", "annotation", "clear",
           "horizontalScroll", "verticalScroll", "oppositeScroll", "postStop", "wholeCanvas"}
REPORT_CAP = 128 * 1024
MEDIA_CAP = 4 * 1024 * 1024


def need(value, message):
    if not value:
        raise ValueError(message)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def bounded(path, maximum):
    need(not path.is_symlink() and path.is_file() and 0 < path.stat().st_size <= maximum,
         f"Missing or oversized regular evidence: {path.name}")
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    need(0 < len(data) <= maximum, f"Evidence changed while reading: {path.name}")
    return data


def digest(path, maximum=MEDIA_CAP):
    return hashlib.sha256(bounded(path, maximum)).hexdigest()


def read(path):
    def duplicate(pairs):
        result = {}
        for key, value in pairs:
            need(key not in result, f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    return json.loads(bounded(path, REPORT_CAP), object_pairs_hook=duplicate,
                      parse_constant=lambda x: (_ for _ in ()).throw(ValueError(f"Nonfinite JSON: {x}")))


def process(job):
    need(isinstance(job, dict), "Missing real helper metrics")
    for key in ("childLaunched", "childExitConfirmed", "temporaryDirectoryRemoved"):
        need(job.get(key) is True, f"Helper {key} unconfirmed")
    need(job.get("configuredWallSeconds") == 300, "Production child wall cap changed")
    need(job.get("configuredChildResidentLimitBytes") == 1_073_741_824, "Production child RSS cap changed")


def timeline(frames, route):
    need(isinstance(frames, list) and len(frames) == 41, f"{route}: not all frames decoded")
    previous, indices, total = -1.0, set(), 0
    for index, item in enumerate(frames):
        need(item.get("index") == index and item.get("delayMS") == 50, f"{route}: wrong frame order/delay")
        requested, actual = item.get("requestedSeconds"), item.get("actualSeconds")
        source_index = item.get("sourceIndex")
        need(finite(requested) and abs(requested - index / 20) < 1e-8, f"{route}: request ticks differ")
        need(finite(actual) and previous <= actual < 2.05, f"{route}: nonmonotonic/outside selected time")
        need(type(source_index) is int and 1 <= source_index <= 21
             and abs(actual - (source_index - 1) / 10) <= 1 / 600,
             f"{route}: actual time does not identify a decoded MP4 frame")
        need(actual <= requested + 1 / 600 and requested < actual + 0.1 + 1 / 600,
             f"{route}: selected sample does not contain its request time")
        errors = item.get("regionMeanAbsoluteError")
        need(isinstance(errors, dict) and set(errors) == REGIONS, f"{route}: missing spatial pixel checks")
        for region, error in errors.items():
            limit = (3 if route == "webpLossless" else 6) if region == "wholeCanvas" else (9 if route == "webpLossless" else 18)
            if region in {"horizontalScroll", "verticalScroll", "oppositeScroll"}:
                limit = 65
            need(finite(error) and 0 <= error <= limit, f"{route}: {region} exceeds decoded-reference tolerance")
        previous = actual
        indices.add(source_index)
        total += item["delayMS"]
    need(total == 2050 and frames[0]["sourceIndex"] == 1 and frames[-1]["sourceIndex"] == 21,
         f"{route}: start/end/total duration differs")
    need({1, 2, 4, 6, 9, 13, 18, 19, 20, 21} <= indices, f"{route}: missing effect/expiry/pause/Stop witness")


def validate(root, commit):
    need(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "Expected full source commit required")
    fixture_path = root / "recording-input-export.json"
    fixture = read(fixture_path)
    native = read(root / "recording-input-export-independent.json")
    original = read(root / "recording-input.json")
    need(original.get("status") == "passed" and original.get("decodedFrames") == 22
         and original.get("sourceCommit") == commit, "Original159 input evidence is incomplete or mismatched")
    need(fixture.get("schemaVersion") == native.get("schemaVersion") == 1, "Unknown evidence schema")
    need(fixture.get("status") == "exported-awaiting-independent-validation" and native.get("status") == "passed",
         "Both installed export and independent decode evidence are required")
    need(fixture.get("sourceCommit") == native.get("sourceCommit") == commit, "Evidence source binding differs")
    need(native.get("fixtureReportSHA256") == digest(fixture_path, REPORT_CAP), "Independent reader used different fixture evidence")
    need(fixture.get("sourceSHA256") == native.get("sourceSHA256") == digest(root / "recording-input.mp4"),
         "Source bytes are not preserved/bound")
    for key in ("sourcePreserved", "original159ReportPreserved", "temporaryDirectoryRemoved", "independentValidationRequired"):
        need(fixture.get(key) is True, f"Fixture {key} not established")
    for key in ("captureStarted", "permissionRequested", "globalInputPosted", "regionRelocationTested", "typedTextCaptured"):
        need(fixture.get(key) is False, f"Fixture exceeded synthetic/privacy scope: {key}")
    need(native.get("sourcePreserved") is True and native.get("webPDecoder") == "PSCodecAnimationNext"
         and native.get("imageIOUsedForWebP") is False, "Missing native all-frame WebP reader")
    need(native.get("verifiedLoopCounts") == {"gif": 0, "webpLossless": 0, "webpLossy": 0},
         "Infinite animation looping was not verified")
    need(fixture.get("selectedStartSeconds") == 0.1 and fixture.get("selectedEndSeconds") == 2.15
         and fixture.get("selectedDurationSeconds") == 2.05 and fixture.get("expectedAnimationFrames") == 41
         and fixture.get("animationFrameRate") == 20, "Selected interval/frame plan changed")
    need(native.get("sourceFrames") == 22 and native.get("selectedFrames") == 21
         and finite(native.get("selectedDurationSeconds"))
         and abs(native["selectedDurationSeconds"] - 2.05) <= 1 / 600, "Independent MP4 decode/selected duration differs")
    need(fixture.get("maximumMediaBytes") == native.get("maximumMediaBytes") == MEDIA_CAP
         and fixture.get("maximumReportBytes") == native.get("maximumReportBytes") == REPORT_CAP
         and native.get("maximumFramesPerAnimation") == 41
         and native.get("maximumRGBABytesPerFrame") == 320 * 180 * 4, "Evidence decode bounds changed")
    exports = fixture.get("exports")
    need(isinstance(exports, list) and len(exports) == len(MEDIA), "Missing export routes")
    for item, (route, name) in zip(exports, MEDIA):
        need(item.get("route") == route and item.get("file") == name, "Unexpected export route/order")
        actual_hash = digest(root / name)
        need(item.get("sha256") == actual_hash == native.get("mediaHashes", {}).get(name), f"{name}: unbound output")
        need(item.get("bytes") == (root / name).stat().st_size, f"{name}: output size differs")
        if route != "mp4":
            process(item.get("process"))
            timeline(native.get(route), route)
    sentinels = fixture.get("destinationSentinels")
    need(isinstance(sentinels, list) and len(sentinels) == 4
         and {x.get("route") for x in sentinels} == {x[0] for x in MEDIA}
         and all(x.get("existingDestinationPreserved") is True for x in sentinels), "Destination sentinel coverage incomplete")
    cancellations = fixture.get("cancellations")
    expected = {(route, phase) for route, _ in MEDIA
                for phase in (["trim-start"] if route == "mp4" else ["trim-start", "helper-progress", "before-publication"])}
    need(isinstance(cancellations, list) and len(cancellations) == len(expected)
         and {(x.get("route"), x.get("phase")) for x in cancellations} == expected, "Cancellation coverage incomplete")
    for item in cancellations:
        need(item.get("destinationAbsent") is True, "Cancellation published output")
        if item["phase"] != "trim-start":
            process(item.get("process"))
    need(not any(x.name.startswith(".picshot-") for x in root.iterdir()), "Owned export stage remains")
    return {"status": "passed", "sourceCommit": commit, "decodedFrames": {"sourceMP4": 22, "selectedMP4": 21,
            "gif": 41, "webpLossless": 41, "webpLossy": 41}, "selectedDurationSeconds": 2.05}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence_directory", type=Path)
    parser.add_argument("source_commit")
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.evidence_directory, args.source_commit), sort_keys=True))
    except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as error:
        parser.exit(1, f"Recording input derived validation failed: {error}\n")
