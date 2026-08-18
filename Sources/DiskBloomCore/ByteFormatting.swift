import Foundation

public enum DiskBloomFormat {
    public static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .usePB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: max(0, value))
    }

    public static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.1f초", seconds)
        }
        if seconds < 60 {
            return String(format: "%.1f초", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)분 \(remainder)초"
    }
}
