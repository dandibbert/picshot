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

    func testSyntaxAndThrownPayloadHaveFixedDiagnostics() {
        expect(.syntaxError, source: "return (")
        expect(.syntaxError, source: "}; globalThis.compromised = true; function ignored(){")
        expect(.scriptException, source: "throw 'synthetic-private-exception';")
        expect(.scriptException, source: "throw { toString() { throw 'must-not-run'; }, get stack() { throw 'must-not-run'; } };")
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
                     "NSFileManager", "NSPasteboard", "window", "document", "setTimeout", "print", "console"]
        for name in names {
            XCTAssertEqual(try TextScriptEngine.transform(source: "return typeof " + name + ";", text: "x"), "undefined", name)
        }
    }

    private func expect(_ diagnostic: TextScriptDiagnostic, source: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TextScriptEngine.transform(source: source, text: "synthetic-input"), file: file, line: line) {
            XCTAssertEqual($0 as? TextScriptDiagnostic, diagnostic, file: file, line: line)
        }
    }
}
