/// Настройки парсера расписания.
///
/// Формат PDF у каждого учебного заведения свой, поэтому все «узнаваемые»
/// элементы (заголовки колонок, шаблоны групп, типовое расписание звонков)
/// вынесены в конфигурацию. Значения по умолчанию рассчитаны на типичное
/// расписание колледжа/школы, сгенерированное из Word или Excel.
library;

/// Типовое время пары: используется, если в PDF время не указано.
class PairTime {
  const PairTime({
    required this.pairNumber,
    required this.start,
    required this.end,
  });

  final int pairNumber;
  final String start;
  final String end;

  String get range => '$start–$end';
}

/// Конфигурация разбора.
class ParserConfig {
  const ParserConfig({
    this.teacherHeaders = _defaultTeacherHeaders,
    this.groupHeaders = _defaultGroupHeaders,
    this.dayHeaders = _defaultDayHeaders,
    this.pairHeaders = _defaultPairHeaders,
    this.timeHeaders = _defaultTimeHeaders,
    this.subjectHeaders = _defaultSubjectHeaders,
    this.roomHeaders = _defaultRoomHeaders,
    this.minColumnGap = 8,
    this.columnPadding = 6,
    this.maxColumns = 14,
    this.maxColumnWidthRatio = 0.6,
    this.rowMergeTolerance = 2.5,
    this.defaultPairTimes = _defaultPairTimes,
    this.assumeDefaultPairTimes = true,
  });

  /// Заголовки колонки с преподавателем.
  final List<String> teacherHeaders;

  /// Заголовки колонки с группой.
  final List<String> groupHeaders;

  /// Заголовки колонки с днём недели.
  final List<String> dayHeaders;

  /// Заголовки колонки с номером пары.
  final List<String> pairHeaders;

  /// Заголовки колонки со временем.
  final List<String> timeHeaders;

  /// Заголовки колонки с предметом.
  final List<String> subjectHeaders;

  /// Заголовки колонки с аудиторией.
  final List<String> roomHeaders;

  /// Минимальный горизонтальный зазор (pt), разделяющий колонки.
  final double minColumnGap;

  /// Допуск (pt) при отнесении фрагмента к колонке.
  final double columnPadding;

  /// Верхняя граница числа колонок: защита от «дребезга» при разборе.
  final int maxColumns;

  /// Фрагменты шире этой доли ширины страницы не участвуют в поиске колонок
  /// (обычно это заголовок документа на всю ширину).
  final double maxColumnWidthRatio;

  /// Допуск (pt) при объединении фрагментов в одну строку.
  final double rowMergeTolerance;

  /// Типовое расписание звонков (если в PDF нет времени).
  final List<PairTime> defaultPairTimes;

  /// Подставлять ли типовое время, когда в PDF его нет.
  final bool assumeDefaultPairTimes;

  /// Время пары по её номеру, либо `null`.
  PairTime? pairTime(int pairNumber) {
    for (final PairTime time in defaultPairTimes) {
      if (time.pairNumber == pairNumber) {
        return time;
      }
    }
    return null;
  }

  ParserConfig copyWith({
    List<String>? teacherHeaders,
    List<String>? groupHeaders,
    List<String>? dayHeaders,
    List<String>? pairHeaders,
    List<String>? timeHeaders,
    List<String>? subjectHeaders,
    List<String>? roomHeaders,
    double? minColumnGap,
    double? columnPadding,
    int? maxColumns,
    double? maxColumnWidthRatio,
    double? rowMergeTolerance,
    List<PairTime>? defaultPairTimes,
    bool? assumeDefaultPairTimes,
  }) {
    return ParserConfig(
      teacherHeaders: teacherHeaders ?? this.teacherHeaders,
      groupHeaders: groupHeaders ?? this.groupHeaders,
      dayHeaders: dayHeaders ?? this.dayHeaders,
      pairHeaders: pairHeaders ?? this.pairHeaders,
      timeHeaders: timeHeaders ?? this.timeHeaders,
      subjectHeaders: subjectHeaders ?? this.subjectHeaders,
      roomHeaders: roomHeaders ?? this.roomHeaders,
      minColumnGap: minColumnGap ?? this.minColumnGap,
      columnPadding: columnPadding ?? this.columnPadding,
      maxColumns: maxColumns ?? this.maxColumns,
      maxColumnWidthRatio: maxColumnWidthRatio ?? this.maxColumnWidthRatio,
      rowMergeTolerance: rowMergeTolerance ?? this.rowMergeTolerance,
      defaultPairTimes: defaultPairTimes ?? this.defaultPairTimes,
      assumeDefaultPairTimes: assumeDefaultPairTimes ?? this.assumeDefaultPairTimes,
    );
  }

  static const List<String> _defaultTeacherHeaders = <String>[
    'преподаватель',
    'препод',
    'педагог',
    'учитель',
    'фио',
    'ф.и.о',
  ];

  static const List<String> _defaultGroupHeaders = <String>[
    'группа',
    'группы',
    'класс',
    'подгруппа',
    'уч. группа',
  ];

  static const List<String> _defaultDayHeaders = <String>[
    'день',
    'день недели',
    'дни недели',
  ];

  static const List<String> _defaultPairHeaders = <String>[
    'пара',
    'пары',
    '№',
    'номер',
    'номер пары',
    'урок',
  ];

  static const List<String> _defaultTimeHeaders = <String>[
    'время',
    'часы',
    'расписание звонков',
  ];

  static const List<String> _defaultSubjectHeaders = <String>[
    'предмет',
    'дисциплина',
    'название',
    'занятие',
    'модуль',
  ];

  static const List<String> _defaultRoomHeaders = <String>[
    'аудитория',
    'ауд',
    'кабинет',
    'каб',
    'ауд.',
    'каб.',
  ];

  /// Стандартная сетка звонков (пары по 90 минут с перерывами 10–40 минут).
  static const List<PairTime> _defaultPairTimes = <PairTime>[
    PairTime(pairNumber: 1, start: '08:30', end: '10:00'),
    PairTime(pairNumber: 2, start: '10:10', end: '11:40'),
    PairTime(pairNumber: 3, start: '12:20', end: '13:50'),
    PairTime(pairNumber: 4, start: '14:00', end: '15:30'),
    PairTime(pairNumber: 5, start: '15:40', end: '17:10'),
    PairTime(pairNumber: 6, start: '17:20', end: '18:50'),
    PairTime(pairNumber: 7, start: '19:00', end: '20:30'),
    PairTime(pairNumber: 8, start: '20:40', end: '22:10'),
  ];
}
