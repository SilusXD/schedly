import 'package:flutter_test/flutter_test.dart';
import 'package:schedly/core/date_utils.dart';
import 'package:schedly/domain/models/weekday.dart';

void main() {
  group('форматирование дат', () {
    test('formatIsoDate добавляет ведущие нули', () {
      expect(formatIsoDate(DateTime(2026, 3, 5)), '2026-03-05');
      expect(formatCompactDate(DateTime(2026, 12, 31)), '20261231');
      expect(formatDottedDate(DateTime(2026, 3, 5)), '05.03.2026');
    });

    test('formatRussianDate использует родительный падеж месяца', () {
      expect(formatRussianDate(DateTime(2026, 3, 15)), '15 марта 2026');
      expect(formatRussianDate(DateTime(2026, 5, 9)), '9 мая 2026');
    });

    test('formatRussianWeekdayDate показывает день недели', () {
      // 16 марта 2026 — понедельник.
      expect(formatRussianWeekdayDate(DateTime(2026, 3, 16)), 'Пн, 16 марта');
    });
  });

  group('учебная неделя', () {
    test('isoWeekStart возвращает понедельник', () {
      expect(isoWeekStart(DateTime(2026, 3, 18)), DateTime(2026, 3, 16));
      expect(isoWeekStart(DateTime(2026, 3, 16)), DateTime(2026, 3, 16));
      // Воскресенье относится к той же неделе, что и предшествующий понедельник.
      expect(isoWeekStart(DateTime(2026, 3, 22)), DateTime(2026, 3, 16));
    });

    test('isoWeekNumber считает недели по ISO-8601', () {
      expect(isoWeekNumber(DateTime(2026, 1, 1)), 1);
      expect(isoWeekNumber(DateTime(2026, 3, 16)), 12);
    });

    test('isoWeekKey формирует ключ вида yyyy-Www', () {
      expect(isoWeekKey(DateTime(2026, 3, 16)), '2026-W12');
      expect(isoWeekKey(DateTime(2026, 3, 22)), '2026-W12');
    });

    test('studyWeekDates возвращает шесть учебных дней', () {
      final List<DateTime> dates = studyWeekDates(DateTime(2026, 3, 18));
      expect(dates.length, 6);
      expect(dates.first, DateTime(2026, 3, 16));
      expect(dates.last, DateTime(2026, 3, 21));
    });
  });

  group('шаблон ссылки', () {
    final DateTime date = DateTime(2026, 3, 5);

    test('подставляет составные плейсхолдеры', () {
      expect(
        applyDateTemplate('https://x.ru/schedule_{yyyy-MM-dd}.pdf', date),
        'https://x.ru/schedule_2026-03-05.pdf',
      );
      expect(
        applyDateTemplate('https://x.ru/{dd.MM.yyyy}/file.pdf', date),
        'https://x.ru/05.03.2026/file.pdf',
      );
      expect(
        applyDateTemplate('https://x.ru/{yyyyMMdd}.pdf', date),
        'https://x.ru/20260305.pdf',
      );
    });

    test('не ломает составной формат при замене отдельных частей', () {
      // Проверка, что {yyyy} не «съедает» часть {yyyy-MM-dd}.
      expect(
        applyDateTemplate('{yyyy}-{MM}-{dd}', date),
        '2026-03-05',
      );
    });

    test('поддерживает однозначные плейсхолдеры', () {
      expect(applyDateTemplate('{d}.{M}.{yy}', date), '5.3.26');
    });
  });

  group('разбор даты из текста', () {
    test('распознаёт dd.MM.yyyy', () {
      expect(parseDateFromText('Расписание на 05.03.2026'), DateTime(2026, 3, 5));
    });

    test('распознаёт yyyy-MM-dd в имени файла', () {
      expect(parseDateFromText('schedule_2026-03-05.pdf'), DateTime(2026, 3, 5));
    });

    test('возвращает null для некорректной даты', () {
      expect(parseDateFromText('31.02.2026'), isNull);
      expect(parseDateFromText('без даты'), isNull);
    });
  });

  group('Weekday', () {
    test('parse распознаёт полные и краткие названия', () {
      expect(Weekday.parse('Понедельник'), Weekday.monday);
      expect(Weekday.parse('ПН.'), Weekday.monday);
      expect(Weekday.parse('ср'), Weekday.wednesday);
      expect(Weekday.parse('Суббота'), Weekday.saturday);
      expect(Weekday.parse('воскресенье'), isNull);
    });

    test('колонки дневника покрывают шесть дней', () {
      expect(Weekday.firstColumn, <Weekday>[
        Weekday.monday,
        Weekday.tuesday,
        Weekday.wednesday,
      ]);
      expect(Weekday.secondColumn.first, Weekday.thursday);
      expect(Weekday.diaryOrder.length, 6);
    });
  });
}
