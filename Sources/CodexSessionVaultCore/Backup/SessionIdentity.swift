import Foundation

public enum SessionIdentity {
    public static func sessionID(from fileURL: URL) -> String? {
        guard fileURL.pathExtension.lowercased() == "jsonl" else {
            return nil
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? nil : stem
    }

    public static func title(fromJSONLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any]
        else {
            return nil
        }

        if let item = object["item"] as? [String: Any],
           let title = title(fromMessageObject: item) {
            return title
        }

        return title(fromMessageObject: object)
    }

    private static func title(fromMessageObject object: [String: Any]) -> String? {
        guard object["role"] as? String == "user" else {
            return nil
        }

        if let text = object["content"] as? String {
            return normalizeTitle(text)
        }

        if let content = object["content"] as? [[String: Any]] {
            for item in content {
                if let text = item["text"] as? String,
                   let normalized = normalizeTitle(text) {
                    return normalized
                }
            }
        }

        return nil
    }

    private static func normalizeTitle(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return String(trimmed.prefix(80))
    }
}
