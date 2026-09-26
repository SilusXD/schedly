import '../../domain/models/lesson.dart';
import '../../domain/models/weekday.dart';
import 'parser_config.dart';

/// Поля, извлечённые из текста одной ячейки или строки расписания.
class CellFields {
  const CellFields({
    this.subject = '',
    this.teacher = '',
    this.group = '',
    this.room = '',
    this.subgroup = '',
    this.note = '',
    this.timeStart,
    this.timeEnd,
    this.pairNumber = 0,
    this.weekday,
    this.parity = WeekParity.both,
  });

  /// Название предмета.
  final String subject;

  /// Преподаватель (может быть несколько через запятую).
  final String teacher;

  /// Группа (может быть несколько через запятую).
  final String group;

  /// Аудитория.
  final String room;

  /// Подгруппа.
  final String subgroup;

  /// Примечание.
  final String note;

  /// Время начала `HH:mm`.
  final String? timeStart;

  /// Время окончания `HH:mm`.
  final String? timeEnd;

  /// Номер пары (0 — неизвестен).
  final int pairNumber;

  /// День недели, если он встретился в тексте.
  final Weekday? weekday;

  /// Чётность недели.
  final WeekParity parity;

  /// Есть ли содержательные данные (кроме служебных).
  bool get hasContent =>
      subject.isNotEmpty ||
      teacher.isNotEmpty ||
      group.isNotEmpty ||
      room.isNotEmpty;

  CellFields copyWith({
    String? subject,
    String? teacher,
    String? group,
    String? room,
    String? subgroup,
    String? note,
    String? timeStart,
    String? timeEnd,
    int? pairNumber,
    Weekday? weekday,
    WeekParity? parity,
  }) {
    return CellFields(
      subject: subject ?? this.subject,
      teacher: teacher ?? this.teacher,
      group: group ?? this.group,
      room: room ?? this.room,
      subgroup: subgroup ?? this.subgroup,
      note: note ?? this.note,
      timeStart: timeStart ?? this.timeStart,
      timeEnd: timeEnd ?? this.timeEnd,
      pairNumber: pairNumber ?? this.pairNumber,
      weekday: weekday ?? this.weekday,
      parity: parity ?? this.parity,
    );
  }

  @override
  String toString() => 'CellFields(subject: "$subject", teacher: "$teacher", '
      'group: "$group", room: "$room", pair: $pairNumber)';
}

/// Разбирает «сырой» текст ячейки на предмет, преподавателя, группу и аудиторию.
///
/// Используются эвристики, а не фиксированный формат: расписания из Word/Excel
/// почти всегда содержат ФИО, номер аудитории и обозначение группы в узнаваемом
/// виде, но порядок и разделители отличаются.
class CellParser {
  CellParser(this.config);

  final ParserConfig config;

  /// Время вида `08:30`, `8.30-10.00`, `08:30–10:00`.
  static final RegExp _timeRange = RegExp(
    r'(\d{1,2})[:.](\d{2})\s*(?:[-–—]\s*(\d{1,2})[:.](\d{2}))?',
  );

  /// Аудитория: «ауд. 305», «каб. 12а», «к. 210», «аудитория № 4».
  static final RegExp _roomWithPrefix = RegExp(
    r'(?:ауд(?:итория)?\.?|каб(?:инет)?\.?|к\.)\s*№?\s*([0-9]{1,4}\s*[а-яa-z]?(?:\s*[/\-]\s*[0-9а-яa-z]{1,4})?)',
    caseSensitive: false,
  );

  /// Аудитория без подписи: «№ 305», «305 каб.».
  static final RegExp _roomWithNumberSign = RegExp(
    r'№\s*([0-9]{1,4}\s*[а-яa-z]?(?:\s*[/\-]\s*[0-9а-яa-z]{1,4})?)',
  );

  /// Обозначение группы с подписью: «группа ИС-21», «гр. 21-ПКС».
  static final RegExp _groupWithPrefix = RegExp(
    r'(?:групп[аы]?|гр\.?|класс|подгрупп[аы]?)\s*№?\s*([0-9]{0,2}\s*[А-ЯЁA-Zа-яёa-z]{0,4}\s*[-–/]?\s*[0-9]{1,3}(?:\s*[-–/]\s*[0-9]{1,3})*)',
    caseSensitive: false,
  );

  /// Обозначение группы без подписи: «ИС-21», «ПКС-19-2», «21ИС».
  ///
  /// Вместо `\b` используются явные просмотры: в Dart (регулярные выражения
  /// совместимы с ECMAScript) `\b` опирается на `\w` = `[A-Za-z0-9_]`, поэтому
  /// кириллица для него не «слово» и границы вокруг русских названий
  /// не срабатывают.
  static final RegExp _groupBare = RegExp(
    r'(?<![A-Za-z0-9_А-Яа-яЁё])([А-ЯЁA-Z]{2,6}\s*[-–]\s*[0-9]{1,3}(?:\s*[-–]\s*[0-9]{1,3})?)(?![A-Za-z0-9_А-Яа-яЁё])',
  );

