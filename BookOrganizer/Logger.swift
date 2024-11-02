import Foundation

actor Logger {
    static let shared = Logger()
    private let logFileURL: URL

    init() {
        // Create the log file in the Downloads folder
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        logFileURL = downloadsURL.appendingPathComponent("BookOrganizerDebugLog.txt")
        // Create the log file if it doesn't exist
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        }
        Task {
            await log("Logger initialized. Log file path: \(logFileURL.path)")
        }
    }

    nonisolated func log(_ message: String) async {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestampString = formatter.string(from: timestamp)
        let logMessage = "[\(timestampString)] \(message)\n"

        DispatchQueue.global(qos: .utility).async {
            if let data = logMessage.data(using: .utf8) {
                do {
                    let fileHandle = try FileHandle(forWritingTo: self.logFileURL)
                    defer {
                        try? fileHandle.close()
                    }
                    try fileHandle.seekToEnd()
                    try fileHandle.write(contentsOf: data)
                } catch {
                    print("Logger error: \(error)")
                }
            }
        }

        // Also print to console
        print(logMessage, terminator: "")
    }
}
