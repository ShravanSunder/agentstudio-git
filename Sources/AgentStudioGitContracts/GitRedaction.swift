import Foundation

public enum GitRedaction {
    public static func redact(_ value: String) -> String {
        var redactedValue = replacingMatches(
            in: value,
            pattern: #"([A-Za-z][A-Za-z0-9+.-]*://)[^/\s@]+@"#,
            template: "$1<redacted>@"
        )
        redactedValue = replacingMatches(
            in: redactedValue,
            pattern: #"(?i)(token|access_token|password|passwd|secret)=([^&\s]+)"#,
            template: "$1=<redacted>"
        )
        redactedValue = replacingMatches(
            in: redactedValue,
            pattern: #"(?i)(?:~|/[^:\s'"]*)/\.ssh/[^:\s'"]+"#,
            template: "<redacted-private-key-path>"
        )
        return redactedValue
    }

    private static func replacingMatches(in value: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
