import 'weekday.dart';

/// Чётность учебной недели, если расписание делится на числитель/знаменатель.
enum WeekParity {
  both('каждую неделю'),
  numerator('числитель'),
  denominator('знаменатель');

  const WeekParity(this.title);

  /// Русская подпись для интерфейса.
  final String title;

  /// Распознаёт чётность недели по тексту ячейки расписания.
  static WeekParity? parse(String raw) {
    final String value = raw.toLowerCase().replaceAll('ё', 'е');
    if (value.contains('числител') || value.contains('нечет') || value.contains('нечёт')) {
      return WeekParity.numerator;
    }
    if (value.contains('знаменател') || value.contains('четн')) {
      return WeekParity.denominator;
    }
    return null;
  }
}

/// Одно занятие (пара) из расписания.
///
/// Модель намеренно «плоская»: одно и то же занятие встречается и в расписании
/// преподавателя, и в расписании группы, поэтому в объекте хранятся оба имени.
/// Группировка по преподавателям/группам выполняется слоем выше
/// (`EntitySchedule`).
class Lesson implements Comparable<Lesson> {
  const Lesson({
    required this.weekday,
    required this.pairNumber,
    required this.subject,
    this.timeStart,
    this.timeEnd,
    this.teacherName = '',
    this.groupName = '',
    this.room = '',
    this.subgroup = '',
    this.note = '',
    this.parity = WeekParity.both,
    this.rawText = '',
    this.plannedTeacherName = '',
    this.isReplacement = false,
  });

  /// День недели занятия.
  final Weekday weekday;

  /// Номер пары (1–8). `0`, если номер не удалось определить.
  final int pairNumber;

  /// Название предмета (дисциплины).
  final String subject;

  /// Время начала в формате `HH:mm`, если известно.
  final String? timeStart;

  /// Время окончания в формате `HH:mm`, если известно.
  final String? timeEnd;

  /// ФИО преподавателя.
  final String teacherName;

  /// Название группы (может содержать несколько групп через запятую).
  final String groupName;

  /// Аудитория/кабинет.
  final String room;

  /// Подгруппа («1 подгруппа», «немецкий»), если занятие делится.
  final String subgroup;

  /// Примечание из расписания (например, «зачёт», «консультация»).
  final String note;

  /// Чётность недели.
  final WeekParity parity;

  /// Исходная строка расписания — помогает разбирать ошибки парсинга.
  final String rawText;

  /// Преподаватель по базовому (полугодовому) расписанию.
  ///
  /// Заполняется, когда занятие собрано из двух источников: ежедневное
  /// расписание даёт фактического преподавателя, полугодовое — планового.
  /// Если они расходятся, [isReplacement] = true.
  final String plannedTeacherName;

  /// Признак замены: фактический преподаватель отличается от планового.
  final bool isReplacement;

  /// Человекочитаемый диапазон времени: `08:30–10:00`, `08:30` или пустая строка.
  String get timeRange {
    final String start = (timeStart ?? '').trim();
    final String end = (timeEnd ?? '').trim();
    if (start.isEmpty && end.isEmpty) {
      return '';
    }
    if (start.isNotEmpty && end.isNotEmpty) {
      return '$start–$end';
    }
    return start.isNotEmpty ? start : end;
  }

  /// Есть ли содержательное занятие (а не пустая ячейка).
  bool get isMeaningful => subject.trim().isNotEmpty || room.trim().isNotEmpty;

  /// Ключ для объединения дубликатов внутри одного дня.
  ///
  /// Не включает преподавателя и группу: если одна и та же пара описана в двух
  /// строках PDF (например, для двух групп потока), они должны склеиться.
  String get mergeKey {
    final String subjectKey = subject.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final String subgroupKey = subgroup.trim().toLowerCase();
    final String timeKey = timeRange.toLowerCase();
    return '${weekday.isoNumber}|$pairNumber|$timeKey|$subjectKey|$subgroupKey';
  }

  /// Порядок сортировки: сначала день, затем номер пары, затем предмет.
  @override
  int compareTo(Lesson other) {
    final int byDay = weekday.isoNumber.compareTo(other.weekday.isoNumber);
    if (byDay != 0) {
      return byDay;
    }
    final int byPair = pairNumber.compareTo(other.pairNumber);
    if (byPair != 0) {
      return byPair;
    }
    final int byTime = (timeStart ?? '').compareTo(other.timeStart ?? '');
    if (byTime != 0) {
      return byTime;
    }
    return subject.compareTo(other.subject);
  }

