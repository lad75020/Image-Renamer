// ContentView.swift – Image Renamer
// Redesigned UI matching the HTML/CSS mockup design.

import SwiftUI
#if os(macOS)
import AppKit
#endif
#if canImport(CoreML)
import CoreML
#endif
#if canImport(Translation)
import Translation
#endif

// MARK: - Design Tokens (approximate sRGB conversions from oklch design values)

private enum T {
    static let accent      = Color(red: 0.42, green: 0.32, blue: 0.85)
    static let accentSoft  = Color(red: 0.933, green: 0.912, blue: 0.990)
    static let accentInk   = Color(red: 0.29, green: 0.21, blue: 0.65)
    static let railBg      = Color(red: 0.960, green: 0.955, blue: 0.944)
    static let paper       = Color(red: 0.983, green: 0.980, blue: 0.972)
    static let panel       = Color.white
    static let panel2      = Color(red: 0.972, green: 0.967, blue: 0.957)
    static let ink         = Color(red: 0.12,  green: 0.11,  blue: 0.17)
    static let ink2        = Color(red: 0.28,  green: 0.27,  blue: 0.36)
    static let ink3        = Color(red: 0.44,  green: 0.43,  blue: 0.52)
    static let ink4        = Color(red: 0.62,  green: 0.61,  blue: 0.69)
    static let line        = Color(red: 0.900, green: 0.897, blue: 0.908)
    static let line2       = Color(red: 0.858, green: 0.855, blue: 0.870)
    static let lineSoft    = Color(red: 0.936, green: 0.934, blue: 0.945)
    static let ok          = Color(red: 0.16,  green: 0.71,  blue: 0.44)
    static let stopBg      = Color(red: 0.98,  green: 0.94,  blue: 0.93)
    static let stopBorder  = Color(red: 0.90,  green: 0.72,  blue: 0.68)
    static let stopFg      = Color(red: 0.55,  green: 0.22,  blue: 0.18)
}

// MARK: - Helpers

private extension AnalysisEngine {
    var cardHint: String {
        switch self {
        case .ollama:          return "Local Ollama server"
        case .openAICompatible: return "OpenAI-compatible API"
        case .coreml:          return "On-device Apple Silicon"
        }
    }
    var needsServer: Bool {
        switch self {
        case .ollama, .openAICompatible: return true
        case .coreml: return false
        }
    }
}

private extension FilenameLanguage {
    var code: String {
        switch self {
        case .english: return "EN"
        case .french:  return "FR"
        case .german:  return "DE"
        case .spanish: return "ES"
        }
    }
}

#if os(macOS)
private enum PreviewImageLoader {
    static func loadImage(from url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
    }

    static func fileSizeDescription(for url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let bytes = attrs[.size] as? Int64 else { return nil }
            let mb = Double(bytes) / 1_048_576
            return mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", Double(bytes) / 1024)
        }.value
    }
}
#endif

// MARK: - Root

struct ContentView: View {
    @StateObject private var viewModel = ImageRenamerViewModel()

    #if canImport(Translation)
    private var targetLanguage: Locale.Language? {
        guard viewModel.translationMode == .apple else { return nil }
        switch viewModel.selectedLanguage {
        case .english: return nil
        case .french:  return Locale.Language(identifier: "fr")
        case .german:  return Locale.Language(identifier: "de")
        case .spanish: return Locale.Language(identifier: "es")
        }
    }
    #endif

    var body: some View {
        AppLayout(viewModel: viewModel)
            .task { await viewModel.refreshModels() }
            #if canImport(Translation)
            .translationTask(source: Locale.Language(identifier: "en"), target: targetLanguage) { session in
                if viewModel.translationMode == .apple {
                    viewModel.setAppleTranslator { text, _ in
                        let response = try await session.translate(text)
                        return response.targetText
                    }
                } else {
                    viewModel.setAppleTranslator(nil)
                }
            }
            .onChange(of: viewModel.translationMode) { _, newValue in
                if newValue != .apple { viewModel.setAppleTranslator(nil) }
            }
            .onDisappear { viewModel.setAppleTranslator(nil) }
            #endif
    }
}

// MARK: - App Layout

