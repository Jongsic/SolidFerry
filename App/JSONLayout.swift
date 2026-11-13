import Foundation

/// JSON laid out with one value per line and two-space indents, keeping everything else as
/// written: key order, number spelling, string escapes. (JSONSerialization would reorder keys
/// and respell numbers.)
enum JSONLayout {
    /// Nil when `text` isn't JSON.
    static func indented(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else { return nil }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var depth = 0
        var inString = false, escaped = false
        func newline() {
            out.append("\n")
            for _ in 0..<(depth * 2) { out.append(" ") }
        }
        func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" }
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                out.append(c)
                // An empty one stays on its line: {} and [].
                var j = i + 1
                while j < scalars.count, isSpace(scalars[j]) { j += 1 }
                if j < scalars.count, scalars[j] == (c == "{" ? "}" : "]") {
                    out.append(scalars[j])
                    i = j
                } else {
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth = max(depth - 1, 0)
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(":")
                out.append(" ")
            default:
                if !isSpace(c) { out.append(c) }
            }
            i += 1
        }
        return String(out)
    }
}
