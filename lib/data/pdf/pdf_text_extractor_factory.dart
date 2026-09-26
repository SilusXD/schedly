import 'dart:typed_data';

import '../../core/app_logger.dart';
import 'pdf_text.dart';
import 'pdf_text_extractor.dart';
import 'pdfrx_text_extractor.dart';
import 'pure_dart_pdf_text_extractor.dart';

/// Экстрактор, который сначала пробует быстрый нативный путь (PDFium), а при
/// неудаче переключается на резервный разбор на чистом Dart.
///
/// Такое сочетание даёт устойчивость: если на устройстве PDFium не справился
/// (нестандартный PDF, повреждённый xref), приложение всё равно попробует
/// извлечь текст самостоятельно, а не покажет пустой экран.
class FallbackPdfTextExtractor implements PdfTextExtractor {
  FallbackPdfTextExtractor({
    PdfTextExtractor? primary,
    PdfTextExtractor? fallback,
    AppLogger? logger,
  })  : _primary = primary ?? PdfrxTextExtractor(logger: logger),
        _fallback = fallback ?? PureDartPdfTextExtractor(),
        _logger = logger ?? appLogger;

  final PdfTextExtractor _primary;
  final PdfTextExtractor _fallback;
  final AppLogger _logger;

  /// Имя фактически сработавшего экстрактора (для диагностики).
  String lastUsedExtractor = '';

  @override
  String get name => '${_primary.name} → ${_fallback.name}';

  @override
  Future<PdfDocumentText> extract(Uint8List bytes) async {
    try {
      final PdfDocumentText result = await _primary.extract(bytes);
      if (result.text.trim().isNotEmpty) {
        lastUsedExtractor = _primary.name;
        return result;
      }
      _logger.warning('${_primary.name}: текстовый слой пуст, пробуем ${_fallback.name}');
    } on PdfTextExtractionException catch (error) {
      _logger.warning('${_primary.name} не справился, пробуем ${_fallback.name}', error);
    }

    final PdfDocumentText result = await _fallback.extract(bytes);
    lastUsedExtractor = _fallback.name;
    return result;
  }
}

/// Создаёт экстрактор текста для приложения.
PdfTextExtractor createPdfTextExtractor({AppLogger? logger}) =>
    FallbackPdfTextExtractor(logger: logger);
