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

struct ContentView: View {
    @StateObject private var viewModel = ImageRenamerViewModel()

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Image Renamer")
                    .font(.largeTitle)
                    .bold()

                HStack(spacing: 8) {
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
                }

                HStack(spacing: 8) {
                    Picker("Filename Language", selection: $viewModel.selectedLanguage) {
                        ForEach(FilenameLanguage.allCases) { lang in
                            Text(lang.rawValue).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                }

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
                    .disabled(viewModel.selectedURLs.isEmpty || viewModel.isProcessing)

                    Button {
                        viewModel.cancelAnalysis()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .disabled(!viewModel.isProcessing)
                }

                if viewModel.isProcessing {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(viewModel.processedCount), total: Double(max(viewModel.totalCount, 1)))
                        Text("\(Int((Double(viewModel.processedCount) / Double(max(viewModel.totalCount, 1))) * 100))% • \(viewModel.processedCount) / \(viewModel.totalCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }

                List(selection: .constant(Set<URL>())) {
                    ForEach(viewModel.selectedURLs, id: \.self) { url in
                        HStack(alignment: .top, spacing: 12) {
                            Image(nsImage: NSImage(contentsOf: url) ?? NSImage(size: .zero))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 64, height: 64)
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(url.lastPathComponent)
                                    .font(.headline)
                                    .lineLimit(1)
                                if let proposed = viewModel.results[url] {
                                    Text("→ \(proposed)\n")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                } else {
                                    Text("No proposal yet")
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
                    }
                }
            }
            .task { await viewModel.refreshModels() }
            .padding()
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                Text("How it works")
                    .font(.title2)
                    .bold()
                Text("1. Click ‘Select Images’ to choose local images.\n2. Enter your Ollama server’s IP (e.g., 192.168.1.10) and tap ‘Connect’, or use the default localhost.\n3. Click ‘Analyze’ to send each image to your Ollama server.\n4. Review the proposed names. If auto-rename is enabled, names are applied automatically.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
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

