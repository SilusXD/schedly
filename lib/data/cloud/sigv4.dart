import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Статические учётные данные для подписи AWS Signature Version 4.
///
/// [sessionToken] заполняется только для временных креденшелов
/// (STS / IAM role). При его наличии заголовок `x-amz-security-token`
/// включается и в запрос, и в список подписанных заголовков.
class AwsCredentials {
  const AwsCredentials({
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
  });

  /// Публичный идентификатор ключа доступа (`AKIA...`).
  final String accessKeyId;

  /// Секретный ключ. Никогда не попадает в заголовки и логи.
  final String secretAccessKey;

  /// Временный токен сессии, если используются временные креденшелы.
  final String? sessionToken;
}

/// Промежуточные значения подписи: удобно для отладки и для тестов,
/// сверяющих канонический запрос и string-to-sign с эталоном AWS.
class SigV4DebugInfo {
  const SigV4DebugInfo({
    required this.canonicalRequest,
    required this.stringToSign,
    required this.signature,
    required this.signedHeaders,
    required this.amzDate,
  });

  /// Канонический запрос — пять строк по спецификации AWS SigV4.
  final String canonicalRequest;

  /// Строка, которую фактически подписывает HMAC.
  final String stringToSign;

  /// Подпись в hex (нижний регистр).
  final String signature;

  /// Список подписанных заголовков через `;` в порядке сортировки.
  final String signedHeaders;

  /// Значение `x-amz-date` в формате `yyyyMMdd'T'HHmmss'Z'` (UTC).
  final String amzDate;
}

/// Подписывает HTTP-запросы алгоритмом AWS Signature Version 4
/// (`AWS4-HMAC-SHA256`) с заголовком `Authorization`.
///
/// Совместим с Amazon S3, Yandex Object Storage, MinIO и другими
/// S3-совместимыми реализациями. Зависимостей, кроме `dart:*` и
/// `package:crypto`, нет.
///
/// Реализация детерминирована: при одинаковом наборе аргументов (включая
/// [DateTime] внутри `timestamp`) результат всегда побайтово одинаков.
/// Текущее время читается только тогда, когда `timestamp` не передан.
class AwsSigV4Signer {
  /// Создаёт подписывающее устройство.
  ///
  /// [clock] подменяется в тестах; по умолчанию используется UTC-время
  /// системы. Функция вызывается только при `timestamp == null`.
  AwsSigV4Signer({
    required this.credentials,
    required this.region,
    this.service = 's3',
    DateTime Function()? clock,
  }) : _clock = clock ?? _systemClock;

  /// Креденшелы, которыми подписываются запросы.
  final AwsCredentials credentials;

  /// Регион подписи, например `ru-central1` для Yandex Object Storage.
  final String region;

  /// Имя сервиса в credential scope; для S3-совместимых хранилищ — `s3`.
  final String service;

  /// Функция текущего времени (UTC) — используется, если `timestamp` не задан.
  final DateTime Function() _clock;

  static const String _algorithm = 'AWS4-HMAC-SHA256';
  static const String _requestSuffix = 'aws4_request';

  /// Символы, которые RFC3986 считает unreserved и потому не кодирует.
  static const String _unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~';

  /// Заголовки, которыми управляет подписывающее устройство: их нельзя
  /// передать снаружи, иначе в запросе окажутся два разных значения.
  static const Set<String> _managedHeaders = {
    'host',
    'x-amz-date',
    'x-amz-content-sha256',
    'x-amz-security-token',
    'authorization',
  };

  static final RegExp _whitespaceRun = RegExp(r'\s+');

  static DateTime _systemClock() => DateTime.now().toUtc();

