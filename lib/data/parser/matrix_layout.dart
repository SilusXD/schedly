import 'dart:math' as math;

import '../pdf/pdf_text.dart';

/// Колонка «шахматной» таблицы расписания.
///
/// В расписаниях КИП таблица строится не по колонкам «предмет/преподаватель», а
/// как матрица: либо «преподаватель × пара», либо «группа × пара». Колонки
/// определяются по строке-шапке, а привязка фрагмента выполняется по
/// ближайшему центру колонки — это надёжнее проверки попадания в диапазон:
/// подписи соседних колонок могут перекрываться (например, строка времён).
class MatrixColumn {
  const MatrixColumn({
    required this.index,
    required this.left,
    required this.right,
    required this.label,
  });

  /// Порядковый номер колонки (слева направо).
  final int index;

  /// Левая граница колонки.
  final double left;

  /// Правая граница колонки.
  final double right;

  /// Подпись колонки из шапки («1 пара», «2ИСИП-125»).
  final String label;

  /// Центр колонки.
  double get center => (left + right) / 2;

  @override
  String toString() => 'MatrixColumn(#$index "${label.trim()}" '
      '${left.toStringAsFixed(0)}..${right.toStringAsFixed(0)})';
}

/// Утилиты для разбора «шахматных» таблиц расписаний.
class MatrixLayout {
  const MatrixLayout._();

  /// Обозначение группы: «2ОИБАС-1825», «4ИСИП-723», «1КК-1826».
  ///
  /// Допускается пробел внутри буквенной части — в PDF встречаются склейки
  /// вида «2ОИБТ С-1325» (разрыв строки внутри подписи).
  static final RegExp groupPattern =
      RegExp(r'\d[А-ЯЁ]{1,6}\s?[А-ЯЁ]{0,6}\s?[-–]\s?\d{2,4}');

  /// ФИО с инициалами: «Азовцева В. В.», «Мордовин-Залесский А. К.»,
  /// а также вариант без точек — «Лештаева Д Д».
  static final RegExp teacherPattern = RegExp(
    r'[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?\s+[А-ЯЁ]\.\s?[А-ЯЁ]?\.?|'
    r'[А-ЯЁ][а-яё]{2,}(?:-[А-ЯЁ][а-яё]+)?\s+[А-ЯЁ]\s+[А-ЯЁ](?![а-яё])',
  );

  /// ФИО полностью: «Иванов Иван Петрович».
  static final RegExp fullNamePattern = RegExp(
    r'[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?\s+[А-ЯЁ][а-яё]+\s+[А-ЯЁ][а-яё]+',
  );

  /// Время пары: «8:30-10:00», «08:30 – 10:00».
  static final RegExp timePattern =
      RegExp(r'(\d{1,2})[:.](\d{2})\s*[-–—]\s*(\d{1,2})[:.](\d{2})');

  /// Номер пары: «3 пара».
  static final RegExp pairPattern =
      RegExp(r'(\d{1,2})\s*пара', caseSensitive: false);

  /// Аудитория или место проведения.
  ///
  /// «класс.час» здесь намеренно отсутствует: это вид занятия, а не место,
  /// поэтому он попадает в примечание.
  static final RegExp roomPattern = RegExp(
    r'^(?:ауд\.?|каб\.?|аудитория|кабинет|спорт\.?\s?зал|акт\.?\s?зал|мастерск\w*)\s*[\wА-Яа-яЁё\-/]*$',
    caseSensitive: false,
  );

  /// Пометка «ВАКАНСИЯ» вместо преподавателя.
  static final RegExp vacancyPattern = RegExp('ВАКАНСИЯ', caseSensitive: false);

  /// Похоже ли значение на обозначение группы.
  static bool looksLikeGroup(String value) => groupPattern.hasMatch(value);

