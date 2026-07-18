import Foundation

public enum SessionIdentity {
    public static func sessionID(from fileURL: URL) -> String? {
        guard fileURL.pathExtension.lowercased() == "jsonl" else {
            return nil
        }

        let filename = fileURL.lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
            if let match = regex.firstMatch(in: filename, range: range),
               let idRange = Range(match.range, in: filename) {
                return String(filename[idRange]).lowercased()
            }
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? nil : stem
    }

    public static func title(fromJSONLine line: String) -> String? {
        guard let data = line.data(using: .utf8) else { return nil }
        return title(fromJSONData: data)
    }

    static func title(fromJSONData data: Data) -> String? {
        return autoreleasepool { () -> String? in
            guard let json = try? JSONSerialization.jsonObject(with: data),
                  let object = json as? [String: Any]
            else {
                return nil
            }

            if let item = object["item"] as? [String: Any],
               let title = title(fromMessageObject: item) {
                return title
            }

            if let payload = object["payload"] as? [String: Any],
               isUserPayload(object: object, payload: payload),
               let title = title(fromPayloadObject: payload) {
                return title
            }

            return title(fromMessageObject: object)
        }
    }

    private static func title(fromMessageObject object: [String: Any]) -> String? {
        guard object["role"] as? String == "user" else {
            return nil
        }

        if let text = object["content"] as? String {
            return normalizeTitle(text)
        }

        if let content = object["content"] as? [[String: Any]] {
            return title(fromContentArray: content)
        }

        return nil
    }

    private static func title(fromPayloadObject object: [String: Any]) -> String? {
        if let message = object["message"] as? String {
            return normalizeTitle(message)
        }

        if let content = object["content"] as? [[String: Any]] {
            return title(fromContentArray: content)
        }

        return nil
    }

    private static func isUserPayload(object: [String: Any], payload: [String: Any]) -> Bool {
        object["type"] as? String == "user_message"
            || payload["type"] as? String == "user_message"
            || payload["role"] as? String == "user"
    }

    private static func title(fromContentArray content: [[String: Any]]) -> String? {
        let text = content
            .compactMap { item in
                guard let text = item["text"] as? String else {
                    return nil
                }
                return normalizeWhitespace(text)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return normalizeTitle(text)
    }

    private static func normalizeTitle(_ text: String) -> String? {
        let normalized = normalizeWhitespace(text)
        guard !normalized.isEmpty else {
            return nil
        }

        return String(normalized.prefix(80))
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
