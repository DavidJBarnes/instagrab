/// Whether a piece of grabbed media is a still image or a video.
enum MediaKind { image, video }

/// One downloadable piece of media extracted from an Instagram or TikTok
/// post.
///
/// A single-image post yields one image item, a reel or video post yields
/// one video item, and a carousel yields one item per frame in post order —
/// which may mix images and videos.
class MediaItem {
  final MediaKind kind;

  /// Direct CDN URL of the full-resolution image, or of the progressive mp4
  /// (video and audio in one file) for a video.
  final String url;

  /// Cover-frame image URL. Always null for images; usually present for
  /// videos, which is what the UI shows in place of a player.
  final String? thumbnailUrl;

  /// Pixel dimensions when the source reports them.
  final int? width;
  final int? height;

  /// Length in seconds for videos, when the source reports it.
  final double? durationSeconds;

  /// Extra HTTP headers the CDN requires to serve [url], or null. TikTok's
  /// CDN refuses requests without the page's session cookie and a Referer.
  final Map<String, String>? headers;

  const MediaItem({
    required this.kind,
    required this.url,
    this.thumbnailUrl,
    this.width,
    this.height,
    this.durationSeconds,
    this.headers,
  });

  const MediaItem.image(
    this.url, {
    this.width,
    this.height,
    this.headers,
  })  : kind = MediaKind.image,
        thumbnailUrl = null,
        durationSeconds = null;

  const MediaItem.video(
    this.url, {
    this.thumbnailUrl,
    this.width,
    this.height,
    this.durationSeconds,
    this.headers,
  }) : kind = MediaKind.video;

  bool get isVideo => kind == MediaKind.video;

  @override
  String toString() => 'MediaItem(${kind.name}, '
      '${width ?? '?'}x${height ?? '?'}'
      '${durationSeconds != null ? ', ${durationSeconds}s' : ''}, $url)';
}
