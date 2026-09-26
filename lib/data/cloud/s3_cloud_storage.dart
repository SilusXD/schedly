import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../core/app_config.dart';
import '../../core/app_logger.dart';
import '../remote/http_client.dart';
import 'cloud_storage.dart';
import 'sigv4.dart';

/// Облачное хранилище, совместимое с Amazon S3.
///
/// Один и тот же адаптер работает с:
/// * Yandex Object Storage (`https://storage.yandexcloud.net`, region `ru-central1`);
/// * MinIO и другими self-hosted S3 (`usePathStyle = true`);
/// * AWS S3;
/// * Google Cloud Storage / Firebase Storage — через режим совместимости
///   (XML API + HMAC-ключи сервисного аккаунта), адрес `https://storage.googleapis.com`.
///
/// Такой выбор позволяет закрыть требование «облачное хранилище» без Firebase
/// SDK и без `GoogleService-Info.plist`, то есть без лишних нативных
/// зависимостей в iOS-сборке.
class S3CloudStorage implements CloudStorage {
  S3CloudStorage({
    required this.config,
    RetryHttpClient? client,
    AppLogger? logger,
  })  : _client = client ?? RetryHttpClient(config: const AppConfig(), logger: logger),
        _logger = logger ?? appLogger;

  final CloudConfig config;
  final RetryHttpClient _client;
  final AppLogger _logger;

  late final AwsSigV4Signer _signer = AwsSigV4Signer(
    credentials: AwsCredentials(
      accessKeyId: config.accessKey,
      secretAccessKey: config.secretKey,
    ),
    region: config.region.trim().isEmpty ? 'us-east-1' : config.region.trim(),
    service: 's3',
  );

  @override
  String get displayName => 'S3 (${config.bucket} @ ${config.baseUri?.host ?? '?'})';

  @override
  bool get isConfigured => config.isConfigured;

  /// У S3 нет настоящих папок — структура задаётся ключами объектов.
  @override
  Future<void> ensureFolder(String path) async {
    // Специально ничего не делаем: «папка» появится вместе с первым объектом.
  }

