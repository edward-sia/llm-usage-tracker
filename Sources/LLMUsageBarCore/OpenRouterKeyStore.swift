import Foundation

/// Reads the OpenRouter API key from shell config files. Read-only: never writes.
public struct OpenRouterKeyStore {
    public static let variableName = "OPENROUTER_API_KEY"

    /// Checked in order; the first file containing a usable assignment wins.
    public static let defaultFiles: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zshrc", ".zshenv", ".zprofile", ".bashrc", ".bash_profile", ".profile"]
            .map { home.appendingPathComponent($0) }
    }()

    private let files: [URL]

    public init(files: [URL] = OpenRouterKeyStore.defaultFiles) {
        self.files = files
    }

    /// Returns the API key or throws `UsageError.notSignedIn`.
    public func apiKey() throws -> String {
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let contents = String(data: data, encoding: .utf8),
                  let key = Self.parseKey(fromFileContents: contents) else { continue }
            return key
        }
        throw UsageError.notSignedIn
    }

    /// Extracts the key from one file's contents, or nil if no line assigns it.
    /// Mirrors shell semantics within the file: the last assignment wins.
    public static func parseKey(fromFileContents contents: String) -> String? {
        var key: String?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            if let parsed = parseKey(fromLine: line.trimmingCharacters(in: .whitespaces)) {
                key = parsed
            }
        }
        return key
    }

    /// One line: optional `export`, the exact variable name, `=`, then a bare or quoted value.
    /// Values containing `$` are shell references this app cannot resolve, so they are skipped.
    private static func parseKey(fromLine line: String) -> String? {
        var rest = line
        if rest.hasPrefix("export ") {
            rest = String(rest.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
        }
        guard rest.hasPrefix("\(variableName)=") else { return nil }
        rest = String(rest.dropFirst(variableName.count + 1))

        let value: String
        if let quote = rest.first, quote == "\"" || quote == "'" {
            let body = rest.dropFirst()
            guard let close = body.firstIndex(of: quote) else { return nil }
            value = String(body[..<close])
        } else {
            value = String(rest.prefix { !$0.isWhitespace && $0 != "#" })
        }
        guard !value.isEmpty, !value.contains("$") else { return nil }
        return value
    }
}
