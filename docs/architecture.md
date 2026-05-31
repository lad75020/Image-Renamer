# Architecture

Image Renamer is a single-target SwiftUI macOS app. The UI is intentionally thin: it renders state and forwards user actions. `ImageRenamerViewModel` owns the application workflow: selection, validation, engine configuration, image analysis, translation, progress, and file renaming.

## System overview

```text
User
  |
  v
SwiftUI UI in ContentView.swift
  |  user actions and bindings
  v
ImageRenamerViewModel.swift
  |  selection, validation, analysis loop, rename state
  +-- OllamaClient.swift ------------------> Ollama HTTP API
  +-- OpenAICompatibleClient.swift --------> OpenAI-compatible HTTP API
  +-- CoreMLDescriber.swift ---------------> Core ML and Vision
  +-- TranslationService ------------------> Bundled NLLB Core ML translation models
  +-- Apple Translation task --------------> Translation framework, when available
  |
  v
FileManager moveItem
  |
  v
Renamed original image files
```

## Entry point and persistence shell

`Image_RenamerApp.swift` defines the SwiftUI app entry point. It creates a SwiftData `ModelContainer` with a single `Item` model and injects it into the window group.

The current app workflow does not depend on persisted `Item` records. `Item.swift` is the default timestamp model from a SwiftData app template. The real runtime state is held in `ImageRenamerViewModel` and user preferences are stored in `UserDefaults`.

## UI layer

`ContentView.swift` is the native macOS UI. It is split into small SwiftUI views:

```text
ContentView
  AppLayout
    SidebarView
      SidebarHeader
      InferenceSection
      LanguageSection
      SourceSection
      SidebarFooter
    WorkspaceView
      WorkspaceHeader
      FocusPanel
        ImagePreview
        RenameRow
      QueuePanel
        QueueRow
        QueueThumbnail
      DebugStrip
```

The UI uses local design tokens in the private `T` enum for colors, panels, borders, text, and accent states. The file comments state that the UI was redesigned to match the HTML/CSS mockup in `Image Renamer/image-renamer-mockup/`.

### Sidebar responsibilities

The sidebar lets the user:

- Choose `Ollama`, `OpenAI API`, or `Core ML`.
- Refresh or select a model for network engines.
- Enter and apply a server address for network engines.
- Pick a Core ML model for the Core ML engine.
- Choose output language.
- Choose translation mode.
- Select files or folders.
- Enable Force rename.
- Start or stop analysis.

### Workspace responsibilities

The workspace shows:

- Current folder name.
- Progress count and percentage.
- Current or most recent image preview.
- Original and proposed filename row.
- Queue state for every selected file.
- Translation debug logs.

Image preview and file size loading run in detached tasks so large image reads do not block the main actor.

## View model responsibilities

`ImageRenamerViewModel` is annotated `@MainActor` because it publishes UI state. Heavy work is pushed into detached tasks where needed.

Important state groups:

| State | Purpose |
| --- | --- |
| `selectedURLs` | Images currently shown in the queue. |
| `allCandidateURLs` | All eligible images discovered from the picker. |
| `results` | Proposed base names for currently selected files. |
| `allResults` | Proposed or final base names across the run. |
| `perFileErrors` | Errors keyed by file URL. |
| `processedCount` and `totalCount` | Progress accounting. |
| `engine` | Selected analysis engine. |
| `serverAddress` | Editable server URL for the selected network engine. |
| `availableModels` and `selectedModel` | Model list and selected model for network engines. |
| `selectedLanguage` and `translationMode` | Output language and translation backend. |
| `currentURLBeingProcessed` | Drives focus panel and queue current state. |
| `debugLog` | Translation and model diagnostic log. |

## Analysis workflow

`startAnalysis` creates a cancellable task and calls `analyzeSelected`.

`analyzeSelected` performs the core workflow:

```text
selectedURLs snapshot
  |
  v
partition into supported and unsupported files
  |
  v
set progress and clear previous run state
  |
  v
engine-specific health check or Core ML readiness check
  |
  v
for each supported URL:
  prepareAnalysisImage
  readImageData or describe through Core ML
  ask engine for a short filename description
  maybeTranslate
  sanitizeFilename
  truncate final base to 60 characters
  renameFile, if auto rename is enabled
  update queue, results, errors, and progress
```

The codebase-memory call trace for `analyzeSelected` found direct calls to health checks, `sanitizeFilename`, `isSupportedImage`, `isAlreadyRenamed`, `prepareAnalysisImage`, `readImageData`, `describeImage`, `maybeTranslate`, `renameFile`, and the local `partitioned` helper.

