import 'dart:typed_data';

import 'pdf_text.dart';

/// Извлекает структурированный текст из PDF.
abstract interface class PdfTextExtractor {
  /// Человекочитаемое имя реализации (для логов и экрана отладки).
  String get name;

  /// Разбирает [bytes] и возвращает текст документа.
  ///
  /// Бросает [PdfTextExtractionException], если файл повреждён, зашифрован
  /// или не является PDF.
  Future<PdfDocumentText> extract(Uint8List bytes);
}

/// Ошибка извлечения текста из PDF.
class PdfTextExtractionException implements Exception {
  /// Создаёт исключение с сообщением [message] и необязательной причиной [cause].
  PdfTextExtractionException(this.message, {this.cause});

  /// Описание проблемы на русском языке.
  final String message;

  /// Исходная ошибка/исключение, если есть.
  final Object? cause;

  @override
  String toString() {
    final cause = this.cause;
    return cause == null
        ? 'PdfTextExtractionException: $message'
        : 'PdfTextExtractionException: $message (cause: $cause)';
  }
}
