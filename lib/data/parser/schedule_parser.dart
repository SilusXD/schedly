import 'dart:math' as math;

import '../../core/app_logger.dart';
import '../../domain/models/lesson.dart';
import '../../domain/models/schedule.dart';
import '../../domain/models/weekday.dart';
import '../pdf/pdf_text.dart';
import 'cell_parser.dart';
import 'kip_daily_parser.dart';
import 'kip_semester_parser.dart';
import 'page_layout.dart';
import 'parser_config.dart';

/// Ошибка разбора: PDF прочитан, но распознать расписание не удалось.
class ScheduleParseException implements Exception {
  ScheduleParseException(this.message, {this.details});

  final String message;
  final List<String>? details;

  @override
  String toString() => details == null || details!.isEmpty
      ? 'ScheduleParseException: $message'
      : 'ScheduleParseException: $message (${details!.join('; ')})';
}

/// Результат разбора: готовое расписание плюс сведения о том, как оно получено.
class ParseOutcome {
  const ParseOutcome({
    required this.schedule,
    required this.strategy,
    required this.confidence,
  });

  /// Разобранное расписание.
  final ParsedSchedule schedule;

  /// Название сработавшей стратегии (для журнала и диагностики).
  final String strategy;

  /// Оценка уверенности разбора, 0..1.
  final double confidence;

  @override
  String toString() =>
      'ParseOutcome($strategy, confidence: ${confidence.toStringAsFixed(2)}, ${schedule.lessonCount} занятий)';
}

/// Роль колонки таблицы расписания.
enum ColumnRole { day, pair, time, subject, teacher, group, room, unknown }

/// Парсер расписания из извлечённого текста PDF.
///
/// Форматы PDF сильно различаются, поэтому применяются три стратегии:
/// 1. `week-matrix` — дни недели в шапке таблицы (шахматка «дни × пары»);
/// 2. `table-columns` — классическая таблица со колонками «День / Пара / Время /
///    Предмет / Преподаватель / Группа / Аудитория»;
/// 3. `flat-text` — построчный разбор без табличной структуры.
///
/// Стратегия выбирается по признакам страницы, а при неудаче происходит переход
/// к следующей. Результат с наибольшим «весом» побеждает.
class ScheduleParser {
  ScheduleParser({
    ParserConfig? config,
    CellParser? cellParser,
    AppLogger? logger,
  })  : config = config ?? const ParserConfig(),
        cellParser = cellParser ?? CellParser(config ?? const ParserConfig()),
        logger = logger ?? appLogger;

  final ParserConfig config;
  final CellParser cellParser;
  final AppLogger logger;

