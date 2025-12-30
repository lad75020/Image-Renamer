import SwiftUI
import Combine
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

func sanitizeFilename(_ input: String) -> String {
    let lower = input.lowercased()
    let allowed = lower.unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) || "-_ ".unicodeScalars.contains(scalar) {
            return Character(String(scalar))
        } else {
            return " "
        }
    }
    let interim = String(allowed)
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .components(separatedBy: CharacterSet.whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let hyphenated = interim.replacingOccurrences(of: " ", with: "-")
    return hyphenated.isEmpty ? "image" : hyphenated
}

enum FilenameLanguage: String, CaseIterable, Identifiable {
    case english = "English"
    case french = "French"
    case spanish = "Spanish"
    case german = "German"
    var id: String { rawValue }
}

@MainActor
final class ImageRenamerViewModel: ObservableObject {
    // Only allow common image file extensions to be analyzed
    private let allowedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp"
    ]

    private func isSupportedImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return allowedImageExtensions.contains(ext)
    }

    // Marker to identify files already renamed by this app
    let renameMarker = "__IR__"

    private func isAlreadyRenamed(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.contains(renameMarker)
    }

    private func convertHEICToJPEGIfNeeded(_ url: URL) throws -> URL {
        #if os(macOS)
        let ext = url.pathExtension.lowercased()
        guard ext == "heic" || ext == "heif" else { return url }

        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
            throw NSError(domain: "ImageRenamer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert HEIC to JPEG for \(url.lastPathComponent)"])
        }

        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(base).appendingPathExtension("jpg")
        var suffix = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(suffix)").appendingPathExtension("jpg")
            suffix += 1
        }

        try jpegData.write(to: candidate, options: .atomic)
        try fm.removeItem(at: url) // Delete original HEIC as requested

        return candidate
        #else
        return url
        #endif
    }

    // Batch processing configuration
    private let batchSize: Int = 20
    private let perRequestDelayNanoseconds: UInt64 = 300_000_000 // 300ms
    private(set) var allCandidateURLs: [URL] = [] // all eligible images discovered (not yet processed)
    @Published var currentBatchIndex: Int = 0 // zero-based batch index

    @Published var selectedURLs: [URL] = []
    @Published var results: [URL: String] = [:] // proposed base name (no extension)
    @Published var perFileErrors: [URL: String] = [:]
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    @Published var processedCount: Int = 0
    @Published var totalCount: Int = 0
    @Published var autoRenameEnabled: Bool = true
    @Published var serverAddress: String = "http://127.0.0.1:11434"
    private var analysisTask: Task<Void, Never>? = nil
    private(set) var allResults: [URL: String] = [:]
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = ""
    @Published var selectedLanguage: FilenameLanguage = .english

    var client: OllamaClient

    init(client: OllamaClient? = nil) {
        if let client {
            self.client = client
            self.serverAddress = client.baseURL.absoluteString
        } else {
            let saved = UserDefaults.standard.string(forKey: "OllamaServerAddress") ?? "127.0.0.1"
            if let url = ImageRenamerViewModel.normalizeServerAddress(saved) {
                self.serverAddress = url.absoluteString
                self.client = OllamaClient(baseURL: url, model: "llava-llama3:8b-v1.1-fp16")
            } else {
                let fallback = URL(string: "http://127.0.0.1:11434")!
                self.serverAddress = fallback.absoluteString
                self.client = OllamaClient(baseURL: fallback, model: "llava-llama3:8b-v1.1-fp16")
            }
        }
        self.selectedModel = self.client.model
        self.availableModels = [self.client.model]
    }

    private static func normalizeServerAddress(_ input: String) -> URL? {
        var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.isEmpty { return nil }
        if !string.contains("://") {
            string = "http://" + string
        }
        guard var comps = URLComponents(string: string) else { return nil }
        if comps.scheme == nil { comps.scheme = "http" }
        if comps.port == nil { comps.port = 11434 }
        return comps.url
    }

    /// Apply the current `serverAddress` by recreating the client and refreshing models.
    func applyServerAddress() async {
        guard let url = ImageRenamerViewModel.normalizeServerAddress(serverAddress) else {
            self.errorMessage = "Invalid server address. Enter an IP or URL like 192.168.1.10 or http://192.168.1.10:11434."
            return
        }
        // Normalize and persist the canonical URL string
        self.serverAddress = url.absoluteString
        UserDefaults.standard.set(self.serverAddress, forKey: "OllamaServerAddress")

        // Rebuild the client pointing to the new server
        let model = self.selectedModel.isEmpty ? "llava-llama3:8b-v1.1-fp16" : self.selectedModel
        self.client = OllamaClient(baseURL: url, model: model)

        // Refresh available models from the new server
        await refreshModels()
    }

    /// Starts the analysis in a cancellable Task so the UI can stop it.
    func startAnalysis(prompt: String = "Provide a short, descriptive filename for this image without file extension.") {
        guard !isProcessing else { return }
        analysisTask = Task { [weak self] in
            await self?.analyzeSelected(prompt: prompt)
        }
    }

    /// Cancels an in-flight analysis run.
    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    func pickImages() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType.image]
        if panel.runModal() == .OK {
            var picked: [URL] = []
            for url in panel.urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    // Enumerate immediate children and collect image files (non-recursive)
                    if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) {
                        for file in contents {
                            if let type = try? file.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .image), isSupportedImage(file) {
                                if !isAlreadyRenamed(file) {
                                    picked.append(file)
                                }
                            }
                        }
                    }
                } else {
                    // If a single file was picked, ensure it's an allowed image type
                    if isSupportedImage(url) && !isAlreadyRenamed(url) {
                        picked.append(url)
                    }
                }
            }
            // Build candidate list (allowed images, not already renamed)
            let candidates = picked.filter { isSupportedImage($0) && !isAlreadyRenamed($0) }
            self.allCandidateURLs = candidates
            self.currentBatchIndex = 0
            self.selectedURLs = Array(candidates.prefix(batchSize))
        }
        #else
        self.errorMessage = "Image picking is only implemented for macOS in this sample."
        #endif
    }

    func refreshModels() async {
        do {
            let models = try await client.listModels()
            self.availableModels = models.sorted()
            if !self.availableModels.contains(self.selectedModel), let first = self.availableModels.first {
                self.selectedModel = first
            }
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    func analyzeSelected(prompt: String = "Provide a short, descriptive filename for this image without file extension.") async {
        guard !allCandidateURLs.isEmpty else { return }

        // Filter out unsupported or already renamed file types to avoid sending non-images or already renamed to the model
        let (supported, unsupported) = allCandidateURLs.partitioned { isSupportedImage($0) && !isAlreadyRenamed($0) }
        if !unsupported.isEmpty {
            for url in unsupported {
                perFileErrors[url] = "Unsupported file type or already renamed: .\(url.pathExtension.lowercased())"
            }
        }
        guard !supported.isEmpty else { return }
        processedCount = 0
        totalCount = supported.count
        if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }

        isProcessing = true
        errorMessage = nil
        results.removeAll()
        allResults.removeAll()
        perFileErrors.removeAll()

        // Verify Ollama server is reachable before sending large payloads
        do {
            try await client.healthCheck()
            if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            self.isProcessing = false
            return
        }

        for url in supported {
            // Skip files already renamed (contain the marker)
            if isAlreadyRenamed(url) { self.processedCount += 1; continue }

            if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }
            var currentURL = url
            do {
                // Convert HEIC/HEIF to JPEG first (high quality) and delete original
                currentURL = try convertHEICToJPEGIfNeeded(url)
                if currentURL != url {
                    if let idx = self.selectedURLs.firstIndex(of: url) {
                        self.selectedURLs[idx] = currentURL
                    }
                    if let idxAll = self.allCandidateURLs.firstIndex(of: url) {
                        self.allCandidateURLs[idxAll] = currentURL
                    }
                }

                // Defensive: skip if current file name contains the marker
                if isAlreadyRenamed(currentURL) { self.processedCount += 1; continue }

                let data = try Data(contentsOf: currentURL)
                let promptWithLanguage = prompt + " Respond in \(self.selectedLanguage.rawValue)."

                func requestOnce() async throws -> String {
                    return try await client.describeImage(data: data, prompt: promptWithLanguage, model: selectedModel)
                }

                var raw: String
                do {
                    raw = try await requestOnce()
                } catch {
                    // If it's a 500 from Ollama, wait 2 seconds and retry once for the same image
                    if case OllamaClientError.httpStatus(let code, _) = error, code == 500 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        raw = try await requestOnce()
                    } else {
                        throw error
                    }
                }

                let trimmed = String(raw.prefix(120))
                let sanitized = sanitizeFilename(trimmed)
                let finalBase = String(sanitized.prefix(60))

                if Task.isCancelled { self.isProcessing = false; self.analysisTask = nil; return }

                if autoRenameEnabled {
                    let (newURL, markedBase) = try renameOne(originalURL: currentURL, base: finalBase)
                    // Keep candidate lists in sync with the rename
                    if let idxAll = self.allCandidateURLs.firstIndex(of: currentURL) {
                        self.allCandidateURLs[idxAll] = newURL
                    }
                    if let idxSel = self.selectedURLs.firstIndex(of: currentURL) {
                        self.selectedURLs[idxSel] = newURL
                    }
                    // Update results for the visible batch
                    if self.selectedURLs.contains(newURL) {
                        self.results.removeValue(forKey: currentURL)
                        self.results[newURL] = markedBase
                    }
                    // Update global results
                    self.allResults.removeValue(forKey: currentURL)
                    self.allResults[newURL] = markedBase
                } else {
                    // Store proposals only (no auto-rename)
                    self.allResults[currentURL] = finalBase
                    if self.selectedURLs.contains(currentURL) {
                        self.results[currentURL] = finalBase
                    }
                }
                self.processedCount += 1
                try? await Task.sleep(nanoseconds: perRequestDelayNanoseconds)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.isProcessing = false
                    self.analysisTask = nil
                    return
                }
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                self.perFileErrors[currentURL] = message
                self.errorMessage = message
                self.processedCount += 1
                // Throttle even after an error to avoid tight retry loops on server issues
                try? await Task.sleep(nanoseconds: perRequestDelayNanoseconds)
                // Continue with the next image in case of failure
                continue
            }
        }

        isProcessing = false
        analysisTask = nil
    }

    private func renameOne(originalURL: URL, base: String) throws -> (URL, String) {
        let fm = FileManager.default
        let ext = originalURL.pathExtension.isEmpty ? "" : "." + originalURL.pathExtension.lowercased()
        let markedBase = base.contains(renameMarker) ? base : "\(base)\(renameMarker)"
        let dir = originalURL.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent(markedBase + ext)

        var suffix = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(markedBase)-\(suffix)" + ext)
            suffix += 1
        }

        try fm.moveItem(at: originalURL, to: candidate)
        return (candidate, markedBase)
    }

    func renameFiles() {
        guard !results.isEmpty else { return }
        let fm = FileManager.default
        var updated: [URL: String] = [:]

        for (url, base) in results {
            let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension.lowercased()
            // Append marker to indicate this file has been renamed by the app
            let markedBase = base.contains(renameMarker) ? base : "\(base)\(renameMarker)"
            let dir = url.deletingLastPathComponent()
            var candidate = dir.appendingPathComponent(markedBase + ext)

            var suffix = 1
            while fm.fileExists(atPath: candidate.path) {
                candidate = dir.appendingPathComponent("\(markedBase)-\(suffix)" + ext)
                suffix += 1
            }

            do {
                try fm.moveItem(at: url, to: candidate)
                updated[candidate] = markedBase
                // Keep global results in sync with renamed files
                self.allResults.removeValue(forKey: url)
                self.allResults[candidate] = markedBase
            } catch {
                errorMessage = "Failed to rename \(url.lastPathComponent): \(error.localizedDescription)"
                updated[url] = markedBase
                self.allResults[url] = markedBase
            }
        }

        // Update selected URLs to reflect new locations
        self.selectedURLs = Array(updated.keys)
        self.results = updated

        // After finishing this batch, try to load the next batch if available
        loadNextBatchIfAvailable()
    }

    func loadNextBatchIfAvailable() {
        let start = (currentBatchIndex + 1) * batchSize
        guard start < allCandidateURLs.count else { return }
        currentBatchIndex += 1
        let end = min(start + batchSize, allCandidateURLs.count)
        self.selectedURLs = Array(allCandidateURLs[start..<end])
        self.results.removeAll()
        for url in self.selectedURLs {
            if let name = allResults[url] {
                self.results[url] = name
            }
        }
        self.perFileErrors.removeAll()
        self.errorMessage = nil
    }
}

