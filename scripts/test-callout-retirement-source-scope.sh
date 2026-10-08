#!/bin/bash
# Native support tests only; this does not run the app acceptance fixture.
set -euo pipefail
picshot_root="$(cd "$(dirname "$0")/.." && pwd)"
picshot_scope="$(mktemp -d "${TMPDIR:-/tmp}/PicShot-Callout-Retirement.XXXXXX")"
trap 'rm -rf "$picshot_scope"' EXIT
mkdir -p "$picshot_scope/Sources/PicShot" "$picshot_scope/Tests/PicShotTests"
cp "$picshot_root/Sources/PicShot/NumberedCalloutRetirementDiagnostics.swift" "$picshot_scope/Sources/PicShot/"
cp "$picshot_root/Tests/PicShotTests/NumberedCalloutRetirementDiagnosticsTests.swift" "$picshot_scope/Tests/PicShotTests/"
python3 - "$picshot_root" "$picshot_scope" <<'PY'
import hashlib
from pathlib import Path
import sys
root, scope = map(Path, sys.argv[1:])
source = root / 'Sources/PicShot/NumberedCalloutLifecycle.swift'
text = source.read_text()
marker = '/// All references are weak.'
if text.count(marker) != 1: raise ValueError('Lifecycle prefix marker changed')
prefix = text[:text.index(marker)]
if 'struct NumberedCalloutLifecycleEvidence: Codable' not in prefix: raise ValueError('Missing original evidence type')
if 'class NumberedCalloutClosedInputProbe' in prefix: raise ValueError('Unexpected app dependencies in prefix')
(scope / 'Sources/PicShot/LifecycleEvidence.swift').write_text(prefix)
for path in [source, root / 'Sources/PicShot/NumberedCalloutRetirementDiagnostics.swift', root / 'Tests/PicShotTests/NumberedCalloutRetirementDiagnosticsTests.swift']:
    print(hashlib.sha256(path.read_bytes()).hexdigest(), path.relative_to(root))
print('Extracted unchanged lifecycle evidence prefix SHA256', hashlib.sha256(prefix.encode()).hexdigest())
PY
cat > "$picshot_scope/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PicShotCalloutRetirementScope", platforms: [.macOS(.v14)], targets: [
    .target(name: "PicShot"), .testTarget(name: "PicShotTests", dependencies: ["PicShot"])
])
PACKAGE
swift test --package-path "$picshot_scope" -Xswiftc -DPICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS --filter NumberedCalloutRetirementDiagnosticsTests
