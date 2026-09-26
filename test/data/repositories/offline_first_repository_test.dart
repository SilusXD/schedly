import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schedly/core/app_logger.dart';
import 'package:schedly/core/date_utils.dart';
import 'package:schedly/data/cloud/cloud_storage.dart';
import 'package:schedly/data/local/local_storage.dart';
import 'package:schedly/data/local/notes_store.dart';
import 'package:schedly/data/local/schedule_cache.dart';
import 'package:schedly/data/local/settings_store.dart';
import 'package:schedly/data/parser/schedule_parser.dart';
import 'package:schedly/data/pdf/pdf_text.dart';
import 'package:schedly/data/remote/http_client.dart';
import 'package:schedly/data/remote/schedule_pdf_source.dart';
import 'package:schedly/data/repositories/offline_first_schedule_repository.dart';
import 'package:schedly/domain/models/lesson.dart';
import 'package:schedly/domain/models/lesson_note.dart';
import 'package:schedly/domain/models/schedule.dart';
import 'package:schedly/domain/models/weekday.dart';
import 'package:schedly/domain/repositories/schedule_repository.dart';

import '../../support/fakes.dart';

/// Документ с одной табличной страницей — источник для парсера в тестах.
PdfDocumentText buildTableDocument() => PdfDocumentText(
      pages: <PdfPageText>[
        buildPage(<PdfTextLine>[
          buildRow(50, <MapEntry<double, String>>[
            const MapEntry<double, String>(40, 'День'),
            const MapEntry<double, String>(120, 'Пара'),
            const MapEntry<double, String>(170, 'Время'),
            const MapEntry<double, String>(240, 'Предмет'),
            const MapEntry<double, String>(360, 'Преподаватель'),
            const MapEntry<double, String>(480, 'Группа'),
            const MapEntry<double, String>(560, 'Аудитория'),
          ]),
          buildRow(70, <MapEntry<double, String>>[
            const MapEntry<double, String>(40, 'Понедельник'),
            const MapEntry<double, String>(120, '1'),
            const MapEntry<double, String>(170, '08:30-10:00'),
            const MapEntry<double, String>(240, 'Математика'),
            const MapEntry<double, String>(360, 'Иванов И.И.'),
            const MapEntry<double, String>(480, 'ИС-21'),
            const MapEntry<double, String>(560, '305'),
          ]),
        ]),
      ],
    );

