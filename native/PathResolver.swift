import Foundation
import Darwin

/// Resolves local filesystem references without invoking a shell or searching directories.
enum PathResolver {
    private static let inputLimit = 256 * 1024
    private static let candidateLimit = 100

    private struct Candidate {
        var text: String
        var input: String
        var prose = false
        var offset = 0
    }

    static func resolve(_ text: String, basePath: String = "") -> [[String: Any]] {
        // Reject oversized clipboard data as text instead of interpreting a truncated path.
        guard text.utf8.prefix(inputLimit + 1).count <= inputLimit else { return [] }
        let base = localPath(basePath).flatMap { path -> String? in
            guard (path as NSString).isAbsolutePath else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        var results = [[String: Any]]()
        var seen = Set<String>()
        var attempts = 0
        for line in text.components(separatedBy: .newlines) {
            guard attempts < candidateLimit else { break }
            let raw = trim(line)
            guard !raw.isEmpty else { continue }
            // An entire existing filename wins even if it looks like prose or Markdown.
            if let row = resolved(Candidate(text: raw, input: raw), base: base, existingOnly: true) {
                attempts += 1
                if let path = row["path"] as? String, seen.insert(path).inserted { results.append(row) }
                continue
            }
            for candidate in extract(raw, limit: candidateLimit - attempts) {
                guard attempts < candidateLimit else { break }
                attempts += 1
                guard let row = resolved(candidate, base: base, existingOnly: false),
                      let path = row["path"] as? String, seen.insert(path).inserted else { continue }
                results.append(row)
            }
        }
        return results
    }

    static func describe(_ url: URL, input: String? = nil, line: Int? = nil) -> [String: Any] {
        let local = url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
        let normalized = local ? url.standardizedFileURL : url
        let path = normalized.path
        var row: [String: Any] = [
            "input": input ?? path, "path": path, "name": normalized.lastPathComponent,
            "exists": false, "kind": "file", "size": Int64(0),
            "modifiedAt": timestamp(Date(timeIntervalSince1970: 0)),
            "extension": normalized.pathExtension.lowercased()
        ]
        if let line = line, line > 0 { row["line"] = line }
        guard local else {
            row["error"] = "Only local file URLs are supported."
            return row
        }
        var directory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        row["exists"] = exists
        row["kind"] = directory.boolValue ? "folder" : "file"
        guard exists else {
            row["error"] = "Path does not exist."
            return row
        }
        // POSIX stat follows symlinks and avoids fetching Finder/iCloud extended attributes.
        var info = stat()
        if path.withCString({ Darwin.fstatat(AT_FDCWD, $0, &info, 0) }) == 0 {
            row["size"] = Int64(info.st_size)
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            row["modifiedAt"] = timestamp(Date(timeIntervalSince1970: modified))
        } else { row["error"] = String(cString: strerror(errno)) }
        return row
    }

    private static func timestamp(_ date: Date) -> String {
        date.ISO8601Format()
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unwrapped(_ text: String) -> [String] {
        var versions = [trim(text)]
        while versions.count < 8, let value = versions.last, value.count >= 2,
              let first = value.first, let last = value.last,
              (first == last && ["\"", "'", "`"].contains(first)) || (first == "<" && last == ">") {
            let next = trim(String(value.dropFirst().dropLast()))
            guard !next.isEmpty else { break }
            versions.append(next)
        }
        return versions
    }

    private static func localPath(_ text: String) -> String? {
        guard !text.isEmpty, !text.contains("\0") else { return nil }
        if text.lowercased().hasPrefix("file://") {
            guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "file",
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost",
                  var path = parts.percentEncodedPath.removingPercentEncoding,
                  path.hasPrefix("/") else { return nil }
            // Check literal '?' and '#' filenames before treating a suffix as an anchor.
            if let query = parts.percentEncodedQuery?.removingPercentEncoding { path += "?" + query }
            if let fragment = parts.percentEncodedFragment?.removingPercentEncoding { path += "#" + fragment }
            guard !path.contains("\0") else { return nil }
            return path
        }
        // Do not turn remote URLs or network shares into local paths.
        guard !hasURLScheme(text), !text.hasPrefix("//"), !text.hasPrefix("\\\\") else { return nil }
        guard text.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) == nil else { return nil }
        if text == "~" || text.hasPrefix("~/") { return (text as NSString).expandingTildeInPath }
        guard !text.hasPrefix("~") else { return nil }
        return text
    }

    private static func url(_ text: String, base: String?) -> URL? {
        guard let path = localPath(text) else { return nil }
        if (path as NSString).isAbsolutePath { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let base = base else { return nil }
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(path).standardizedFileURL
    }

    private static func anchor(_ text: String) -> (String, Int?) {
        let pattern = #"(?::([1-9][0-9]*)(?::[0-9]+)?|#L([1-9][0-9]*))$"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return (text, nil) }
        let suffix = String(text[range])
        let number = suffix.hasPrefix("#L") ? String(suffix.dropFirst(2)) : String(suffix.dropFirst().split(separator: ":")[0])
        guard let line = Int(number) else { return (text, nil) }
        return (String(text[..<range.lowerBound]), line)
    }

    private static func resolved(_ candidate: Candidate, base: String?, existingOnly: Bool) -> [String: Any]? {
        var versions = unwrapped(candidate.text)
        if candidate.prose, let value = versions.last {
            let cleaned = prosePath(value)
            if !cleaned.isEmpty && cleaned != versions.last { versions += unwrapped(cleaned) }
        }
        // Test *all* literal variants before parsing any line suffix.
        for value in versions {
            if let location = url(value, base: base), FileManager.default.fileExists(atPath: location.path) {
                return describe(location, input: candidate.input)
            }
        }
        guard let value = versions.last else { return nil }
        let (path, line) = anchor(value)
        guard let location = url(path, base: base) else { return nil }
        if existingOnly && (line == nil || !FileManager.default.fileExists(atPath: location.path)) { return nil }
        return describe(location, input: candidate.input, line: line)
    }

    private static func prosePath(_ text: String) -> String {
        var value = text[...]
        while let first = value.first, "([{“".contains(first) { value = value.dropFirst() }
        while let last = value.last, ",;.!?)]}”".contains(last) { value = value.dropLast() }
        return String(value)
    }

    private static func hasURLScheme(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
    }

    private static func plausible(_ text: String, allowSpaces: Bool = false) -> Bool {
        let versions = unwrapped(text)
        let value = versions.last ?? text
        guard !value.isEmpty, !hasURLScheme(value) || value.lowercased().hasPrefix("file://") else { return false }
        if value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("./") || value.hasPrefix("../") || value == "~" { return true }
        guard allowSpaces || versions.count > 1 || !value.contains(where: { $0.isWhitespace }) else { return false }
        let path = anchor(value).0
        if path.contains("/") { return true }
        // Bare filenames such as README.md are useful; ordinary words and sentence dots are not paths.
        guard Double(path) == nil, !path.contains("@") else { return false }
        let ext = (path as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 32 && ext.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private static func extract(_ text: String, limit: Int) -> [Candidate] {
        var characters = Array(text)
        var candidates = [Candidate]()
        var hadMarkdown = false
        func record(_ candidate: Candidate) {
            // Keep the earliest candidates even though markup and quotes are recognized in separate passes.
            if candidates.count == limit {
                guard let last = candidates.last, candidate.offset < last.offset else { return }
                candidates.removeLast()
            }
            candidates.append(candidate)
            candidates.sort { $0.offset < $1.offset }
        }
        var index = 0
        // Balanced Markdown destinations allow spaces and nested filename parentheses.
        while index < characters.count && candidates.count < limit {
            guard characters[index] == "[" else { index += 1; continue }
            var endLabel = index + 1
            while endLabel < characters.count && characters[endLabel] != "]" { endLabel += 1 }
            guard endLabel < characters.count else { break }
            guard endLabel + 1 < characters.count, characters[endLabel + 1] == "(" else { index = endLabel + 1; continue }
            let start = endLabel + 2
            var end = start
            var depth = 1
            while end < characters.count {
                if characters[end] == "\\", end + 1 < characters.count { end += 2; continue }
                if characters[end] == "(" { depth += 1 }
                if characters[end] == ")" { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            guard depth == 0 else { break }
            hadMarkdown = true
            let destination = String(characters[start..<end])
                .replacingOccurrences(of: #"\("#, with: "(")
                .replacingOccurrences(of: #"\)"#, with: ")")
            if plausible(destination, allowSpaces: true) {
                record(Candidate(text: destination, input: String(characters[index...end]), offset: index))
            }
            for position in index...end { characters[position] = " " }
            index = end + 1
        }
        // A standalone path may contain arbitrary spaces or shell metacharacters.
        if candidates.isEmpty && !hadMarkdown && plausible(text) {
            return [Candidate(text: text, input: text)]
        }
        index = 0
        while index < characters.count && (candidates.count < limit || index < candidates.last!.offset) {
            let quote = characters[index]
            guard quote == "\"" || quote == "'" || quote == "`" else { index += 1; continue }
            // Apostrophes in prose words ("I've") are not opening path quotes.
            if index > 0 && (characters[index - 1].isLetter || characters[index - 1].isNumber) { index += 1; continue }
            var end = index + 1
            while end < characters.count && characters[end] != quote { end += 1 }
            guard end < characters.count else { index += 1; continue }
            let value = String(characters[(index + 1)..<end])
            if plausible(value, allowSpaces: true) { record(Candidate(text: value, input: String(characters[index...end]), offset: index)) }
            for position in index...end { characters[position] = " " }
            index = end + 1
        }
        index = 0
        while index < characters.count && (candidates.count < limit || index < candidates.last!.offset) {
            if characters[index].isWhitespace { index += 1; continue }
            let start = index
            while index < characters.count && !characters[index].isWhitespace { index += 1 }
            let value = String(characters[start..<index])
            guard plausible(value) || plausible(prosePath(value)) else { continue }
            record(Candidate(text: value, input: value, prose: true, offset: start))
        }
        return candidates
    }
}
