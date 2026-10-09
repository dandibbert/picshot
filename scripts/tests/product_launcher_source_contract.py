"""Remove only the four literal counted opt-in product launcher insertions."""


def without_product_launcher_hooks(test, source):
    hooks = [
        ('"PICSHOT_EDITABLE_PRODUCT_MODE", "PICSHOT_EDITABLE_PRODUCT_INPUT", "PICSHOT_EDITABLE_PRODUCT_CERTIFICATE", ', ''),
        ('let launchBeganUptime = ProcessInfo.processInfo.systemUptime\n', ''),
        ('if ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil ||\n       ProcessInfo.processInfo.environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"] == "1" ||',
         'if ProcessInfo.processInfo.environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"] == "1" ||'),
        ('        if ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil {\n'
         '            report["launchBeganUptimeSeconds"] = launchBeganUptime\n'
         '            report["finishUptimeSeconds"] = ProcessInfo.processInfo.systemUptime\n'
         '        }\n', ''),
    ]
    for hook, replacement in hooks:
        test.assertEqual(source.count(hook), 1, 'Missing, duplicated or changed product-only launcher hook')
        source = source.replace(hook, replacement, 1)
    return source
