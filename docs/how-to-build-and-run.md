# How to build and run Image Renamer

This guide shows how to build the macOS app through Xcode and from the terminal, then verify that the app launches from the generated product.

## Prerequisites

- macOS 26.2 or newer.
- Xcode with a macOS SDK compatible with the project. The verified local build used the macOS 26.5 SDK.
- The repository checked out locally.

## Build in Xcode

1. Open the project:

   ```bash
   open "Image Renamer.xcodeproj"
   ```

2. Select the `Image Renamer` scheme.
3. Select `My Mac` as the run destination.
4. Press Command-B to build or Command-R to build and run.

## Build from the terminal

Run this from the repository root:

```bash
xcodebuild -project "Image Renamer.xcodeproj" \
  -scheme "Image Renamer" \
  -configuration Debug \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

Expected success marker:

```text
** BUILD SUCCEEDED **
```

The current repository was verified with this command.

## Find the built app

Ask Xcode where it put the product:

```bash
xcodebuild -project "Image Renamer.xcodeproj" \
  -scheme "Image Renamer" \
  -configuration Debug \
  -showBuildSettings | grep -E 'BUILT_PRODUCTS_DIR|FULL_PRODUCT_NAME'
```

The verified build on this machine produced:

```text
/Volumes/WDBlack4TB/XCodeDerivedData/Build/Products/Debug/Image Renamer.app
```

Open the app with Finder or:

```bash
open "/Volumes/WDBlack4TB/XCodeDerivedData/Build/Products/Debug/Image Renamer.app"
```

Adjust the path if your `BUILT_PRODUCTS_DIR` differs.

## Project settings that matter

| Setting | Value |
| --- | --- |
| Xcode target | `Image Renamer` |
| Shared scheme | `Image Renamer` |
| Bundle identifier | `fr.dubertrand.Image-Renamer` |
| Generated display name | `AI Renames Your Photos` |
| Deployment target | macOS 26.2 |
| Swift version setting | 5.0 |
| App sandbox | Enabled |
| User selected files access | Read/write |
| Generated Info.plist | Enabled |

## Continuous integration

The repository includes `.github/workflows/objective-c-xcode.yml`.

The workflow runs on `push` and `pull_request` for the `master` branch. It chooses the default Xcode target, then runs:

```bash
xcodebuild clean build analyze -scheme "$scheme" -project "Image Renamer.xcodeproj"
```

The workflow pipes output through `xcpretty`, so CI machines need `xcpretty` available.

## Verification

After building, verify these behaviors manually:

1. The app launches.
2. The sidebar appears with `Ollama`, `OpenAI API`, and `Core ML` engine cards.
3. Command-O opens the image picker.
4. Selecting a small folder updates the queue count.
5. The `Rename N images` button is enabled when the selected engine is configured.

## Troubleshooting

### Xcode logs a passcode-protected device warning

The verified command-line build logged a warning about a connected locked device while still ending with `** BUILD SUCCEEDED **`. For macOS builds, this warning is not a failure. Disconnect or unlock the device if you want a cleaner log.

### Code signing fails

For local compile verification, use:

```bash
CODE_SIGNING_ALLOWED=NO
```

For distribution, configure the signing team in Xcode. The project file currently contains a development team setting.

### The app cannot access files after launch

Select files or folders through the app's open panel. The target is sandboxed and uses user-selected read/write file access.
