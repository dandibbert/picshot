"""Exact, counted removals of diagnostic-only hooks added after source129.

Never update the old fixture fingerprints to accept an unrelated change.
"""
NATIVE = 'Sources/PicShot/EditableAnnotationNativeFixture.swift'
DRAWING = 'Sources/PicShot/EditableDrawingPairDiagnostic.swift'
HOOKS = {
    NATIVE: (
        '        try SeedRenderCropSubstageProbe.process?.checkpoint(.afterNativeCrop)\n',
        '        try SeedRenderCropSubstageProbe.process?.checkpoint(.afterReferenceFullRender)\n',
    ),
    DRAWING: (
        '        try SeedRenderCropSubstageProbe.begin(includeResources: includeResources)\n',
        '        try SeedRenderCropSubstageProbe.process?.observeDrawingCheckpoint(checkpoints[checkpoints.count - 1])\n',
        '        try SeedRenderCropSubstageProbe.process?.write(native: native, nativeData: nativeData, drawingData: data, directory: directory)\n',
    ),
}
SOURCE129_SHA256 = {
    NATIVE: '4b328adbce635a7f9801b347294146814986e56a94ea12c28c00cd513e1489c3',
    DRAWING: '59b16741cd310d899c44769e5612884da1ebaf27e393a1e9eaabcee5434d7a8c',
    'Sources/PicShot/EditableAnnotationFixtureObservation.swift': 'a1bca80ae3b178aff0a166871eba12718f8f878b14054958814492c50b0a6dad',
    'Sources/PicShot/EffectOutputFailureNativeFixture.swift': '24ce9bf612aef873351f4abc3702dd4f78f9f61b12d67b83b5e6caf33b076cb7',
    'Sources/PicShot/EffectContextGuardControl.swift': '540797eda3c4eb392c5ba675c57ecaab1105856de972544e9449e32f6d4033de',
}


def without_substage_hooks(path, source):
    for hook in HOOKS.get(path, ()):
        count = source.count(hook)
        if count != 1:
            raise AssertionError(f'{path}: expected exactly one unchanged substage hook; got {count}: {hook!r}')
        source = source.replace(hook, '', 1)
    return source
