import '../../core/app_logger.dart';
import '../../domain/models/lesson.dart';
import '../../domain/models/weekday.dart';
import '../pdf/pdf_text.dart';
import 'matrix_layout.dart';

/// Разбор полугодового расписания КИП (матрица «группа × пара»).
///
/// Формат: одна страница — один учебный день; шапка страницы перечисляет
/// группы (колонки), в служебной колонке слева стоят номер пары и время, а в
/// ячейках — название предмета и ФИО преподавателя (предмет выше, ФИО ниже,
/// текст может переноситься на несколько строк).
///
/// Один файл содержит весь семестр, поэтому такое расписание служит источником
/// названий предметов и плановых преподавателей.
class KipSemesterParser {
  KipSemesterParser({AppLogger? logger}) : _logger = logger ?? appLogger;

  final AppLogger _logger;

  /// Определяет, похож ли документ на полугодовое расписание КИП.
  static bool matches(PdfDocumentText document) {
    for (final PdfPageText page in document.pages) {
      for (final PdfTextLine line in page.lines) {
        int groups = 0;
        for (final PdfTextFragment fragment in line.fragments) {
          if (MatrixLayout.looksLikeGroup(fragment.text)) {
            groups++;
          }
        }
        if (groups >= 3) {
          return true;
        }
      }
    }
    return false;
  }

  /// Разбирает документ в список занятий (по одной записи на группу).
  List<Lesson> parse(PdfDocumentText document) {
    final List<Lesson> lessons = <Lesson>[];
    Weekday? currentWeekday;

    for (final PdfPageText page in document.pages) {
      if (page.lines.length < 5) {
        continue;
      }

      // День недели: на странице полугодового расписания он вынесен отдельной
      // (нередко вертикальной) надписью слева.
      final Weekday? pageWeekday = _detectWeekday(page);
      if (pageWeekday != null) {
        currentWeekday = pageWeekday;
      }
      if (currentWeekday == null) {
        continue;
      }

      final List<MatrixColumn> columns = _detectGroupColumns(page);
      if (columns.length < 3) {
        continue;
      }
      final double serviceEdge = columns.first.left - 6;

      final List<_PairAnchor> anchors = _detectPairAnchors(page, serviceEdge, page.height);
      if (anchors.isEmpty) {
        continue;
      }

      for (final MatrixColumn column in columns) {
        // Фрагменты колонки распределяются по парам по БЛИЖАЙШЕМУ якорю
        // времени: это устойчивее деления на секции, потому что текст ячейки
        // может «подниматься» над временем своей пары и заходить за границу
        // соседней. Всё, что выше первой пары, — это шапка с подписями
        // колонок, поэтому такие фрагменты исключаются.
        final double contentTop = anchors.first.top - 20;
        final List<PdfTextFragment> columnFragments = page.lines
            .expand((PdfTextLine line) => line.fragments)
            .where((PdfTextFragment f) =>
                f.text.trim().isNotEmpty &&
                f.left >= serviceEdge &&
                f.top >= contentTop &&
                MatrixLayout.nearestColumnByLeft(f, columns) == column.index)
            .toList();

        final Map<int, List<PdfTextFragment>> byPair = <int, List<PdfTextFragment>>{};
        for (final PdfTextFragment fragment in columnFragments) {
          final int pairIndex = _nearestAnchorIndex(fragment.top, anchors);
          if (pairIndex < 0) {
            continue;
          }
          byPair.putIfAbsent(pairIndex, () => <PdfTextFragment>[]).add(fragment);
        }

        for (final MapEntry<int, List<PdfTextFragment>> entry in byPair.entries) {
          final _PairAnchor anchor = anchors[entry.key];
          final List<PdfTextFragment> fragments = entry.value
            ..sort((PdfTextFragment a, PdfTextFragment b) {
              final int byTop = a.top.compareTo(b.top);
              return byTop != 0 ? byTop : a.left.compareTo(b.left);
            });
          if (fragments.isEmpty) {
            continue;
          }

          final List<String> lines = MatrixLayout.toLines(fragments);
          final List<String> teacherLines = <String>[];
          final List<String> subjectLines = <String>[];
          for (final String line in lines) {
            if (MatrixLayout.looksLikeTeacher(line) ||
                MatrixLayout.vacancyPattern.hasMatch(line)) {
              teacherLines.add(line);
            } else {
              subjectLines.add(line);
            }
          }

          // Название предмета может занимать несколько строк («Иностранный
          // язык в сфере профессиональной деятельности»), поэтому все строки
          // без ФИО склеиваются в одно название.
          final String subject =
              MatrixLayout.normalizeSpaces(subjectLines.join(' '));

          if (teacherLines.isEmpty) {
            if (subject.isEmpty) {
              continue;
            }
            lessons.add(Lesson(
              weekday: currentWeekday,
              pairNumber: anchor.pairNumber,
              subject: subject,
              timeStart: anchor.timeStart,
              timeEnd: anchor.timeEnd,
              groupName: MatrixLayout.normalizeGroup(column.label),
              rawText: '${column.label}: ${lines.join(' / ')}',
            ));
            continue;
          }

          // Две записи в одной ячейке означают деление семестра по неделям:
          // первая — нечётная (числитель), вторая — чётная (знаменатель).
          for (int slot = 0; slot < teacherLines.length; slot++) {
            lessons.add(Lesson(
              weekday: currentWeekday,
              pairNumber: anchor.pairNumber,
              subject: subject,
              timeStart: anchor.timeStart,
              timeEnd: anchor.timeEnd,
              teacherName: MatrixLayout.normalizeSpaces(teacherLines[slot]),
              groupName: MatrixLayout.normalizeGroup(column.label),
              parity: teacherLines.length == 1
                  ? WeekParity.both
                  : (slot == 0 ? WeekParity.numerator : WeekParity.denominator),
              rawText: '${column.label}: ${lines.join(' / ')}',
            ));
          }
        }
      }
    }

    _logger.info('Полугодовое расписание: ${lessons.length} записей, '
        'групп ${lessons.map((Lesson l) => l.groupName).toSet().length}');
    return lessons;
  }

