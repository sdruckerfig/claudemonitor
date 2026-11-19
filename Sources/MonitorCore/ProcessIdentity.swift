import Darwin
import Foundation

/// Identity of a live process, to make sure a remembered pid still means the same process.
public enum ProcessIdentity {
    public static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// True when `pid` is still the process that `row` described in a snapshot taken at `takenAt`
    /// (start times agree to within `ps`'s one-second etime resolution, plus slack).
    public static func isSameProcess(_ row: ProcessRow, takenAt: Date) -> Bool {
        guard let start = startTime(of: row.pid) else { return false }
        let expected = takenAt.addingTimeInterval(-TimeInterval(row.elapsedSeconds))
        return abs(start.timeIntervalSince(expected)) < 3
    }
}