  /// Подписывает запрос и возвращает полный набор заголовков:
  /// исходные + `Host`, `x-amz-date`, `x-amz-content-sha256`
  /// (+ `x-amz-security-token`, если есть токен сессии) + `Authorization`.
  ///
  /// [method] — HTTP-метод (`GET`, `PUT`, `HEAD`, `DELETE`, `POST`, ...),
  /// регистр не важен: в каноническом запросе он всегда верхний.
  ///
  /// [uri] — абсолютный URL, включая path и query. Хост (с нестандартным
  /// портом, если он есть) попадает в подписанный заголовок `Host`.
  ///
  /// [headers] — дополнительные заголовки (например `content-type`).
  /// Все они, кроме `authorization`, попадают в список подписанных.
  /// `host`/`x-amz-date`/`x-amz-content-sha256`, переданные здесь,
  /// переопределяются: `host` берётся как есть, остальные вычисляются.
  ///
  /// [payload] — тело запроса; `null` означает пустое тело.
  ///
  /// [timestamp] — момент подписи; если `null`, берётся из `clock`.
  Map<String, String> sign({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    Uint8List? payload,
    DateTime? timestamp,
  }) {
    final computation = _compute(
      method: method,
      uri: uri,
      headers: headers,
      payload: payload,
      timestamp: timestamp,
    );

    final result = <String, String>{};
    headers.forEach((key, value) {
      if (_managedHeaders.contains(key.toLowerCase())) return;
      result[key] = value;
    });
    result['Host'] = computation.host;
    result['x-amz-date'] = computation.amzDate;
    result['x-amz-content-sha256'] = computation.payloadHash;
    final token = computation.securityToken;
    if (token != null) {
      result['x-amz-security-token'] = token;
    }
    result['Authorization'] = computation.authorization;
    return result;
  }

  /// Возвращает канонический запрос, string-to-sign и подпись, ничего
  /// не изменяя. Результат совпадает с тем, что использует [sign].
  SigV4DebugInfo debugCanonicalRequest({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    Uint8List? payload,
    DateTime? timestamp,
  }) {
    final computation = _compute(
      method: method,
      uri: uri,
      headers: headers,
      payload: payload,
      timestamp: timestamp,
    );
    return SigV4DebugInfo(
      canonicalRequest: computation.canonicalRequest,
      stringToSign: computation.stringToSign,
      signature: computation.signature,
      signedHeaders: computation.signedHeaders,
      amzDate: computation.amzDate,
    );
  }

  /// Единственная точка, где считаются все значения подписи.
  ///
  /// Если [timestamp] не передан, текущее время читается через `_clock`
  /// ровно один раз — дальше подпись полностью детерминирована.
  _SigV4Computation _compute({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required Uint8List? payload,
    required DateTime? timestamp,
  }) {
    final amzDate = _formatAmzDate(timestamp ?? _clock());
    final dateStamp = amzDate.substring(0, 8);
    final payloadHash = _hexSha256(payload ?? Uint8List(0));

    // Канонические заголовки: строчные имена, всё, кроме Authorization.
    final canonicalHeaders = <String, String>{};
    headers.forEach((key, value) {
      final name = key.toLowerCase();
      if (name == 'authorization') {
        return;
      }
      canonicalHeaders[name] = value;
    });
    canonicalHeaders.putIfAbsent('host', () => _hostHeader(uri));
    canonicalHeaders['x-amz-date'] = amzDate;
    canonicalHeaders['x-amz-content-sha256'] = payloadHash;
    final sessionToken = credentials.sessionToken;
    if (sessionToken != null && sessionToken.isNotEmpty) {
      canonicalHeaders['x-amz-security-token'] = sessionToken;
    }

    final names = canonicalHeaders.keys.toList()..sort();
    final headerBlock = StringBuffer();
    for (final name in names) {
      headerBlock
        ..write(name)
        ..write(':')
        ..write(_normalizeHeaderValue(canonicalHeaders[name]!))
        ..write('\n');
    }
    final signedHeaders = names.join(';');

    final canonicalRequest = StringBuffer()
      ..write(method.toUpperCase())
      ..write('\n')
      ..write(_canonicalUri(uri))
      ..write('\n')
      ..write(_canonicalQueryString(uri))
      ..write('\n')
      ..write(headerBlock)
      ..write('\n')
      ..write(signedHeaders)
      ..write('\n')
      ..write(payloadHash);
    final canonicalRequestString = canonicalRequest.toString();

    final scope = '$dateStamp/$region/$service/$_requestSuffix';
    final stringToSign =
        '$_algorithm\n'
        '$amzDate\n'
        '$scope\n'
        '${_hexSha256Text(canonicalRequestString)}';

    final signingKey = _signingKey(dateStamp);
    final signature = _hexHmac(signingKey, stringToSign);
    final authorization =
        '$_algorithm '
        'Credential=${credentials.accessKeyId}/$scope, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';

    return _SigV4Computation(
      canonicalRequest: canonicalRequestString,
      stringToSign: stringToSign,
      signature: signature,
      signedHeaders: signedHeaders,
      amzDate: amzDate,
      payloadHash: payloadHash,
      authorization: authorization,
      host: canonicalHeaders['host']!,
      securityToken: canonicalHeaders['x-amz-security-token'],
    );
  }

