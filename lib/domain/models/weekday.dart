/// Дни учебной недели, используемые в расписании.
///
/// Индекс [isoNumber] соответствует ISO-8601: понедельник = 1 ... воскресенье = 7.
/// В расписании школы/колледжа используются только понедельник–суббота.
enum Weekday {
  monday(1, 'Пн', 'Понедельник'),
  tuesday(2, 'Вт', 'Вторник'),
  wednesday(3, 'Ср', 'Среда'),
  thursday(4, 'Чт', 'Четверг'),
  friday(5, 'Пт', 'Пятница'),
  saturday(6, 'Сб', 'Суббота');

  const Weekday(this.isoNumber, this.shortTitle, this.title);

  /// Номер дня по ISO-8601 (понедельник = 1).
  final int isoNumber;

  /// Короткое русское название («Пн»).
  final String shortTitle;

  /// Полное русское название («Понедельник»).
  final String title;

  /// Дни, отображаемые в левой колонке дневника (Пн–Ср).
  static const List<Weekday> firstColumn = <Weekday>[monday, tuesday, wednesday];

  /// Дни, отображаемые в правой колонке дневника (Чт–Сб).
  static const List<Weekday> secondColumn = <Weekday>[thursday, friday, saturday];

  /// Все дни в порядке отображения в дневнике.
  static const List<Weekday> diaryOrder = <Weekday>[
    monday,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
  ];

  /// Возвращает день недели по номеру ISO-8601, либо `null`, если номер
  /// не соответствует учебному дню (0, 7 или значение вне диапазона).
  static Weekday? fromIsoNumber(int isoNumber) {
    for (final Weekday day in Weekday.values) {
      if (day.isoNumber == isoNumber) {
        return day;
      }
    }
    return null;
  }

  /// Возвращает день недели по [DateTime.weekday].
  static Weekday fromDateTime(DateTime date) =>
      Weekday.values[date.weekday - 1];

  /// Распознаёт день недели по произвольной строке из PDF.
  ///
  /// Поддерживаются полные и сокращённые русские названия, варианты с точкой
  /// («Пн.»), в верхнем регистре и с лишними пробелами.
  static Weekday? parse(String raw) {
    final String value = normalizeDayToken(raw);
    if (value.isEmpty) {
      return null;
    }
    for (final Weekday day in Weekday.values) {
      if (day._aliases.contains(value)) {
        return day;
      }
    }
    return null;
  }

  static const Map<Weekday, Set<String>> _aliasesByDay = <Weekday, Set<String>>{
    monday: <String>{'понедельник', 'пн', 'пон', 'понедельн'},
    tuesday: <String>{'вторник', 'вт', 'вто', 'вторн'},
    wednesday: <String>{'среда', 'ср', 'сре', 'сред'},
    thursday: <String>{'четверг', 'чт', 'чет', 'четв'},
    friday: <String>{'пятница', 'пт', 'пят', 'пятн'},
    saturday: <String>{'суббота', 'сб', 'суб', 'субб'},
  };

  Set<String> get _aliases => _aliasesByDay[this] ?? const <String>{};

  /// Приводит токен дня недели к сравнимому виду: нижний регистр, без точек,
  /// лишних пробелов и дефисов.
  static String normalizeDayToken(String raw) {
    final StringBuffer buffer = StringBuffer();
    for (final int rune in raw.trim().toLowerCase().runes) {
      final String ch = String.fromCharCode(rune);
      if (ch == 'ё') {
        buffer.write('е');
        continue;
      }
      final bool isLetter = RegExp(r'[а-яa-z]').hasMatch(ch);
      if (isLetter) {
        buffer.write(ch);
      }
    }
    return buffer.toString();
  }
}