  Lesson copyWith({
    Weekday? weekday,
    int? pairNumber,
    String? subject,
    String? timeStart,
    String? timeEnd,
    String? teacherName,
    String? groupName,
    String? room,
    String? subgroup,
    String? note,
    WeekParity? parity,
    String? rawText,
    String? plannedTeacherName,
    bool? isReplacement,
  }) {
    return Lesson(
      weekday: weekday ?? this.weekday,
      pairNumber: pairNumber ?? this.pairNumber,
      subject: subject ?? this.subject,
      timeStart: timeStart ?? this.timeStart,
      timeEnd: timeEnd ?? this.timeEnd,
      teacherName: teacherName ?? this.teacherName,
      groupName: groupName ?? this.groupName,
      room: room ?? this.room,
      subgroup: subgroup ?? this.subgroup,
      note: note ?? this.note,
      parity: parity ?? this.parity,
      rawText: rawText ?? this.rawText,
      plannedTeacherName: plannedTeacherName ?? this.plannedTeacherName,
      isReplacement: isReplacement ?? this.isReplacement,
    );
  }

  /// Дополняет занятие сведениями из дубликата, не перетирая заполненные поля.
  Lesson mergeWith(Lesson other) {
    String pick(String current, String candidate) =>
        current.trim().isNotEmpty ? current : candidate;

    return Lesson(
      weekday: weekday,
      pairNumber: pairNumber != 0 ? pairNumber : other.pairNumber,
      subject: pick(subject, other.subject),
      timeStart: (timeStart ?? '').trim().isNotEmpty ? timeStart : other.timeStart,
      timeEnd: (timeEnd ?? '').trim().isNotEmpty ? timeEnd : other.timeEnd,
      teacherName: _mergeNames(teacherName, other.teacherName),
      groupName: _mergeNames(groupName, other.groupName),
      room: pick(room, other.room),
      subgroup: pick(subgroup, other.subgroup),
      note: pick(note, other.note),
      parity: parity == WeekParity.both ? other.parity : parity,
      rawText: rawText.trim().isNotEmpty ? rawText : other.rawText,
      plannedTeacherName: pick(plannedTeacherName, other.plannedTeacherName),
      isReplacement: isReplacement || other.isReplacement,
    );
  }

  /// Склеивает перечисления имён через запятую без дубликатов.
  static String _mergeNames(String current, String candidate) {
    final List<String> parts = <String>[];
    for (final String chunk in <String>[current, candidate]) {
      for (final String part in chunk.split(',')) {
        final String value = part.trim();
        if (value.isEmpty) {
          continue;
        }
        if (!parts.any((String existing) => existing.toLowerCase() == value.toLowerCase())) {
          parts.add(value);
        }
      }
    }
    return parts.join(', ');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'weekday': weekday.isoNumber,
        'pair': pairNumber,
        'subject': subject,
        if (timeStart != null) 'timeStart': timeStart,
        if (timeEnd != null) 'timeEnd': timeEnd,
        'teacher': teacherName,
        'group': groupName,
        'room': room,
        'subgroup': subgroup,
        'note': note,
        'parity': parity.name,
        'raw': rawText,
        if (plannedTeacherName.isNotEmpty) 'plannedTeacher': plannedTeacherName,
        if (isReplacement) 'replacement': true,
      };

  factory Lesson.fromJson(Map<String, dynamic> json) {
    return Lesson(
      weekday: Weekday.fromIsoNumber(_asInt(json['weekday'])) ?? Weekday.monday,
      pairNumber: _asInt(json['pair']),
      subject: _asString(json['subject']),
      timeStart: _asNullableString(json['timeStart']),
      timeEnd: _asNullableString(json['timeEnd']),
      teacherName: _asString(json['teacher']),
      groupName: _asString(json['group']),
      room: _asString(json['room']),
      subgroup: _asString(json['subgroup']),
      note: _asString(json['note']),
      parity: WeekParity.values.firstWhere(
        (WeekParity value) => value.name == _asString(json['parity']),
        orElse: () => WeekParity.both,
      ),
      rawText: _asString(json['raw']),
      plannedTeacherName: _asString(json['plannedTeacher']),
      isReplacement: json['replacement'] == true,
    );
  }

  static int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }

  static String _asString(Object? value) => value is String ? value : '';

  static String? _asNullableString(Object? value) {
    if (value is! String) {
      return null;
    }
    return value.trim().isEmpty ? null : value;
  }

  @override
  String toString() =>
      'Lesson(${weekday.shortTitle} #$pairNumber ${timeRange.isEmpty ? '' : '$timeRange '}'
      '$subject${room.isEmpty ? '' : ' ауд. $room'})';
}
