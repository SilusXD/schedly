import 'dart:math' as math;

import '../pdf/pdf_text.dart';
import 'parser_config.dart';

/// Горизонтальная полоса страницы, соответствующая одной колонке таблицы.
class ColumnBand {
  const ColumnBand({required this.index, required this.left, required this.right});

  /// Порядковый номер колонки (слева направо, начиная с 0).
  final int index;

  /// Левая граница полосы (pt).
  final double left;

  /// Правая граница полосы (pt).
  final double right;

  /// Ширина полосы.
  double get width => right - left;

  /// Центр полосы.
  double get center => (left + right) / 2;

  @override
  String toString() =>
      'ColumnBand(#$index ${left.toStringAsFixed(1)}..${right.toStringAsFixed(1)})';
}

/// Визуальная строка страницы, разложенная по колонкам.
class LayoutRow {
  LayoutRow({required this.line, required this.cellTexts, required this.columns});

  /// Исходная строка PDF.
  final PdfTextLine line;

  /// Текст по каждой колонке (индекс соответствует [ColumnBand.index]).
  final List<String> cellTexts;

  /// Колонки страницы.
  final List<ColumnBand> columns;

  /// Верхняя координата строки (top-origin).
  double get top => line.top;

  /// Нижняя координата строки (top-origin).
  double get bottom => line.bottom;

  /// Полный текст строки.
  String get text => line.text;

  /// Непустые ячейки с их номерами.
  List<MapEntry<int, String>> get filledCells {
    final List<MapEntry<int, String>> result = <MapEntry<int, String>>[];
    for (int i = 0; i < cellTexts.length; i++) {
      final String value = cellTexts[i].trim();
      if (value.isNotEmpty) {
        result.add(MapEntry<int, String>(i, value));
      }
    }
    return result;
  }

  /// Текст ячейки по индексу, либо пустая строка.
  String cell(int index) =>
      index >= 0 && index < cellTexts.length ? cellTexts[index].trim() : '';

  @override
  String toString() => 'LayoutRow(top: ${top.toStringAsFixed(1)}, "$text")';
}

/// Разметка страницы: колонки и строки, разложенные по этим колонкам.
///
/// Именно этот слой превращает «облако фрагментов с координатами» в подобие
/// таблицы, что и позволяет разбирать расписание без знания точного формата
/// исходного PDF.
class PageLayout {
  PageLayout({required this.page, required this.columns, required this.rows});

  /// Исходная страница.
  final PdfPageText page;

  /// Обнаруженные колонки (слева направо).
  final List<ColumnBand> columns;

  /// Строки страницы, разложенные по колонкам.
  final List<LayoutRow> rows;

  /// Строит разметку страницы.
  ///
  /// Колонки определяются методом «профиля занятости»: по всем фрагментам
  /// страницы строится карта заполненных горизонтальных участков, затем
  /// участки, разделённые зазором меньше [ParserConfig.minColumnGap],
  /// объединяются в одну колонку. Широкие фрагменты (обычно заголовок
  /// документа) исключаются из анализа, чтобы не «склеить» всю страницу
  /// в единственную колонку.
  factory PageLayout.build(PdfPageText page, ParserConfig config) {
    final List<ColumnBand> columns = _detectColumns(page, config);

    final List<LayoutRow> rows = <LayoutRow>[];
    for (final PdfTextLine line in page.lines) {
      final List<StringBuffer> buffers = List<StringBuffer>.generate(
        columns.length,
        (_) => StringBuffer(),
      );
      for (final PdfTextFragment fragment in line.fragments) {
        final int index = _columnIndexFor(fragment, columns, config.columnPadding);
        if (index < 0) {
          continue;
        }
        final StringBuffer buffer = buffers[index];
        if (buffer.isNotEmpty) {
          buffer.write(' ');
        }
        buffer.write(fragment.text);
      }
      rows.add(LayoutRow(
        line: line,
        cellTexts: buffers.map((StringBuffer buffer) => buffer.toString().trim()).toList(),
        columns: columns,
      ));
    }

    return PageLayout(page: page, columns: columns, rows: rows);
  }

  /// Строки, отсортированные сверху вниз (страховка от неотсортированного входа).
  List<LayoutRow> get sortedRows => List<LayoutRow>.of(rows)
    ..sort((LayoutRow a, LayoutRow b) => a.top.compareTo(b.top));

