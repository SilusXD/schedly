import '../../core/app_logger.dart';
import '../../domain/models/lesson.dart';
import '../../domain/models/weekday.dart';
import '../pdf/pdf_text.dart';
import 'matrix_layout.dart';

/// Разбор ежедневного «общего» расписания КИП (матрица «преподаватель × пара»).
///
/// Формат: одна страница (или несколько подряд) — один учебный день; в шапке
/// указаны пары и их время, строки таблицы — преподаватели, а в ячейках стоят
/// группы и аудитория. Названий предметов в этом файле нет: они берутся из
/// полугодового расписания (см. `KipSemesterParser` и `ScheduleMerger`).
class KipDailyParser {
  KipDailyParser({AppLogger? logger}) : _logger = logger ?? appLogger;

  final AppLogger _logger;

  /// Отступ, на который содержимое строки преподавателя поднимается вверх.
  static const double _sectionOffset = 15;

  /// Определяет, похож ли документ на ежедневное расписание КИП.
  static bool matches(PdfDocumentText document) {
    for (final PdfPageText page in document.pages) {
      bool hasPairHeader = false;
      bool hasTeacherHeader = false;
      for (final PdfTextLine line in page.lines) {
        int pairs = 0;
        for (final PdfTextFragment fragment in line.fragments) {
          if (MatrixLayout.pairPattern.hasMatch(fragment.text)) {
            pairs++;
          }
        }
        if (pairs >= 3) {
          hasPairHeader = true;
        }
        if (line.text.toLowerCase().contains('преподаватель')) {
          hasTeacherHeader = true;
        }
      }
      if (hasPairHeader && hasTeacherHeader) {
        return true;
      }
    }
    return false;
  }

  /// Разбирает документ: по одной записи на каждую пару «преподаватель + группа».
  List<Lesson> parse(PdfDocumentText document) {
    final List<Lesson> lessons = <Lesson>[];
    Weekday? currentWeekday;

    for (final PdfPageText page in document.pages) {
      final Weekday? pageWeekday = _detectWeekday(page);
      if (pageWeekday != null) {
        currentWeekday = pageWeekday;
      }
      if (currentWeekday == null) {
        continue;
      }

      final List<MatrixColumn> columns = _detectPairColumns(page);
      if (columns.isEmpty) {
        continue;
      }

      final double serviceEdge = columns.first.left - 6;
      final Map<int, (String, String)> times = _detectTimes(page, columns, serviceEdge);
      final List<_TeacherAnchor> anchors =
          _detectTeacherAnchors(page, serviceEdge, page.height);
      if (anchors.isEmpty) {
        continue;
      }

      for (int index = 0; index < anchors.length; index++) {
        final _TeacherAnchor anchor = anchors[index];
        final double topFrom = anchor.top - _sectionOffset;
        final double topTo = index + 1 < anchors.length
            ? anchors[index + 1].top - _sectionOffset
            : page.height;

        for (final MatrixColumn column in columns) {
          final List<PdfTextFragment> fragments = MatrixLayout.fragmentsIn(
            page: page,
            columns: columns,
            column: column,
            topFrom: topFrom,
            topTo: topTo,
            minLeft: serviceEdge,
          );
          if (fragments.isEmpty) {
            continue;
          }

          final List<String> lines = MatrixLayout.toLines(fragments);
          final List<String> groups = <String>[];
          final List<String> rooms = <String>[];
          final List<String> others = <String>[];
          for (final String line in lines) {
            final Iterable<RegExpMatch> matches =
                MatrixLayout.groupPattern.allMatches(line);
            if (matches.isNotEmpty) {
              for (final RegExpMatch match in matches) {
                groups.add(MatrixLayout.normalizeGroup(match.group(0)!));
              }
              continue;
            }
            if (MatrixLayout.looksLikeRoom(line)) {
              rooms.add(line);
              continue;
            }
            others.add(line);
          }

          if (groups.isEmpty && rooms.isEmpty && others.isEmpty) {
            continue;
          }

          final String room = MatrixLayout.normalizeSpaces(rooms.join(', '));
          final int pairNumber = column.index + 1;
          final (String, String)? time = times[pairNumber];

          if (groups.isEmpty) {
            lessons.add(Lesson(
              weekday: currentWeekday,
              pairNumber: pairNumber,
              subject: '',
              timeStart: time?.$1,
              timeEnd: time?.$2,
              teacherName: anchor.name,
              room: room,
              note: MatrixLayout.normalizeSpaces(others.join(', ')),
              rawText: '${anchor.name}: ${lines.join(' / ')}',
            ));
            continue;
          }

          for (final String group in groups.toSet()) {
            lessons.add(Lesson(
              weekday: currentWeekday,
              pairNumber: pairNumber,
              subject: '',
              timeStart: time?.$1,
              timeEnd: time?.$2,
              teacherName: anchor.name,
              groupName: group,
              room: room,
              note: MatrixLayout.normalizeSpaces(others.join(', ')),
              rawText: '${anchor.name}: ${lines.join(' / ')}',
            ));
          }
        }
      }
    }

    _logger.info('Ежедневное расписание: ${lessons.length} записей, '
        'преподавателей ${lessons.map((Lesson l) => l.teacherName).toSet().length}');
    return lessons;
  }