private struct AppLayout: View {
    @ObservedObject var viewModel: ImageRenamerViewModel
    @State private var showDebug = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(viewModel: viewModel)
                .frame(width: 280)
            WorkspaceView(viewModel: viewModel, showDebug: $showDebug)
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(T.paper)
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    SidebarHeader()
                    InferenceSection(viewModel: viewModel)
                    Divider().background(T.lineSoft)
                    LanguageSection(viewModel: viewModel)
                    Divider().background(T.lineSoft)
                    SourceSection(viewModel: viewModel)
                }
            }
            SidebarFooter(viewModel: viewModel)
        }
        .background(T.railBg)
        .overlay(alignment: .trailing) {
            Rectangle().fill(T.line).frame(width: 1)
        }
    }
}

// MARK: - Sidebar Header

private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [T.accent, Color(red: 0.28, green: 0.18, blue: 0.80)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: T.accent.opacity(0.5), radius: 6, x: 0, y: 3)
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("Image Renamer")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(T.ink)
                Text("Vision-powered renaming")
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.ink3)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(T.lineSoft).frame(height: 1)
        }
    }
}

// MARK: - Inference Section

private struct InferenceSection: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Inference")

            VStack(alignment: .leading, spacing: 6) {
                Text("Engine")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(T.ink2)
                LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(AnalysisEngine.allCases) { engine in
                        EngineCard(
                            label: engine.rawValue,
                            hint: engine.cardHint,
                            isActive: viewModel.engine == engine
                        )
                        .onTapGesture { viewModel.engine = engine }
                    }
                }
            }

            if viewModel.engine == .coreml {
                FieldRow(label: "Model") {
                    HStack(spacing: 6) {
                        Text(viewModel.coreMLModelDisplayName.isEmpty ? "No model" : viewModel.coreMLModelDisplayName)
                            .font(.system(size: 12))
                            .foregroundStyle(T.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        SmallButton("Choose…", systemImage: "doc.badge.plus") {
                            viewModel.pickCoreMLModel()
                        }
                        .disabled(viewModel.isProcessing)
                    }
                }
            } else {
                FieldRow(label: "Model") {
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(viewModel.availableModels, id: \.self) { m in
                                Button(m) { viewModel.selectedModel = m }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(viewModel.selectedModel.isEmpty ? "No models" : viewModel.selectedModel)
                                    .font(.system(size: 12))
                                    .foregroundStyle(T.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(T.ink3)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(T.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7).stroke(T.line, lineWidth: 1)
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize(horizontal: false, vertical: true)

                        SmallIconButton(systemImage: "arrow.clockwise") {
                            Task { await viewModel.refreshModels() }
                        }
                        .disabled(viewModel.isProcessing)
                    }
                }

                if viewModel.engine.needsServer {
                    FieldRow(label: "Server", alignTop: true) {
                        ServerInputRow(viewModel: viewModel)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: - Engine Card

private struct EngineCard: View {
    let label: String
    let hint: String
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? T.accentInk : T.ink)
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(T.ink3)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(isActive ? T.accentSoft : T.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? T.accent : T.line, lineWidth: 1)
        )
        .shadow(color: isActive ? T.accent.opacity(0.12) : .clear, radius: 0, x: 0, y: 0)
        .contentShape(Rectangle())
    }
}

// MARK: - Server Input

private struct ServerInputRow: View {
    @ObservedObject var viewModel: ImageRenamerViewModel
    @State private var isConnected = false
    @State private var isConnecting = false

    private var serverPlaceholder: String {
        switch viewModel.engine {
        case .ollama:           return "http://127.0.0.1:11434"
        case .openAICompatible: return "http://localhost:8887"
        case .coreml:           return "Server URL"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(isConnected: isConnected, isConnecting: isConnecting)
                TextField(serverPlaceholder, text: $viewModel.serverAddress)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(T.ink)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled(true)
                Button {
                    isConnecting = true
                    Task {
                        await viewModel.applyServerAddress()
                        isConnecting = false
                        isConnected = true
                    }
                } label: {
                    Text(isConnecting ? "Connecting…" : isConnected ? "Connected" : "Connect")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isConnected ? T.ok : T.ink2)
                }
                .buttonStyle(.plain)
                .disabled(isConnecting || viewModel.isProcessing)
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(T.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))
        }
    }
}

