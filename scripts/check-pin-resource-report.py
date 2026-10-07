"""Optional native-report assertions for the owner wrapper; no report is fabricated here."""
import json,sys
r=json.load(open(sys.argv[1])); kind=sys.argv[2]
assert kind in ('group','latex')
assert r['status']=='passed', {key: r[key] for key in ('status','error','stage') if key in r}
e=r['resourceEvidence']; warm,cycles,live,warm_probes,probes,final_probes=(3,20,4,15,100,4) if kind=='group' else (2,12,1,4,24,1)
assert e['observationsComplete'] is True and e['warmupCycles']==warm and e['measuredCycles']==cycles
assert e['completedMeasuredCycles']==cycles and len(e['settledAfterCycles'])==cycles
assert e['sampleIntervalSeconds']==0.05 and e['measuredElapsedSeconds']>0 and e['processIdentifier']>0
for key in ('warmupSampledMemory','sampledMemory'):
    s=e[key]; total=s['timerTickCount']+s['boundarySampleCount']
    assert s['timerTickCount']>0 and s['boundarySampleCount']>0
    assert s['residentSampleCount']==s['physicalFootprintSampleCount']==total
    assert s['failedResidentSampleCount']==s['failedPhysicalFootprintSampleCount']==0
    assert s['peakResidentBytes']>0 and s['peakPhysicalFootprintBytes']>0
for point in [e['beforeWarmup'],e['baselineAfterWarmup'],*e['settledAfterCycles'],e['afterMeasuredCycles'],e['finalAfterCleanup']]:
    assert point['residentBytes']>0 and point['physicalFootprintBytes']>0
assert e['settledAfterCycles'][-1]==e['afterMeasuredCycles']
assert e['livePinsAtBaselineAndCycleEnds']==live and e['livePinsAfterCleanup']==0
assert e['warmupReleaseProbes']==warm_probes and e['measuredReleaseProbes']==probes and e['finalTeardownReleaseProbes']==final_probes
assert e['retainedControllers']==e['retainedContentViews']==0
assert e['assetsUnchanged'] is True and e['assetDigests']
assert e['memoryIsObservational'] is True and e['stabilityAssessed'] is False and e['lateIntervalCycles']==1
for field,label in [('residentBytes','resident'),('physicalFootprintBytes','physicalFootprint')]:
    ends=[x[field] for x in e['settledAfterCycles']]
    assert e[label+'GrowthFromWarmupBytes']==ends[-1]-e['baselineAfterWarmup'][field]
    assert e[label+'LastIntervalGrowthBytes']==ends[-1]-ends[-2]
    assert e[label+'LateThreeIntervalGrowthBytes']==[ends[i]-ends[i-1] for i in range(cycles-3,cycles)]
    assert e[label+'CleanupDeltaBytes']==e['finalAfterCleanup'][field]-ends[-1]
assert r['desktopVisibilityPreferencesIsolated'] is True
if kind=='latex':
    assert e['retainedSourceModels']==0 and e['fixtureRequestedRendersDuringCycles']==0
    g=r['formulaSaveChooserGeometry']
    assert g['status']=='passed' and g['nativeWindowGeometryOnly'] is True and g['pixelsCaptured'] is False
    assert g['stableVisibleFrameObservations']>=3
    assert g['pinBefore']==g['compactRequestedFrame']==g['pinAfterCancel']
    assert g['pinBefore']['width']==180 and g['pinBefore']['height']==72
    for key in ('chooserWasVisible','ownedSheetVerified','fullyOnScreen','pinFrameUnchanged','cancelledWithoutOrphanSheet'):
        assert g[key] is True
    f,v=g['chooserFrame'],g['screenVisibleFrame']
    assert f['width']>0 and f['height']>0 and f['x']>=v['x'] and f['y']>=v['y']
    assert f['x']+f['width']<=v['x']+v['width'] and f['y']+f['height']<=v['y']+v['height']
else:
    assert r['userDefaultsChanged'] is False and r['userPreferenceReadScope']
print('Native report evidence fields verified; no memory-envelope or stability verdict applied')
