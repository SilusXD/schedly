import 'package:flutter_test/flutter_test.dart';
import 'package:schedly/core/lesson_key.dart';
import 'package:schedly/domain/models/lesson.dart';
import 'package:schedly/domain/models/lesson_note.dart';
import 'package:schedly/domain/models/schedule.dart';
import 'package:schedly/domain/models/weekday.dart';

import '../support/fakes.dart';

void main() {
  group('Lesson', () {
    const Lesson lesson = Lesson(
      weekday: Weekday.monday,
      pairNumber: 2,
      subject: 'Математика',
      timeStart: '10:10',
      timeEnd: '11:40',
      teacherName: 'Иванов И.И.',
      groupName: 'ИС-21',
      room: '305',
    );

    test('timeRange собирает диапазон', () {
      expect(lesson.timeRange, '10:10–11:40');
      const Lesson onlyStart = Lesson(
        weekday: Weekday.monday,
        pairNumber: 1,
        subject: 'X',
        timeStart: '08:30',
      );
      expect(onlyStart.timeRange, '08:30');
      const Lesson withoutTime = Lesson(
        weekday: Weekday.monday,
        pairNumber: 1,
        subject: 'X',
      );
      expect(withoutTime.timeRange, '');
    });

    test('mergeKey не зависит от преподавателя и группы', () {
      expect(lesson.mergeKey, lesson.copyWith(teacherName: 'Петров П.П.').mergeKey);
    });

    test('mergeWith дополняет пустые поля и не перетирает заполненные', () {
      const Lesson partial = Lesson(
        weekday: Weekday.monday,
        pairNumber: 2,
        subject: 'Математика',
        timeStart: '10:10',
        timeEnd: '11:40',
        groupName: 'ИС-22',
      );
      final Lesson merged = partial.mergeWith(lesson);
      expect(merged.teacherName, 'Иванов И.И.');
      expect(merged.room, '305');
      // Группы объединяются: у одной пары могут заниматься несколько групп.
      expect(merged.groupName, 'ИС-22, ИС-21');
    });

    test('mergeWith объединяет списки групп без дубликатов', () {
      const Lesson first = Lesson(
        weekday: Weekday.monday,
        pairNumber: 1,
        subject: 'Физика',
        groupName: 'ИС-21',
      );
      final Lesson merged = first.mergeWith(first.copyWith(groupName: 'ИС-21, ИС-22'));
      expect(merged.groupName, 'ИС-21, ИС-22');
    });

    test('сериализация в JSON сохраняет все поля', () {
      final Lesson restored = Lesson.fromJson(lesson.toJson());
      expect(restored.subject, lesson.subject);
      expect(restored.weekday, lesson.weekday);
      expect(restored.pairNumber, lesson.pairNumber);
      expect(restored.timeRange, lesson.timeRange);
      expect(restored.teacherName, lesson.teacherName);
      expect(restored.groupName, lesson.groupName);
      expect(restored.room, lesson.room);
    });

    test('compareTo сортирует по дню, затем по паре', () {
      final List<Lesson> lessons = <Lesson>[
        lesson.copyWith(weekday: Weekday.friday),
        lesson.copyWith(weekday: Weekday.monday, pairNumber: 3),
        lesson,
      ]..sort();
      expect(lessons.first.weekday, Weekday.monday);
      expect(lessons.first.pairNumber, 2);
      expect(lessons.last.weekday, Weekday.friday);
    });
  });

  group('WeekParity', () {
    test('parse распознаёт числитель и знаменатель', () {
      expect(WeekParity.parse('числитель'), WeekParity.numerator);
      expect(WeekParity.parse('Знаменатель'), WeekParity.denominator);
      expect(WeekParity.parse('неделя'), isNull);
    });
  });

  group('ParsedSchedule', () {
    final ParsedSchedule schedule = buildSampleSchedule(date: DateTime(2026, 3, 16));

    test('weekKey и weekStart вычисляются по дате расписания', () {
      expect(schedule.weekKey, '2026-W12');
      expect(schedule.weekStart, DateTime(2026, 3, 16));
    });

    test('имена преподавателей и групп доступны и отсортированы', () {
      expect(schedule.teacherNames, <String>['Иванов Иван Петрович']);
      expect(schedule.groupNames, <String>['ИС-21']);
      expect(schedule.lessonCount, 2);
    });

    test('поиск сущности работает без учёта регистра и по части имени', () {
      expect(schedule.teacher('иванов иван петрович'), isNotNull);
      expect(schedule.teacher('Иванов'), isNotNull);
      expect(schedule.group('ис-21'), isNotNull);
      expect(schedule.teacher('Неизвестный'), isNull);
    });

    test('JSON round-trip сохраняет занятия', () {
      final ParsedSchedule? restored = ParsedSchedule.tryParse(schedule.toJsonString());
      expect(restored, isNotNull);
      expect(restored!.teacherNames, schedule.teacherNames);
      expect(restored.groupNames, schedule.groupNames);
      expect(restored.lessonCount, schedule.lessonCount);
      expect(restored.scheduleDate, schedule.scheduleDate);
    });

    test('JSON без сырого текста не содержит его', () {
      final String json = schedule.toJsonString();
      expect(json.contains('rawText'), isFalse);
      final String withRaw = schedule.toJsonString(includeRawText: true);
      expect(withRaw.contains('rawText'), isTrue);
    });

    test('tryParse возвращает null для мусора', () {
      expect(ParsedSchedule.tryParse('{ не json'), isNull);
      expect(ParsedSchedule.tryParse('[]'), isNull);
    });

    test('EntitySchedule.lessonsFor фильтрует по дню', () {
      final EntitySchedule? teacher = schedule.teacher('Иванов Иван Петрович');
      expect(teacher, isNotNull);
      expect(teacher!.lessonsFor(Weekday.monday).length, 1);
      expect(teacher.lessonsFor(Weekday.friday), isEmpty);
      expect(teacher.activeWeekdays.length, 2);
    });
  });

  group('LessonNote', () {
    test('isEmpty учитывает домашнее задание, пометку и отметку о выполнении', () {
      final LessonNote empty = LessonNote(lessonKey: 'k', updatedAt: DateTime(2026, 3, 16));
      expect(empty.isEmpty, isTrue);
      expect(empty.copyWith(homework: '§3').isEmpty, isFalse);
      expect(empty.copyWith(personalNote: 'взять конспект').isEmpty, isFalse);
      expect(empty.copyWith(homeworkDone: true).isEmpty, isFalse);
    });

    test('JSON round-trip', () {
      final LessonNote note = LessonNote(
        lessonKey: 'k',
        updatedAt: DateTime(2026, 3, 16, 12),
        homework: 'Задачи 1–5',
        personalNote: 'Уточнить срок',
        homeworkDone: true,
        subject: 'Математика',
        weekKey: '2026-W12',
      );
      final LessonNote? restored = LessonNote.tryParse(note.toJson());
      expect(restored, isNotNull);
      expect(restored!.homework, note.homework);
      expect(restored.personalNote, note.personalNote);
      expect(restored.homeworkDone, isTrue);
      expect(restored.weekKey, note.weekKey);
    });
  });

  group('ключ заметки', () {
    test('стабилен при одинаковых входных данных', () {
      final String first = buildLessonKey(
        weekKey: '2026-W12',
        entityType: 'teacher',
        entityName: 'Иванов И.И.',
        weekday: Weekday.monday,
        pairNumber: 1,
        subject: 'Математика',
      );
      final String second = buildLessonKey(
        weekKey: '2026-W12',
        entityType: 'teacher',
        entityName: 'иванов и.и.',
        weekday: Weekday.monday,
        pairNumber: 1,
        subject: 'математика',
      );
      expect(first, second);
      expect(first, contains('2026-W12'));
      expect(first, contains('математика'));
    });

    test('различается для разных пар', () {
      final String first = buildLessonKey(
        weekKey: '2026-W12',
        entityType: 'group',
        entityName: 'ИС-21',
        weekday: Weekday.monday,
        pairNumber: 1,
        subject: 'Математика',
      );
      final String second = buildLessonKey(
        weekKey: '2026-W12',
        entityType: 'group',
        entityName: 'ИС-21',
        weekday: Weekday.monday,
        pairNumber: 2,
        subject: 'Математика',
      );
      expect(first, isNot(second));
    });

    test('slugify убирает лишние символы', () {
      expect(slugify('  Математика  '), 'математика');
      expect(slugify('Физика и астрономия'), 'физика-и-астрономия');
    });
  });
}
