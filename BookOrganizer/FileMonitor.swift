import Foundation
import Combine
import PDFKit
import ZIPFoundation
import AppKit

@MainActor
class FileMonitor: ObservableObject {
    @Published var detectedFiles: [DetectedFile] = []

    private let fileManager = FileManager.default
    private let downloadsURL: URL
    private let booksFolderURL: URL
    private let allowedExtensions = ["pdf", "epub"]
    private var folderMonitor: DispatchSourceProtocol?
    private var isProcessing = false
    private var processingTasks: [URL: Task<Void, Never>] = [:]

    init() {
        downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        booksFolderURL = downloadsURL.appendingPathComponent("Books")

        log("[Init] FileMonitor initialized")
        log("[Init] Downloads URL: \(downloadsURL.path)")
        log("[Init] Books Folder URL: \(booksFolderURL.path)")
    }

    func startMonitoring() {
        createBooksFolder()
        Task {
            await processExistingFiles()
        }
        startFolderMonitor()
    }

    func stopMonitoring() {
        folderMonitor?.cancel()
        folderMonitor = nil
        log("[Monitoring] Stopped monitoring.")
    }

    private func startFolderMonitor() {
        let descriptor = open(downloadsURL.path, O_EVTONLY)
        if descriptor == -1 {
            log("[Error] Unable to open Downloads directory.")
            return
        }

        let eventMask: DispatchSource.FileSystemEvent = [.write, .extend]
        let queue = DispatchQueue.global()

        folderMonitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: eventMask, queue: queue)

