# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

This repo is **source-only** — it ships `lib/`, `pubspec.yaml`, `analysis_options.yaml`, and a reference `android/app/src/main/AndroidManifest.xml`, but **not** the generated Flutter platform scaffolding (no `linux/`, no `android/` Gradle files, no `ios/`, no `.dart_tool/`). Before anything will build you must bootstrap a Flutter project around these files:

```bash
flutter create insta_grab --platforms=linux,android
# then copy lib/, pubspec.yaml, analysis_options.yaml over the generated ones
# and MERGE the intent-filter + permissions from android/app/src/main/AndroidManifest.xml
# into the generated manifest (do not blindly overwrite — the generated manifest has
# additional <queries> entries and theme references that must stay)
```

The package name in the reference manifest is `com.djb.insta_grab` and must match the `applicationId` Gradle uses after `flutter create`.

## Common commands

```bash
flutter pub get                 # fetch deps
flutter run -d linux            # desktop run (dev)
flutter run -d android          # device/emulator run
flutter analyze                 # lint (uses analysis_options.yaml)
flutter test                    # unit tests in test/ (split-frames tests need ffmpeg)
dart format lib/                # format
```

Dart SDK constraint is `>=3.2.0 <4.0.0`. Lints extend `flutter_lints` and additionally require `prefer_const_constructors` + `prefer_const_declarations`; `avoid_print` is **off** (home_screen.dart uses `print` for per-image download failures — this is intentional).

## Architecture

Single-activity, two-screen Material 3 app. Flow:

```
HomeScreen (URL input)
  └─► InstagramService.extractMedia(url) → List<MediaItem>   ← lib/services/instagram_service.dart
        ├─ Strategy 1: logged-in /api/v1/media/<id>/info/ (browser cookies) → image_versions2 / video_versions
        ├─ Strategy 2: public post page → embedded JSON, then og:video/og:image, then .mp4 CDN URLs
        └─ Strategy 3: public {url}embed/captioned/ → parsed the same way
  └─► (tiktok.com URL) TikTokService.extractMedia(url) → TikTokPost      ← lib/services/tiktok_service.dart
        └─ public post page → __UNIVERSAL_DATA_FOR_REHYDRATION__ (or SIGI_STATE) JSON → imagePost photos, else bitrateInfo video
  └─► per item: ImageService.downloadImage → LibraryService.add          (images)
                VideoService.downloadVideo (streamed) → LibraryService.addVideo  (videos)
      and a verbatim copy of each original into the save path
  └─► EditorScreen(initialImageId)  — library rail (videos carry a play badge)
        ├─ image: Crop mode (crop_your_image) / Resize mode (image pkg copyResize)
        │     └─► ImageService.saveImage → save path
        └─ video: cover-frame preview + Save video (VideoService.saveVideo, a file copy)
                  + Split frames (VideoService.splitFrames → system ffmpeg)
```

Key invariants to preserve when editing:

- **`InstagramService` is 100% static** (no instance state) and pure-Dart. All strategies live in this one file and run sequentially — short-circuit on first non-empty result. When adding a strategy, chain it onto `extractMedia` in the same "return if non-empty, otherwise continue" pattern and throw `InstagramExtractionException` only after all strategies fail (the logged-in strategy's error is the one surfaced). The parsers `mediaFromApiItem` / `mediaFromHtml` are public and tested against `test/fixtures/`.
- **Extraction returns `MediaItem`s** (`lib/models/media_item.dart`): image or video, with a cover `thumbnailUrl`, dimensions and duration for videos. For videos the highest-resolution entry of `video_versions` wins — those are progressive mp4s with audio muxed in; never use the DASH manifest or `bytestart=` segment URLs.
- **Videos are never decoded or re-encoded.** `VideoService` streams them to `<name>.part`, checks the `ftyp` header, renames, and exports by file copy. No native video plugins — the editor shows the cover frame, and on Linux "Open in video player" just runs `xdg-open`.
- **The one exception is "Split frames"** (video info pane): `VideoService.splitFrames` shells out to the system `ffmpeg` to write every 4th frame as a lossless PNG into `<save path>/<shortcode>_<i>_frames/`, named by source frame number (`_f000004.png`). It is a subprocess, not a plugin; a missing ffmpeg surfaces as `FrameSplitException`.
- **"Clear library"** (editor AppBar, confirmed) is `LibraryService.clear()`: deletes every file in the library dir, index included. Exports are untouched.
- **Library entries carry a `kind`** (`LibraryImage.kind`); index entries written before video support have none and load as images. A video entry's `filename` is the `.mp4` and `thumbnailFilename` its cover. Crop/resize/Wanly upload are image-only.
- **`ImageService` uses only `package:image`** (pure Dart) for decode/resize/encode — no native codecs. This is the reason the app builds for Linux desktop with no extra plugin work. Don't introduce platform-channel image libs.
- **Output directory is platform-branched** in `ImageService.getOutputDirectory` (Android: `/storage/emulated/0/Download/InstaGrab`, Linux: `$HOME/Pictures/InstaGrab`, else: app documents). The Android manifest declares legacy external storage + `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` to support this hardcoded path.
- **`DownloadedImage` is defined in `home_screen.dart`** (not in a model file) and imported by `editor_screen.dart`. `EditorScreen` holds the post-edit bytes in `_croppedBytes`; `null` means "show original". `_updateImageInfo` must be called after any op that changes `_activeBytes` so the width/height fields and `_originalAspect` stay in sync.
- **The `Crop` widget is rebuilt via a ValueKey** combining index + aspect ratio + cropped-bytes length. Changing any of these without updating that key will silently leave stale crop state.

## Instagram extraction caveats

Instagram actively rate-limits and, for unauthenticated clients, now almost always returns an empty JS shell (~640 KB, no media JSON or og tags) for both the post and embed pages — in practice only the cookie strategy works today. The layered strategy exists because each one fails independently — do not collapse them. When debugging extraction failures, log the HTTP status and body length from `_fetchAndParse` before adding new parsers; most "no images found" failures are 200s with a login wall rather than parser bugs.

The regex in `_extractUrlsFromScriptText` filters URLs >500 chars (Instagram CDN URLs with very long query strings are usually tracking pixels, not the full-resolution image). Adjust with care.

## TikTok

`TikTokService` is static and pure Dart, like `InstagramService`, and needs no login: the public video page embeds the post JSON. The clean files in `video.bitrateInfo` (any H.264 file beats any H.265 one, since stock Fedora VLC/ffmpeg can't decode HEVC; then highest resolution) return 403 unless the request carries the `tt_chain_token` cookie that the page fetch set, plus a `tiktok.com` Referer. Those headers travel on `MediaItem.headers` into `VideoService.downloadVideo`. Never use `downloadAddr`, which is the watermarked copy. Library entries use `tt_<videoId>` as their `shortcode`. Short links (`vm.tiktok.com`, `/t/`) are resolved by following the redirect. Photo (slideshow) posts (`/photo/<id>`) are fetched via `/@user/video/<id>` (`fetchUrlFor`) because the `/photo/` page has no post data. They yield one image per `imagePost.images[]`, preferring a JPEG/PNG/WebP URL over HEIC; their background music is not fetched.

## Share intent (Android)

The reference manifest registers an `ACTION_SEND` / `text/plain` intent filter so Instagram's "Share → InstaGrab" flow delivers the URL as shared text. **The Dart side does not currently consume this intent** — `HomeScreen` only reads the clipboard via the paste button. If you add share-intent handling, wire it through `share_plus` in `initState` and populate `_urlController` before the first frame.
