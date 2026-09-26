import 'dart:convert';
import 'dart:typed_data';

import '../../core/app_config.dart';
import '../../core/app_logger.dart';
import '../../core/date_utils.dart';
import 'http_client.dart';
import 'schedule_pdf_source.dart';

/// Ссылка на файл расписания, найденная на странице-каталоге.
///
/// Для КИП Фин.университета страница `schedule.php` публикует два вида файлов:
/// * ежедневное «общее» расписание — `Расписание на 26.09.2026`;
/// * полугодовые расписания по курсам — `Для студентов 2 курса`.
///
/// Имя файла содержит случайный хеш (`/upload/constructor/<hex>/<hash>/…`),
/// который меняется при каждой публикации, поэтому ссылку нельзя собрать по
/// шаблону с датой — её нужно извлекать со страницы.
class SchedulePageLink {
  const SchedulePageLink({
    required this.uri,
    required this.title,
    this.date,
    this.course,
    this.extramural = false,
    this.isSemester = false,
    this.groupHint = '',
    this.originalHref = '',
  });

  /// Абсолютная ссылка на PDF.
  final Uri uri;

  /// Подпись ссылки со страницы.
  final String title;

  /// Дата расписания (только для ежедневных файлов).
  final DateTime? date;

  /// Номер курса (только для полугодовых файлов).
  final int? course;

  /// Очно-заочная форма обучения.
  final bool extramural;

  /// Является ли файл полугодовым расписанием.
  final bool isSemester;

  /// Обозначение группы, если оно указано в подписи («1озРУПО-2026»).
  final String groupHint;

  /// Исходный `href` со страницы (для диагностики).
  final String originalHref;

  @override
  String toString() => 'SchedulePageLink(${date == null ? '' : formatIsoDate(date!)} '
      'курс=${course ?? '-'}${extramural ? ' (очно-заочно)' : ''} "$title" → $uri)';
}

/// Индекс ссылок, собранный со страницы расписания.
class SchedulePageIndex {
  const SchedulePageIndex({
    required this.pageUri,
    required this.daily,
    required this.semester,
  });

  /// Адрес страницы.
  final Uri pageUri;

  /// Ежедневные «общие» расписания.
  final List<SchedulePageLink> daily;

  /// Полугодовые расписания по курсам.
  final List<SchedulePageLink> semester;

  /// Есть ли хоть одна ссылка.
  bool get isEmpty => daily.isEmpty && semester.isEmpty;

  /// Ежедневное расписание на [date]: точное совпадение, затем ближайшее
  /// прошедшее, затем ближайшее будущее.
  ///
  /// Такой порядок связан с тем, что файл за сегодня может быть ещё не
  /// опубликован (например, в выходные или рано утром), а расписание на
  /// текущую неделю остаётся актуальным.
  SchedulePageLink? dailyFor(DateTime date, {int lookBackDays = 7}) {
    if (daily.isEmpty) {
      return null;
    }
    final DateTime target = dateOnly(date);
    final List<SchedulePageLink> dated = daily
        .where((SchedulePageLink link) => link.date != null)
        .toList()
      ..sort((SchedulePageLink a, SchedulePageLink b) =>
          b.date!.compareTo(a.date!));

    for (final SchedulePageLink link in dated) {
      if (dateOnly(link.date!) == target) {
        return link;
      }
    }
    for (final SchedulePageLink link in dated) {
      final DateTime value = dateOnly(link.date!);
      final int diff = target.difference(value).inDays;
      if (diff > 0 && diff <= lookBackDays) {
        return link;
      }
    }
    for (final SchedulePageLink link in dated.reversed) {
      if (dateOnly(link.date!).isAfter(target)) {
        return link;
      }
    }
    return dated.isEmpty ? null : dated.first;
  }

  /// Полугодовое расписание для конкретной группы.
  ///
  /// Сначала ищется точное совпадение по группе из подписи, затем — по курсу
  /// (первая цифра обозначения группы) и форме обучения.
  SchedulePageLink? semesterForGroup(String groupName) {
    if (semester.isEmpty) {
      return null;
    }
    final String group = _normalizeGroup(groupName);
    if (group.isEmpty) {
      return null;
    }
    for (final SchedulePageLink link in semester) {
      if (link.groupHint.isNotEmpty && _normalizeGroup(link.groupHint) == group) {
        return link;
      }
    }
    final RegExpMatch? courseMatch = RegExp(r'(\d)').firstMatch(group);
    final int? course = courseMatch == null ? null : int.tryParse(courseMatch.group(1)!);
    if (course == null) {
      return null;
    }
    final bool extramural = group.contains('оз');
    return semesterForCourse(course, extramural: extramural);
  }

  /// Полугодовое расписание курса (при наличии — с учётом формы обучения).
  SchedulePageLink? semesterForCourse(int course, {bool extramural = false}) {
    final List<SchedulePageLink> matching = semester
        .where((SchedulePageLink link) => link.course == course)
        .toList();
    if (matching.isEmpty) {
      return null;
    }
    for (final SchedulePageLink link in matching) {
      if (link.extramural == extramural && link.groupHint.isEmpty) {
        return link;
      }
    }
    for (final SchedulePageLink link in matching) {
      if (!link.extramural) {
        return link;
      }
    }
    return matching.first;
  }

