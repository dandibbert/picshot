import XCTest
import PicShotTextScriptCore
@testable import PicShotTextScriptHelper

/// These bounded unit tests do not establish App Sandbox or owned-process lifecycle behavior.
/// Those properties require the exact signed native helper fixture, never an in-process fallback.
final class TextScriptEngineTests: XCTestCase {
    func testUnicodeRegexDedupeAndSeparateInput() throws {
        let source = "return [...new Set(text.match(/PIC-[0-9]+/g) || [])].join(' / ');"
        XCTAssertEqual(try TextScriptEngine.transform(source: source, text: "中文🙂 PIC-12 PIC-7 PIC-12"), "PIC-12 / PIC-7")
        let data = "\"); throw new Error('input is data'); //\u{0000}🙂"
        XCTAssertEqual(try TextScriptEngine.transform(source: "return text;", text: data), data)
    }

    func testWhitespaceNULAndBoundaryOutputArePreserved() throws {
        XCTAssertEqual(try TextScriptEngine.transform(source: "return ' \\u0000\\n';", text: "x"), " \u{0000}\n")
        XCTAssertEqual(try TextScriptEngine.transform(source: "return 'x'.repeat(32768);", text: "x").utf16.count, 32_768)
        expect(.outputTooLarge, source: "return 'x'.repeat(32769);")
        expect(.emptyOutput, source: "return ''; ")
    }

    func testSyntaxAndThrownPayloadHaveFixedDiagnostics() throws {
        expect(.syntaxError, source: "return (")
        expect(.syntaxError, source: "}; globalThis.compromised = true; function ignored(){")
        expect(.scriptException, source: "throw 'synthetic-private-exception';")
        expect(.scriptException, source: "throw { toString() { throw 'must-not-run'; }, get stack() { throw 'must-not-run'; } };")
        let callerProbe = """
        try {
            return arguments.callee.caller === null ? 'blocked' : 'exposed';
        } catch {
            return 'blocked';
        }
        """
        XCTAssertEqual(try TextScriptEngine.transform(source: callerProbe, text: "x"), "blocked")
        let tamperedThrow = """
        Object.prototype.toString = function() { throw 'must-not-run'; };
        Function.prototype.call = function() { throw 'must-not-run'; };
        Function.prototype.apply = function() { throw 'must-not-run'; };
        globalThis.fn = function() { return 'forged'; };
        globalThis.failure = 'forged';
        globalThis.text = 'forged';
        throw new Proxy({}, { get() { throw 'must-not-run'; } });
        """
        expect(.scriptException, source: tamperedThrow)
        let tamperedReturn = """
        Object.defineProperty(Object.prototype, 'value', { get() { throw 'must-not-run'; } });
        Function.prototype.call = function() { throw 'must-not-run'; };
        globalThis.failure = text;
        return text;
        """
        XCTAssertEqual(try TextScriptEngine.transform(source: tamperedReturn, text: "unchanged"), "unchanged")
    }

    func testOnlyPrimitiveStringsAcceptedWithoutCoercion() {
        for source in ["return 42;", "return undefined;", "return null;", "return false;",
                       "return new String('boxed');", "return Promise.resolve('async');",
                       "return { toString() { throw 'must-not-run'; } };",
                       "return new Proxy({}, { get() { throw 'must-not-run'; } });"] {
            expect(.outputNotString, source: source)
        }
    }

    func testRejectsUnpairedSurrogatesAndKeepsLegitimateReplacementCharacter() throws {
        expect(.invalidUnicode, source: "return '\\ud800';")
        expect(.invalidUnicode, source: "return '\\udc00';")
        expect(.invalidUnicode, source: "return '\\ud800x';")
        XCTAssertEqual(try TextScriptEngine.transform(source: "return '\\ud83d\\ude42\\ufffd';", text: "x"), "🙂�")
    }

    func testFreshContextAndAbsentHostAPIs() throws {
        XCTAssertEqual(try TextScriptEngine.transform(source: "globalThis.syntheticMarker = 42; return 'set';", text: "x"), "set")
        XCTAssertEqual(try TextScriptEngine.transform(source: "return typeof globalThis.syntheticMarker;", text: "x"), "undefined")
        let names = ["fetch", "XMLHttpRequest", "WebSocket", "require", "process", "Deno", "Bun", "ObjC",
                     "NSFileManager", "NSPasteboard", "window", "document", "setTimeout", "print", "console", "ShadowRealm"]
        for name in names {
            XCTAssertEqual(try TextScriptEngine.transform(source: "return typeof " + name + ";", text: "x"), "undefined", name)
        }
        let consoleAliases = """
        const absent = () => typeof console === 'undefined' && globalThis.console === undefined &&
            Reflect.get(globalThis, 'console') === undefined &&
            Function('return this.console')() === undefined &&
            (0, eval)('this.console') === undefined;
        if (!absent()) return 'initial-alias';
        console = { log() {} };
        globalThis.console = { log() {} };
        if (Reflect.set(globalThis, 'console', {}) || !absent()) return 'assignment';
        if (delete globalThis.console) return 'deletion';
        if (Reflect.deleteProperty(globalThis, 'console') || !absent()) return 'reflect-deletion';
        if (Function('delete this.console; this.console = {}; return this.console')() !== undefined)
            return 'function-alias';
        const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'console');
        if (!descriptor || descriptor.value !== undefined || descriptor.writable || descriptor.configurable)
            return 'descriptor';
        return absent() ? 'absent' : 'final-alias';
        """
        XCTAssertEqual(try TextScriptEngine.transform(source: consoleAliases, text: "x"), "absent")
        let realmAliases = """
        const absent = () => typeof ShadowRealm === 'undefined' && globalThis.ShadowRealm === undefined &&
            Reflect.get(globalThis, 'ShadowRealm') === undefined &&
            Function('return this.ShadowRealm')() === undefined &&
            (0, eval)('this.ShadowRealm') === undefined;
        if (!absent()) return 'initial-alias';
        ShadowRealm = function() {};
        globalThis.ShadowRealm = function() {};
        if (Reflect.set(globalThis, 'ShadowRealm', {}) || !absent()) return 'assignment';
        if (delete globalThis.ShadowRealm || Reflect.deleteProperty(globalThis, 'ShadowRealm')) return 'deletion';
        const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'ShadowRealm');
        if (!descriptor || descriptor.value !== undefined || descriptor.writable || descriptor.configurable)
            return 'descriptor';
        return absent() ? 'absent' : 'final-alias';
        """
        XCTAssertEqual(try TextScriptEngine.transform(source: realmAliases, text: "x"), "absent")
    }

    private func expect(_ diagnostic: TextScriptDiagnostic, source: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TextScriptEngine.transform(source: source, text: "synthetic-input"), file: file, line: line) {
            XCTAssertEqual($0 as? TextScriptDiagnostic, diagnostic, file: file, line: line)
        }
    }
}