  /// Разбирает документ.
  ///
  /// [scheduleDate] — дата, к которой относится расписание (обычно из имени
  /// файла), [sourceUrl] — откуда получен PDF.
  ParseOutcome parse(
    PdfDocumentText document, {
    required DateTime scheduleDate,
    required String sourceUrl,
  }) {
    if (document.pages.isEmpty) {
      throw ScheduleParseException('PDF не содержит страниц');
    }
    if (document.text.trim().isEmpty) {
      throw ScheduleParseException(
        'В PDF не найден текстовый слой',
        details: <String>[
          'Скорее всего, документ является сканом (изображением).',
          'Такой PDF нельзя разобрать без OCR.',
        ],
      );
    }

    final List<String> warnings = <String>[];
    final Map<String, Lesson> collected = <String, Lesson>{};
    final Set<String> usedStrategies = <String>{};

    // Сначала пробуем специализированные форматы расписаний КИП: это матрицы
    // «преподаватель × пара» (ежедневное «общее») и «группа × пара»
    // (полугодовое). Их структура не описывается общими стратегиями ниже,
    // поэтому формат определяется по признакам шапки таблицы.
    final List<Lesson> kipLessons = <Lesson>[];
    if (KipDailyParser.matches(document)) {
      kipLessons.addAll(KipDailyParser(logger: logger).parse(document));
      if (kipLessons.isNotEmpty) {
        usedStrategies.add('kip-daily');
      }
    } else if (KipSemesterParser.matches(document)) {
      kipLessons.addAll(KipSemesterParser(logger: logger).parse(document));
      if (kipLessons.isNotEmpty) {
        usedStrategies.add('kip-semester');
      }
    }

    for (final PdfPageText page in document.pages) {
      if (kipLessons.isNotEmpty) {
        break;
      }
      final PageLayout layout = PageLayout.build(page, config);

      List<Lesson> pageLessons = <Lesson>[];
      final String? matrixStrategy = _tryWeekMatrix(layout);
      if (matrixStrategy == null) {
        pageLessons = _parseTableColumns(layout);
        if (pageLessons.isNotEmpty) {
          usedStrategies.add('table-columns');
        }
      } else {
        pageLessons = _parseWeekMatrix(layout);
        if (pageLessons.isNotEmpty) {
          usedStrategies.add('week-matrix');
        }
      }

      if (pageLessons.isEmpty) {
        final List<Lesson> flat = _parseFlatText(page);
        if (flat.isNotEmpty) {
          pageLessons = flat;
          usedStrategies.add('flat-text');
        } else {
          warnings.add('Страница ${page.pageNumber}: структура не распознана, занятий не найдено');
        }
      }

      for (final Lesson lesson in pageLessons) {
        _addLesson(collected, lesson);
      }
    }

    final List<Lesson> lessons;
    if (kipLessons.isNotEmpty) {
      // В матрицах КИП одно занятие описывается парой «группа + преподаватель»,
      // поэтому обычный ключ склейки (без группы) здесь не подходит.
      final Map<String, Lesson> unique = <String, Lesson>{};
      for (final Lesson lesson in kipLessons) {
        unique['${lesson.weekday.isoNumber}|${lesson.pairNumber}|'
            '${lesson.groupName}|${lesson.teacherName}'] = lesson;
      }
      lessons = unique.values.toList()
        ..sort((Lesson a, Lesson b) => a.compareTo(b));
    } else {
      if (collected.isEmpty) {
        throw ScheduleParseException(
          'Не удалось распознать ни одного занятия',
          details: warnings.isEmpty ? null : warnings,
        );
      }
      lessons = collected.values.toList()
        ..sort((Lesson a, Lesson b) => a.compareTo(b));
    }

    // Догружаем типовое время, если в PDF его не было.
    final List<Lesson> withTime = _applyDefaultPairTimes(lessons, warnings);

    final List<EntitySchedule> teachers =
        _buildEntities(withTime, ScheduleEntityType.teacher);
    final List<EntitySchedule> groups = _buildEntities(withTime, ScheduleEntityType.group);

    if (teachers.isEmpty) {
      warnings.add('В расписании не найдено ни одного преподавателя');
    }
    if (groups.isEmpty) {
      warnings.add('В расписании не найдено ни одной группы');
    }

    final double confidence = _confidence(withTime);
    final String strategy = usedStrategies.isEmpty
        ? 'unknown'
        : (usedStrategies.toList()..sort()).join('+');

    final ParsedSchedule schedule = ParsedSchedule.fromLessons(
      lessons: withTime,
      scheduleDate: scheduleDate,
      parsedAt: DateTime.now(),
      sourceUrl: sourceUrl,
      warnings: warnings,
      rawText: document.text,
    );

    logger.info(
      'Разбор завершён ($strategy): '
      '${withTime.length} занятий, преподавателей ${teachers.length}, групп ${groups.length}, '
      'уверенность ${confidence.toStringAsFixed(2)}',
    );

    return ParseOutcome(schedule: schedule, strategy: strategy, confidence: confidence);
  }

  // ---------------------------------------------------------------------------
  // Стратегия 1: матрица «дни недели × пары».
  // ---------------------------------------------------------------------------

