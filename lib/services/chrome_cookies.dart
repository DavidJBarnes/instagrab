import 'dart:convert';
import 'dart:io';

/// Lifts Instagram session cookies from a Chrome/Chromium profile.
///
/// Linux-only. Unlike Firefox, Chrome stores cookie values encrypted with
/// AES-128-CBC under a key derived from a passphrase held in the OS keyring.
/// This shells out to `secret-tool` (keyring) and `openssl` (PBKDF2 + AES)
/// alongside the `sqlite3` CLI the Firefox jar already relies on — all three
/// ship on any desktop distro, and none of them drag a native plugin into the
/// Flutter build.
class ChromeCookieJar {
  /// Fixed parameters baked into Chrome's Linux `os_crypt`.
  static const _salt = 'saltysalt';
  static const _iterations = 1;
  static const _keyLengthBytes = 16;

  /// Chrome's IV is sixteen 0x20 (space) bytes.
  static const _ivHex = '20202020202020202020202020202020';

  /// Chrome 130+ prefixes the plaintext with a 32-byte SHA-256 of the host
  /// key, which is not part of the cookie value.
  static const _domainHashLength = 32;

  /// Profile roots to search, in preference order. Flatpak installs first —
  /// on a Flatpak-primary desktop the `~/.config` copy is usually a stale
  /// leftover from a native install.
  static List<String> _profileRoots(String home) => [
        '$home/.var/app/com.google.Chrome/config/google-chrome',
        '$home/.config/google-chrome',
        '$home/.var/app/org.chromium.Chromium/config/chromium',
        '$home/.config/chromium',
      ];

  /// Keyring entries to try, paired with the profile roots they belong to.
  static const _keyringApps = ['chrome', 'chromium'];

  /// Reads Instagram cookies from the most recently modified Chrome profile
  /// and returns them as a `Cookie:` header value, or null when Chrome isn't
  /// installed, holds no Instagram session, or its keyring entry is missing.
  ///
  /// Throws [ChromeCookieException] on unexpected tool failures.
  static Future<String?> readInstagramCookieHeader() async {
    final home = Platform.environment['HOME'];
    if (home == null) {
      throw const ChromeCookieException('HOME environment variable not set');
    }

    final dbs = <File>[];
    for (final root in _profileRoots(home)) {
      final db = File('$root/Default/Cookies');
      if (await db.exists()) dbs.add(db);
    }
    if (dbs.isEmpty) return null;

    dbs.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    final password = await _keyringPassword();
    if (password == null) return null;
    final keyHex = await _deriveKeyHex(password);

    for (final db in dbs) {
      final cookies = await _readCookies(db, keyHex);
      if (cookies.containsKey('sessionid')) {
        return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
      }
    }
    return null;
  }

  /// Fetches Chrome's "Safe Storage" passphrase from the login keyring.
  /// Returns null when no entry exists (keyring locked, or Chrome never run).
  static Future<String?> _keyringPassword() async {
    for (final app in _keyringApps) {
      try {
        final result =
            await Process.run('secret-tool', ['lookup', 'application', app]);
        if (result.exitCode == 0) {
          final password = (result.stdout as String).trim();
          if (password.isNotEmpty) return password;
        }
      } on ProcessException {
        throw const ChromeCookieException(
          'secret-tool not found on PATH. Install it with your package '
          'manager (e.g. `sudo dnf install libsecret` or '
          '`sudo apt install libsecret-tools`).',
        );
      }
    }
    return null;
  }

