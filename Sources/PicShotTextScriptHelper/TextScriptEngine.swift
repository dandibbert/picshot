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
        try disableDefaultHostGlobals(in: context)

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

        let boundary = try makeExceptionBoundary(in: context)
        JSValueProtect(context, boundary)
        defer { JSValueUnprotect(context, boundary) }
        guard let failure = JSObjectMake(context, nil, nil) else { throw TextScriptDiagnostic.runtimeUnavailable }
        JSValueProtect(context, failure)
        defer { JSValueUnprotect(context, failure) }

        let inputString = try makeString(text)
        defer { JSStringRelease(inputString) }
        guard let input = JSValueMakeString(context, inputString) else { throw TextScriptDiagnostic.runtimeUnavailable }
        JSValueProtect(context, input)
        defer { JSValueUnprotect(context, input) }
        let arguments: [JSValueRef?] = [function, input, failure]
        exception = nil
        let result = arguments.withUnsafeBufferPointer {
            JSObjectCallAsFunction(context, boundary, nil, $0.count, $0.baseAddress, &exception)
        }
        guard exception == nil, let result else { throw TextScriptDiagnostic.scriptException }
        JSValueProtect(context, result)
        defer { JSValueUnprotect(context, result) }
        guard !JSValueIsStrictEqual(context, result, failure) else { throw TextScriptDiagnostic.scriptException }
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

    /// Catch user-thrown values inside JavaScript: JSC's C API exception-reporting path
    /// may stringify them even if native code never examines its exception pointer.
    /// This strict, unexported wrapper uses only lexical parameters and a direct call.
    /// It never inspects the caught value, a result property, or a mutable global API.
    private static func makeExceptionBoundary(in context: JSGlobalContextRef) throws -> JSObjectRef {
        let functionParameter = try makeString("fn")
        defer { JSStringRelease(functionParameter) }
        let textParameter = try makeString("text")
        defer { JSStringRelease(textParameter) }
        let failureParameter = try makeString("failure")
        defer { JSStringRelease(failureParameter) }
        let body = try makeString("\"use strict\"; try { return fn(text); } catch { return failure; }")
        defer { JSStringRelease(body) }
        let parameters: [JSStringRef?] = [functionParameter, textParameter, failureParameter]
        var exception: JSValueRef?
        let boundary = parameters.withUnsafeBufferPointer {
            JSObjectMakeFunction(context, nil, UInt32($0.count), $0.baseAddress, body, nil, 1, &exception)
        }
        guard exception == nil, let boundary else { throw TextScriptDiagnostic.runtimeUnavailable }
        return boundary
    }

    /// Some JavaScriptCore versions install a console even when inspection is disabled.
    /// Remove it and the optional ShadowRealm constructor, which could create another
    /// realm with default globals, before compiling user source. This only defines the
    /// available API; the independently verified App Sandbox is a separate boundary.
    private static func disableDefaultHostGlobals(in context: JSGlobalContextRef) throws {
        guard let global = JSContextGetGlobalObject(context) else { throw TextScriptDiagnostic.runtimeUnavailable }
        for identifier in ["console", "ShadowRealm"] {
            let name = try makeString(identifier)
            defer { JSStringRelease(name) }
            var exception: JSValueRef?
            guard JSObjectDeleteProperty(context, global, name, &exception), exception == nil,
                  !JSObjectHasProperty(context, global, name) else { throw TextScriptDiagnostic.runtimeUnavailable }
            let attributes = JSPropertyAttributes(kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete | kJSPropertyAttributeDontEnum)
            JSObjectSetProperty(context, global, name, JSValueMakeUndefined(context), attributes, &exception)
            guard exception == nil else { throw TextScriptDiagnostic.runtimeUnavailable }
            // Verify both immutable replacement and failed deletion with public property APIs.
            // Any rejection exception is discarded, never inspected or converted to text.
            JSObjectSetProperty(context, global, name, JSValueMakeBoolean(context, true), JSPropertyAttributes(kJSPropertyAttributeNone), nil)
            guard !JSObjectDeleteProperty(context, global, name, nil),
                  let value = JSObjectGetProperty(context, global, name, &exception), exception == nil,
                  JSValueIsUndefined(context, value) else { throw TextScriptDiagnostic.runtimeUnavailable }
        }
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
