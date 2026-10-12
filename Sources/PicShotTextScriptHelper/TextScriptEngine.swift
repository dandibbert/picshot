import Foundation
import JavaScriptCore
import PicShotTextScriptCore

enum TextScriptEngine {
    /// There are no native exports, callbacks, JSExport objects or shared global context.
    /// `source` is the editable BODY of function transform(text), never a whole wrapper.
    static func transform(source: String, text: String) throws -> String {
        try TextScriptRequest.transform(source: source, text: text).validate()
        guard let group = JSContextGroupCreate() else { throw TextScriptDiagnostic.runtimeUnavailable }
        defer { JSContextGroupRelease(group) }
        guard let context = JSGlobalContextCreateInGroup(group, nil) else { throw TextScriptDiagnostic.runtimeUnavailable }
        defer { JSGlobalContextRelease(context) }
        JSGlobalContextSetInspectable(context, false)
        guard !JSGlobalContextIsInspectable(context) else { throw TextScriptDiagnostic.runtimeUnavailable }

        let functionName = try makeString("transform")
        defer { JSStringRelease(functionName) }
        let parameterName = try makeString("text")
        defer { JSStringRelease(parameterName) }
        let body = try makeString(source)
        defer { JSStringRelease(body) }
        var exception: JSValueRef?
        var parameter: JSStringRef? = parameterName
        let function = withUnsafePointer(to: &parameter) {
            JSObjectMakeFunction(context, functionName, 1, $0, body, nil, 1, &exception)
        }
        // Do not inspect any exception property: a getter/toString can execute user code.
        guard exception == nil, let function else { throw TextScriptDiagnostic.syntaxError }
        JSValueProtect(context, function)
        defer { JSValueUnprotect(context, function) }

        let inputString = try makeString(text)
        defer { JSStringRelease(inputString) }
        guard let input = JSValueMakeString(context, inputString) else { throw TextScriptDiagnostic.runtimeUnavailable }
        JSValueProtect(context, input)
        defer { JSValueUnprotect(context, input) }
        var argument: JSValueRef? = input
        exception = nil
        let result = withUnsafePointer(to: &argument) {
            JSObjectCallAsFunction(context, function, nil, 1, $0, &exception)
        }
        guard exception == nil, let result else { throw TextScriptDiagnostic.scriptException }
        JSValueProtect(context, result)
        defer { JSValueUnprotect(context, result) }
        // Primitive check precedes conversion. Promise, boxed String, Proxy and all other
        // objects are rejected without calling their coercion hooks.
        guard JSValueIsString(context, result) else { throw TextScriptDiagnostic.outputNotString }
        guard let string = JSValueToStringCopy(context, result, nil) else { throw TextScriptDiagnostic.runtimeUnavailable }
        defer { JSStringRelease(string) }
        let count = JSStringGetLength(string)
        guard count > 0 else { throw TextScriptDiagnostic.emptyOutput }
        guard count <= TextScriptLimits.outputUTF16Units else { throw TextScriptDiagnostic.outputTooLarge }
        // Inspect the JSC UTF-16 backing buffer before allocating any native result string.
        guard let characters = JSStringGetCharactersPtr(string) else { throw TextScriptDiagnostic.runtimeUnavailable }
        let units = UnsafeBufferPointer(start: characters, count: count)
        try validateUnicode(units)
        let output = String(decoding: units, as: UTF16.self)
        guard output.utf8.count <= TextScriptLimits.outputUTF8Bytes else { throw TextScriptDiagnostic.outputTooLarge }
        return output
    }

    private static func makeString(_ string: String) throws -> JSStringRef {
        // A bounded UTF-16 array also preserves embedded NUL; C-string creation would not.
        let units = Array(string.utf16)
        guard let value = units.withUnsafeBufferPointer({ JSStringCreateWithCharacters($0.baseAddress, $0.count) }) else {
            throw TextScriptDiagnostic.runtimeUnavailable
        }
        return value
    }

    private static func validateUnicode(_ units: UnsafeBufferPointer<UInt16>) throws {
        var index = 0
        while index < units.count {
            let unit = units[index]
            if (0xd800...0xdbff).contains(unit) {
                guard index + 1 < units.count, (0xdc00...0xdfff).contains(units[index + 1]) else {
                    throw TextScriptDiagnostic.invalidUnicode
                }
                index += 2
            } else {
                guard !(0xdc00...0xdfff).contains(unit) else { throw TextScriptDiagnostic.invalidUnicode }
                index += 1
            }
        }
    }
}