#if os(macOS)
extension ImageRenamerViewModel {
    /// Prompts the user to authorize access to a folder (external or network) and stores a security-scoped bookmark.
    func authorizeFolderAccess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Authorize"
        panel.message = "Choose a folder (external or network) to grant the app access."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: "AuthorizedFolderBookmark")
                UserDefaults.standard.synchronize()
                self.errorMessage = nil
            } catch {
                self.errorMessage = "Failed to save folder authorization: \(error.localizedDescription)"
            }
        }
    }

    /// Resolves the previously stored security-scoped bookmark for the authorized folder.
    func resolveAuthorizedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "AuthorizedFolderBookmark") else {
            return nil
        }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                // Re-save a fresh bookmark if needed
                let fresh = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(fresh, forKey: "AuthorizedFolderBookmark")
            }
            return url
        } catch {
            self.errorMessage = "Failed to resolve folder authorization: \(error.localizedDescription)"
            return nil
        }
    }

    /// Executes a closure with security-scoped access to the authorized folder, if available.
    @discardableResult
    func withAuthorizedFolderAccess<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let url = resolveAuthorizedFolder() else {
            self.errorMessage = "No authorized folder. Please authorize access first."
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            self.errorMessage = "Could not start security-scoped access for the authorized folder."
            return nil
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }
}
#endif

private extension Array {
    func partitioned(by belongsInFirstPartition: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = []
        var second: [Element] = []
        first.reserveCapacity(count)
        second.reserveCapacity(count)
        for element in self {
            if belongsInFirstPartition(element) {
                first.append(element)
            } else {
                second.append(element)
            }
        }
        return (first, second)
    }
}