  /// Возвращает название стратегии, если страница похожа на матрицу дней.
  String? _tryWeekMatrix(PageLayout layout) {
    for (final LayoutRow row in layout.sortedRows) {
      final int dayCells = row.filledCells
          .where((MapEntry<int, String> cell) => Weekday.parse(cell.value) != null)
          .length;
      if (dayCells >= 2) {
        return 'week-matrix';
      }
    }
    return null;
  }

  List<Lesson> _parseWeekMatrix(PageLayout layout) {
    final List<LayoutRow> rows = layout.sortedRows;
    int headerIndex = -1;
    Map<int, Weekday> dayColumns = <int, Weekday>{};

    for (int i = 0; i < rows.length; i++) {
      final Map<int, Weekday> found = <int, Weekday>{};
      for (final MapEntry<int, String> cell in rows[i].filledCells) {
        final Weekday? day = Weekday.parse(cell.value);
        if (day != null) {
          found[cell.key] = day;
        }
      }
      if (found.length >= 2) {
        headerIndex = i;
        dayColumns = found;
        break;
      }
    }

    if (headerIndex < 0 || dayColumns.length < 2) {
      return const <Lesson>[];
    }

    final int firstDayColumn = dayColumns.keys.reduce(math.min);
    final List<Lesson> lessons = <Lesson>[];
    int currentPair = 0;
    String? currentTimeStart;
    String? currentTimeEnd;

    for (int i = headerIndex + 1; i < rows.length; i++) {
      final LayoutRow row = rows[i];
      if (_isHeaderRow(row)) {
        continue;
      }

      // Левая часть строки: номер пары и/или время.
      final StringBuffer left = StringBuffer();
      for (final MapEntry<int, String> cell in row.filledCells) {
        if (cell.key < firstDayColumn) {
          left.write(' ${cell.value}');
        }
      }
      final String leftText = left.toString().trim();
      if (leftText.isNotEmpty) {
        final CellFields leftFields = cellParser.parse(leftText);
        if (leftFields.pairNumber > 0) {
          currentPair = leftFields.pairNumber;
        }
        if (leftFields.timeStart != null) {
          currentTimeStart = leftFields.timeStart;
          currentTimeEnd = leftFields.timeEnd;
        }
      }

      // Правая часть: ячейки по дням недели.
      for (final MapEntry<int, Weekday> column in dayColumns.entries) {
        final String cellText = row.cell(column.key);
        if (cellText.isEmpty || _isHeaderCell(cellText)) {
          continue;
        }
        final CellFields fields = cellParser.parse(cellText);
        final String subject = fields.subject.isNotEmpty
            ? fields.subject
            : (fields.teacher.isEmpty && fields.group.isEmpty ? cellText : '');
        if (subject.isEmpty && fields.teacher.isEmpty && fields.room.isEmpty) {
          continue;
        }
        lessons.add(Lesson(
          weekday: fields.weekday ?? column.value,
          pairNumber: fields.pairNumber > 0 ? fields.pairNumber : currentPair,
          subject: subject,
          timeStart: fields.timeStart ?? currentTimeStart,
          timeEnd: fields.timeEnd ?? currentTimeEnd,
          teacherName: fields.teacher,
          groupName: fields.group,
          room: fields.room,
          subgroup: fields.subgroup,
          note: fields.note,
          parity: fields.parity,
          rawText: '${row.text} » $cellText',
        ));
      }
    }

    return lessons;
  }

  // ---------------------------------------------------------------------------
  // Стратегия 2: таблица с колонками.
  // ---------------------------------------------------------------------------

