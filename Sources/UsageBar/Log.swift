import Foundation
import os

/// Appends diagnostics to ~/Library/Logs/UsageBar.log and the unified log
/// (public, so `log show --predicate 'process == "UsageBar"'` shows them).
enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/UsageBar.log"
    private static let logger = Logger(subsystem: "com.wallacehsieh.UsageBar", category: "app")
    private static let queue = DispatchQueue(label: "claude-usage.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static func write(_ msg: String) {
        logger.notice("\(msg, privacy: .public)")
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        queue.sync {
            if let h = FileHandle(forWritingAtPath: path) {
                defer { h.closeFile() }
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
            } else {
                FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
            }
        }
    }
}
