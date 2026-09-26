import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../../core/app_config.dart';
import '../../core/app_logger.dart';
import '../../core/date_utils.dart';
import '../../core/lesson_key.dart';
import '../../data/local/settings_store.dart';
import '../../domain/models/lesson.dart';
import '../../domain/models/lesson_note.dart';
import '../../domain/models/schedule.dart';
import '../../domain/models/weekday.dart';
import '../../domain/repositories/schedule_repository.dart';

/// Состояние экранов расписания.
///
/// Контроллер намеренно ничего не знает про виджеты: он хранит данные,
/// заметки, состояние загрузки и сетевые статусы, а интерфейс только
/// отображает их.
class ScheduleController extends ChangeNotifier {
  ScheduleController({
    required this.repository,
    required this.settings,
    required this.config,
    this.monitorConnectivity = true,
    AppLogger? logger,
  }) : _logger = logger ?? appLogger;

  final ScheduleRepository repository;
  final SettingsStore settings;
  final AppConfig config;

  /// Следить ли за состоянием сети через системный плагин.
  ///
  /// В тестах отключается: плагин в тестовой среде недоступен, а ожидание его
  /// ответа приводит к зависанию.
  final bool monitorConnectivity;

  final AppLogger _logger;

  ScheduleLoadResult? _result;
  bool _isLoading = false;
  String _query = '';
  ScheduleEntityType _tab = ScheduleEntityType.teacher;
  Map<String, LessonNote> _notes = <String, LessonNote>{};
  bool _isOnline = true;
  String? _statusMessage;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  /// Последний результат загрузки.
  ScheduleLoadResult? get result => _result;

  /// Текущее расписание (может быть `null`).
  ParsedSchedule? get schedule => _result?.schedule;

  /// Идёт ли загрузка.
  bool get isLoading => _isLoading;

  /// Активная вкладка.
  ScheduleEntityType get tab => _tab;

  /// Поисковый запрос.
  String get query => _query;

  /// Есть ли сеть (по данным системы).
  bool get isOnline => _isOnline;

  /// Сообщение для баннера/снэкбара.
  String? get statusMessage => _statusMessage;

  /// Показаны ли данные не из сети.
  bool get isOfflineData => _result?.isOffline ?? false;

  /// Устарели ли показанные данные.
  bool get isStale => _result?.isStale ?? false;

  /// Ключ текущей учебной недели.
  String get weekKey => schedule?.weekKey ?? isoWeekKey(DateTime.now());

  /// Заметки текущей недели.
  Map<String, LessonNote> get notes => _notes;

  /// Состояние облачной синхронизации.
  String get cloudStatus => repository.cloudStatus;

  /// Запускает приложение: подписка на сеть и первичная загрузка.
  Future<void> initialize() async {
    await _subscribeConnectivity();
    await load();
  }

  /// Загружает расписание (сначала кэш, затем при необходимости — сеть).
  Future<void> load() async {
    await _run(() => repository.load());
  }

  /// Принудительно обновляет расписание.
  Future<void> refresh() async {
    await _run(() => repository.refresh());
  }

  /// Переключает вкладку «Преподаватели»/«Группы».
  void setTab(ScheduleEntityType value) {
    if (_tab == value) {
      return;
    }
    _tab = value;
    notifyListeners();
  }

  /// Устанавливает поисковый запрос.
  void setQuery(String value) {
    if (_query == value) {
      return;
    }
    _query = value;
    notifyListeners();
  }

  /// Очищает сообщение о статусе.
  void clearStatus() {
    if (_statusMessage == null) {
      return;
    }
    _statusMessage = null;
    notifyListeners();
  }

  /// Имена сущностей активной вкладки с учётом поиска.
  List<String> get visibleNames {
    final ParsedSchedule? value = schedule;
    if (value == null) {
      return const <String>[];
    }
    final List<String> all = _tab == ScheduleEntityType.teacher
        ? value.teacherNames
        : value.groupNames;
    final String needle = _normalize(_query);
    if (needle.isEmpty) {
      return all;
    }
    return all.where((String name) => _normalize(name).contains(needle)).toList();
  }

  /// Расписание выбранной сущности.
  EntitySchedule? entity(String name) => schedule?.entity(_tab, name);

  /// Расписание сущности по типу (используется на экране дневника).
  EntitySchedule? entityOf(ScheduleEntityType type, String name) =>
      schedule?.entity(type, name);

  /// Заметка для пары.
  LessonNote? noteFor({
    required ScheduleEntityType entityType,
    required String entityName,
    required Lesson lesson,
  }) {
    final String key = lessonKey(entityType: entityType, entityName: entityName, lesson: lesson);
    return _notes[key];
  }

  /// Ключ заметки для пары.
  String lessonKey({
    required ScheduleEntityType entityType,
    required String entityName,
    required Lesson lesson,
  }) =>
      buildLessonKey(
        weekKey: weekKey,
        entityType: entityType.name,
        entityName: entityName,
        weekday: lesson.weekday,
        pairNumber: lesson.pairNumber,
        subject: lesson.subject,
      );

