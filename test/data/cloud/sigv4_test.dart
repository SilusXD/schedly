// Тесты подписи AWS Signature Version 4 для S3-совместимого хранилища.
//
// ИСТОЧНИКИ ОФИЦИАЛЬНЫХ ТЕСТОВЫХ ВЕКТОРОВ
//
// 1) aws-sig-v4-test-suite (generic-набор AWS, service = "service"):
//    https://github.com/awslabs/aws-c-auth/tree/main/tests/aws-signing-test-suite/v4
//    Строки ниже скопированы из файлов набора через зеркало
//    https://github.com/mhart/aws4fetch/tree/master/test/aws-sig-v4-test-suite
//    (кейсы get-vanilla, post-x-www-form-urlencoded, get-header-value-trim).
//
// 2) Примеры Amazon S3 из документации AWS —
//    "Signature Calculations for the Authorization Header: Transferring
//     Payload in a Single Chunk (AWS Signature Version 4)":
//    https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
//    Те же векторы независимо воспроизведены в:
//      * https://github.com/Nugine/s3s (crates/s3s/src/sig_v4/methods.rs, тесты
//        example_get_object / example_put_object_single_chunk);
//      * https://github.com/cloudyr/aws.signature
//        (tests/testthat/test-v4.R).
//
// ВАЖНОЕ РАЗЛИЧИЕ ДВУХ НАБОРОВ
// Набор (1) — generic: в нём НЕТ заголовка x-amz-content-sha256, и подписаны
// только host / content-type / x-amz-date. Наш подписывающий класс по
// требованию API ВСЕГДА добавляет и подписывает x-amz-content-sha256
// (обязательный заголовок S3), поэтому его `Authorization` для запросов из
// набора (1) не может совпасть с официальной строкой побайтово — канонический
// запрос отличается на одну строку заголовка. Поэтому:
//   * набор (1) сверяется в этом файле НЕЗАВИСИМОЙ «наивной» реализацией
//     (см. _naive* ниже) — по каноническому запросу, string-to-sign и
//     полной строке Authorization;
//   * библиотека сверяется с теми же запросами по каноническому запросу
//     (единственная добавленная строка — x-amz-content-sha256);
//   * ПОЛНАЯ сверка библиотеки «конец-в-конец» (канонический запрос +
//     string-to-sign + подпись + Authorization) идёт по набору (2) —
//     официальным S3-примерам AWS, где x-amz-content-sha256 присутствует.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:schedly/data/cloud/sigv4.dart';

// ---------------------------------------------------------------------------
// Константы официальных наборов
// ---------------------------------------------------------------------------

/// Ключ и секрет из aws-sig-v4-test-suite.
const String _suiteAccessKey = 'AKIDEXAMPLE';
const String _suiteSecretKey = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY';

/// Дата `20150830T123600Z` из aws-sig-v4-test-suite.
final DateTime _suiteDate = DateTime.utc(2015, 8, 30, 12, 36, 0);

/// SHA-256 пустой строки: подпись пустого тела во всех векторах ниже.
const String _emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Официальный .creq кейса get-vanilla.
const String _officialGetVanillaCreq =
    'GET\n'
    '/\n'
    '\n'
    'host:example.amazonaws.com\n'
    'x-amz-date:20150830T123600Z\n'
    '\n'
    'host;x-amz-date\n'
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Официальный .sts кейса get-vanilla.
const String _officialGetVanillaSts =
    'AWS4-HMAC-SHA256\n'
    '20150830T123600Z\n'
    '20150830/us-east-1/service/aws4_request\n'
    'bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63';

/// Официальный .authz кейса get-vanilla.
const String _officialGetVanillaAuthz =
    'AWS4-HMAC-SHA256 '
    'Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, '
    'SignedHeaders=host;x-amz-date, '
    'Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31';

/// Официальный .creq кейса post-x-www-form-urlencoded (тело `Param1=value1`).
const String _officialPostFormCreq =
    'POST\n'
    '/\n'
    '\n'
    'content-type:application/x-www-form-urlencoded\n'
    'host:example.amazonaws.com\n'
    'x-amz-date:20150830T123600Z\n'
    '\n'
    'content-type;host;x-amz-date\n'
    '9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e';

/// Официальный .sts кейса post-x-www-form-urlencoded.
const String _officialPostFormSts =
    'AWS4-HMAC-SHA256\n'
    '20150830T123600Z\n'
    '20150830/us-east-1/service/aws4_request\n'
    '42a5e5bb34198acb3e84da4f085bb7927f2bc277ca766e6d19c73c2154021281';

/// Официальный .authz кейса post-x-www-form-urlencoded.
const String _officialPostFormAuthz =
    'AWS4-HMAC-SHA256 '
    'Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, '
    'SignedHeaders=content-type;host;x-amz-date, '
    'Signature=ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a';

