import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/app_config.dart';
import '../../core/app_logger.dart';

/// Ошибка сети или транспорта (таймаут, обрыв, DNS).
class NetworkException implements Exception {
  NetworkException(this.message, {this.uri, this.cause});

  final String message;
  final Uri? uri;
  final Object? cause;

  @override
  String toString() =>
      'NetworkException: $message${uri == null ? '' : ' ($uri)'}'
      '${cause == null ? '' : ' | $cause'}';
}

/// Сервер ответил статусом, который считается ошибкой.
class HttpStatusException implements Exception {
  HttpStatusException(this.statusCode, {required this.uri, this.reason});

  final int statusCode;
  final Uri uri;
  final String? reason;

  @override
  String toString() =>
      'HttpStatusException: HTTP $statusCode для $uri${reason == null ? '' : ' ($reason)'}';
}

/// HTTP-клиент с таймаутами и повторными попытками.
///
/// Повторы выполняются с экспоненциальной задержкой: 500 мс, 1 с, 2 с
/// (плюс небольшой случайный разброс, чтобы одновременные запросы не
/// «бились» в один момент). Повторяются только временные сбои: сетевые ошибки,
/// таймауты и коды 408/425/429/5xx. Ответы 4xx (кроме перечисленных) означают
/// окончательную ошибку и не повторяются.
class RetryHttpClient {
  RetryHttpClient({
    required this.config,
    http.Client? client,
    AppLogger? logger,
  })  : _client = client ?? http.Client(),
        _logger = logger ?? appLogger;

  final AppConfig config;
  final http.Client _client;
  final AppLogger _logger;
  final math.Random _random = math.Random();

  /// Проверяет, доступен ли ресурс.
  ///
  /// Сначала используется `HEAD`. Многие школьные веб-серверы не поддерживают
  /// `HEAD` (отвечают 405/501) или возвращают некорректные заголовки, поэтому
  /// предусмотрен резервный вариант — `GET` с заголовком `Range: bytes=0-0`.
  Future<bool> exists(Uri uri) async {
    try {
      final http.Response response = await _sendWithRetry(
        () => _client.head(uri).timeout(config.headTimeout),
        uri: uri,
        attemptLabel: 'HEAD',
      );
      if (response.statusCode == 200 || response.statusCode == 204) {
        return true;
      }
      if (response.statusCode == 404 || response.statusCode == 410) {
        return false;
      }
      if (response.statusCode == 405 || response.statusCode == 501) {
        _logger.debug('Сервер не поддерживает HEAD ($uri) — проверяем через GET Range');
      } else {
        _logger.warning('HEAD $uri вернул HTTP ${response.statusCode}');
      }
    } on NetworkException catch (error) {
      _logger.warning('HEAD-запрос не удался, пробуем GET Range', error);
    } on HttpStatusException catch (error) {
      _logger.warning('HEAD-запрос не удался', error);
    }

    try {
      final http.Response response = await _sendWithRetry(
        () => _client
            .get(uri, headers: const <String, String>{'Range': 'bytes=0-0'})
            .timeout(config.headTimeout),
        uri: uri,
        attemptLabel: 'GET Range',
      );
      if (response.statusCode == 200 || response.statusCode == 206) {
        return true;
      }
      if (response.statusCode == 404 || response.statusCode == 410) {
        return false;
      }
      return false;
    } on NetworkException {
      return false;
    } on HttpStatusException {
      return false;
    }
  }

  /// Скачивает тело целиком.
  Future<Uint8List> download(Uri uri) async {
    final http.Response response = await _sendWithRetry(
      () => _client.get(uri).timeout(config.downloadTimeout),
      uri: uri,
      attemptLabel: 'GET',
    );
    if (response.statusCode != 200) {
      throw HttpStatusException(response.statusCode, uri: uri);
    }
    final Uint8List body = response.bodyBytes;
    if (body.isEmpty) {
      throw NetworkException('Получен пустой файл', uri: uri);
    }
    _logger.info('Скачано ${body.length} байт с $uri');
    return body;
  }

  /// Универсальный GET для небольших документов (например, JSON из облака).
  Future<Uint8List> get(Uri uri, {Map<String, String>? headers}) async {
    final http.Response response = await _sendWithRetry(
      () => _client.get(uri, headers: headers).timeout(config.downloadTimeout),
      uri: uri,
      attemptLabel: 'GET',
    );
    if (response.statusCode != 200) {
      throw HttpStatusException(response.statusCode, uri: uri);
    }
    return response.bodyBytes;
  }

  /// Выполняет произвольный запрос с политикой повторов.
  Future<http.Response> send(
    Future<http.Response> Function() request, {
    required Uri uri,
    String attemptLabel = 'REQUEST',
  }) =>
      _sendWithRetry(request, uri: uri, attemptLabel: attemptLabel);

  /// Низкоуровневая отправка запроса.
  ///
  /// Нужна для методов, которые `package:http` не предоставляет напрямую
  /// (`PROPFIND`, `MKCOL`, `PUT` с телом и т. п.). Повторы выполняет вызывающий
  /// код через [send].
  Future<http.StreamedResponse> sendRaw(http.BaseRequest request) =>
      _client.send(request);

  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function() request, {
    required Uri uri,
    required String attemptLabel,
  }) async {
    final int attempts = math.max(1, config.maxDownloadAttempts);
    Object? lastError;

    for (int attempt = 1; attempt <= attempts; attempt++) {
      try {
        final http.Response response = await request();
        if (_isRetryableStatus(response.statusCode) && attempt < attempts) {
          _logger.warning(
            '$attemptLabel $uri → HTTP ${response.statusCode}, повтор $attempt/$attempts',
          );
          await _delay(attempt);
          continue;
        }
        return response;
      } on TimeoutException catch (error) {
        lastError = error;
        _logger.warning('$attemptLabel $uri: таймаут, попытка $attempt/$attempts');
      } on http.ClientException catch (error) {
        lastError = error;
        _logger.warning('$attemptLabel $uri: ошибка клиента, попытка $attempt/$attempts', error);
      } on Object catch (error) {
        lastError = error;
        _logger.warning('$attemptLabel $uri: неизвестная ошибка, попытка $attempt/$attempts', error);
      }

      if (attempt < attempts) {
        await _delay(attempt);
      }
    }

    throw NetworkException(
      'Не удалось выполнить запрос после $attempts попыток',
      uri: uri,
      cause: lastError,
    );
  }

  static bool _isRetryableStatus(int statusCode) =>
      statusCode == 408 ||
      statusCode == 425 ||
      statusCode == 429 ||
      (statusCode >= 500 && statusCode <= 599);

  Future<void> _delay(int attempt) async {
    final int baseMs = config.initialRetryDelay.inMilliseconds * (1 << (attempt - 1));
    final int jitter = _random.nextInt(math.max(1, baseMs ~/ 4));
    await Future<void>.delayed(Duration(milliseconds: baseMs + jitter));
  }

  /// Закрывает нижележащий клиент.
  void close() => _client.close();
}
