// Quick CLI smoke test: `dart run tool/smoke_extract.dart <instagram-url>`.
// Intentionally not under test/ so `flutter test` ignores it.
import 'package:insta_grab/services/instagram_service.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: dart run tool/smoke_extract.dart <instagram-url>');
    return;
  }
  try {
    final media = await InstagramService.extractMedia(args.first);
    print('Found ${media.length} item(s):');
    for (var i = 0; i < media.length; i++) {
      final m = media[i];
      final dims = m.width != null ? ' ${m.width}x${m.height}' : '';
      final dur = m.durationSeconds != null ? ' ${m.durationSeconds}s' : '';
      print('  [$i] ${m.kind.name}$dims$dur  ${m.url}');
      if (m.thumbnailUrl != null) print('       cover: ${m.thumbnailUrl}');
    }
  } on InstagramExtractionException catch (e) {
    print('EXTRACTION FAILED: ${e.message}');
  }
}
