/// Утилиты для работы с датами расписания.
///
/// Важно: расписание школы/колледжа живёт в локальном часовом поясе учебного
/// заведения, поэтому все «даты расписания» строятся от календарной даты без
/// времени (см. [dateOnly]) — иначе переход через полночь или смена часового
/// пояса на устройстве способны «сдвинуть» ссылку на PDF.
library;

/// Русские названия месяцев в родительном падеже (для «15 марта 2026»).
const List<String> _russianMonthsGenitive = <String>[
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

/// Отбрасывает время, оставляя только календарную дату.
DateTime dateOnly(DateTime value) => DateTime(value.year, value.month, value.day);

/// Сегодняшняя календарная дата для [now] (по умолчанию — текущий момент).
DateTime today([DateTime? now]) => dateOnly(now ?? DateTime.now());

/// Формат `yyyy-MM-dd` (ISO-8601, только дата).
String formatIsoDate(DateTime date) {
  final String month = date.month.toString().padLeft(2, '0');
  final String day = date.day.toString().padLeft(2, '0');
  return '${date.year.toString().padLeft(4, '0')}-$month-$day';
}

/// Формат `yyyyMMdd` (компактный, для имён файлов).
String formatCompactDate(DateTime date) =>
    formatIsoDate(date).replaceAll('-', '');

/// Формат `dd.MM.yyyy` — как даты обычно выглядят в школьных документах.
String formatDottedDate(DateTime date) {
  final String month = date.month.toString().padLeft(2, '0');
  final String day = date.day.toString().padLeft(2, '0');
  return '$day.$month.${date.year.toString().padLeft(4, '0')}';
}

/// Понедельник недели, к которой относится [date] (начало недели, 00:00).
DateTime isoWeekStart(DateTime date) {
  final DateTime day = dateOnly(date);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

/// Номер недели по ISO-8601.
int isoWeekNumber(DateTime date) {
  final DateTime day = dateOnly(date);
  // Четверг той же недели всегда лежит в «правильном» году по ISO-8601.
  final DateTime thursday = day.add(Duration(days: DateTime.thursday - day.weekday));
  final DateTime firstThursday = DateTime(thursday.year, 1, 4);
  final DateTime firstThursdayWeekStart =
      firstThursday.subtract(Duration(days: firstThursday.weekday - DateTime.monday));
  final int days = thursday.difference(firstThursdayWeekStart).inDays;
  return (days ~/ 7) + 1;
}

/// Ключ учебной недели вида `2026-W12`.
///
/// Используется как часть ключа заметок и ДЗ, чтобы домашнее задание не
/// «переезжало» на другую неделю при смене даты расписания.
String isoWeekKey(DateTime date) {
  final String week = isoWeekNumber(date).toString().padLeft(2, '0');
  final int year = isoWeekYear(date);
  return '${year.toString().padLeft(4, '0')}-W$week';
}

/// Год недели по ISO-8601 (может отличаться от календарного на границах года).
int isoWeekYear(DateTime date) {
  final DateTime day = dateOnly(date);
  final DateTime thursday = day.add(Duration(days: DateTime.thursday - day.weekday));
  return thursday.year;
}

/// Даты шести учебных дней недели, начиная с понедельника [monday].
List<DateTime> studyWeekDates(DateTime monday) {
  final DateTime start = isoWeekStart(monday);
  return List<DateTime>.generate(6, (int index) => start.add(Duration(days: index)));
}

/// «15 марта 2026».
String formatRussianDate(DateTime date) {
  final String month = _russianMonthsGenitive[date.month - 1];
  return '${date.day} $month ${date.year}';
}

/// «15 марта» (без года) — для компактных подписей.
String formatRussianDayMonth(DateTime date) =>
    '${date.day} ${_russianMonthsGenitive[date.month - 1]}';

/// «Пн, 15 марта».
String formatRussianWeekdayDate(DateTime date) {
  const List<String> shortNames = <String>['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
  return '${shortNames[date.weekday - 1]}, ${formatRussianDayMonth(date)}';
}

/// Подставляет дату в шаблон ссылки на PDF.
///
/// Поддерживаемые плейсхолдеры:
/// * `{yyyy}` — год, 4 цифры;
/// * `{yy}` — год, 2 цифры;
/// * `{MM}` — месяц, 2 цифры;
/// * `{M}` — месяц без ведущего нуля;
/// * `{dd}` — день, 2 цифры;
/// * `{d}` — день без ведущего нуля;
/// * `{yyyy-MM-dd}`, `{dd.MM.yyyy}`, `{dd-MM-yyyy}`, `{yyyyMMdd}`, `{dd_MM_yyyy}` —
///   готовые составные форматы, которые чаще всего встречаются в именах файлов.
///
/// Составные плейсхолдеры обрабатываются первыми, поэтому шаблон
/// `schedule_{yyyy-MM-dd}.pdf` не будет испорчен заменой `{yyyy}`.
String applyDateTemplate(String template, DateTime date) {
  final String year = date.year.toString().padLeft(4, '0');
  final String shortYear = year.substring(year.length - 2);
  final String month = date.month.toString().padLeft(2, '0');
  final String day = date.day.toString().padLeft(2, '0');

  const Map<String, String> compositeKeys = <String, String>{
    '{yyyy-MM-dd}': 'yyyy-MM-dd',
    '{dd.MM.yyyy}': 'dd.MM.yyyy',
    '{dd-MM-yyyy}': 'dd-MM-yyyy',
    '{yyyyMMdd}': 'yyyyMMdd',
    '{dd_MM_yyyy}': 'dd_MM_yyyy',
    '{MM-dd-yyyy}': 'MM-dd-yyyy',
  };

  String result = template;
  for (final MapEntry<String, String> entry in compositeKeys.entries) {
    if (!result.contains(entry.key)) {
      continue;
    }
    final String replacement = switch (entry.value) {
      'yyyy-MM-dd' => '$year-$month-$day',
      'dd.MM.yyyy' => '$day.$month.$year',
      'dd-MM-yyyy' => '$day-$month-$year',
      'yyyyMMdd' => '$year$month$day',
      'dd_MM_yyyy' => '${day}_${month}_$year',
      'MM-dd-yyyy' => '$month-$day-$year',
      _ => entry.value,
    };
    result = result.replaceAll(entry.key, replacement);
  }

  return result
      .replaceAll('{yyyy}', year)
      .replaceAll('{yy}', shortYear)
      .replaceAll('{MM}', month)
      .replaceAll('{M}', date.month.toString())
      .replaceAll('{dd}', day)
      .replaceAll('{d}', date.day.toString());
}

/// Пытается найти дату в произвольном тексте (заголовок PDF, имя файла).
///
/// Распознаёт `dd.MM.yyyy`, `dd.MM.yy`, `yyyy-MM-dd` и `dd/MM/yyyy`.
/// Возвращает `null`, если дата не найдена или значение некорректно.
DateTime? parseDateFromText(String text) {
  final List<RegExp> patterns = <RegExp>[
    RegExp(r'(\d{1,2})[.\-/](\d{1,2})[.\-/](\d{4})'),
    RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})'),
  ];

  for (final RegExp pattern in patterns) {
    final RegExpMatch? match = pattern.firstMatch(text);
    if (match == null) {
      continue;
    }
    final int first = int.parse(match.group(1)!);
    final int second = int.parse(match.group(2)!);
    final int third = int.parse(match.group(3)!);
    final bool yearFirst = pattern.pattern.startsWith(r'(\d{4})');
    final int year = yearFirst ? first : third;
    final int month = yearFirst ? second : second;
    final int day = yearFirst ? third : first;
    if (year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31) {
      continue;
    }
    // Отсекаем заведомо невозможные даты (например, 31 февраля).
    final DateTime candidate = DateTime(year, month, day);
    if (candidate.day != day || candidate.month != month) {
      continue;
    }
    return candidate;
  }
  return null;
}