  /// Индекс якоря пары, ближайшего к позиции [top].
  static int _nearestAnchorIndex(double top, List<_PairAnchor> anchors) {
    if (anchors.isEmpty) {
      return -1;
    }
    int best = 0;
    double bestDistance = double.infinity;
    for (int i = 0; i < anchors.length; i++) {
      final double distance = (anchors[i].top - top).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }

  /// Ищет день недели на странице.
  static Weekday? _detectWeekday(PdfPageText page) {
    for (final PdfTextLine line in page.lines) {
      for (final PdfTextFragment fragment in line.fragments) {
        final String text = fragment.text.trim();
        if (text.length < 3 || text.length > 20) {
          continue;
        }
        final Weekday? day = Weekday.parse(text);
        if (day != null) {
          return day;
        }
      }
    }
    return null;
  }

  /// Определяет колонки групп по шапке страницы.
  ///
  /// Колонки строятся по ВСЕМ подписям строки-шапки, а не только по тем, что
  /// распознались как группа: если одна подпись разорвана переносом
  /// («2ОИБТ С-1325»), фильтр пропустил бы её и сдвинул все последующие
  /// колонки — данные попали бы не в свои группы.
  static List<MatrixColumn> _detectGroupColumns(PdfPageText page) {
    PdfTextLine? bestRow;
    int bestCount = 0;
    for (final PdfTextLine line in page.lines) {
      final int count = line.fragments
          .where((PdfTextFragment f) => MatrixLayout.looksLikeGroup(f.text))
          .length;
      if (count > bestCount) {
        bestCount = count;
        bestRow = line;
      }
    }
    if (bestRow == null || bestCount < 3) {
      return const <MatrixColumn>[];
    }
    return MatrixLayout.columnsFromRow(
      bestRow,
      accept: (String label) =>
          label.trim().length >= 4 && RegExp(r'[0-9А-Яа-я]').hasMatch(label),
    );
  }

  /// Находит пары на странице по строке времени в служебной колонке.
  static List<_PairAnchor> _detectPairAnchors(
    PdfPageText page,
    double serviceEdge,
    double pageHeight,
  ) {
    final List<PdfTextFragment> service = page.lines
        .expand((PdfTextLine line) => line.fragments)
        .where((PdfTextFragment f) =>
            f.text.trim().isNotEmpty && f.left < serviceEdge && f.top < pageHeight)
        .toList();

    final List<_PairAnchor> anchors = <_PairAnchor>[];
    for (final PdfTextFragment fragment in service) {
      final (String, String)? time = MatrixLayout.parseTime(fragment.text);
      if (time == null) {
        continue;
      }
      anchors.add(_PairAnchor(
        top: fragment.top,
        timeStart: time.$1,
        timeEnd: time.$2,
        pairNumber: 0,
      ));
    }
    anchors.sort((_PairAnchor a, _PairAnchor b) => a.top.compareTo(b.top));

    // Номер пары: сначала пробуем подпись «N пара» рядом со временем,
    // иначе — по порядку следования пар на странице.
    for (int i = 0; i < anchors.length; i++) {
      final _PairAnchor anchor = anchors[i];
      int number = 0;
      for (final PdfTextFragment fragment in service) {
        if ((fragment.top - anchor.top).abs() > 12) {
          continue;
        }
        final RegExpMatch? match = MatrixLayout.pairPattern.firstMatch(fragment.text);
        if (match != null) {
          number = int.tryParse(match.group(1)!) ?? 0;
          break;
        }
      }
      anchors[i] = anchor.copyWith(pairNumber: number > 0 ? number : i + 1);
    }
    return anchors;
  }
}

/// Якорь пары: вертикальная позиция, время и номер.
class _PairAnchor {
  const _PairAnchor({
    required this.top,
    required this.timeStart,
    required this.timeEnd,
    required this.pairNumber,
  });

  final double top;
  final String timeStart;
  final String timeEnd;
  final int pairNumber;

  _PairAnchor copyWith({int? pairNumber}) => _PairAnchor(
        top: top,
        timeStart: timeStart,
        timeEnd: timeEnd,
        pairNumber: pairNumber ?? this.pairNumber,
      );
}