        folderMonitor?.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.debouncedDirectoryDidChange()
            }
        }

        folderMonitor?.setCancelHandler {
            close(descriptor)
        }

        folderMonitor?.resume()

        log("[Monitoring] Started monitoring \(downloadsURL.path) using DispatchSource.")
    }

    private var debounceTimer: Task<Void, Never>?

    private func debouncedDirectoryDidChange() async {
        debounceTimer?.cancel()
        debounceTimer = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            await directoryDidChange()
        }
    }

    private func directoryDidChange() async {
        log("[Monitoring] Detected changes in Downloads directory.")
        await processNewFiles()
    }

    private func processNewFiles() async {
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for fileURL in fileURLs {
                guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                    continue
                }

                if !detectedFiles.contains(where: { $0.url == fileURL }) {
                    let detectedFile = DetectedFile(url: fileURL)
                    detectedFiles.append(detectedFile)
                    await updateFileStatus(for: detectedFile.id, status: .pending)
                    await processFile(at: fileURL)
                }
            }
        } catch {
            log("[Error] Failed to list contents of Downloads folder: \(error)")
        }
    }

    private func createBooksFolder() {
        log("[CreateBooksFolder] Ensuring Books folder exists at: \(booksFolderURL.path)")
        if !fileManager.fileExists(atPath: booksFolderURL.path) {
            do {
                try fileManager.createDirectory(at: booksFolderURL, withIntermediateDirectories: true, attributes: nil)
                log("[CreateBooksFolder] Books folder created.")
            } catch {
                log("[Error] Failed to create Books folder: \(error)")
            }
        } else {
            log("[CreateBooksFolder] Books folder already exists.")
        }
    }

    private func processExistingFiles() async {
        log("[ProcessExistingFiles] Scanning Downloads folder for existing files.")
        await processNewFiles()
    }

    private func processFile(at url: URL) async {
        guard !processingTasks.keys.contains(url) else { return }

        let task = Task {
            await processFileOperation(at: url)
        }
        processingTasks[url] = task
    }

    private func processFileOperation(at url: URL) async {
        log("[ProcessFile] Processing file: \(url.lastPathComponent)")

        guard !url.path.contains("/Books/") else {
            log("[ProcessFile] File is already in Books folder. Skipping.")
            return
        }

        await updateFileStatus(for: url, status: .processing)

        do {
            var identifiers = [String: String]() // Key: Type, Value: Identifier

            if let isbn = try await extractISBN(from: url) {
                log("[ProcessFile] ISBN extracted: \(isbn)")
                identifiers["isbn"] = isbn
            } else if let title = try extractTitle(from: url) {
                log("[ProcessFile] Title extracted: \(title)")
                identifiers["title"] = title
            } else {
                log("[ProcessFile] No identifiers found in \(url.lastPathComponent).")
                await updateFileStatus(for: url, status: .failed)
                return
            }

            let success = await moveAndRenameFile(at: url, withIdentifiers: identifiers)
            if success {
                await updateFileStatus(for: url, status: .processed)
            } else {
                await updateFileStatus(for: url, status: .failed)
            }
        } catch {
            log("[Error] Error processing file \(url.lastPathComponent): \(error)")
            await updateFileStatus(for: url, status: .failed)
        }
        processingTasks[url] = nil
    }

    private func extractISBN(from url: URL) async throws -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return try await extractISBNFromPDF(url: url)
        case "epub":
            return try await extractISBNFromEPUB(url: url)
        default:
            return nil
        }
    }

    private func extractISBNFromPDF(url: URL) async throws -> String? {
        log("[ExtractISBNFromPDF] Extracting ISBN from PDF: \(url.lastPathComponent)")
        guard let pdfDocument = PDFDocument(url: url) else {
            log("[ExtractISBNFromPDF] Failed to open PDF document.")
            return nil
        }

        var potentialISBNs = Set<String>()

        if let metadata = pdfDocument.documentAttributes {
            for key in ["Keywords", "Title", "Subject", "Author", "Producer", "Creator"] {
                if let value = metadata[key] as? String {
                    let isbns = extractISBNsFromString(value)
                    potentialISBNs.formUnion(isbns)
                }
            }
        }

        let maxPagesToSearch = min(pdfDocument.pageCount, 10)
        for pageIndex in 0..<maxPagesToSearch {
            if let page = pdfDocument.page(at: pageIndex),
               let pageContent = page.string {
                let isbns = extractISBNsFromString(pageContent)
                potentialISBNs.formUnion(isbns)
            }
        }

        for isbn in potentialISBNs {
            if isValidISBN(isbn) {
                log("[ExtractISBNFromPDF] Valid ISBN found: \(isbn)")
                return isbn
            }
        }

        log("[ExtractISBNFromPDF] No valid ISBN found in PDF.")
        return nil
    }

    private func extractISBNFromEPUB(url: URL) async throws -> String? {
        log("[ExtractISBNFromEPUB] Extracting ISBN from EPUB: \(url.lastPathComponent)")
        do {
            let archive = try Archive(url: url, accessMode: .read)
            var potentialISBNs = Set<String>()

            for entry in archive {
                if entry.path.hasSuffix(".opf") || entry.path.hasSuffix(".html") || entry.path.hasSuffix(".htm") || entry.path.hasSuffix(".xhtml") {
                    var fileData = Data()
                    _ = try archive.extract(entry, consumer: { data in
                        fileData.append(data)
                    })
                    if let fileString = String(data: fileData, encoding: .utf8) {
                        let isbns = extractISBNsFromString(fileString)
                        potentialISBNs.formUnion(isbns)
                    }
                }
            }

            for isbn in potentialISBNs {
                if isValidISBN(isbn) {
                    log("[ExtractISBNFromEPUB] Valid ISBN found: \(isbn)")
                    return isbn
                }
            }

            log("[ExtractISBNFromEPUB] No valid ISBN found in EPUB.")
            return nil
        } catch {
            log("[ExtractISBNFromEPUB] Failed to open EPUB archive: \(error)")
            return nil
        }
    }

    private func extractISBNsFromString(_ string: String) -> Set<String> {
        var potentialISBNs = Set<String>()

        let patterns = [
            #"\b(?:ISBN(?:-1[03])?:?\s*)?((?:97[89][\-\s]?)?[0-9][0-9\-\s]{9,}[0-9Xx])\b"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let nsString = string as NSString
                let results = regex.matches(in: string, options: [], range: NSRange(location: 0, length: nsString.length))
                for match in results {
                    let isbnCandidate = nsString.substring(with: match.range(at: 1))
                    let cleanedISBN = cleanISBNString(isbnCandidate)
                    potentialISBNs.insert(cleanedISBN)
                }
            }
        }

        return potentialISBNs
    }

    private func cleanISBNString(_ isbn: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics
        let cleanedISBN = isbn.unicodeScalars.filter { allowedCharacters.contains($0) }.map { Character($0) }
        return String(cleanedISBN).uppercased()
    }

    private func isValidISBN(_ isbn: String) -> Bool {
        let isbnDigits = isbn.filter { $0.isNumber || $0 == "X" }

        if isbnDigits.count == 10 {
            return isValidISBN10(isbnDigits)
        } else if isbnDigits.count == 13 {
            return isValidISBN13(isbnDigits)
        }
        return false
    }

    private func isValidISBN10(_ isbn: String) -> Bool {
        var sum = 0
        for (index, character) in isbn.enumerated() {
            let multiplier = 10 - index
            let value: Int
            if character == "X" && index == 9 {
                value = 10
            } else if let digit = Int(String(character)) {
                value = digit
            } else {
                return false
            }
            sum += multiplier * value
        }
        return sum % 11 == 0
    }

    private func isValidISBN13(_ isbn: String) -> Bool {
        var sum = 0
        for (index, character) in isbn.enumerated() {
            guard let digit = Int(String(character)) else {
                return false
            }
            let multiplier = (index % 2 == 0) ? 1 : 3
            sum += digit * multiplier
        }
        return sum % 10 == 0
    }

    private func extractTitle(from url: URL) throws -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return try extractTitleFromPDF(url: url)
        case "epub":
            return try extractTitleFromEPUB(url: url)
        default:
            return nil
        }
    }

    private func extractTitleFromPDF(url: URL) throws -> String? {
        log("[ExtractTitleFromPDF] Extracting title from PDF: \(url.lastPathComponent)")
        guard let pdfDocument = PDFDocument(url: url) else {
            log("[ExtractTitleFromPDF] Failed to open PDF document.")
            return nil
        }

        if let metadata = pdfDocument.documentAttributes,
           let title = metadata["Title"] as? String, !title.isEmpty {
            log("[ExtractTitleFromPDF] Found title in metadata: \(title)")
            return title
        }

        if let firstPage = pdfDocument.page(at: 0),
           let pageContent = firstPage.string {
            let lines = pageContent.components(separatedBy: "\n")
            for line in lines {
                if line.count > 5 && line.count < 100 {
                    log("[ExtractTitleFromPDF] Found title in content: \(line)")
                    return line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        log("[ExtractTitleFromPDF] No title found in PDF.")
        return nil
    }

    private func extractTitleFromEPUB(url: URL) throws -> String? {
        log("[ExtractTitleFromEPUB] Extracting title from EPUB: \(url.lastPathComponent)")
        do {
            let archive = try Archive(url: url, accessMode: .read)

            for entry in archive {
                if entry.path.hasSuffix(".opf") {
                    var xmlData = Data()
                    _ = try archive.extract(entry, consumer: { data in
                        xmlData.append(data)
                    })
                    if let xmlString = String(data: xmlData, encoding: .utf8) {
                        if let title = extractTitleFromOPF(xmlString: xmlString) {
                            log("[ExtractTitleFromEPUB] Found title in OPF: \(title)")
                            return title
                        }
                    }
                }
            }

            log("[ExtractTitleFromEPUB] No title found in EPUB.")
            return nil
        } catch {
            log("[ExtractTitleFromEPUB] Failed to open EPUB archive: \(error)")
            return nil
        }
    }

    private func extractTitleFromOPF(xmlString: String) -> String? {
        let pattern = "<dc:title(?:[^>]*)>(.*?)</dc:title>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let nsString = xmlString as NSString
            let range = NSRange(location: 0, length: nsString.length)
            if let match = regex.firstMatch(in: xmlString, options: [], range: range) {
                let title = nsString.substring(with: match.range(at: 1))
                return title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func moveAndRenameFile(at url: URL, withIdentifiers identifiers: [String: String]) async -> Bool {
        guard let (fullName, metadata) = await fetchBookInfo(identifiers: identifiers) else {
            log("[MoveAndRenameFile] Failed to fetch book info for identifiers: \(identifiers)")
            return false
        }

        let sanitizedName = sanitizeFileName(fullName)
        let destinationURL = booksFolderURL.appendingPathComponent("\(sanitizedName).\(url.pathExtension)")

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: url, to: destinationURL)
            log("[MoveAndRenameFile] Moved and renamed file to \(destinationURL.path)")

            updateMetadata(for: destinationURL, with: metadata)

            if let index = detectedFiles.firstIndex(where: { $0.url == url }) {
                detectedFiles[index].newFileName = sanitizedName + "." + url.pathExtension
            }

            return true
        } catch {
            log("[Error] Error moving and renaming file: \(error)")
            return false
        }
    }

    private func fetchBookInfo(identifiers: [String: String]) async -> (String, [String: Any])? {
        let apiKey = ""

        var query = ""
        if let isbn = identifiers["isbn"] {
            query = "isbn:\(isbn)"
        } else if let title = identifiers["title"] {
            query = "intitle:\(title)"
        } else {
            return nil
        }

        let urlString = "https://www.googleapis.com/books/v1/volumes?q=\(query)&key=\(apiKey)"
        guard let encodedURLString = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encodedURLString) else {
            log("[FetchBookInfo] Invalid URL for query: \(query)")
            return nil
        }

        let urlSession = URLSession(configuration: .ephemeral)
        let maxAttempts = 3
        var attempts = 0
        var delay: UInt64 = 1_000_000_000

        while attempts < maxAttempts {
            attempts += 1
            do {
                let (data, _) = try await urlSession.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let items = json["items"] as? [[String: Any]],
                   let volumeInfo = items.first?["volumeInfo"] as? [String: Any],
                   let title = volumeInfo["title"] as? String {

                    let authors = volumeInfo["authors"] as? [String] ?? ["Unknown Author"]
                    let authorsString = authors.joined(separator: ", ")
                    let fullName = "\(title) - \(authorsString)"

                    log("[FetchBookInfo] Fetched book info: \(fullName)")
                    return (fullName, volumeInfo)
                } else {
                    log("[FetchBookInfo] Book info not found in response.")
                    return nil
                }
            } catch {
                log("[FetchBookInfo] Error fetching book info: \(error)")
                if attempts < maxAttempts {
                    log("[FetchBookInfo] Retrying in \(delay / 1_000_000_000) seconds... (\(attempts)/\(maxAttempts))")
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                } else {
                    return nil
                }
            }
        }
        return nil
    }

    private func updateMetadata(for url: URL, with metadata: [String: Any]?) {
        guard let metadata = metadata else { return }
        let fileExtension = url.pathExtension.lowercased()

        switch fileExtension {
        case "pdf":
            updatePDFMetadata(for: url, with: metadata)
        case "epub":
            updateEPUBMetadata(for: url, with: metadata)
        default:
            break
        }
    }

    private func updatePDFMetadata(for url: URL, with metadata: [String: Any]) {
        guard let pdfDocument = PDFDocument(url: url) else {
            log("[UpdatePDFMetadata] Failed to open PDF document.")
            return
        }

        var attributes = pdfDocument.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = metadata["title"]
        attributes[PDFDocumentAttribute.authorAttribute] = (metadata["authors"] as? [String])?.joined(separator: ", ")
        attributes[PDFDocumentAttribute.subjectAttribute] = (metadata["categories"] as? [String])?.joined(separator: ", ")
        pdfDocument.documentAttributes = attributes

        let success = pdfDocument.write(to: url)
        if success {
            log("[UpdatePDFMetadata] Updated PDF metadata for \(url.lastPathComponent)")
        } else {
            log("[UpdatePDFMetadata] Failed to write updated PDF.")
        }
    }

    private func updateEPUBMetadata(for url: URL, with metadata: [String: Any]) {
        log("[UpdateEPUBMetadata] Updating EPUB metadata is not fully implemented.")
    }

    private func updateFileStatus(for url: URL, status: FileStatus) async {
        if let index = detectedFiles.firstIndex(where: { $0.url == url }) {
            detectedFiles[index].status = status
        }
    }

    private func updateFileStatus(for id: UUID, status: FileStatus) async {
        if let index = detectedFiles.firstIndex(where: { $0.id == id }) {
            detectedFiles[index].status = status
        }
    }

    func promptForISBN(file: DetectedFile) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Enter ISBN"
            alert.informativeText = "Enter the ISBN for \(file.originalFileName):"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            alert.accessoryView = inputField

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let isbnInput = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanedISBN = self.cleanISBNString(isbnInput)
                if self.isValidISBN(cleanedISBN) {
                    Task {
                        await self.updateFileStatus(for: file.url, status: .processing)
                        await self.processFileWithManualISBN(file: file, isbn: cleanedISBN)
                    }
                } else {
                    self.log("[ManualISBNEntry] Invalid ISBN entered: \(isbnInput)")
                    Task {
                        await self.updateFileStatus(for: file.url, status: .failed)
                    }
                }
            }
        }
    }

    private func processFileWithManualISBN(file: DetectedFile, isbn: String) async {
        let success = await moveAndRenameFile(at: file.url, withIdentifiers: ["isbn": isbn])
        if success {
            await updateFileStatus(for: file.url, status: .processed)
        } else {
            await updateFileStatus(for: file.url, status: .failed)
        }
    }

    private func sanitizeFileName(_ fileName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return fileName.components(separatedBy: invalidCharacters).joined(separator: "_")
    }

    private func log(_ message: String) {
        Task {
            await Logger.shared.log(message)
        }
    }
}

enum FileStatus {
    case pending
    case processing
    case processed
    case failed
}

class DetectedFile: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let originalFileName: String
    @Published var newFileName: String?
    @Published var status: FileStatus

    init(url: URL) {
        self.url = url
        self.originalFileName = url.lastPathComponent
        self.status = .pending
    }
}
