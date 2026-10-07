#!/usr/bin/env python3
"""Check installed native OCR evidence without treating RSS observations as leak proof."""
from pathlib import Path
import argparse
import json


def validate(r, *, expected_commit, expected_version, expected_build, installed_app, evidence_directory, full):
    assert r['status']=='passed' and r['schemaVersion']==1
    assert r['sourceCommit']==expected_commit and r['version']==expected_version
    assert r['buildVersion']==expected_build
    assert Path(r['bundlePath']).resolve()==installed_app.resolve()
    assert r['includeResourceCycles'] is full
    assert 0 < r['elapsedSeconds'] < r['overallDeadlineSeconds']==240
    assert r['realAppleVisionRan'] is True
    assert r['actualResourceVisionCalls']==(14 if full else 0)
    assert r['finalVisionActiveJobs']==r['finalVisionWaitingJobs']==0
    for k in ['temporaryDirectoryRemoved','privateDefaultsRemoved','privatePasteboardCopyVerified']:
        assert r[k] is True
    for k in ['standardUserDefaultsChanged','generalPasteboardChanged','screenCaptureStarted',
              'permissionRequests','networkUsed','globalInputPosted','physicalRetinaVerified',
              'externalApplicationVerified','tccAcceptanceVerified']:
        assert r[k] is False
    limits=r['limits']
    assert (limits['frontActiveJobs'],limits['frontAutomaticJobs'],limits['frontWaitingSessions'],
            limits['visionActiveJobs'],limits['visionWaitingJobs'],limits['livePins'])==(2,1,32,2,4,20)
    assert (limits['resourceWarmupCycles'],limits['resourceMeasuredCycles'])==(2,12)
    c=r['controls']
    assert c['status']=='passed' and c['automaticWithDirectCopyEnabled'] is True
    assert c['sentinelKeyAndFirstResponderPreserved'] is True
    assert c['automaticResultOpened'] is False and c['automaticPasteboardChanged'] is False
    assert c['cachedConsumers']==['selection','copy-all','result'] and c['bidirectionalPinResultLinks'] is True
    lang=c['languageRerun']
    if lang['supportedEnglish']:
        assert lang['status']=='passed' and lang['actualVisionRan'] is True and lang['nativePopupAction'] is True
        assert lang['language']=='en-US'
        assert r['actualFunctionalVisionCalls']==c['actualVisionCalls']==c['sourceReadCount']==2
    else:
        assert lang['status']=='unavailable' and lang['actualVisionRan'] is False and lang['reason']
        assert r['actualFunctionalVisionCalls']==c['actualVisionCalls']==c['sourceReadCount']==1
    link=r['sourceLinkAcceptance']
    assert link['status']=='passed' and link['exactDocumentPreserved'] is True
    assert link['sourceUnitCount']>=3 and link['realAppleVisionRanHere'] is False
    assert set(['compact-default','output-to-source','source-to-output','native-edits-unmapped',
                'unchanged-edit-spans','barcode-appendix-unmapped','join-lines-source-map',
                'close-clears-document']).issubset(link['checks'])
    g=r['coordinatorRestoration']
    assert g['status']=='passed' and g['restoredPinCount']==20 and g['controllerFactoryUsed'] is True
    assert g['deterministicRaceGate'] is True and g['realAppleVisionRanInRacePhase'] is False
    assert g['initialSourceReads']==1 and g['sourceReadsAfterExplicitPromotion']==2
    assert g['queuedMetadataContainsRasters'] is False and g['focusPreserved'] is True
    assert g['cancelledPendingCopyPreservedClipboard'] is True and g['sourceReadEvidence']
    assert g['cancellationChecks']==['hide-current-group','switch-group','native-click-through','recover-current-group','close']
    assert g['releaseProbeCount']==60 and g['retainedObjects']==g['liveControllersAfter']==g['gatePendingAfter']==0
    for entry,wanted in zip(g['observedFrontBoundaries'],[(1,1,19),(2,1,18)]):
        assert (entry['activeJobs'],entry['automaticJobs'],entry['waitingSessions'])==wanted
    assert len(g['observedFrontBoundaries'])==2
    f=g['finalFront']
    assert f['activeJobs']==f['automaticJobs']==f['waitingSessions']==f['rejectedJobs']==0
    assert f['admittedJobs']==f['releasedJobs']==f['cancelledJobs']==5
    for section,count in [(c,1),(g,60)]:
        assert section['releaseEvidence']['probeCount']==count
        assert all(v==0 for k,v in section['releaseEvidence'].items() if k.startswith('retained'))
    e=r['resourceEvidence']
    if not full:
        assert e['status']=='not-run' and e['warmupCycles']==e['completedMeasuredCycles']==e['actualVisionCalls']==0
    else:
        assert e['status']=='passed' and e['observationsComplete'] is True
        assert e['warmupCycles']==2 and e['measuredCycles']==e['completedMeasuredCycles']==12
        assert e['actualVisionCalls']==e['cachedResultReuseCount']==14 and e['sameAuthoredRasterEachCycle'] is True
        assert e['sampleIntervalSeconds']==0.05 and e['settlingDelaySeconds']==0.15
        assert e['measuredElapsedSeconds']>0 and e['processIdentifier']>0 and e['peakActualVisionCalls']==1
        assert e['livePinsAndResultsAtBaselineAndEveryCycleEnd']==e['activeJobsAtBaselineAndEveryCycleEnd']==0
        assert e['fixedInputRasterCountAtBaselineAndEveryCycleEnd']==1 and e['snapshotsInsideMeasuredLoop']==0
        assert e['warmupReleaseProbes']==2 and e['measuredReleaseProbes']==12 and e['retainedObjects']==0
        assert e['releaseEvidence']['probeCount']==14
        assert all(v==0 for k,v in e['releaseEvidence'].items() if k.startswith('retained'))
        assert e['memoryPressureOrSystemSettingsChanged'] is False
        assert e['memoryIsObservational'] is True and e['stabilityAssessed'] is False and e['lateIntervalCycles']==1
        f=e['finalFront']
        assert f['activeJobs']==f['automaticJobs']==f['waitingSessions']==f['cancelledJobs']==f['rejectedJobs']==0
        assert f['admittedJobs']==f['releasedJobs']==14
        for key in ['warmupSampledMemory','sampledMemory']:
            s=e[key]; total=s['timerTickCount']+s['boundarySampleCount']
            assert s['timerTickCount']>0 and s['boundarySampleCount']>0
            assert s['residentSampleCount']==s['physicalFootprintSampleCount']==total
            assert s['failedResidentSampleCount']==s['failedPhysicalFootprintSampleCount']==0
            assert s['peakResidentBytes']>0 and s['peakPhysicalFootprintBytes']>0
        assert len(e['settledAfterCycles'])==12 and e['settledAfterCycles'][-1]==e['afterMeasuredCycles']
        for point in [e['beforeWarmup'],e['baselineAfterWarmup'],*e['settledAfterCycles'],e['afterMeasuredCycles'],e['finalAfterCleanup']]:
            assert point['residentBytes']>0 and point['physicalFootprintBytes']>0
        for field,label in [('residentBytes','resident'),('physicalFootprintBytes','physicalFootprint')]:
            ends=[x[field] for x in e['settledAfterCycles']]
            assert e[label+'GrowthFromWarmupBytes']==ends[-1]-e['baselineAfterWarmup'][field]
            assert e[label+'LastIntervalGrowthBytes']==ends[-1]-ends[-2]
            assert e[label+'LateThreeIntervalGrowthBytes']==[ends[i]-ends[i-1] for i in range(9,12)]
            assert e[label+'CleanupDeltaBytes']==e['finalAfterCleanup'][field]-ends[-1]
    for name in r['evidenceFiles']:
        assert Path(name).name==name
        assert (evidence_directory/name).read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    assert len(r['evidenceFiles'])==6


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('app', type=Path)
    parser.add_argument('source')
    parser.add_argument('version')
    parser.add_argument('build')
    parser.add_argument('--full', action='store_true')
    args = parser.parse_args()
    validate(json.loads(args.report.read_text()), expected_commit=args.source,
             expected_version=args.version, expected_build=args.build,
             installed_app=args.app, evidence_directory=args.report.parent, full=args.full)
    print('Native OCR workflow evidence passed; memory remains observational')


if __name__ == '__main__':
    main()
