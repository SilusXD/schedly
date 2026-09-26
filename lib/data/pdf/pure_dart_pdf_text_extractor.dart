import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'pdf_text.dart';
import 'pdf_text_extractor.dart';

// ---------------------------------------------------------------------------
// Ограничения (защита от PDF-бомб, циклов и «бесконечных» файлов).
// ---------------------------------------------------------------------------

/// Максимальная глубина разбора вложенных объектов и ссылок.
const int _maxObjectDepth = 32;

/// Максимальная глубина дерева страниц.
const int _maxPageTreeDepth = 64;

/// Максимальное число страниц, которые вообще обрабатываются.
const int _maxPages = 4000;

/// Максимальное число фрагментов текста на одной странице.
const int _maxFragmentsPerPage = 200000;

/// Максимальное число объектов, помещаемых в кэш при разборе.
const int _maxObjects = 300000;

/// Максимальный размер раскодированного потока (байт).
const int _maxDecodedStreamBytes = 64 << 20;

/// Максимальное число объектов внутри одного объектного потока.
const int _maxObjectStreamObjects = 200000;

/// Реализация [PdfTextExtractor] на чистом Dart.
///
/// Разбирает PDF без Flutter, без нативных библиотек и без внешних пакетов:
/// xref-таблицы и xref-потоки, объектные потоки (`/Type /ObjStm`), фильтры
/// `FlateDecode`/`ASCIIHexDecode`/`ASCII85Decode`/`LZWDecode`/`RunLengthDecode`,
/// предикторы PNG/TIFF, дерево страниц, шрифты (простые и Type0), CMap
/// `/ToUnicode`, кодировки WinAnsi/MacRoman/Standard и `/Differences`.
///
/// Если xref-разбор не удался или оказался неполным, используется резервный
/// полный скан файла по шаблону `N G obj ... endobj`.
class PureDartPdfTextExtractor implements PdfTextExtractor {
  /// Создаёт экстрактор. Класс не хранит состояния и может использоваться
  /// повторно.
  const PureDartPdfTextExtractor();

  @override
  String get name => 'pure-dart';

  @override
  Future<PdfDocumentText> extract(Uint8List bytes) async {
    return _PdfFile(bytes).extract();
  }
}

// ---------------------------------------------------------------------------
// Лексические примитивы PDF.
// ---------------------------------------------------------------------------

/// Имя PDF (`/Name`). Значение хранится вместе с ведущим слешем.
class _Name {
  const _Name(this.value);

  final String value;

  @override
  String toString() => value;
}

/// Ключевое слово или оператор (`obj`, `endobj`, `<<`, `TJ`, ...).
class _Keyword {
  const _Keyword(this.value);

  final String value;

  @override
  String toString() => value;
}

/// Строка PDF (литеральная или hex) — хранится как «сырые» байты.
class _PdfString {
  _PdfString(this.bytes);

  final Uint8List bytes;

  @override
  String toString() => '<string ${bytes.length}B>';
}

/// Косвенная ссылка `N G R`.
class _PdfRef {
  const _PdfRef(this.number, this.generation);

  final int number;
  final int generation;

  @override
  String toString() => '$number $generation R';
}

/// Потоковый объект: словарь + «сырой» (не раскодированный) диапазон байт.
class _StreamValue {
  _StreamValue(this.dict, this.bytes, this.start, this.end);

  final Map<String, Object?> dict;
  final Uint8List bytes;
  final int start;
  final int end;

  Uint8List get rawBytes => Uint8List.sublistView(bytes, start, end);

  @override
  String toString() => '<stream ${end - start}B>';
}

/// Токенизатор PDF-синтаксиса.
class _Lexer {
  _Lexer(this.data, [this.position = 0]);

  final Uint8List data;

  /// Текущая позиция разбора. Поле публичное намеренно: класс приватный, и
  /// аксессоры вокруг него ничего не добавляли бы.
  int position;

  static bool _isWhitespace(int c) =>
      c == 0x00 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0C ||
      c == 0x0D ||
      c == 0x20;

  static bool _isDelimiter(int c) =>
      c == 0x28 || // (
      c == 0x29 || // )
      c == 0x3C || // <
      c == 0x3E || // >
      c == 0x5B || // [
      c == 0x5D || // ]
      c == 0x7B || // {
      c == 0x7D || // }
      c == 0x2F || // /
      c == 0x25; // %

  static bool _isRegular(int c) => !_isWhitespace(c) && !_isDelimiter(c);

  static int _hexValue(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }

  int peek([int offset = 0]) {
    final index = position + offset;
    return index >= 0 && index < data.length ? data[index] : -1;
  }

  void skipWhitespaceAndComments() {
    while (position < data.length) {
      final c = data[position];
      if (_isWhitespace(c)) {
        position++;
        continue;
      }
      if (c == 0x25) {
        while (position < data.length &&
            data[position] != 0x0A &&
            data[position] != 0x0D) {
          position++;
        }
        continue;
      }
      break;
    }
  }

  /// Возвращает следующий токен или `null` в конце данных.
  Object? nextToken() {
    skipWhitespaceAndComments();
    if (position >= data.length) return null;
    final c = data[position];
    switch (c) {
      case 0x2F:
        return _readName();
      case 0x28:
        return _readLiteralString();
      case 0x3C:
        if (peek(1) == 0x3C) {
          position += 2;
          return const _Keyword('<<');
        }
        return _readHexString();
      case 0x3E:
        if (peek(1) == 0x3E) {
          position += 2;
          return const _Keyword('>>');
        }
        position++;
        return const _Keyword('>');
      case 0x5B:
        position++;
        return const _Keyword('[');
      case 0x5D:
        position++;
        return const _Keyword(']');
      case 0x7B:
        position++;
        return const _Keyword('{');
      case 0x7D:
        position++;
        return const _Keyword('}');
    }
    if (c == 0x2B || c == 0x2D || c == 0x2E || (c >= 0x30 && c <= 0x39)) {
      return _readNumber();
    }
    return _readKeyword();
  }

  Object _readNumber() {
    final start = position;
    while (position < data.length) {
      final c = data[position];
      if ((c >= 0x30 && c <= 0x39) ||
          c == 0x2B ||
          c == 0x2D ||
          c == 0x2E ||
          c == 0x65 ||
          c == 0x45) {
        position++;
        continue;
      }
      break;
    }
    final text = String.fromCharCodes(data, start, position);
    final asInt = int.tryParse(text);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(text);
    if (asDouble != null) return asDouble;
    return _Keyword(text);
  }

  _Name _readName() {
    position++; // '/'
    final bytes = <int>[0x2F];
    while (position < data.length) {
      final c = data[position];
      if (!_isRegular(c)) break;
      if (c == 0x23) {
        final h1 = _hexValue(peek(1));
        final h2 = _hexValue(peek(2));
        if (h1 >= 0 && h2 >= 0) {
          bytes.add(h1 * 16 + h2);
          position += 3;
          continue;
        }
      }
      bytes.add(c);
      position++;
    }
    return _Name(String.fromCharCodes(bytes));
  }

  _PdfString _readLiteralString() {
    position++; // '('
    final bytes = <int>[];
    var depth = 1;
    while (position < data.length) {
      final c = data[position++];
      if (c == 0x5C) {
        if (position >= data.length) break;
        final escaped = data[position++];
        switch (escaped) {
          case 0x6E:
            bytes.add(0x0A);
          case 0x72:
            bytes.add(0x0D);
          case 0x74:
            bytes.add(0x09);
          case 0x62:
            bytes.add(0x08);
          case 0x66:
            bytes.add(0x0C);
          case 0x28:
            bytes.add(0x28);
          case 0x29:
            bytes.add(0x29);
          case 0x5C:
            bytes.add(0x5C);
          case 0x0D:
            if (position < data.length && data[position] == 0x0A) {
              position++;
            }
          case 0x0A:
            break;
          default:
            if (escaped >= 0x30 && escaped <= 0x37) {
              var value = escaped - 0x30;
              var count = 1;
              while (count < 3 && position < data.length) {
                final d = data[position];
                if (d < 0x30 || d > 0x37) break;
                value = value * 8 + (d - 0x30);
                position++;
                count++;
              }
              bytes.add(value & 0xFF);
            } else {
              bytes.add(escaped);
            }
        }
        continue;
      }
      if (c == 0x28) {
        depth++;
        bytes.add(c);
        continue;
      }
      if (c == 0x29) {
        depth--;
        if (depth == 0) break;
        bytes.add(c);
        continue;
      }
      bytes.add(c);
    }
    return _PdfString(Uint8List.fromList(bytes));
  }

  _PdfString _readHexString() {
    position++; // '<'
    final bytes = <int>[];
    var high = -1;
    while (position < data.length) {
      final c = data[position++];
      if (c == 0x3E) break;
      final value = _hexValue(c);
      if (value < 0) continue;
      if (high < 0) {
        high = value;
      } else {
        bytes.add(high * 16 + value);
        high = -1;
      }
    }
    if (high >= 0) bytes.add(high * 16);
    return _PdfString(Uint8List.fromList(bytes));
  }

  _Keyword _readKeyword() {
    final start = position;
    while (position < data.length && _isRegular(data[position])) {
      position++;
    }
    if (position == start) position++; // неизвестный разделитель
    return _Keyword(String.fromCharCodes(data, start, position));
  }
}

/// Разбор значений PDF (словари, массивы, ссылки, примитивы).
class _ObjectParser {
  const _ObjectParser();

  /// Читает следующее значение.
  Object? parse(_Lexer lexer, [int depth = 0]) {
    return fromToken(lexer, lexer.nextToken(), depth);
  }