void main() {
  // Нужен для корректной работы плагинов (path_provider, secure storage):
  // без binding они падают не «понятной» ошибкой, а сообщением о его отсутствии.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalStorage storage;
  late SettingsStore settings;
  late ScheduleCache cache;
  late NotesStore notes;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('schedly_test_');
  });

  setUp(() async {
    storage = LocalStorage(logger: AppLogger(), initPathOverride: tempDir.path);
    await storage.init();
    await storage.schedules.clear();
    await storage.notes.clear();
    await storage.settings.clear();

    settings = SettingsStore(storage, logger: AppLogger());
    cache = ScheduleCache(storage, logger: AppLogger());
    notes = NotesStore(storage, logger: AppLogger());
  });

  tearDownAll(() async {
    // Hive держит файлы открытыми: без закрытия каталог с базой не удаляется.
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  OfflineFirstScheduleRepository buildRepository({
    required http.Client client,
    PdfDocumentText? document,
    FakeCloudStorage? cloud,
  }) {
    final RetryHttpClient retryClient = RetryHttpClient(
      config: testConfig,
      client: client,
      logger: AppLogger(),
    );
    return OfflineFirstScheduleRepository(
      config: testConfig,
      cache: cache,
      notes: notes,
      settings: settings,
      pdfSource: SchedulePdfSource(
        config: testConfig,
        client: retryClient,
        logger: AppLogger(),
      ),
      extractor: FakePdfTextExtractor(document ?? buildTableDocument()),
      parser: ScheduleParser(logger: AppLogger()),
      cloudStorage: cloud,
      logger: AppLogger(),
    );
  }

  MockClient alwaysAvailableClient({int headCalls = 0, int getCalls = 0}) {
    final List<int> counters = <int>[headCalls, getCalls];
    return MockClient((http.Request request) async {
      if (request.method == 'HEAD') {
        counters[0]++;
        return http.Response('', 200);
      }
      counters[1]++;
      return http.Response.bytes(
        Uint8List.fromList(utf8.encode('%PDF-1.4 тестовый файл')),
        200,
      );
    });
  }

  group('обновление по сети', () {
    test('скачивает PDF, разбирает и кладёт в кэш', () async {
      final OfflineFirstScheduleRepository repository =
          buildRepository(client: alwaysAvailableClient());

      final ScheduleLoadResult result = await repository.refresh();

      expect(result.source, ScheduleSource.network);
      expect(result.schedule, isNotNull);
      expect(result.schedule!.lessonCount, 1);
      expect(result.schedule!.teacherNames, <String>['Иванов И.И.']);

      final List<DateTime> dates = await repository.cachedDates();
      expect(dates.length, 1);
      expect(dates.first, dateOnly(DateTime.now()).subtract(const Duration(days: 0)));
    });

    test('выгружает расписание в облако при настроенном хранилище', () async {
      final FakeCloudStorage cloud = FakeCloudStorage();
      final OfflineFirstScheduleRepository repository = buildRepository(
        client: alwaysAvailableClient(),
        cloud: cloud,
      );
      await repository.reloadCloudStorage();

      final ScheduleLoadResult result = await repository.refresh();

      expect(result.source, ScheduleSource.network);
      expect(cloud.files.keys.any((String key) => key.endsWith('.json')), isTrue);
      expect(repository.cloudStatus, contains('fake-cloud'));
    });
  });

  group('оффлайн-режим и откаты', () {
    test('при недоступном PDF отдаёт расписание из локального кэша', () async {
      final DateTime today = dateOnly(DateTime.now());
      await cache.save(buildSampleSchedule(date: today));

      final OfflineFirstScheduleRepository repository = buildRepository(
        client: MockClient((http.Request request) async => http.Response('not found', 404)),
      );

      final ScheduleLoadResult result = await repository.refresh();

      expect(result.source, ScheduleSource.localCache);
      expect(result.isOffline, isTrue);
      expect(result.schedule, isNotNull);
      expect(result.message, contains('Свежее расписание'));
      expect(result.errorDetails, isNotEmpty);
    });

    test('load() отдаёт кэш без обращения к сети', () async {
      int networkCalls = 0;
      await cache.save(buildSampleSchedule(date: dateOnly(DateTime.now())));

      final OfflineFirstScheduleRepository repository = buildRepository(
        client: MockClient((http.Request request) async {
          networkCalls++;
          return http.Response('not found', 404);
        }),
      );

      final ScheduleLoadResult result = await repository.load();

      expect(result.source, ScheduleSource.localCache);
      expect(networkCalls, 0);
    });

    test('при отсутствии кэша берёт расписание из облака', () async {
      final DateTime today = dateOnly(DateTime.now());
      final ParsedSchedule cloudSchedule = buildSampleSchedule(date: today);
      final FakeCloudStorage cloud = FakeCloudStorage(
        files: <String, Uint8List>{
          'schedules/schedule_${formatIsoDate(today)}.json': Uint8List.fromList(
            utf8.encode(cloudSchedule.toJsonString()),
          ),
        },
      );

      final OfflineFirstScheduleRepository repository = buildRepository(
        client: MockClient((http.Request request) async => http.Response('not found', 404)),
        cloud: cloud,
      );
      await repository.reloadCloudStorage();

      final ScheduleLoadResult result = await repository.refresh();

      expect(result.source, ScheduleSource.cloud);
      expect(result.schedule, isNotNull);
      expect(result.schedule!.lessonCount, cloudSchedule.lessonCount);
    });

    test('без сети, кэша и облака сообщает «Расписание недоступно»', () async {
      final OfflineFirstScheduleRepository repository = buildRepository(
        client: MockClient((http.Request request) async => http.Response('not found', 404)),
      );

      final ScheduleLoadResult result = await repository.refresh();

      expect(result.source, ScheduleSource.none);
      expect(result.hasData, isFalse);
      expect(result.message, 'Расписание недоступно');
      expect(result.errorDetails, isNotEmpty);
    });

    test('битый PDF не роняет приложение, а уходит в откат', () async {
      final DateTime today = dateOnly(DateTime.now());
      await cache.save(buildSampleSchedule(date: today));

      final RetryHttpClient retryClient = RetryHttpClient(
        config: testConfig,
        client: alwaysAvailableClient(),
        logger: AppLogger(),
      );
      final OfflineFirstScheduleRepository repository = OfflineFirstScheduleRepository(
        config: testConfig,
        cache: cache,
        notes: notes,
        settings: settings,
        pdfSource: SchedulePdfSource(
          config: testConfig,
          client: retryClient,
          logger: AppLogger(),
        ),
        extractor: ThrowingPdfTextExtractor('повреждённый PDF'),
        parser: ScheduleParser(logger: AppLogger()),
        logger: AppLogger(),
      );

      final ScheduleLoadResult result = await repository.refresh();

      expect(result.source, ScheduleSource.localCache);
      expect(result.errorDetails.any((String line) => line.contains('повреждённый PDF')), isTrue);
    });
  });

  group('заметки', () {
    test('сохраняются и читаются по неделе', () async {
      await cache.save(buildSampleSchedule(date: DateTime(2026, 3, 16)));
      final OfflineFirstScheduleRepository repository =
          buildRepository(client: alwaysAvailableClient());

      const Lesson lesson = Lesson(
        weekday: Weekday.monday,
        pairNumber: 1,
        subject: 'Математика',
      );
      await repository.saveNote(
        LessonNote(
          lessonKey: '2026-W12|teacher|ivanov|1|1|matematika',
          updatedAt: DateTime.now(),
          homework: 'Задачи 1–5',
          subject: lesson.subject,
          weekKey: '2026-W12',
        ),
      );

      final Map<String, LessonNote> week = repository.notesForWeek('2026-W12');
      expect(week.length, 1);
      expect(week.values.first.homework, 'Задачи 1–5');

      expect(repository.notesForWeek('2026-W13'), isEmpty);
    });

    test('пустая заметка удаляется из хранилища', () async {
      final OfflineFirstScheduleRepository repository =
          buildRepository(client: alwaysAvailableClient());

      await repository.saveNote(
        LessonNote(lessonKey: 'k', updatedAt: DateTime.now(), homework: 'текст'),
      );
      expect(notes.count, 1);

      await repository.saveNote(LessonNote(lessonKey: 'k', updatedAt: DateTime.now()));
      expect(notes.count, 0);
    });
  });

  group('облако', () {
    test('syncToCloud без настроек сообщает об ошибке', () async {
      final OfflineFirstScheduleRepository repository =
          buildRepository(client: alwaysAvailableClient());

      expect(
        () => repository.syncToCloud(),
        throwsA(isA<CloudStorageException>()),
      );
    });

    test('syncFromCloud возвращает пустой результат при отсутствии данных', () async {
      final OfflineFirstScheduleRepository repository = buildRepository(
        client: alwaysAvailableClient(),
        cloud: FakeCloudStorage(),
      );
      await repository.reloadCloudStorage();

      final ScheduleLoadResult result = await repository.syncFromCloud();

      expect(result.hasData, isFalse);
      expect(result.source, ScheduleSource.none);
    });

    test('checkUrl сообщает о некорректном шаблоне', () async {
      final OfflineFirstScheduleRepository repository =
          buildRepository(client: alwaysAvailableClient());

      final String result = await repository.checkUrl('это не ссылка');
      expect(result, contains('Некорректная ссылка'));
    });

    test('checkUrl подтверждает доступный файл', () async {
      final OfflineFirstScheduleRepository repository =
          buildRepository(client: alwaysAvailableClient());

      final String result = await repository.checkUrl(
        'https://example.com/schedule_{yyyy-MM-dd}.pdf',
      );
      expect(result, contains('доступен'));
    });
  });
}
