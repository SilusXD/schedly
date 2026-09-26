import '../models/lesson_note.dart';
import '../models/schedule.dart';

/// Откуда взято показанное расписание.
enum ScheduleSource {
  /// Скачано с сайта учебного заведения и разобрано на этом устройстве.
  network('С сайта учебного заведения'),

  /// Взято из локального кэша (сайт или сеть недоступны).
  localCache('Из локального кэша'),

  /// Получено из облачного хранилища (с другого устройства).
  cloud('Из облачного хранилища'),

  /// Данных нет вообще.
  none('Нет данных');

  const ScheduleSource(this.title);

  /// Подпись для интерфейса.
  final String title;
}

/// Результат попытки получить расписание.
class ScheduleLoadResult {
  const ScheduleLoadResult({
    required this.schedule,
    required this.source,
    this.message,
    this.isOffline = false,
    this.cachedAt,
    this.errorDetails = const <String>[],
  });

  /// Разобранное расписание, либо `null`, если данных нет.
  final ParsedSchedule? schedule;

  /// Источник данных.
  final ScheduleSource source;

  /// Сообщение для пользователя (причина использования кэша и т. п.).
  final String? message;

  /// Признак оффлайн-режима: показаны данные не из сети.
  final bool isOffline;

  /// Когда данные были получены (для кэша — время разбора PDF).
  final DateTime? cachedAt;

  /// Подробности для экрана диагностики.
  final List<String> errorDetails;

  /// Есть ли что показать.
  bool get hasData => schedule != null;

  /// Устарели ли данные (кэш не за сегодня).
  bool get isStale {
    final ParsedSchedule? value = schedule;
    if (value == null) {
      return false;
    }
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    return value.scheduleDate.isBefore(today);
  }

  /// Результат «данных нет».
  factory ScheduleLoadResult.empty(String message) => ScheduleLoadResult(
        schedule: null,
        source: ScheduleSource.none,
        message: message,
        isOffline: true,
      );

  @override
  String toString() => 'ScheduleLoadResult(${source.name}, '
      'данные: ${schedule == null ? 'нет' : schedule.toString()})';
}

/// Репозиторий расписания: единая точка доступа к данным для интерфейса.
abstract interface class ScheduleRepository {
  /// Загружает расписание.
  ///
  /// Если [forceRefresh] = true, сначала выполняется попытка получить свежий PDF.
  /// Иначе при наличии кэша данные отдаются немедленно (offline-first), а
  /// обновление выполняется отдельным вызовом [refresh].
  Future<ScheduleLoadResult> load({bool forceRefresh = false});

  /// Принудительно обновляет расписание по полному сценарию:
  /// PDF за сегодня → парсинг → локальный кэш → облако, с откатом на кэш и
  /// облако при любой ошибке.
  Future<ScheduleLoadResult> refresh();

  /// Даты, для которых есть данные в локальном кэше.
  Future<List<DateTime>> cachedDates();

  /// Заметки и домашние задания для учебной недели.
  Map<String, LessonNote> notesForWeek(String weekKey);

  /// Сохраняет заметку к паре.
  Future<void> saveNote(LessonNote note);

  /// Выгружает последнее расписание в облако вручную.
  Future<String> syncToCloud();

  /// Загружает самое свежее расписание из облака.
  Future<ScheduleLoadResult> syncFromCloud();

  /// Перечитывает настройки облачного хранилища (после их изменения).
  Future<void> reloadCloudStorage();

  /// Проверяет, доступен ли PDF по указанному шаблону ссылки.
  ///
  /// Возвращает человекочитаемый результат проверки для экрана настроек.
  Future<String> checkUrl(String template);

  /// Полностью очищает локальный кэш расписаний (заметки не затрагиваются).
  Future<void> clearLocalCache();

  /// Сообщение о состоянии облачной синхронизации для интерфейса.
  String get cloudStatus;
}
