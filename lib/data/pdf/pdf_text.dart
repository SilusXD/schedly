import 'dart:math' as math;

/// Фрагмент текста на странице PDF с ограничивающим прямоугольником.
/// Координаты — в пунктах PDF (1/72 дюйма), начало координат — ЛЕВЫЙ ВЕРХНИЙ угол
/// страницы, ось Y растёт ВНИЗ (top-origin). Это важно: парсер расписания
/// восстанавливает колонки таблицы по `left`, а строки — по `top`.
class PdfTextFragment {
  /// Создаёт фрагмент с явно заданным прямоугольником.
  const PdfTextFragment({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.fontSize = 0,
  });

  /// Текст фрагмента (уже декодированный в Unicode).
  final String text;

  /// Левый край прямоугольника в top-origin координатах страницы.
  final double left;

  /// Верхний край прямоугольника в top-origin координатах страницы.
  final double top;

  /// Правый край прямоугольника.
  final double right;

  /// Нижний край прямоугольника.
  final double bottom;

  /// Размер шрифта в пунктах (0 — если определить не удалось).
  final double fontSize;

  /// Ширина прямоугольника.
  double get width => right - left;

  /// Высота прямоугольника.
  double get height => bottom - top;

  /// Вертикальный центр прямоугольника.
  double get centerY => (top + bottom) / 2;

  /// Копия фрагмента с заменой отдельных полей.
  PdfTextFragment copyWith({
    String? text,
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? fontSize,
  }) {
    return PdfTextFragment(
      text: text ?? this.text,
      left: left ?? this.left,
      top: top ?? this.top,
      right: right ?? this.right,
      bottom: bottom ?? this.bottom,
      fontSize: fontSize ?? this.fontSize,
    );
  }

  /// Сериализация в JSON-совместимую карту (только примитивы).
  Map<String, dynamic> toJson() => <String, dynamic>{
    'text': text,
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
    'fontSize': fontSize,
  };

  /// Восстанавливает фрагмент из карты, полученной через [toJson].
  factory PdfTextFragment.fromJson(Map<String, dynamic> json) {
    return PdfTextFragment(
      text: json['text'] as String,
      left: (json['left'] as num).toDouble(),
      top: (json['top'] as num).toDouble(),
      right: (json['right'] as num).toDouble(),
      bottom: (json['bottom'] as num).toDouble(),
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 0,
    );
  }

  @override
  String toString() =>
      'PdfTextFragment("$text", left: $left, top: $top, right: $right, '
      'bottom: $bottom, fontSize: $fontSize)';
}

/// Визуальная строка: фрагменты на одной базовой линии (сортированы по left).
class PdfTextLine {
  /// Создаёт строку из фрагментов.
  const PdfTextLine({required this.fragments});

  /// Фрагменты строки в порядке слева направо.
  final List<PdfTextFragment> fragments;

  /// Склейка фрагментов. Если горизонтальный разрыв между соседними фрагментами
  /// больше `gapThreshold`, вставить один пробел; иначе склеить без пробела.
  /// gapThreshold = max(1.0, 0.25 * максимальный fontSize строки).
  String get text {
    if (fragments.isEmpty) return '';
    var maxFontSize = 0.0;
    for (final fragment in fragments) {
      if (fragment.fontSize > maxFontSize) maxFontSize = fragment.fontSize;
    }
    final double gapThreshold = math.max(1.0, 0.25 * maxFontSize);
    final buffer = StringBuffer(fragments.first.text);
    var previousRight = fragments.first.right;
    for (var i = 1; i < fragments.length; i++) {
      final fragment = fragments[i];
      if (fragment.left - previousRight > gapThreshold) {
        buffer.write(' ');
      }
      buffer.write(fragment.text);
      if (fragment.right > previousRight) previousRight = fragment.right;
    }
    return buffer.toString();
  }

  /// Левый край строки.
  double get left => fragments.isEmpty
      ? 0
      : fragments.map((f) => f.left).reduce((a, b) => math.min(a, b));

  /// Верхний край строки.
  double get top => fragments.isEmpty
      ? 0
      : fragments.map((f) => f.top).reduce((a, b) => math.min(a, b));

  /// Правый край строки.
  double get right => fragments.isEmpty
      ? 0
      : fragments.map((f) => f.right).reduce((a, b) => math.max(a, b));

  /// Нижний край строки.
  double get bottom => fragments.isEmpty
      ? 0
      : fragments.map((f) => f.bottom).reduce((a, b) => math.max(a, b));

  /// Вертикальный центр строки.
  double get centerY => (top + bottom) / 2;

  /// Сериализация в JSON-совместимую карту.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'fragments': fragments.map((f) => f.toJson()).toList(),
  };

  /// Восстанавливает строку из карты, полученной через [toJson].
  factory PdfTextLine.fromJson(Map<String, dynamic> json) {
    final raw = json['fragments'] as List<dynamic>;
    return PdfTextLine(
      fragments: raw
          .map(
            (e) => PdfTextFragment.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
    );
  }

  @override
  String toString() => 'PdfTextLine("$text", fragments: ${fragments.length})';
}

/// Текст одной страницы.
class PdfPageText {
  /// Создаёт текст страницы.
  const PdfPageText({
    required this.pageNumber,
    required this.width,
    required this.height,
    required this.lines,
  });

  /// Номер страницы, нумерация с 1.
  final int pageNumber;

  /// Ширина страницы в пунктах (с учётом поворота страницы).
  final double width;

  /// Высота страницы в пунктах (с учётом поворота страницы).
  final double height;

  /// Строки страницы сверху вниз.
  final List<PdfTextLine> lines;

  /// Текст страницы: строки через '\n'.
  String get text => lines.map((line) => line.text).join('\n');

  /// Сериализация в JSON-совместимую карту.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'pageNumber': pageNumber,
    'width': width,
    'height': height,
    'lines': lines.map((line) => line.toJson()).toList(),
  };

  /// Восстанавливает страницу из карты, полученной через [toJson].
  factory PdfPageText.fromJson(Map<String, dynamic> json) {
    final raw = json['lines'] as List<dynamic>;
    return PdfPageText(
      pageNumber: (json['pageNumber'] as num).toInt(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      lines: raw
          .map((e) => PdfTextLine.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  @override
  String toString() =>
      'PdfPageText(pageNumber: $pageNumber, width: $width, height: $height, '
      'lines: ${lines.length})';
}

/// Текст всего документа.
class PdfDocumentText {
  /// Создаёт текст документа.
  const PdfDocumentText({required this.pages});

  /// Страницы документа в порядке следования.
  final List<PdfPageText> pages;

  /// Текст документа: страницы через '\n\n'.
  String get text => pages.map((page) => page.text).join('\n\n');

  /// Пуст ли документ (нет страниц либо ни на одной странице нет текста).
  bool get isEmpty => pages.every((page) => page.text.isEmpty);

  /// Сериализация в JSON-совместимую карту.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'pages': pages.map((page) => page.toJson()).toList(),
  };

  /// Восстанавливает документ из карты, полученной через [toJson].
  factory PdfDocumentText.fromJson(Map<String, dynamic> json) {
    final raw = json['pages'] as List<dynamic>;
    return PdfDocumentText(
      pages: raw
          .map((e) => PdfPageText.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  @override
  String toString() => 'PdfDocumentText(pages: ${pages.length})';
}
