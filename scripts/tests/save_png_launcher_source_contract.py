"""Exact opt-in Save comparison launcher delta; historical identities stay fixed."""

SAVE_PNG_LAUNCHER_HOOKS = (('let savePNGComparisonMode = ProcessInfo.processInfo.environment["PICSHOT_SAVE_PNG_COMPARISON_MODE"]\n'
  'let savePNGComparisonDiagnostic = savePNGComparisonMode != nil\n',
  ''),
 ('for key in ["PICSHOT_SAVE_PNG_COMPARISON_MODE", "PICSHOT_SAVE_PNG_COMPARISON_ARM", '
  '"PICSHOT_SAVE_PNG_COMPARISON_INPUT_DIRECTORY", "PICSHOT_TEXT_SCRIPT_DEMO_ONLY", '
  '"PICSHOT_CAPTURE_CHAIN_DEMO_ONLY", "PICSHOT_LIVE_SCROLL_RESOURCE_MODE", '
  '"PICSHOT_LIVE_SCROLL_RESOURCE_INPUT", "PICSHOT_LIVE_SCROLL_PNG_WRITER", "PICSHOT_LIVE_SCROLL_DEMO_ONLY", '
  '"PICSHOT_LIVE_SCROLL_TARGET", "PICSHOT_CODEC_STAGING_MODE", "PICSHOT_CODEC_STAGING_ARM", '
  '"PICSHOT_CODEC_STAGING_PROFILE", "PICSHOT_CODEC_STAGING_FORMAT", "PICSHOT_CODEC_STAGING_INPUT_DIRECTORY", '
  '"PICSHOT_EDITABLE_PRODUCT_MODE", "PICSHOT_EDITABLE_PRODUCT_INPUT", '
  '"PICSHOT_EDITABLE_PRODUCT_CERTIFICATE", "PICSHOT_RENDERER_STORAGE_STRATEGY", '
  '"PICSHOT_DRAWING_RASTER_STRATEGY", "PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY", '
  '"PICSHOT_EDITABLE_HASH_DIAGNOSTIC", "PICSHOT_EDITABLE_ANNOTATIONS_ONLY", '
  '"PICSHOT_EDITABLE_ANNOTATION_RESOURCES", "PICSHOT_MULTIWINDOW_COMPOSITION", '
  '"PICSHOT_MULTIWINDOW_RESOURCES_ONLY", "PICSHOT_MULTIWINDOW_DIAGNOSTIC_TAIL_FIRST", '
  '"PICSHOT_MULTIWINDOW_DIAGNOSTIC_BOUNDARIES", "PICSHOT_RECORDING_COMPOSITION_ONLY", '
  '"PICSHOT_RECORDING_COMPOSITION_TRACE", "PICSHOT_MANUAL_HASH_STRATEGY", "PICSHOT_SCROLL_ATTRIBUTION_MODE", '
  '"PICSHOT_SCROLL_ATTRIBUTION_INPUT_DIRECTORY", "PICSHOT_SCROLL_ATTRIBUTION_PRODUCTION_COMMIT", '
  '"PICSHOT_SCROLL_ATTRIBUTION_OVERLAY_COMMIT", "PICSHOT_MANUAL_SCROLL_ONLY", '
  '"PICSHOT_MANUAL_SCROLL_RESOURCES", "PICSHOT_ANNOTATION_DETAILS_ONLY", "PICSHOT_AUTOMATIC_MOSAIC_ONLY", '
  '"PICSHOT_PIN_GROUP_TRANSFORMS_ONLY", "PICSHOT_LATEX_PIN_VERIFY", "PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY", '
  '"PICSHOT_SMOKE_FORMULA_MODEL_DIR", "PICSHOT_SMOKE_FORMULA_INPUT", "PICSHOT_SMOKE_TABLE_MODEL_DIR", '
  '"PICSHOT_SMOKE_TABLE_INPUT", "PICSHOT_SMOKE_ERASE_MODEL_DIR", "PICSHOT_UI_PREVIEW_ONLY", '
  '"PICSHOT_SMOKE_GIF_RESOURCES", "PICSHOT_GIF_DIAGNOSTIC_MODE", "PICSHOT_GIF_EXTRACTION", '
  '"PICSHOT_GIF_EXECUTION", "PICSHOT_CODEC_ATTRIBUTION_MODE", "PICSHOT_CODEC_ATTRIBUTION_FORMAT", '
  '"PICSHOT_CODEC_ATTRIBUTION_PROFILE", "PICSHOT_CODEC_ATTRIBUTION_INPUT_DIRECTORY", '
  '"PICSHOT_IMAGE_BACKING_MODE", "PICSHOT_IMAGE_BACKING_FORMAT", "PICSHOT_IMAGE_BACKING_PROFILE", '
  '"PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY"] {\n',
  'for key in ["PICSHOT_TEXT_SCRIPT_DEMO_ONLY", "PICSHOT_CAPTURE_CHAIN_DEMO_ONLY", '
  '"PICSHOT_LIVE_SCROLL_RESOURCE_MODE", "PICSHOT_LIVE_SCROLL_RESOURCE_INPUT", '
  '"PICSHOT_LIVE_SCROLL_PNG_WRITER", "PICSHOT_LIVE_SCROLL_DEMO_ONLY", "PICSHOT_LIVE_SCROLL_TARGET", '
  '"PICSHOT_CODEC_STAGING_MODE", "PICSHOT_CODEC_STAGING_ARM", "PICSHOT_CODEC_STAGING_PROFILE", '
  '"PICSHOT_CODEC_STAGING_FORMAT", "PICSHOT_CODEC_STAGING_INPUT_DIRECTORY", "PICSHOT_EDITABLE_PRODUCT_MODE", '
  '"PICSHOT_EDITABLE_PRODUCT_INPUT", "PICSHOT_EDITABLE_PRODUCT_CERTIFICATE", '
  '"PICSHOT_RENDERER_STORAGE_STRATEGY", "PICSHOT_DRAWING_RASTER_STRATEGY", '
  '"PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY", "PICSHOT_EDITABLE_HASH_DIAGNOSTIC", '
  '"PICSHOT_EDITABLE_ANNOTATIONS_ONLY", "PICSHOT_EDITABLE_ANNOTATION_RESOURCES", '
  '"PICSHOT_MULTIWINDOW_COMPOSITION", "PICSHOT_MULTIWINDOW_RESOURCES_ONLY", '
  '"PICSHOT_MULTIWINDOW_DIAGNOSTIC_TAIL_FIRST", "PICSHOT_MULTIWINDOW_DIAGNOSTIC_BOUNDARIES", '
  '"PICSHOT_RECORDING_COMPOSITION_ONLY", "PICSHOT_RECORDING_COMPOSITION_TRACE", '
  '"PICSHOT_MANUAL_HASH_STRATEGY", "PICSHOT_SCROLL_ATTRIBUTION_MODE", '
  '"PICSHOT_SCROLL_ATTRIBUTION_INPUT_DIRECTORY", "PICSHOT_SCROLL_ATTRIBUTION_PRODUCTION_COMMIT", '
  '"PICSHOT_SCROLL_ATTRIBUTION_OVERLAY_COMMIT", "PICSHOT_MANUAL_SCROLL_ONLY", '
  '"PICSHOT_MANUAL_SCROLL_RESOURCES", "PICSHOT_ANNOTATION_DETAILS_ONLY", "PICSHOT_AUTOMATIC_MOSAIC_ONLY", '
  '"PICSHOT_PIN_GROUP_TRANSFORMS_ONLY", "PICSHOT_LATEX_PIN_VERIFY", "PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY", '
  '"PICSHOT_SMOKE_FORMULA_MODEL_DIR", "PICSHOT_SMOKE_FORMULA_INPUT", "PICSHOT_SMOKE_TABLE_MODEL_DIR", '
  '"PICSHOT_SMOKE_TABLE_INPUT", "PICSHOT_SMOKE_ERASE_MODEL_DIR", "PICSHOT_UI_PREVIEW_ONLY", '
  '"PICSHOT_SMOKE_GIF_RESOURCES", "PICSHOT_GIF_DIAGNOSTIC_MODE", "PICSHOT_GIF_EXTRACTION", '
  '"PICSHOT_GIF_EXECUTION", "PICSHOT_CODEC_ATTRIBUTION_MODE", "PICSHOT_CODEC_ATTRIBUTION_FORMAT", '
  '"PICSHOT_CODEC_ATTRIBUTION_PROFILE", "PICSHOT_CODEC_ATTRIBUTION_INPUT_DIRECTORY", '
  '"PICSHOT_IMAGE_BACKING_MODE", "PICSHOT_IMAGE_BACKING_FORMAT", "PICSHOT_IMAGE_BACKING_PROFILE", '
  '"PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY"] {\n'),
 ('if savePNGComparisonDiagnostic || liveScrollDiagnostic || captureChainDiagnostic || textScriptDiagnostic '
  '|| recordingInputExportOnly || pinUIDiagnostic != nil {\n',
  'if liveScrollDiagnostic || captureChainDiagnostic || textScriptDiagnostic || recordingInputExportOnly || '
  'pinUIDiagnostic != nil {\n'),
 ('let effectiveTimeout: TimeInterval = savePNGComparisonDiagnostic\n'
  '    ? (savePNGComparisonMode == "validate" ? 240 : 360)\n'
  '    : ((captureChainDiagnostic || textScriptDiagnostic) ? 240 : timeout)\n',
  'let effectiveTimeout: TimeInterval = (captureChainDiagnostic || textScriptDiagnostic) ? 240 : timeout\n'),
 ('    if savePNGComparisonDiagnostic || liveScrollDiagnostic || captureChainDiagnostic || '
  'textScriptDiagnostic || recordingInputExportOnly || '
  'ProcessInfo.processInfo.environment["PICSHOT_CODEC_STAGING_MODE"] != nil || '
  'ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil ||\n',
  '    if liveScrollDiagnostic || captureChainDiagnostic || textScriptDiagnostic || recordingInputExportOnly '
  '|| ProcessInfo.processInfo.environment["PICSHOT_CODEC_STAGING_MODE"] != nil || '
  'ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil ||\n'),
 ('        if savePNGComparisonDiagnostic || '
  'ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil {\n',
  '        if ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil {\n'),
 ('        if savePNGComparisonDiagnostic {\n'
  '            report["savePNGComparisonDiagnosticOnly"] = true\n'
  '            report["savePNGComparisonMode"] = savePNGComparisonMode!\n'
  '            report["arguments"] = configuration.arguments\n'
  '        }\n'
  '        if savePNGComparisonDiagnostic || recordingInputExportOnly || liveScrollDiagnostic || '
  'captureChainDiagnostic || textScriptDiagnostic {\n',
  '        if recordingInputExportOnly || liveScrollDiagnostic || captureChainDiagnostic || '
  'textScriptDiagnostic {\n'),
 ('        if (savePNGComparisonDiagnostic || liveScrollDiagnostic || captureChainDiagnostic || '
  'textScriptDiagnostic || recordingInputExportOnly || '
  'ProcessInfo.processInfo.environment["PICSHOT_CODEC_STAGING_MODE"] != nil) && !launchedIdentityMatches() '
  '{\n',
  '        if (liveScrollDiagnostic || captureChainDiagnostic || textScriptDiagnostic || '
  'recordingInputExportOnly || ProcessInfo.processInfo.environment["PICSHOT_CODEC_STAGING_MODE"] != nil) && '
  '!launchedIdentityMatches() {\n'),
 ('if let launched, !launched.isTerminated, !(savePNGComparisonDiagnostic || recordingInputExportOnly || '
  'liveScrollDiagnostic || captureChainDiagnostic || textScriptDiagnostic) || launchedIdentityMatches(),\n',
  'if let launched, !launched.isTerminated, !(recordingInputExportOnly || liveScrollDiagnostic || '
  'captureChainDiagnostic || textScriptDiagnostic) || launchedIdentityMatches(),\n'))

def without_save_png_launcher_hooks(test, source):
    for hook, replacement in SAVE_PNG_LAUNCHER_HOOKS:
        test.assertEqual(source.count(hook), 1, "Missing, duplicate or changed Save PNG launcher hook")
        source = source.replace(hook, replacement, 1)
    test.assertNotIn('savePNGComparison', source, "Unreviewed Save PNG launcher addition")
    test.assertNotIn('PICSHOT_SAVE_PNG_', source, "Unreviewed Save PNG selector")
    return source

def current_save_png_fragment(fragment):
    # Older tests mutate current source, not obsolete literals. Preserve their
    # original post-reversal assertions and exact historical hashes.
    for current, previous in SAVE_PNG_LAUNCHER_HOOKS:
        if previous and previous in fragment:
            fragment = fragment.replace(previous, current)
    return fragment
