import Foundation
import CodeIslandCore

struct CodexPermissionRules {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    static func isCodexEvent(_ event: HookEvent) -> Bool {
        SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) == "codex"
    }

    static func prefixPattern(for event: HookEvent) -> [String]? {
        if let suggested = findSuggestedPrefixRule(in: event.rawJSON) {
            return suggested
        }

        guard event.toolName == "Bash",
              let command = event.toolInput?["command"] as? String else {
            return nil
        }

        return shellPrefix(from: command, maxTokens: 3)
    }

    @discardableResult
    func persistAlwaysAllowRule(for event: HookEvent) -> Bool {
        guard let pattern = Self.prefixPattern(for: event), !pattern.isEmpty else {
            return false
        }

        let rulesDirectory = ConfigInstaller.codexHome() + "/rules"
        let rulesPath = rulesDirectory + "/codeisland.rules"
        let block = Self.ruleBlock(for: pattern)
        let patternLine = Self.patternLine(for: pattern)

        do {
            try fileManager.createDirectory(atPath: rulesDirectory, withIntermediateDirectories: true)

            let existing = (try? String(contentsOfFile: rulesPath, encoding: .utf8)) ?? ""
            if existing.contains(patternLine), existing.contains(#"decision = "allow""#) {
                return true
            }

            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            let updated = existing + separator + block
            try updated.write(toFile: rulesPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func patternLine(for pattern: [String]) -> String {
        "pattern = [\(pattern.map(quotedRuleString).joined(separator: ", "))]"
    }

    private static func ruleBlock(for pattern: [String]) -> String {
        """
        # Added by CodeIsland when "Always Allow" is clicked for Codex.
        prefix_rule(
            \(patternLine(for: pattern)),
            decision = "allow",
            justification = "Allowed from CodeIsland Always Allow",
        )

        """
    }

    private static func quotedRuleString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func findSuggestedPrefixRule(in value: Any) -> [String]? {
        if let dictionary = value as? [String: Any] {
            for key in ["prefix_rule", "prefixRule"] {
                if let pattern = stringArray(from: dictionary[key]) {
                    return pattern
                }
            }

            for nested in dictionary.values {
                if let pattern = findSuggestedPrefixRule(in: nested) {
                    return pattern
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let pattern = findSuggestedPrefixRule(in: nested) {
                    return pattern
                }
            }
        }
        return nil
    }

    private static func stringArray(from value: Any?) -> [String]? {
        if let pattern = value as? [String], !pattern.isEmpty {
            return pattern
        }
        if let dictionary = value as? [String: Any],
           let pattern = dictionary["pattern"] as? [String],
           !pattern.isEmpty {
            return pattern
        }
        return nil
    }

    private static func shellPrefix(from command: String, maxTokens: Int) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var index = command.startIndex

        func appendCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current = ""
        }

        while index < command.endIndex {
            let char = command[index]
            let next = command.index(after: index)

            if escaping {
                current.append(char)
                escaping = false
                index = next
                continue
            }

            if char == "\\" {
                escaping = true
                index = next
                continue
            }

            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                index = next
                continue
            }

            if char == "'" || char == "\"" {
                quote = char
                index = next
                continue
            }

            if char == "$", next < command.endIndex, command[next] == "(" {
                appendCurrentToken()
                break
            }

            if char == "\n" || char == "|" || char == ";" || char == "<" || char == ">" || char == "&" {
                appendCurrentToken()
                break
            }

            if char.isWhitespace {
                appendCurrentToken()
                if tokens.count >= maxTokens {
                    break
                }
            } else {
                current.append(char)
            }

            index = next
        }

        appendCurrentToken()

        let prefix = Array(tokens.prefix(maxTokens))
        guard !prefix.isEmpty, !looksLikeEnvironmentAssignment(prefix[0]) else {
            return nil
        }
        return prefix
    }

    private static func looksLikeEnvironmentAssignment(_ token: String) -> Bool {
        guard let equalsIndex = token.firstIndex(of: "="), equalsIndex != token.startIndex else {
            return false
        }
        let name = token[..<equalsIndex]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