private struct StatusDot: View {
    let isConnected: Bool
    let isConnecting: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(isConnecting ? Color.yellow : isConnected ? T.ok : T.ink4)
            .frame(width: 8, height: 8)
            .opacity(isConnecting ? (pulse ? 1 : 0.4) : 1)
            .animation(isConnecting ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { if isConnecting { pulse = true } }
            .onChange(of: isConnecting) { _, v in pulse = v }
    }
}

// MARK: - Language Section

private struct LanguageSection: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    private var availableModes: [TranslationMode] {
        #if canImport(Translation)
        return TranslationMode.allCases
        #else
        return [.ai]
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Output language")

            LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(FilenameLanguage.allCases) { lang in
                    LanguageCard(
                        code: lang.code,
                        label: lang.rawValue,
                        isActive: viewModel.selectedLanguage == lang
                    )
                    .onTapGesture { viewModel.selectedLanguage = lang }
                }
            }

            FieldRow(label: "Translator") {
                SegmentedPicker(
                    selection: $viewModel.translationMode,
                    options: availableModes,
                    label: { mode in
                        switch mode {
                        case .ai:    return "AI model"
                        case .apple: return "Apple Translate"
                        }
                    }
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

private struct LanguageCard: View {
    let code: String
    let label: String
    let isActive: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(code)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isActive ? T.accent : T.ink3)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isActive ? T.accentInk : T.ink2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(isActive ? T.accentSoft : T.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isActive ? T.accent : T.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

// MARK: - Source Section

private struct SourceSection: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    private var folderPath: String {
        guard let first = viewModel.selectedURLs.first else { return "No files selected" }
        let dir = first.deletingLastPathComponent().path
        return dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var folderName: String {
        String(folderPath.split(separator: "/").last ?? Substring(folderPath))
    }

    private var fileFormats: String {
        let exts = Set(viewModel.selectedURLs.map { $0.pathExtension.uppercased() }).sorted()
        return exts.isEmpty ? "HEIC, JPG, PNG" : exts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Source")

            Button {
                viewModel.pickImages()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(T.accentSoft)
                        Image(systemName: "folder")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(T.accent)
                    }
                    .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.selectedURLs.isEmpty ? "Choose images…" : folderName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(T.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 4) {
                            Text("\(viewModel.selectedURLs.count) images")
                            Text("·").foregroundStyle(T.ink4)
                            Text(fileFormats)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(T.ink3)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(T.ink3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(T.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: [.command])

            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(viewModel.forceRename ? T.accent : T.panel)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(viewModel.forceRename ? T.accent : T.line2, lineWidth: 1))
                    if viewModel.forceRename {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 16, height: 16)
                .onTapGesture { viewModel.forceRename.toggle() }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Force rename")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(T.ink)
                    Text("Re-run on files already renamed")
                        .font(.system(size: 10.5))
                        .foregroundStyle(T.ink3)
                }
                .onTapGesture { viewModel.forceRename.toggle() }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: - Sidebar Footer

private struct SidebarFooter: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    private var canRename: Bool {
        !viewModel.selectedURLs.isEmpty &&
        !viewModel.isProcessing &&
        (viewModel.engine != .coreml || viewModel.isCoreMLReady) &&
        ((!viewModel.engine.needsServer) || !viewModel.selectedModel.isEmpty)
    }

    private var hintText: String {
        if viewModel.isProcessing { return "Working… you can stop at any time" }
        if viewModel.processedCount > 0 && viewModel.processedCount < viewModel.totalCount {
            return "\(viewModel.processedCount)/\(viewModel.totalCount) renamed — press to run remaining"
        }
        if viewModel.processedCount > 0 { return "\(viewModel.processedCount)/\(viewModel.totalCount) renamed" }
        return "Runs locally — nothing leaves your Mac"
    }

    var body: some View {
        VStack(spacing: 8) {
            if viewModel.isProcessing {
                Button {
                    viewModel.cancelAnalysis()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Stop")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(T.stopBg)
                    .foregroundStyle(T.stopFg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.stopBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    viewModel.startAnalysis()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Rename \(viewModel.selectedURLs.count) \(viewModel.selectedURLs.count == 1 ? "image" : "images")")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(canRename ? T.accent : T.panel2)
                    .foregroundStyle(canRename ? .white : T.ink3)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: canRename ? T.accent.opacity(0.4) : .clear, radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(!canRename)
            }

            Text(viewModel.errorMessage ?? hintText)
                .font(.system(size: 11))
                .foregroundStyle(viewModel.errorMessage != nil ? Color.red : T.ink3)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(T.line).frame(height: 1)
        }
    }
}

// MARK: - Workspace

private struct WorkspaceView: View {
    @ObservedObject var viewModel: ImageRenamerViewModel
    @Binding var showDebug: Bool

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(viewModel: viewModel)
            HStack(spacing: 0) {
                FocusPanel(viewModel: viewModel)
                    .frame(maxWidth: .infinity)
                Rectangle().fill(T.line).frame(width: 1)
                QueuePanel(viewModel: viewModel)
                    .frame(width: 300)
            }
            .frame(maxHeight: .infinity)
            DebugStrip(viewModel: viewModel, showDebug: $showDebug)
        }
        .background(T.paper)
    }
}

// MARK: - Workspace Header

private struct WorkspaceHeader: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    private var folderName: String {
        guard let first = viewModel.selectedURLs.first else { return "No selection" }
        return first.deletingLastPathComponent().lastPathComponent
    }

    private var total: Int { viewModel.selectedURLs.count }
    private var processed: Int { viewModel.processedCount }
    private var percent: Int {
        guard total > 0 else { return 0 }
        return Int(Double(processed) / Double(total) * 100)
    }

    var body: some View {
        HStack(spacing: 24) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(T.ink3)
                Text(folderName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(T.ink)
            }
            Spacer()
            HStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 999)
                            .fill(T.lineSoft)
                        RoundedRectangle(cornerRadius: 999)
                            .fill(
                                LinearGradient(
                                    colors: [T.accent, Color(red: 0.52, green: 0.42, blue: 0.95)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * CGFloat(percent) / 100)
                            .animation(.easeInOut(duration: 0.4), value: percent)
                    }
                }
                .frame(width: 200, height: 6)

                HStack(spacing: 4) {
                    Text("\(processed)")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(T.ink)
                    Text("/ \(total)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(T.ink3)
                    Text("· \(percent)%")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(T.ink3)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(T.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(T.line).frame(height: 1)
        }
    }
}

// MARK: - Focus Panel

private enum FocusState { case processing, done, recent, idle }

private struct FocusPanel: View {
    @ObservedObject var viewModel: ImageRenamerViewModel
    @State private var fileSizeText: String?

    private var focusURL: URL? {
        viewModel.currentURLBeingProcessed
            ?? viewModel.allResults.keys.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
            ?? viewModel.selectedURLs.first
    }

    private var state: FocusState {
        if viewModel.currentURLBeingProcessed != nil { return .processing }
        guard let url = focusURL else { return .idle }
        if viewModel.allResults[url] != nil {
            return viewModel.processedCount == viewModel.totalCount && viewModel.totalCount > 0 ? .done : .recent
        }
        return .idle
    }

    private var badgeText: String {
        switch state {
        case .processing: return viewModel.isProcessing ? "Analyzing…" : "Analyzing…"
        case .done:       return "Batch complete"
        case .recent:     return "Last renamed"
        case .idle:       return "Preview"
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // Badge + meta
                HStack {
                    FocusBadge(state: state, text: badgeText)
                    Spacer()
                    if let url = focusURL {
                        HStack(spacing: 6) {
                            if let size = fileSizeText {
                                Text(size)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(T.ink3)
                                Text("·").foregroundStyle(T.ink4)
                            }
                            Text(url.pathExtension.uppercased())
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(T.ink3)
                        }
                    }
                }

                // Image preview
                if let url = focusURL {
                    ImagePreview(url: url, isProcessing: state == .processing)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(T.panel2)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 32))
                                    .foregroundStyle(T.ink4)
                                Text("Select images to get started")
                                    .font(.system(size: 13))
                                    .foregroundStyle(T.ink3)
                            }
                        )
                        .aspectRatio(4/3, contentMode: .fit)
                }

                // Rename row
                if let url = focusURL {
                    RenameRow(
                        url: url,
                        proposed: viewModel.allResults[url],
                        isProcessing: state == .processing,
                        language: viewModel.selectedLanguage.rawValue
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(22)
        }
        .task(id: focusURL) {
            #if os(macOS)
            if let focusURL {
                fileSizeText = await PreviewImageLoader.fileSizeDescription(for: focusURL)
            } else {
                fileSizeText = nil
            }
            #endif
        }
    }
}

private struct FocusBadge: View {
    let state: FocusState
    let text: String
    @State private var pulsing = false

    private var bg: Color {
        switch state {
        case .processing: return T.accentSoft
        case .done:       return Color(red: 0.92, green: 0.98, blue: 0.94)
        case .recent, .idle: return T.panel
        }
    }
    private var fg: Color {
        switch state {
        case .processing: return T.accentInk
        case .done:       return T.ok
        case .recent, .idle: return T.ink3
        }
    }
    private var border: Color {
        switch state {
        case .processing: return T.accent.opacity(0.3)
        case .done:       return T.ok.opacity(0.35)
        case .recent, .idle: return T.line
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if state == .processing {
                Circle()
                    .fill(T.accent)
                    .frame(width: 6, height: 6)
                    .scaleEffect(pulsing ? 1.4 : 1)
                    .opacity(pulsing ? 0.6 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(fg)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(bg)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 1))
    }
}

private struct ImagePreview: View {
    let url: URL
    let isProcessing: Bool
    @State private var scanOffset: CGFloat = -1
    @State private var image: Image?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                }

                if isProcessing {
                    // Grid overlay
                    Canvas { ctx, size in
                        let step: CGFloat = 48
                        var x: CGFloat = 0
                        while x < size.width {
                            ctx.stroke(Path { p in p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height)) }, with: .color(.white.opacity(0.08)), lineWidth: 1)
                            x += step
                        }
                        var y: CGFloat = 0
                        while y < size.height {
                            ctx.stroke(Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)) }, with: .color(.white.opacity(0.08)), lineWidth: 1)
                            y += step
                        }
                    }

                    // Scan line
                    LinearGradient(
                        colors: [.clear, T.accent.opacity(0.55), T.accent.opacity(0.55), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: geo.size.height * 0.08)
                    .offset(y: scanOffset * geo.size.height)
                    .animation(
                        .linear(duration: 2.4).repeatForever(autoreverses: false),
                        value: scanOffset
                    )
                    .onAppear { scanOffset = 1.2 }
                }

                // File ext badge
                VStack {
                    HStack {
                        Text(url.pathExtension.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .padding(12)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
        .aspectRatio(4/3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        .task(id: url) {
            image = nil
            #if os(macOS)
            if let nsImage = await PreviewImageLoader.loadImage(from: url) {
                image = Image(nsImage: nsImage)
            }
            #endif
        }
    }
}

private struct RenameRow: View {
    let url: URL
    let proposed: String?
    let isProcessing: Bool
    let language: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ORIGINAL")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(T.ink3)
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(T.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Circle()
                        .fill(T.accentSoft)
                        .frame(width: 30, height: 30)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(T.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("PROPOSED")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(T.ink3)
                        Text("· \(language.lowercased())")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(T.ink2)
                    }
                    if isProcessing {
                        TypingText(target: proposed ?? "analyzing…")
                    } else if let name = proposed {
                        HStack(spacing: 0) {
                            Text(name)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(T.accentInk)
                            Text(".\(url.pathExtension.lowercased())")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(T.ink3)
                        }
                        .lineLimit(1)
                    } else {
                        Text("Waiting…")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(T.ink4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(T.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.line, lineWidth: 1))
    }
}

private struct TypingText: View {
    let target: String
    @State private var shown = ""
    @State private var showCaret = true

    var body: some View {
        HStack(spacing: 0) {
            Text(shown)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(T.accentInk)
            Text("|")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(T.accent)
                .opacity(showCaret ? 1 : 0)
                .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: showCaret)
        }
        .lineLimit(1)
        .onAppear {
            shown = ""
            showCaret = false
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                for char in target {
                    shown.append(char)
                    try? await Task.sleep(nanoseconds: 28_000_000)
                }
            }
        }
        .onChange(of: target) { _, t in
            shown = ""
            Task {
                for char in t {
                    shown.append(char)
                    try? await Task.sleep(nanoseconds: 28_000_000)
                }
            }
        }
    }
}

// MARK: - Queue Panel

private struct QueuePanel: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    private var processed: Int { viewModel.processedCount }
    private var total: Int { viewModel.selectedURLs.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(T.ink)
                Spacer()
                Text("\(processed) of \(total)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(T.ink3)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(T.line).frame(height: 1)
            }

            if viewModel.selectedURLs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 28))
                        .foregroundStyle(T.ink4)
                    Text("No images selected")
                        .font(.system(size: 12))
                        .foregroundStyle(T.ink3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(viewModel.selectedURLs.enumerated()), id: \.element) { index, url in
                            QueueRow(
                                index: index,
                                url: url,
                                proposed: viewModel.allResults[url],
                                isCurrent: url == viewModel.currentURLBeingProcessed,
                                isDone: viewModel.allResults[url] != nil && url != viewModel.currentURLBeingProcessed
                            )
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
            }
        }
        .background(T.panel)
    }
}