  /// Сохраняет домашнее задание/пометку к паре.
  Future<void> saveNote({
    required ScheduleEntityType entityType,
    required String entityName,
    required Lesson lesson,
    String? homework,
    String? personalNote,
    bool? homeworkDone,
  }) async {
    final String key = lessonKey(
      entityType: entityType,
      entityName: entityName,
      lesson: lesson,
    );
    final LessonNote existing = _notes[key] ??
        LessonNote(
          lessonKey: key,
          updatedAt: DateTime.now(),
          subject: lesson.subject,
          weekKey: weekKey,
        );

    final LessonNote updated = existing.copyWith(
      homework: homework,
      personalNote: personalNote,
      homeworkDone: homeworkDone,
      subject: lesson.subject,
      weekKey: weekKey,
      updatedAt: DateTime.now(),
    );

    await repository.saveNote(updated);
    if (updated.isEmpty) {
      _notes.remove(key);
    } else {
      _notes[key] = updated;
    }
    notifyListeners();
  }

  /// Выгружает расписание в облако.
  Future<void> syncToCloud() async {
    _isLoading = true;
    notifyListeners();
    try {
      _statusMessage = await repository.syncToCloud();
      _logger.info(_statusMessage!);
    } on Object catch (error) {
      _statusMessage = 'Не удалось выгрузить в облако: ${_messageOf(error)}';
      _logger.error('Ошибка выгрузки в облако', error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Загружает расписание из облака.
  Future<void> syncFromCloud() async {
    _isLoading = true;
    notifyListeners();
    try {
      final ScheduleLoadResult fromCloud = await repository.syncFromCloud();
      _result = fromCloud;
      _statusMessage = fromCloud.message;
      _reloadNotes();
    } on Object catch (error) {
      _statusMessage = 'Не удалось загрузить из облака: ${_messageOf(error)}';
      _logger.error('Ошибка загрузки из облака', error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Перечитывает настройки облака (после их изменения на экране настроек).
  Future<void> reloadCloud() async {
    try {
      await repository.reloadCloudStorage();
    } on Object catch (error) {
      _logger.warning('Не удалось перечитать настройки облака', error);
    }
    notifyListeners();
  }

  /// Проверяет доступность ссылки на PDF (для экрана настроек).
  Future<String> checkUrl(String template) => repository.checkUrl(template);

  /// Очищает локальный кэш расписаний.
  Future<void> clearCache() async {
    await repository.clearLocalCache();
    _result = null;
    _notes = <String, LessonNote>{};
    _statusMessage = 'Локальный кэш расписаний очищен';
    notifyListeners();
  }

  /// Даты, для которых есть сохранённые расписания.
  Future<List<DateTime>> cachedDates() => repository.cachedDates();

  Future<void> _run(Future<ScheduleLoadResult> Function() action) async {
    _isLoading = true;
    notifyListeners();
    try {
      _result = await action();
      _statusMessage = _result?.message;
      _reloadNotes();
    } on Object catch (error) {
      _logger.error('Не удалось загрузить расписание', error);
      _statusMessage = 'Ошибка загрузки: ${_messageOf(error)}';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _reloadNotes() {
    try {
      _notes = repository.notesForWeek(weekKey);
    } on Object catch (error) {
      _logger.warning('Не удалось прочитать заметки', error);
      _notes = <String, LessonNote>{};
    }
  }

  Future<void> _subscribeConnectivity() async {
    if (!monitorConnectivity) {
      return;
    }
    try {
      final Connectivity connectivity = Connectivity();
      final List<ConnectivityResult> initial = await connectivity.checkConnectivity();
      _isOnline = _hasNetwork(initial);
      _connectivitySubscription =
          connectivity.onConnectivityChanged.listen((List<ConnectivityResult> results) {
        final bool online = _hasNetwork(results);
        if (online != _isOnline) {
          _isOnline = online;
          _logger.info(online ? 'Сеть появилась' : 'Сеть пропала — оффлайн-режим');
          notifyListeners();
        }
      });
    } on Object catch (error) {
      // Без плагина сетевого состояния приложение продолжает работать.
      _logger.warning('Не удалось определить состояние сети', error);
    }
  }

  static bool _hasNetwork(List<ConnectivityResult> results) => results.any(
        (ConnectivityResult result) =>
            result == ConnectivityResult.wifi ||
            result == ConnectivityResult.mobile ||
            result == ConnectivityResult.ethernet ||
            result == ConnectivityResult.vpn,
      );

  static String _normalize(String value) =>
      value.trim().toLowerCase().replaceAll('ё', 'е');

  static String _messageOf(Object error) {
    final String text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  /// Заметки по дню недели (для экрана дневника).
  List<Lesson> lessonsFor(ScheduleEntityType type, String name, Weekday weekday) =>
      entityOf(type, name)?.lessonsFor(weekday) ?? const <Lesson>[];

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }
}
