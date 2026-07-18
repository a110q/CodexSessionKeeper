import Foundation

public struct ConversationLogMessage: Identifiable, Hashable, Sendable {
    public let id: String
    public let role: String
    public let phase: String?
    public let timestamp: Date?
    public let text: String

    public init(
        id: String,
        role: String,
        phase: String?,
        timestamp: Date?,
        text: String
    ) {
        self.id = id
        self.role = role
        self.phase = phase
        self.timestamp = timestamp
        self.text = text
    }
}

public enum ConversationLogParser {
    public static func loadMessages(from trusted: TrustedSessionFile) throws -> [ConversationLogMessage] {
        try Task.checkCancellation()
        var eventMessages: [ConversationLogMessage] = []
        var responseMessages: [ConversationLogMessage] = []
        eventMessages.reserveCapacity(256)
        responseMessages.reserveCapacity(128)
        let timestamps = TimestampParser()

        let result = try SessionJSONLScanner.scan(trusted.fileURL) { lineNumber, _, object in
            try Task.checkCancellation()
            if let message = eventMessage(
                from: object,
                lineNumber: lineNumber,
                timestamps: timestamps
            ) {
                eventMessages.append(message)
                return
            }

            if eventMessages.isEmpty,
               let message = responseMessage(
                   from: object,
                   lineNumber: lineNumber,
                   timestamps: timestamps
               ) {
                responseMessages.append(message)
            }
        }
        guard result.fingerprint == trusted.fingerprint else {
            throw SessionJSONLValidationError(
                fileURL: trusted.fileURL,
                lineNumber: 1,
                reason: "文件在会话预检后发生变化"
            )
        }

        return eventMessages.isEmpty ? responseMessages : eventMessages
    }

    private static func eventMessage(
        from object: [String: Any],
        lineNumber: Int,
        timestamps: TimestampParser
    ) -> ConversationLogMessage? {
        guard object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let eventType = payload["type"] as? String else {
            return nil
        }

        let role: String
        switch eventType {
        case "user_message": role = "用户"
        case "agent_message": role = "助手"
        default: return nil
        }
        let text = cleanText(
            payload["message"] as? String ?? extractText(from: payload["content"])
        )
        guard !text.isEmpty else { return nil }

        return ConversationLogMessage(
            id: "event-\(lineNumber)",
            role: role,
            phase: payload["phase"] as? String,
            timestamp: timestamps.parse(object["timestamp"] as? String),
            text: text
        )
    }

    private static func responseMessage(
        from object: [String: Any],
        lineNumber: Int,
        timestamps: TimestampParser
    ) -> ConversationLogMessage? {
        guard object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              let rawRole = payload["role"] as? String,
              rawRole == "user" || rawRole == "assistant" else {
            return nil
        }
        let text = cleanText(extractText(from: payload["content"]))
        guard !text.isEmpty else { return nil }

        return ConversationLogMessage(
            id: "response-\(lineNumber)",
            role: rawRole == "user" ? "用户" : "助手",
            phase: payload["phase"] as? String,
            timestamp: timestamps.parse(object["timestamp"] as? String),
            text: text
        )
    }

    private static func extractText(from value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        if let values = value as? [Any] {
            return values
                .map(extractText)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }
        if let object = value as? [String: Any] {
            for key in ["text", "message", "content", "input", "output"] {
                let text = extractText(from: object[key])
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return ""
    }

    private static func cleanText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class TimestampParser {
    private let fractional: ISO8601DateFormatter
    private let standard: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        standard = ISO8601DateFormatter()
    }

    func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractional.date(from: value) ?? standard.date(from: value)
    }
}
