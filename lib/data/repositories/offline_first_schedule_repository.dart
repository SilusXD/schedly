import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../core/app_config.dart';
import '../../core/app_logger.dart';
import '../../core/date_utils.dart';
import '../../domain/models/lesson_note.dart';
import '../../domain/models/schedule.dart';
import '../../domain/repositories/schedule_repository.dart';
import '../cloud/cloud_storage.dart';
import '../cloud/cloud_storage_factory.dart';
import '../local/notes_store.dart';
import '../local/schedule_cache.dart';
import '../local/settings_store.dart';
import '../parser/schedule_parser.dart';
import '../pdf/pdf_text.dart';
import '../pdf/pdf_text_extractor.dart';
import '../remote/http_client.dart';
import '../remote/schedule_pdf_source.dart';

/// Репозиторий расписания с приоритетом локальных данных (offline-first).
///
/// Полный сценарий обновления (метод [refresh]):
/// 1. скачать PDF за сегодня (с проверкой нескольких дат назад);
/// 2. извлечь текст и разобрать расписание;
/// 3. сохранить результат в локальный кэш;
/// 4. выгрузить JSON (и исходный PDF) в облачное хранилище;
/// 5. при любой ошибке шагов 1–2 отдать последнее расписание из кэша;
/// 6. если кэша нет — попробовать забрать JSON из облака;
/// 7. если данных нет нигде — вернуть «Расписание недоступно», не удаляя
///    то, что уже сохранено.
class OfflineFirstScheduleRepository implements ScheduleRepository {
  OfflineFirstScheduleRepository({
    required AppConfig config,
    required ScheduleCache cache,
    required NotesStore notes,
    required SettingsStore settings,
    required SchedulePdfSource pdfSource,
    required PdfTextExtractor extractor,
    required ScheduleParser parser,
    CloudStorage? cloudStorage,
    AppLogger? logger,
  })  : _config = config,
        _cache = cache,
        _notes = notes,
        _settings = settings,
        _pdfSource = pdfSource,
        _extractor = extractor,
        _parser = parser,
        _cloudOverride = cloudStorage,
        _logger = logger ?? appLogger;

  final AppConfig _config;
  final ScheduleCache _cache;
  final NotesStore _notes;
  final SettingsStore _settings;
  final SchedulePdfSource _pdfSource;
  final PdfTextExtractor _extractor;
  final ScheduleParser _parser;
  final CloudStorage? _cloudOverride;
  final AppLogger _logger;

  CloudStorage? _cloud;
  CloudConfig _cloudConfig = const CloudConfig();

  /// Текущее состояние облака (для интерфейса).
  String _cloudStatus = 'Облачное хранилище не настроено';

  /// Перечитывает настройки облака и пересоздаёт клиент хранилища.
  @override
  Future<void> reloadCloudStorage() async {
    final CloudConfig config = await _settings.cloudConfig();
    _cloudConfig = config;
    _cloud?.dispose();
    // В тестах хранилище подставляется напрямую, минуя сетевую фабрику.
    _cloud = _cloudOverride ?? createCloudStorage(config, logger: _logger);
    _cloudStatus = _cloud == null
        ? 'Облачное хранилище не настроено'
        : 'Облако: ${_cloud!.displayName}';
    _logger.info(_cloudStatus);
  }

  /// Настроено ли облако.
  bool get isCloudConfigured => _cloud != null;

  @override
  String get cloudStatus => _cloudStatus;

  @override
  Future<ScheduleLoadResult> load({bool forceRefresh = false}) async {
    if (forceRefresh) {
      return refresh();
    }

    final DateTime today = dateOnly(DateTime.now());
    final ParsedSchedule? cached = _cache.byDate(today) ?? _cache.latest();
    if (cached != null) {
      final bool fresh = cached.scheduleDate == today;
      return ScheduleLoadResult(
        schedule: cached,
        source: ScheduleSource.localCache,
        cachedAt: cached.parsedAt,
        message: fresh
            ? null
            : 'Показано расписание за ${formatRussianDate(cached.scheduleDate)}',
      );
    }

    return refresh();
  }