  List<Lesson> _parseTableColumns(PageLayout layout) {
    final List<LayoutRow> rows = layout.sortedRows;
    if (rows.isEmpty) {
      return const <Lesson>[];
    }

    Map<int, ColumnRole> roles = <int, ColumnRole>{};
    int headerIndex = -1;

    for (int i = 0; i < rows.length; i++) {
      final int recognised = _headerRolesOf(rows[i]).length;
      if (recognised >= 2) {
        roles = _mapHeaderRoles(rows[i]);
        headerIndex = i;
        break;
      }
    }

    // Если шапки нет — пробуем угадать колонки по содержимому.
    if (headerIndex < 0) {
      roles = _guessRolesByContent(rows, layout.columns.length);
      headerIndex = -1;
      final int recognised =
          roles.values.where((ColumnRole role) => role != ColumnRole.unknown).length;
      if (recognised == 0) {
        return const <Lesson>[];
      }
    }

    final List<Lesson> lessons = <Lesson>[];
    Weekday? currentDay;
    int currentPair = 0;
    String? currentTimeStart;
    String? currentTimeEnd;

    for (int i = headerIndex + 1; i < rows.length; i++) {
      final LayoutRow row = rows[i];
      if (_isHeaderRow(row)) {
        continue;
      }

      String dayCell = '';
      String pairCell = '';
      String timeCell = '';
      final List<String> subjectCells = <String>[];
      final List<String> teacherCells = <String>[];
      final List<String> groupCells = <String>[];
      final List<String> roomCells = <String>[];
      final List<String> unknownCells = <String>[];

      for (final MapEntry<int, String> cell in row.filledCells) {
        switch (roles[cell.key] ?? ColumnRole.unknown) {
          case ColumnRole.day:
            dayCell = dayCell.isEmpty ? cell.value : '$dayCell ${cell.value}';
          case ColumnRole.pair:
            pairCell = pairCell.isEmpty ? cell.value : '$pairCell ${cell.value}';
          case ColumnRole.time:
            timeCell = timeCell.isEmpty ? cell.value : '$timeCell ${cell.value}';
          case ColumnRole.subject:
            subjectCells.add(cell.value);
          case ColumnRole.teacher:
            teacherCells.add(cell.value);
          case ColumnRole.group:
            groupCells.add(cell.value);
          case ColumnRole.room:
            roomCells.add(cell.value);
          case ColumnRole.unknown:
            unknownCells.add(cell.value);
        }
      }

      final Weekday? parsedDay = dayCell.isEmpty ? null : Weekday.parse(dayCell);
      final CellFields timeFields = cellParser.parse(timeCell);
      final int parsedPair = pairCell.isEmpty
          ? (cellParser.extractPairNumber(timeCell) ?? 0)
          : (cellParser.extractPairNumber(pairCell) ?? 0);

      if (parsedDay != null) {
        currentDay = parsedDay;
      }
      if (parsedPair > 0) {
        currentPair = parsedPair;
      }
      if (timeFields.timeStart != null) {
        currentTimeStart = timeFields.timeStart;
        currentTimeEnd = timeFields.timeEnd;
      }

      final CellFields content = _combineContent(
        subjectCells: subjectCells,
        teacherCells: teacherCells,
        groupCells: groupCells,
        roomCells: roomCells,
        unknownCells: unknownCells,
      );

      final bool hasContent = content.hasContent;
      final bool hasAnchor = parsedDay != null || parsedPair > 0 || timeFields.timeStart != null;

      if (!hasContent) {
        continue;
      }

      // Строка-продолжение: нет «якоря» (дня/пары/времени) и предыдущее занятие
      // ещё не имеет преподавателя или группы — значит это перенос текста.
      final bool isContinuation = !hasAnchor &&
          lessons.isNotEmpty &&
          currentDay != null &&
          (lessons.last.teacherName.isEmpty || lessons.last.groupName.isEmpty);

      if (isContinuation && currentDay == lessons.last.weekday) {
        lessons[lessons.length - 1] = lessons.last.mergeWith(Lesson(
              weekday: currentDay,
              pairNumber: currentPair,
              subject: content.subject,
              timeStart: content.timeStart,
              timeEnd: content.timeEnd,
              teacherName: content.teacher,
              groupName: content.group,
              room: content.room,
              subgroup: content.subgroup,
              note: content.note,
              parity: content.parity,
              rawText: row.text,
            ));
        continue;
      }

      if (currentDay == null) {
        // Без дня недели занятие нельзя отнести к столбцу дневника —
        // пропускаем, но фиксируем это как предупреждение позже.
        continue;
      }

      lessons.add(Lesson(
        weekday: parsedDay ?? currentDay,
        pairNumber: content.pairNumber > 0 ? content.pairNumber : currentPair,
        subject: content.subject,
        timeStart: content.timeStart ?? currentTimeStart,
        timeEnd: content.timeEnd ?? currentTimeEnd,
        teacherName: content.teacher,
        groupName: content.group,
        room: content.room,
        subgroup: content.subgroup,
        note: content.note,
        parity: content.parity,
        rawText: row.text,
      ));
    }

    return lessons;
  }