  /// PBKDF2-HMAC-SHA1(password, "saltysalt", 1 iteration, 16 bytes), hex.
  static Future<String> _deriveKeyHex(String password) async {
    final ProcessResult result;
    try {
      result = await Process.run(
        'openssl',
        [
          'kdf',
          '-keylen',
          '$_keyLengthBytes',
          '-kdfopt',
          'digest:SHA1',
          '-kdfopt',
          'pass:$password',
          '-kdfopt',
          'salt:$_salt',
          '-kdfopt',
          'iter:$_iterations',
          'PBKDF2',
        ],
      );
    } on ProcessException {
      throw const ChromeCookieException(
        'openssl not found on PATH. Install it with your package manager '
        '(e.g. `sudo dnf install openssl` or `sudo apt install openssl`).',
      );
    }
    if (result.exitCode != 0) {
      throw ChromeCookieException('openssl kdf failed: ${result.stderr}');
    }
    // `openssl kdf` prints colon-separated hex, e.g. "98:BE:B6:...".
    return (result.stdout as String).trim().replaceAll(':', '').toLowerCase();
  }

  /// Copies the DB (Chrome keeps a WAL lock while running) and decrypts every
  /// instagram.com cookie in it.
  static Future<Map<String, String>> _readCookies(
      File db, String keyHex) async {
    final stem =
        '${Directory.systemTemp.path}/instagrab_chrome_${db.path.hashCode}';
    final tmp = File(stem);
    final tmpWal = File('$stem-wal');
    try {
      await db.copy(tmp.path);
      final wal = File('${db.path}-wal');
      if (await wal.exists()) await wal.copy(tmpWal.path);

      final result = await Process.run('sqlite3', [
        '-separator',
        '\t',
        tmp.path,
        "SELECT name, hex(encrypted_value) FROM cookies "
            "WHERE host_key LIKE '%instagram%';",
      ]);
      if (result.exitCode != 0) {
        throw ChromeCookieException('sqlite3 query failed: ${result.stderr}');
      }

      final out = <String, String>{};
      for (final line in (result.stdout as String).split('\n')) {
        if (line.isEmpty) continue;
        final sep = line.indexOf('\t');
        if (sep < 0) continue;
        final name = line.substring(0, sep);
        final value = await _decrypt(line.substring(sep + 1), keyHex);
        if (value != null) out[name] = value;
      }
      return out;
    } finally {
      for (final f in [tmp, tmpWal]) {
        if (await f.exists()) await f.delete();
      }
    }
  }

  /// Decrypts one `encrypted_value` given as hex. Returns null for values
  /// that aren't in the v10/v11 format (nothing useful to recover).
  static Future<String?> _decrypt(String hex, String keyHex) async {
    final bytes = _fromHex(hex);
    if (bytes.length <= 3) return null;
    final version = ascii.decode(bytes.sublist(0, 3), allowInvalid: true);
    if (version != 'v10' && version != 'v11') return null;

    final tmp = File(
      '${Directory.systemTemp.path}/instagrab_ct_${hex.hashCode}.bin',
    );
    try {
      await tmp.writeAsBytes(bytes.sublist(3), flush: true);
      final result = await Process.run(
        'openssl',
        [
          'enc',
          '-aes-128-cbc',
          '-d',
          '-K',
          keyHex,
          '-iv',
          _ivHex,
          '-nopad',
          '-in',
          tmp.path,
        ],
        stdoutEncoding: null,
      );
      if (result.exitCode != 0) return null;

      var plain = (result.stdout as List<int>);
      if (plain.isEmpty) return null;
      // Strip PKCS#7 padding.
      final pad = plain.last;
      if (pad > 0 && pad <= 16 && pad <= plain.length) {
        plain = plain.sublist(0, plain.length - pad);
      }
      // Chrome 130+ prepends a SHA-256 of the host key.
      if (plain.length > _domainHashLength &&
          plain.take(_domainHashLength).any((b) => b < 0x20 || b > 0x7e)) {
        plain = plain.sublist(_domainHashLength);
      }
      return utf8.decode(plain, allowMalformed: true);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  static List<int> _fromHex(String hex) => [
        for (var i = 0; i + 1 < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ];
}

/// Thrown when reading Chrome cookies fails unexpectedly.
///
/// "No Chrome session" is signalled by a null return from
/// [ChromeCookieJar.readInstagramCookieHeader], not by this exception.
class ChromeCookieException implements Exception {
  final String message;
  const ChromeCookieException(this.message);
  @override
  String toString() => 'ChromeCookieException: $message';
}
