# Rename your first batch of images

This tutorial takes you from launching Image Renamer to a renamed image batch. You will use the default local Ollama workflow because it keeps the setup simple and matches the app's default server and model choices.

## What you need

- macOS 26.2 or newer.
- Image Renamer built and launched. If you have not built it yet, follow [How to build and run](how-to-build-and-run.md).
- Ollama installed and running.
- A local vision model available in Ollama. The app default is `llava:13b`.
- A small folder of test images. Use copies first because the app renames files in place.

## Step 1: Start Ollama and install a model

Open Terminal and run:

```bash
ollama serve
```

In another Terminal window, pull a vision model:

```bash
ollama pull llava:13b
```

You now have a local server at `http://127.0.0.1:11434` and a model the app can list through Ollama's `/api/tags` endpoint.

## Step 2: Launch Image Renamer

Build and open the app from Xcode, or use the built Debug app from DerivedData.

The app opens with a sidebar for engine, language, and source selection, plus a workspace that shows preview, progress, and the queue.

## Step 3: Connect to the Ollama engine

1. In the `Inference` section, choose `Ollama`.
2. Set `Server` to `http://127.0.0.1:11434`.
3. Click `Connect` or the refresh button beside the model menu.
4. Choose `llava:13b` or another listed vision model.

If the app cannot connect, it shows the HTTP or decoding error in the footer. See [Troubleshooting](troubleshooting.md#ollama-does-not-connect).

## Step 4: Choose output language

Choose `English` for the first run. English returns the model output without translation.

For French, German, or Spanish, the app asks the vision model to answer in that language and then may run translation if the output still needs it. See [Reference](reference.md#translation).

## Step 5: Select images

Click `Choose images…` or press Command-O.

You can select individual images or a folder. When you pick a folder, the app recursively scans it and keeps files with these extensions:

- jpg, jpeg
- png
- gif
- bmp
- tif, tiff
- heic, heif
- webp

The queue updates with the number of selected images and the formats detected.

## Step 6: Rename the images

Click `Rename N images`.

During processing, the app shows:

- A progress bar and processed count in the workspace header.
- The current image in the focus panel.
- An animated analysis overlay.
- The current queue row.
- Per-file errors when a file cannot be processed.

For each image, the app:

1. Verifies the engine is reachable.
2. Converts HEIC or HEIF to a temporary JPEG for analysis only.
3. Sends image bytes to the selected engine.
4. Sanitizes the returned description.
5. Adds an engine marker.
6. Renames the original file in place.

## Step 7: Check the result

A file named like this:

```text
IMG_1234.HEIC
```

may become:

```text
red-sports-car-on-street__OLLAMA__.heic
```

The original extension is preserved as a lowercase extension. The engine marker tells the app that this file was already renamed by Ollama.

## What you built

You renamed a batch of images using a local AI vision model. You also verified the full app pipeline: selection, engine connection, image analysis, filename sanitation, collision-safe rename, and UI progress.

Next steps:

- Configure other engines in [How to choose and configure an engine](how-to-configure-engines.md).
- Learn the rename rules in [Reference](reference.md#filename-generation-and-renaming).
- Read the architecture in [Architecture](architecture.md).
