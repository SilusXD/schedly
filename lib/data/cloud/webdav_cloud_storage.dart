import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../core/app_config.dart';
import '../../core/app_logger.dart';
import '../remote/http_client.dart';
import 'cloud_storage.dart';

/// Облачное хранилище по протоколу WebDAV.
///
/// Выбрано как основной вариант синхронизации, потому что не требует ни
/// регистрации приложения, ни SDK, ни платного аккаунта: достаточно адреса
/// сервера и пары «логин + пароль приложения». Так работает Яндекс.Диск
/// (`https://webdav.yandex.ru`), а также Nextcloud/ownCloud.
class WebDavCloudStorage implements CloudStorage {
  WebDavCloudStorage({
    required this.config,
    RetryHttpClient? client,
    AppLogger? logger,
  })  : _client = client ?? RetryHttpClient(config: const AppConfig(), logger: logger),
        _logger = logger ?? appLogger;

  final CloudConfig config;
  final RetryHttpClient _client;
  final AppLogger _logger;

  @override
  String get displayName => 'WebDAV (${config.baseUri?.host ?? 'нет адреса'})';

  @override
  bool get isConfigured => config.isConfigured;

  @override
  Future<void> ensureFolder(String path) async {
    final List<String> segments =
        path.split('/').where((String part) => part.trim().isNotEmpty).toList();
    String current = '';
    for (final String segment in segments) {
      current = current.isEmpty ? segment : '$current/$segment';
      final http.Response response = await _send('MKCOL', _uri(current));
      if (response.statusCode == 201 || response.statusCode == 200) {
        _logger.debug('WebDAV: создана папка $current');
      } else if (response.statusCode == 405 ||
          response.statusCode == 301 ||
          response.statusCode == 409) {
        // 405/301 — папка уже существует; 409 — существует родитель.
        _logger.debug('WebDAV: папка $current уже существует');
      } else {
        throw CloudStorageException(
          'Не удалось создать папку «$current»',
          statusCode: response.statusCode,
        );
      }
    }
  }

  @override
  Future<List<CloudFile>> list(String folder) async {
    final Uri uri = _uri(folder);
    final http.Response response = await _send('PROPFIND', uri, depth: '1',
        body: Uint8List.fromList(utf8.encode(_propfindBody)));
    if (response.statusCode == 404) {
      return const <CloudFile>[];
    }
    if (response.statusCode != 207 && response.statusCode != 200) {
      throw CloudStorageException(
        'Не удалось получить список файлов',
        statusCode: response.statusCode,
      );
    }

    final List<CloudFile> files = <CloudFile>[];
    try {
      final XmlDocument document = XmlDocument.parse(utf8.decode(response.bodyBytes));
      for (final XmlElement element in document.findAllElements('response')) {
        final String? href = element.getElement('href')?.innerText.trim();
        if (href == null || href.isEmpty) {
          continue;
        }
        final bool isCollection = element
            .findAllElements('resourcetype')
            .any((XmlElement type) => type.findElements('collection').isNotEmpty);
        if (isCollection) {
          continue;
        }
        final DateTime? modified = DateTime.tryParse(
          element.findAllElements('getlastmodified').firstOrNull?.innerText ?? '',
        );
        final int size = int.tryParse(
              element.findAllElements('getcontentlength').firstOrNull?.innerText ?? '',
            ) ??
            0;
        files.add(CloudFile(
          path: _normalizePath(href),
          size: size,
          modified: modified,
        ));
      }
    } on XmlParserException catch (error) {
      throw CloudStorageException('Сервер вернул некорректный XML', cause: error);
    }

    return files;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final http.Response response = await _send('GET', _uri(path));
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw CloudStorageException('Не удалось прочитать файл $path',
          statusCode: response.statusCode);
    }
    return response.bodyBytes;
  }

  @override
  Future<void> write(String path, Uint8List bytes, {String? contentType}) async {
    final http.Response response = await _send(
      'PUT',
      _uri(path),
      body: bytes,
      contentType: contentType,
    );
    if (response.statusCode != 201 && response.statusCode != 200 && response.statusCode != 204) {
      throw CloudStorageException('Не удалось записать файл $path',
          statusCode: response.statusCode);
    }
    _logger.info('WebDAV: загружено $path (${bytes.length} байт)');
  }

  @override
  Future<bool> delete(String path) async {
    final http.Response response = await _send('DELETE', _uri(path));
    if (response.statusCode == 404) {
      return false;
    }
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw CloudStorageException('Не удалось удалить файл $path',
          statusCode: response.statusCode);
    }
    return true;
  }

  @override
  Future<bool> exists(String path) async {
    final http.Response response = await _send('HEAD', _uri(path));
    return response.statusCode == 200 || response.statusCode == 204;
  }

  @override
  void dispose() => _client.close();

  static const String _propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:">'
      '<d:prop><d:getcontentlength/><d:getlastmodified/><d:resourcetype/></d:prop>'
      '</d:propfind>';

  Uri _uri(String path) {
    final Uri? base = config.baseUri;
    if (base == null) {
      throw CloudStorageException('Некорректный адрес WebDAV-сервера: «${config.endpoint}»');
    }
    final List<String> segments = <String>[
      ...config.basePath.split('/'),
      ...path.split('/'),
    ].where((String part) => part.trim().isNotEmpty).toList();

    final String joined = segments.map(Uri.encodeComponent).join('/');
    return base.replace(path: '/$joined');
  }

  /// Приводит href из ответа сервера к относительному пути внутри хранилища.
  String _normalizePath(String href) {
    String value = href;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      value = Uri.parse(value).path;
    }
    value = Uri.decodeComponent(value);
    final String base = config.basePath.trim();
    if (base.isNotEmpty && value.startsWith('/$base/')) {
      value = value.substring(base.length + 2);
    } else if (value.startsWith('/')) {
      value = value.substring(1);
    }
    return value;
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Uint8List? body,
    String? contentType,
    String? depth,
  }) async {
    final Map<String, String> headers = <String, String>{
      'Authorization': _basicAuthHeader,
      'Content-Type': ?contentType,
      'Depth': ?depth,
    };

    Future<http.Response> perform() async {
      final http.Request request = http.Request(method, uri);
      request.headers.addAll(headers);
      if (body != null) {
        request.bodyBytes = body;
      }
      final http.StreamedResponse streamed =
          await _client.sendRaw(request).timeout(const Duration(seconds: 45));
      return http.Response.fromStream(streamed);
    }

    final http.Response response =
        await _client.send(perform, uri: uri, attemptLabel: method);

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw CloudStorageException(
        'WebDAV отклонил авторизацию. Проверьте логин и пароль приложения',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode >= 400 &&
        response.statusCode != 404 &&
        response.statusCode != 405 &&
        response.statusCode != 409) {
      throw CloudStorageException(
        'WebDAV вернул ошибку на запрос $method',
        statusCode: response.statusCode,
      );
    }
    return response;
  }

  String get _basicAuthHeader {
    final String token = base64Encode(utf8.encode('${config.accessKey}:${config.secretKey}'));
    return 'Basic $token';
  }
}