  /// Преобразует уже прочитанный токен в значение.
  Object? fromToken(_Lexer lexer, Object? token, [int depth = 0]) {
    if (token == null) return null;
    if (depth > _maxObjectDepth) return null;
    if (token is _Keyword) {
      switch (token.value) {
        case '<<':
          return _parseDict(lexer, depth);
        case '[':
          return _parseArray(lexer, depth);
        case 'null':
          return null;
        case 'true':
          return true;
        case 'false':
          return false;
        default:
          return token;
      }
    }
    if (token is int) {
      final save = lexer.position;
      final second = lexer.nextToken();
      if (second is int) {
        final save2 = lexer.position;
        final third = lexer.nextToken();
        if (third is _Keyword && third.value == 'R') {
          return _PdfRef(token, second);
        }
        lexer.position = save2;
      }
      lexer.position = save;
      return token;
    }
    return token;
  }

  Map<String, Object?> _parseDict(_Lexer lexer, int depth) {
    final map = <String, Object?>{};
    while (true) {
      final key = lexer.nextToken();
      if (key == null) break;
      if (key is _Keyword && (key.value == '>>' || key.value == ']')) break;
      if (key is! _Name) continue;
      final valueToken = lexer.nextToken();
      if (valueToken == null) break;
      map[key.value] = fromToken(lexer, valueToken, depth + 1);
    }
    return map;
  }

  List<Object?> _parseArray(_Lexer lexer, int depth) {
    final list = <Object?>[];
    while (true) {
      final token = lexer.nextToken();
      if (token == null) break;
      if (token is _Keyword && (token.value == ']' || token.value == '>>')) {
        break;
      }
      list.add(fromToken(lexer, token, depth + 1));
    }
    return list;
  }
}

// ---------------------------------------------------------------------------
// Небольшие помощники для значений.
// ---------------------------------------------------------------------------

double? _toDouble(Object? value) => value is num ? value.toDouble() : null;

int? _toInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  return null;
}

String? _nameValue(Object? value) => value is _Name ? value.value : null;

/// Имя без ведущего слеша (`/FlateDecode` → `FlateDecode`).
String _nameWithoutSlash(String name) =>
    name.startsWith('/') ? name.substring(1) : name;

Map<String, Object?>? _asDict(Object? value) =>
    value is Map<String, Object?> ? value : null;

List<Object?>? _asArray(Object? value) => value is List<Object?> ? value : null;

/// Пара «объектный поток / индекс объекта в нём» из xref-потока.
class _ObjStmLocation {
  const _ObjStmLocation(this.streamNumber, this.index);

  final int streamNumber;
  final int index;
}

/// Разобранный косвенный объект.
class _ParsedObject {
  const _ParsedObject(this.number, this.value);

  final int number;
  final Object? value;
}

// ---------------------------------------------------------------------------
// Матрица преобразования 3x2 (a b c d e f, вектор-строка).
// ---------------------------------------------------------------------------

/// Аффинное преобразование PDF: `[x y 1] * M`.
class _Mat {
  const _Mat(this.a, this.b, this.c, this.d, this.e, this.f);

  static const _Mat identity = _Mat(1, 0, 0, 1, 0, 0);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  static _Mat translation(double tx, double ty) => _Mat(1, 0, 0, 1, tx, ty);

  /// `this`, применённая первой, затем [other].
  _Mat multiply(_Mat other) => _Mat(
    a * other.a + b * other.c,
    a * other.b + b * other.d,
    c * other.a + d * other.c,
    c * other.b + d * other.d,
    e * other.a + f * other.c + other.e,
    e * other.b + f * other.d + other.f,
  );

  /// Равномерный масштаб (корень из модуля определителя).
  double uniformScale() {
    final det = (a * d - b * c).abs();
    return det > 0 ? math.sqrt(det) : 1.0;
  }

  double applyX(double x, double y) => a * x + c * y + e;

  double applyY(double x, double y) => b * x + d * y + f;
}

// ---------------------------------------------------------------------------
// Шрифты и кодировки.
// ---------------------------------------------------------------------------

/// Кодировка простого (однобайтового) шрифта.
enum _SimpleEncoding { winAnsi, macRoman, standard }

/// Таблицы однобайтовых кодировок (код → Unicode).
class _EncodingTables {
  static const String _cp1252High =
      '\u20AC\u0000\u201A\u0192\u201E\u2026\u2020\u2021'
      '\u02C6\u2030\u0160\u2039\u0152\u0000\u017D\u0000'
      '\u0000\u2018\u2019\u201C\u201D\u2022\u2013\u2014'
      '\u02DC\u2122\u0161\u203A\u0153\u0000\u017E\u0178';

  static const String _macRomanHigh =
      '\u00C4\u00C5\u00C7\u00C9\u00D1\u00D6\u00DC\u00E1'
      '\u00E0\u00E2\u00E4\u00E3\u00E5\u00E7\u00E9\u00E8'
      '\u00EA\u00EB\u00ED\u00EC\u00EE\u00EF\u00F1\u00F3'
      '\u00F2\u00F4\u00F6\u00F5\u00FA\u00F9\u00FB\u00FC'
      '\u2020\u00B0\u00A2\u00A3\u00A7\u2022\u00B6\u00DF'
      '\u00AE\u00A9\u2122\u00B4\u00A8\u2260\u00C6\u00D8'
      '\u221E\u00B1\u2264\u2265\u00A5\u00B5\u2202\u2211'
      '\u220F\u03C0\u222B\u00AA\u00BA\u03A9\u00E6\u00F8'
      '\u00BF\u00A1\u00AC\u221A\u0192\u2248\u2206\u00AB'
      '\u00BB\u2026\u00A0\u00C0\u00C3\u00D5\u0152\u0153'
      '\u2013\u2014\u201C\u201D\u2018\u2019\u00F7\u25CA'
      '\u00FF\u0178\u2044\u20AC\u2039\u203A\uFB01\uFB02'
      '\u2021\u00B7\u201A\u201E\u2030\u00C2\u00CA\u00C1'
      '\u00CB\u00C8\u00CD\u00CE\u00CF\u00CC\u00D3\u00D4'
      '\uF8FF\u00D2\u00DA\u00DB\u00D9\u0131\u02C6\u02DC'
      '\u00AF\u02D8\u02D9\u02DA\u00B8\u02DD\u02DB\u02C7';

  static const String _standardHigh =
      '\u0000\u00A1\u00A2\u00A3\u2044\u00A5\u0192\u00A7'
      '\u00A4\u0027\u201C\u00AB\u2039\u203A\uFB01\uFB02'
      '\u0000\u2013\u2020\u2021\u00B7\u00B6\u2022\u201A'
      '\u201E\u201D\u201C\u2026\u2030\u00C2\u00CA\u00C1'
      '\u00CB\u00C8\u00CD\u00CE\u00CF\u00CC\u00D3\u00D4'
      '\u0000\u00D2\u00DA\u00DB\u00D9\u0131\u02C6\u02DC'
      '\u00AF\u02D8\u02D9\u02DA\u00B8\u02DD\u02DB\u02C7'
      '\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000'
      '\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000';

  static const String _cp1251High =
      '\u0402\u0403\u201A\u0453\u201E\u2026\u2020\u2021'
      '\u20AC\u2030\u0409\u2039\u040A\u040C\u040B\u040F'
      '\u0452\u2018\u2019\u201C\u201D\u2022\u2013\u2014'
      '\u0000\u2122\u0459\u203A\u045A\u045C\u045B\u045F'
      '\u00A0\u040E\u045E\u0408\u00A4\u0490\u00A6\u00A7'
      '\u0401\u00A9\u0404\u00AB\u00AC\u00AD\u00AE\u0407'
      '\u00B0\u00B1\u0406\u0456\u0491\u00B5\u00B6\u00B7'
      '\u0451\u2116\u0454\u00BB\u0458\u0405\u0455\u0457';

  /// Возвращает строку для кода [code] (0..255) или `null`.
  ///
  /// Для `/WinAnsiEncoding` и `/StandardEncoding` байты 0x80..0xFF трактуются
  /// как CP1251 (Windows-1251): русские генераторы PDF массово кладут байты
  /// CP1251 в шрифт с объявленной кодировкой WinAnsi, а настоящая CP1252 в
  /// кириллических документах не встречается. Если код в CP1251 не определён
  /// (например, 0x98), берётся значение из объявленной таблицы.
  ///
  /// Приоритет `/ToUnicode` и `/Differences` выше: если они есть у шрифта,
  /// применяются именно они (см. `_FontInfo._charFor`), поэтому корректно
  /// размеченные PDF с западноевропейским текстом читаются точно.
  static String? lookup(_SimpleEncoding encoding, int code) {
    if (code < 0 || code > 255) return null;
    if (code < 0x20) return null;
    if (code < 0x80) return String.fromCharCode(code);
    switch (encoding) {
      case _SimpleEncoding.winAnsi:
        return lookupCp1251(code) ?? _lookupCp1252(code);
      case _SimpleEncoding.macRoman:
        return String.fromCharCode(_macRomanHigh.codeUnitAt(code - 0x80));
      case _SimpleEncoding.standard:
        return lookupCp1251(code) ?? _lookupStandard(code);
    }
  }

  /// Байт в диапазоне 0xA0..0xFF совпадает с Unicode-кодом (Latin-1).
  static String? _lookupCp1252(int code) {
    if (code < 0xA0) {
      final char = _cp1252High.codeUnitAt(code - 0x80);
      return char == 0 ? null : String.fromCharCode(char);
    }
    return String.fromCharCode(code);
  }

  static String? _lookupStandard(int code) {
    if (code < 0xA0) return null;
    final char = _standardHigh.codeUnitAt(code - 0xA0);
    return char == 0 ? null : String.fromCharCode(char);
  }

  /// Таблица CP1251 (Windows-1251): 0xC0..0xFF — сплошной блок А..я.
  static String? lookupCp1251(int code) {
    if (code < 0x20) return null;
    if (code < 0x80) return String.fromCharCode(code);
    if (code >= 0xC0) return String.fromCharCode(0x0410 + (code - 0xC0));
    final char = _cp1251High.codeUnitAt(code - 0x80);
    return char == 0 ? null : String.fromCharCode(char);
  }
}