  /// Обозначение группы вида «21ИС», «9Б».
  static final RegExp _groupDigitsWithLetters = RegExp(
    r'(?<![A-Za-z0-9_А-Яа-яЁё])([0-9]{1,2}\s*[А-ЯЁ]{1,3}[0-9]?)(?![A-Za-z0-9_А-Яа-яЁё])',
  );

  /// ФИО: «Иванов Иван», «Иванов Иван Петрович», «Иванова И. П.».
  static final RegExp _fullName = RegExp(
    r'(?<![A-Za-z0-9_А-Яа-яЁё])([А-ЯЁ][а-яё]{2,}(?:\s+[А-ЯЁ][а-яё]{2,}){1,2})(?![A-Za-z0-9_А-Яа-яЁё])',
  );

  /// Фамилия с инициалами: «Иванов И.П.».
  static final RegExp _nameWithInitials = RegExp(
    r'(?<![A-Za-z0-9_А-Яа-яЁё])([А-ЯЁ][а-яё]{2,}\s+[А-ЯЁ]\.\s?[А-ЯЁ]?\.?)(?![A-Za-z0-9_А-Яа-яЁё])',
  );

  /// Номер пары отдельной ячейкой: «1», «1 пара», «3 урок».
  static final RegExp _pairNumberOnly = RegExp(
    r'^\s*(\d{1,2})\s*(?:пара|пары|урок|ур|п/п)?\s*$',
    caseSensitive: false,
  );

  /// Номер пары внутри строки: «1 пара», «3 урок», «2-я пара».
  static final RegExp _pairWithWord = RegExp(
    r'(\d{1,2})\s*(?:-?я|ий)?\s*(?:пара|пары|урок|ур)(?![A-Za-z0-9_А-Яа-яЁё])',
    caseSensitive: false,
  );

  /// Аудитория без подписи в конце строки: «Математика 305».
  static final RegExp _roomTail = RegExp(r'(?:^|\s)([0-9]{2,4}\s*[а-яa-z]?)\s*$');

  /// Примечания, которые полезно вынести отдельно.
  static const List<String> _noteKeywords = <String>[
    'зачёт',
    'зачет',
    'экзамен',
    'консультация',
    'практика',
    'семинар',
    'лекция',
    'лабораторная',
    'контрольная',
  ];

  /// Разбирает текст одной ячейки/строки.
  CellFields parse(String text) {
    final String source = normalizeSpaces(text);
    if (source.isEmpty) {
      return const CellFields();
    }

    CellFields fields = CellFields(
      weekday: Weekday.parse(source),
      parity: WeekParity.parse(source) ?? WeekParity.both,
    );

    // Время.
    final RegExpMatch? timeMatch = _timeRange.firstMatch(source);
    if (timeMatch != null) {
      fields = fields.copyWith(
        timeStart: _normalizeTime(timeMatch.group(1)!, timeMatch.group(2)!),
        timeEnd: timeMatch.group(3) == null
            ? null
            : _normalizeTime(timeMatch.group(3)!, timeMatch.group(4)!),
      );
    }

    // Номер пары — если ячейка целиком является числом пары, либо если номер
    // указан словами («1 пара», «3 урок»).
    final RegExpMatch? pairMatch = _pairNumberOnly.firstMatch(source);
    if (pairMatch != null) {
      fields = fields.copyWith(pairNumber: int.tryParse(pairMatch.group(1)!) ?? 0);
    } else {
      final RegExpMatch? pairWithWord = _pairWithWord.firstMatch(source);
      if (pairWithWord != null) {
        fields = fields.copyWith(pairNumber: int.tryParse(pairWithWord.group(1)!) ?? 0);
      }
    }

    // Аудитория.
    final String? room = extractRoom(source);
    if (room != null) {
      fields = fields.copyWith(room: room);
    }

    // Группа.
    final String? group = extractGroup(source);
    if (group != null) {
      fields = fields.copyWith(group: group);
    }

    // Преподаватель.
    final String? teacher = extractTeacher(source);
    if (teacher != null) {
      fields = fields.copyWith(teacher: teacher);
    }

    // Предмет — всё, что осталось после вырезания распознанных сущностей.
    String remainder = source;
    for (final String? found in <String?>[room, group, teacher]) {
      if (found == null || found.isEmpty) {
        continue;
      }
      for (final String part in found.split(',')) {
        final String value = part.trim();
        if (value.isNotEmpty) {
          remainder = remainder.replaceFirst(value, ' ');
        }
      }
    }
    if (timeMatch != null) {
      remainder = remainder.replaceAll(timeMatch.group(0)!, ' ');
    }
    if (fields.pairNumber > 0) {
      remainder = remainder.replaceAll(_pairWithWord, ' ');
      remainder = remainder.replaceAll(_pairNumberOnly, ' ');
    }
    // Название дня недели не является частью предмета.
    if (fields.weekday != null) {
      remainder = remainder
          .split(RegExp(r'\s+'))
          .where((String word) => Weekday.parse(word) == null)
          .join(' ');
    }
    // Служебные подписи («ауд.», «гр.», «пара») в название предмета не входят.
    remainder = remainder.replaceAll(
      RegExp(
        r'(?:^|\s)(?:ауд|аудитория|каб|кабинет|гр|группа|подгруппа|пара|пары|урок|преподаватель|препод)\.?(?=\s|$)',
        caseSensitive: false,
      ),
      ' ',
    );
    remainder = normalizeSpaces(remainder.replaceAll(RegExp(r'[\s,;.\-–—]+'), ' '));
    if (remainder.isNotEmpty) {
      fields = fields.copyWith(subject: remainder);
    }

    final String? note = _extractNote(source);
    if (note != null) {
      fields = fields.copyWith(note: note);
    }

    return fields;
  }

