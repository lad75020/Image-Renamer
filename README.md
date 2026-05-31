# Image Renamer

Image Renamer is a native macOS app that renames batches of photos from what an AI vision model sees in each image. It can use a local Ollama vision model, an OpenAI-compatible vision server, or a user-selected Core ML image model. It preserves the original file extension, adds an engine marker to prevent accidental repeat processing, and shows progress, preview, queue, errors, and translation debug output while it works.

The app target is named `Image Renamer`; the generated app display name is `AI Renames Your Photos`.

## What it does

- Picks individual image files or whole folders from a sandboxed macOS open panel.
- Recursively finds supported image files in selected folders.
- Skips files already renamed by the selected engine unless Force rename is enabled.
- Sends each image to one of three engines: Ollama, OpenAI-compatible API, or Core ML.
- Converts HEIC and HEIF to a temporary JPEG only for analysis, then renames the original HEIC or HEIF file.
- Sanitizes AI output into safe, lowercase, hyphen-separated file names.
- Adds `__OLLAMA__`, `__OPENAI__`, or `__COREML__` to each renamed file.
- Translates generated names to English, French, German, or Spanish through either bundled Core ML translation models or Apple Translation when available.
- Handles duplicate target names by adding numeric suffixes.

## Documentation

Start here:

- [Documentation index](docs/index.md)
- [First rename tutorial](docs/tutorial-first-rename.md)
- [How to build and run](docs/how-to-build-and-run.md)
- [How to choose and configure an engine](docs/how-to-configure-engines.md)
- [Architecture](docs/architecture.md)
- [Reference](docs/reference.md)
- [Troubleshooting](docs/troubleshooting.md)

## Requirements

- macOS 26.2 or newer, based on the project deployment target.
- Xcode with a macOS SDK compatible with the project. The current repository was verified with Xcode using the macOS 26.5 SDK.
- Apple Silicon is recommended for Core ML and local model workflows.
- Optional for Ollama mode: an Ollama server with a vision model, for example `llava:13b`.
- Optional for OpenAI API mode: an OpenAI-compatible server that implements model listing and chat completions with image input.
- Optional for Core ML mode: an image classification or image-to-text Core ML model.

## Installation and local development

### 1. Clone the repository

```bash
git clone https://github.com/lad75020/Image-Renamer.git
cd Image-Renamer
```

### 2. Open the project in Xcode

```bash
open "Image Renamer.xcodeproj"
```

In Xcode, choose the `Image Renamer` scheme and run it on `My Mac`.

### 3. Build from the command line

This command was run successfully against the current repository:

```bash
xcodebuild -project "Image Renamer.xcodeproj" \
  -scheme "Image Renamer" \
  -configuration Debug \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

Expected result:

```text
** BUILD SUCCEEDED **
```

Xcode may also log warnings about a locked iOS device if one is connected. Those warnings do not block the macOS build.

### 4. Run the built app

After a Debug build, the app is under Xcode DerivedData. On this machine the verified build output was:

```text
/Volumes/WDBlack4TB/XCodeDerivedData/Build/Products/Debug/Image Renamer.app
```

If your DerivedData path differs, ask Xcode for build settings:

```bash
xcodebuild -project "Image Renamer.xcodeproj" \
  -scheme "Image Renamer" \
  -configuration Debug \
  -showBuildSettings | grep -E 'BUILT_PRODUCTS_DIR|FULL_PRODUCT_NAME'
```

Then open the app from the reported product directory.

### 5. Configure an engine

For Ollama:

```bash
ollama serve
ollama pull llava:13b
```

In the app, choose `Ollama`, set the server to `http://127.0.0.1:11434`, refresh models, then choose a model.

For an OpenAI-compatible local server, start your server, choose `OpenAI API`, set the server URL, refresh models, then choose a model.

For Core ML, choose `Core ML`, click `Choose…`, then select a `.mlmodel` or compiled model file.

## Quick start

1. Launch the app.
2. Choose the inference engine.
3. Connect or choose a model if the engine needs it.
4. Select English, French, German, or Spanish as the output language.
5. Click `Choose images…` or press Command-O.
6. Select image files or a folder.
7. Click `Rename N images`.
8. Watch the progress bar, focus preview, and queue.

## Supported image formats

The picker accepts system image types. The view model filters by extension:

- JPG and JPEG
- PNG
- GIF
- BMP
- TIF and TIFF
- HEIC and HEIF
- WebP

## Safety notes

The app is sandboxed and has user-selected file read/write access. It can rename files only after the user selects them through the open panel or grants folder access.

Network engines send image bytes to the configured server. Core ML mode runs on device. Ollama mode is local by default, but it can point to another allowed HTTP or HTTPS host. OpenAI-compatible mode has no built-in API key header support in this codebase; use a trusted local proxy if your server requires authentication.

Plain HTTP is accepted only for localhost, LAN, link-local, Tailscale, and `.local` hosts. WAN servers must use HTTPS.

## Project structure

```text
Image Renamer.xcodeproj/              Xcode project and shared scheme
Image Renamer/Image_RenamerApp.swift  SwiftUI app entry point and SwiftData container
Image Renamer/ContentView.swift       Native macOS UI
Image Renamer/ImageRenamerViewModel.swift  Selection, engine orchestration, translation, renaming
Image Renamer/OllamaClient.swift      Ollama HTTP client
Image Renamer/OpenAICompatibleClient.swift OpenAI-compatible HTTP client
Image Renamer/CoreMLDescriber.swift   Core ML and Vision image description helper
Image Renamer/TranslationModels/      Bundled NLLB Core ML translation resources
Image Renamer/image-renamer-mockup/   HTML/CSS/React design prototype
.github/workflows/objective-c-xcode.yml GitHub Actions build workflow
```

## Verification status

Current documentation was generated after indexing the repository with `codebase-memory-mcp` and reading the Swift source, project file, workflow, and design handoff. The app was built successfully with `xcodebuild` using the `Image Renamer` scheme.

There are no automated test targets in the Xcode project at the time of writing.