## Engine workflows

### Ollama

`OllamaClient` talks to a server whose default base URL is `http://127.0.0.1:11434`.

- `healthCheck` calls `GET /api/tags`.
- `listModels` decodes `models[].name` from `GET /api/tags`.
- `describeImage` calls `POST /api/generate` with model, prompt, `stream: false`, and one base64 image string.

The analysis loop retries once after a two-second delay when Ollama returns HTTP 500.

### OpenAI-compatible API

`OpenAICompatibleClient` talks to a server whose default base URL is `http://localhost:8887`.

- `healthCheck` calls `listModels`.
- `listModels` decodes `data[].id` from `GET /v1/models`.
- `describeImage` calls `POST /v1/chat/completions` with `stream: false` and a user message containing text plus a data URL image part.

The client accepts response content either as a string or as an array of text parts.

### Core ML

`CoreMLDescriber` loads a compiled model URL and tries two paths:

1. Vision classification through `VNCoreMLModel` and `VNCoreMLRequest`.
2. Direct Core ML prediction with a pixel buffer input.

Direct prediction returns the first useful string output, `classLabel`, the best `classLabelProbs` key, another string-typed output, or finally `image`.

## Translation workflow

Translation runs only when `selectedLanguage` is not English.

```text
Vision model output
  |
  v
maybeTranslate
  +-- AI mode: bundled NLLB Core ML TranslationService
  +-- Apple mode: closure installed by ContentView.translationTask
  |
  v
filename sanitation
```

`TranslationService` supports several model interfaces:

1. Decoder with string source and target language inputs.
2. Decoder with one string input using a target language prefix.
3. Full encoder and decoder greedy decoding with tokenizer resources.

The service loads tokenizer vocabulary, added tokens, merges, special tokens, language token maps, and then logs model input and output descriptions to the debug strip.

## File preparation and renaming

HEIC and HEIF are special. `prepareAnalysisImage` converts them to a temporary JPEG for model input, but returns the original URL as `originalURL`. The temporary file is deleted after analysis. The rename operation always moves the original file.

`renameFile` builds the final destination:

```text
sanitized-base + engine-marker + lowercase-extension
```

If the destination already exists, it appends a numeric suffix before the extension.

Example:

```text
lake-at-sunset__OLLAMA__.jpg
lake-at-sunset__OLLAMA__-1.jpg
lake-at-sunset__OLLAMA__-2.jpg
```

## Security and privacy design

The app uses macOS sandboxing with user-selected file read/write access. Selection happens through `NSOpenPanel`. The view model also includes security-scoped bookmark helpers for explicit folder authorization.

Network server addresses are normalized and checked before use. Plain HTTP is rejected for WAN hosts. This prevents accidental cleartext upload of images to public servers.

Privacy depends on the engine:

- Core ML runs locally.
- Ollama is local by default but can be configured to another allowed host.
- OpenAI-compatible mode sends image data to the configured server.

The OpenAI-compatible client currently has no built-in authorization header support. That keeps the app simple but means authenticated providers need a local proxy.

## Design prototype

The repository includes `Image Renamer/image-renamer-mockup/`, a Claude Design handoff bundle. It contains HTML, CSS, React components, and a screenshot asset. The SwiftUI interface mirrors that prototype through native views and design tokens instead of embedding the web prototype.

## Trade-offs

### Single view model instead of multiple services

Most workflow logic lives in `ImageRenamerViewModel`. This makes the app easy to inspect and keeps UI state transitions in one place. The trade-off is file size and complexity: `ImageRenamerViewModel.swift` also contains the translation service and helper functions, making it the most important file to test before refactoring.

### Engine markers in filenames

Markers prevent accidental repeated renames by the same engine and make provenance visible in Finder. The trade-off is that filenames contain implementation-specific suffixes.

### Temporary JPEG for HEIC and HEIF

Many vision APIs accept JPEG more reliably than HEIC. The app converts only the analysis copy and keeps the original file. The trade-off is temporary disk I/O and possible analysis differences from JPEG conversion.

### OpenAI-compatible without auth headers

The client can work with simple local servers without storing secrets. The trade-off is that hosted APIs usually need a proxy.

## Related documents

- [Reference](reference.md)
- [How to configure engines](how-to-configure-engines.md)
- [Troubleshooting](troubleshooting.md)
