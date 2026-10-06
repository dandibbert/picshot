import Foundation

public enum SaveWorkflowValidationError: LocalizedError, Equatable {
    case invalidBaseDirectory, invalidTemplate, unknownVariable(String), invalidContext, pathTooLong, counterExhausted
    public var errorDescription: String? {
        switch self {
        case .invalidBaseDirectory: return "请先选择本地保存文件夹；路径不能包含链接或上级目录。"
        case .invalidTemplate: return "命名模板无效。请使用普通名称以及 {date}、{time}、{width}、{height}、{counter}。"
        case .unknownVariable(let name): return "未知的命名变量：{\(name)}。"
        case .invalidContext: return "截图尺寸、时间或编号无效。"
        case .pathTooLong: return "保存路径过长或文件夹层级过多。"
        case .counterExhausted: return "自动命名编号已用尽，请重新设置命名。"
        }
    }
}

public struct SaveWorkflowContext: Equatable, Sendable {
    public let date: Date
    public let width: Int
    public let height: Int
    public let counter: UInt64
    /// UTC is deterministic by default. The UI may explicitly supply the user's time zone.
    public let timeZoneIdentifier: String
    public init(date: Date = Date(), width: Int, height: Int, counter: UInt64,
                timeZoneIdentifier: String = "UTC") {
        self.date = date; self.width = width; self.height = height; self.counter = counter
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public struct SaveWorkflowDestination: Equatable, Sendable {
    public let baseURL: URL
    public let relativeDirectories: [String]
    public let filename: String
    public init(baseURL: URL, relativeDirectories: [String], filename: String) {
        self.baseURL = baseURL; self.relativeDirectories = relativeDirectories; self.filename = filename
    }
    public var url: URL {
        relativeDirectories.reduce(baseURL) { $0.appendingPathComponent($1, isDirectory: true) }
            .appendingPathComponent(filename, isDirectory: false)
    }
    public var relativePath: String { (relativeDirectories + [filename]).joined(separator: "/") }
}

public enum SaveWorkflowCollisionBehavior: String, Codable, CaseIterable, Sendable {
    case ask, keepBoth
}

/// Only an explicitly finalized, flattened output is eligible for an automatic copy.
/// Capture acquisition, opening history, previews and editor dismissal are not finalization.
public enum SaveWorkflowTrigger: Sendable {
    case finalizedAction, captureAcquired, historyOpened, previewUpdated, editorCancelled
}

public struct SaveWorkflowSettings: Codable, Equatable, Sendable {
    public static let preferenceKey = "saveWorkflow.v1"
    public var baseURL: URL?
    public var relativeFolderTemplate: String
    /// A filename stem; the actual encoder's extension is appended separately.
    public var filenameTemplate: String
    public var autoOnFinalizedAction: Bool
    public var collisionBehavior: SaveWorkflowCollisionBehavior
    public init(baseURL: URL? = nil, relativeFolderTemplate: String = "",
                filenameTemplate: String = "PicShot-{date}-{time}-{counter}",
                autoOnFinalizedAction: Bool = false, collisionBehavior: SaveWorkflowCollisionBehavior = .ask) {
        self.baseURL = baseURL; self.relativeFolderTemplate = relativeFolderTemplate
        self.filenameTemplate = filenameTemplate; self.autoOnFinalizedAction = autoOnFinalizedAction
        self.collisionBehavior = collisionBehavior
    }
    public func shouldAutomaticallySave(for trigger: SaveWorkflowTrigger) -> Bool {
        guard autoOnFinalizedAction, baseURL != nil else { return false }
        if case .finalizedAction = trigger { return true }; return false
    }
    public func preview(context: SaveWorkflowContext, filenameExtension: String = "png") throws -> SaveWorkflowDestination {
        guard let baseURL else { throw SaveWorkflowValidationError.invalidBaseDirectory }
        try Self.validateBaseURL(baseURL)
        guard filenameExtension.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) != nil else {
            throw SaveWorkflowValidationError.invalidTemplate
        }
        let template = try SaveWorkflowTemplate(folder: relativeFolderTemplate, filename: filenameTemplate)
        let result = try template.render(context: context)
        let filename = result.filename + "." + filenameExtension
        guard baseURL.path.utf8.count + result.directories.joined(separator: "/").utf8.count + filename.utf8.count + 10 <= 1_024 else {
            throw SaveWorkflowValidationError.pathTooLong
        }
        return SaveWorkflowDestination(baseURL: baseURL, relativeDirectories: result.directories, filename: filename)
    }
    public func validate() throws {
        _ = try SaveWorkflowTemplate(folder: relativeFolderTemplate, filename: filenameTemplate)
        if let baseURL { try Self.validateBaseURL(baseURL) }
        if autoOnFinalizedAction && baseURL == nil { throw SaveWorkflowValidationError.invalidBaseDirectory }
    }
    public static func read(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: preferenceKey), data.count <= 16_384,
              let settings = try? JSONDecoder().decode(Self.self, from: data),
              (try? settings.validate()) != nil else { return Self() }
        return settings
    }
    public func save(to defaults: UserDefaults) throws {
        try validate(); defaults.set(try JSONEncoder().encode(self), forKey: Self.preferenceKey)
    }
    public static func validateBaseURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), url.path != "/",
              !url.path.contains("\u{0}"), !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              url.path.utf8.count <= 768, url.pathComponents.count <= 65 else { throw SaveWorkflowValidationError.invalidBaseDirectory }
    }
}

