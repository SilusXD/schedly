import 'dart:typed_data';

import '../../core/app_config.dart';
import '../../core/app_logger.dart';
import '../../core/date_utils.dart';
import 'http_client.dart';

/// Найденный PDF-файл расписания.
class SchedulePdf {
  const SchedulePdf({
    required this.bytes,
    required this.uri,
    required this.date,
  });

  /// Содержимое файла.
  final Uint8List bytes;

  /// Ссылка, с которой скачан файл.
  final Uri uri;

  /// Дата, к которой относится расписание.
  final DateTime date;

  /// Размер файла в байтах.
  int get sizeInBytes => bytes.length;

  @override
  String toString() => 'SchedulePdf(${formatIsoDate(date)}, ${bytes.length} байт, $uri)';
}

/// Расписание недоступно: ни за одну из проверенных дат файла нет.
class ScheduleNotAvailableException implements Exception {
  ScheduleNotAvailableException(this.message, {this.triedUrls = const <String>[]});

  final String message;

  /// Ссылки, которые были проверены (для диагностики).
  final List<String> triedUrls;

  @override
  String toString() => 'ScheduleNotAvailableException: $message';
}

/// Источник PDF-расписания: строит ссылку по шаблону и скачивает файл.
///
/// Шаблон содержит дату (например `https://school.ru/schedule_{yyyy-MM-dd}.pdf`),
/// поэтому источник умеет проверять несколько дат подряд: сегодняшнюю, затем
/// предыдущие — на случай, если файл за сегодня ещё не выложили или он лежит
/// под датой начала недели.
class SchedulePdfSource {
  SchedulePdfSource({
    required this.config,
    RetryHttpClient? client,
    AppLogger? logger,
  })  : _client = client ?? RetryHttpClient(config: config, logger: logger),
        _logger = logger ?? appLogger;

  final AppConfig config;
  final RetryHttpClient _client;
  final AppLogger _logger;

  /// Строит список ссылок-кандидатов: от [today] назад на [AppConfig.fallbackDaysBack] дней.
  ///
  /// Порядок важен: сначала самая свежая дата.
  List<Uri> buildCandidates(String template, {DateTime? today}) {
    final DateTime start = dateOnly(today ?? DateTime.now());
    final List<Uri> candidates = <Uri>[];

    for (int offset = -config.futureDaysForward;
        offset <= config.fallbackDaysBack;
        offset++) {
      final DateTime date = start.add(Duration(days: -offset));
      final Uri? uri = buildUri(template, date);
      if (uri == null) {
        continue;
      }
      if (candidates.any((Uri existing) => existing.toString() == uri.toString())) {
        continue;
      }
      candidates.add(uri);
    }
    return candidates;
  }

  /// Подставляет дату в шаблон и проверяет корректность полученной ссылки.
  Uri? buildUri(String template, DateTime date) {
    final String trimmed = template.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final String filled = applyDateTemplate(trimmed, date);
    final Uri? uri = Uri.tryParse(filled);
    if (uri == null) {
      _logger.warning('Некорректная ссылка, полученная из шаблона: $filled');
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      _logger.warning('Поддерживаются только http/https, получено: ${uri.scheme}');
      return null;
    }
    if (!uri.hasAuthority) {
      _logger.warning('В ссылке отсутствует домен: $filled');
      return null;
    }
    return uri;
  }

  /// Находит и скачивает самый свежий доступный PDF.
  ///
  /// [onProgress] вызывается перед проверкой каждой даты — удобно для интерфейса.
  Future<SchedulePdf> fetchLatest(
    String template, {
    DateTime? today,
    void Function(DateTime date, int index, int total)? onProgress,
  }) async {
    final List<Uri> candidates = buildCandidates(template, today: today);
    if (candidates.isEmpty) {
      throw ScheduleNotAvailableException(
        'Шаблон ссылки не задан или некорректен. Укажите адрес PDF в настройках.',
      );
    }

    final List<String> tried = <String>[];
    for (int index = 0; index < candidates.length; index++) {
      final Uri uri = candidates[index];
      final DateTime date = dateFromUri(uri) ??
          dateOnly(today ?? DateTime.now()).subtract(Duration(days: index));
      onProgress?.call(date, index + 1, candidates.length);
      tried.add(uri.toString());

      final bool available = await _client.exists(uri);
      if (!available) {
        _logger.debug('Файл за ${formatIsoDate(date)} не найден: $uri');
        continue;
      }

      final Uint8List bytes = await _client.download(uri);
      return SchedulePdf(bytes: bytes, uri: uri, date: date);
    }

    throw ScheduleNotAvailableException(
      'Расписание не найдено за последние ${config.fallbackDaysBack + 1} дней. '
      'Проверьте шаблон ссылки на экране настроек.',
      triedUrls: tried,
    );
  }

  /// Пытается извлечь дату из ссылки (имя файла содержит дату).
  DateTime? dateFromUri(Uri uri) => parseDateFromText(uri.path);

  /// Проверяет доступность конкретной ссылки (используется на экране настроек).
  Future<bool> exists(Uri uri) => _client.exists(uri);

  /// Закрывает сетевые ресурсы.
  void dispose() => _client.close();
}
