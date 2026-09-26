import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:schedly/data/pdf/pdf_text.dart';
import 'package:schedly/data/pdf/pdf_text_extractor.dart';
import 'package:schedly/data/pdf/pure_dart_pdf_text_extractor.dart';

import 'pdf_fixtures.dart';

void main() {
  const extractor = PureDartPdfTextExtractor();

  group('метаданные', () {
    test('имя реализации', () {
      expect(extractor.name, 'pure-dart');
      expect(extractor, isA<PdfTextExtractor>());
    });

    test('сообщение исключения содержит причину', () {
      final exception = PdfTextExtractionException(
        'сломанный файл',
        cause: StateError('boom'),
      );
      expect(exception.toString(), contains('сломанный файл'));
      expect(exception.toString(), contains('boom'));
      expect(PdfTextExtractionException('x').toString(), 'PdfTextExtractionException: x');
    });
  });

  group('простой текст', () {
    test('извлекает строки и координаты одной страницы', () async {
      final bytes = buildSimplePdf(
        lines: <String>['Schedule 2025', 'Monday 08:30'],
      );
      final document = await extractor.extract(bytes);

      expect(document.pages, hasLength(1));
      final page = document.pages.single;
      expect(page.pageNumber, 1);
      expect(page.width, closeTo(612, 0.001));
      expect(page.height, closeTo(792, 0.001));
      expect(page.text, 'Schedule 2025\nMonday 08:30');
      expect(document.isEmpty, isFalse);
    });

    test('строки упорядочены сверху вниз, левый край точен', () async {
      final bytes = buildSimplePdf(
        lines: <String>['Первая', 'Вторая', 'Третья'],
      );
      final page = (await extractor.extract(bytes)).pages.single;

      expect(page.lines, hasLength(3));
      final tops = page.lines.map((line) => line.top).toList();
      for (var i = 1; i < tops.length; i++) {
        expect(
          tops[i],
          greaterThan(tops[i - 1]),
          reason: 'строки должны идти сверху вниз',
        );
      }
      expect(page.lines.first.fragments.first.left, closeTo(72, 0.5));
      expect(page.lines.first.fragments.first.top, closeTo(792 - 700 - 9.6, 0.5));
      expect(page.lines.first.fragments.first.fontSize, closeTo(12, 0.001));
      expect(page.lines.first.fragments.first.width, greaterThan(0));
    });

    test('порядок строк сохраняется при большом количестве строк', () async {
      final lines = List<String>.generate(40, (i) => 'Строка номер $i');
      final page = (await extractor.extract(buildSimplePdf(lines: lines)))
          .pages
          .single;
      expect(page.lines, hasLength(lines.length));
      expect(page.text, lines.join('\n'));
    });
  });

  group('кириллица', () {
    test('WinAnsi-шрифт с байтами CP1251', () async {
      final lines = <String>[
        'Расписание занятий',
        'Понедельник 08:30 — Математика',
      ];
      final page = (await extractor.extract(buildSimplePdf(lines: lines)))
          .pages
          .single;
      expect(page.text, lines.join('\n'));
    });

    test('CP1251 в коротких строках и отдельных символах', () async {
      // Одиночные буквы и короткие слова: раньше на них не срабатывала
      // эвристика и текст выходил как 'Ðàç'.
      final lines = <String>['Р', 'Раз', 'Ёё', '№ 5', '«Ёлка», тест'];
      final page = (await extractor.extract(buildSimplePdf(lines: lines)))
          .pages
          .single;
      expect(page.text, lines.join('\n'));
      expect(page.text, isNot(contains('Ð')));
    });

    test('Type0/Identity-H через /ToUnicode', () async {
      final lines = <String>[
        'Расписание группы ИС-21',
        'Физика, аудитория 305',
      ];
      final document = await extractor.extract(buildCidFontPdf(lines: lines));
      expect(document.pages.single.text, lines.join('\n'));
    });

    test('ToUnicode с bfrange', () async {
      final bytes = buildCidFontPdf(
        lines: <String>['абвгд'],
        ranges: true,
      );
      expect(latin1.decode(bytes), contains('beginbfrange'));
      final page = (await extractor.extract(bytes)).pages.single;
      expect(page.text, 'абвгд');
    });
  });

  group('фильтры потока содержимого', () {
    final lines = <String>['Первая строка', 'Вторая строка'];

    test('FlateDecode', () async {
      final page = (await extractor.extract(buildFlateCompressedPdf(lines: lines)))
          .pages
          .single;
      expect(page.text, lines.join('\n'));
    });

    test('ASCIIHexDecode', () async {
      final bytes = buildSimplePdf(
        lines: lines,
        filter: PdfContentFilter.asciiHex,
      );
      expect((await extractor.extract(bytes)).pages.single.text, lines.join('\n'));
    });

    test('ASCII85Decode', () async {
      final bytes = buildSimplePdf(
        lines: lines,
        filter: PdfContentFilter.ascii85,
      );
      expect((await extractor.extract(bytes)).pages.single.text, lines.join('\n'));
    });

    test('LZWDecode (включая рост ширины кода)', () async {
      final many = List<String>.generate(
        120,
        (i) => 'Строка ${i.toString().padLeft(3, '0')} альфа бета гамма дельта',
      );
      final bytes = buildSimplePdf(lines: many, filter: PdfContentFilter.lzw);
      final page = (await extractor.extract(bytes)).pages.single;
      expect(page.lines, hasLength(many.length));
      expect(page.lines.first.text, many.first);
      expect(page.lines.last.text, many.last);
    });
  });

  group('структура файла', () {
    test('резервный полный скан при отсутствующем xref', () async {
      final bytes = buildSimplePdf(
        lines: <String>['Без xref', 'Всё равно читается'],
        brokenXref: true,
      );
      // В файле действительно нет таблицы xref.
      expect(latin1.decode(bytes), isNot(contains('trailer')));
      final page = (await extractor.extract(bytes)).pages.single;
      expect(page.text, 'Без xref\nВсё равно читается');
    });

    test('объектный поток (/Type /ObjStm) с xref-потоком и предиктором', () async {
      final bytes = buildObjStmPdf(
        lines: <String>['Объектный поток', 'Читается корректно'],
      );
      final page = (await extractor.extract(bytes)).pages.single;
      expect(page.text, 'Объектный поток\nЧитается корректно');
    });

    test('объектный поток при классическом xref без записи об объекте', () async {
      final bytes = buildObjStmPdf(
        lines: <String>['ObjStm', 'Без записи в xref'],
        xrefStream: false,
      );
      final page = (await extractor.extract(bytes)).pages.single;
      expect(page.text, 'ObjStm\nБез записи в xref');
    });

    test('поток содержимого из массива потоков', () async {
      final bytes = buildSimplePdf(
        lines: const <String>['Первый поток', 'Второй поток'],
        splitContents: true,
      );
      expect(latin1.decode(bytes), contains('/Contents [4 0 R 6 0 R]'));
      final page = (await extractor.extract(bytes)).pages.single;
      expect(page.text, 'Первый поток\nВторой поток');
    });
  });

  group('таблица: колонки по left', () {
    test('левый край совпадает с заданными X-координатами', () async {
      final rows = <List<String>>[
        <String>['ИС-21', 'Математика', '08:30'],
        <String>['ИС-22', 'Физика', '10:10'],
        <String>['ИС-23', 'Информатика', '12:40'],
      ];
      final columnX = <double>[72, 200, 400];
      final page = (await extractor.extract(
        buildTablePdf(rows: rows, columnX: columnX),
      )).pages.single;

      expect(page.lines, hasLength(rows.length));
      for (var row = 0; row < rows.length; row++) {
        final lefts = page.lines[row].fragments.map((f) => f.left).toList();
        expect(lefts, hasLength(3));
        for (var column = 0; column < columnX.length; column++) {
          expect(
            (lefts[column] - columnX[column]).abs(),
            lessThan(2.0),
            reason: 'колонка $column должна начинаться на x=${columnX[column]}',
          );
          expect((lefts[column] - columnX[column]).abs(), lessThan(0.5));
        }
        // Монотонность по колонкам.
        expect(lefts[1], greaterThan(lefts[0]));
        expect(lefts[2], greaterThan(lefts[1]));
      }
      for (var row = 0; row < rows.length; row++) {
        for (final cell in rows[row]) {
          expect(page.lines[row].text, contains(cell));
        }
      }
    });
  });

  group('JSON', () {
    test('round-trip моделей без потерь', () async {
      final document = await extractor.extract(
        buildSimplePdf(lines: <String>['Расписание', 'Вторник 10:10']),
      );
      final restored = PdfDocumentText.fromJson(
        jsonDecode(jsonEncode(document.toJson())) as Map<String, dynamic>,
      );

      expect(restored.pages, hasLength(document.pages.length));
      expect(restored.text, document.text);
      for (var p = 0; p < document.pages.length; p++) {
        final original = document.pages[p];
        final copy = restored.pages[p];
        expect(copy.pageNumber, original.pageNumber);
        expect(copy.width, original.width);
        expect(copy.height, original.height);
        expect(copy.lines, hasLength(original.lines.length));
        for (var l = 0; l < original.lines.length; l++) {
          final originalFragments = original.lines[l].fragments;
          final copiedFragments = copy.lines[l].fragments;
          expect(copiedFragments, hasLength(originalFragments.length));
          for (var f = 0; f < originalFragments.length; f++) {
            expect(copiedFragments[f].text, originalFragments[f].text);
            expect(copiedFragments[f].left, originalFragments[f].left);
            expect(copiedFragments[f].top, originalFragments[f].top);
            expect(copiedFragments[f].right, originalFragments[f].right);
            expect(copiedFragments[f].bottom, originalFragments[f].bottom);
            expect(copiedFragments[f].fontSize, originalFragments[f].fontSize);
          }
        }
      }
    });

    test('сериализуются только примитивы JSON', () {
      const fragment = PdfTextFragment(
        text: 'x',
        left: 1,
        top: 2,
        right: 3,
        bottom: 4,
        fontSize: 12,
      );
      expect(() => jsonEncode(fragment.toJson()), returnsNormally);
      expect(latin1.decode(utf8.encode(jsonEncode(fragment.toJson()))), isNotEmpty);
    });

    test('copyWith и геттеры моделей', () {
      const line = PdfTextLine(
        fragments: <PdfTextFragment>[
          PdfTextFragment(text: 'A', left: 10, top: 20, right: 20, bottom: 30, fontSize: 10),
          PdfTextFragment(text: 'B', left: 22, top: 20, right: 30, bottom: 30, fontSize: 10),
          PdfTextFragment(text: 'C', left: 60, top: 20, right: 70, bottom: 30, fontSize: 10),
        ],
      );
      // Небольшой разрыв склеивается без пробела, большой — с пробелом.
      expect(line.text, 'AB C');
      expect(line.left, 10);
      expect(line.right, 70);
      expect(line.top, 20);
      expect(line.bottom, 30);
      expect(line.centerY, 25);

      final fragment = line.fragments.first.copyWith(text: 'Z', left: 11);
      expect(fragment.text, 'Z');
      expect(fragment.left, 11);
      expect(fragment.right, 20);
      expect(fragment.width, 9);
      expect(fragment.height, 10);
      expect(fragment.centerY, 25);
      expect(fragment.toString(), contains('Z'));
    });

    test('пустая строка и пустой документ', () {
      const emptyLine = PdfTextLine(fragments: <PdfTextFragment>[]);
      expect(emptyLine.text, '');
      expect(emptyLine.left, 0);
      expect(emptyLine.top, 0);
      expect(
        const PdfDocumentText(pages: <PdfPageText>[]).isEmpty,
        isTrue,
      );
    });
  });

  group('устойчивость', () {
    test('мусорные байты → PdfTextExtractionException', () async {
      expect(
        extractor.extract(buildGarbageBytes()),
        throwsA(isA<PdfTextExtractionException>()),
      );
    });

    test('пустой файл → PdfTextExtractionException', () async {
      expect(
        extractor.extract(Uint8List(0)),
        throwsA(isA<PdfTextExtractionException>()),
      );
    });

    test('текстовый мусор вместо PDF → PdfTextExtractionException', () async {
      final bytes = Uint8List.fromList(utf8.encode('это не pdf, а просто текст'));
      expect(
        extractor.extract(bytes),
        throwsA(isA<PdfTextExtractionException>()),
      );
    });

    test('зашифрованный PDF → PdfTextExtractionException', () async {
      final bytes = buildSimplePdf(
        lines: <String>['Секрет'],
        encrypted: true,
      );
      await expectLater(
        extractor.extract(bytes),
        throwsA(
          isA<PdfTextExtractionException>().having(
            (e) => e.message,
            'message',
            contains('зашифрован'),
          ),
        ),
      );
    });

    test('обрыв файла не приводит к исключению вне контракта', () async {
      final bytes = buildSimplePdf(lines: <String>['Обрыв']);
      final truncated = Uint8List.sublistView(bytes, 0, bytes.length ~/ 2);
      try {
        final document = await extractor.extract(truncated);
        expect(document, isA<PdfDocumentText>());
      } on PdfTextExtractionException catch (e) {
        expect(e.message, isNotEmpty);
      }
    });

    test('повторное использование экстрактора', () async {
      final first = await extractor.extract(
        buildSimplePdf(lines: <String>['Раз']),
      );
      final second = await extractor.extract(
        buildSimplePdf(lines: <String>['Два']),
      );
      expect(first.text, 'Раз');
      expect(second.text, 'Два');
    });
  });

  group('пустые документы', () {
    test('страница без текста', () async {
      final document = await extractor.extract(
        buildSimplePdf(lines: <String>[]),
      );
      expect(document.pages, hasLength(1));
      expect(document.pages.single.lines, isEmpty);
      expect(document.pages.single.text, '');
      expect(document.isEmpty, isTrue);
    });

    test('документ без страниц', () async {
      final document = await extractor.extract(buildNoPagesPdf());
      expect(document.pages, isEmpty);
      expect(document.text, '');
      expect(document.isEmpty, isTrue);
    });
  });

  group('фикстуры', () {
    test('cp1251Encode покрывает кириллицу и пунктуацию', () {
      // Windows-1251: А=0xC0, Я=0xDF, а=0xE0, я=0xFF (сплошной блок А..я).
      expect(cp1251Encode('А'), <int>[0xC0]);
      expect(cp1251Encode('Р'), <int>[0xD0]);
      expect(cp1251Encode('я'), <int>[0xFF]);
      expect(cp1251Encode('ё'), <int>[0xB8]);
      expect(cp1251Encode('№'), <int>[0xB9]);
      expect(cp1251Encode('—'), <int>[0x97]);
      expect(cp1251Encode('«»'), <int>[0xAB, 0xBB]);
      expect(cp1251Encode('A'), <int>[0x41]);
      expect(cp1251Encode('☃'), <int>[0x3F]);
      // Обратная проверка: блок А..я линеен и покрывает весь диапазон.
      expect(cp1251Encode('АБВГДЕЖЗ'), <int>[0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7]);
      expect(cp1251Encode('абвгдежз'), <int>[0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7]);
    });

    test('pdfLiteralString экранирует спецсимволы', () {
      expect(pdfLiteralString(<int>[0x28, 0x29, 0x5C]), r'(\(\)\\)');
      // 'А' = 0xC0 = 0o300, 'Р' = 0xD0 = 0o320.
      expect(pdfLiteralString(cp1251Encode('А')), r'(\300)');
      expect(pdfLiteralString(cp1251Encode('Р')), r'(\320)');
      expect(pdfLiteralString(cp1251Encode('я')), r'(\377)');
    });

    test('pdfHexString пишет двухбайтовые коды', () {
      expect(pdfHexString(<int>[0x0041, 0x0410]), '<00410410>');
    });

    test('генераторы создают PDF 1.4 с подписью', () {
      final bytes = buildSimplePdf(lines: <String>['x']);
      expect(latin1.decode(bytes.sublist(0, 8)), startsWith('%PDF-1.4'));
      expect(latin1.decode(bytes), endsWith('%%EOF\n'));
    });
  });
}