private struct QueueRow: View {
    let index: Int
    let url: URL
    let proposed: String?
    let isCurrent: Bool
    let isDone: Bool

    @State private var spinDegrees: Double = 0

    private var state: String { isDone ? "done" : isCurrent ? "now" : "pending" }

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(isDone ? T.ok : isCurrent ? T.accent : T.panel2)
                    .overlay(Circle().stroke(isDone ? .clear : isCurrent ? .clear : T.line, lineWidth: 1))
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else if isCurrent {
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(spinDegrees))
                        .onAppear {
                            withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                                spinDegrees = 360
                            }
                        }
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(T.ink3)
                }
            }
            .frame(width: 22, height: 22)

            // Thumbnail
            QueueThumbnail(url: url, isDone: isDone, isCurrent: isCurrent)

            // File names
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(isDone ? T.ink4 : T.ink2)
                    .strikethrough(isDone, color: T.ink4)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let name = proposed {
                    HStack(spacing: 0) {
                        Text("→ ")
                            .foregroundStyle(T.ink3)
                        Text(name)
                            .foregroundStyle(isCurrent ? T.accent : T.accentInk)
                            .fontWeight(isCurrent ? .semibold : .semibold)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                } else if isCurrent {
                    Text("Analyzing…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(T.ink3)
                        .italic()
                } else {
                    Text("Waiting")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(T.ink4)
                        .italic()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isCurrent ? T.accentSoft : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

private struct QueueThumbnail: View {
    let url: URL
    let isDone: Bool
    let isCurrent: Bool
    @State private var image: Image? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(T.panel2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line, lineWidth: 1))
            if let img = image {
                img.resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 40, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(isDone ? 0.5 : 1)
        .task(id: url) {
            image = nil
            #if os(macOS)
            if let nsImg = await PreviewImageLoader.loadImage(from: url) {
                image = Image(nsImage: nsImg)
            }
            #endif
        }
    }
}

// MARK: - Debug Strip

private struct DebugStrip: View {
    @ObservedObject var viewModel: ImageRenamerViewModel
    @Binding var showDebug: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(T.line).frame(height: 1)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDebug.toggle() }
                viewModel.showDebugLog = showDebug
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .foregroundStyle(T.ink3)
                    Text("Translation debug log")
                        .font(.system(size: 11.5))
                        .foregroundStyle(T.ink2)
                    Spacer()
                    Image(systemName: showDebug ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(T.ink3)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .background(T.panel2)

            if showDebug {
                ScrollView(.vertical) {
                    Text(viewModel.debugLog.isEmpty ? "No log entries yet." : viewModel.debugLog)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(T.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .frame(height: 140)
                .background(T.panel)
                .overlay(alignment: .top) {
                    Rectangle().fill(T.lineSoft).frame(height: 1)
                }
            }
        }
    }
}

// MARK: - Reusable primitives

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(T.ink3)
            .kerning(0.8)
    }
}

private struct FieldRow<Content: View>: View {
    let label: String
    let alignTop: Bool
    @ViewBuilder let content: () -> Content

    init(label: String, alignTop: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.alignTop = alignTop
        self.content = content
    }

    var body: some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(T.ink2)
                .frame(width: 62, alignment: .leading)
            content()
        }
    }
}

private struct SegmentedPicker<Option: Hashable & Identifiable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { opt in
                Button {
                    selection = opt
                } label: {
                    Text(label(opt))
                        .font(.system(size: 12))
                        .foregroundStyle(selection == opt ? T.ink : T.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selection == opt ? T.panel : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: selection == opt ? .black.opacity(0.06) : .clear, radius: 1, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(T.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))
    }
}

private struct SmallButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(T.ink2)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(T.panel)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct SmallIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(T.ink2)
                .frame(width: 28, height: 28)
                .background(T.panel)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
