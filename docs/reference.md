# Reference

This reference describes the public behavior and important internal interfaces of Image Renamer.

## App target

| Item | Value |
| --- | --- |
| Project | `Image Renamer.xcodeproj` |
| Target | `Image Renamer` |
| Scheme | `Image Renamer` |
| Bundle identifier | `fr.dubertrand.Image-Renamer` |
| Display name | `AI Renames Your Photos` |
| Deployment target | macOS 26.2 |
| Swift version setting | 5.0 |
| Sandbox | Enabled |
| User-selected file access | Read/write |

## Supported image extensions

The view model accepts these extensions after lowercasing:

| Extension group | Values |
| --- | --- |
| JPEG | `jpg`, `jpeg` |
| PNG | `png` |
| GIF | `gif` |
| Bitmap | `bmp` |
| TIFF | `tif`, `tiff` |
| HEIC or HEIF | `heic`, `heif` |
| WebP | `webp` |

## Analysis engines

| Engine enum case | UI label | Marker | Server needed | Default server |
| --- | --- | --- | --- | --- |
| `ollama` | `Ollama` | `__OLLAMA__` | Yes | `http://127.0.0.1:11434` |
| `openAICompatible` | `OpenAI API` | `__OPENAI__` | Yes | `http://localhost:8887` |
| `coreml` | `Core ML` | `__COREML__` | No | Not applicable |

## Languages

| Enum case | UI label | Short code |
| --- | --- | --- |
| `english` | `English` | `EN` |
| `french` | `French` | `FR` |
| `german` | `German` | `DE` |
| `spanish` | `Spanish` | `ES` |

## Translation modes

| Enum case | UI label | Availability |
| --- | --- | --- |
| `ai` | `AI model` | Always shown by app logic |
| `apple` | `Apple Translate` | Shown only when the Translation framework can be imported |

## Filename generation and renaming

### Prompt

`startAnalysis` uses this default prompt:

```text
Provide a descriptive filename for this image without file extension in less than 10 words, separated with a dash.
```

`analyzeSelected` has a similar default prompt without the comma before `separated`.

Before calling a network model, the app appends:

```text
Respond in the selected language.
```

### Sanitizing

`sanitizeFilename` applies these rules:

1. Lowercase the input.
2. Keep alphanumeric characters, hyphen, underscore, and spaces.
3. Replace all other Unicode scalars with spaces.
4. Replace newlines and tabs with spaces.
5. Collapse whitespace-separated components with a single space.
6. Replace spaces with hyphens.
7. Return `image` if the result is empty.

The analysis loop trims raw model output to 120 characters before sanitation and then trims the sanitized base to 60 characters.

### Markers

Before moving the file, `renameFile` appends the selected engine marker unless the base already contains it.

Examples:

```text
red-dog-running__OLLAMA__.jpg
red-dog-running__OPENAI__.jpg
red-dog-running__COREML__.jpg
```

### Extensions

The file extension is preserved from the original URL and lowercased in the destination.

### Duplicate names

If a destination already exists, `renameFile` appends a numeric suffix:

```text
red-dog-running__OLLAMA__.jpg
red-dog-running__OLLAMA__-1.jpg
red-dog-running__OLLAMA__-2.jpg
```

## Already-renamed detection

A file is considered already renamed for the selected engine when its base filename contains that engine's marker. Force rename disables this check.

Example: in Ollama mode, this file is skipped unless Force rename is enabled:

```text
red-dog-running__OLLAMA__.jpg
```

The same file is not skipped by OpenAI API mode unless it also contains `__OPENAI__`.

## Server address normalization

`normalizeServerAddress`:

- Trims whitespace.
- Adds `http://` if no scheme is present.
- Adds the engine default port if no port is present.
- Returns a `URL` or nil.

Default ports:

| Engine | Port |
| --- | --- |
| Ollama | 11434 |
| OpenAI-compatible | 8887 |

## Transport policy

`validateTransportPolicy` allows only `http` and `https` schemes.

HTTPS is always accepted. Plain HTTP is accepted only for allowed local or private hosts.

Allowed HTTP hosts include:

- `localhost`
- names ending in `.localhost`
- names ending in `.local`
- names ending in `.ts.net`
- IPv4 loopback `127.0.0.0/8`
- IPv4 private ranges `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
- IPv4 link-local `169.254.0.0/16`
- Tailscale CGNAT `100.64.0.0/10`
- IPv6 loopback `::1`
- IPv6 link-local starting with `fe80:`
- IPv6 unique local starting with `fc` or `fd`

Rejected HTTP WAN servers show:

```text
HTTPS is required for WAN servers. Plain HTTP is allowed only for localhost, LAN, or Tailscale addresses.
```

## Ollama client

Source: `Image Renamer/OllamaClient.swift`

### Types

| Type | Purpose |
| --- | --- |
| `OllamaClientError` | Localized errors for invalid responses, HTTP status failures, and decoding failures. |
| `OllamaGenerateRequest` | Encodes `model`, `prompt`, `stream`, and base64 `images`. |
| `OllamaGenerateResponse` | Decodes the `response` string. |
| `OllamaClient` | Performs health checks, model listing, and image description. |

### Methods

| Method | Behavior |
| --- | --- |
| `healthCheck()` | Sends `GET /api/tags` and requires a 2xx response. |
| `listModels()` | Sends `GET /api/tags` and returns `models[].name`. |
| `describeImage(data:prompt:model:)` | Sends `POST /api/generate` with one base64 image and returns trimmed `response`. |

### Large payload warning

In Debug builds, `describeImage` prints a warning when the base64 image payload exceeds about 10 MB.

## OpenAI-compatible client

Source: `Image Renamer/OpenAICompatibleClient.swift`

### Types

| Type | Purpose |
| --- | --- |
| `OpenAICompatibleClientError` | Localized errors for invalid responses, HTTP status failures, decoding failures, and missing content. |
| `OpenAIModelListResponse` | Decodes `data[].id`. |
| `OpenAIChatCompletionsRequest` | Encodes model, messages, content parts, image data URL, and `stream: false`. |
| `OpenAIChatCompletionsResponse` | Decodes assistant content as either a string or text parts. |
| `OpenAICompatibleClient` | Performs health checks, model listing, and image description. |

### Methods

| Method | Behavior |
| --- | --- |
| `healthCheck()` | Calls `listModels()`. |
| `listModels()` | Sends `GET /v1/models` and returns model IDs. |
| `describeImage(data:imageURL:prompt:model:)` | Sends `POST /v1/chat/completions` with text and image content parts. |
| `mimeType(for:)` | Maps image file extensions to MIME types for data URLs. |

### MIME type mapping

| Extension | MIME type |
| --- | --- |
| `jpg`, `jpeg` | `image/jpeg` |
| `png` | `image/png` |
| `gif` | `image/gif` |
| `webp` | `image/webp` |
| `heic`, `heif` | `image/heic` |
| `bmp` | `image/bmp` |
| `tif`, `tiff` | `image/tiff` |
| anything else | `application/octet-stream` |

## Core ML describer

Source: `Image Renamer/CoreMLDescriber.swift`

### Main type

`CoreMLDescriber` is a `nonisolated final class` that loads an `MLModel` from a compiled model URL.

### Description flow

1. Load an `NSImage` from the image URL.
2. Convert it to `CGImage`.
3. Try Vision classification through `VNCoreMLRequest`.
4. Fall back to direct Core ML prediction.
5. Return a useful label or `image`.

### Direct prediction fallback order

1. First non-empty string output.
2. `classLabel` string.
3. Best key from `classLabelProbs` dictionary.
4. Any non-empty string-typed output.
5. `image`.

## Translation service

Source: `Image Renamer/ImageRenamerViewModel.swift`

`TranslationService` is compiled only when Core ML is available.

### Bundled resources

The project includes:

```text
Image Renamer/TranslationModels/NLLB_Encoder_256.mlmodelc
Image Renamer/TranslationModels/NLLB_Decoder_256.mlmodelc
Image Renamer/TranslationModels/tokenizer/tokenizer.json
Image Renamer/TranslationModels/tokenizer/tokenizer_config.json
Image Renamer/TranslationModels/tokenizer/special_tokens_map.json
Image Renamer/TranslationModels/tokenizer/sentencepiece.bpe.model
```

### Language token defaults

| Language | Default token |
| --- | --- |
| English | `__eng_Latn__` |
| French | `__fra_Latn__` |
| German | `__deu_Latn__` |
| Spanish | `__spa_Latn__` |

The service can override these through `lang_tokens.json` or `language_codes.json` if present.

### Translation fallback order

1. Decoder string input with a target language string input.
2. Single string input with a target token prefix.
3. Greedy encoder-decoder decoding with tokenizer IDs, attention masks, hidden states, and logits.

## Security-scoped folder helpers

`ImageRenamerViewModel` includes macOS-only helpers:

| Method | Purpose |
| --- | --- |
| `authorizeFolderAccess()` | Opens an `NSOpenPanel`, stores a security-scoped bookmark in `UserDefaults`. |
| `resolveAuthorizedFolder()` | Resolves the stored bookmark and refreshes stale bookmark data. |
| `withAuthorizedFolderAccess(_:)` | Starts security-scoped access, runs a closure, and stops access. |

These helpers are present for folder authorization workflows. The primary picker already uses user-selected file access.

## Build workflow reference

The GitHub Actions workflow is `.github/workflows/objective-c-xcode.yml`.

Triggers:

- Push to `master`.
- Pull request targeting `master`.

Build command:

```bash
xcodebuild clean build analyze -scheme "$scheme" -project "Image Renamer.xcodeproj" | xcpretty
```

## Related documents

- [Architecture](architecture.md)
- [How to configure engines](how-to-configure-engines.md)
- [Troubleshooting](troubleshooting.md)