/// SHA-256 тела `Param1=value1` из официального .creq выше.
const String _postFormBodySha256 =
    '9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e';

/// Официальный .creq кейса get-header-value-trim: `"a   b   c"` -> `"a b c"`.
const String _officialHeaderTrimCreq =
    'GET\n'
    '/\n'
    '\n'
    'host:example.amazonaws.com\n'
    'my-header1:value1\n'
    'my-header2:"a b c"\n'
    'x-amz-date:20150830T123600Z\n'
    '\n'
    'host;my-header1;my-header2;x-amz-date\n'
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Официальный .authz кейса get-header-value-trim.
const String _officialHeaderTrimAuthz =
    'AWS4-HMAC-SHA256 '
    'Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, '
    'SignedHeaders=host;my-header1;my-header2;x-amz-date, '
    'Signature=acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736';

// --- Официальные S3-примеры из документации AWS ----------------------------

/// Ключ и секрет из S3-примеров документации AWS.
const String _docsAccessKey = 'AKIAIOSFODNN7EXAMPLE';
const String _docsSecretKey = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';

/// Дата `20130524T000000Z` из S3-примеров документации AWS.
final DateTime _docsDate = DateTime.utc(2013, 5, 24, 0, 0, 0);

/// Пример «GET Object»: канонический запрос из документации AWS.
const String _docsGetObjectCreq =
    'GET\n'
    '/test.txt\n'
    '\n'
    'host:examplebucket.s3.amazonaws.com\n'
    'range:bytes=0-9\n'
    'x-amz-content-sha256:'
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n'
    'x-amz-date:20130524T000000Z\n'
    '\n'
    'host;range;x-amz-content-sha256;x-amz-date\n'
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Пример «GET Object»: string-to-sign из документации AWS.
const String _docsGetObjectSts =
    'AWS4-HMAC-SHA256\n'
    '20130524T000000Z\n'
    '20130524/us-east-1/s3/aws4_request\n'
    '7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972';

/// Пример «GET Object»: `Authorization` из документации AWS.
///
/// В документации AWS разделители записаны без пробела после запятой —
/// это тот же заголовок, пробелы после запятых в нём не значимы. Для полной
/// сверки строка нормализуется через [_awsDocsToSuiteSpacing].
const String _docsGetObjectAuthz =
    'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41';

/// Пример «PUT Object»: канонический запрос из документации AWS.
const String _docsPutObjectCreq =
    'PUT\n'
    '/test%24file.text\n'
    '\n'
    'date:Fri, 24 May 2013 00:00:00 GMT\n'
    'host:examplebucket.s3.amazonaws.com\n'
    'x-amz-content-sha256:'
    '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072\n'
    'x-amz-date:20130524T000000Z\n'
    'x-amz-storage-class:REDUCED_REDUNDANCY\n'
    '\n'
    'date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class\n'
    '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072';

/// Пример «PUT Object»: string-to-sign из документации AWS.
const String _docsPutObjectSts =
    'AWS4-HMAC-SHA256\n'
    '20130524T000000Z\n'
    '20130524/us-east-1/s3/aws4_request\n'
    '9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d';

/// Пример «PUT Object»: `Authorization` из документации AWS.
const String _docsPutObjectAuthz =
    'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd';

/// Тело запроса «PUT Object» из документации AWS: `Welcome to Amazon S3.`
final Uint8List _docsPutObjectBody = Uint8List.fromList(
  utf8.encode('Welcome to Amazon S3.'),
);

/// Переписывает строку `Authorization` из документации AWS в тот же вид,
/// что и aws-sig-v4-test-suite (пробел после запятой).
String _awsDocsToSuiteSpacing(String awsDocsAuthorization) =>
    awsDocsAuthorization.replaceAll(',', ', ');

// ---------------------------------------------------------------------------
// Независимая «наивная» эталонная реализация SigV4.
//
// Написана здесь намеренно «в лоб»: посимвольное кодирование по байтам, ручные
// пузырьковые сортировки, сборка строк через StringBuffer. НЕ использует код
// из lib/data/cloud/sigv4.dart — это независимый источник истины для сверки
// официальных векторов и защита от ошибок рефакторинга библиотеки.
// ---------------------------------------------------------------------------

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _sha256Hex(List<int> bytes) => _toHex(sha256.convert(bytes).bytes);

String _sha256HexOfText(String text) => _sha256Hex(utf8.encode(text));

List<int> _hmacBytes(List<int> key, String data) =>
    Hmac(sha256, key).convert(utf8.encode(data)).bytes;