  /// Объединяет содержимое ячеек строки в один набор полей.
  CellFields _combineContent({
    required List<String> subjectCells,
    required List<String> teacherCells,
    required List<String> groupCells,
    required List<String> roomCells,
    required List<String> unknownCells,
  }) {
    final List<String> subjects = <String>[];
    final List<String> teachers = <String>[];
    final List<String> groups = <String>[];
    final List<String> rooms = <String>[];

    for (final String cell in <String>[...subjectCells, ...unknownCells]) {
      final CellFields fields = cellParser.parse(cell);
      if (fields.subject.isNotEmpty) {
        subjects.add(fields.subject);
      }
      if (fields.teacher.isNotEmpty) {
        teachers.add(fields.teacher);
      }
      if (fields.group.isNotEmpty) {
        groups.add(fields.group);
      }
      if (fields.room.isNotEmpty) {
        rooms.add(fields.room);
      }
      if (fields.subject.isEmpty &&
          fields.teacher.isEmpty &&
          fields.group.isEmpty &&
          fields.room.isEmpty) {
        subjects.add(cell);
      }
    }

    for (final String cell in teacherCells) {
      final String? teacher = cellParser.extractTeacher(cell);
      teachers.add(teacher ?? CellParser.normalizeSpaces(cell));
    }
    for (final String cell in groupCells) {
      final String? group = cellParser.extractGroup(cell);
      groups.add(group ?? CellParser.normalizeSpaces(cell));
    }
    for (final String cell in roomCells) {
      rooms.add(cellParser.extractRoom(cell) ?? CellParser.normalizeSpaces(cell));
    }

    return CellFields(
      subject: _joinUnique(subjects),
      teacher: _joinUnique(teachers),
      group: _joinUnique(groups),
      room: _joinUnique(rooms),
      parity: WeekParity.both,
    );
  }

  static String _joinUnique(List<String> values) {
    final List<String> result = <String>[];
    for (final String raw in values) {
      for (final String part in raw.split(',')) {
        final String value = CellParser.normalizeSpaces(part);
        if (value.isEmpty) {
          continue;
        }
        if (!result.any((String existing) => existing.toLowerCase() == value.toLowerCase())) {
          result.add(value);
        }
      }
    }
    return result.join(', ');
  }

  /// Определяет роли колонок по строке-шапке.
  Map<int, ColumnRole> _mapHeaderRoles(LayoutRow row) {
    final Map<int, ColumnRole> roles = <int, ColumnRole>{};
    for (final MapEntry<int, String> cell in row.filledCells) {
      roles[cell.key] = _roleForHeader(cell.value);
    }
    return roles;
  }

