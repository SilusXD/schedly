import 'package:flutter_test/flutter_test.dart';
import 'package:schedly/data/parser/schedule_parser.dart';
import 'package:schedly/data/pdf/pdf_text.dart';
import 'package:schedly/domain/models/schedule.dart';
import 'package:schedly/domain/models/weekday.dart';

import '../../support/fakes.dart';

void main() {
  final ScheduleParser parser = ScheduleParser();

  group('таблица с колонками', () {
    late PdfDocumentText document;

    setUp(() {
      document = PdfDocumentText(
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
            // День не повторяется — проверяем «протягивание» значения вниз.
            buildRow(85, <MapEntry<double, String>>[
              const MapEntry<double, String>(120, '2'),
              const MapEntry<double, String>(170, '10:10-11:40'),
              const MapEntry<double, String>(240, 'Физика'),
              const MapEntry<double, String>(360, 'Петров П.П.'),
              const MapEntry<double, String>(480, 'ИС-21'),
              const MapEntry<double, String>(560, '210'),
            ]),
            buildRow(100, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, 'Вторник'),
              const MapEntry<double, String>(120, '3'),
              const MapEntry<double, String>(170, '12:20-13:50'),
              const MapEntry<double, String>(240, 'Информатика'),
              const MapEntry<double, String>(360, 'Сидоров С.С.'),
              const MapEntry<double, String>(480, 'ИС-22'),
              const MapEntry<double, String>(560, '412'),
            ]),
          ]),
        ],
      );
    });

    test('распознаёт занятия, преподавателей и группы', () {
      final ParseOutcome outcome = parser.parse(
        document,
        scheduleDate: DateTime(2026, 3, 16),
        sourceUrl: 'https://example.com/schedule.pdf',
      );

      expect(outcome.schedule.lessonCount, 3);
      expect(outcome.strategy, contains('table-columns'));
      expect(outcome.confidence, greaterThan(0.5));

      expect(outcome.schedule.teacherNames, <String>[
        'Иванов И.И.',
        'Петров П.П.',
        'Сидоров С.С.',
      ]);
      expect(outcome.schedule.groupNames, <String>['ИС-21', 'ИС-22']);
    });

    test('день недели «протягивается» на последующие строки', () {
      final ParseOutcome outcome = parser.parse(
        document,
        scheduleDate: DateTime(2026, 3, 16),
        sourceUrl: 'https://example.com/schedule.pdf',
      );

      final EntitySchedule? teacher = outcome.schedule.teacher('Иванов И.И.');
      expect(teacher, isNotNull);
      expect(teacher!.lessonsFor(Weekday.monday).length, 1);
      expect(teacher.lessonsFor(Weekday.monday).first.pairNumber, 1);

      final EntitySchedule? petrov = outcome.schedule.teacher('Петров П.П.');
      expect(petrov!.lessonsFor(Weekday.monday).length, 1);
      expect(petrov.lessonsFor(Weekday.monday).first.pairNumber, 2);
      expect(petrov.lessonsFor(Weekday.monday).first.room, '210');
    });

    test('группа видит занятия всех преподавателей', () {
      final ParseOutcome outcome = parser.parse(
        document,
        scheduleDate: DateTime(2026, 3, 16),
        sourceUrl: 'https://example.com/schedule.pdf',
      );
      final EntitySchedule? group = outcome.schedule.group('ИС-21');
      expect(group!.lessonCount, 2);
      expect(group.lessonsFor(Weekday.tuesday), isEmpty);
    });
  });

  group('матрица «дни недели × пары»', () {
    test('разбирает шахматку с днями в шапке', () {
      // Мелкий шрифт и разнесённые колонки: ячейки не должны перекрываться,
      // иначе колонки сольются в одну (в реальных PDF колонки тоже узкие).
      final PdfDocumentText document = PdfDocumentText(
        pages: <PdfPageText>[
          buildPage(<PdfTextLine>[
            buildRow(50, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, 'Пара'),
              const MapEntry<double, String>(100, 'Понедельник'),
              const MapEntry<double, String>(250, 'Вторник'),
              const MapEntry<double, String>(400, 'Среда'),
            ], fontSize: 7),
            buildRow(70, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, '1'),
              const MapEntry<double, String>(100, 'Математика, ауд. 305, Иванов И.И.'),
              const MapEntry<double, String>(250, 'Физика, каб. 210, Петров П.П.'),
            ], fontSize: 7),
            buildRow(85, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, '2'),
              const MapEntry<double, String>(400, 'История, ауд. 12, Сидоров С.С.'),
            ], fontSize: 7),
          ]),
        ],
      );

      final ParseOutcome outcome = parser.parse(
        document,
        scheduleDate: DateTime(2026, 3, 16),
        sourceUrl: 'https://example.com/matrix.pdf',
      );

      expect(outcome.strategy, contains('week-matrix'));
      expect(outcome.schedule.lessonCount, 3);

      final EntitySchedule? ivanov = outcome.schedule.teacher('Иванов И.И.');
      expect(ivanov, isNotNull);
      expect(ivanov!.lessonsFor(Weekday.monday).first.subject, contains('Математика'));
      expect(ivanov.lessonsFor(Weekday.monday).first.room, '305');

      final EntitySchedule? sidorov = outcome.schedule.teacher('Сидоров С.С.');
      expect(sidorov!.lessonsFor(Weekday.wednesday).first.pairNumber, 2);
    });
  });

  group('плоский текст', () {
    test('разбирает построчное представление', () {
      final PdfDocumentText document = PdfDocumentText(
        pages: <PdfPageText>[
          buildPage(<PdfTextLine>[
            buildRow(50, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, 'Понедельник'),
            ]),
            buildRow(65, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, '1 пара 08:30-10:00'),
            ]),
            buildRow(80, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, 'Математика'),
            ]),
            buildRow(95, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, 'Иванов И.И. 305'),
            ]),
            buildRow(110, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, 'Вторник'),
            ]),
            buildRow(125, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, '2 пара 10:10-11:40'),
            ]),
            buildRow(140, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, 'Физика'),
            ]),
            buildRow(155, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, 'Петров П.П. 210'),
            ]),
          ]),
        ],
      );

      final ParseOutcome outcome = parser.parse(
        document,
        scheduleDate: DateTime(2026, 3, 16),
        sourceUrl: 'https://example.com/flat.pdf',
      );

      expect(outcome.schedule.lessonCount, 2);

      final EntitySchedule? ivanov = outcome.schedule.teacher('Иванов И.И.');
      expect(ivanov, isNotNull);
      final List<dynamic> monday = ivanov!.lessonsFor(Weekday.monday);
      expect(monday.length, 1);
      expect(monday.first.subject, contains('Математика'));
      expect(monday.first.timeStart, '08:30');

      final EntitySchedule? petrov = outcome.schedule.teacher('Петров П.П.');
      expect(petrov!.lessonsFor(Weekday.tuesday).first.pairNumber, 2);
    });
  });

  group('ошибки разбора', () {
    test('пустой документ даёт понятную ошибку', () {
      expect(
        () => parser.parse(
          const PdfDocumentText(pages: <PdfPageText>[]),
          scheduleDate: DateTime(2026, 3, 16),
          sourceUrl: 'x',
        ),
        throwsA(isA<ScheduleParseException>()),
      );
    });

    test('PDF без текста (скан) распознаётся как ошибка', () {
      final PdfDocumentText document = PdfDocumentText(
        pages: <PdfPageText>[buildPage(const <PdfTextLine>[])],
      );
      expect(
        () => parser.parse(
          document,
          scheduleDate: DateTime(2026, 3, 16),
          sourceUrl: 'x',
        ),
        throwsA(
          isA<ScheduleParseException>().having(
            (ScheduleParseException e) => e.message,
            'message',
            contains('текстовый слой'),
          ),
        ),
      );
    });

    test('текст без структуры не даёт занятий', () {
      final PdfDocumentText document = PdfDocumentText(
        pages: <PdfPageText>[
          buildPage(<PdfTextLine>[
            buildRow(50, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, 'Документ сгенерирован автоматически'),
            ]),
            buildRow(65, <MapEntry<double, String>>[
              const MapEntry<double, String>(40, 'Страница 1 из 1'),
            ]),
          ]),
        ],
      );
      expect(
        () => parser.parse(
          document,
          scheduleDate: DateTime(2026, 3, 16),
          sourceUrl: 'x',
        ),
        throwsA(isA<ScheduleParseException>()),
      );
    });
  });
}