/// Один глиф из показанной строки: код в шрифте и ширина (в 1/1000 em).
class _Glyph {
  const _Glyph(this.code, this.width);

  final int code;
  final double width;
}

/// Сведения о шрифте, нужные для декодирования кодов и оценок ширины.
class _FontInfo {
  _FontInfo({
    required this.twoByte,
    required this.toUnicode,
    required this.differences,
    required this.encoding,
    required this.widths,
    required this.defaultWidth,
  });

  final bool twoByte;
  final Map<int, String>? toUnicode;
  final Map<int, String>? differences;
  final _SimpleEncoding encoding;
  final Map<int, double> widths;
  final double defaultWidth;

  /// Декодирует один байт в текст.
  ///
  /// Приоритет: `/ToUnicode` → `/Differences` → базовая кодировка шрифта
  /// (для WinAnsi/Standard высокие байты трактуются как CP1251, см.
  /// [_EncodingTables.lookup]).
  String _charFor(int code) {
    final unicode = toUnicode;
    if (unicode != null) {
      final mapped = unicode[code];
      if (mapped != null) return mapped;
      if (twoByte) return '';
    }
    final diff = differences;
    if (diff != null) {
      final mapped = diff[code];
      if (mapped != null) return mapped;
    }
    if (twoByte) return '';
    final mapped = _EncodingTables.lookup(encoding, code);
    if (mapped != null) return mapped;
    return code >= 0x20 ? String.fromCharCode(code) : '';
  }

  double widthOf(int code) => widths[code] ?? defaultWidth;

  /// Разбирает байты показанной строки на коды (без декодирования в Unicode).
  List<_Glyph> codesOf(Uint8List bytes) {
    final glyphs = <_Glyph>[];
    if (twoByte) {
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        final code = (bytes[i] << 8) | bytes[i + 1];
        glyphs.add(_Glyph(code, widthOf(code)));
      }
    } else {
      for (final byte in bytes) {
        glyphs.add(_Glyph(byte, widthOf(byte)));
      }
    }
    return glyphs;
  }

  /// Декодирует коды в текст.
  String textOf(List<int> codes) {
    final buffer = StringBuffer();
    for (final code in codes) {
      buffer.write(_charFor(code));
    }
    return buffer.toString();
  }
}

/// Имена глифов Adobe — минимально необходимый набор (латиница, пунктуация,
/// кириллица `afii*`, `uniXXXX`).
String? _glyphNameToUnicode(String name) {
  if (name.isEmpty) return null;
  if (name.length == 1) return name;
  if (name.startsWith('uni') && name.length >= 7) {
    final code = int.tryParse(name.substring(3, 7), radix: 16);
    if (code != null) return String.fromCharCode(code);
  }
  if (name.startsWith('u') && name.length >= 5) {
    final code = int.tryParse(name.substring(1), radix: 16);
    if (code != null) return String.fromCharCode(code);
  }
  if (name.startsWith('afii')) {
    final number = int.tryParse(name.substring(4));
    if (number != null) {
      // afii10017..afii10048 — А..Я, afii10065..afii10096 — а..я.
      if (number >= 10017 && number <= 10048) {
        return String.fromCharCode(0x0410 + (number - 10017));
      }
      if (number >= 10065 && number <= 10096) {
        return String.fromCharCode(0x0430 + (number - 10065));
      }
      switch (number) {
        case 10049:
          return '\u0401';
        case 10050:
          return '\u0451';
        case 10054:
          return '\u0404';
        case 10055:
          return '\u0454';
        case 10056:
          return '\u0407';
        case 10057:
          return '\u0457';
        case 10058:
          return '\u0406';
        case 10059:
          return '\u0456';
        case 10060:
          return '\u0490';
        case 10061:
          return '\u0491';
      }
    }
    return null;
  }
  const named = <String, String>{
    'space': ' ',
    'exclam': '!',
    'quotedbl': '"',
    'numbersign': '#',
    'dollar': r'$',
    'percent': '%',
    'ampersand': '&',
    'quotesingle': "'",
    'parenleft': '(',
    'parenright': ')',
    'asterisk': '*',
    'plus': '+',
    'comma': ',',
    'hyphen': '-',
    'period': '.',
    'slash': '/',
    'colon': ':',
    'semicolon': ';',
    'less': '<',
    'equal': '=',
    'greater': '>',
    'question': '?',
    'at': '@',
    'bracketleft': '[',
    'backslash': r'\',
    'bracketright': ']',
    'asciicircum': '^',
    'underscore': '_',
    'grave': '`',
    'braceleft': '{',
    'bar': '|',
    'braceright': '}',
    'asciitilde': '~',
    'endash': '\u2013',
    'emdash': '\u2014',
    'quoteleft': '\u2018',
    'quoteright': '\u2019',
    'quotedblleft': '\u201C',
    'quotedblright': '\u201D',
    'bullet': '\u2022',
    'ellipsis': '\u2026',
    'nbspace': '\u00A0',
    'degree': '\u00B0',
    'numero': '\u2116',
    'guillemotleft': '\u00AB',
    'guillemotright': '\u00BB',
  };
  return named[name];
}

// ---------------------------------------------------------------------------
// Текст: «сырые» фрагменты и геометрия.
// ---------------------------------------------------------------------------

/// Фрагмент, полученный из потока содержимого до декодирования в Unicode.
class _RawFragment {
  const _RawFragment({
    required this.font,
    required this.codes,
    required this.startX,
    required this.startY,
    required this.endX,
    required this.endY,
    required this.baseline,
    required this.fontSize,
  });

  final _FontInfo font;
  final List<int> codes;
  final double startX;
  final double startY;
  final double endX;
  final double endY;
  final double baseline;
  final double fontSize;
}

/// Преобразование координат страницы в top-origin координаты отображения
/// с учётом `/Rotate`.
class _PageTransform {
  const _PageTransform({
    required this.x0,
    required this.y0,
    required this.width,
    required this.height,
    required this.rotate,
  });

  final double x0;
  final double y0;
  final double width;
  final double height;
  final int rotate;

  double displayWidth() =>
      rotate == 90 || rotate == 270 ? height : width;

  double displayHeight() =>
      rotate == 90 || rotate == 270 ? width : height;

  double displayX(double x, double y) {
    switch (rotate) {
      case 90:
        return y - y0;
      case 180:
        return width - (x - x0);
      case 270:
        return height - (y - y0);
      default:
        return x - x0;
    }
  }

  double displayTop(double x, double y) {
    switch (rotate) {
      case 90:
        return x - x0;
      case 180:
        return y - y0;
      case 270:
        return width - (x - x0);
      default:
        return height - (y - y0);
    }
  }
}

/// Страница, разобранная до сборки строк.
class _RawPage {
  const _RawPage({
    required this.pageNumber,
    required this.transform,
    required this.fragments,
  });

  final int pageNumber;
  final _PageTransform transform;
  final List<_RawFragment> fragments;
}

/// Фрагмент с рассчитанным прямоугольником (для сортировки в строки).
class _PlacedFragment {
  const _PlacedFragment(this.fragment, this.baseline);

  final PdfTextFragment fragment;
  final double baseline;
}

/// Состояние графики/текста (часть сохраняется по `q`/`Q`).
class _GraphicsState {
  _Mat ctm = _Mat.identity;
  _FontInfo? font;
  double fontSize = 0;
  double charSpacing = 0;
  double wordSpacing = 0;
  double horizontalScale = 1;
  double leading = 0;
  double rise = 0;

  _GraphicsState copy() => _GraphicsState()
    ..ctm = ctm
    ..font = font
    ..fontSize = fontSize
    ..charSpacing = charSpacing
    ..wordSpacing = wordSpacing
    ..horizontalScale = horizontalScale
    ..leading = leading
    ..rise = rise;
}

/// Разбор потока содержимого: операторы, текст, координаты.
class _ContentParser {
  _ContentParser({
    required this.file,
    required this.content,
    required this.resources,
  });

  final _PdfFile file;
  final Uint8List content;
  final Map<String, Object?>? resources;

  final List<_RawFragment> _fragments = <_RawFragment>[];
  final List<_GraphicsState> _stack = <_GraphicsState>[];
  final Map<Object, _FontInfo?> _fontCache = <Object, _FontInfo?>{};

  _GraphicsState _state = _GraphicsState();
  _Mat _textMatrix = _Mat.identity;
  _Mat _lineMatrix = _Mat.identity;

  final List<int> _pendingCodes = <int>[];
  _FontInfo? _pendingFont;
  bool _hasPending = false;
  double _pendingStartX = 0;
  double _pendingStartY = 0;
  double _pendingEndX = 0;
  double _pendingEndY = 0;
  double _pendingFontSize = 0;

  bool _limitReached = false;

  /// Разбирает поток и возвращает фрагменты.
  List<_RawFragment> parse() {
    final lexer = _Lexer(content);
    final operands = <Object?>[];
    final parser = _ObjectParser();
    while (true) {
      if (_limitReached) break;
      final token = lexer.nextToken();
      if (token == null) break;
      if (token is _Keyword) {
        switch (token.value) {
          case '[':
            operands.add(_readArray(lexer, parser));
          case ']':
            break;
          case 'BI':
            _flush();
            _skipInlineImage(lexer);
          default:
            _execute(token.value, operands);
            operands.clear();
        }
        continue;
      }
      operands.add(parser.fromToken(lexer, token));
      if (operands.length > 64) {
        operands.removeRange(0, operands.length - 32);
      }
    }
    _flush();
    return _fragments;
  }

  List<Object?> _readArray(_Lexer lexer, _ObjectParser parser) {
    final list = <Object?>[];
    while (true) {
      final token = lexer.nextToken();
      if (token == null) break;
      if (token is _Keyword) {
        if (token.value == ']' || token.value == '>>') break;
        if (token.value == '[') {
          list.add(_readArray(lexer, parser));
          continue;
        }
      }
      list.add(parser.fromToken(lexer, token));
    }
    return list;
  }