  /// `kSigning = HMAC(HMAC(HMAC(HMAC("AWS4"+secret, date), region), service), "aws4_request")`.
  List<int> _signingKey(String dateStamp) {
    final secret = utf8.encode('AWS4${credentials.secretAccessKey}');
    final dateKey = _hmac(secret, dateStamp);
    final regionKey = _hmac(dateKey, region);
    final serviceKey = _hmac(regionKey, service);
    return _hmac(serviceKey, _requestSuffix);
  }

  static String _formatAmzDate(DateTime timestamp) {
    final utc = timestamp.toUtc();
    return '${_pad(utc.year, 4)}${_pad(utc.month)}${_pad(utc.day)}'
        'T${_pad(utc.hour)}${_pad(utc.minute)}${_pad(utc.second)}Z';
  }

  static String _pad(int value, [int width = 2]) =>
      value.toString().padLeft(width, '0');

  static String _canonicalUri(Uri uri) {
    final buffer = StringBuffer('/');
    final segments = uri.pathSegments;
    for (var i = 0; i < segments.length; i++) {
      if (i > 0) {
        buffer.write('/');
      }
      buffer.write(_uriEncode(segments[i]));
    }
    return buffer.toString();
  }

  static String _canonicalQueryString(Uri uri) {
    final raw = uri.query;
    if (raw.isEmpty) {
      return '';
    }
    final encoded = <MapEntry<String, String>>[];
    for (final part in raw.split('&')) {
      if (part.isEmpty) {
        continue;
      }
      final separator = part.indexOf('=');
      final rawName = separator < 0 ? part : part.substring(0, separator);
      final rawValue = separator < 0 ? '' : part.substring(separator + 1);
      encoded.add(
        MapEntry(
          _uriEncode(Uri.decodeQueryComponent(rawName)),
          _uriEncode(Uri.decodeQueryComponent(rawValue)),
        ),
      );
    }
    encoded.sort((a, b) {
      final byName = a.key.compareTo(b.key);
      return byName != 0 ? byName : a.value.compareTo(b.value);
    });
    return encoded.map((entry) => '${entry.key}=${entry.value}').join('&');
  }

  static String _uriEncode(String input) {
    final buffer = StringBuffer();
    for (final byte in utf8.encode(input)) {
      if (byte < 0x80 && _unreserved.contains(String.fromCharCode(byte))) {
        buffer.writeCharCode(byte);
      } else {
        buffer.write('%');
        buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return buffer.toString();
  }

  /// Обрезает внешние пробелы и сжимает внутренние до одного пробела.
  static String _normalizeHeaderValue(String value) =>
      value.trim().replaceAll(_whitespaceRun, ' ');

  static String _hostHeader(Uri uri) {
    final host = uri.host;
    if (host.isEmpty) {
      throw ArgumentError.value(
        uri,
        'uri',
        'должен быть абсолютным URL с хостом',
      );
    }
    final formatted = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return uri.hasPort ? '$formatted:${uri.port}' : formatted;
  }

  static List<int> _hmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  static String _hexHmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).toString();

  static String _hexSha256(List<int> bytes) => sha256.convert(bytes).toString();

  static String _hexSha256Text(String text) =>
      sha256.convert(utf8.encode(text)).toString();
}

/// Внутренний результат вычисления подписи.
class _SigV4Computation {
  const _SigV4Computation({
    required this.canonicalRequest,
    required this.stringToSign,
    required this.signature,
    required this.signedHeaders,
    required this.amzDate,
    required this.payloadHash,
    required this.authorization,
    required this.host,
    required this.securityToken,
  });

  final String canonicalRequest;
  final String stringToSign;
  final String signature;
  final String signedHeaders;
  final String amzDate;
  final String payloadHash;
  final String authorization;
  final String host;
  final String? securityToken;
}
