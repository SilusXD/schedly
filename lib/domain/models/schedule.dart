import 'dart:convert';

import '../../core/date_utils.dart';
import 'lesson.dart';
import 'weekday.dart';

/// Тип сущности, для которой строится расписание.
enum ScheduleEntityType {
  teacher('Преподаватели', 'Преподаватель'),
  group('Группы', 'Группа');

  const ScheduleEntityType(this.tabTitle, this.singularTitle);

  /// Заголовок вкладки в интерфейсе.
  final String tabTitle;

  /// Название в единственном числе (для подписей).
  final String singularTitle;
}

/// Расписание одной сущности: преподавателя или группы.
class EntitySchedule {
  const EntitySchedule({
    required this.name,
    required this.type,
    required this.lessons,
  });

  /// Имя преподавателя или название группы.
  final String name;

  /// Тип сущности.
  final ScheduleEntityType type;

  /// Занятия, отсортированные по дню и номеру пары.
  final List<Lesson> lessons;

  /// Занятия конкретного дня недели (в порядке следования пар).
  List<Lesson> lessonsFor(Weekday weekday) =>
      lessons.where((Lesson lesson) => lesson.weekday == weekday).toList()
        ..sort((Lesson a, Lesson b) => a.compareTo(b));

  /// Дни недели, в которые есть занятия.
  Set<Weekday> get activeWeekdays =>
      lessons.map((Lesson lesson) => lesson.weekday).toSet();

  /// Максимальный номер пары (нужен для оценки «сетки» дневника).
  int get maxPairNumber => lessons.isEmpty
      ? 0
      : lessons.map((Lesson lesson) => lesson.pairNumber).reduce((int a, int b) => a > b ? a : b);

  bool get isEmpty => lessons.isEmpty;

  int get lessonCount => lessons.length;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'type': type.name,
        'lessons': lessons.map((Lesson lesson) => lesson.toJson()).toList(),
      };

  factory EntitySchedule.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawLessons =
        json['lessons'] is List ? json['lessons'] as List<dynamic> : const <dynamic>[];
    final List<Lesson> lessons = rawLessons
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> item) =>
            Lesson.fromJson(Map<String, dynamic>.from(item)))
        .toList()
      ..sort((Lesson a, Lesson b) => a.compareTo(b));

    return EntitySchedule(
      name: json['name'] is String ? json['name'] as String : '',
      type: ScheduleEntityType.values.firstWhere(
        (ScheduleEntityType value) => value.name == json['type'],
        orElse: () => ScheduleEntityType.group,
      ),
      lessons: lessons,
    );
  }
}

/// Полностью разобранное расписание на конкретную дату.
///
/// Один объект = один исходный PDF. Именно он сериализуется в локальный кэш и
/// загружается в облако как `schedule_YYYY-MM-DD.json`.
class ParsedSchedule {
  const ParsedSchedule({
    required this.scheduleDate,
    required this.parsedAt,
    required this.sourceUrl,
    required this.teachers,
    required this.groups,
    this.lessons = const <Lesson>[],
    this.parserVersion = currentParserVersion,
    this.warnings = const <String>[],
    this.rawText,
  });

  /// Версия парсера: позволяет понять, что кэш построен старой логикой.
  static const String currentParserVersion = '2.0.0';

  /// Плоский список занятий.
  ///
  /// Хранится рядом со сгруппированными расписаниями, потому что слияние двух
  /// источников (ежедневного и полугодового) выполняется именно по занятиям:
  /// ключ сопоставления — «день, пара, группа», и в модели он представлен
  /// отдельной записью, а не «занятием внутри группы».
  final List<Lesson> lessons;

  /// Дата, к которой относится расписание (из имени файла или заголовка PDF).
  final DateTime scheduleDate;

  /// Момент разбора PDF.
  final DateTime parsedAt;

  /// Ссылка, с которой был скачан PDF (или `local://…` для ручной загрузки).
  final String sourceUrl;

  /// Расписания преподавателей.
  final List<EntitySchedule> teachers;

  /// Расписания групп.
  final List<EntitySchedule> groups;

  /// Версия парсера, которым получен результат.
  final String parserVersion;

  /// Некритичные замечания парсера (показываются на экране диагностики).
  final List<String> warnings;

  /// Сырой извлечённый текст PDF. В облако не выгружается, но хранится
  /// локально: без него невозможно разобраться в причине ошибок парсинга.
  final String? rawText;

  /// Ключ учебной недели (`2026-W12`) — используется для заметок и ДЗ.
  String get weekKey => isoWeekKey(scheduleDate);

