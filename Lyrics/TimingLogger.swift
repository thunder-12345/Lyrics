import Foundation

enum TimingLogger {
    static func log(_ message: String) {
        print("[LyricsTiming] \(Date().timeIntervalSince1970) \(message)")
    }

    static func elapsedMS(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
