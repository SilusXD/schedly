import '../../core/app_logger.dart';
import '../../core/date_utils.dart';
import '../../domain/models/schedule.dart';
import 'local_storage.dart';

/// Локальный кэш разобранных расписаний.
///
/// Ключ записи — `schedule_YYYY-MM-DD`, значение — JSON расписания (включая
/// исходный текст PDF: без него невозможно разобраться в ошибках парсинга).
/// Кэш ограничен по количеству записей, чтобы не занимать память устройства.
class ScheduleCache {
  ScheduleCache(this._storage, {AppLogger? logger}) : _logger = logger ?? appLogger;

  final LocalStorage _storage;
  final AppLogger _logger;

  static const String _prefix = 'schedule_';

  /// Сохраняет расписание, попутно подчищая старые записи.
  Future<void> save(ParsedSchedule schedule, {int maxEntries = 14}) async {
    final String key = _key(schedule.scheduleDate);
    await _storage.schedules.put(key, schedule.toJsonString(includeRawText: true));
    _logger.info('Расписание сохранено в кэш: $key');
    await prune(maxEntries: maxEntries);
  }

  /// Сохраняет расписание, полученное из облака.
  ///
  /// Отличие от [save] только в источнике: в журнале помечается, что данные
  /// пришли из облака, а не из PDF.
  Future<void> saveFromCloud(ParsedSchedule schedule, {int maxEntries = 14}) async {
    await save(schedule, maxEntries: maxEntries);
    _logger.info('Облачное расписание загружено в кэш: ${formatIsoDate(schedule.scheduleDate)}');
  }

  /// Читает расписание на конкретную дату.
  ParsedSchedule? byDate(DateTime date) => _decode(_storage.schedules.get(_key(date)));

  /// Самое свежее расписание в кэше.
  ParsedSchedule? latest() {
    ParsedSchedule? result;
    for (final String raw in _storage.schedules.values) {
      final ParsedSchedule? schedule = _decode(raw);
      if (schedule == null) {
        continue;
      }
      if (result == null || schedule.scheduleDate.isAfter(result.scheduleDate)) {
        result = schedule;
      }
    }
    return result;
  }

  /// Все расписания из кэша, отсортированные от новых к старым.
  List<ParsedSchedule> all() {
    final List<ParsedSchedule> result = <ParsedSchedule>[];
    for (final String raw in _storage.schedules.values) {
      final ParsedSchedule? schedule = _decode(raw);
      if (schedule != null) {
        result.add(schedule);
      }
    }
    result.sort((ParsedSchedule a, ParsedSchedule b) =>
        b.scheduleDate.compareTo(a.scheduleDate));
    return result;
  }

  /// Даты, для которых есть кэш.
  List<DateTime> cachedDates() =>
      all().map((ParsedSchedule schedule) => schedule.scheduleDate).toList();

  /// Удаляет расписание на дату.
  Future<void> remove(DateTime date) => _storage.schedules.delete(_key(date));

  /// Ограничивает кэш [maxEntries] самыми свежими записями.
  Future<void> prune({int maxEntries = 14}) async {
    final List<ParsedSchedule> schedules = all();
    if (schedules.length <= maxEntries) {
      return;
    }
    for (final ParsedSchedule schedule in schedules.sublist(maxEntries)) {
      await remove(schedule.scheduleDate);
      _logger.debug('Из кэша удалено старое расписание: ${formatIsoDate(schedule.scheduleDate)}');
    }
  }

  /// Полностью очищает кэш расписаний.
  Future<void> clear() => _storage.schedules.clear();

  String _key(DateTime date) => '$_prefix${formatIsoDate(date)}';

  ParsedSchedule? _decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final ParsedSchedule? schedule = ParsedSchedule.tryParse(raw);
    if (schedule == null) {
      _logger.warning('Повреждённая запись кэша расписания будет проигнорирована');
    }
    return schedule;
  }
}
