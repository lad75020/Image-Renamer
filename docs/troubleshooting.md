# Troubleshooting

Use this guide when Image Renamer cannot connect to a model server, does not enable the rename button, fails to rename files, or produces unexpected filenames.

## The rename button is disabled

Check the selected engine.

### Ollama or OpenAI API

The button requires:

- At least one selected image.
- No analysis currently running.
- A selected model.

Fix:

1. Select files or a folder with `Choose images…`.
2. Click the model refresh button.
3. Choose a model from the menu.
4. Check that the footer does not show a server error.

### Core ML

The button requires:

- At least one selected image.
- No analysis currently running.
- A loaded Core ML model.

Fix:

1. Choose `Core ML`.
2. Click `Choose…`.
3. Pick a `.mlmodel` or compiled model file.
4. Confirm the model name appears in the sidebar.

## Ollama does not connect

The app calls `GET /api/tags` for both health checks and model listing.

Fix:

1. Start Ollama:

   ```bash
   ollama serve
   ```

2. Verify the endpoint:

   ```bash
   curl http://127.0.0.1:11434/api/tags
   ```

3. Install a vision model if the list is empty:

   ```bash
   ollama pull llava:13b
   ```

4. In the app, set the server to:

   ```text
   http://127.0.0.1:11434
   ```

5. Click refresh and select the model.

## Ollama returns HTTP 500 during image analysis

The analysis loop retries once after two seconds when Ollama returns HTTP 500. If it still fails, the per-file error is shown.

Fix:

- Try a smaller image.
- Use a smaller batch.
- Restart Ollama.
- Use a model with lower memory requirements.
- Watch the Ollama server logs for model loading or memory errors.

## OpenAI-compatible server does not connect

The app calls `GET /v1/models` and expects a response shaped like:

```json
{
  "data": [
    { "id": "model-name" }
  ]
}
```

Fix:

1. Verify the server URL in a terminal:

   ```bash
   curl http://localhost:8887/v1/models
   ```

2. Make sure the app server field points to the base URL, not the full endpoint.
3. Make sure the model list returns IDs.
4. If your server requires authentication, use a local proxy. The current client does not set an authorization header.

## OpenAI-compatible image requests fail

The app sends `POST /v1/chat/completions` with a user message containing:

- A text content part with the filename prompt.
- An image content part with a base64 data URL.
- `stream: false`.

Fix:

- Confirm your server supports image input in chat completions.
- Confirm it accepts data URL images.
- Confirm it returns assistant content as either a string or an array of text parts.
- Confirm the selected model is a vision-capable model.

## The app rejects a server URL

The app accepts only `http` and `https`.

Plain HTTP is allowed only for local, LAN, link-local, Tailscale, and `.local` hosts. Public WAN servers must use HTTPS.

Fix examples:

```text
http://example.com:11434     rejected
https://example.com:11434    accepted
http://192.168.1.10:11434    accepted
http://device-name.ts.net    accepted
```

## No supported images found

The picker can select system image types, but the view model filters by extension.

Supported extensions:

```text
jpg jpeg png gif bmp tif tiff heic heif webp
```

Fix:

- Check that your files use one of those extensions.
- Check that the selected folder is not empty.
- Check that the files are not hidden if selecting a folder. Folder enumeration skips hidden files.
- Disable Force rename only if you want to skip previously renamed files. Enable Force rename if all candidates already contain the selected engine marker.

## Files are skipped as already renamed

The app skips files whose base filename already contains the current engine marker.

Markers:

```text
__OLLAMA__
__OPENAI__
__COREML__
```

Fix:

- Enable `Force rename` to process them again.
- Choose a different engine if you intentionally want a second engine-specific rename.

## HEIC or HEIF processing fails

The app converts HEIC and HEIF to a temporary JPEG for model analysis. It renames the original file afterward.

Fix:

- Make sure macOS can open the HEIC or HEIF file in Preview.
- Try converting a copy to JPEG and rerun.
- Check available disk space in the temporary directory.
- Check the per-file error in the queue or footer.

## Core ML model fails to load

Core ML mode accepts `.mlmodel` files and compiled model files. `.mlmodel` files are compiled before loading.

Fix:

- Confirm the model is a valid Core ML model.
- Prefer an image classification model for best compatibility.
- If the model is compiled, select the compiled model file the app can load.
- Check whether the model accepts an image input. Direct prediction fails if there is no image input.

## Core ML output is generic

`CoreMLDescriber` falls back to `image` when it cannot find a useful classification, string output, `classLabel`, or `classLabelProbs` dictionary.

Fix:

- Use a model with Vision classification outputs.
- Use a model that outputs `classLabel` or `classLabelProbs`.
- Use a model whose string output is a useful caption.

## Translation fails or returns English

For non-English output, the app asks the vision model to answer in the selected language and then may translate the result.

AI translation depends on bundled NLLB Core ML resources. Apple translation depends on the Translation framework and an active translation session.

Fix:

- Open the `Translation debug log` strip and check which path was used.
- Switch translator mode.
- Use English to verify that the engine itself works.
- Confirm the bundled `TranslationModels/` files are present in the app resources.

## Filenames look too short or too plain

The app trims raw output to 120 characters, sanitizes it, and then trims the final base to 60 characters. It removes punctuation that is not a hyphen or underscore.

Fix:

- Adjust the prompt in code if you need more detail.
- Use a stronger vision model.
- Use a language model that follows filename formatting instructions well.

## Duplicate filenames get suffixes

This is expected. If the destination path already exists, the app appends a suffix before the extension.

Example:

```text
cat-on-sofa__OLLAMA__.jpg
cat-on-sofa__OLLAMA__-1.jpg
```

## Build succeeds but logs device warnings

The verified command-line build logged a passcode-protected connected-device warning and still ended with `** BUILD SUCCEEDED **`. Disconnect or unlock the device if you want a quieter build. The warning is not an Image Renamer compile failure.

## Related documents

- [How to configure engines](how-to-configure-engines.md)
- [Reference](reference.md)
- [Architecture](architecture.md)