  ColumnRole _roleForHeader(String text) {
    final String value = text.toLowerCase().replaceAll('ё', 'е');
    bool matches(List<String> headers) =>
        headers.any((String header) => value.contains(header));

    if (matches(config.teacherHeaders)) {
      return ColumnRole.teacher;
    }
    if (matches(config.groupHeaders)) {
      return ColumnRole.group;
    }
    if (matches(config.dayHeaders)) {
      return ColumnRole.day;
    }
    if (matches(config.pairHeaders)) {
      return ColumnRole.pair;
    }
    if (matches(config.timeHeaders)) {
      return ColumnRole.time;
    }
    if (matches(config.subjectHeaders)) {
      return ColumnRole.subject;
    }
    if (matches(config.roomHeaders)) {
      return ColumnRole.room;
    }
    return ColumnRole.unknown;
  }

  /// Пытается определить роли колонок по их содержимому (когда шапки нет).
  Map<int, ColumnRole> _guessRolesByContent(List<LayoutRow> rows, int columnCount) {
    final Map<int, ColumnRole> roles = <int, ColumnRole>{};
    for (int column = 0; column < columnCount; column++) {
      int dayHits = 0;
      int pairHits = 0;
      int timeHits = 0;
      int teacherHits = 0;
      int groupHits = 0;
      int roomHits = 0;
      int total = 0;

      for (final LayoutRow row in rows) {
        final String text = row.cell(column);
        if (text.isEmpty) {
          continue;
        }
        total++;
        if (Weekday.parse(text) != null) {
          dayHits++;
        }
        if (cellParser.extractPairNumber(text) != null) {
          pairHits++;
        }
        if (RegExp(r'\d{1,2}[:.]\d{2}').hasMatch(text)) {
          timeHits++;
        }
        if (cellParser.extractTeacher(text) != null) {
          teacherHits++;
        }
        if (cellParser.extractGroup(text) != null) {
          groupHits++;
        }
        if (cellParser.extractRoom(text) != null) {
          roomHits++;
        }
      }

      if (total == 0) {
        roles[column] = ColumnRole.unknown;
        continue;
      }

      final List<MapEntry<ColumnRole, int>> scores = <MapEntry<ColumnRole, int>>[
        MapEntry<ColumnRole, int>(ColumnRole.day, dayHits),
        MapEntry<ColumnRole, int>(ColumnRole.teacher, teacherHits),
        MapEntry<ColumnRole, int>(ColumnRole.group, groupHits),
        MapEntry<ColumnRole, int>(ColumnRole.room, roomHits),
        MapEntry<ColumnRole, int>(ColumnRole.time, timeHits),
        MapEntry<ColumnRole, int>(ColumnRole.pair, pairHits),
      ]..sort((MapEntry<ColumnRole, int> a, MapEntry<ColumnRole, int> b) =>
          b.value.compareTo(a.value));

      final MapEntry<ColumnRole, int> best = scores.first;
      roles[column] = best.value >= math.max(2, (total * 0.3).ceil())
          ? best.key
          : ColumnRole.unknown;
    }
    return roles;
  }

  // ---------------------------------------------------------------------------
  // Стратегия 3: построчный разбор «плоского» текста.
  // ---------------------------------------------------------------------------