  /// День недели из заголовка страницы («Понедельник 28.09.2026»).
  static Weekday? _detectWeekday(PdfPageText page) {
    for (final PdfTextLine line in page.lines.take(12)) {
      for (final PdfTextFragment fragment in line.fragments) {
        final String text = fragment.text.trim();
        if (text.isEmpty || text.length > 40) {
          continue;
        }
        final String firstWord = text.split(RegExp(r'[\s,]+')).first;
        final Weekday? day = Weekday.parse(firstWord);
        if (day != null) {
          return day;
        }
      }
    }
    return null;
  }

  /// Колонки пар по строке-шапке («1 пара», «2 пара», …).
  static List<MatrixColumn> _detectPairColumns(PdfPageText page) {
    List<MatrixColumn> best = const <MatrixColumn>[];
    for (final PdfTextLine line in page.lines) {
      final List<MatrixColumn> columns = MatrixLayout.columnsFromRow(
        line,
        accept: (String label) => MatrixLayout.pairPattern.hasMatch(label),
      );
      if (columns.length > best.length) {
        best = columns;
      }
      if (best.length >= 5) {
        break;
      }
    }
    return best;
  }

  /// Времена пар из строки времён, разложенные по колонкам.
  static Map<int, (String, String)> _detectTimes(
    PdfPageText page,
    List<MatrixColumn> columns,
    double serviceEdge,
  ) {
    final Map<int, (String, String)> result = <int, (String, String)>{};
    List<PdfTextFragment>? bestRow;
    int bestCount = 0;

    for (final PdfTextLine line in page.lines) {
      final List<PdfTextFragment> times = line.fragments
          .where((PdfTextFragment f) => MatrixLayout.parseTime(f.text) != null)
          .toList();
      if (times.length > bestCount) {
        bestCount = times.length;
        bestRow = times;
      }
    }
    if (bestRow == null || bestCount < 2) {
      return result;
    }

    for (final PdfTextFragment fragment in bestRow) {
      final int index = MatrixLayout.nearestColumn(fragment, columns);
      if (index < 0) {
        continue;
      }
      final (String, String)? time = MatrixLayout.parseTime(fragment.text);
      if (time != null) {
        result[index + 1] = time;
      }
    }
    return result;
  }

  /// Якоря строк таблицы — ФИО преподавателей в левой колонке.
  static List<_TeacherAnchor> _detectTeacherAnchors(
    PdfPageText page,
    double serviceEdge,
    double pageHeight,
  ) {
    final List<_TeacherAnchor> anchors = <_TeacherAnchor>[];
    for (final PdfTextLine line in page.lines) {
      for (final PdfTextFragment fragment in line.fragments) {
        if (fragment.left >= serviceEdge || fragment.top >= pageHeight) {
          continue;
        }
        final String text = MatrixLayout.normalizeSpaces(fragment.text);
        if (text.isEmpty || !MatrixLayout.looksLikeTeacher(text)) {
          continue;
        }
        anchors.add(_TeacherAnchor(top: fragment.top, name: text));
      }
    }
    anchors.sort((_TeacherAnchor a, _TeacherAnchor b) => a.top.compareTo(b.top));

    // Один преподаватель может занимать несколько фрагментов на близких
    // позициях — оставляем самый верхний.
    final List<_TeacherAnchor> unique = <_TeacherAnchor>[];
    for (final _TeacherAnchor anchor in anchors) {
      if (unique.isNotEmpty && (anchor.top - unique.last.top).abs() < 6) {
        continue;
      }
      unique.add(anchor);
    }
    return unique;
  }
}

/// Якорь строки таблицы: преподаватель и его вертикальная позиция.
class _TeacherAnchor {
  const _TeacherAnchor({required this.top, required this.name});

  final double top;
  final String name;
}
