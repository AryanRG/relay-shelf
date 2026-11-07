import Foundation

// swiftc -swift-version 5 native/PathResolver.swift tests/PathResolverTests.swift -o /tmp/PathResolverTests
@main
struct PathResolverTests {
    private static var assertions = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1
        precondition(condition(), "\(file):\(line): \(message)")
    }

    private static func only(_ rows: [[String: Any]], _ message: String = "Expected one result") -> [String: Any] {
        expect(rows.count == 1, "\(message); received \(rows)")
        return rows[0]
    }

    private static func checkSchema(_ row: [String: Any]) {
        let required: Set<String> = ["input", "path", "name", "exists", "kind", "size", "modifiedAt", "extension"]
        expect(required.isSubset(of: Set(row.keys)), "Required ResolvedPath keys")
        expect(Set(row.keys).isSubset(of: required.union(["line", "error"])), "No additional keys")
        for key in ["input", "path", "name", "kind", "modifiedAt", "extension"] {
            expect(row[key] is String, "\(key) is a String")
        }
        expect(row["exists"] is Bool, "exists is Bool")
        expect(row["size"] is Int64, "size is Int64")
        expect(["file", "folder"].contains(row["kind"] as? String ?? ""), "Valid kind")
        expect(ISO8601DateFormatter().date(from: row["modifiedAt"] as? String ?? "") != nil, "ISO8601 timestamp")
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("RelayShelf-PathResolver-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        func file(_ name: String, contents: String = "fixture") throws -> URL {
            let url = root.appendingPathComponent(name)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            return url.standardizedFileURL
        }
        func resolve(_ text: String, base: String? = nil) -> [[String: Any]] {
            PathResolver.resolve(text, basePath: base ?? root.path)
        }
        func matches(_ text: String, _ url: URL, line: Int? = nil) {
            let row = only(resolve(text), "Resolve \(text)")
            expect(row["path"] as? String == url.path, "Resolved path for \(text)")
            expect(row["exists"] as? Bool == true, "Existing path for \(text)")
            expect(row["line"] as? Int == line, "Line for \(text)")
            expect(row["error"] == nil, "No error for \(text)")
        }

        let source = try file("src/Example.SWIFT", contents: "hello")
        let space = try file("folder with spaces/a file.txt")
        let parentheses = try file("folder with spaces/report (final (v2)).md")
        let unicode = try file("資料/naïve 🦊.TXT")
        let encoded = try file("encoded # percent% plus+.TXT")
        let plain = try file("README")
        let punctuation = try file("src/literal.swift,")
        let colonDirectory = try file("folder:/literal.txt")

        let row = only(PathResolver.resolve(source.path))
        checkSchema(row)
        expect(row["input"] as? String == source.path, "Original input")
        expect(row["name"] as? String == "Example.SWIFT", "Basename")
        expect(row["size"] as? Int64 == 5, "File byte size")
        expect(row["extension"] as? String == "swift", "Lowercase extension")
        expect(row["kind"] as? String == "file", "File kind")

        for path in [space, parentheses, unicode] {
            matches(path.path, path)
            for quote in ["\"", "'", "`", "```"] {
                matches(" \t\(quote)\(path.path)\(quote)  ", path)
            }
        }
        matches("src/Example.SWIFT", source)
        matches("./src/../src/Example.SWIFT", source)
        matches("folder with spaces/a file.txt", space)
        matches("README", plain)
        matches(source.path, source)
        matches(colonDirectory.path.replacingOccurrences(of: "folder:/", with: "folder://"), colonDirectory)
        expect(PathResolver.resolve("src/Example.SWIFT").isEmpty, "No implicit cwd for relative paths")
        expect(PathResolver.resolve("README").isEmpty, "No implicit cwd even for bare names")
        expect(PathResolver.resolve("./missing.txt", basePath: "relative/base").isEmpty, "Base must be absolute")
        expect(PathResolver.resolve("./missing.txt", basePath: "ssh://host/project").isEmpty, "No remote base mapping")

        let colon = try file("report:12")
        let colonColumn = try file("report:12:4")
        let hash = try file("report#L12")
        _ = try file("report")
        let quotedName = try file("\"literal name.txt\"")
        matches(colon.path, colon)
        matches(colonColumn.path, colonColumn)
        matches(hash.path, hash)
        matches("'\(colon.path)'", colon)
        matches(quotedName.path, quotedName)
        matches("\(source.path):23", source, line: 23)
        matches("\(source.path):23:8", source, line: 23)
        matches("\(space.path):3:14", space, line: 3)
        matches("\(unicode.path)#L9", unicode, line: 9)
        matches("`\(source.path):23:8`", source, line: 23)
        matches("src/Example.SWIFT#L11", source, line: 11)
        // A suffix-bearing filename inside quotes wins over parsing the outer spelling.
        matches("\"\(colonColumn.path)\"", colonColumn)
        expect(only(resolve(source.path + ":0"))["line"] == nil, "Zero is not a line anchor")
        expect(only(resolve(source.path + ":999999999999999999999999"))["line"] == nil, "Overflowing line is literal")

        matches("[source](\(source.path))", source)
        matches("[source](src/Example.SWIFT:7:2)", source, line: 7)
        matches("[report](\(parentheses.path))", parentheses)
        let escapedMarkdown = parentheses.path.replacingOccurrences(of: "(", with: #"\("#).replacingOccurrences(of: ")", with: #"\)"#)
        matches("[report](\(escapedMarkdown))", parentheses)
        matches("[report](<\(parentheses.path)>)", parentheses)
        matches("[unicode](\(unicode.path))", unicode)
        let markdownName = try file("[literal](report).txt")
        matches(markdownName.path, markdownName)
        let mixed = resolve("Changed [source](src/Example.SWIFT:12) and `\(space.path)`.")
        expect(mixed.count == 2, "Markdown and quoted prose references")
        expect(mixed[0]["line"] as? Int == 12, "Markdown line metadata")
        expect(mixed[1]["path"] as? String == space.path, "Quoted prose spaces")

        matches("Updated \(source.path):18:2, successfully.", source, line: 18)
        matches("Changed `src/Example.SWIFT:4` in this patch.", source, line: 4)
        matches("Updated \"\(space.path)\" successfully.", space)
        matches("I've updated '\(space.path)' successfully.", space)
        matches("Updated \(punctuation.path) successfully.", punctuation)
        matches("Inspect (\(source.path):6).", source, line: 6)
        let basename = try file("bare.swift")
        matches("Updated bare.swift, successfully.", basename)
        let ordered = resolve("Changed `\(space.path)` and [source](src/Example.SWIFT).")
        expect(ordered.compactMap { $0["path"] as? String } == [space.path, source.path], "Prose references retain source order")
        let firstAnchor = only(resolve("Changed `src/Example.SWIFT:5` and [again](src/Example.SWIFT:9)."))
        expect(firstAnchor["line"] as? Int == 5, "Deduplication retains earliest prose occurrence")

        matches(encoded.absoluteString, encoded)
        matches(unicode.absoluteString, unicode)
        matches("[encoded](\(encoded.absoluteString))", encoded)
        matches(source.absoluteString + "#L8", source, line: 8)
        matches(source.absoluteString + ":9:2", source, line: 9)
        matches("file://localhost" + source.path, source)
        matches(hash.absoluteString, hash)
        matches("file://" + hash.path, hash)
        for remote in ["https://example.com/file.txt", "ssh://host/project/file.swift", "file://remote-host" + source.path, "//remote-host/share/file.txt", #"C:\Users\someone\file.txt"#, "C:/Users/someone/file.txt"] {
            expect(resolve(remote).isEmpty, "No remote mapping: \(remote)")
        }

        let home = only(PathResolver.resolve("~"))
        expect(home["path"] as? String == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path, "Tilde home expansion")
        expect(home["kind"] as? String == "folder", "Home is a folder")
        let missingHome = only(PathResolver.resolve("~/RelayShelf-missing-\(UUID().uuidString)/file.txt"))
        expect((missingHome["path"] as? String)?.hasPrefix(NSHomeDirectory() + "/") == true, "Tilde prefix expansion")
        expect(missingHome["error"] is String, "Missing tilde path reports error")

        let multiline = resolve(" \(source.path)\r\n\"\(space.path)\"\n\n[unicode](\(unicode.path))\r\(parentheses.path)")
        expect(multiline.count == 4, "CRLF, LF, and CR multiline paths")
        expect(multiline.compactMap { $0["path"] as? String } == [source.path, space.path, unicode.path, parentheses.path], "Input ordering")
        let duplicates = resolve("\(source.path):4\n./src/Example.SWIFT\n\(source.absoluteString)\nsrc/../src/Example.SWIFT#L6")
        expect(duplicates.count == 1, "Deduplicate normalized paths and URL spellings")
        expect(duplicates[0]["line"] as? Int == 4, "First occurrence retains metadata")

        for text in ["", " \n\t", "Hello, this is ordinary clipboard text.", "Please fix the failing tests tomorrow", "I use Swift 5.0", "Contact me at person@example.com", "`ordinary text`", "[website](https://example.com/file.txt)"] {
            expect(resolve(text).isEmpty, "Ordinary text stays text: \(text)")
        }
        let missing = only(resolve("missing/does-not-exist.txt:42:7"))
        checkSchema(missing)
        expect(missing["exists"] as? Bool == false, "Missing path exists=false")
        expect(missing["error"] is String, "Missing path error")
        expect(missing["size"] as? Int64 == 0, "Missing path size")
        expect(missing["path"] as? String == root.appendingPathComponent("missing/does-not-exist.txt").path, "Missing relative uses base")
        expect(missing["line"] as? Int == 42, "Missing anchored path line")
        expect(only(resolve("not-here.txt"))["error"] is String, "Plausible missing basename")
        expect(only(resolve("\"missing file name.txt\""))["error"] is String, "Quoted missing relative basename with spaces")
        expect(only(resolve("See [missing](missing folder/no file.txt)."))["error"] is String, "Markdown missing relative path with spaces")
        expect(only(resolve(root.appendingPathComponent("missing with spaces.txt").path))["error"] is String, "Missing absolute spaces")

        let sentinel = root.appendingPathComponent("SHELL_MUST_NOT_EXECUTE")
        let shellName = "literal $(touch \(sentinel.path)); `whoami` & 'quoted'.txt"
        let shellFile = try file(shellName)
        matches(shellFile.path, shellFile)
        matches("\"\(shellFile.path)\"", shellFile)
        let shellMissing = root.appendingPathComponent("missing $(touch \(sentinel.path)); echo pwned.txt").path
        let shellRow = only(resolve(shellMissing))
        expect(shellRow["path"] as? String == shellMissing, "Missing shell payload is literal")
        expect(!manager.fileExists(atPath: sentinel.path), "No shell payload executed")

        let link = root.appendingPathComponent("source-link.swift")
        try manager.createSymbolicLink(at: link, withDestinationURL: source)
        matches(link.path, link)
        let linkRow = only(resolve(link.path))
        expect(linkRow["size"] as? Int64 == 5, "File symlink target metadata")
        let folderLink = root.appendingPathComponent("folder-link")
        try manager.createSymbolicLink(at: folderLink, withDestinationURL: space.deletingLastPathComponent())
        let folder = only(resolve(folderLink.path))
        checkSchema(folder)
        expect(folder["kind"] as? String == "folder", "Directory symlink target kind")
        expect(folder["path"] as? String == folderLink.path, "Preserve symlink reference")
        let broken = root.appendingPathComponent("broken-link.txt")
        try manager.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("no-target"))
        expect(only(resolve(broken.path))["error"] is String, "Broken symlink error")
        expect(resolve(root.path).count == 1, "Folder resolution does not enumerate descendants")

        let described = PathResolver.describe(source, input: "original reference", line: 17)
        checkSchema(described)
        expect(described["input"] as? String == "original reference", "describe input override")
        expect(described["line"] as? Int == 17, "describe line override")
        expect(PathResolver.describe(source)["input"] as? String == source.path, "describe default input")
        expect(PathResolver.describe(source, line: -1)["line"] == nil, "describe rejects nonpositive line")
        expect(PathResolver.describe(URL(string: "https://example.com/file.txt")!)["error"] is String, "describe rejects non-file URL")

        let many = (0..<140).map { root.appendingPathComponent("missing-\($0).txt").path }.joined(separator: "\n")
        expect(resolve(many).count == 100, "At most 100 candidates")
        let manyLinks = (0..<140).map { "[item](missing-\($0).txt)" }.joined(separator: " ")
        expect(resolve(manyLinks).count == 100, "Markdown candidate bound")
        let limitedMixed = resolve("`src/Example.SWIFT:10` " + manyLinks)
        expect(limitedMixed.count == 100, "Mixed prose candidate bound")
        expect(limitedMixed[0]["path"] as? String == source.path, "Earlier quote survives Markdown candidate limit")
        expect(resolve(String(repeating: "x", count: 256 * 1024 + 1)).isEmpty, "Reject oversized UTF8 input")
        expect(resolve(String(repeating: "🦊", count: 65537)).isEmpty, "Byte limit, not character limit")
        let boundary = source.path + String(repeating: " ", count: 256 * 1024 - source.path.utf8.count)
        matches(boundary, source)
        expect(resolve(String(repeating: "[", count: 256 * 1024)).isEmpty, "Malformed Markdown remains bounded")
        expect(resolve(String(repeating: "`", count: 256 * 1024)).isEmpty, "Repeated wrappers remain bounded")
        expect(resolve("file:///tmp/invalid%00name.txt").isEmpty, "Reject encoded NUL")
        expect(resolve("/tmp/invalid\0name.txt").isEmpty, "Reject literal NUL")

        print("PathResolverTests passed (\(assertions) assertions)")
    }
}