  List<Lesson> _parseFlatText(PdfPageText page) {
    final List<Lesson> lessons = <Lesson>[];
    Weekday? currentDay;
    int currentPair = 0;
    String? currentTimeStart;
    String? currentTimeEnd;

    final List<PdfTextLine> lines = List<PdfTextLine>.of(page.lines)
      ..sort((PdfTextLine a, PdfTextLine b) => a.top.compareTo(b.top));

    for (final PdfTextLine line in lines) {
      final String text = CellParser.normalizeSpaces(line.text);
      if (text.isEmpty || _isHeaderCell(text)) {
        continue;
      }

      final Weekday? day = Weekday.parse(text);
      final CellFields fields = cellParser.parse(text);
      final int pairFromText = cellParser.extractPairNumber(text) ?? 0;

      // Строка-заголовок дня: «Понедельник», «ПН».
      if (day != null && !fields.hasContent) {
        currentDay = day;
        currentPair = 0;
        currentTimeStart = null;
        currentTimeEnd = null;
        continue;
      }

      if (day != null) {
        currentDay = day;
      }
      if (pairFromText > 0) {
        currentPair = pairFromText;
      }
      if (fields.timeStart != null) {
        currentTimeStart = fields.timeStart;
        currentTimeEnd = fields.timeEnd;
        if (currentPair == 0) {
          currentPair = _pairNumberByTime(currentTimeStart);
        }
      }

      // Строка содержит только «якорь» (день, номер пары или время): она
      // обновляет текущее состояние разбора, но занятия не создаёт.
      if (!fields.hasContent) {
        continue;
      }
      if (currentDay == null) {
        continue;
      }

      // Строка может быть продолжением предыдущего занятия (вторая строка
      // названия предмета или списка преподавателей). В «плоском» тексте
      // строки одной пары идут подряд, поэтому продолжаем до смены пары.
      final bool isContinuation = fields.timeStart == null &&
          pairFromText == 0 &&
          lessons.isNotEmpty &&
          lessons.last.weekday == currentDay &&
          lessons.last.pairNumber == currentPair;

      if (isContinuation) {
        final Lesson merged = lessons.last.mergeWith(Lesson(
          weekday: currentDay,
          pairNumber: currentPair,
          subject: fields.subject,
          teacherName: fields.teacher,
          groupName: fields.group,
          room: fields.room,
          subgroup: fields.subgroup,
          note: fields.note,
          rawText: text,
        ));
        lessons[lessons.length - 1] = merged;
        continue;
      }

      final String subject = fields.subject.isNotEmpty
          ? fields.subject
          : (fields.teacher.isEmpty && fields.group.isEmpty ? text : '');

      lessons.add(Lesson(
        weekday: currentDay,
        pairNumber: pairFromText > 0 ? pairFromText : currentPair,
        subject: subject,
        timeStart: fields.timeStart ?? currentTimeStart,
        timeEnd: fields.timeEnd ?? currentTimeEnd,
        teacherName: fields.teacher,
        groupName: fields.group,
        room: fields.room,
        subgroup: fields.subgroup,
        note: fields.note,
        parity: fields.parity,
        rawText: text,
      ));
    }

    return lessons;
  }

  int _pairNumberByTime(String? timeStart) {
    if (timeStart == null) {
      return 0;
    }
    for (final PairTime time in config.defaultPairTimes) {
      if (time.start == timeStart) {
        return time.pairNumber;
      }
    }
    return 0;
  }

  // ---------------------------------------------------------------------------
  // Служебные операции.
  // ---------------------------------------------------------------------------

  /// Является ли строка шапкой таблицы.
  ///
  /// Ячейки с цифрами игнорируются: «ауд. 305» и «08:30-10:00» содержат
  /// служебные слова из списка заголовков, но это данные, а не заголовки —
  /// без этой проверки строка занятий ошибочно принималась за шапку.
  bool _isHeaderRow(LayoutRow row) => _headerRolesOf(row).length >= 2;

  /// Роли заголовков, распознанные в строке (только по ячейкам без цифр).
  Set<ColumnRole> _headerRolesOf(LayoutRow row) {
    final Set<ColumnRole> roles = <ColumnRole>{};
    for (final MapEntry<int, String> cell in row.filledCells) {
      if (RegExp(r'\d').hasMatch(cell.value)) {
        continue;
      }
      final ColumnRole role = _roleForHeader(cell.value);
      if (role != ColumnRole.unknown) {
        roles.add(role);
      }
    }
    return roles;
  }

  /// Является ли ячейка подписью колонки.
  ///
  /// Подпись — это короткая строка без цифр («Аудитория», «Пара», «Время»).
  /// Строка данных вроде «1 пара 08:30-10:00» или «Математика, ауд. 305»
  /// содержит цифры и заголовком не считается, хотя и включает служебные слова.
  bool _isHeaderCell(String text) {
    if (text.length > 24 || RegExp(r'\d').hasMatch(text)) {
      return false;
    }
    return _roleForHeader(text) != ColumnRole.unknown;
  }

