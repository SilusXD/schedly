import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../core/app_logger.dart';
import 'pdf_text.dart';
import 'pdf_text_extractor.dart';

/// Извлечение текста из PDF через PDFium (пакет `pdfrx`).
///
/// Это основной путь на устройстве: PDFium даёт координаты каждого фрагмента,
/// поэтому парсер расписания может восстановить таблицу по геометрии, а не
/// «угадывать» структуру по потоку текста.
///
/// Импорт выполнен с префиксом: у `pdfrx` есть собственный класс `PdfPageText`,
/// который конфликтует с одноимённой моделью приложения.
class PdfrxTextExtractor implements PdfTextExtractor {
  PdfrxTextExtractor({AppLogger? logger}) : _logger = logger ?? appLogger;

  final AppLogger _logger;

  @override
  String get name => 'pdfrx (PDFium)';

  @override
  Future<PdfDocumentText> extract(Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw PdfTextExtractionException('Пустой PDF-файл');
    }

    pdfrx.PdfDocument? document;
    try {
      document = await pdfrx.PdfDocument.openData(bytes, sourceName: 'schedule.pdf');

      final List<PdfPageText> pages = <PdfPageText>[];
      for (final pdfrx.PdfPage page in document.pages) {
        final pdfrx.PdfPageText text = await page.loadStructuredText();
        pages.add(PdfPageText(
          pageNumber: text.pageNumber,
          width: page.width,
          height: page.height,
          lines: buildLines(_fragmentsOf(text, page)),
        ));
      }

      if (pages.isEmpty) {
        throw PdfTextExtractionException('В PDF не найдено ни одной страницы');
      }

      final int fragmentCount = pages.fold<int>(
        0,
        (int sum, PdfPageText page) =>
            sum + page.lines.fold<int>(0, (int count, PdfTextLine line) => count + line.fragments.length),
      );
      _logger.debug('pdfrx: извлечено ${pages.length} страниц, $fragmentCount фрагментов');
      return PdfDocumentText(pages: pages);
    } on PdfTextExtractionException {
      rethrow;
    } on Object catch (error) {
      throw PdfTextExtractionException(
        'Не удалось прочитать PDF средствами PDFium',
        cause: error,
      );
    } finally {
      try {
        await document?.dispose();
      } on Object catch (error) {
        _logger.warning('Не удалось освободить PDF-документ', error);
      }
    }
  }

  /// Переводит фрагменты PDFium в собственную модель с top-origin координатами.
  ///
  /// Важно: в PDF координаты отсчитываются от нижнего левого угла, а в модели
  /// приложения — от верхнего левого, поэтому по оси Y выполняется отражение.
  List<PdfTextFragment> _fragmentsOf(pdfrx.PdfPageText text, pdfrx.PdfPage page) {
    final double pageHeight = page.height;
    final List<PdfTextFragment> result = <PdfTextFragment>[];

    for (final pdfrx.PdfPageTextFragment fragment in text.fragments) {
      final String value = fragment.text;
      if (value.trim().isEmpty) {
        continue;
      }
      pdfrx.PdfRect bounds = fragment.bounds;
      if (page.rotation != pdfrx.PdfPageRotation.none) {
        // Повернутые страницы встречаются редко; при повороте пересчитываем
        // координаты, чтобы «верх» оставался верхом.
        try {
          bounds = bounds.rotate(page.rotation.index, page);
        } on Object catch (error) {
          _logger.warning('Не удалось учесть поворот страницы', error);
        }
      }

      result.add(PdfTextFragment(
        text: value,
        left: bounds.left,
        top: pageHeight - bounds.top,
        right: bounds.right,
        bottom: pageHeight - bounds.bottom,
        fontSize: bounds.height.abs(),
      ));
    }
    return result;
  }

  /// Собирает фрагменты в визуальные строки по близости базовых линий.
  static List<PdfTextLine> buildLines(List<PdfTextFragment> fragments) {
    if (fragments.isEmpty) {
      return const <PdfTextLine>[];
    }

    final List<PdfTextFragment> sorted = List<PdfTextFragment>.of(fragments)
      ..sort((PdfTextFragment a, PdfTextFragment b) {
        final int byTop = a.top.compareTo(b.top);
        return byTop != 0 ? byTop : a.left.compareTo(b.left);
      });

    final List<List<PdfTextFragment>> groups = <List<PdfTextFragment>>[];
    for (final PdfTextFragment fragment in sorted) {
      if (groups.isEmpty) {
        groups.add(<PdfTextFragment>[fragment]);
        continue;
      }
      final List<PdfTextFragment> current = groups.last;
      final double referenceCenter = current
              .map((PdfTextFragment item) => item.centerY)
              .reduce((double a, double b) => a + b) /
          current.length;
      final double tolerance = math.max(
        2.5,
        math.max(fragment.fontSize, current.first.fontSize) * 0.5,
      );
      if ((fragment.centerY - referenceCenter).abs() <= tolerance) {
        current.add(fragment);
      } else {
        groups.add(<PdfTextFragment>[fragment]);
      }
    }

    return groups.map((List<PdfTextFragment> group) {
      group.sort((PdfTextFragment a, PdfTextFragment b) => a.left.compareTo(b.left));
      return PdfTextLine(fragments: group);
    }).toList();
  }
}