  /// Приводит обозначение группы к каноническому виду без пробелов:
  /// «2ОИБТ С-1325» → «2ОИБТС-1325». Это нужно, чтобы группы, распознанные из
  /// разных файлов, совпадали при слиянии.
  static String normalizeGroup(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').trim();

  /// Похоже ли значение на ФИО преподавателя.
  static bool looksLikeTeacher(String value) {
    final String text = value.trim();
    if (text.isEmpty) {
      return false;
    }
    return teacherPattern.hasMatch(text) || fullNamePattern.hasMatch(text);
  }

  /// Похоже ли значение на аудиторию или место проведения.
  static bool looksLikeRoom(String value) => roomPattern.hasMatch(value.trim());

  /// Извлекает время из строки, возвращая пару «начало, конец» в виде `HH:mm`.
  static (String, String)? parseTime(String text) {
    final RegExpMatch? match = timePattern.firstMatch(text);
    if (match == null) {
      return null;
    }
    final String start = '${match.group(1)!.padLeft(2, '0')}:${match.group(2)!}';
    final String end = '${match.group(3)!.padLeft(2, '0')}:${match.group(4)!}';
    return (start, end);
  }

  /// Строит колонки по строке-шапке: каждая подпись шапки становится колонкой.
  ///
  /// Границы проходят по серединам между соседними подписями, поэтому длинный
  /// текст ячейки, заходящий на соседнюю колонку, остаётся в своей.
  static List<MatrixColumn> columnsFromRow(
    PdfTextLine row, {
    bool Function(String label)? accept,
  }) {
    final List<PdfTextFragment> fragments = row.fragments
        .where((PdfTextFragment f) => f.text.trim().isNotEmpty)
        .toList()
      ..sort((PdfTextFragment a, PdfTextFragment b) => a.left.compareTo(b.left));
    final List<PdfTextFragment> accepted = accept == null
        ? fragments
        : fragments.where((PdfTextFragment f) => accept(f.text)).toList();
    if (accepted.isEmpty) {
      return const <MatrixColumn>[];
    }

    final List<MatrixColumn> columns = <MatrixColumn>[];
    for (int i = 0; i < accepted.length; i++) {
      final PdfTextFragment current = accepted[i];
      final double leftEdge = i == 0
          ? current.left - 12
          : (accepted[i - 1].right + current.left) / 2;
      final double rightEdge = i == accepted.length - 1
          ? current.right + 12
          : (current.right + accepted[i + 1].left) / 2;
      columns.add(MatrixColumn(
        index: i,
        left: math.min(leftEdge, current.left),
        right: math.max(rightEdge, current.right),
        label: current.text.trim(),
      ));
    }
    return columns;
  }

  /// Индекс ближайшей колонки для фрагмента (по центру фрагмента), либо -1.
  static int nearestColumn(PdfTextFragment fragment, List<MatrixColumn> columns) {
    if (columns.isEmpty) {
      return -1;
    }
    final double center = (fragment.left + fragment.right) / 2;
    int best = 0;
    double bestDistance = double.infinity;
    for (final MatrixColumn column in columns) {
      final double distance = (center - column.center).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = column.index;
      }
    }
    return best;
  }

  /// Индекс колонки по ЛЕВОМУ краю фрагмента.
  ///
  /// В таблицах КИП текст ячейки выровнен по левому краю колонки, а сам
  /// фрагмент может быть шире колонки (длинное название предмета). Привязка по
  /// центру в таком случае «уводила» текст в соседнюю колонку, поэтому для
  /// ячеек используется левый край.
  static int nearestColumnByLeft(
    PdfTextFragment fragment,
    List<MatrixColumn> columns,
  ) {
    if (columns.isEmpty) {
      return -1;
    }
    int best = 0;
    double bestDistance = double.infinity;
    for (final MatrixColumn column in columns) {
      final double distance = (fragment.left - column.left).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = column.index;
      }
    }
    return best;
  }

  /// Собирает фрагменты, относящиеся к колонке [column.index] и диапазону `top`.
  ///
  /// [minLeft] отсекает служебную зону слева (номера пар, время, ФИО
  /// преподавателя), чтобы её содержимое не попадало в ячейки.
  static List<PdfTextFragment> fragmentsIn({
    required PdfPageText page,
    required List<MatrixColumn> columns,
    required MatrixColumn column,
    required double topFrom,
    required double topTo,
    double minLeft = 0,
  }) {
    return page.lines
        .expand((PdfTextLine line) => line.fragments)
        .where((PdfTextFragment f) =>
            f.text.trim().isNotEmpty &&
            f.left >= minLeft &&
            f.top >= topFrom &&
            f.top < topTo &&
            nearestColumnByLeft(f, columns) == column.index)
        .toList()
      ..sort((PdfTextFragment a, PdfTextFragment b) {
        final int byTop = a.top.compareTo(b.top);
        return byTop != 0 ? byTop : a.left.compareTo(b.left);
      });
  }

  /// Склеивает фрагменты в визуальные строки по близости `top`.
  static List<String> toLines(
    List<PdfTextFragment> fragments, {
    double tolerance = 4,
  }) {
    final List<String> lines = <String>[];
    List<PdfTextFragment> current = <PdfTextFragment>[];
    double referenceTop = 0;

    for (final PdfTextFragment fragment in fragments) {
      if (current.isEmpty) {
        current.add(fragment);
        referenceTop = fragment.top;
        continue;
      }
      if ((fragment.top - referenceTop).abs() <= tolerance) {
        current.add(fragment);
      } else {
        lines.add(joinFragments(current));
        current = <PdfTextFragment>[fragment];
        referenceTop = fragment.top;
      }
    }
    if (current.isNotEmpty) {
      lines.add(joinFragments(current));
    }
    return lines.where((String line) => line.isNotEmpty).toList();
  }

  /// Склеивает фрагменты одной строки: разрыв по X превращается в пробел,
  /// а вплотную стоящие фрагменты (разбитые кернингом) — нет.
  static String joinFragments(List<PdfTextFragment> fragments) {
    final List<PdfTextFragment> sorted = List<PdfTextFragment>.of(fragments)
      ..sort((PdfTextFragment a, PdfTextFragment b) => a.left.compareTo(b.left));
    final StringBuffer buffer = StringBuffer();
    double? previousRight;
    for (final PdfTextFragment fragment in sorted) {
      if (previousRight != null) {
        final double gap = fragment.left - previousRight;
        if (gap > 0.6) {
          buffer.write(' ');
        }
      }
      buffer.write(fragment.text);
      previousRight = fragment.right;
    }
    return normalizeSpaces(buffer.toString());
  }

  /// Убирает лишние пробелы.
  static String normalizeSpaces(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();
}