  void _skipInlineImage(_Lexer lexer) {
    final data = lexer.data;
    var index = lexer.position;
    while (index < data.length - 1) {
      if (data[index] == 0x45 && data[index + 1] == 0x49) {
        final before = index == 0 ? 0x20 : data[index - 1];
        final after = index + 2 < data.length ? data[index + 2] : 0x20;
        final beforeOk =
            _Lexer._isWhitespace(before) || _Lexer._isDelimiter(before);
        final afterOk =
            _Lexer._isWhitespace(after) || _Lexer._isDelimiter(after);
        if (beforeOk && afterOk) {
          lexer.position = index + 2;
          return;
        }
      }
      index++;
    }
    lexer.position = data.length;
  }

  void _execute(String operator, List<Object?> args) {
    switch (operator) {
      case 'q':
        if (_stack.length < 64) _stack.add(_state.copy());
      case 'Q':
        if (_stack.isNotEmpty) _state = _stack.removeLast();
      case 'cm':
        if (args.length >= 6) {
          final m = _matrixFrom(args, 0);
          if (m != null) _state.ctm = m.multiply(_state.ctm);
        }
      case 'BT':
        _textMatrix = _Mat.identity;
        _lineMatrix = _Mat.identity;
      case 'ET':
        _flush();
      case 'Tf':
        final name = args.isNotEmpty ? _nameValue(args[0]) : null;
        _flush();
        _state.font = name == null ? null : _fontFor(name);
        _state.fontSize = args.length > 1 ? (_toDouble(args[1]) ?? 0) : 0;
      case 'Td':
        _flush();
        if (args.length >= 2) {
          _lineMatrix = _Mat.translation(
            _toDouble(args[0]) ?? 0,
            _toDouble(args[1]) ?? 0,
          ).multiply(_lineMatrix);
          _textMatrix = _lineMatrix;
        }
      case 'TD':
        _flush();
        if (args.length >= 2) {
          final ty = _toDouble(args[1]) ?? 0;
          _state.leading = -ty;
          _lineMatrix = _Mat.translation(
            _toDouble(args[0]) ?? 0,
            ty,
          ).multiply(_lineMatrix);
          _textMatrix = _lineMatrix;
        }
      case 'Tm':
        _flush();
        if (args.length >= 6) {
          final m = _matrixFrom(args, 0);
          if (m != null) {
            _lineMatrix = m;
            _textMatrix = m;
          }
        }
      case 'T*':
        _flush();
        _lineMatrix = _Mat.translation(
          0,
          -_state.leading,
        ).multiply(_lineMatrix);
        _textMatrix = _lineMatrix;
      case 'TL':
        if (args.isNotEmpty) _state.leading = _toDouble(args[0]) ?? 0;
      case 'Tc':
        if (args.isNotEmpty) _state.charSpacing = _toDouble(args[0]) ?? 0;
      case 'Tw':
        if (args.isNotEmpty) _state.wordSpacing = _toDouble(args[0]) ?? 0;
      case 'Tz':
        if (args.isNotEmpty) {
          _state.horizontalScale = (_toDouble(args[0]) ?? 100) / 100;
        }
      case 'Ts':
        if (args.isNotEmpty) _state.rise = _toDouble(args[0]) ?? 0;
      case 'Tj':
        if (args.isNotEmpty && args[0] is _PdfString) {
          _showText((args[0] as _PdfString).bytes);
        }
      case 'TJ':
        if (args.isNotEmpty && args[0] is List) {
          _showArray(args[0] as List<Object?>);
        }
      case "'":
        _flush();
        _lineMatrix = _Mat.translation(
          0,
          -_state.leading,
        ).multiply(_lineMatrix);
        _textMatrix = _lineMatrix;
        if (args.isNotEmpty && args[0] is _PdfString) {
          _showText((args[0] as _PdfString).bytes);
        }
      case '"':
        if (args.length >= 3) {
          _state.wordSpacing = _toDouble(args[0]) ?? 0;
          _state.charSpacing = _toDouble(args[1]) ?? 0;
          _flush();
          _lineMatrix = _Mat.translation(
            0,
            -_state.leading,
          ).multiply(_lineMatrix);
          _textMatrix = _lineMatrix;
          if (args[2] is _PdfString) {
            _showText((args[2] as _PdfString).bytes);
          }
        }
    }
  }

  _Mat? _matrixFrom(List<Object?> args, int offset) {
    final values = <double>[];
    for (var i = 0; i < 6; i++) {
      final value = _toDouble(args[offset + i]);
      if (value == null) return null;
      values.add(value);
    }
    return _Mat(
      values[0],
      values[1],
      values[2],
      values[3],
      values[4],
      values[5],
    );
  }

  _FontInfo? _fontFor(String name) {
    final fonts = _asDict(file.deref(resources?['/Font']));
    if (fonts == null) return null;
    final raw = file.deref(fonts[name]);
    final dict = _asDict(raw);
    if (dict == null) return null;
    if (_fontCache.containsKey(dict)) return _fontCache[dict];
    final info = file.buildFont(dict);
    _fontCache[dict] = info;
    return info;
  }

  double _deviceFontSize() {
    final m = _textMatrix.multiply(_state.ctm);
    return _state.fontSize * m.uniformScale();
  }

  void _showArray(List<Object?> items) {
    for (final item in items) {
      if (item is _PdfString) {
        _showText(item.bytes);
        continue;
      }
      final adjustment = _toDouble(item);
      if (adjustment == null) continue;
      final shift =
          -(adjustment / 1000.0) * _state.fontSize * _state.horizontalScale;
      if (shift > 0.3 * _deviceFontSize() && _hasPending) _flush();
      _textMatrix = _Mat.translation(shift, 0).multiply(_textMatrix);
      _updatePendingEnd();
    }
  }

  void _showText(Uint8List bytes) {
    final font = _state.font;
    if (font == null || bytes.isEmpty) return;
    if (_fragments.length >= _maxFragmentsPerPage) {
      _limitReached = true;
      return;
    }
    final glyphs = font.codesOf(bytes);
    for (final glyph in glyphs) {
      final combined = _textMatrix.multiply(_state.ctm);
      final originX = combined.applyX(0, _state.rise);
      final originY = combined.applyY(0, _state.rise);
      if (!_hasPending) {
        _beginFragment(font, originX, originY);
      }
      _pendingCodes.add(glyph.code);
      if (_pendingCodes.length > _maxFragmentsPerPage * 16) {
        _limitReached = true;
        break;
      }
      final advance =
          (glyph.width / 1000.0) * _state.fontSize +
          _state.charSpacing +
          (glyph.code == 0x20 ? _state.wordSpacing : 0.0);
      _textMatrix = _Mat.translation(
        advance * _state.horizontalScale,
        0,
      ).multiply(_textMatrix);
      _updatePendingEnd();
    }
  }

  void _beginFragment(_FontInfo font, double x, double y) {
    _hasPending = true;
    _pendingFont = font;
    _pendingCodes.clear();
    _pendingStartX = x;
    _pendingStartY = y;
    _pendingEndX = x;
    _pendingEndY = y;
    _pendingFontSize = _deviceFontSize();
  }

  void _updatePendingEnd() {
    if (!_hasPending) return;
    final combined = _textMatrix.multiply(_state.ctm);
    _pendingEndX = combined.applyX(0, _state.rise);
    _pendingEndY = combined.applyY(0, _state.rise);
  }

  void _flush() {
    if (!_hasPending) return;
    final font = _pendingFont;
    if (font != null && _pendingCodes.isNotEmpty) {
      final codes = List<int>.of(_pendingCodes);
      _fragments.add(
        _RawFragment(
          font: font,
          codes: codes,
          startX: _pendingStartX,
          startY: _pendingStartY,
          endX: _pendingEndX,
          endY: _pendingEndY,
          baseline: _pendingStartY,
          fontSize: _pendingFontSize <= 0 ? 12 : _pendingFontSize,
        ),
      );
    }
    _pendingCodes.clear();
    _pendingFont = null;
    _hasPending = false;
  }
}

// ---------------------------------------------------------------------------
// Разбор файла.
// ---------------------------------------------------------------------------

/// Разобранный PDF-файл: таблицы объектов, потоки, страницы.
class _PdfFile {
  _PdfFile(this.bytes);

  final Uint8List bytes;

  final Map<int, int> _offsets = <int, int>{};
  final Map<int, int> _scanOffsets = <int, int>{};
  final Map<int, _ObjStmLocation> _compressed = <int, _ObjStmLocation>{};
  final Map<int, Object?> _cache = <int, Object?>{};
  final Map<_StreamValue, Uint8List?> _decodedStreams =
      <_StreamValue, Uint8List?>{};
  final Set<int> _loading = <int>{};
  final Set<int> _freeObjects = <int>{};
  Map<String, Object?>? _trailer;
  bool _encrypted = false;
  bool _objectStreamsIndexed = false;

  static final RegExp _objectHeaderPattern = RegExp(
    r'(\d{1,10})[ \t\r\n\f\x00]+(\d{1,5})[ \t\r\n\f\x00]+obj\b',
  );

  // --- Точка входа ---------------------------------------------------------

