import '../domain/models/weekday.dart';

/// Строит стабильный ключ пары для хранения заметок и домашних заданий.
///
/// Ключ не должен зависеть от порядка занятий в PDF или от времени его разбора,
/// иначе заметки «потеряются» при следующем обновлении расписания. Поэтому в
/// ключ входят только устойчивые характеристики: учебная неделя, тип и имя
/// сущности, день недели, номер пары и предмет.
String buildLessonKey({
  required String weekKey,
  required String entityType,
  required String entityName,
  required Weekday weekday,
  required int pairNumber,
  required String subject,
}) {
  final String subjectSlug = slugifyForKeys(subject);
  return <String>[
    weekKey,
    slugifyForKeys(entityType),
    slugifyForKeys(entityName),
    weekday.isoNumber.toString(),
    pairNumber.toString(),
    subjectSlug.isEmpty ? 'lesson' : subjectSlug,
  ].join('|');
}

/// Упрощённый слаг для ключей (без внешних зависимостей).
String slugifyForKeys(String value) {
  final StringBuffer buffer = StringBuffer();
  bool lastWasDash = false;
  for (final int rune in value.trim().toLowerCase().runes) {
    final String ch = String.fromCharCode(rune);
    if (RegExp(r'[a-zа-я0-9]').hasMatch(ch)) {
      buffer.write(ch == 'ё' ? 'е' : ch);
      lastWasDash = false;
      continue;
    }
    if (!lastWasDash) {
      buffer.write('-');
      lastWasDash = true;
    }
  }
  String result = buffer.toString();
  while (result.startsWith('-')) {
    result = result.substring(1);
  }
  while (result.endsWith('-')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}