  static const int _profileStep = 2;

  static List<ColumnBand> _detectColumns(PdfPageText page, ParserConfig config) {
    final double pageWidth = page.width > 0 ? page.width : 595;
    final double maxFragmentWidth = pageWidth * config.maxColumnWidthRatio;

    final List<PdfTextFragment> fragments = <PdfTextFragment>[];
    for (final PdfTextLine line in page.lines) {
      for (final PdfTextFragment fragment in line.fragments) {
        if (fragment.text.trim().isEmpty) {
          continue;
        }
        if (fragment.width > maxFragmentWidth && fragment.width > pageWidth * 0.35) {
          continue;
        }
        fragments.add(fragment);
      }
    }

    if (fragments.isEmpty) {
      return <ColumnBand>[
        ColumnBand(index: 0, left: 0, right: pageWidth),
      ];
    }

    double minLeft = double.infinity;
    double maxRight = double.negativeInfinity;
    for (final PdfTextFragment fragment in fragments) {
      minLeft = math.min(minLeft, fragment.left);
      maxRight = math.max(maxRight, fragment.right);
    }
    if (!minLeft.isFinite || !maxRight.isFinite || maxRight <= minLeft) {
      return <ColumnBand>[ColumnBand(index: 0, left: 0, right: pageWidth)];
    }

    final int buckets = ((maxRight - minLeft) / _profileStep).ceil() + 1;
    final List<bool> occupied = List<bool>.filled(buckets, false);
    for (final PdfTextFragment fragment in fragments) {
      final int from = ((fragment.left - minLeft) / _profileStep).floor().clamp(0, buckets - 1);
      final int to = ((fragment.right - minLeft) / _profileStep).ceil().clamp(0, buckets - 1);
      for (int i = from; i <= to; i++) {
        occupied[i] = true;
      }
    }

    // Собираем непрерывные заполненные участки профиля.
    final List<List<double>> bands = <List<double>>[];
    int index = 0;
    while (index < buckets) {
      if (!occupied[index]) {
        index++;
        continue;
      }
      final int start = index;
      while (index < buckets && occupied[index]) {
        index++;
      }
      bands.add(<double>[
        minLeft + start * _profileStep,
        minLeft + math.min(index * _profileStep, maxRight - minLeft),
      ]);
    }

    if (bands.isEmpty) {
      return <ColumnBand>[ColumnBand(index: 0, left: 0, right: pageWidth)];
    }

    // Объединяем участки, разделённые небольшим зазором: так «08:30» и «10:00»
    // в одной колонке не превращаются в две разные колонки.
    double gap = config.minColumnGap;
    List<List<double>> merged = _mergeBands(bands, gap);
    while (merged.length > config.maxColumns && gap < 60) {
      gap *= 1.6;
      merged = _mergeBands(bands, gap);
    }

    return List<ColumnBand>.generate(
      merged.length,
      (int i) => ColumnBand(index: i, left: merged[i][0], right: merged[i][1]),
    );
  }

  static List<List<double>> _mergeBands(List<List<double>> bands, double minGap) {
    final List<List<double>> result = <List<double>>[];
    for (final List<double> band in bands) {
      if (result.isEmpty) {
        result.add(<double>[band[0], band[1]]);
        continue;
      }
      final List<double> last = result.last;
      if (band[0] - last[1] <= minGap) {
        last[1] = math.max(last[1], band[1]);
      } else {
        result.add(<double>[band[0], band[1]]);
      }
    }
    return result;
  }

  /// Определяет колонку для фрагмента: по попаданию в полосу, иначе — по
  /// ближайшему центру полосы.
  static int _columnIndexFor(
    PdfTextFragment fragment,
    List<ColumnBand> columns,
    double padding,
  ) {
    if (columns.isEmpty) {
      return -1;
    }
    final double center = (fragment.left + fragment.right) / 2;
    for (final ColumnBand column in columns) {
      if (center >= column.left - padding && center <= column.right + padding) {
        return column.index;
      }
    }

    int best = 0;
    double bestDistance = double.infinity;
    for (final ColumnBand column in columns) {
      final double distance = (center - column.center).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = column.index;
      }
    }
    return best;
  }
}