  /// Извлекает текст документа.
  PdfDocumentText extract() {
    if (bytes.isEmpty) {
      throw PdfTextExtractionException('PDF-файл пуст');
    }
    if (!_looksLikePdf()) {
      throw PdfTextExtractionException(
        'Данные не похожи на PDF: не найдена подпись "%PDF-"',
      );
    }
    _scanIndirectObjects();
    _parseXrefChain();
    if (_offsets.isEmpty && _scanOffsets.isEmpty && _compressed.isEmpty) {
      throw PdfTextExtractionException(
        'В файле не найдено ни одного косвенного объекта',
      );
    }
    if (_encrypted) {
      throw PdfTextExtractionException(
        'PDF зашифрован: извлечение текста без расшифровки невозможно',
      );
    }
    final root = _resolveCatalog();
    if (root == null) {
      throw PdfTextExtractionException(
        'Не найден каталог документа (/Root): файл повреждён или неполон',
      );
    }
    final pageDicts = _collectPages(root);
    final rawPages = <_RawPage>[];
    for (var i = 0; i < pageDicts.length; i++) {
      rawPages.add(_parsePage(pageDicts[i], i + 1));
    }
    final pages = <PdfPageText>[];
    for (final rawPage in rawPages) {
      pages.add(_buildPageText(rawPage));
    }
    return PdfDocumentText(pages: pages);
  }

