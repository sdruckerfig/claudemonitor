import Foundation

public enum Format {
    public static func bytes<T: BinaryInteger>(_ n: T) -> String {
        let v = Double(n)
        if v >= 1_073_741_824 { return String(format: "%.1f GB", v / 1_073_741_824) }
        if v >= 1_048_576 { return String(format: "%.0f MB", v / 1_048_576) }
        return String(format: "%.0f KB", v / 1024)
    }

    public static func cores(_ c: Double) -> String {
        c < 0.05 ? "0 cores" : String(format: c < 10 ? "%.1f cores" : "%.0f cores", c)
    }

    /// Compact age: 45s, 12m, 5h, 3d.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// Replaces the home directory with ~.
    public static func path(_ p: String, home: String = NSHomeDirectory()) -> String {
        p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }
}
