import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:schedly/app.dart';
import 'package:schedly/core/app_logger.dart';
import 'package:schedly/data/local/local_storage.dart';
import 'package:schedly/data/local/settings_store.dart';
import 'package:schedly/domain/repositories/schedule_repository.dart';
import 'package:schedly/ui/state/schedule_controller.dart';
import 'package:schedly/ui/widgets/lesson_card.dart';
import 'package:schedly/ui/widgets/offline_banner.dart';
import 'package:schedly/domain/models/lesson.dart';
import 'package:schedly/domain/models/weekday.dart';

import 'support/fakes.dart';

void main() {
  late Directory tempDir;
  late LocalStorage storage;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('schedly_widget_');
    storage = LocalStorage(logger: AppLogger(), initPathOverride: tempDir.path);
    await storage.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    await storage.settings.clear();
  });

  Future<ScheduleController> buildController(ScheduleRepository repository) async {
    return ScheduleController(
      repository: repository,
      settings: SettingsStore(storage, logger: AppLogger()),
      config: testConfig,
      // В тестовой среде системный плагин состояния сети недоступен.
      monitorConnectivity: false,
      logger: AppLogger(),
    );
  }

  testWidgets('главный экран показывает преподавателей из расписания', (
    WidgetTester tester,
  ) async {
    final FakeScheduleRepository repository = FakeScheduleRepository(
      result: ScheduleLoadResult(
        schedule: buildSampleSchedule(date: DateTime.now()),
        source: ScheduleSource.localCache,
      ),
    );
    final ScheduleController controller = await buildController(repository);
    await controller.initialize();

    await tester.pumpWidget(SchedlyApp(controller: controller));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Дневник расписания'), findsOneWidget);
    expect(find.text('Преподаватели'), findsOneWidget);
    expect(find.text('Группы'), findsOneWidget);
    expect(find.text('Иванов Иван Петрович'), findsOneWidget);
    expect(find.byType(OfflineBanner), findsOneWidget);
  });

  testWidgets('переключение на вкладку «Группы» показывает группы', (
    WidgetTester tester,
  ) async {
    final FakeScheduleRepository repository = FakeScheduleRepository(
      result: ScheduleLoadResult(
        schedule: buildSampleSchedule(date: DateTime.now()),
        source: ScheduleSource.localCache,
      ),
    );
    final ScheduleController controller = await buildController(repository);
    await controller.initialize();

    await tester.pumpWidget(SchedlyApp(controller: controller));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Группы'));
    await tester.pump();
    // Анимация переключения вкладки длится 300 мс.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('ИС-21'), findsOneWidget);
  });

  testWidgets('поиск фильтрует список', (WidgetTester tester) async {
    final FakeScheduleRepository repository = FakeScheduleRepository(
      result: ScheduleLoadResult(
        schedule: buildSampleSchedule(date: DateTime.now()),
        source: ScheduleSource.localCache,
      ),
    );
    final ScheduleController controller = await buildController(repository);
    await controller.initialize();

    await tester.pumpWidget(SchedlyApp(controller: controller));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField).first, 'Несуществующий');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Иванов Иван Петрович'), findsNothing);
  });

  testWidgets('пустое состояние предлагает повторить загрузку', (
    WidgetTester tester,
  ) async {
    final FakeScheduleRepository repository = FakeScheduleRepository(
      result: ScheduleLoadResult.empty('Расписание недоступно'),
    );
    final ScheduleController controller = await buildController(repository);
    await controller.initialize();

    await tester.pumpWidget(SchedlyApp(controller: controller));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Сообщение встречается в пустом состоянии, в строке статуса и в
    // оффлайн-баннере — важно, что оно вообще показано и есть кнопка повтора.
    expect(find.text('Расписание недоступно'), findsWidgets);
    expect(find.text('Повторить загрузку'), findsOneWidget);
  });

  testWidgets('карточка пары сохраняет домашнее задание', (
    WidgetTester tester,
  ) async {
    final List<String> saved = <String>[];
    const Lesson lesson = Lesson(
      weekday: Weekday.monday,
      pairNumber: 1,
      subject: 'Математика',
      timeStart: '08:30',
      timeEnd: '10:00',
      room: '305',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LessonCard(
            lesson: lesson,
            note: null,
            onHomeworkChanged: saved.add,
            onNoteChanged: (String value) {},
            onDoneChanged: (bool value) {},
          ),
        ),
      ),
    );

    expect(find.text('Математика'), findsOneWidget);
    expect(find.text('08:30–10:00'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Задачи 1–5');
    // Ожидаем срабатывания отложенного сохранения.
    await tester.pump(const Duration(milliseconds: 900));

    expect(saved, contains('Задачи 1–5'));
  });
}