  bool _looksLikePdf() {
    final signature = '%PDF-'.codeUnits;
    final limit = math.min(bytes.length, 4096);
    for (var i = 0; i + signature.length <= limit; i++) {
      var matches = true;
      for (var j = 0; j < signature.length; j++) {
        if (bytes[i + j] != signature[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }

  bool _matchesAscii(int offset, String text) {
    if (offset < 0 || offset + text.length > bytes.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (bytes[offset + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  // --- Резервный полный скан ----------------------------------------------

  /// Ищет все заголовки `N G obj` во всём файле (используется как fallback,
  /// когда xref отсутствует, повреждён или неполон).
  void _scanIndirectObjects() {
    final text = latin1.decode(bytes);
    for (final match in _objectHeaderPattern.allMatches(text)) {
      final numberText = match.group(1);
      if (numberText == null) continue;
      final number = int.tryParse(numberText);
      if (number == null || number < 0) continue;
      // При инкрементальных обновлениях более поздняя версия объекта должна
      // побеждать, поэтому последнее вхождение перекрывает предыдущие.
      _scanOffsets[number] = match.start;
    }
  }

  // --- xref -----------------------------------------------------------------

  int? _findStartXref() {
    final from = math.max(0, bytes.length - 4096);
    for (var i = bytes.length - 9; i >= from; i--) {
      if (_matchesAscii(i, 'startxref')) {
        final lexer = _Lexer(bytes, i + 9);
        final token = lexer.nextToken();
        final offset = _toInt(token);
        if (offset != null) return offset;
      }
    }
    return null;
  }

  void _parseXrefChain() {
    var offset = _findStartXref();
    final visited = <int>{};
    var guard = 0;
    while (offset != null && guard++ < 64) {
      if (offset < 0 || offset >= bytes.length) break;
      if (!visited.add(offset)) break;
      final next = _parseXrefSectionAt(offset);
      if (next == null) break;
      if (next == offset) break;
      offset = next;
    }
  }

  int? _parseXrefSectionAt(int offset) {
    final lexer = _Lexer(bytes, offset);
    lexer.skipWhitespaceAndComments();
    final first = lexer.nextToken();
    if (first is _Keyword && first.value == 'xref') {
      return _parseClassicXref(lexer);
    }
    final parsed = _parseIndirectObjectAt(offset);
    final value = parsed?.value;
    if (value is! _StreamValue) return null;
    if (_nameValue(deref(value.dict['/Type'])) != '/XRef') return null;
    _mergeXrefStream(value.dict, value);
    return _toInt(deref(value.dict['/Prev']));
  }

  int? _parseClassicXref(_Lexer lexer) {
    int? prev;
    while (true) {
      final token = lexer.nextToken();
      if (token == null) break;
      if (token is _Keyword) {
        if (token.value == 'trailer') {
          final trailer = _ObjectParser().parse(lexer);
          final dict = _asDict(trailer);
          if (dict != null) {
            _mergeTrailer(dict);
            prev = _toInt(deref(dict['/Prev'])) ?? prev;
            final hybrid = _toInt(deref(dict['/XRefStm']));
            if (hybrid != null) _parseXrefSectionAt(hybrid);
          }
          break;
        }
        continue;
      }
      if (token is int) {
        final count = _toInt(lexer.nextToken());
        if (count == null) break;
        for (var i = 0; i < count; i++) {
          final entryOffset = _toInt(lexer.nextToken());
          final generation = _toInt(lexer.nextToken());
          final typeToken = lexer.nextToken();
          if (entryOffset == null || generation == null) break;
          if (typeToken is! _Keyword) break;
          final number = token + i;
          if (typeToken.value == 'n') {
            if (entryOffset > 0 && entryOffset < bytes.length) {
              _offsets.putIfAbsent(number, () => entryOffset);
            }
          } else {
            _freeObjects.add(number);
          }
        }
        continue;
      }
      break;
    }
    return prev;
  }

  void _mergeXrefStream(Map<String, Object?> dict, _StreamValue stream) {
    _mergeTrailer(dict);
    final data = _decodeStream(stream);
    if (data == null) return;
    final widthsRaw = _asArray(deref(dict['/W']));
    if (widthsRaw == null || widthsRaw.length < 3) return;
    final widths = <int>[];
    for (var i = 0; i < 3; i++) {
      widths.add(_toInt(deref(widthsRaw[i])) ?? 0);
    }
    final rowLength = widths[0] + widths[1] + widths[2];
    if (rowLength <= 0) return;
    final size = _toInt(deref(dict['/Size'])) ?? 0;
    List<int> index;
    final indexRaw = _asArray(deref(dict['/Index']));
    if (indexRaw != null && indexRaw.length >= 2) {
      index = <int>[];
      for (final item in indexRaw) {
        index.add(_toInt(deref(item)) ?? 0);
      }
    } else {
      index = <int>[0, size];
    }
    var position = 0;
    for (var i = 0; i + 1 < index.length; i += 2) {
      var number = index[i];
      final count = index[i + 1];
      for (var k = 0; k < count; k++, number++) {
        if (position + rowLength > data.length) return;
        final type = widths[0] == 0
            ? 1
            : _readBigEndian(data, position, widths[0]);
        final field2 = _readBigEndian(
          data,
          position + widths[0],
          widths[1],
        );
        final field3 = _readBigEndian(
          data,
          position + widths[0] + widths[1],
          widths[2],
        );
        position += rowLength;
        if (type == 1) {
          if (field2 > 0 && field2 < bytes.length) {
            _offsets.putIfAbsent(number, () => field2);
          }
        } else if (type == 2) {
          _compressed.putIfAbsent(
            number,
            () => _ObjStmLocation(field2, field3),
          );
        } else {
          _freeObjects.add(number);
        }
      }
    }
  }

  int _readBigEndian(Uint8List data, int offset, int width) {
    var value = 0;
    for (var i = 0; i < width; i++) {
      final index = offset + i;
      value = (value << 8) | (index < data.length ? data[index] : 0);
    }
    return value;
  }

  void _mergeTrailer(Map<String, Object?> dict) {
    final trailer = _trailer ??= <String, Object?>{};
    for (final key in const <String>['/Root', '/Info', '/Size', '/ID']) {
      if (!trailer.containsKey(key) && dict.containsKey(key)) {
        trailer[key] = dict[key];
      }
    }
    if (dict.containsKey('/Encrypt')) _encrypted = true;
    if (dict.containsKey('/Root')) {
      trailer.putIfAbsent('/Root', () => dict['/Root']);
    }
  }

  // --- Объекты --------------------------------------------------------------

  /// Разыменовывает ссылки (цепочка `R`) до первого не-ссылочного значения.
  Object? deref(Object? value) {
    var current = value;
    var guard = 0;
    while (current is _PdfRef && guard++ < _maxObjectDepth) {
      current = _resolveObject(current.number);
    }
    return current;
  }

  Object? _resolveObject(int number) {
    if (number < 0) return null;
    if (_cache.containsKey(number)) return _cache[number];
    if (_cache.length >= _maxObjects) return null;
    if (!_loading.add(number)) return null; // цикл
    try {
    var value = _parseObjectFromOffsets(number) ?? _objectFromObjectStream(number);
      _cache[number] = value;
      return value;
    } finally {
      _loading.remove(number);
    }
  }

  Object? _parseObjectFromOffsets(int number) {
    final candidates = <int>[];
    final fromXref = _offsets[number];
    if (fromXref != null) candidates.add(fromXref);
    final fromScan = _scanOffsets[number];
    if (fromScan != null && fromScan != fromXref) candidates.add(fromScan);
    for (final offset in candidates) {
      final parsed = _parseIndirectObjectAt(offset, expectedNumber: number);
      if (parsed != null && parsed.number == number) return parsed.value;
    }
    return null;
  }

  _ParsedObject? _parseIndirectObjectAt(int offset, {int? expectedNumber}) {
    if (offset < 0 || offset >= bytes.length) return null;
    final lexer = _Lexer(bytes, offset);
    lexer.skipWhitespaceAndComments();
    final number = _toInt(lexer.nextToken());
    if (number == null) return null;
    final generation = _toInt(lexer.nextToken());
    if (generation == null) return null;
    final keyword = lexer.nextToken();
    if (keyword is! _Keyword || keyword.value != 'obj') return null;
    if (expectedNumber != null && number != expectedNumber) return null;
    final parser = _ObjectParser();
    final value = parser.parse(lexer);
    var stream = value;
    final save = lexer.position;
    lexer.skipWhitespaceAndComments();
    final streamKeyword = lexer.nextToken();
    if (streamKeyword is _Keyword &&
        streamKeyword.value == 'stream' &&
        value is Map<String, Object?>) {
      var dataStart = lexer.position;
      if (dataStart < bytes.length && bytes[dataStart] == 0x0D) dataStart++;
      if (dataStart < bytes.length && bytes[dataStart] == 0x0A) dataStart++;
      int? dataEnd;
      // Сначала пробуем довериться /Length (если он прямой и корректен).
      final declaredLength = _toInt(deref(value['/Length']));
      if (declaredLength != null &&
          declaredLength >= 0 &&
          dataStart + declaredLength <= bytes.length) {
        final after = _skipWhitespaceAt(dataStart + declaredLength);
        if (_matchesAscii(after, 'endstream')) {
          dataEnd = dataStart + declaredLength;
        }
      }
      int resolvedEnd = dataEnd ?? _findEndstream(dataStart);
      if (resolvedEnd < 0) {
        resolvedEnd = declaredLength == null
            ? bytes.length
            : math.min(bytes.length, dataStart + declaredLength);
      } else {
        while (resolvedEnd > dataStart &&
            (bytes[resolvedEnd - 1] == 0x0A || bytes[resolvedEnd - 1] == 0x0D)) {
          resolvedEnd--;
        }
      }
      if (resolvedEnd < dataStart) resolvedEnd = dataStart;
      stream = _StreamValue(value, bytes, dataStart, resolvedEnd);
    } else {
      lexer.position = save;
    }
    return _ParsedObject(number, stream);
  }

  int _skipWhitespaceAt(int offset) {
    var index = offset;
    while (index < bytes.length && _Lexer._isWhitespace(bytes[index])) {
      index++;
    }
    return index;
  }

  int _findEndstream(int from) {
    const pattern = 'endstream';
    final length = pattern.length;
    for (var i = from; i + length <= bytes.length; i++) {
      if (bytes[i] != 0x65) continue; // 'e'
      var matches = true;
      for (var j = 1; j < length; j++) {
        if (bytes[i + j] != pattern.codeUnitAt(j)) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      final after = i + length < bytes.length ? bytes[i + length] : 0x20;
      if (!_Lexer._isWhitespace(after) && !_Lexer._isDelimiter(after)) {
        continue;
      }
      if (i > 0) {
        final before = bytes[i - 1];
        if (!_Lexer._isWhitespace(before) && !_Lexer._isDelimiter(before)) {
          continue;
        }
      }
      return i;
    }
    return -1;
  }

  // --- Объектные потоки -----------------------------------------------------

  Object? _objectFromObjectStream(int number) {
    var location = _compressed[number];
    if (location == null) {
      _indexObjectStreams();
      location = _compressed[number];
      if (location == null) return null;
    }
    final container = _resolveObject(location.streamNumber);
    if (container is! _StreamValue) return null;
    final data = _decodeStream(container);
    if (data == null) return null;
    return _objectAt(data, container.dict, location.index);
  }

  /// Извлекает объект с индексом [index] из объектного потока.
  Object? _objectAt(Uint8List data, Map<String, Object?> dict, int index) {
    final count = _toInt(deref(dict['/N'])) ?? 0;
    final first = _toInt(deref(dict['/First'])) ?? 0;
    if (count <= 0 || first < 0 || first > data.length) return null;
    final lexer = _Lexer(data);
    final numbers = <int>[];
    final offsets = <int>[];
    final limit = math.min(count, _maxObjectStreamObjects);
    for (var i = 0; i < limit; i++) {
      final number = _toInt(lexer.nextToken());
      final offset = _toInt(lexer.nextToken());
      if (number == null || offset == null) break;
      numbers.add(number);
      offsets.add(offset);
    }
    if (index < 0 || index >= numbers.length) return null;
    final start = first + offsets[index];
    if (start < 0 || start >= data.length) return null;
    final bodyLexer = _Lexer(data, start);
    const parser = _ObjectParser();
    return parser.parse(bodyLexer);
  }

  /// Индексирует все объектные потоки файла (нужно, когда xref не содержит
  /// type-2 записей, например в файлах со «сломанной» таблицей xref).
  void _indexObjectStreams() {
    if (_objectStreamsIndexed) return;
    _objectStreamsIndexed = true;
    final numbers = <int>{..._offsets.keys, ..._scanOffsets.keys}.toList()
      ..sort();
    var examined = 0;
    for (final number in numbers) {
      if (examined++ > 5000) break;
      if (_freeObjects.contains(number)) continue;
      if (_compressed.containsKey(number)) continue;
      final value = _resolveObject(number);
      if (value is! _StreamValue) continue;
      if (_nameValue(deref(value.dict['/Type'])) != '/ObjStm') continue;
      final data = _decodeStream(value);
      if (data == null) continue;
      final count = _toInt(deref(value.dict['/N'])) ?? 0;
      if (count <= 0) continue;
      final lexer = _Lexer(data);
      final limit = math.min(count, _maxObjectStreamObjects);
      for (var i = 0; i < limit; i++) {
        final objectNumber = _toInt(lexer.nextToken());
        final offset = _toInt(lexer.nextToken());
        if (objectNumber == null || offset == null) break;
        _compressed.putIfAbsent(
          objectNumber,
          () => _ObjStmLocation(number, i),
        );
      }
    }
  }

  // --- Потоки ---------------------------------------------------------------

  /// Раскодирует поток (фильтры + предикторы) с кэшированием результата.
  Uint8List? _decodeStream(_StreamValue stream) {
    if (_decodedStreams.containsKey(stream)) return _decodedStreams[stream];
    final result = _decodeStreamUncached(stream);
    _decodedStreams[stream] = result;
    return result;
  }

  Uint8List? _decodeStreamUncached(_StreamValue stream) {
    var data = stream.rawBytes;
    final filters = _filterNames(deref(stream.dict['/Filter']));
    final parms = _decodeParms(
      deref(stream.dict['/DecodeParms'] ?? stream.dict['/DP']),
      filters.length,
    );
    for (var i = 0; i < filters.length; i++) {
      final parameters = i < parms.length ? parms[i] : null;
      switch (filters[i]) {
        case 'FlateDecode':
        case 'Fl':
          final inflated = _inflate(data);
          if (inflated == null) return null;
          data = inflated;
        case 'ASCIIHexDecode':
        case 'AHx':
          data = _asciiHexDecode(data);
        case 'ASCII85Decode':
        case 'A85':
          final decoded = _ascii85Decode(data);
          if (decoded == null) return null;
          data = decoded;
        case 'LZWDecode':
        case 'LZW':
          final decoded = _lzwDecode(
            data,
            earlyChange:
                _toInt(deref(parameters?['/EarlyChange'])) ?? 1,
          );
          if (decoded == null) return null;
          data = decoded;
        case 'RunLengthDecode':
        case 'RL':
          data = _runLengthDecode(data);
        default:
          return null; // DCTDecode/JPXDecode/Crypt: текст из них не извлечь
      }
      if (data.length > _maxDecodedStreamBytes) {
        throw PdfTextExtractionException(
          'Раскодированный поток превышает лимит '
          '(${_maxDecodedStreamBytes ~/ (1 << 20)} МБ)',
        );
      }
      data = _applyPredictor(data, parameters);
    }
    return data;
  }

  /// Возвращает имена фильтров без ведущего слеша.
  List<String> _filterNames(Object? value) {
    if (value is _Name) return <String>[_nameWithoutSlash(value.value)];
    if (value is List) {
      final names = <String>[];
      for (final item in value) {
        final name = _nameValue(deref(item));
        if (name != null) names.add(_nameWithoutSlash(name));
      }
      return names;
    }
    return const <String>[];
  }

  List<Map<String, Object?>?> _decodeParms(Object? value, int filters) {
    final result = <Map<String, Object?>?>[];
    if (value is Map<String, Object?>) {
      result.add(value);
    } else if (value is List) {
      for (final item in value) {
        result.add(_asDict(deref(item)));
      }
    }
    while (result.length < filters) {
      result.add(null);
    }
    return result;
  }

  Uint8List? _inflate(Uint8List input) {
    if (input.isEmpty) return Uint8List(0);
    for (final raw in const <bool>[false, true]) {
      try {
        final filter = RawZLibFilter.inflateFilter(raw: raw);
        filter.process(input, 0, input.length);
        final builder = BytesBuilder(copy: false);
        for (var i = 0; i < 100000; i++) {
          final chunk = filter.processed();
          if (chunk == null || chunk.isEmpty) break;
          builder.add(chunk);
        }
        final result = builder.takeBytes();
        if (result.isNotEmpty) return result;
      } catch (_) {
        // пробуем следующий вариант
      }
      try {
        final decoded = ZLibDecoder(raw: raw).convert(input);
        if (decoded.isNotEmpty) return Uint8List.fromList(decoded);
      } catch (_) {
        // пробуем следующий вариант
      }
    }
    return null;
  }

  Uint8List _asciiHexDecode(Uint8List input) {
    final out = <int>[];
    var high = -1;
    for (final byte in input) {
      if (byte == 0x3E) break; // '>'
      final value = _Lexer._hexValue(byte);
      if (value < 0) continue;
      if (high < 0) {
        high = value;
      } else {
        out.add(high * 16 + value);
        high = -1;
      }
    }
    if (high >= 0) out.add(high * 16);
    return Uint8List.fromList(out);
  }

  Uint8List? _ascii85Decode(Uint8List input) {
    final out = <int>[];
    final tuple = <int>[];
    // Данные могут быть обрамлены "<~" ... "~>".
    var index =
        input.length >= 2 && input[0] == 0x3C && input[1] == 0x7E ? 2 : 0;
    while (index < input.length) {
      final byte = input[index++];
      if (_Lexer._isWhitespace(byte)) continue;
      if (byte == 0x7E) break; // '~'
      if (byte == 0x7A && tuple.isEmpty) {
        out.addAll(const <int>[0, 0, 0, 0]); // 'z'
        continue;
      }
      if (byte < 0x21 || byte > 0x75) return null;
      tuple.add(byte - 0x21);
      if (tuple.length == 5) {
        var value = 0;
        for (final digit in tuple) {
          value = value * 85 + digit;
        }
        out.addAll(<int>[
          (value >> 24) & 0xFF,
          (value >> 16) & 0xFF,
          (value >> 8) & 0xFF,
          value & 0xFF,
        ]);
        tuple.clear();
      }
    }
    if (tuple.isNotEmpty) {
      final count = tuple.length;
      while (tuple.length < 5) {
        tuple.add(84); // 'u' - 33
      }
      var value = 0;
      for (final digit in tuple) {
        value = value * 85 + digit;
      }
      final tail = <int>[
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];
      out.addAll(tail.take(count - 1));
    }
    return Uint8List.fromList(out);
  }

  Uint8List? _lzwDecode(Uint8List input, {required int earlyChange}) {
    const clearCode = 256;
    const endOfData = 257;
    final out = <int>[];
    var dictionary = <List<int>>[];
    var nextCode = 258;
    var codeWidth = 9;
    var previous = <int>[];

    void resetDictionary() {
      dictionary = List<List<int>>.generate(256, (i) => <int>[i]);
      dictionary.add(<int>[]); // 256: clear
      dictionary.add(<int>[]); // 257: EOD
      nextCode = 258;
      codeWidth = 9;
      previous = <int>[];
    }

    resetDictionary();
    var bitPosition = 0;
    int? readCode() {
      if (bitPosition + codeWidth > input.length * 8) return null;
      var value = 0;
      for (var i = 0; i < codeWidth; i++) {
        final bitIndex = bitPosition + i;
        final byte = input[bitIndex >> 3];
        final bit = (byte >> (7 - (bitIndex & 7))) & 1;
        value = (value << 1) | bit;
      }
      bitPosition += codeWidth;
      return value;
    }

    while (true) {
      final code = readCode();
      if (code == null) break;
      if (code == clearCode) {
        resetDictionary();
        continue;
      }
      if (code == endOfData) break;
      late List<int> entry;
      if (code < dictionary.length) {
        entry = dictionary[code];
      } else if (code == nextCode && previous.isNotEmpty) {
        entry = <int>[...previous, previous.first];
      } else {
        break; // повреждённый поток
      }
      out.addAll(entry);
      if (previous.isNotEmpty) {
        if (nextCode < 4096) {
          dictionary.add(<int>[...previous, entry.first]);
          nextCode++;
          final threshold = (1 << codeWidth) - (earlyChange != 0 ? 1 : 0);
          if (nextCode >= threshold && codeWidth < 12) codeWidth++;
        }
      }
      previous = entry;
      if (out.length > _maxDecodedStreamBytes) return null;
    }
    return Uint8List.fromList(out);
  }

  Uint8List _runLengthDecode(Uint8List input) {
    final out = <int>[];
    var index = 0;
    while (index < input.length) {
      final length = input[index++];
      if (length == 128) break;
      if (length < 128) {
        final end = math.min(input.length, index + length + 1);
        out.addAll(input.sublist(index, end));
        index = end;
      } else {
        if (index >= input.length) break;
        final byte = input[index++];
        for (var i = 0; i < 257 - length; i++) {
          out.add(byte);
        }
      }
    }
    return Uint8List.fromList(out);
  }

  Uint8List _applyPredictor(
    Uint8List data,
    Map<String, Object?>? parameters,
  ) {
    if (parameters == null || data.isEmpty) return data;
    final predictor = _toInt(deref(parameters['/Predictor'])) ?? 1;
    if (predictor <= 1) return data;
    final colors = math.max(1, _toInt(deref(parameters['/Colors'])) ?? 1);
    final bits = _toInt(deref(parameters['/BitsPerComponent'])) ?? 8;
    final columns = math.max(1, _toInt(deref(parameters['/Columns'])) ?? 1);
    final rowLength = (columns * colors * bits + 7) ~/ 8;
    if (rowLength <= 0) return data;
    var bytesPerPixel = (colors * bits) ~/ 8;
    if (bytesPerPixel < 1) bytesPerPixel = 1;

    if (predictor == 2) {
      // TIFF Predictor 2 (поддержано для 8 бит на компоненту).
      if (bits != 8) return data;
      final out = Uint8List.fromList(data);
      for (var row = 0; row + rowLength <= out.length; row += rowLength) {
        for (var i = bytesPerPixel; i < rowLength; i++) {
          out[row + i] = (out[row + i] + out[row + i - bytesPerPixel]) & 0xFF;
        }
      }
      return out;
    }

    if (predictor < 10) return data;
    final out = BytesBuilder(copy: false);
    var previous = Uint8List(rowLength);
    var position = 0;
    while (position < data.length) {
      final filterType = data[position++];
      final end = math.min(data.length, position + rowLength);
      if (end <= position) break;
      final row = Uint8List.fromList(data.sublist(position, end));
      for (var i = 0; i < row.length; i++) {
        final left = i >= bytesPerPixel ? row[i - bytesPerPixel] : 0;
        final up = i < previous.length ? previous[i] : 0;
        final upLeft = i >= bytesPerPixel && i - bytesPerPixel < previous.length
            ? previous[i - bytesPerPixel]
            : 0;
        switch (filterType) {
          case 1:
            row[i] = (row[i] + left) & 0xFF;
          case 2:
            row[i] = (row[i] + up) & 0xFF;
          case 3:
            row[i] = (row[i] + ((left + up) >> 1)) & 0xFF;
          case 4:
            row[i] = (row[i] + _paeth(left, up, upLeft)) & 0xFF;
        }
      }
      out.add(row);
      previous = row;
      position = end;
    }
    return out.takeBytes();
  }

  int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs();
    final pb = (p - b).abs();
    final pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
  }

  // --- Шрифты ---------------------------------------------------------------

  /// Собирает сведения о шрифте по его словарю.
  _FontInfo buildFont(Map<String, Object?> dict) {
    final subtype = _nameValue(deref(dict['/Subtype']));
    final twoByte = subtype == '/Type0';
    Map<int, String>? toUnicode;
    final toUnicodeStream = deref(dict['/ToUnicode']);
    if (toUnicodeStream is _StreamValue) {
      final data = _decodeStream(toUnicodeStream);
      if (data != null) {
        final parsed = _parseToUnicode(data);
        if (parsed.isNotEmpty) toUnicode = parsed;
      }
    }

    Map<int, String>? differences;
    var encoding = _SimpleEncoding.standard;
    final encodingValue = deref(dict['/Encoding']);
    if (encodingValue is _Name) {
      encoding = _encodingFromName(encodingValue.value);
    } else if (encodingValue is Map<String, Object?>) {
      final base = _nameValue(deref(encodingValue['/BaseEncoding']));
      if (base != null) encoding = _encodingFromName(base);
      differences = _parseDifferences(deref(encodingValue['/Differences']));
    }

    final widths = <int, double>{};
    var defaultWidth = twoByte ? 1000.0 : 500.0;
    if (twoByte) {
      defaultWidth = _toDouble(deref(dict['/DW'])) ?? 1000.0;
      _collectCidWidths(deref(dict['/W']), widths);
    } else {
      _collectSimpleWidths(dict, widths);
      final descriptor = _asDict(deref(dict['/FontDescriptor']));
      if (descriptor != null) {
        defaultWidth =
            _toDouble(deref(descriptor['/MissingWidth'])) ?? defaultWidth;
      }
    }
    return _FontInfo(
      twoByte: twoByte,
      toUnicode: toUnicode,
      differences: differences,
      encoding: encoding,
      widths: widths,
      defaultWidth: defaultWidth,
    );
  }

  _SimpleEncoding _encodingFromName(String name) {
    switch (name) {
      case '/WinAnsiEncoding':
        return _SimpleEncoding.winAnsi;
      case '/MacRomanEncoding':
        return _SimpleEncoding.macRoman;
      default:
        return _SimpleEncoding.standard;
    }
  }

  void _collectSimpleWidths(
    Map<String, Object?> dict,
    Map<int, double> widths,
  ) {
    final firstChar = _toInt(deref(dict['/FirstChar']));
    final array = _asArray(deref(dict['/Widths']));
    if (firstChar == null || array == null) return;
    for (var i = 0; i < array.length; i++) {
      final width = _toDouble(deref(array[i]));
      if (width != null) widths[firstChar + i] = width;
    }
  }

  void _collectCidWidths(Object? value, Map<int, double> widths) {
    final array = _asArray(value);
    if (array == null) return;
    var index = 0;
    while (index < array.length) {
      final first = _toInt(deref(array[index]));
      if (first == null) break;
      if (index + 1 >= array.length) break;
      final second = deref(array[index + 1]);
      if (second is List) {
        for (var i = 0; i < second.length; i++) {
          final width = _toDouble(deref(second[i]));
          if (width != null) widths[first + i] = width;
        }
        index += 2;
        continue;
      }
      final last = _toInt(second);
      final width = index + 2 < array.length
          ? _toDouble(deref(array[index + 2]))
          : null;
      if (last == null || width == null) break;
      for (var code = first; code <= last && code - first < 65536; code++) {
        widths[code] = width;
      }
      index += 3;
    }
  }

  Map<int, String>? _parseDifferences(Object? value) {
    final array = _asArray(value);
    if (array == null) return null;
    final result = <int, String>{};
    var code = 0;
    for (final item in array) {
      final number = _toInt(deref(item));
      if (number != null) {
        code = number;
        continue;
      }
      final name = _nameValue(deref(item));
      if (name == null) continue;
      final unicode = _glyphNameToUnicode(name.substring(1));
      if (unicode != null) result[code] = unicode;
      code++;
    }
    return result.isEmpty ? null : result;
  }

  /// Разбирает CMap `/ToUnicode`.
  Map<int, String> _parseToUnicode(Uint8List data) {
    final result = <int, String>{};
    final lexer = _Lexer(data);
    const parser = _ObjectParser();
    while (true) {
      final token = lexer.nextToken();
      if (token == null) break;
      if (token is! _Keyword) continue;
      switch (token.value) {
        case 'beginbfchar':
          final pending = <_PdfString>[];
          while (true) {
            final item = lexer.nextToken();
            if (item == null) break;
            if (item is _Keyword) {
              if (item.value == 'endbfchar') break;
              continue;
            }
            if (item is _PdfString) {
              pending.add(item);
              if (pending.length == 2) {
                final source = _hexToCode(pending[0].bytes);
                if (source != null) {
                  result[source] = _decodeUtf16Be(pending[1].bytes);
                }
                pending.clear();
              }
            }
          }
        case 'beginbfrange':
          _PdfString? low;
          _PdfString? high;
          while (true) {
            final item = lexer.nextToken();
            if (item == null) break;
            if (item is _Keyword && item.value == 'endbfrange') break;
            if (item is _PdfString) {
              if (low == null) {
                low = item;
              } else if (high == null) {
                high = item;
              } else {
                _addRange(result, low, high, item.bytes, null);
                low = null;
                high = null;
              }
              continue;
            }
            if (item is _Keyword && item.value == '[') {
              final list = <_PdfString>[];
              while (true) {
                final element = lexer.nextToken();
                if (element == null) break;
                if (element is _Keyword && element.value == ']') break;
                if (element is _PdfString) list.add(element);
              }
              if (low != null && high != null) {
                _addRange(result, low, high, null, list);
              }
              low = null;
              high = null;
              continue;
            }
            if (item is _Keyword && item.value == ']') break;
          }
        case 'begincodespacerange':
          while (true) {
            final item = lexer.nextToken();
            if (item == null) break;
            if (item is _Keyword && item.value == 'endcodespacerange') break;
          }
        default:
          parser.fromToken(lexer, token);
      }
    }
    return result;
  }

  void _addRange(
    Map<int, String> result,
    _PdfString low,
    _PdfString high,
    Uint8List? destination,
    List<_PdfString>? list,
  ) {
    final start = _hexToCode(low.bytes);
    final end = _hexToCode(high.bytes);
    if (start == null || end == null || end < start) return;
    if (list != null) {
      for (var i = 0; i < list.length && start + i <= end; i++) {
        result[start + i] = _decodeUtf16Be(list[i].bytes);
      }
      return;
    }
    if (destination == null) return;
    final base = _decodeUtf16Be(destination);
    if (base.isEmpty) return;
    final baseCode = base.codeUnitAt(0);
    for (var code = start; code <= end && code - start < 65536; code++) {
      result[code] = String.fromCharCode(baseCode + (code - start));
    }
  }

  int? _hexToCode(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    if (bytes.length == 1) return bytes[0];
    return (bytes[0] << 8) | bytes[1];
  }

  String _decodeUtf16Be(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    if (bytes.length == 1) return String.fromCharCode(bytes[0]);
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  // --- Страницы -------------------------------------------------------------

  Map<String, Object?>? _resolveCatalog() {
    final root = _asDict(deref(_trailer?['/Root']));
    if (root != null) return root;
    if (_findCatalogByScan() case final found?) return found;
    return null;
  }

  Map<String, Object?>? _findCatalogByScan() {
    final numbers = <int>{..._offsets.keys, ..._scanOffsets.keys}.toList()
      ..sort();
    var examined = 0;
    for (final number in numbers) {
      if (examined++ > 5000) break;
      if (_freeObjects.contains(number)) continue;
      final value = _resolveObject(number);
      if (value is _StreamValue) continue;
      final dict = _asDict(value);
      if (dict == null) continue;
      if (_nameValue(deref(dict['/Type'])) == '/Catalog') return dict;
    }
    return null;
  }

  List<Map<String, Object?>> _collectPages(Map<String, Object?> root) {
    final pages = <Map<String, Object?>>[];
    final visited = <Object>{};
    void walk(
      Object? node,
      Map<String, Object?>? resources,
      List<double>? mediaBox,
      int? rotate,
      int depth,
    ) {
      if (pages.length >= _maxPages || depth > _maxPageTreeDepth) return;
      final dict = _asDict(deref(node));
      if (dict == null) return;
      if (!visited.add(dict)) return;
      final localResources =
          _asDict(deref(dict['/Resources'])) ?? resources;
      final localBox = _numberList(deref(dict['/MediaBox'])) ?? mediaBox;
      final localRotate = _toInt(deref(dict['/Rotate'])) ?? rotate;
      final type = _nameValue(deref(dict['/Type']));
      final kids = _asArray(deref(dict['/Kids']));
      if (type == '/Pages' || (kids != null && type != '/Page')) {
        if (kids != null) {
          for (final kid in kids) {
            walk(kid, localResources, localBox, localRotate, depth + 1);
          }
        }
        return;
      }
      if (type == '/Page' || (type == null && dict.containsKey('/Contents'))) {
        pages.add(dict);
      }
    }

    walk(root['/Pages'], null, null, null, 0);
    return pages;
  }

  List<double>? _numberList(Object? value) {
    final array = _asArray(value);
    if (array == null || array.length < 4) return null;
    final numbers = <double>[];
    for (var i = 0; i < 4; i++) {
      final number = _toDouble(deref(array[i]));
      if (number == null) return null;
      numbers.add(number);
    }
    return numbers;
  }

  _RawPage _parsePage(Map<String, Object?> dict, int pageNumber) {
    final box = _numberList(deref(dict['/MediaBox'])) ?? const <double>[0, 0, 612, 792];
    final x0 = math.min(box[0], box[2]);
    final y0 = math.min(box[1], box[3]);
    final width = (box[2] - box[0]).abs();
    final height = (box[3] - box[1]).abs();
    var rotate = _toInt(deref(dict['/Rotate'])) ?? 0;
    rotate = ((rotate % 360) + 360) % 360;
    if (rotate != 90 && rotate != 180 && rotate != 270) rotate = 0;
    final transform = _PageTransform(
      x0: x0,
      y0: y0,
      width: width == 0 ? 612 : width,
      height: height == 0 ? 792 : height,
      rotate: rotate,
    );
    final resources = _asDict(deref(dict['/Resources']));
    final content = _pageContent(dict);
    if (content.isEmpty) {
      return _RawPage(
        pageNumber: pageNumber,
        transform: transform,
        fragments: const <_RawFragment>[],
      );
    }
    final parser = _ContentParser(
      file: this,
      content: content,
      resources: resources,
    );
    return _RawPage(
      pageNumber: pageNumber,
      transform: transform,
      fragments: parser.parse(),
    );
  }

  Uint8List _pageContent(Map<String, Object?> dict) {
    final builder = BytesBuilder(copy: false);
    void addStream(Object? value) {
      final stream = deref(value);
      if (stream is! _StreamValue) return;
      final data = _decodeStream(stream);
      if (data == null) return;
      if (builder.isNotEmpty) builder.addByte(0x0A);
      builder.add(data);
    }

    final contents = deref(dict['/Contents']);
    if (contents is List) {
      for (final item in contents) {
        addStream(item);
      }
    } else {
      addStream(contents);
    }
    return builder.takeBytes();
  }

  // --- Сборка строк ---------------------------------------------------------

  PdfPageText _buildPageText(_RawPage rawPage) {
    final placed = <_PlacedFragment>[];
    final transform = rawPage.transform;
    for (final raw in rawPage.fragments) {
      final text = raw.font.textOf(raw.codes);
      if (text.isEmpty) continue;
      placed.add(_PlacedFragment(_placeFragment(raw, transform, text), raw.baseline));
    }
    return PdfPageText(
      pageNumber: rawPage.pageNumber,
      width: transform.displayWidth(),
      height: transform.displayHeight(),
      lines: _assembleLines(placed),
    );
  }

  PdfTextFragment _placeFragment(
    _RawFragment raw,
    _PageTransform transform,
    String text,
  ) {
    final size = raw.fontSize <= 0 ? 12.0 : raw.fontSize;
    final startX = transform.displayX(raw.startX, raw.startY);
    final startTop = transform.displayTop(raw.startX, raw.startY);
    final endX = transform.displayX(raw.endX, raw.endY);
    final endTop = transform.displayTop(raw.endX, raw.endY);
    final estimated = math.max(0.5 * size, 0.5);
    final rotated = transform.rotate == 90 || transform.rotate == 270;

    double left = math.min(startX, endX);
    double right = math.max(startX, endX);
    double top = math.min(startTop, endTop);
    double bottom = math.max(startTop, endTop);

    if (!rotated) {
      if (right - left < 0.01) right = left + estimated;
      top = startTop - 0.8 * size;
      bottom = startTop + 0.2 * size;
    } else {
      if (right - left < 0.01) {
        right = left + math.max(estimated, bottom - top);
      }
      if (bottom - top < 0.01) {
        top = startTop - 0.8 * size;
        bottom = startTop + 0.2 * size;
      }
    }
    return PdfTextFragment(
      text: text,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      fontSize: size,
    );
  }

  List<PdfTextLine> _assembleLines(List<_PlacedFragment> placed) {
    if (placed.isEmpty) return const <PdfTextLine>[];
    final sorted = List<_PlacedFragment>.of(placed)
      ..sort((a, b) => b.baseline.compareTo(a.baseline));
    final groups = <List<_PlacedFragment>>[];
    for (final item in sorted) {
      if (groups.isEmpty) {
        groups.add(<_PlacedFragment>[item]);
        continue;
      }
      final group = groups.last;
      final reference = group.first.baseline;
      final tolerance =
          0.5 *
          math.max(group.first.fragment.fontSize, item.fragment.fontSize);
      if ((reference - item.baseline).abs() <= tolerance) {
        group.add(item);
      } else {
        groups.add(<_PlacedFragment>[item]);
      }
    }
    final lines = <PdfTextLine>[];
    for (final group in groups) {
      group.sort((a, b) => a.fragment.left.compareTo(b.fragment.left));
      lines.add(
        PdfTextLine(
          fragments: group.map((item) => item.fragment).toList(growable: false),
        ),
      );
    }
    lines.sort((a, b) => a.top.compareTo(b.top));
    return lines;
  }
}
