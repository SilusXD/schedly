import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Фильтр сжатия потока содержимого, применяемый генераторами фикстур.
enum PdfContentFilter {
  /// Без сжатия (поток хранится как есть).
  none,

  /// `/Filter /FlateDecode`.
  flate,

  /// `/Filter /ASCIIHexDecode`.
  asciiHex,

  /// `/Filter /ASCII85Decode`.
  ascii85,

  /// `/Filter /LZWDecode`.
  lzw,
}

// ---------------------------------------------------------------------------
// Кодирование текста
// ---------------------------------------------------------------------------

const String _cp1251High =
    '\u0402\u0403\u201A\u0453\u201E\u2026\u2020\u2021'
    '\u20AC\u2030\u0409\u2039\u040A\u040C\u040B\u040F'
    '\u0452\u2018\u2019\u201C\u201D\u2022\u2013\u2014'
    '\u0000\u2122\u0459\u203A\u045A\u045C\u045B\u045F'
    '\u00A0\u040E\u045E\u0408\u00A4\u0490\u00A6\u00A7'
    '\u0401\u00A9\u0404\u00AB\u00AC\u00AD\u00AE\u0407'
    '\u00B0\u00B1\u0406\u0456\u0491\u00B5\u00B6\u00B7'
    '\u0451\u2116\u0454\u00BB\u0458\u0405\u0455\u0457';

/// Переводит строку UTF-16 (Dart `String`) в байты CP1251.
///
/// Кириллица А..я занимает 0xC0..0xFF, остальные символы берутся из таблицы
/// CP1251 (тире, кавычки, «ё» и т.п.). Неизвестные символы заменяются на '?'.
Uint8List cp1251Encode(String text) {
  final bytes = <int>[];
  for (final rune in text.runes) {
    if (rune < 0x80) {
      bytes.add(rune);
      continue;
    }
    if (rune >= 0x0410 && rune <= 0x044F) {
      bytes.add(rune - 0x0410 + 0xC0);
      continue;
    }
    final index = _cp1251High.indexOf(String.fromCharCode(rune));
    if (index >= 0) {
      bytes.add(0x80 + index);
      continue;
    }
    bytes.add(0x3F); // '?'
  }
  return Uint8List.fromList(bytes);
}

/// Кодирует байты как литеральную строку PDF (непечатаемые — восьмеричными
/// escape-последовательностями, чтобы файл оставался ASCII).
String pdfLiteralString(List<int> bytes) {
  final buffer = StringBuffer('(');
  for (final byte in bytes) {
    switch (byte) {
      case 0x28:
        buffer.write(r'\(');
      case 0x29:
        buffer.write(r'\)');
      case 0x5C:
        buffer.write(r'\\');
      default:
        if (byte < 0x20 || byte > 0x7E) {
          buffer.write('\\${byte.toRadixString(8).padLeft(3, '0')}');
        } else {
          buffer.writeCharCode(byte);
        }
    }
  }
  buffer.write(')');
  return buffer.toString();
}

/// Кодирует [codes] как hex-строку PDF (используется для Identity-H).
String pdfHexString(List<int> codes) {
  final buffer = StringBuffer('<');
  for (final code in codes) {
    buffer.write(_hex4(code));
  }
  buffer.write('>');
  return buffer.toString();
}

String _hex4(int value) => value.toRadixString(16).padLeft(4, '0');

// ---------------------------------------------------------------------------
// Публичные генераторы
// ---------------------------------------------------------------------------