  @override
  Future<ScheduleLoadResult> refresh() async {
    final DateTime today = dateOnly(DateTime.now());
    final String template = _settings.urlTemplate(_config);
    final List<String> details = <String>[];

    try {
      final SchedulePdf pdf = await _pdfSource.fetchLatest(template);
      _logger.info('Найден PDF: $pdf');

      final PdfDocumentText documentText = await _extractor.extract(pdf.bytes);
      final ParseOutcome outcome = _parser.parse(
        documentText,
        scheduleDate: pdf.date,
        sourceUrl: pdf.uri.toString(),
      );

      await _cache.save(outcome.schedule, maxEntries: _config.maxCacheFiles);
      await _saveRawPdf(pdf.bytes, pdf.date);

      String? cloudMessage;
      if (_cloud != null && _cloudConfig.autoSync) {
        try {
          await _uploadToCloud(outcome.schedule, pdfBytes: pdf.bytes);
          cloudMessage = 'Расписание выгружено в облако';
        } on CloudStorageException catch (error) {
          // Ошибка облака не должна ломать обновление расписания.
          _logger.warning('Не удалось выгрузить расписание в облако', error);
          cloudMessage = 'Облако недоступно: ${error.message}';
          details.add('Облако: ${error.message}');
        }
      }

      return ScheduleLoadResult(
        schedule: outcome.schedule,
        source: ScheduleSource.network,
        cachedAt: outcome.schedule.parsedAt,
        message: cloudMessage,
        errorDetails: details,
      );
    } on ScheduleNotAvailableException catch (error) {
      details.add(error.message);
      _logger.warning('PDF расписания не найден', error);
    } on NetworkException catch (error) {
      details.add('Сеть: ${error.message}');
      _logger.warning('Ошибка сети при загрузке расписания', error);
    } on HttpStatusException catch (error) {
      details.add('Сервер вернул HTTP ${error.statusCode}');
      _logger.warning('Сервер вернул ошибку', error);
    } on PdfTextExtractionException catch (error) {
      details.add('Чтение PDF: ${error.message}');
      _logger.error('Не удалось извлечь текст из PDF', error);
    } on ScheduleParseException catch (error) {
      details.add('Разбор: ${error.message}');
      if (error.details != null) {
        details.addAll(error.details!);
      }
      _logger.error('Не удалось разобрать расписание', error);
    } on Object catch (error) {
      details.add('Непредвиденная ошибка: $error');
      _logger.error('Непредвиденная ошибка при обновлении расписания', error);
    }

    // Откат 1: локальный кэш.
    final ParsedSchedule? cached = _cache.byDate(today) ?? _cache.latest();
    if (cached != null) {
      return ScheduleLoadResult(
        schedule: cached,
        source: ScheduleSource.localCache,
        isOffline: true,
        cachedAt: cached.parsedAt,
        message: 'Свежее расписание получить не удалось — показаны данные '
            'за ${formatRussianDate(cached.scheduleDate)}',
        errorDetails: details,
      );
    }

    // Откат 2: облако.
    try {
      final ParsedSchedule? fromCloud = await _fetchLatestFromCloud();
      if (fromCloud != null) {
        await _cache.saveFromCloud(fromCloud, maxEntries: _config.maxCacheFiles);
        return ScheduleLoadResult(
          schedule: fromCloud,
          source: ScheduleSource.cloud,
          isOffline: true,
          cachedAt: fromCloud.parsedAt,
          message: 'Данные получены из облака',
          errorDetails: details,
        );
      }
      details.add('В облаке нет сохранённых расписаний');
    } on CloudStorageException catch (error) {
      details.add('Облако: ${error.message}');
      _logger.warning('Не удалось получить расписание из облака', error);
    }

    return ScheduleLoadResult(
      schedule: null,
      source: ScheduleSource.none,
      isOffline: true,
      message: 'Расписание недоступно',
      errorDetails: details,
    );
  }

  @override
  Future<List<DateTime>> cachedDates() async => _cache.cachedDates();

