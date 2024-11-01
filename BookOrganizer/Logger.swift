import Foundation

class Logger {
    static let shared = Logger()
    private let logFileURL: URL
    private let fileHandle: FileHandle?

    private let queue = DispatchQueue(label: "com.bookorganizer.loggerQueue", qos: .utility)

    init() {
        // Create the log file in the Downloads folder
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        logFileURL = downloadsURL.appendingPathComponent("BookOrganizerDebugLog.txt")
        // Create the log file if it doesn't exist
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        }
        // Open the file handle for writing
        do {
            fileHandle = try FileHandle(forWritingTo: logFileURL)
            // Move to the end of the file for appending
            fileHandle?.seekToEndOfFile()
        } catch {
            print("Logger initialization error: \(error)")
            fileHandle = nil
        }
        log("Logger initialized. Log file path: \(logFileURL.path)")
    }

    func log(_ message: String) {
        queue.async {
            let timestamp = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let timestampString = formatter.string(from: timestamp)
            let logMessage = "[\(timestampString)] \(message)\n"
            if let data = logMessage.data(using: .utf8) {
                self.fileHandle?.write(data)
            }
            // Also print to console
            print(logMessage, terminator: "")
        }
    }

    deinit {
        fileHandle?.closeFile()
    }
}