  /// Создаёт расписание из плоского списка занятий, группируя их по
  /// преподавателям и группам.
  factory ParsedSchedule.fromLessons({
    required List<Lesson> lessons,
    required DateTime scheduleDate,
    required DateTime parsedAt,
    required String sourceUrl,
    List<String> warnings = const <String>[],
    String? rawText,
    String parserVersion = currentParserVersion,
  }) {
    final List<Lesson> sorted = List<Lesson>.of(lessons)
      ..sort((Lesson a, Lesson b) => a.compareTo(b));
    return ParsedSchedule(
      lessons: sorted,
      teachers: entitiesFrom(sorted, ScheduleEntityType.teacher),
      groups: entitiesFrom(sorted, ScheduleEntityType.group),
      scheduleDate: scheduleDate,
      parsedAt: parsedAt,
      sourceUrl: sourceUrl,
      warnings: warnings,
      rawText: rawText,
      parserVersion: parserVersion,
    );
  }

  /// Группирует занятия по преподавателям или группам.
  static List<EntitySchedule> entitiesFrom(
    List<Lesson> lessons,
    ScheduleEntityType type,
  ) {
    final Map<String, Map<String, Lesson>> byEntity = <String, Map<String, Lesson>>{};
    for (final Lesson lesson in lessons) {
      final String raw =
          type == ScheduleEntityType.teacher ? lesson.teacherName : lesson.groupName;
      for (final String name in raw
          .split(RegExp(r'[,;]'))
          .map((String part) => part.trim())
          .where((String part) => part.isNotEmpty)
          .toSet()) {
        final Map<String, Lesson> bucket =
            byEntity.putIfAbsent(name, () => <String, Lesson>{});
        bucket[_lessonKey(lesson)] = lesson;
      }
    }

    final List<EntitySchedule> result = byEntity.entries
        .map(
          (MapEntry<String, Map<String, Lesson>> entry) => EntitySchedule(
            name: entry.key,
            type: type,
            lessons: entry.value.values.toList()
              ..sort((Lesson a, Lesson b) => a.compareTo(b)),
          ),
        )
        .toList()
      ..sort((EntitySchedule a, EntitySchedule b) => a.name.compareTo(b.name));
    return result;
  }

  /// Ключ уникальности занятия внутри сущности (группа учитывается всегда,
  /// иначе занятия разных групп склеились бы).
  static String _lessonKey(Lesson lesson) => <String>[
        lesson.weekday.isoNumber.toString(),
        lesson.pairNumber.toString(),
        lesson.mergeKey,
        lesson.groupName.toLowerCase(),
        lesson.teacherName.toLowerCase(),
        lesson.parity.name,
      ].join('|');

  /// Понедельник учебной недели.
  DateTime get weekStart => isoWeekStart(scheduleDate);

  /// Есть ли хоть одно занятие.
  bool get isEmpty => teachers.isEmpty && groups.isEmpty;

  /// Количество уникальных занятий в расписании.
  ///
  /// Одно и то же занятие присутствует и в расписании преподавателя, и в
  /// расписании группы, поэтому занятия объединяются по ключу — иначе они
  /// считались бы дважды.
  int get lessonCount {
    if (lessons.isNotEmpty) {
      return lessons.map(_lessonKey).toSet().length;
    }
    final Set<String> keys = <String>{};
    for (final EntitySchedule entity in <EntitySchedule>[...teachers, ...groups]) {
      for (final Lesson lesson in entity.lessons) {
        keys.add(_lessonKey(lesson));
      }
    }
    return keys.length;
  }

  /// Имена преподавателей в алфавитном порядке.
  List<String> get teacherNames =>
      teachers.map((EntitySchedule item) => item.name).toList()..sort();

  /// Названия групп (естественный порядок: по алфавиту с учётом цифр).
  List<String> get groupNames =>
      groups.map((EntitySchedule item) => item.name).toList()..sort();

  /// Находит расписание преподавателя по имени (без учёта регистра).
  EntitySchedule? teacher(String name) =>
      _findByName(teachers, name, ScheduleEntityType.teacher);

  /// Находит расписание группы по названию (без учёта регистра).
  EntitySchedule? group(String name) =>
      _findByName(groups, name, ScheduleEntityType.group);

  /// Поиск по типу сущности.
  EntitySchedule? entity(ScheduleEntityType type, String name) =>
      type == ScheduleEntityType.teacher ? teacher(name) : group(name);