  @override
  Map<String, LessonNote> notesForWeek(String weekKey) => _notes.forWeek(weekKey);

  @override
  Future<void> saveNote(LessonNote note) => _notes.save(note);

  @override
  Future<String> syncToCloud() async {
    final CloudStorage? cloud = _cloud;
    if (cloud == null) {
      throw CloudStorageException('Облачное хранилище не настроено');
    }
    final ParsedSchedule? schedule = _cache.latest();
    if (schedule == null) {
      throw CloudStorageException('Локальный кэш пуст: сначала обновите расписание');
    }

    await _uploadToCloud(schedule);
    return 'Расписание за ${formatRussianDate(schedule.scheduleDate)} выгружено в облако';
  }

  @override
  Future<ScheduleLoadResult> syncFromCloud() async {
    final ParsedSchedule? schedule = await _fetchLatestFromCloud();
    if (schedule == null) {
      return ScheduleLoadResult.empty('В облаке нет сохранённых расписаний');
    }
    await _cache.saveFromCloud(schedule, maxEntries: _config.maxCacheFiles);
    await _settings.setLastCloudSync(DateTime.now());
    return ScheduleLoadResult(
      schedule: schedule,
      source: ScheduleSource.cloud,
      cachedAt: schedule.parsedAt,
      message: 'Загружено из облака: ${formatRussianDate(schedule.scheduleDate)}',
    );
  }

  @override
  Future<String> checkUrl(String template) async {
    final Uri? uri = _pdfSource.buildUri(template, dateOnly(DateTime.now()));
    if (uri == null) {
      return 'Некорректная ссылка: проверьте шаблон и подстановку даты';
    }
    try {
      final bool available = await _pdfSource.exists(uri);
      return available
          ? 'Файл доступен: $uri'
          : 'Файл не найден (404): $uri';
    } on Object catch (error) {
      return 'Не удалось проверить ссылку: ${error.toString()}';
    }
  }

  @override
  Future<void> clearLocalCache() async {
    await _cache.clear();
    _logger.warning('Локальный кэш расписаний очищен пользователем');
  }

  /// Выгружает расписание и (если передан) исходный PDF в хранилище.
  Future<void> _uploadToCloud(ParsedSchedule schedule, {Uint8List? pdfBytes}) async {
    final CloudStorage? cloud = _cloud;
    if (cloud == null) {
      throw CloudStorageException('Облачное хранилище не настроено');
    }

    final String base = _config.cloudFolder.trim().isEmpty
        ? 'schedules'
        : _config.cloudFolder.trim();
    await cloud.ensureFolder(base);

    final String dateKey = formatIsoDate(schedule.scheduleDate);
    // В облако кладём компактный JSON (без сырого текста PDF) — так файл
    // остаётся небольшим, а сырой текст при необходимости берётся из PDF.
    final String json = schedule.toJsonString();
    await cloud.write(
      '$base/schedule_$dateKey.json',
      Uint8List.fromList(utf8.encode(json)),
      contentType: 'application/json; charset=utf-8',
    );

    final Uint8List? bytes = pdfBytes ?? await _readRawPdf(schedule.scheduleDate);
    if (bytes != null) {
      final String rawFolder = _config.rawPdfFolder.trim().isEmpty
          ? 'raw'
          : _config.rawPdfFolder.trim();
      await cloud.ensureFolder('$base/$rawFolder');
      await cloud.write(
        '$base/$rawFolder/$dateKey.pdf',
        bytes,
        contentType: 'application/pdf',
      );
    }

    await _settings.setLastCloudSync(DateTime.now());
  }

