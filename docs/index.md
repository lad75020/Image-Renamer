# Image Renamer documentation

This documentation covers the full Image Renamer application: user workflows, build steps, architecture, engine behavior, internal reference, and troubleshooting.

## Reader paths

### I want to use the app

1. [First rename tutorial](tutorial-first-rename.md)
2. [How to choose and configure an engine](how-to-configure-engines.md)
3. [Troubleshooting](troubleshooting.md)

### I want to build or modify the app

1. [How to build and run](how-to-build-and-run.md)
2. [Architecture](architecture.md)
3. [Reference](reference.md)

### I want exact implementation details

1. [Reference](reference.md)
2. [Architecture](architecture.md)
3. [Troubleshooting](troubleshooting.md)

## Documentation map

| File | Type | What it answers |
| --- | --- | --- |
| [tutorial-first-rename.md](tutorial-first-rename.md) | Tutorial | How do I rename my first batch of images? |
| [how-to-build-and-run.md](how-to-build-and-run.md) | How-to | How do I build and run the macOS app from Xcode or the terminal? |
| [how-to-configure-engines.md](how-to-configure-engines.md) | How-to | How do I configure Ollama, OpenAI-compatible, and Core ML engines? |
| [architecture.md](architecture.md) | Explanation | Why is the app structured this way, and how does data move through it? |
| [reference.md](reference.md) | Reference | What are the public behaviors, supported formats, markers, clients, and defaults? |
| [troubleshooting.md](troubleshooting.md) | How-to | How do I fix common model, network, sandbox, and rename failures? |

## Verified source of truth

The documentation is derived from these project files:

- `Image Renamer/Image_RenamerApp.swift`
- `Image Renamer/ContentView.swift`
- `Image Renamer/ImageRenamerViewModel.swift`
- `Image Renamer/OllamaClient.swift`
- `Image Renamer/OpenAICompatibleClient.swift`
- `Image Renamer/CoreMLDescriber.swift`
- `Image Renamer/CoreMLSupport.swift`
- `Image Renamer/Item.swift`
- `Image Renamer.xcodeproj/project.pbxproj`
- `.github/workflows/objective-c-xcode.yml`
- `Image Renamer/image-renamer-mockup/README.md`

The repository was also indexed with `codebase-memory-mcp`. The refreshed graph contained 369 nodes and 673 edges. The central analysis path is `startAnalysis` calling `analyzeSelected`, which calls engine health checks, image preparation, image data loading, translation, filename sanitation, and file renaming.
