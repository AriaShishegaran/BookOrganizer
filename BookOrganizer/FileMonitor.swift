import Foundation
import Combine
import PDFKit
import ZIPFoundation
import AppKit

class FileMonitor: ObservableObject {
    @Published var detectedFiles: [DetectedFile] = []

    private let fileManager = FileManager.default
    private let downloadsURL: URL
    private let booksFolderURL: URL
    private let allowedExtensions = ["pdf", "epub"]
    private let operationQueue = OperationQueue()
    private var folderMonitor: DispatchSourceFileSystemObject?

    init() {
        downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        booksFolderURL = downloadsURL.appendingPathComponent("Books")

        log("[Init] FileMonitor initialized")
        log("[Init] Downloads URL: \(downloadsURL.path)")
        log("[Init] Books Folder URL: \(booksFolderURL.path)")

        // Configure the operation queue
        operationQueue.maxConcurrentOperationCount = 4
        operationQueue.qualityOfService = .userInitiated
    }

    func startMonitoring() {
        createBooksFolder()
        processExistingFiles()
        startFolderMonitor()
    }

    func stopMonitoring() {
        folderMonitor?.cancel()
        folderMonitor = nil
        operationQueue.cancelAllOperations()
        log("[Monitoring] Stopped monitoring.")
    }

