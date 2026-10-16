import Foundation

/// Hands the tab progress bar over between Claude Eyes and Claude Code through ~/.claude/settings.json:
/// Claude Code's own bar is off while ours is on (both would fight over the same tab), and when ours is
/// turned off the key is removed, so Claude Code falls back to its own setting (on by default).
enum ClaudeSettings {
    static let progressBarKey = "terminalProgressBarEnabled"

    static func syncProgressBar(oursEnabled: Bool) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath()
        // Only once the hook is installed: without it, Claude Code's bar is the only one
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("claude-state.sh") else { return }
        let updated = oursEnabled
            ? SettingsText.setting(text, key: progressBarKey, to: false)
            : SettingsText.removing(text, key: progressBarKey, ifEqualTo: false)
        guard let updated, updated != text else { return }

        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        guard (try? updated.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }
}

/// Minimal text edits of a JSON object, so the user's formatting and key order are kept.
/// A result is returned only once parsed back and saying exactly what was asked.
enum SettingsText {
    static func setting(_ text: String, key: String, to value: Bool) -> String? {
        let existing = try! NSRegularExpression(pattern: "(\"\(key)\"\\s*:\\s*)(true|false)")
        let whole = NSRange(text.startIndex..., in: text)
        var result: String
        if existing.firstMatch(in: text, range: whole) != nil {
            result = existing.stringByReplacingMatches(in: text, range: whole, withTemplate: "$1\(value)")
        } else {
            guard let brace = text.firstIndex(of: "{") else { return nil }
            let rest = text[text.index(after: brace)...]
            let isEmpty = rest.trimmingCharacters(in: .whitespacesAndNewlines) == "}"
            result = isEmpty
                ? "{\n  \"\(key)\": \(value)\n}\n"
                : text.replacingCharacters(in: brace...brace, with: "{\n  \"\(key)\": \(value),")
        }
        return object(result)?[key] as? Bool == value ? result : nil
    }

    static func removing(_ text: String, key: String, ifEqualTo value: Bool) -> String? {
        guard let current = object(text)?[key] as? Bool, current == value else { return nil }
        let quotedKey = NSRegularExpression.escapedPattern(for: "\"\(key)\"")
        let candidates = [
            "\\n[ \\t]*\(quotedKey)\\s*:\\s*\(value)\\s*,",   // its own line, followed by another key
            "\(quotedKey)\\s*:\\s*\(value)\\s*,\\s*",          // inline, followed by another key
            ",\\s*\(quotedKey)\\s*:\\s*\(value)(?=\\s*\\})",   // last key
            "\\s*\(quotedKey)\\s*:\\s*\(value)(?=\\s*\\})",    // only key
        ]
        for pattern in candidates {
            let regex = try! NSRegularExpression(pattern: pattern)
            let whole = NSRange(text.startIndex..., in: text)
            guard regex.firstMatch(in: text, range: whole) != nil else { continue }
            let result = regex.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
            if let parsed = object(result), parsed[key] == nil { return result }
        }
        return nil
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
