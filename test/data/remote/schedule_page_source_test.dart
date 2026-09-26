import 'package:flutter_test/flutter_test.dart';
import 'package:schedly/data/remote/schedule_page_source.dart';

/// Фрагмент реальной страницы КИП (структура ссылок сохранена).
const String _html = '''
<div class="news-list">
  <a href="/upload/constructor/279/gzg8yvpd1aydg3algcdsejy2celg4sl8/Raspisanie-_obshchee_-26.09.pdf">Расписание на 26.09.2026</a>
  <span>PDF</span>
  <a href="/upload/constructor/3a5/yqv7pli1faei3nzk43kstpzu3o5otisz/Raspisanie-_obshchee_-28.09.pdf">Расписание на 28.09.2026</a>
  <a href="/upload/constructor/71f/ei37levshj3bq67jy5exbc2pgrsqnzlf/Raspisanie-1-polugodie-2026_2027_1-kurs.pdf">Для студентов 1 курса</a>
  <a href="/upload/constructor/9f3/9fgrbt8qpdy94i790docveijr1xky6g4/Dlya-studentov-2-kursa.pdf">Для студентов 2 курса</a>
  <a href="/upload/constructor/409/3c84l15u2l0ezh22ulwfir73wys6ko2w/Dlya-studentov-3-kursa.pdf">Для студентов 3 курса</a>
  <a href="/upload/constructor/012/az1g8ea1qro0u367c1we8xe5irhnjh7y/Dlya-studentov-4-kursa.pdf">Для студентов 4 курса</a>
  <a href="/upload/constructor/a0a/3nreoijnwzv0r11fc52c2im61dl9tgk9/Raspisanie-1k-o3-1ozRUPO_2026-2026_2027-1-polugodie.pdf">Для студентов 1 курса очно-заочной формы обучения гр. 1озРУПО-2026</a>
  <a href="/media/logo.png">Логотип</a>
  <a href="/kip/students/gup.php">График учебного процесса</a>
</div>
''';

void main() {
  final Uri pageUri = Uri.parse('https://www.fa.ru/kip/students/schedule.php');
  final SchedulePageIndex index = SchedulePageSource.parseIndex(pageUri, _html);

  group('разбор страницы-каталога', () {
    test('находит ежедневные и полугодовые файлы, игнорируя прочие ссылки', () {
      expect(index.daily.length, 2);
      expect(index.semester.length, 5);
      expect(index.isEmpty, isFalse);
    });

    test('дата ежедневного файла берётся из подписи ссылки', () {
      expect(index.daily.first.date, DateTime(2026, 9, 28));
      expect(index.daily.last.date, DateTime(2026, 9, 26));
    });

    test('ссылки преобразуются в абсолютные', () {
      expect(
        index.daily.first.uri.toString(),
        startsWith('https://www.fa.ru/upload/constructor/'),
      );
      expect(index.daily.first.uri.path, endsWith('.pdf'));
    });

    test('курс и форма обучения распознаются', () {
      final SchedulePageLink? second = index.semesterForCourse(2);
      expect(second, isNotNull);
      expect(second!.course, 2);
      expect(second.extramural, isFalse);

      final SchedulePageLink extramural = index.semester
          .firstWhere((SchedulePageLink link) => link.extramural);
      expect(extramural.course, 1);
      expect(extramural.groupHint, '1озРУПО-2026');
    });
  });

  group('выбор файла на дату', () {
    test('точное совпадение даты', () {
      final SchedulePageLink? link = index.dailyFor(DateTime(2026, 9, 28));
      expect(link, isNotNull);
      expect(link!.date, DateTime(2026, 9, 28));
    });

    test('для дня без файла берётся ближайшее прошедшее расписание', () {
      // Воскресенье 27.09 — файла нет, актуально расписание за 26.09.
      final SchedulePageLink? link = index.dailyFor(DateTime(2026, 9, 27));
      expect(link, isNotNull);
      expect(link!.date, DateTime(2026, 9, 26));
    });

    test('далёкое будущее — берётся самое свежее расписание', () {
      final SchedulePageLink? link = index.dailyFor(DateTime(2026, 10, 10));
      expect(link, isNotNull);
      expect(link!.date, DateTime(2026, 9, 28));
    });
  });

  group('выбор полугодового расписания', () {
    test('по группе определяется курс', () {
      final SchedulePageLink? link = index.semesterForGroup('2ОИБАС-1825');
      expect(link, isNotNull);
      expect(link!.course, 2);
    });

    test('очно-заочная группа получает свой файл', () {
      final SchedulePageLink? link = index.semesterForGroup('1озРУПО-2026');
      expect(link, isNotNull);
      expect(link!.groupHint, '1озРУПО-2026');
      expect(link.extramural, isTrue);
    });

    test('semesterForAllCourses отдаёт по одному файлу на курс', () {
      final List<SchedulePageLink> links = index.semesterForAllCourses();
      expect(links.length, 4);
      expect(links.map((SchedulePageLink l) => l.course).toList(), <int>[1, 2, 3, 4]);
      expect(links.every((SchedulePageLink l) => !l.extramural), isTrue);
    });

    test('неизвестная группа не ломает выбор', () {
      expect(index.semesterForGroup(''), isNull);
      expect(index.semesterForGroup('без-цифр'), isNull);
    });
  });

  group('устойчивость разбора', () {
    test('пустой HTML даёт пустой индекс', () {
      final SchedulePageIndex empty =
          SchedulePageSource.parseIndex(pageUri, '<html><body>нет ссылок</body></html>');
      expect(empty.isEmpty, isTrue);
      expect(empty.dailyFor(DateTime(2026, 9, 26)), isNull);
      expect(empty.semesterForCourse(1), isNull);
    });

    test('ссылки без .pdf игнорируются', () {
      final SchedulePageIndex value = SchedulePageSource.parseIndex(
        pageUri,
        '<a href="/docs/plan.doc">План</a><a href="/docs/s.pdf">Расписание на 01.09.2026</a>',
      );
      expect(value.daily.length, 1);
      expect(value.daily.first.date, DateTime(2026, 9, 1));
    });
  });
}
