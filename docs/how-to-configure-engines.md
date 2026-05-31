# How to choose and configure an engine

Image Renamer can describe images through three engines. Choose the engine based on where you want inference to happen and what model interface you have available.

## Engine comparison

| Engine | Best for | Server needed | Image bytes leave the app? | Model source |
| --- | --- | --- | --- | --- |
| Ollama | Local vision models | Yes, usually local | Yes, to the configured Ollama server | Ollama model list |
| OpenAI API | Local or remote OpenAI-compatible vision servers | Yes | Yes, to the configured API server | API model list |
| Core ML | On-device image classifiers or image-to-text models | No | No | User-selected Core ML model |

## How to configure Ollama

1. Start Ollama:

   ```bash
   ollama serve
   ```

2. Install a vision model:

   ```bash
   ollama pull llava:13b
   ```

3. In Image Renamer, choose `Ollama`.
4. Set `Server` to:

   ```text
   http://127.0.0.1:11434
   ```

5. Click `Connect` or refresh models.
6. Choose a model from the model menu.

The app calls `GET /api/tags` to list models and `POST /api/generate` to describe each image.

## How to configure an OpenAI-compatible server

1. Start your OpenAI-compatible vision server.
2. Make sure it implements:

   ```text
   GET /v1/models
   POST /v1/chat/completions
   ```

3. In Image Renamer, choose `OpenAI API`.
4. Set `Server` to the base URL, for example:

   ```text
   http://localhost:8887
   ```

5. Click `Connect` or refresh models.
6. Choose a model from the model menu.

The app sends the image as a base64 data URL in a chat completion message. It does not attach an authorization header. If your server requires authentication, put a local trusted proxy in front of it and point the app to that proxy.

## How to configure Core ML

1. In Image Renamer, choose `Core ML`.
2. Click `Choose…`.
3. Select a `.mlmodel` or a compiled Core ML model file.
4. Wait for the model name to appear in the sidebar.
5. Select images and run the rename.

The app compiles `.mlmodel` files when needed, loads the model through Core ML, and attempts to use Vision classification first. If Vision cannot produce a classification, it tries direct model prediction.

## How to choose output language

The app supports four output language choices:

- English
- French
- German
- Spanish

English returns the generated text as-is after filename sanitation.

For the other languages, the app does two things:

1. It adds a language instruction to the vision prompt.
2. It may translate the returned text through the selected translator.

Translator modes:

| Mode | Implementation |
| --- | --- |
| AI model | Bundled NLLB Core ML encoder, decoder, and tokenizer resources in `TranslationModels/` |
| Apple Translate | SwiftUI `translationTask` and Apple's Translation framework when available |

If Apple Translation is not available at compile time, only AI model mode is shown.

## How to configure a non-local server safely

The app enforces a transport policy in `validateTransportPolicy`.

Plain HTTP is allowed for:

- `localhost` and `.localhost`
- `.local` hosts
- `.ts.net` hosts
- IPv4 loopback, private LAN, link-local, and Tailscale CGNAT ranges
- IPv6 loopback, link-local, and unique local ranges

WAN servers must use HTTPS.

Examples:

```text
http://127.0.0.1:11434        allowed
http://192.168.1.10:11434     allowed
http://my-mac.local:11434     allowed
http://device-name.ts.net     allowed
https://example.com:11434     allowed
http://example.com:11434      rejected
```

## Verification

A correctly configured engine enables the rename button when images are selected. Network engines also need a selected model. Core ML needs a loaded model.

If a network engine fails, the footer shows the localized error from the HTTP client. See [Troubleshooting](troubleshooting.md).