  /// Добавляет занятие, склеивая дубликаты (одна пара у нескольких групп и т. п.).
  void _addLesson(Map<String, Lesson> target, Lesson lesson) {
    if (!lesson.isMeaningful && lesson.teacherName.isEmpty && lesson.groupName.isEmpty) {
      return;
    }
    final String key = lesson.mergeKey;
    final Lesson? existing = target[key];
    target[key] = existing == null ? lesson : existing.mergeWith(lesson);
  }

  /// Подставляет типовое время парам, у которых его нет.
  List<Lesson> _applyDefaultPairTimes(List<Lesson> lessons, List<String> warnings) {
    if (!config.assumeDefaultPairTimes) {
      return lessons;
    }
    int replaced = 0;
    final List<Lesson> result = <Lesson>[];
    for (final Lesson lesson in lessons) {
      if ((lesson.timeStart ?? '').isNotEmpty) {
        result.add(lesson);
        continue;
      }
      final PairTime? time = config.pairTime(lesson.pairNumber);
      if (time == null) {
        result.add(lesson);
        continue;
      }
      replaced++;
      result.add(lesson.copyWith(timeStart: time.start, timeEnd: time.end));
    }
    if (replaced > 0) {
      warnings.add(
        'Для $replaced занятий время не указано в PDF — подставлено типовое расписание звонков',
      );
    }
    return result;
  }

  /// Собирает расписания преподавателей или групп из плоского списка занятий.
  List<EntitySchedule> _buildEntities(
    List<Lesson> lessons,
    ScheduleEntityType type,
  ) {
    final Map<String, Map<String, Lesson>> byEntity = <String, Map<String, Lesson>>{};

    for (final Lesson lesson in lessons) {
      final String raw =
          type == ScheduleEntityType.teacher ? lesson.teacherName : lesson.groupName;
      for (final String name in _splitEntityNames(raw)) {
        final Map<String, Lesson> bucket =
            byEntity.putIfAbsent(name, () => <String, Lesson>{});
        final Lesson? existing = bucket[lesson.mergeKey];
        bucket[lesson.mergeKey] = existing == null ? lesson : existing.mergeWith(lesson);
      }
    }

    final List<EntitySchedule> result = byEntity.entries.map(
      (MapEntry<String, Map<String, Lesson>> entry) {
        final List<Lesson> entityLessons = entry.value.values.toList()..sort();
        return EntitySchedule(
          name: entry.key,
          type: type,
          lessons: entityLessons,
        );
      },
    ).toList()
      ..sort((EntitySchedule a, EntitySchedule b) => a.name.compareTo(b.name));

    return result;
  }

  /// Разбивает «Иванов И.И., Петров П.П.» на отдельные сущности.
  static List<String> _splitEntityNames(String raw) {
    final String value = CellParser.normalizeSpaces(raw);
    if (value.isEmpty) {
      return const <String>[];
    }
    return value
        .split(RegExp(r'[,;]'))
        .map((String part) => part.trim())
        .where((String part) => part.isNotEmpty)
        .toSet()
        .toList();
  }

  /// Оценка качества разбора: чем больше занятий с предметом и участниками,
  /// тем выше уверенность.
  double _confidence(List<Lesson> lessons) {
    if (lessons.isEmpty) {
      return 0;
    }
    double subject = 0;
    double teacher = 0;
    double group = 0;
    for (final Lesson lesson in lessons) {
      if (lesson.subject.isNotEmpty) {
        subject++;
      }
      if (lesson.teacherName.isNotEmpty) {
        teacher++;
      }
      if (lesson.groupName.isNotEmpty) {
        group++;
      }
    }
    final double total = lessons.length.toDouble();
    return ((subject / total) * 0.4 + (teacher / total) * 0.3 + (group / total) * 0.3)
        .clamp(0, 1);
  }
}
