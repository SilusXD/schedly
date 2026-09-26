import '../../core/app_logger.dart';
import '../../domain/models/lesson.dart';

/// Слияние двух источников расписания КИП.
///
/// * **Полугодовое** расписание даёт предмет и планового преподавателя;
/// * **ежедневное** — фактическую расстановку на конкретный день: аудитории,
///   группы и замены.
///
/// Ключ сопоставления — «день недели + номер пары + группа». Если занятие есть
/// только в одном источнике, оно попадает в результат как есть.
class ScheduleMerger {
  ScheduleMerger({AppLogger? logger}) : _logger = logger ?? appLogger;

  final AppLogger _logger;

  /// Объединяет занятия двух источников.
  List<Lesson> merge({
    required List<Lesson> semester,
    required List<Lesson> daily,
  }) {
    final Map<String, Lesson> merged = <String, Lesson>{};
    int replacements = 0;

    for (final Lesson lesson in semester) {
      merged[_key(lesson)] = lesson;
    }

    for (final Lesson lesson in daily) {
      final String key = _key(lesson);
      final Lesson? planned = merged[key];
      if (planned == null) {
        merged[key] = lesson;
        continue;
      }

      final String fact = lesson.teacherName;
      final String plan = planned.teacherName;
      final bool isReplacement =
          fact.isNotEmpty && plan.isNotEmpty && !_samePerson(fact, plan);
      if (isReplacement) {
        replacements++;
      }

      merged[key] = planned.copyWith(
        subject: planned.subject,
        room: lesson.room.isNotEmpty ? lesson.room : planned.room,
        teacherName: fact.isNotEmpty ? fact : planned.teacherName,
        plannedTeacherName: plan,
        isReplacement: isReplacement,
        timeStart: lesson.timeStart ?? planned.timeStart,
        timeEnd: lesson.timeEnd ?? planned.timeEnd,
        subgroup: lesson.subgroup.isNotEmpty ? lesson.subgroup : planned.subgroup,
        note: lesson.note.isNotEmpty ? lesson.note : planned.note,
      );
    }

    final List<Lesson> result = merged.values.toList()
      ..sort((Lesson a, Lesson b) => a.compareTo(b));
    _logger.info('Слияние расписаний: ${semester.length} семестровых + '
        '${daily.length} ежедневных → ${result.length} записей, замен: $replacements');
    return result;
  }

  /// Ключ сопоставления: день, номер пары и группа.
  static String _key(Lesson lesson) => <String>[
        lesson.weekday.isoNumber.toString(),
        lesson.pairNumber.toString(),
        _normalizePerson(lesson.groupName),
      ].join('|');

  /// Сравнивает преподавателей по фамилии: инициалы в источниках могут быть
  /// указаны по-разному («Аксёнова Т.Г.» и «Аксенова Т. Г.»).
  static bool _samePerson(String first, String second) {
    final String a = _normalizePerson(first);
    final String b = _normalizePerson(second);
    if (a.isEmpty || b.isEmpty) {
      return a == b;
    }
    if (a == b) {
      return true;
    }
    return _surname(a) == _surname(b);
  }

  static String _surname(String value) {
    final List<String> parts = value.split(' ');
    return parts.isEmpty ? value : parts.first;
  }

  /// Приводит имя к сравнимому виду: нижний регистр, без точек и пробелов,
  /// `ё` → `е`.
  static String _normalizePerson(String value) => value
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[.,]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