  /// Ищет в облаке самое свежее расписание.
  Future<ParsedSchedule?> _fetchLatestFromCloud() async {
    final CloudStorage? cloud = _cloud;
    if (cloud == null) {
      return null;
    }

    final String base = _config.cloudFolder.trim().isEmpty
        ? 'schedules'
        : _config.cloudFolder.trim();

    // 1. Пробуем файл за сегодня (и за ближайшие прошедшие даты).
    final DateTime today = dateOnly(DateTime.now());
    for (int offset = 0; offset <= _config.fallbackDaysBack; offset++) {
      final DateTime date = today.subtract(Duration(days: offset));
      final Uint8List? bytes = await cloud.read('$base/schedule_${formatIsoDate(date)}.json');
      if (bytes == null) {
        continue;
      }
      final ParsedSchedule? schedule = _decodeCloudSchedule(bytes);
      if (schedule != null) {
        return schedule;
      }
    }

    // 2. Если точного совпадения нет — берём самый свежий файл в папке.
    final List<CloudFile> files = await cloud.list(base);
    final List<CloudFile> schedules = files
        .where((CloudFile file) => file.fileName.startsWith('schedule_'))
        .where((CloudFile file) => file.fileName.endsWith('.json'))
        .toList()
      ..sort((CloudFile a, CloudFile b) => b.fileName.compareTo(a.fileName));

    for (final CloudFile file in schedules) {
      final Uint8List? bytes = await cloud.read(file.path);
      if (bytes == null) {
        continue;
      }
      final ParsedSchedule? schedule = _decodeCloudSchedule(bytes);
      if (schedule != null) {
        return schedule;
      }
    }
    return null;
  }

  ParsedSchedule? _decodeCloudSchedule(Uint8List bytes) {
    try {
      final ParsedSchedule? schedule =
          ParsedSchedule.tryParse(utf8.decode(bytes, allowMalformed: true));
      if (schedule == null) {
        _logger.warning('Файл в облаке не является корректным расписанием');
      }
      return schedule;
    } on Object catch (error) {
      _logger.warning('Не удалось разобрать файл расписания из облака', error);
      return null;
    }
  }

  /// Каталог для исходных PDF (нужен для повторного разбора и диагностики).
  Future<Directory> _rawPdfDirectory() async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory directory = Directory(
      '${base.path}${Platform.pathSeparator}${_config.rawPdfFolder}',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<void> _saveRawPdf(Uint8List bytes, DateTime date) async {
    try {
      final Directory directory = await _rawPdfDirectory();
      final File file = File(
        '${directory.path}${Platform.pathSeparator}schedule_${formatIsoDate(date)}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      _logger.debug('Исходный PDF сохранён: ${file.path}');
    } on Object catch (error) {
      // Не критично: отсутствие локальной копии PDF не мешает работе.
      _logger.warning('Не удалось сохранить исходный PDF', error);
    }
  }

  Future<Uint8List?> _readRawPdf(DateTime date) async {
    try {
      final Directory directory = await _rawPdfDirectory();
      final File file = File(
        '${directory.path}${Platform.pathSeparator}schedule_${formatIsoDate(date)}.pdf',
      );
      if (!await file.exists()) {
        return null;
      }
      return file.readAsBytes();
    } on Object catch (error) {
      _logger.warning('Не удалось прочитать сохранённый PDF', error);
      return null;
    }
  }

  /// Разбирает PDF, лежащий в файловой системе (для экрана диагностики).
  Future<ScheduleLoadResult> parseLocalPdf(String path, {DateTime? date}) async {
    try {
      final File file = File(path);
      if (!await file.exists()) {
        return ScheduleLoadResult.empty('Файл не найден: $path');
      }
      final PdfDocumentText text = await _extractor.extract(await file.readAsBytes());
      final ParseOutcome outcome = _parser.parse(
        text,
        scheduleDate: date ?? dateOnly(DateTime.now()),
        sourceUrl: 'file://$path',
      );
      await _cache.save(outcome.schedule, maxEntries: _config.maxCacheFiles);
      return ScheduleLoadResult(
        schedule: outcome.schedule,
        source: ScheduleSource.localCache,
        cachedAt: outcome.schedule.parsedAt,
        message: 'Файл разобран: ${outcome.strategy}, '
            'уверенность ${outcome.confidence.toStringAsFixed(2)}',
      );
    } on Object catch (error) {
      return ScheduleLoadResult.empty('Не удалось разобрать файл: $error');
    }
  }

  /// Освобождает сетевые ресурсы.
  void dispose() {
    _cloud?.dispose();
    _pdfSource.dispose();
  }
}
