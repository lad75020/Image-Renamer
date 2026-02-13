//
//  ContentView.swift
//  Image Renamer
//
//  Created by Laurent Dubertrand on 29/12/2025.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif
#if canImport(CoreML)
import CoreML
#endif

struct ContentView: View {
    @StateObject private var viewModel = ImageRenamerViewModel()

    var body: some View {
        NavigationStack {
            MainContent(viewModel: viewModel)
                .task { await viewModel.refreshModels() }
                .padding()
        }
    }
}

// MARK: - Extracted main content
private struct MainContent: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image Renamer")
                .font(.largeTitle)
                .bold()

            EnginePicker(engine: $viewModel.engine)

            LanguagePicker(selectedLanguage: $viewModel.selectedLanguage)

            ModelSelectionRow(viewModel: viewModel)

            if viewModel.engine == .ollama {
                ServerConnectionRow(viewModel: viewModel)
            }

            ActionButtons(viewModel: viewModel)

            if viewModel.isProcessing {
                ProcessingProgress(processed: viewModel.processedCount, total: viewModel.totalCount)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }

            DebugLogSection(viewModel: viewModel)

            CurrentItemDetail(viewModel: viewModel)
        }
    }
}

// MARK: - Engine Picker
private struct EnginePicker: View {
    @Binding var engine: AnalysisEngine

    var body: some View {
        HStack(spacing: 8) {
            Picker("Engine", selection: $engine) {
                ForEach(AnalysisEngine.allCases) { engineCase in
                    Text(engineCase.rawValue).tag(engineCase)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Language Picker
private struct LanguagePicker: View {
    @Binding var selectedLanguage: FilenameLanguage

    var body: some View {
        HStack(spacing: 8) {
            Picker("Language", selection: $selectedLanguage) {
                ForEach(FilenameLanguage.allCases) { lang in
                    Text(lang.rawValue).tag(lang)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Model Selection
private struct ModelSelectionRow: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    var body: some View {
        HStack(spacing: 8) {
            if viewModel.engine == .ollama {
                Picker("Model", selection: $viewModel.selectedModel) {
                    ForEach(viewModel.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    Task { await viewModel.refreshModels() }
                } label: {
                    Label("Refresh Models", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isProcessing)
            } else {
                HStack(spacing: 8) {
                    Text(viewModel.coreMLModelDisplayName.isEmpty ? "No model selected" : viewModel.coreMLModelDisplayName)
                        .lineLimit(1)
                    Button {
                        viewModel.pickCoreMLModel()
                    } label: {
                        Label("Choose Core ML Model", systemImage: "doc.badge.plus")
                    }
                    .disabled(viewModel.isProcessing)
                }
            }
        }
    }
}

// MARK: - Server Connection (Ollama)
private struct ServerConnectionRow: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    var body: some View {
        HStack(spacing: 8) {
            TextField("Server (IP or URL)", text: $viewModel.serverAddress)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .disableAutocapitalization()
                .disableAutocorrection(true)
            Button {
                Task { await viewModel.applyServerAddress() }
            } label: {
                Label("Connect", systemImage: "network")
            }
            .disabled(viewModel.isProcessing)
        }
    }
}

// MARK: - Action Buttons
private struct ActionButtons: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.pickImages()
            } label: {
                Label("Select Images", systemImage: "photo.on.rectangle")
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button {
                viewModel.startAnalysis()
            } label: {
                Label("Analyze", systemImage: "sparkles")
            }
            .disabled(viewModel.selectedURLs.isEmpty || viewModel.isProcessing || (viewModel.engine == .coreml && !viewModel.isCoreMLReady))

            Button {
                viewModel.cancelAnalysis()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .disabled(!viewModel.isProcessing)
        }
    }
}

// MARK: - Progress
private struct ProcessingProgress: View {
    let processed: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let safeTotal: Double = Double(max(total, 1))
            let progressValue: Double = Double(processed)
            ProgressView(value: progressValue, total: safeTotal)
            let percent: Int = Int((progressValue / safeTotal) * 100)
            Text("\(percent)% • \(processed) / \(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Debug Log
private struct DebugLogSection: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show Translation Debug Log", isOn: $viewModel.showDebugLog)
            if viewModel.showDebugLog {
                TextEditor(text: $viewModel.debugLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
            }
        }
    }
}

// MARK: - Current Item Detail
private struct CurrentItemDetail: View {
    @ObservedObject var viewModel: ImageRenamerViewModel

    var body: some View {
        Group {
            if let url = viewModel.currentURLBeingProcessed {
                HStack(alignment: .top, spacing: 12) {
#if os(macOS)
                    Image(nsImage: NSImage(contentsOf: url) ?? NSImage(size: .zero))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 160, height: 160)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
#else
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 160, height: 160)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
#endif
                    VStack(alignment: .leading, spacing: 6) {
                        Text(url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)
                        if let proposed = viewModel.results[url] {
                            Text("→ \(proposed)\n")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else if let proposed = viewModel.allResults[url] {
                            Text("→ \(proposed)\n")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Text("Analyzing…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            } else {
                Text("No image currently being processed.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func disableAutocapitalization() -> some View {
        #if os(iOS) || os(tvOS) || os(visionOS)
        if #available(iOS 16.0, tvOS 16.0, visionOS 1.0, *) {
            self.textInputAutocapitalization(.never)
        } else {
            self.autocapitalization(.none)
        }
        #else
        self
        #endif
    }
}

#Preview {
    ContentView()
}

