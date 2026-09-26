import 'dart:typed_data';

import 'package:schedly/core/app_config.dart';
import 'package:schedly/data/cloud/cloud_storage.dart';
import 'package:schedly/data/pdf/pdf_text.dart';
import 'package:schedly/data/pdf/pdf_text_extractor.dart';
import 'package:schedly/domain/models/lesson.dart';
import 'package:schedly/domain/models/lesson_note.dart';
import 'package:schedly/domain/models/schedule.dart';
import 'package:schedly/domain/models/weekday.dart';
import 'package:schedly/domain/repositories/schedule_repository.dart';

/// Экстрактор текста, отдающий заранее подготовленные данные.
///
/// Нужен, чтобы тестировать репозиторий и парсер без настоящих PDF-файлов.
class FakePdfTextExtractor implements PdfTextExtractor {
  FakePdfTextExtractor(this.document);

  final PdfDocumentText document;
  int calls = 0;

  @override
  String get name => 'fake';

  @override
  Future<PdfDocumentText> extract(Uint8List bytes) async {
    calls++;
    return document;
  }
}

/// Экстрактор, всегда заканчивающийся ошибкой.
class ThrowingPdfTextExtractor implements PdfTextExtractor {
  ThrowingPdfTextExtractor([this.message = 'тестовая ошибка']);

  final String message;

  @override
  String get name => 'throwing';

  @override
  Future<PdfDocumentText> extract(Uint8List bytes) async =>
      throw PdfTextExtractionException(message);
}

/// Репозиторий-заглушка для виджет-тестов.
class FakeScheduleRepository implements ScheduleRepository {
  FakeScheduleRepository({
    this.result,
    this.refreshResult,
    this.notes = const <String, LessonNote>{},
  });

  ScheduleLoadResult? result;
  ScheduleLoadResult? refreshResult;
  Map<String, LessonNote> notes;
  int saveNoteCalls = 0;
  int refreshCalls = 0;
  int clearCacheCalls = 0;
  String cloudStatusValue = 'Облако не настроено';

  @override
  String get cloudStatus => cloudStatusValue;

  @override
  Future<ScheduleLoadResult> load({bool forceRefresh = false}) async =>
      forceRefresh ? refresh() : (result ?? ScheduleLoadResult.empty('нет данных'));

  @override
  Future<ScheduleLoadResult> refresh() async {
    refreshCalls++;
    return refreshResult ?? result ?? ScheduleLoadResult.empty('нет данных');
  }

  @override
  Future<List<DateTime>> cachedDates() async => <DateTime>[];

  @override
  Map<String, LessonNote> notesForWeek(String weekKey) => notes;

  @override
  Future<void> saveNote(LessonNote note) async {
    saveNoteCalls++;
    if (note.isEmpty) {
      notes.remove(note.lessonKey);
    } else {
      notes[note.lessonKey] = note;
    }
  }

  @override
  Future<String> syncToCloud() async => 'выгружено';

  @override
  Future<ScheduleLoadResult> syncFromCloud() async =>
      result ?? ScheduleLoadResult.empty('нет данных');

  @override
  Future<void> reloadCloudStorage() async {}

  @override
  Future<String> checkUrl(String template) async => 'проверка недоступна';

  @override
  Future<void> clearLocalCache() async {
    clearCacheCalls++;
  }
}

/// Облачное хранилище в памяти для тестов.
class FakeCloudStorage implements CloudStorage {
  FakeCloudStorage({Map<String, Uint8List>? files})
      : files = files ?? <String, Uint8List>{};

  final Map<String, Uint8List> files;
  bool disposed = false;

  @override
  String get displayName => 'fake-cloud';

  @override
  bool get isConfigured => true;

  @override
  Future<void> ensureFolder(String path) async {}

  @override
  Future<List<CloudFile>> list(String folder) async => files.entries
      .where((MapEntry<String, Uint8List> entry) => entry.key.startsWith('$folder/'))
      .map(
        (MapEntry<String, Uint8List> entry) =>
            CloudFile(path: entry.key, size: entry.value.length),
      )
      .toList();

  @override
  Future<Uint8List?> read(String path) async => files[path];

  @override
  Future<void> write(String path, Uint8List bytes, {String? contentType}) async {
    files[path] = bytes;
  }

  @override
  Future<bool> delete(String path) async => files.remove(path) != null;

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  void dispose() {
    disposed = true;
  }
}

/// Готовое расписание для тестов: один преподаватель и одна группа.
ParsedSchedule buildSampleSchedule({DateTime? date}) {
  final DateTime scheduleDate = date ?? DateTime(2026, 3, 16);

  const Lesson math = Lesson(
    weekday: Weekday.monday,
    pairNumber: 1,
    subject: 'Математика',
    timeStart: '08:30',
    timeEnd: '10:00',
    teacherName: 'Иванов Иван Петрович',
    groupName: 'ИС-21',
    room: '305',
  );

  const Lesson physics = Lesson(
    weekday: Weekday.thursday,
    pairNumber: 2,
    subject: 'Физика',
    timeStart: '10:10',
    timeEnd: '11:40',
    teacherName: 'Иванов Иван Петрович',
    groupName: 'ИС-21',
    room: '210',
  );

  return ParsedSchedule(
    scheduleDate: scheduleDate,
    parsedAt: DateTime(2026, 3, 16, 7, 30),
    sourceUrl: 'https://example.com/schedule_${scheduleDate.day}.pdf',
    teachers: const <EntitySchedule>[
      EntitySchedule(
        name: 'Иванов Иван Петрович',
        type: ScheduleEntityType.teacher,
        lessons: <Lesson>[math, physics],
      ),
    ],
    groups: const <EntitySchedule>[
      EntitySchedule(
        name: 'ИС-21',
        type: ScheduleEntityType.group,
        lessons: <Lesson>[math, physics],
      ),
    ],
    rawText: 'Понедельник 1 08:30-10:00 Математика Иванов Иван Петрович 305',
  );
}

/// Страница с одной строкой текста — минимальная заготовка для тестов парсера.
PdfPageText buildPage(List<PdfTextLine> lines, {double width = 595, double height = 842}) =>
    PdfPageText(pageNumber: 1, width: width, height: height, lines: lines);

/// Строит строку из «ячеек», расположенных по указанным X-координатам.
PdfTextLine buildRow(
  double top,
  List<MapEntry<double, String>> cells, {
  double fontSize = 10,
  double pageWidth = 595,
}) {
  final List<PdfTextFragment> fragments = cells
      .map(
        (MapEntry<double, String> cell) => PdfTextFragment(
          text: cell.value,
          left: cell.key,
          right: cell.key + cell.value.length * fontSize * 0.5,
          top: top,
          bottom: top + fontSize,
          fontSize: fontSize,
        ),
      )
      .toList();
  return PdfTextLine(fragments: fragments);
}

/// Стандартная конфигурация приложения для тестов.
const AppConfig testConfig = AppConfig(
  scheduleUrlTemplate: 'https://example.com/schedule_{yyyy-MM-dd}.pdf',
  fallbackDaysBack: 2,
  downloadTimeout: Duration(seconds: 2),
  headTimeout: Duration(seconds: 2),
  maxDownloadAttempts: 1,
  initialRetryDelay: Duration(milliseconds: 1),
);