String _hmacHex(List<int> key, String data) => _toHex(_hmacBytes(key, data));

/// RFC3986-кодирование: unreserved = `A-Za-z0-9-_.~`, остальное — `%XX`.
String _encode(String input) {
  final buffer = StringBuffer();
  for (final byte in utf8.encode(input)) {
    final unreserved =
        (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2D ||
        byte == 0x2E ||
        byte == 0x5F ||
        byte == 0x7E;
    if (unreserved) {
      buffer.writeCharCode(byte);
    } else {
      buffer.write('%');
      buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buffer.toString();
}

/// Обрезка внешних пробелов и сжатие внутренних (формулировка через split).
String _normalizeHeaderValue(String raw) =>
    raw.trim().split(RegExp(r'\s+')).join(' ');

/// Пузырьковая сортировка имён заголовков — намеренно не `List.sort`.
List<String> _sortedHeaderNames(Map<String, String> headers) {
  final names = headers.keys.toList();
  for (var i = 0; i < names.length; i++) {
    for (var j = i + 1; j < names.length; j++) {
      if (names[j].compareTo(names[i]) < 0) {
        final tmp = names[i];
        names[i] = names[j];
        names[j] = tmp;
      }
    }
  }
  return names;
}

String _naiveCanonicalRequest({
  required String method,
  required String canonicalUri,
  required String canonicalQueryString,
  required Map<String, String> headers,
  required String hashedPayload,
}) {
  final names = _sortedHeaderNames(headers);
  final buffer = StringBuffer()
    ..write(method)
    ..write('\n')
    ..write(canonicalUri)
    ..write('\n')
    ..write(canonicalQueryString)
    ..write('\n');
  for (final name in names) {
    buffer
      ..write(name)
      ..write(':')
      ..write(_normalizeHeaderValue(headers[name]!))
      ..write('\n');
  }
  buffer
    ..write('\n')
    ..write(names.join(';'))
    ..write('\n')
    ..write(hashedPayload);
  return buffer.toString();
}

String _naiveStringToSign({
  required String canonicalRequest,
  required String amzDate,
  required String region,
  required String service,
}) {
  final dateStamp = amzDate.substring(0, 8);
  return 'AWS4-HMAC-SHA256\n'
      '$amzDate\n'
      '$dateStamp/$region/$service/aws4_request\n'
      '${_sha256HexOfText(canonicalRequest)}';
}

List<int> _naiveSigningKey({
  required String secretAccessKey,
  required String amzDate,
  required String region,
  required String service,
}) {
  var key = _hmacBytes(
    utf8.encode('AWS4$secretAccessKey'),
    amzDate.substring(0, 8),
  );
  key = _hmacBytes(key, region);
  key = _hmacBytes(key, service);
  return _hmacBytes(key, 'aws4_request');
}

String _naiveSignature({
  required String stringToSign,
  required String secretAccessKey,
  required String amzDate,
  required String region,
  required String service,
}) => _hmacHex(
  _naiveSigningKey(
    secretAccessKey: secretAccessKey,
    amzDate: amzDate,
    region: region,
    service: service,
  ),
  stringToSign,
);

/// Канонизация пути «по-другому»: режем закодированный путь по `/`, затем
/// декодируем и заново кодируем каждый сегмент (библиотека использует
/// `Uri.pathSegments`).
String _naiveCanonicalUri(Uri uri) {
  final rawPath = uri.path;
  if (rawPath.isEmpty) {
    return '/';
  }
  final parts = rawPath.split('/');
  final encoded = parts
      .map((part) => _encode(Uri.decodeComponent(part)))
      .join('/');
  return encoded.isEmpty ? '/' : encoded;
}

/// Канонизация строки запроса: `+` трактуется как пробел и кодируется `%20`.
String _naiveCanonicalQueryString(Uri uri) {
  final raw = uri.query;
  if (raw.isEmpty) {
    return '';
  }
  final pairs = <List<String>>[];
  for (final chunk in raw.split('&')) {
    if (chunk.isEmpty) {
      continue;
    }
    final separator = chunk.indexOf('=');
    if (separator < 0) {
      pairs.add(<String>[_encode(Uri.decodeQueryComponent(chunk)), '']);
    } else {
      pairs.add(<String>[
        _encode(Uri.decodeQueryComponent(chunk.substring(0, separator))),
        _encode(Uri.decodeQueryComponent(chunk.substring(separator + 1))),
      ]);
    }
  }
  for (var i = 0; i < pairs.length; i++) {
    for (var j = i + 1; j < pairs.length; j++) {
      final byName = pairs[i][0].compareTo(pairs[j][0]);
      if (byName > 0 ||
          (byName == 0 && pairs[i][1].compareTo(pairs[j][1]) > 0)) {
        final tmp = pairs[i];
        pairs[i] = pairs[j];
        pairs[j] = tmp;
      }
    }
  }
  return pairs.map((p) => '${p[0]}=${p[1]}').join('&');
}

AwsSigV4Signer _suiteSigner() => AwsSigV4Signer(
  credentials: const AwsCredentials(
    accessKeyId: _suiteAccessKey,
    secretAccessKey: _suiteSecretKey,
  ),
  region: 'us-east-1',
  service: 'service',
);

AwsSigV4Signer _docsSigner() => AwsSigV4Signer(
  credentials: const AwsCredentials(
    accessKeyId: _docsAccessKey,
    secretAccessKey: _docsSecretKey,
  ),
  region: 'us-east-1',
  service: 's3',
);

List<String> _lines(String canonicalRequest) => canonicalRequest.split('\n');

void main() {
  // -------------------------------------------------------------------------
  group('официальный aws-sig-v4-test-suite (generic, без x-amz-content-sha256)', () {
    test('get-vanilla: creq / sts / authz воспроизводятся независимым кодом', () {
      final headers = <String, String>{
        'host': 'example.amazonaws.com',
        'x-amz-date': '20150830T123600Z',
      };

      final creq = _naiveCanonicalRequest(
        method: 'GET',
        canonicalUri: '/',
        canonicalQueryString: '',
        headers: headers,
        hashedPayload: _emptySha256,
      );
      expect(creq, _officialGetVanillaCreq);

      final sts = _naiveStringToSign(
        canonicalRequest: creq,
        amzDate: '20150830T123600Z',
        region: 'us-east-1',
        service: 'service',
      );
      expect(sts, _officialGetVanillaSts);

      final signature = _naiveSignature(
        stringToSign: sts,
        secretAccessKey: _suiteSecretKey,
        amzDate: '20150830T123600Z',
        region: 'us-east-1',
        service: 'service',
      );
      final authz =
          'AWS4-HMAC-SHA256 '
          'Credential=$_suiteAccessKey/20150830/us-east-1/service/aws4_request, '
          'SignedHeaders=${_sortedHeaderNames(headers).join(';')}, '
          'Signature=$signature';
      expect(authz, _officialGetVanillaAuthz);
    });

    test('post-x-www-form-urlencoded: creq / sts / authz воспроизводятся', () {
      final body = utf8.encode('Param1=value1');
      final bodyHash = _sha256Hex(body);
      expect(bodyHash, _postFormBodySha256);

      final headers = <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
        'host': 'example.amazonaws.com',
        'x-amz-date': '20150830T123600Z',
      };

      final creq = _naiveCanonicalRequest(
        method: 'POST',
        canonicalUri: '/',
        canonicalQueryString: '',
        headers: headers,
        hashedPayload: bodyHash,
      );
      expect(creq, _officialPostFormCreq);

      final sts = _naiveStringToSign(
        canonicalRequest: creq,
        amzDate: '20150830T123600Z',
        region: 'us-east-1',
        service: 'service',
      );
      expect(sts, _officialPostFormSts);

      final signature = _naiveSignature(
        stringToSign: sts,
        secretAccessKey: _suiteSecretKey,
        amzDate: '20150830T123600Z',
        region: 'us-east-1',
        service: 'service',
      );
      expect(
        'AWS4-HMAC-SHA256 '
        'Credential=$_suiteAccessKey/20150830/us-east-1/service/aws4_request, '
        'SignedHeaders=${_sortedHeaderNames(headers).join(';')}, '
        'Signature=$signature',
        _officialPostFormAuthz,
      );
    });

    test('get-header-value-trim: пробелы в значениях сжимаются', () {
      final headers = <String, String>{
        'host': 'example.amazonaws.com',
        'my-header1': 'value1',
        'my-header2': '"a   b   c"',
        'x-amz-date': '20150830T123600Z',
      };

      final creq = _naiveCanonicalRequest(
        method: 'GET',
        canonicalUri: '/',
        canonicalQueryString: '',
        headers: headers,
        hashedPayload: _emptySha256,
      );
      expect(creq, _officialHeaderTrimCreq);

      final sts = _naiveStringToSign(
        canonicalRequest: creq,
        amzDate: '20150830T123600Z',
        region: 'us-east-1',
        service: 'service',
      );
      final signature = _naiveSignature(
        stringToSign: sts,
        secretAccessKey: _suiteSecretKey,
        amzDate: '20150830T123600Z',
        region: 'us-east-1',
        service: 'service',
      );
      expect(
        'AWS4-HMAC-SHA256 '
        'Credential=$_suiteAccessKey/20150830/us-east-1/service/aws4_request, '
        'SignedHeaders=${_sortedHeaderNames(headers).join(';')}, '
        'Signature=$signature',
        _officialHeaderTrimAuthz,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('официальные S3-векторы AWS: библиотека конец-в-конец', () {
    test('GET Object (диапазон bytes=0-9)', () {
      final uri = Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt');
      final info = _docsSigner().debugCanonicalRequest(
        method: 'GET',
        uri: uri,
        headers: const {'Range': 'bytes=0-9'},
        timestamp: _docsDate,
      );

      expect(info.amzDate, '20130524T000000Z');
      expect(info.canonicalRequest, _docsGetObjectCreq);
      expect(info.stringToSign, _docsGetObjectSts);
      expect(
        info.signature,
        'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
      );
      expect(info.signedHeaders, 'host;range;x-amz-content-sha256;x-amz-date');

      final signed = _docsSigner().sign(
        method: 'GET',
        uri: uri,
        headers: const {'Range': 'bytes=0-9'},
        timestamp: _docsDate,
      );
      expect(
        signed['Authorization'],
        _awsDocsToSuiteSpacing(_docsGetObjectAuthz),
      );
    });

    test('PUT Object (тело "Welcome to Amazon S3.", ключ с \$ -> %24)', () {
      final uri = Uri.parse(
        r'https://examplebucket.s3.amazonaws.com/test$file.text',
      );
      final info = _docsSigner().debugCanonicalRequest(
        method: 'PUT',
        uri: uri,
        headers: const {
          'Date': 'Fri, 24 May 2013 00:00:00 GMT',
          'x-amz-storage-class': 'REDUCED_REDUNDANCY',
        },
        payload: _docsPutObjectBody,
        timestamp: _docsDate,
      );

      expect(info.canonicalRequest, _docsPutObjectCreq);
      expect(info.stringToSign, _docsPutObjectSts);
      expect(
        info.signature,
        '98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd',
      );
      expect(
        info.signedHeaders,
        'date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class',
      );

      final signed = _docsSigner().sign(
        method: 'PUT',
        uri: uri,
        headers: const {
          'Date': 'Fri, 24 May 2013 00:00:00 GMT',
          'x-amz-storage-class': 'REDUCED_REDUNDANCY',
        },
        payload: _docsPutObjectBody,
        timestamp: _docsDate,
      );
      expect(
        signed['Authorization'],
        _awsDocsToSuiteSpacing(_docsPutObjectAuthz),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('библиотека на запросах aws-sig-v4-test-suite', () {
    // Библиотека всегда добавляет и подписывает x-amz-content-sha256, поэтому
    // её канонический запрос равен официальному .creq ровно с одной
    // добавленной строкой заголовка (и с расширенным SignedHeaders).

    test('get-vanilla: creq библиотеки = официальный creq + строка sha256', () {
      final info = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://example.amazonaws.com/'),
        timestamp: _suiteDate,
      );

      expect(
        info.canonicalRequest,
        'GET\n'
        '/\n'
        '\n'
        'host:example.amazonaws.com\n'
        'x-amz-content-sha256:$_emptySha256\n'
        'x-amz-date:20150830T123600Z\n'
        '\n'
        'host;x-amz-content-sha256;x-amz-date\n'
        '$_emptySha256',
      );
      expect(info.signedHeaders, 'host;x-amz-content-sha256;x-amz-date');
      expect(info.amzDate, '20150830T123600Z');

      // Обратная проверка: если убрать ровно добавленный библиотекой
      // заголовок, получается байт-в-байт официальный .creq набора.
      final stripped = info.canonicalRequest
          .replaceFirst('x-amz-content-sha256:$_emptySha256\n', '')
          .replaceFirst(';x-amz-content-sha256', '');
      expect(stripped, _officialGetVanillaCreq);
    });

    test('post-x-www-form-urlencoded: creq библиотеки + подпись ссылки', () {
      final body = Uint8List.fromList(utf8.encode('Param1=value1'));
      final info = _suiteSigner().debugCanonicalRequest(
        method: 'POST',
        uri: Uri.parse('https://example.amazonaws.com/'),
        headers: const {'content-type': 'application/x-www-form-urlencoded'},
        payload: body,
        timestamp: _suiteDate,
      );

      expect(
        info.canonicalRequest,
        'POST\n'
        '/\n'
        '\n'
        'content-type:application/x-www-form-urlencoded\n'
        'host:example.amazonaws.com\n'
        'x-amz-content-sha256:$_postFormBodySha256\n'
        'x-amz-date:20150830T123600Z\n'
        '\n'
        'content-type;host;x-amz-content-sha256;x-amz-date\n'
        '$_postFormBodySha256',
      );

      // Тело и хеш — как в официальном векторе.
      expect(info.canonicalRequest.split('\n').last, _postFormBodySha256);

      // Байт-в-байт официальный .creq после снятия добавленного заголовка.
      expect(
        info.canonicalRequest
            .replaceFirst('x-amz-content-sha256:$_postFormBodySha256\n', '')
            .replaceFirst(';x-amz-content-sha256', ''),
        _officialPostFormCreq,
      );

      // Независимая сверка подписи библиотеки той же «наивной» реализацией,
      // которой выше были воспроизведены официальные векторы.
      final naiveSignature = _naiveSignature(
        stringToSign: info.stringToSign,
        secretAccessKey: _suiteSecretKey,
        amzDate: '20150830T123600Z',
        region: 'us-east-1',
        service: 'service',
      );
      expect(info.signature, naiveSignature);
    });

    test(
      'get-header-value-trim: библиотека сжимает пробелы так же, как AWS',
      () {
        final info = _suiteSigner().debugCanonicalRequest(
          method: 'GET',
          uri: Uri.parse('https://example.amazonaws.com/'),
          headers: const {
            'My-Header1': '   value1   ',
            'My-Header2': '"a   b   c"',
          },
          timestamp: _suiteDate,
        );

        expect(
          info.canonicalRequest,
          'GET\n'
          '/\n'
          '\n'
          'host:example.amazonaws.com\n'
          'my-header1:value1\n'
          'my-header2:"a b c"\n'
          'x-amz-content-sha256:$_emptySha256\n'
          'x-amz-date:20150830T123600Z\n'
          '\n'
          'host;my-header1;my-header2;x-amz-content-sha256;x-amz-date\n'
          '$_emptySha256',
        );
      },
    );

    test(
      'библиотека совпадает с наивной реализацией на произвольных входах',
      () {
        final uris = <Uri>[
          Uri.parse('https://example.amazonaws.com/'),
          Uri.parse('https://bucket.s3.yandexcloud.net/a/b/c.json?x=1&y=2'),
          Uri.parse(
            'https://minio.local:9000/bucket/schedules/расписание.json',
          ),
          Uri.parse(r'https://s3.example.com/bucket/test$file.text'),
          Uri.parse('https://s3.example.com/bucket/a%2Fb?k=a%2Bb&j=a+b'),
        ];
        const bodyText = '{"a":1}';
        final payloadHash = _sha256Hex(utf8.encode(bodyText));
        for (final uri in uris) {
          final info = _suiteSigner().debugCanonicalRequest(
            method: 'PUT',
            uri: uri,
            headers: const {'Content-Type': 'application/json'},
            payload: Uint8List.fromList(utf8.encode(bodyText)),
            timestamp: _suiteDate,
          );

          final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
          final expectedCreq = _naiveCanonicalRequest(
            method: 'PUT',
            canonicalUri: _naiveCanonicalUri(uri),
            canonicalQueryString: _naiveCanonicalQueryString(uri),
            headers: <String, String>{
              'content-type': 'application/json',
              'host': host,
              'x-amz-content-sha256': payloadHash,
              'x-amz-date': '20150830T123600Z',
            },
            hashedPayload: payloadHash,
          );
          expect(info.canonicalRequest, expectedCreq, reason: 'creq для $uri');
          expect(
            _lines(info.canonicalRequest).last,
            payloadHash,
            reason: 'hashed payload для $uri',
          );
          expect(
            info.signature,
            _naiveSignature(
              stringToSign: info.stringToSign,
              secretAccessKey: _suiteSecretKey,
              amzDate: '20150830T123600Z',
              region: 'us-east-1',
              service: 'service',
            ),
            reason: 'signature для $uri',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  group('канонизация query-строки', () {
    test('сортировка по имени, затем по значению; кодирование RFC3986', () {
      final uri = Uri.parse(
        'https://s3.example.com/bucket'
        '?b=2&a=1&a=0&A=z&x=%D1%80%D0%B0&empty',
      );
      final info = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: uri,
        timestamp: _suiteDate,
      );
      expect(
        _lines(info.canonicalRequest)[2],
        'A=z&a=0&a=1&b=2&empty=&x=%D1%80%D0%B0',
      );
      expect(_lines(info.canonicalRequest)[2], _naiveCanonicalQueryString(uri));
    });

    test('плюс и пробел в значении кодируются как %20, %2B остаётся %2B', () {
      final plusAsSpace = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://s3.example.com/bucket?key=a+b'),
        timestamp: _suiteDate,
      );
      expect(_lines(plusAsSpace.canonicalRequest)[2], 'key=a%20b');

      final encodedPlus = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://s3.example.com/bucket?k=a%2Bb'),
        timestamp: _suiteDate,
      );
      expect(_lines(encodedPlus.canonicalRequest)[2], 'k=a%2Bb');

      final space = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://s3.example.com/bucket?k=%20'),
        timestamp: _suiteDate,
      );
      expect(_lines(space.canonicalRequest)[2], 'k=%20');
    });

    test('get-vanilla-подобный запрос без query даёт пустую строку', () {
      final info = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://example.amazonaws.com/'),
        timestamp: _suiteDate,
      );
      expect(_lines(info.canonicalRequest)[2], '');
    });
  });

  // -------------------------------------------------------------------------
  group('канонизация пути', () {
    test('кириллица в ключе объекта кодируется по UTF-8 байтам', () {
      final info = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse(
          'https://bucket.s3.yandexcloud.net/schedules/расписание.json',
        ),
        timestamp: _suiteDate,
      );
      expect(
        _lines(info.canonicalRequest)[1],
        '/schedules/'
        '%D1%80%D0%B0%D1%81%D0%BF%D0%B8%D1%81%D0%B0%D0%BD%D0%B8%D0%B5.json',
      );
    });

    test('разделитель / не кодируется, а / внутри ключа — кодируется', () {
      final nested = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://s3.example.com/a/b/c.json'),
        timestamp: _suiteDate,
      );
      expect(_lines(nested.canonicalRequest)[1], '/a/b/c.json');

      final encodedSlash = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://s3.example.com/a%2Fb'),
        timestamp: _suiteDate,
      );
      expect(_lines(encodedSlash.canonicalRequest)[1], '/a%2Fb');
    });

    test('пустой путь заменяется на /, нестандартный порт попадает в host', () {
      final root = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://s3.example.com'),
        timestamp: _suiteDate,
      );
      expect(_lines(root.canonicalRequest)[1], '/');
      expect(root.canonicalRequest, contains('host:s3.example.com\n'));

      final minio = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://minio.local:9000/bucket/key.txt'),
        timestamp: _suiteDate,
      );
      expect(minio.canonicalRequest, contains('host:minio.local:9000\n'));

      final standardPort = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://s3.example.com:443/bucket/key.txt'),
        timestamp: _suiteDate,
      );
      expect(standardPort.canonicalRequest, contains('host:s3.example.com\n'));
    });

    test('незарезервированные символы не кодируются, остальные — да', () {
      final info = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: Uri.parse('https://s3.example.com/~tilde/a b/(paren)'),
        timestamp: _suiteDate,
      );
      expect(_lines(info.canonicalRequest)[1], '/~tilde/a%20b/%28paren%29');
    });
  });

  // -------------------------------------------------------------------------
  group('заголовки и подпись', () {
    test(
      'x-amz-security-token появляется и подписывается при sessionToken',
      () {
        final withToken =
            AwsSigV4Signer(
              credentials: const AwsCredentials(
                accessKeyId: _suiteAccessKey,
                secretAccessKey: _suiteSecretKey,
                sessionToken: 'SESSIONTOKEN',
              ),
              region: 'us-east-1',
            ).sign(
              method: 'GET',
              uri: Uri.parse('https://example.amazonaws.com/'),
              timestamp: _suiteDate,
            );
        expect(withToken['x-amz-security-token'], 'SESSIONTOKEN');
        expect(
          withToken['Authorization'],
          contains(
            'SignedHeaders=host;x-amz-content-sha256;x-amz-date;'
            'x-amz-security-token',
          ),
        );

        final withoutToken = _suiteSigner().sign(
          method: 'GET',
          uri: Uri.parse('https://example.amazonaws.com/'),
          timestamp: _suiteDate,
        );
        expect(withoutToken.containsKey('x-amz-security-token'), isFalse);
        expect(
          withoutToken['Authorization'],
          isNot(contains('x-amz-security-token')),
        );
      },
    );

    test('x-amz-content-sha256 совпадает с фактическим SHA-256 тела', () {
      final payload = Uint8List.fromList(utf8.encode('расписание'));
      final signed = _suiteSigner().sign(
        method: 'PUT',
        uri: Uri.parse('https://s3.example.com/bucket/key.txt'),
        payload: payload,
        timestamp: _suiteDate,
      );
      expect(
        signed['x-amz-content-sha256'],
        sha256.convert(payload).toString(),
      );
      expect(signed['x-amz-content-sha256'], isNot(_emptySha256));
    });

    test('null и пустое тело дают SHA-256 пустой строки', () {
      final nullBody = _suiteSigner().sign(
        method: 'PUT',
        uri: Uri.parse('https://s3.example.com/bucket/key.txt'),
        timestamp: _suiteDate,
      );
      expect(nullBody['x-amz-content-sha256'], _emptySha256);

      final emptyBody = _suiteSigner().sign(
        method: 'PUT',
        uri: Uri.parse('https://s3.example.com/bucket/key.txt'),
        payload: Uint8List(0),
        timestamp: _suiteDate,
      );
      expect(emptyBody['x-amz-content-sha256'], _emptySha256);
      expect(emptyBody['Authorization'], nullBody['Authorization']);
    });

    test(
      'возвращаются исходные заголовки + Host + x-amz-* + Authorization',
      () {
        final signed = _suiteSigner().sign(
          method: 'PUT',
          uri: Uri.parse('https://s3.example.com/bucket/key.txt'),
          headers: const {'Content-Type': 'application/json'},
          timestamp: _suiteDate,
        );
        expect(signed['Content-Type'], 'application/json');
        expect(signed['Host'], 's3.example.com');
        expect(signed['x-amz-date'], '20150830T123600Z');
        expect(signed['x-amz-content-sha256'], _emptySha256);
        expect(signed['Authorization'], isNotNull);
        expect(signed['Authorization'], startsWith('AWS4-HMAC-SHA256 '));
        expect(signed.containsKey('authorization'), isFalse);
      },
    );

    test('Authorization: формат Credential / SignedHeaders / Signature', () {
      final signed = _suiteSigner().sign(
        method: 'GET',
        uri: Uri.parse('https://s3.example.com/bucket/key.txt'),
        timestamp: _suiteDate,
      );
      final expected = RegExp(
        r'^AWS4-HMAC-SHA256 '
        r'Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, '
        r'SignedHeaders=host;x-amz-content-sha256;x-amz-date, '
        r'Signature=[0-9a-f]{64}$',
      );
      expect(signed['Authorization'], matches(expected));
    });

    test('x-amz-date: yyyyMMddT HHmmssZ, без миллисекунд', () {
      final info = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        // 500 мс и 123 мкс не должны попасть в дату.
        uri: Uri.parse('https://s3.example.com/bucket/key.txt'),
        timestamp: DateTime.utc(2015, 8, 30, 12, 36, 0, 500, 123),
      );
      expect(info.amzDate, '20150830T123600Z');
      expect(info.amzDate, matches(RegExp(r'^\d{8}T\d{6}Z$')));
    });

    test('при timestamp == null используется clock()', () {
      final signer = AwsSigV4Signer(
        credentials: const AwsCredentials(
          accessKeyId: _suiteAccessKey,
          secretAccessKey: _suiteSecretKey,
        ),
        region: 'ru-central1',
        clock: () => DateTime.utc(2015, 8, 30, 12, 36, 0),
      );
      final signed = signer.sign(
        method: 'GET',
        uri: Uri.parse('https://storage.yandexcloud.net/bucket/key.txt'),
      );
      expect(signed['x-amz-date'], '20150830T123600Z');
      expect(signed['Authorization'], contains('/20150830/ru-central1/s3/'));
    });
  });

  // -------------------------------------------------------------------------
  group('стабильность', () {
    test('два вызова с одним timestamp дают одинаковый Authorization', () {
      final uri = Uri.parse('https://s3.example.com/bucket/key.txt');
      final payload = Uint8List.fromList(utf8.encode('тело'));
      final first = _suiteSigner().sign(
        method: 'PUT',
        uri: uri,
        headers: const {'Content-Type': 'application/json'},
        payload: payload,
        timestamp: _suiteDate,
      );
      final second = _suiteSigner().sign(
        method: 'PUT',
        uri: uri,
        headers: const {'Content-Type': 'application/json'},
        payload: payload,
        timestamp: _suiteDate,
      );
      expect(first, second);
      expect(first['Authorization'], second['Authorization']);
    });

    test('порядок вызова debugCanonicalRequest не меняет sign', () {
      final uri = Uri.parse('https://s3.example.com/bucket/key.txt');
      final before = _suiteSigner().sign(
        method: 'GET',
        uri: uri,
        timestamp: _suiteDate,
      );

      final info = _suiteSigner().debugCanonicalRequest(
        method: 'GET',
        uri: uri,
        timestamp: _suiteDate,
      );

      final after = _suiteSigner().sign(
        method: 'GET',
        uri: uri,
        timestamp: _suiteDate,
      );
      expect(after, before);
      expect(
        before['Authorization'],
        endsWith(', Signature=${info.signature}'),
      );
      expect(info.signedHeaders, 'host;x-amz-content-sha256;x-amz-date');
      expect(
        info.stringToSign,
        'AWS4-HMAC-SHA256\n'
        '20150830T123600Z\n'
        '20150830/us-east-1/service/aws4_request\n'
        '${_sha256HexOfText(info.canonicalRequest)}',
      );
    });
  });
}