  static EntitySchedule? _findByName(
    List<EntitySchedule> source,
    String name,
    ScheduleEntityType type,
  ) {
    final String needle = name.trim().toLowerCase();
    for (final EntitySchedule item in source) {
      if (item.name.trim().toLowerCase() == needle) {
        return item;
      }
    }
    for (final EntitySchedule item in source) {
      if (item.type == type && item.name.trim().toLowerCase().contains(needle)) {
        return item;
      }
    }
    return null;
  }

  ParsedSchedule copyWith({
    DateTime? scheduleDate,
    DateTime? parsedAt,
    String? sourceUrl,
    List<EntitySchedule>? teachers,
    List<EntitySchedule>? groups,
    List<Lesson>? lessons,
    String? parserVersion,
    List<String>? warnings,
    String? rawText,
  }) {
    return ParsedSchedule(
      scheduleDate: scheduleDate ?? this.scheduleDate,
      parsedAt: parsedAt ?? this.parsedAt,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      teachers: teachers ?? this.teachers,
      groups: groups ?? this.groups,
      lessons: lessons ?? this.lessons,
      parserVersion: parserVersion ?? this.parserVersion,
      warnings: warnings ?? this.warnings,
      rawText: rawText ?? this.rawText,
    );
  }

  /// Сериализация. [includeRawText] = false — компактный вариант для облака.
  Map<String, dynamic> toJson({bool includeRawText = false}) => <String, dynamic>{
        'schemaVersion': 1,
        'parserVersion': parserVersion,
        'scheduleDate': formatIsoDate(scheduleDate),
        'weekKey': weekKey,
        'parsedAt': parsedAt.toUtc().toIso8601String(),
        'sourceUrl': sourceUrl,
        'warnings': warnings,
        if (includeRawText && rawText != null) 'rawText': rawText,
        'lessons': lessons.map((Lesson lesson) => lesson.toJson()).toList(),
        'teachers': teachers.map((EntitySchedule item) => item.toJson()).toList(),
        'groups': groups.map((EntitySchedule item) => item.toJson()).toList(),
      };

  String toJsonString({bool includeRawText = false}) =>
      jsonEncode(toJson(includeRawText: includeRawText));

  factory ParsedSchedule.fromJson(Map<String, dynamic> json) {
    final DateTime? date = json['scheduleDate'] is String
        ? DateTime.tryParse(json['scheduleDate'] as String)
        : null;
    final DateTime? parsedAt =
        json['parsedAt'] is String ? DateTime.tryParse(json['parsedAt'] as String) : null;

    return ParsedSchedule(
      scheduleDate: dateOnly(date ?? DateTime.now()),
      parsedAt: (parsedAt ?? DateTime.now()).toLocal(),
      sourceUrl: json['sourceUrl'] is String ? json['sourceUrl'] as String : '',
      parserVersion: json['parserVersion'] is String
          ? json['parserVersion'] as String
          : currentParserVersion,
      warnings: (json['warnings'] is List)
          ? (json['warnings'] as List<dynamic>).whereType<String>().toList()
          : const <String>[],
      rawText: json['rawText'] is String ? json['rawText'] as String : null,
      lessons: _lessons(json['lessons']),
      teachers: _entities(json['teachers'], ScheduleEntityType.teacher),
      groups: _entities(json['groups'], ScheduleEntityType.group),
    );
  }

  /// Читает плоский список занятий; если его нет (старый кэш) — собирает из
  /// сгруппированных расписаний.
  static List<Lesson> _lessons(Object? raw) {
    if (raw is List) {
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> item) =>
              Lesson.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    }
    return const <Lesson>[];
  }

  /// Разбор из строки JSON (данные локального кэша или облака).
  static ParsedSchedule? tryParse(String jsonString) {
    try {
      final Object? decoded = jsonDecode(jsonString);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return ParsedSchedule.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  static List<EntitySchedule> _entities(Object? raw, ScheduleEntityType type) {
    if (raw is! List) {
      return const <EntitySchedule>[];
    }
    final List<EntitySchedule> result = raw
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> item) {
          final Map<String, dynamic> map = Map<String, dynamic>.from(item);
          map['type'] = map['type'] ?? type.name;
          return EntitySchedule.fromJson(map);
        })
        .toList();
    result.sort((EntitySchedule a, EntitySchedule b) => a.name.compareTo(b.name));
    return result;
  }

  @override
  String toString() => 'ParsedSchedule(${formatIsoDate(scheduleDate)}, '
      'преподавателей: ${teachers.length}, групп: ${groups.length}, занятий: $lessonCount)';
}