/// Минимальный PDF 1.4: одна страница, шрифт Helvetica с `/WinAnsiEncoding`,
/// строки выводятся оператором `Tj` с переводами строки через `T*`.
///
/// Кириллица кодируется байтами CP1251.
Uint8List buildSimplePdf({
  required List<String> lines,
  PdfContentFilter filter = PdfContentFilter.none,
  bool brokenXref = false,
  bool encrypted = false,
  bool splitContents = false,
  double fontSize = 12,
}) {
  final writer = _PdfWriter();
  final content = _simpleContent(lines, fontSize: fontSize);
  final encoded = _encodeContent(content, filter);
  writer.addObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
  writer.addObject(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  if (splitContents) {
    // Поток содержимого из двух частей: проверяется обработка массива
    // /Contents. Разрез делается по переводу строки, чтобы не разорвать токен.
    final firstHalf = _splitAtNewline(content);
    writer.addObject(
      3,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 5 0 R >> >> /Contents [4 0 R 6 0 R] >>',
    );
    writer.addStream(
      4,
      _filterDictionary(filter),
      _encodeContent(firstHalf, filter),
    );
    writer.addObject(5, _helveticaFont);
    writer.addStream(
      6,
      _filterDictionary(filter),
      _encodeContent(content.substring(firstHalf.length), filter),
    );
    return writer.finishClassic(
      root: 1,
      size: 7,
      brokenXref: brokenXref,
      encrypted: encrypted,
    );
  }
  writer.addObject(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
    '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
  );
  writer.addStream(4, _filterDictionary(filter), encoded);
  writer.addObject(5, _helveticaFont);
  return writer.finishClassic(
    root: 1,
    size: 6,
    brokenXref: brokenXref,
    encrypted: encrypted,
  );
}

/// PDF с содержимым, сжатым `/Filter /FlateDecode`.
Uint8List buildFlateCompressedPdf({required List<String> lines}) {
  return buildSimplePdf(lines: lines, filter: PdfContentFilter.flate);
}

/// PDF с составным шрифтом Type0/Identity-H и CMap `/ToUnicode`.
///
/// Коды глифов не совпадают с Unicode (0x41, 0x42, ...), поэтому корректный
/// текст можно получить только через `/ToUnicode`.
Uint8List buildCidFontPdf({
  required List<String> lines,
  bool ranges = false,
}) {
  final runes = <int>{};
  for (final line in lines) {
    runes.addAll(line.runes);
  }
  final ordered = runes.toList()..sort();
  final codeOf = <int, int>{};
  for (var i = 0; i < ordered.length; i++) {
    codeOf[ordered[i]] = 0x41 + i;
  }

  final content = StringBuffer()
    ..write('BT\n')
    ..write('/F1 14 Tf\n')
    ..write('16 TL\n')
    ..write('72 700 Td\n');
  for (var i = 0; i < lines.length; i++) {
    if (i > 0) content.write('T*\n');
    final codes = <int>[
      for (final rune in lines[i].runes)
        codeOf[rune] ?? 0x3F,
    ];
    content
      ..write(pdfHexString(codes))
      ..write(' Tj\n');
  }
  content.write('ET\n');

  final cmap = StringBuffer()
    ..write('/CIDInit /ProcSet findresource begin\n')
    ..write('12 dict begin\n')
    ..write('begincmap\n')
    ..write('/CMapName /Superset-Identity-H def\n')
    ..write('/CMapType 2 def\n')
    ..write('1 begincodespacerange\n')
    ..write('<0000> <FFFF>\n')
    ..write('endcodespacerange\n');
  if (ranges) {
    final contiguous = <bool>[
      for (var i = 0; i < ordered.length; i++) ordered[i] == ordered.first + i,
    ].every((value) => value);
    if (!contiguous) {
      throw StateError(
        'Фикстура с beginbfrange требует непрерывного диапазона символов',
      );
    }
    cmap
      ..write('1 beginbfrange\n')
      ..write('<${_hex4(0x41)}> ')
      ..write('<${_hex4(0x41 + ordered.length - 1)}> ')
      ..write('<${_hex4(ordered.first)}>\n')
      ..write('endbfrange\n');
  } else {
    cmap.write('${ordered.length} beginbfchar\n');
    for (final rune in ordered) {
      cmap
        ..write('<${_hex4(codeOf[rune]!)}> ')
        ..write('<${_hex4(rune)}>\n');
    }
    cmap.write('endbfchar\n');
  }
  cmap
    ..write('endcmap\n')
    ..write('CMapName currentdict /CMap defineresource pop\n')
    ..write('end\n')
    ..write('end\n');

  final writer = _PdfWriter();
  writer.addObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
  writer.addObject(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  writer.addObject(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
    '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
  );
  writer.addStream(4, '', asciiBytes(content.toString()));
  writer.addObject(
    5,
    '<< /Type /Font /Subtype /Type0 /BaseFont /Schedly-Test-CID '
    '/Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>',
  );
  writer.addObject(
    6,
    '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Schedly-Test-CID '
    '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) '
    '/Supplement 0 >> /FontDescriptor 8 0 R /DW 1000 >>',
  );
  writer.addStream(7, '', asciiBytes(cmap.toString()));
  writer.addObject(
    8,
    '<< /Type /FontDescriptor /FontName /Schedly-Test-CID /Flags 4 '
    '/FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -200 '
    '/CapHeight 700 /StemV 80 >>',
  );
  return writer.finishClassic(root: 1, size: 9);
}

/// PDF с текстом, размещённым по заданным X-координатам (эмуляция таблицы).
///
/// Каждая ячейка выводится своим `Tm`, поэтому левый край фрагментов совпадает
/// с [columnX].
Uint8List buildTablePdf({
  required List<List<String>> rows,
  required List<double> columnX,
  double rowHeight = 20,
  double firstRowY = 700,
  double fontSize = 12,
}) {
  final content = StringBuffer()
    ..write('BT\n')
    ..write('/F1 ${_num(fontSize)} Tf\n');
  final x = <double>[...columnX]..sort();
  for (var row = 0; row < rows.length; row++) {
    final y = firstRowY - row * rowHeight;
    for (var column = 0; column < rows[row].length; column++) {
      if (column >= x.length) break;
      content
        ..write('1 0 0 1 ${_num(x[column])} ${_num(y)} Tm\n')
        ..write('${pdfLiteralString(cp1251Encode(rows[row][column]))} Tj\n');
    }
  }
  content.write('ET\n');

  final writer = _PdfWriter();
  writer.addObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
  writer.addObject(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  writer.addObject(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
    '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
  );
  writer.addStream(4, '', asciiBytes(content.toString()));
  writer.addObject(5, _helveticaFont);
  return writer.finishClassic(root: 1, size: 6);
}

/// PDF 1.5, в котором объект шрифта упакован в объектный поток `/Type /ObjStm`.
///
/// При `xrefStream: true` используется xref-поток с типом записи 2 и
/// предиктором PNG Up; при `xrefStream: false` — обычная таблица xref, в
/// которой объекта из ObjStm вообще нет (проверяется резервная индексация
/// объектных потоков).
Uint8List buildObjStmPdf({
  required List<String> lines,
  bool xrefStream = true,
}) {
  final writer = _PdfWriter();
  final content = _simpleContent(lines);
  writer.addObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
  writer.addObject(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  writer.addObject(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
    '/Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>',
  );
  writer.addStream(4, '', asciiBytes(content));

  // Объект 6 живёт внутри объектного потока 7.
  final header = '6 0 ';
  final objStmData = asciiBytes('$header$_helveticaFont\n');
  writer.addStream(7, '/Type /ObjStm /N 1 /First ${header.length}', objStmData);

  if (!xrefStream) {
    return writer.finishClassic(root: 1, size: 8);
  }

  // xref-поток (объект 9) должен быть последним: его собственное смещение уже
  // известно, потому что все остальные объекты записаны.
  const size = 10;
  final xrefOffset = writer.length;
  final rows = <int>[];
  void addRow(int type, int field2, int field3) {
    rows
      ..add(type)
      ..add((field2 >> 24) & 0xFF)
      ..add((field2 >> 16) & 0xFF)
      ..add((field2 >> 8) & 0xFF)
      ..add(field2 & 0xFF)
      ..add((field3 >> 8) & 0xFF)
      ..add(field3 & 0xFF);
  }

  for (var number = 0; number < size; number++) {
    if (number == 0) {
      addRow(0, 0, 65535);
      continue;
    }
    if (number == 6) {
      addRow(2, 7, 0); // внутри объектного потока 7, индекс 0
      continue;
    }
    if (number == 9) {
      addRow(1, xrefOffset, 0);
      continue;
    }
    final offset = writer.objectOffset(number);
    if (offset == null) {
      addRow(0, 0, 0);
    } else {
      addRow(1, offset, 0);
    }
  }
  final predicted = _pngUpEncode(rows, 7);
  final compressed = ZLibEncoder().convert(predicted);
  writer.addStream(
    9,
    '/Type /XRef /Size $size /W [1 4 2] /Index [0 $size] /Root 1 0 R '
    '/Filter /FlateDecode '
    '/DecodeParms << /Predictor 12 /Columns 7 >>',
    compressed,
  );
  writer
    ..ascii('startxref\n$xrefOffset\n')
    ..ascii('%%EOF\n');
  return writer.takeBytes();
}

/// PDF с корректной структурой, но без страниц (`/Kids []`).
Uint8List buildNoPagesPdf() {
  final writer = _PdfWriter();
  writer.addObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
  writer.addObject(2, '<< /Type /Pages /Kids [] /Count 0 >>');
  return writer.finishClassic(root: 1, size: 3);
}

/// Байты, не являющиеся PDF (для проверки обработки ошибок).
Uint8List buildGarbageBytes() {
  return Uint8List.fromList(
    List<int>.generate(512, (i) => (i * 37 + 11) & 0xFF),
  );
}

// ---------------------------------------------------------------------------
// Сборка объектов
// ---------------------------------------------------------------------------

const String _helveticaFont =
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
    '/Encoding /WinAnsiEncoding /FirstChar 32 '
    '/Widths [278 278 355 556 556 889 667 191 333 333 389 584 278 333 278 '
    '278 556 556 556 556 556 556 556 556 556 556 278 278 584 584 584 556 '
    '1015 667 667 722 722 667 611 778 722 278 500 667 556 833 722 778 667 '
    '778 722 667 611 722 667 944 667 667 611] >>';

String _num(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toString();

/// Возвращает первую половину [content], оканчивающуюся переводом строки.
String _splitAtNewline(String content) {
  final middle = content.length ~/ 2;
  final boundary = content.indexOf('\n', middle);
  return boundary < 0 ? content : content.substring(0, boundary + 1);
}

/// Байты строки (фикстуры строятся только из ASCII).
Uint8List asciiBytes(String text) => Uint8List.fromList(latin1.encode(text));

String _simpleContent(
  List<String> lines, {
  double fontSize = 12,
  double startX = 72,
  double startY = 700,
}) {
  final buffer = StringBuffer()
    ..write('BT\n')
    ..write('/F1 ${_num(fontSize)} Tf\n')
    ..write('${_num(fontSize * 1.35)} TL\n')
    ..write('${_num(startX)} ${_num(startY)} Td\n');
  for (var i = 0; i < lines.length; i++) {
    if (i > 0) buffer.write('T*\n');
    buffer
      ..write(pdfLiteralString(cp1251Encode(lines[i])))
      ..write(' Tj\n');
  }
  buffer.write('ET\n');
  return buffer.toString();
}

String _filterDictionary(PdfContentFilter filter) {
  switch (filter) {
    case PdfContentFilter.none:
      return '';
    case PdfContentFilter.flate:
      return '/Filter /FlateDecode';
    case PdfContentFilter.asciiHex:
      return '/Filter /ASCIIHexDecode';
    case PdfContentFilter.ascii85:
      return '/Filter /ASCII85Decode';
    case PdfContentFilter.lzw:
      return '/Filter /LZWDecode';
  }
}

Uint8List _encodeContent(String content, PdfContentFilter filter) {
  final raw = asciiBytes(content);
  switch (filter) {
    case PdfContentFilter.none:
      return raw;
    case PdfContentFilter.flate:
      return Uint8List.fromList(ZLibEncoder().convert(raw));
    case PdfContentFilter.asciiHex:
      final buffer = StringBuffer();
      for (final byte in raw) {
        buffer.write(byte.toRadixString(16).padLeft(2, '0'));
      }
      buffer.write('>');
      return asciiBytes(buffer.toString());
    case PdfContentFilter.ascii85:
      return asciiBytes(_ascii85Encode(raw));
    case PdfContentFilter.lzw:
      return Uint8List.fromList(_lzwEncode(raw));
  }
}

String _ascii85Encode(List<int> data) {
  final buffer = StringBuffer('<~');
  var index = 0;
  while (index < data.length) {
    final remaining = data.length - index;
    final chunk = <int>[
      for (var i = 0; i < 4; i++) i < remaining ? data[index + i] : 0,
    ];
    var value =
        (chunk[0] << 24) | (chunk[1] << 16) | (chunk[2] << 8) | chunk[3];
    final digits = <int>[0, 0, 0, 0, 0];
    for (var i = 4; i >= 0; i--) {
      digits[i] = value % 85;
      value ~/= 85;
    }
    final count = remaining >= 4 ? 5 : remaining + 1;
    for (var i = 0; i < count; i++) {
      buffer.writeCharCode(digits[i] + 33);
    }
    index += 4;
  }
  buffer.write('~>');
  return buffer.toString();
}

/// Кодирование PNG Up-предиктором (для xref-потоков), по [columns] байт в строке.
List<int> _pngUpEncode(List<int> data, int columns) {
  final out = <int>[];
  var previous = List<int>.filled(columns, 0);
  for (var i = 0; i < data.length; i += columns) {
    final row = data.sublist(i, math.min(i + columns, data.length));
    out.add(2); // PNG Up
    for (var j = 0; j < row.length; j++) {
      out.add((row[j] - previous[j]) & 0xFF);
    }
    previous = row;
  }
  return out;
}

// --- LZW -------------------------------------------------------------------

class _BitWriter {
  final List<int> _bytes = <int>[];
  int _current = 0;
  int _bits = 0;

  void write(int code, int width) {
    for (var i = width - 1; i >= 0; i--) {
      _current = (_current << 1) | ((code >> i) & 1);
      _bits++;
      if (_bits == 8) {
        _bytes.add(_current & 0xFF);
        _current = 0;
        _bits = 0;
      }
    }
  }

  List<int> finish() {
    if (_bits > 0) {
      _bytes.add((_current << (8 - _bits)) & 0xFF);
    }
    return _bytes;
  }
}

/// LZW-кодирование в варианте PDF (MSB-first, clear=256, EOD=257,
/// раннее изменение ширины кода `/EarlyChange 1`).
List<int> _lzwEncode(List<int> input) {
  const clearCode = 256;
  const endOfData = 257;
  const earlyChange = 1;
  final writer = _BitWriter();
  var dictionary = <String, int>{};
  var width = 9;
  var nextEntry = 258;
  var codesWritten = 0;

  void reset() {
    dictionary = <String, int>{};
    for (var i = 0; i < 256; i++) {
      dictionary['$i'] = i;
    }
    width = 9;
    nextEntry = 258;
    codesWritten = 0;
  }

  /// Обновляет ширину кода в «декодерной» конвенции: декодер добавляет запись
  /// в словарь только начиная со второго кода, поэтому его счётчик на единицу
  /// меньше счётчика кодера.
  void afterCode() {
    codesWritten++;
    final decoderCounter = 258 + (codesWritten - 1);
    while (width < 12 && decoderCounter >= (1 << width) - earlyChange) {
      width++;
    }
  }

  reset();
  writer.write(clearCode, width);
  var current = <int>[];
  for (final byte in input) {
    final candidate = <int>[...current, byte];
    final key = candidate.join(',');
    if (dictionary.containsKey(key)) {
      current = candidate;
      continue;
    }
    writer.write(dictionary[current.join(',')]!, width);
    afterCode();
    dictionary[key] = nextEntry++;
    current = <int>[byte];
    if (nextEntry >= 4095) {
      writer.write(clearCode, width);
      reset();
    }
  }
  if (current.isNotEmpty) {
    writer.write(dictionary[current.join(',')]!, width);
    afterCode();
  }
  writer.write(endOfData, width);
  return writer.finish();
}

// --- Запись файла -----------------------------------------------------------

class _PdfWriter {
  _PdfWriter() {
    // Заголовок + бинарный комментарий (признак «бинарного» файла для
    // транспорта, как того требует спецификация).
    ascii('%PDF-1.4\n%\u00E2\u00E3\u00CF\u00D3\n');
  }

  final BytesBuilder _out = BytesBuilder(copy: false);
  final Map<int, int> _offsets = <int, int>{};

  int get length => _out.length;

  int? objectOffset(int number) => _offsets[number];

  void ascii(String text) => _out.add(latin1.encode(text));

  void addObject(int number, String body) {
    _offsets[number] = _out.length;
    ascii('$number 0 obj\n$body\nendobj\n');
  }

  void addStream(int number, String extraDictionary, List<int> data) {
    _offsets[number] = _out.length;
    final dictionary = StringBuffer('<< /Length ${data.length}');
    if (extraDictionary.isNotEmpty) dictionary.write(' $extraDictionary');
    dictionary.write(' >>');
    ascii('$number 0 obj\n$dictionary\nstream\n');
    _out.add(data);
    ascii('\nendstream\nendobj\n');
  }

  /// Завершает файл классической таблицей xref и trailer.
  ///
  /// При `brokenXref: true` таблица не пишется вовсе, а `startxref` указывает
  /// на начало файла: читатель обязан найти объекты полным сканом.
  Uint8List finishClassic({
    required int root,
    required int size,
    bool brokenXref = false,
    bool encrypted = false,
  }) {
    final buffer = StringBuffer();
    if (brokenXref) {
      buffer.write('startxref\n0\n%%EOF\n');
      _out.add(latin1.encode(buffer.toString()));
      return _out.takeBytes();
    }
    final xrefOffset = _out.length;
    buffer.write('xref\n0 $size\n');
    buffer.write('0000000000 65535 f \n');
    for (var number = 1; number < size; number++) {
      final offset = _offsets[number];
      if (offset == null) {
        buffer.write('0000000000 00000 f \n');
      } else {
        buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
      }
    }
    buffer.write('trailer\n<< /Size $size /Root $root 0 R');
    if (encrypted) buffer.write(' /Encrypt << /Filter /Standard >>');
    buffer.write(' >>\nstartxref\n$xrefOffset\n%%EOF\n');
    _out.add(latin1.encode(buffer.toString()));
    return _out.takeBytes();
  }

  Uint8List takeBytes() => _out.takeBytes();
}
