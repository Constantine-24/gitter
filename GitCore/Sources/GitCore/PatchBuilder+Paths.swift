import Foundation

// The file header git wants in front of the hunks, including the way git spells paths.
extension PatchBuilder {

    /// Always a plain modification: `git apply --cached` patches the index entry, so mode
    /// lines for an addition or a deletion would be wrong for a partial selection.
    static func fileHeader(for path: String) -> String {
        let old = quote(prefix: "a/", path: path)
        let new = quote(prefix: "b/", path: path)
        // git appends a TAB when the rendered name contains a space, so the name stays
        // unambiguous on the `---`/`+++` lines.
        let oldTab = old.contains(" ") ? "\t" : ""
        let newTab = new.contains(" ") ? "\t" : ""
        return "diff --git \(old) \(new)\n--- \(old)\(oldTab)\n+++ \(new)\(newTab)\n"
    }

    /// git's `quote_c_style`: the prefix and the path are quoted together inside one pair of
    /// double quotes as soon as any byte needs escaping.
    private static func quote(prefix: String, path: String) -> String {
        let bytes = Array((prefix + path).utf8)
        guard bytes.contains(where: needsEscape) else { return prefix + path }
        var out = "\""
        for byte in bytes {
            switch byte {
            case 0x07: out += "\\a"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0B: out += "\\v"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            default:
                if needsEscape(byte) {
                    let octal = String(byte, radix: 8)
                    out += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
                } else {
                    out.append(Character(UnicodeScalar(byte)))
                }
            }
        }
        return out + "\""
    }

    private static func needsEscape(_ byte: UInt8) -> Bool {
        byte < 0x20 || byte >= 0x7F || byte == 0x22 || byte == 0x5C
    }
}
