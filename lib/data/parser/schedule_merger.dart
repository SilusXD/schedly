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
  ///
  /// Если на одну и ту же пару и группу в полугодовом расписании приходится два
  /// занятия (нечётная и чётная недели), ежедневное занятие сопоставляется с
  /// тем из них, у которого совпадает преподаватель; вторая запись сохраняется
  /// без изменений, чтобы не потерять вторую неделю.
  List<Lesson> merge({
    required List<Lesson> semester,
    required List<Lesson> daily,
  }) {
    final Map<String, List<Lesson>> planned = <String, List<Lesson>>{};
    for (final Lesson lesson in semester) {
      planned.putIfAbsent(_key(lesson), () => <Lesson>[]).add(lesson);
    }

    final Map<String, Lesson> result = <String, Lesson>{};
    int replacements = 0;

    // Ключи, к которым уже «применилось» ежедневное расписание: индексы
    // занятий внутри группы, заменённые фактическими данными.
    final Set<String> consumed = <String>{};

    for (final Lesson actual in daily) {
      final String key = _key(actual);
      final List<Lesson> candidates = planned[key] ?? const <Lesson>[];
      if (candidates.isEmpty) {
        result['$key|daily|${actual.teacherName}'] = actual;
        continue;
      }

      // Выбираем запись плана: сначала с совпадающим преподавателем,
      // иначе — первую незанятую.
      int index = -1;
      for (int i = 0; i < candidates.length; i++) {
        if (consumed.contains('$key#$i')) {
          continue;
        }
        if (_samePerson(candidates[i].teacherName, actual.teacherName)) {
          index = i;
          break;
        }
      }
      if (index < 0) {
        for (int i = 0; i < candidates.length; i++) {
          if (!consumed.contains('$key#$i')) {
            index = i;
            break;
          }
        }
      }
      if (index < 0) {
        index = 0;
      }
      consumed.add('$key#$index');

      final Lesson plan = candidates[index];
      final String fact = actual.teacherName;
      final bool isReplacement =
          fact.isNotEmpty && plan.teacherName.isNotEmpty && !_samePerson(fact, plan.teacherName);
      if (isReplacement) {
        replacements++;
      }

      result['$key#$index'] = plan.copyWith(
        subject: plan.subject,
        room: actual.room.isNotEmpty ? actual.room : plan.room,
        teacherName: fact.isNotEmpty ? fact : plan.teacherName,
        plannedTeacherName: plan.teacherName,
        isReplacement: isReplacement,
        timeStart: actual.timeStart ?? plan.timeStart,
        timeEnd: actual.timeEnd ?? plan.timeEnd,
        subgroup: actual.subgroup.isNotEmpty ? actual.subgroup : plan.subgroup,
        note: actual.note.isNotEmpty ? actual.note : plan.note,
      );
    }

    // Незатронутые записи плана (в том числе вторая неделя).
    for (final MapEntry<String, List<Lesson>> entry in planned.entries) {
      for (int i = 0; i < entry.value.length; i++) {
        final String slot = '${entry.key}#$i';
        if (consumed.contains(slot)) {
          continue;
        }
        result[slot] = entry.value[i];
      }
    }

    final List<Lesson> merged = result.values.toList()
      ..sort((Lesson a, Lesson b) => a.compareTo(b));
    _logger.info('Слияние расписаний: ${semester.length} семестровых + '
        '${daily.length} ежедневных → ${merged.length} записей, замен: $replacements');
    return merged;
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