  /// Все полугодовые файлы (нужны, когда группа пользователя неизвестна).
  List<SchedulePageLink> semesterForAllCourses() {
    final Map<int, SchedulePageLink> byCourse = <int, SchedulePageLink>{};
    for (final SchedulePageLink link in semester) {
      final int? course = link.course;
      if (course == null || link.extramural || link.groupHint.isNotEmpty) {
        continue;
      }
      byCourse[course] = link;
    }
    final List<int> courses = byCourse.keys.toList()..sort();
    return courses.map((int course) => byCourse[course]!).toList();
  }

  static String _normalizeGroup(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').toLowerCase().replaceAll('ё', 'е');
}

/// Источник ссылок со страницы-каталога расписаний.
class SchedulePageSource {
  SchedulePageSource({
    required AppConfig config,
    RetryHttpClient? client,
    AppLogger? logger,
  })  : _client = client ?? RetryHttpClient(config: config, logger: logger),
        _logger = logger ?? appLogger;

  final RetryHttpClient _client;
  final AppLogger _logger;

  static final RegExp _anchorPattern = RegExp(
    r'<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*>(.*?)</a>',
    caseSensitive: false,
    dotAll: true,
  );
  static const List<String> _htmlEntities = <String>[
    '&nbsp;',
    '&amp;',
    '&laquo;',
    '&raquo;',
    '&quot;',
    '&#039;',
  ];

  /// Скачивает страницу и собирает индекс ссылок.
  Future<SchedulePageIndex> fetchIndex(String pageUrl) async {
    final Uri? uri = Uri.tryParse(pageUrl.trim());
    if (uri == null || !uri.hasAuthority) {
      throw ScheduleNotAvailableException('Некорректный адрес страницы расписания: «$pageUrl»');
    }
    final Uint8List bytes = await _client.get(uri);
    final String html = utf8.decode(bytes, allowMalformed: true);
    final SchedulePageIndex index = parseIndex(uri, html);
    _logger.info('Страница расписания: ежедневных ссылок ${index.daily.length}, '
        'полугодовых ${index.semester.length}');
    return index;
  }

  /// Разбирает HTML и извлекает ссылки на PDF.
  ///
  /// Разбор сделан регулярным выражением, а не XML-парсером: страница
  /// генерируется CMS и содержит разметку, не являющуюся строго корректным XML.
  static SchedulePageIndex parseIndex(Uri pageUri, String html) {
    final List<SchedulePageLink> daily = <SchedulePageLink>[];
    final List<SchedulePageLink> semester = <SchedulePageLink>[];

    for (final RegExpMatch match in _anchorPattern.allMatches(html)) {
      final String href = match.group(1)?.trim() ?? '';
      if (!href.toLowerCase().contains('.pdf')) {
        continue;
      }
      final String title = _cleanText(match.group(2) ?? '');
      final Uri? uri = Uri.tryParse(href);
      if (uri == null) {
        continue;
      }
      final Uri absolute = uri.hasScheme ? uri : pageUri.resolveUri(uri);

      final DateTime? date = parseDateFromText(title);
      final bool mentionsCourse = RegExp(r'курс', caseSensitive: false).hasMatch(title);
      final int? course = _courseOf(title);

      if (date != null && !mentionsCourse) {
        daily.add(SchedulePageLink(
          uri: absolute,
          title: title,
          date: date,
          originalHref: href,
        ));
        continue;
      }
      if (mentionsCourse) {
        semester.add(SchedulePageLink(
          uri: absolute,
          title: title,
          course: course,
          extramural: RegExp(r'очно-заочн', caseSensitive: false).hasMatch(title),
          isSemester: true,
          groupHint: _groupHintOf(title),
          originalHref: href,
        ));
      }
    }

    daily.sort((SchedulePageLink a, SchedulePageLink b) {
      final DateTime? first = a.date;
      final DateTime? second = b.date;
      if (first == null || second == null) {
        return 0;
      }
      return second.compareTo(first);
    });

    return SchedulePageIndex(pageUri: pageUri, daily: daily, semester: semester);
  }

  /// Номер курса из подписи ссылки.
  static int? _courseOf(String title) {
    final RegExpMatch? match = RegExp(r'(\d)\s*курс', caseSensitive: false).firstMatch(title);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1)!);
  }

  /// Обозначение группы из подписи («…… гр. 1озРУПО-2026»).
  static String _groupHintOf(String title) {
    final RegExpMatch? match =
        RegExp(r'(\d[А-ЯЁа-яё]{2,6}[-–]\d{2,4})').firstMatch(title);
    if (match == null) {
      return '';
    }
    return match.group(1)!.replaceAll(RegExp(r'\s+'), '');
  }

  /// Убирает теги и HTML-сущности из подписи ссылки.
  static String _cleanText(String raw) {
    String text = raw.replaceAll(RegExp(r'<[^>]*>'), ' ');
    for (int i = 0; i < _htmlEntities.length; i++) {
      const List<String> replacements = <String>[
        ' ',
        '&',
        '«',
        '»',
        '"',
        "'",
      ];
      text = text.replaceAll(_htmlEntities[i], replacements[i]);
    }
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Освобождает сетевые ресурсы.
  void dispose() => _client.close();
}