  @override
  Future<List<CloudFile>> list(String folder) async {
    final String prefix = _prefix(folder);
    final Uri uri = _objectUri('', queryParameters: <String, String>{
      'list-type': '2',
      'prefix': prefix,
      'delimiter': '/',
      'max-keys': '1000',
    });

    final http.Response response = await _signedRequest('GET', uri);
    if (response.statusCode == 404) {
      return const <CloudFile>[];
    }
    if (response.statusCode != 200) {
      throw _errorFor('получение списка файлов', response);
    }

    final List<CloudFile> files = <CloudFile>[];
    try {
      final XmlDocument document = XmlDocument.parse(utf8.decode(response.bodyBytes));
      for (final XmlElement element in document.findAllElements('Contents')) {
        final String key = element.getElement('Key')?.innerText ?? '';
        if (key.isEmpty || key.endsWith('/')) {
          continue;
        }
        files.add(CloudFile(
          path: _stripBasePath(key),
          size: int.tryParse(element.getElement('Size')?.innerText ?? '') ?? 0,
          modified:
              DateTime.tryParse(element.getElement('LastModified')?.innerText ?? ''),
          etag: element.getElement('ETag')?.innerText.replaceAll('"', ''),
        ));
      }
    } on XmlParserException catch (error) {
      throw CloudStorageException('S3 вернул некорректный XML', cause: error);
    }
    return files;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final http.Response response =
        await _signedRequest('GET', _objectUri(_key(path)));
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw _errorFor('чтение файла $path', response);
    }
    return response.bodyBytes;
  }

  @override
  Future<void> write(String path, Uint8List bytes, {String? contentType}) async {
    final http.Response response = await _signedRequest(
      'PUT',
      _objectUri(_key(path)),
      payload: bytes,
      extraHeaders: <String, String>{
        'content-type': contentType ?? 'application/octet-stream',
      },
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _errorFor('запись файла $path', response);
    }
    _logger.info('S3: загружено $path (${bytes.length} байт)');
  }

  @override
  Future<bool> delete(String path) async {
    final http.Response response =
        await _signedRequest('DELETE', _objectUri(_key(path)));
    if (response.statusCode == 404) {
      return false;
    }
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw _errorFor('удаление файла $path', response);
    }
    return true;
  }

  @override
  Future<bool> exists(String path) async {
    final http.Response response =
        await _signedRequest('HEAD', _objectUri(_key(path)));
    if (response.statusCode == 404) {
      return false;
    }
    if (response.statusCode == 200) {
      return true;
    }
    throw _errorFor('проверку файла $path', response);
  }

  @override
  void dispose() => _client.close();

  /// Полный ключ объекта: `<basePath>/<path>`.
  String _key(String path) {
    final String base = config.basePath.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    final String clean = path.trim().replaceAll(RegExp(r'^/+'), '');
    return base.isEmpty ? clean : '$base/$clean';
  }

  String _prefix(String folder) {
    final String key = _key(folder);
    return key.isEmpty ? '' : '$key/';
  }

  String _stripBasePath(String key) {
    final String base = config.basePath.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (base.isNotEmpty && key.startsWith('$base/')) {
      return key.substring(base.length + 1);
    }
    return key;
  }

  /// Формирует адрес объекта с учётом path-style или virtual-hosted адресации.
  Uri _objectUri(String key, {Map<String, String>? queryParameters}) {
    final Uri? base = config.baseUri;
    if (base == null) {
      throw CloudStorageException('Некорректный адрес S3: «${config.endpoint}»');
    }
    final String bucket = config.bucket.trim();
    if (bucket.isEmpty) {
      throw CloudStorageException('Не указан бакет (bucket)');
    }

    final String encodedKey = key.isEmpty
        ? ''
        : key.split('/').map(Uri.encodeComponent).join('/');

    if (config.usePathStyle) {
      final String path = '/$bucket${encodedKey.isEmpty ? '' : '/$encodedKey'}';
      return Uri(
        scheme: base.scheme,
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: path,
        queryParameters: queryParameters,
      );
    }

    final String host = base.host;
    return Uri(
      scheme: base.scheme,
      host: '$bucket.$host',
      port: base.hasPort ? base.port : null,
      path: encodedKey.isEmpty ? '/' : '/$encodedKey',
      queryParameters: queryParameters,
    );
  }

  Future<http.Response> _signedRequest(
    String method,
    Uri uri, {
    Uint8List? payload,
    Map<String, String>? extraHeaders,
  }) async {
    final Map<String, String> headers = <String, String>{...?extraHeaders};
    final Map<String, String> signed = _signer.sign(
      method: method,
      uri: uri,
      headers: headers,
      payload: payload,
    );

    // Заголовок Host формируется HTTP-клиентом самостоятельно; подпись уже
    // посчитана с правильным host, поэтому при отправке его не дублируем.
    final Map<String, String> sendHeaders = Map<String, String>.of(signed)
      ..remove('host')
      ..remove('Host');

    Future<http.Response> perform() async {
      final http.Request request = http.Request(method, uri);
      request.headers.addAll(sendHeaders);
      if (payload != null) {
        request.bodyBytes = payload;
      }
      final http.StreamedResponse streamed =
          await _client.sendRaw(request).timeout(const Duration(seconds: 45));
      return http.Response.fromStream(streamed);
    }

    return _client.send(perform, uri: uri, attemptLabel: 'S3 $method');
  }

  CloudStorageException _errorFor(String action, http.Response response) {
    final String body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final String detail = _extractAwsMessage(body);
    return CloudStorageException(
      'S3: ошибка при выполнении операции «$action»${detail.isEmpty ? '' : ': $detail'}',
      statusCode: response.statusCode,
    );
  }

  static String _extractAwsMessage(String xml) {
    if (xml.trim().isEmpty) {
      return '';
    }
    try {
      final XmlDocument document = XmlDocument.parse(xml);
      return document.findAllElements('Message').firstOrNull?.innerText ?? '';
    } on XmlParserException {
      return '';
    }
  }
}