  /// Извлекает аудиторию из текста.
  String? extractRoom(String text) {
    final RegExpMatch? withPrefix = _roomWithPrefix.firstMatch(text);
    if (withPrefix != null) {
      return normalizeSpaces(withPrefix.group(1)!);
    }
    final RegExpMatch? withSign = _roomWithNumberSign.firstMatch(text);
    if (withSign != null) {
      return normalizeSpaces(withSign.group(1)!);
    }
    // «Голый» номер в конце строки считаем аудиторией только тогда, когда в
    // строке есть содержательный текст (иначе это номер пары).
    final bool hasWords = RegExp(r'[А-Яа-яA-Za-z]{3,}').hasMatch(text);
    if (hasWords) {
      final RegExpMatch? tail = _roomTail.firstMatch(text);
      if (tail != null) {
        return normalizeSpaces(tail.group(1)!);
      }
    }
    return null;
  }

  /// Извлекает обозначение группы (возможен список через запятую).
  String? extractGroup(String text) {
    final Set<String> found = <String>{};

    for (final RegExpMatch match in _groupWithPrefix.allMatches(text)) {
      found.add(normalizeSpaces(match.group(1)!));
    }
    if (found.isEmpty) {
      for (final RegExpMatch match in _groupBare.allMatches(text)) {
        found.add(normalizeSpaces(match.group(1)!));
      }
    }
    if (found.isEmpty) {
      for (final RegExpMatch match in _groupDigitsWithLetters.allMatches(text)) {
        found.add(normalizeSpaces(match.group(1)!));
      }
    }

    final List<String> cleaned = found
        .map((String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((String value) => value.isNotEmpty && !_looksLikeTimeOrRoom(value))
        .toList();
    if (cleaned.isEmpty) {
      return null;
    }
    return cleaned.join(', ');
  }

  /// Извлекает ФИО преподавателя (возможен список через запятую).
  String? extractTeacher(String text) {
    final Set<String> found = <String>{};

    for (final RegExpMatch match in _nameWithInitials.allMatches(text)) {
      found.add(normalizeSpaces(match.group(1)!));
    }
    for (final RegExpMatch match in _fullName.allMatches(text)) {
      final String value = normalizeSpaces(match.group(1)!);
      // Отсекаем ложные срабатывания на названиях предметов в два слова
      // («Русский язык», «Физическая культура»): настоящая фамилия с
      // заглавной буквы встречается не чаще одного раза в цепочке.
      if (_looksLikeSubjectPhrase(value)) {
        continue;
      }
      found.add(value);
    }

    if (found.isEmpty) {
      return null;
    }
    return found.join(', ');
  }

  /// Извлекает номер пары из текста целиком (если строка — только номер)
  /// либо из конструкции вида «1 пара».
  int? extractPairNumber(String text) {
    final String normalized = normalizeSpaces(text);
    final RegExpMatch? match = _pairNumberOnly.firstMatch(normalized);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    final RegExpMatch? withWord = _pairWithWord.firstMatch(normalized);
    if (withWord != null) {
      return int.tryParse(withWord.group(1)!);
    }
    return null;
  }

  /// Убирает лишние пробелы.
  static String normalizeSpaces(String value) =>
      value.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').trim();

  static String _normalizeTime(String hours, String minutes) =>
      '${hours.padLeft(2, '0')}:$minutes';

  static bool _looksLikeTimeOrRoom(String value) {
    if (RegExp(r'^\d{1,2}[:.]\d{2}$').hasMatch(value)) {
      return true;
    }
    return false;
  }

  /// Отсекает типичные названия предметов, которые можно спутать с ФИО.
  static bool _looksLikeSubjectPhrase(String value) {
    final String lower = value.toLowerCase();
    const List<String> subjectMarkers = <String>[
      'язык',
      'культура',
      'литература',
      'математика',
      'информатика',
      'история',
      'география',
      'физика',
      'химия',
      'биология',
      'общество',
      'безопасность',
      'технология',
      'черчение',
      'астрономия',
    ];
    return subjectMarkers.any((String marker) => lower.contains(marker));
  }

  static String? _extractNote(String source) {
    final String lower = source.toLowerCase();
    for (final String keyword in _noteKeywords) {
      if (lower.contains(keyword)) {
        return keyword;
      }
    }
    return null;
  }
}