public struct SaveWorkflowTemplate: Equatable, Sendable {
    public let folder: String
    public let filename: String
    private static let variables: Set<String> = ["date", "time", "width", "height", "counter"]
    public init(folder: String = "", filename: String) throws {
        guard folder.utf8.count <= 1_024, filename.utf8.count <= 1_024,
              !filename.isEmpty, !filename.contains("/"), !filename.contains("\\"),
              !folder.contains("\\"), !folder.hasPrefix("/"), !folder.hasSuffix("/"),
              !folder.hasPrefix("~") else { throw SaveWorkflowValidationError.invalidTemplate }
        let components = folder.isEmpty ? [] : folder.components(separatedBy: "/")
        guard components.count <= 8 else { throw SaveWorkflowValidationError.pathTooLong }
        for component in components + [filename] {
            guard !component.isEmpty, component != ".", component != ".." else { throw SaveWorkflowValidationError.invalidTemplate }
            _ = try Self.expand(component, values: Dictionary(uniqueKeysWithValues: Self.variables.map { ($0, "1") }))
            guard !Self.sanitize(component).isEmpty else { throw SaveWorkflowValidationError.invalidTemplate }
        }
        self.folder = folder; self.filename = filename
    }
    public func render(context: SaveWorkflowContext) throws -> (directories: [String], filename: String) {
        guard context.width > 0, context.height > 0, context.width <= 100_000_000 / context.height,
              context.counter > 0, context.date.timeIntervalSinceReferenceDate.isFinite,
              abs(context.date.timeIntervalSince1970) <= 253_402_214_400,
              let zone = TimeZone(identifier: context.timeZoneIdentifier) else { throw SaveWorkflowValidationError.invalidContext }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"; let date = formatter.string(from: context.date)
        formatter.dateFormat = "HH-mm-ss"; let time = formatter.string(from: context.date)
        let values = ["date": date, "time": time, "width": String(context.width), "height": String(context.height), "counter": String(context.counter)]
        func renderComponent(_ value: String) throws -> String {
            let rendered = Self.sanitize(try Self.expand(value, values: values))
            guard !rendered.isEmpty, rendered != ".", rendered != ".." else { throw SaveWorkflowValidationError.invalidTemplate }
            return rendered
        }
        let directories = try (folder.isEmpty ? [] : folder.components(separatedBy: "/")).map(renderComponent)
        return (directories, try renderComponent(filename))
    }
    private static func expand(_ template: String, values: [String: String]) throws -> String {
        var output = "", variable: String?
        for character in template {
            if character == "{" {
                guard variable == nil else { throw SaveWorkflowValidationError.invalidTemplate }; variable = ""
            } else if character == "}" {
                guard let name = variable else { throw SaveWorkflowValidationError.invalidTemplate }
                guard let value = values[name] else { throw SaveWorkflowValidationError.unknownVariable(name) }
                output += value; variable = nil
            } else if variable != nil { variable!.append(character) }
            else { output.append(character) }
        }
        guard variable == nil else { throw SaveWorkflowValidationError.invalidTemplate }; return output
    }
    /// Preserve Unicode graphemes, but strip invisible controls/bidi overrides and replace
    /// Finder/path-reserved punctuation. Byte bounding leaves room for collision suffixes.
    private static func sanitize(_ value: String) -> String {
        let safe = value.unicodeScalars.map { scalar -> String in
            if (scalar.value < 32 || (127...159).contains(scalar.value)) || [0x200B, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains(Int(scalar.value)) { return "_" }
            return ":\\?*\"<>|".unicodeScalars.contains(scalar) ? "_" : String(scalar)
        }.joined().precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for character in safe {
            let next = String(character)
            if result.utf8.count + next.utf8.count > 180 { break }; result += next
        }
        while result.hasSuffix(".") || result.hasSuffix(" ") { result.removeLast() }
        if result.hasPrefix(".") { result = "_" + String(result.dropFirst()) }
        return result
    }
}

/// Reserves a monotonic name before beginning a job. Cancellation intentionally leaves a gap.
/// Store decimal text rather than a signed/defaults integer so UInt64 boundaries are exact.
public enum SaveWorkflowCounter {
    private static let lock = NSLock()
    public static let preferenceKey = "saveWorkflow.nextCounter.v1"
    public static func next(in defaults: UserDefaults) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let saved = defaults.string(forKey: preferenceKey)
        guard saved == nil || UInt64(saved!) != nil else { throw SaveWorkflowValidationError.counterExhausted }
        let current = saved.flatMap(UInt64.init) ?? 1
        guard current > 0, current < UInt64.max else { throw SaveWorkflowValidationError.counterExhausted }
        defaults.set(String(current + 1), forKey: preferenceKey); return current
    }
}