    private func startFolderMonitor() {
        let descriptor = open(downloadsURL.path, O_EVTONLY)
        if descriptor == -1 {
            log("[Error] Unable to open Downloads directory.")
            return
        }

        folderMonitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend], queue: DispatchQueue.global())

        folderMonitor?.setEventHandler { [weak self] in
            self?.directoryDidChange()
        }

        folderMonitor?.setCancelHandler {
            close(descriptor)
        }

        folderMonitor?.resume()
        log("[Monitoring] Started monitoring \(downloadsURL.path) using DispatchSource.")
    }

    private func directoryDidChange() {
        log("[Monitoring] Detected changes in Downloads directory.")
        processNewFiles()
    }

    private func processNewFiles() {
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for fileURL in fileURLs {
                guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                    continue
                }

                DispatchQueue.main.async {
                    if !self.detectedFiles.contains(where: { $0.url == fileURL }) {
                        let detectedFile = DetectedFile(url: fileURL)
                        self.detectedFiles.append(detectedFile)
                        self.updateFileStatus(for: detectedFile.id, status: .pending)
                        self.processFile(at: fileURL)
                    }
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

    private func processExistingFiles() {
        log("[ProcessExistingFiles] Scanning Downloads folder for existing files.")
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for fileURL in fileURLs {
                guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                    continue
                }
                DispatchQueue.main.async {
                    if !self.detectedFiles.contains(where: { $0.url == fileURL }) {
                        let detectedFile = DetectedFile(url: fileURL)
                        self.detectedFiles.append(detectedFile)
                        self.updateFileStatus(for: detectedFile.id, status: .pending)
                        self.processFile(at: fileURL)
                    }
                }
            }
        } catch {
            log("[Error] Failed to list contents of Downloads folder: \(error)")
        }
    }

    private func processFile(at url: URL) {
        operationQueue.addOperation {
            self.processFileOperation(at: url)
        }
    }

    private func processFileOperation(at url: URL) {
        log("[ProcessFile] Processing file: \(url.lastPathComponent)")

        guard !url.path.contains("/Books/") else {
            log("[ProcessFile] File is already in Books folder. Skipping.")
            return
        }

        self.updateFileStatus(for: url, status: .processing)

        do {
            var identifiers = [String: String]() // Key: Type, Value: Identifier

            if let isbn = try self.extractISBN(from: url) {
                log("[ProcessFile] ISBN extracted: \(isbn)")
                identifiers["isbn"] = isbn
            } else if let title = try self.extractTitle(from: url) {
                log("[ProcessFile] Title extracted: \(title)")
                identifiers["title"] = title
            } else {
                log("[ProcessFile] No identifiers found in \(url.lastPathComponent).")
                self.updateFileStatus(for: url, status: .failed)
                return
            }

            self.moveAndRenameFile(at: url, withIdentifiers: identifiers) { success in
                if success {
                    self.updateFileStatus(for: url, status: .processed)
                } else {
                    self.updateFileStatus(for: url, status: .failed)
                }
            }
        } catch {
            log("[Error] Error processing file \(url.lastPathComponent): \(error)")
            self.updateFileStatus(for: url, status: .failed)
        }
    }

    // MARK: - Enhanced Identifier Extraction

    private func extractISBN(from url: URL) throws -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return try extractISBNFromPDF(url: url)
        case "epub":
            return try extractISBNFromEPUB(url: url)
        default:
            return nil
        }
    }

    private func extractISBNFromPDF(url: URL) throws -> String? {
        log("[ExtractISBNFromPDF] Extracting ISBN from PDF: \(url.lastPathComponent)")
        guard let pdfDocument = PDFDocument(url: url) else {
            log("[ExtractISBNFromPDF] Failed to open PDF document.")
            return nil
        }

        var potentialISBNs = Set<String>()

        // Extract ISBN from document metadata
        if let metadata = pdfDocument.documentAttributes {
            for key in ["Keywords", "Title", "Subject", "Author", "Producer", "Creator"] {
                if let value = metadata[key] as? String {
                    let isbns = extractISBNsFromString(value)
                    potentialISBNs.formUnion(isbns)
                }
            }
        }

        // Extract ISBN from the first few pages
        let maxPagesToSearch = min(pdfDocument.pageCount, 10)
        for pageIndex in 0..<maxPagesToSearch {
            if let page = pdfDocument.page(at: pageIndex),
               let pageContent = page.string {
                let isbns = extractISBNsFromString(pageContent)
                potentialISBNs.formUnion(isbns)
            }
        }

        // If no ISBNs found yet, scan the entire document (can be time-consuming)
        if potentialISBNs.isEmpty {
            for pageIndex in maxPagesToSearch..<pdfDocument.pageCount {
                if let page = pdfDocument.page(at: pageIndex),
                   let pageContent = page.string {
                    let isbns = extractISBNsFromString(pageContent)
                    potentialISBNs.formUnion(isbns)
                }
            }
        }

        // Validate ISBNs
        for isbn in potentialISBNs {
            if isValidISBN(isbn) {
                log("[ExtractISBNFromPDF] Valid ISBN found: \(isbn)")
                return isbn
            }
        }

        log("[ExtractISBNFromPDF] No valid ISBN found in PDF.")
        return nil
    }

    private func extractISBNFromEPUB(url: URL) throws -> String? {
        log("[ExtractISBNFromEPUB] Extracting ISBN from EPUB: \(url.lastPathComponent)")
        do {
            let archive = try Archive(url: url, accessMode: .read)
            var potentialISBNs = Set<String>()

            // Look for OPF and HTML files in EPUB
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

            // Validate ISBNs
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

        // Regular expressions for ISBN-10 and ISBN-13
        let patterns = [
            #"\bISBN[- ]?(1[03])?:?\s*([0-9]{1,5}[\- ]?[0-9]+[\- ]?[0-9]+[\- ]?[0-9Xx])\b"#,  // Matches ISBN with or without ISBN-10 or ISBN-13 prefix
            #"\b(97(8|9))?\d{9}(\d|X)\b"#  // Matches 13-digit ISBNs
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let nsString = string as NSString
                let results = regex.matches(in: string, options: [], range: NSRange(location: 0, length: nsString.length))
                for match in results {
                    let isbnCandidate = nsString.substring(with: match.range)
                    let cleanedISBN = cleanISBNString(isbnCandidate)
                    potentialISBNs.insert(cleanedISBN)
                }
            }
        }

        return potentialISBNs
    }

    private func cleanISBNString(_ isbn: String) -> String {
        // Remove any non-alphanumeric characters
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

        // Check document attributes for Title
        if let metadata = pdfDocument.documentAttributes,
           let title = metadata["Title"] as? String, !title.isEmpty {
            log("[ExtractTitleFromPDF] Found title in metadata: \(title)")
            return title
        }

        // Fallback to first page content
        if let firstPage = pdfDocument.page(at: 0),
           let pageContent = firstPage.string {
            let lines = pageContent.components(separatedBy: "\n")
            for line in lines {
                if line.count > 5 && line.count < 100 { // Heuristic for title length
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

    // MARK: - Move and Rename File with Identifiers

    private func moveAndRenameFile(at url: URL, withIdentifiers identifiers: [String: String], completion: @escaping (Bool) -> Void) {
        fetchBookInfo(identifiers: identifiers) { [weak self] fullName, metadata in
            guard let self = self else { return }
            guard let fullName = fullName else {
                self.log("[MoveAndRenameFile] Failed to fetch book info for identifiers: \(identifiers)")
                completion(false)
                return
            }

            let sanitizedName = self.sanitizeFileName(fullName)
            let destinationURL = self.booksFolderURL
                .appendingPathComponent("\(sanitizedName).\(url.pathExtension)")

            do {
                if self.fileManager.fileExists(atPath: destinationURL.path) {
                    try self.fileManager.removeItem(at: destinationURL)
                }
                try self.fileManager.moveItem(at: url, to: destinationURL)
                self.log("[MoveAndRenameFile] Moved and renamed file to \(destinationURL.path)")

                // Update metadata
                self.updateMetadata(for: destinationURL, with: metadata)

                // Update UI
                DispatchQueue.main.async {
                    if let index = self.detectedFiles.firstIndex(where: { $0.url == url }) {
                        self.detectedFiles[index].newFileName = sanitizedName + "." + url.pathExtension
                    }
                }

                completion(true)
            } catch {
                self.log("[Error] Error moving and renaming file: \(error)")
                completion(false)
            }
        }
    }

    // MARK: - Fetch Book Info with Retry Mechanism

    private func fetchBookInfo(identifiers: [String: String], completion: @escaping (String?, [String: Any]?) -> Void) {
        let apiKey = "" // Add your Google Books API key if you have one

        var query = ""
        if let isbn = identifiers["isbn"] {
            query = "isbn:\(isbn)"
        } else if let title = identifiers["title"] {
            query = "intitle:\(title)"
        } else {
            completion(nil, nil)
            return
        }

        let urlString = "https://www.googleapis.com/books/v1/volumes?q=\(query)&key=\(apiKey)"
        guard let encodedURLString = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encodedURLString) else {
            log("[FetchBookInfo] Invalid URL for query: \(query)")
            completion(nil, nil)
            return
        }

        let urlSession = URLSession(configuration: .ephemeral)
        var attempts = 0
        let maxAttempts = 3

        func makeRequest() {
            attempts += 1
            let task = urlSession.dataTask(with: url) { [weak self] data, response, error in
                guard let self = self else { return }

                if let error = error {
                    self.log("[FetchBookInfo] Error fetching book info: \(error)")
                    if attempts < maxAttempts {
                        self.log("[FetchBookInfo] Retrying... (\(attempts)/\(maxAttempts))")
                        makeRequest()
                    } else {
                        completion(nil, nil)
                    }
                    return
                }

                guard let data = data else {
                    self.log("[FetchBookInfo] No data received from book info request.")
                    completion(nil, nil)
                    return
                }

                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let items = json["items"] as? [[String: Any]],
                       let volumeInfo = items.first?["volumeInfo"] as? [String: Any],
                       let title = volumeInfo["title"] as? String {

                        let authors = volumeInfo["authors"] as? [String] ?? ["Unknown Author"]
                        let authorsString = authors.joined(separator: ", ")
                        let fullName = "\(title) - \(authorsString)"

                        self.log("[FetchBookInfo] Fetched book info: \(fullName)")
                        completion(fullName, volumeInfo)
                    } else {
                        self.log("[FetchBookInfo] Book info not found in response.")
                        completion(nil, nil)
                    }
                } catch {
                    self.log("[FetchBookInfo] Error parsing JSON: \(error)")
                    completion(nil, nil)
                }
            }
            task.resume()
        }

        makeRequest()
    }

    // MARK: - Update Metadata

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

        // Save the updated PDF
        pdfDocument.write(to: url)
        log("[UpdatePDFMetadata] Updated PDF metadata for \(url.lastPathComponent)")
    }

    private func updateEPUBMetadata(for url: URL, with metadata: [String: Any]) {
        // Updating EPUB metadata is complex; a full implementation would require parsing and updating OPF files.
        // For brevity, we'll log that this is not implemented fully.
        log("[UpdateEPUBMetadata] Updating EPUB metadata is not fully implemented.")
    }

    // MARK: - Update File Status

    private func updateFileStatus(for url: URL, status: FileStatus) {
        DispatchQueue.main.async {
            if let index = self.detectedFiles.firstIndex(where: { $0.url == url }) {
                self.detectedFiles[index].status = status
            }
        }
    }

    private func updateFileStatus(for id: UUID, status: FileStatus) {
        DispatchQueue.main.async {
            if let index = self.detectedFiles.firstIndex(where: { $0.id == id }) {
                self.detectedFiles[index].status = status
            }
        }
    }

    // MARK: - Manual ISBN Entry

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
                    self.updateFileStatus(for: file.url, status: .processing)
                    self.processFileWithManualISBN(file: file, isbn: cleanedISBN)
                } else {
                    self.log("[ManualISBNEntry] Invalid ISBN entered: \(isbnInput)")
                    self.updateFileStatus(for: file.url, status: .failed)
                }
            }
        }
    }

    private func processFileWithManualISBN(file: DetectedFile, isbn: String) {
        self.moveAndRenameFile(at: file.url, withIdentifiers: ["isbn": isbn]) { success in
            if success {
                self.updateFileStatus(for: file.url, status: .processed)
            } else {
                self.updateFileStatus(for: file.url, status: .failed)
            }
        }
    }

    // MARK: - Utility Methods

    private func sanitizeFileName(_ fileName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return fileName.components(separatedBy: invalidCharacters).joined(separator: "_")
    }

    private func log(_ message: String) {
        Logger.shared.log(message)
    }
}

// MARK: - Supporting Types

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
