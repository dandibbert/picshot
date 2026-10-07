#!/bin/bash
# Explicit standalone diagnostic; no production/default CI hook or installer.
set -euo pipefail
if [[ $# -ne 3 || "$1" != --compare ]]; then
  echo 'Usage: image-draw-attribution.sh --compare /absolute/PicShot.app /absolute/new-evidence-directory' >&2
  exit 64
fi
cd "$(dirname "$0")/.."
app="$2"; root="$3"
[[ "$app" == /* && "$root" == /* && "$app" == *.app && ! -e "$root" ]] || { echo 'Use an absolute app path and a new evidence directory' >&2; exit 64; }
[[ "$(uname -s)" == Darwin ]] || { echo 'Native macOS is required' >&2; exit 69; }
architecture=$(uname -m)
[[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || exit 69
binary="$app/Contents/MacOS/PicShot"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/lipo "$binary" -verify_arch "$architecture"
source_commit=$(/usr/libexec/PlistBuddy -c 'Print :PicShotSourceCommit' "$app/Contents/Info.plist")
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'App must contain a full source commit' >&2; exit 65; }
python3 - "$binary" <<'PY'
import sys
needle=b'image-raster-materialization-v1'
with open(sys.argv[1],'rb') as f:
    tail=b''
    while True:
        block=f.read(1024*1024)
        if not block: raise SystemExit('App lacks the explicit draw diagnostic protocol')
        if needle in tail+block: break
        tail=block[-len(needle):]
PY
mkdir -p "$(dirname "$root")"
mkdir "$root"
cat > "$root/api-availability-check.swift" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
// Typecheck only: these functions are never invoked by the availability check.
func signatureOnly(pointer: UnsafeMutableRawPointer, info: UnsafeMutableRawPointer?) {
    let release: CGDataProviderReleaseDataCallback = { _, _, _ in }
    _ = CGDataProvider(dataInfo: info, data: UnsafeRawPointer(pointer), size: 1_769_472, releaseData: release)
    let callback: CGBitmapContextReleaseDataCallback = { _, _ in }
    _ = CGContext(data: pointer, width: 768, height: 576, bitsPerComponent: 8, bytesPerRow: 3072,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue,
        releaseCallback: callback, releaseInfo: info)
    let _: [CFString: Bool] = [kCGImageSourceShouldCache: false,
        kCGImageSourceShouldCacheImmediately: false, kCGImageSourceShouldAllowFloat: false]
}
SWIFT
xcrun swiftc -target "$architecture-apple-macos14.0" -typecheck "$root/api-availability-check.swift" > "$root/api-typecheck.log" 2>&1
printf 'CoreGraphics/ImageIO Swift API typecheck passed; no drawing or allocation was executed by this check\n' >> "$root/api-typecheck.log"
swift scripts/launch-image-draw.swift "$app" prepare-inputs "$root/prepared"
for mode in production-draw imageio-no-cache-draw owned-rgba-draw; do
  swift scripts/launch-image-draw.swift "$app" "$mode" "$root/$mode" "$root/prepared"
done
python3 - "$root" "$source_commit" "$architecture" <<'PY'
import json,math,pathlib,statistics,sys
root=pathlib.Path(sys.argv[1]);source,architecture=sys.argv[2:]
def read(path):
    data=path.read_bytes();assert len(data)<=1024*1024
    return json.loads(data)
prepared=read(root/'prepared/image-draw-inputs.json')
assert prepared['protocol']=='image-raster-materialization-v1' and prepared['status']=='prepared'
assert prepared['sourceCommit']==source and prepared['architecture']==architecture and prepared['syntheticSource']
assert prepared['sourceWidth']==768 and prepared['sourceHeight']==576 and prepared['rawBytes']==1769472
pids={prepared['processIdentifier']};summaries=[]
for mode in ['production-draw','imageio-no-cache-draw','owned-rgba-draw']:
    r=read(root/mode/f'image-draw-{mode}.json')
    assert r['protocol']=='image-raster-materialization-v1' and r['status']=='observed' and r['mode']==mode
    assert r['sourceCommit']==source and r['architecture']==architecture
    assert r['processIdentifier'] not in pids;pids.add(r['processIdentifier'])
    assert r['inputPreparationProcessIdentifier']==prepared['processIdentifier']
    assert r['sourceWidth']==768 and r['sourceHeight']==576 and r['rasterBytes']==1769472
    assert r['warmupCycles']==2 and r['measuredCycles']==12 and len(r['warmups'])==2 and len(r['cycles'])==12
    assert r['completedDraws']==14 and r['completedFullPixelValidations']==14
    assert r['pixelTolerance']==2 and r['destinationAllocationBytes']==1769472
    assert r['cooperativeDeadlineSeconds']==45 and r['requiredOuterDeadlineSeconds']==60 and r['elapsedSeconds']<=45
    assert r['allocatorReliefCalls']==0 and r['helperInvocations']==0 and r['ownedTemporaryMediaFiles']==0 and r['retainedCycleImages']==0
    assert not r['captureStarted'] and not r['networkAttempted'] and r['immutableInputsUnchanged'] and r['destinationOwnerDropped']
    assert r['immutablePNGSHA256']==prepared['pngSHA256'] and r['immutableRawSHA256']==prepared['rawSHA256']
    dest=r['destinationLifetime'];assert dest['allocations']==1 and dest['callbackSizesMatch']
    assert 0<=dest['releaseCallbacks']<=1 and 0<=dest['deallocations']<=1 and dest['peakActiveBytes']==1769472
    for group,warmup in [('warmups',True),('cycles',False)]:
        for index,c in enumerate(r[group],1):
            assert c['index']==index and c['isWarmup']==warmup and c['fixtureScopeExited']
            w=c['workload'];assert w['width']==768 and w['height']==576 and w['actualDrawCount']==1
            assert w['validatedRGBABytes']==1769472 and w['pixelsWithinTolerance'] and 0<=w['maximumAbsoluteChannelDifference']<=2
            assert len(w['pixelsSHA256'])==64
            for key in ['imageCreationSeconds','drawAndFlushSeconds','pixelValidationSeconds','totalOperationSeconds','workloadWallSeconds']:
                assert math.isfinite(w[key]) and w[key]>=0
            assert w['workloadWallSeconds']+1e-9>=w['totalOperationSeconds']
            for sample in [c['before'],w['beforeDrawImageLive'],w['afterDrawAndReadbackImageLive'],c['afterAutoreleasePool'],c['settled']]:
                assert sample['standard']['kernelReturn']==0 and sample['standard']['bytes']['resident_size']>0
                assert sample['standard']['bytes']['phys_footprint']>0 and 'kernelReturn' in sample['purgeable']
            if mode=='owned-rgba-draw':assert c['rawProviderLifetime']['allocations']==index+(2 if not warmup else 0)
            else:assert 'rawProviderLifetime' not in c
    if mode=='owned-rgba-draw':
        for key in ['rawProviderLifetimeBeforeDestinationClose','rawProviderLifetimeAfterDestinationClose']:
            p=r[key];assert p['allocations']==14 and p['callbackSizesMatch']
            assert 0<=p['releaseCallbacks']<=14 and 0<=p['deallocations']<=14
            assert p['activeBytes']==(14-p['deallocations'])*1769472 and p['peakActiveBytes']<=14*1769472
        # Release callback/deallocation completion is evidence, not forced pass criteria.
    else:assert 'rawProviderLifetimeAfterDestinationClose' not in r
    timing={key:statistics.median(c['workload'][key] for c in r['cycles']) for key in
        ['imageCreationSeconds','drawAndFlushSeconds','pixelValidationSeconds','totalOperationSeconds','workloadWallSeconds']}
    summary={'mode':mode,'residentTrend':r['residentTrend'],'physicalFootprintTrend':r['physicalFootprintTrend'],
        'medianMeasuredSeconds':timing,'destinationLifetime':dest}
    if mode=='owned-rgba-draw':summary['rawProviderLifetimeAfterDestinationClose']=r['rawProviderLifetimeAfterDestinationClose']
    summaries.append(summary)
assert len(pids)==4
summary={'status':'observed','sourceCommit':source,'architecture':architecture,'arms':summaries,
    'interpretation':'All arms actually drew and validated pixels; raw timing/callback/accounting observations do not establish a production remedy'}
(root/'comparison.json').write_text(json.dumps(summary,indent=2,sort_keys=True)+'\n')
print(json.dumps(summary,indent=2,sort_keys=True))
PY
