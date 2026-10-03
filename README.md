# InstaGrab

Download Instagram images and videos from share URLs, and crop and resize the images. Flutter app targeting Linux desktop and Android.

## Features

- **URL Input** — Paste any Instagram post/reel/TV share URL
- **Multi-image support** — Carousel posts download all images with thumbnail strip navigation
- **Video download** — Reels, video posts and video frames in carousels are saved as the original `.mp4` (highest resolution, with audio, never re-encoded); they show in the strip with a play badge
- **Interactive crop** — Drag-to-crop with aspect ratio presets (Free, 1:1, 4:5, 16:9, 9:16, 4:3, 3:2)
- **Resize** — Manual width/height input with aspect ratio lock, plus quick presets (1080×1080, 1080×1350, etc.)
- **Save** — Export as PNG or JPEG to ~/Pictures/InstaGrab (Linux) or Downloads/InstaGrab (Android)
- **Share intent** — Android share sheet integration (share from Instagram → InstaGrab)

## Setup

```bash
# Clone/copy the lib/ directory and pubspec.yaml into a new Flutter project:
flutter create insta_grab --platforms=linux,android
# Then replace lib/ and pubspec.yaml with these files

# Or if starting fresh, copy everything and run:
cd insta_grab
flutter pub get
flutter run -d linux    # Linux desktop
flutter run -d android  # Android device/emulator
```

## Architecture

```
lib/
├── main.dart                    # App entry, theme
├── models/
│   └── media_item.dart          # Extracted image | video (+ cover, size, duration)
├── screens/
│   ├── home_screen.dart         # URL input, extraction + download flow
│   ├── editor_screen.dart       # Library rail, crop + resize UI, video preview/save
│   └── settings_screen.dart     # Save path, image format, Wanly
├── services/
│   ├── instagram_service.dart   # URL parsing, media extraction strategies
│   ├── image_service.dart       # Download, resize, encode, save images
│   ├── video_service.dart       # Stream-download and save videos (no re-encode)
│   ├── library_service.dart     # On-disk library of grabbed media
│   └── ...                      # Browser-cookie readers, settings
```

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `http` | HTTP requests for page fetching and image download |
| `html` | HTML parsing for og:image meta tag extraction |
| `crop_your_image` | Pure-Dart interactive crop widget (no native deps) |
| `image` | Cross-platform image decode/resize/encode |
| `path_provider` | Platform-appropriate file paths |
| `share_plus` | Share intent handling |

## Instagram Extraction Strategy

The service uses multiple fallback strategies:
1. Logged-in `/api/v1/media/<id>/info/` using your browser's Instagram cookies → `image_versions2` / `video_versions`
2. Public post page → embedded JSON (`video_url`, `display_url`), then `og:video` / `og:image`, then any `.mp4` URL on `cdninstagram.com` / `fbcdn.net`
3. Public `/embed/captioned/` page → parsed the same way

Try one from the command line with `dart run tool/smoke_extract.dart <url>`.

## Notes

- Instagram may rate-limit or block requests from certain IPs. If extraction fails, retry after a moment.
- Private posts cannot be accessed.
- The Android manifest includes a share intent filter so you can share directly from Instagram to InstaGrab.
- The `AndroidManifest.xml` provided here is a reference — after `flutter create`, merge the permissions and intent filters into the generated manifest.
