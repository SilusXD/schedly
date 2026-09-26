import 'package:flutter_test/flutter_test.dart';
import 'package:schedly/data/parser/schedule_merger.dart';
import 'package:schedly/domain/models/lesson.dart';
import 'package:schedly/domain/models/weekday.dart';

void main() {
  final ScheduleMerger merger = ScheduleMerger();

  const Lesson semesterLesson = Lesson(
    weekday: Weekday.monday,
    pairNumber: 2,
    subject: 'Основы информационной безопасности',
    timeStart: '10:10',
    timeEnd: '11:40',
    teacherName: 'Крымцева В. П.',
    groupName: '2ОИБАС-1825',
  );

  test('предмет и плановый преподаватель берутся из полугодового расписания', () {
    final List<Lesson> merged = merger.merge(
      semester: <Lesson>[semesterLesson],
      daily: const <Lesson>[
        Lesson(
          weekday: Weekday.monday,
          pairNumber: 2,
          subject: '',
          teacherName: 'Крымцева В. П.',
          groupName: '2ОИБАС-1825',
          room: 'ауд.316',
        ),
      ],
    );

    expect(merged.length, 1);
    expect(merged.first.subject, 'Основы информационной безопасности');
    expect(merged.first.room, 'ауд.316');
    expect(merged.first.teacherName, 'Крымцева В. П.');
    expect(merged.first.isReplacement, isFalse);
  });

  test('расхождение преподавателей помечается как замена', () {
    final List<Lesson> merged = merger.merge(
      semester: <Lesson>[semesterLesson],
      daily: const <Lesson>[
        Lesson(
          weekday: Weekday.monday,
          pairNumber: 2,
          subject: '',
          teacherName: 'Гущин П. А.',
          groupName: '2ОИБАС-1825',
          room: 'ауд.121',
        ),
      ],
    );

    expect(merged.first.isReplacement, isTrue);
    expect(merged.first.teacherName, 'Гущин П. А.');
    expect(merged.first.plannedTeacherName, 'Крымцева В. П.');
    expect(merged.first.subject, 'Основы информационной безопасности');
  });

  test('разное написание инициалов не считается заменой', () {
    final List<Lesson> merged = merger.merge(
      semester: <Lesson>[semesterLesson],
      daily: const <Lesson>[
        Lesson(
          weekday: Weekday.monday,
          pairNumber: 2,
          subject: '',
          teacherName: 'Крымцева В.П.',
          groupName: '2ОИБАС-1825',
        ),
      ],
    );

    expect(merged.first.isReplacement, isFalse);
  });

  test('занятие только из ежедневного расписания сохраняется', () {
    final List<Lesson> merged = merger.merge(
      semester: <Lesson>[semesterLesson],
      daily: const <Lesson>[
        Lesson(
          weekday: Weekday.friday,
          pairNumber: 3,
          subject: '',
          teacherName: 'Ковалевский М.В.',
          groupName: '2ОИБАС-1825',
          room: 'ауд.308',
        ),
      ],
    );

    expect(merged.length, 2);
    final Lesson extra = merged.firstWhere((Lesson l) => l.weekday == Weekday.friday);
    expect(extra.room, 'ауд.308');
    expect(extra.subject, isEmpty);
  });

  test('занятия разных групп не склеиваются', () {
    final List<Lesson> merged = merger.merge(
      semester: <Lesson>[semesterLesson],
      daily: const <Lesson>[
        Lesson(
          weekday: Weekday.monday,
          pairNumber: 2,
          subject: '',
          teacherName: 'Крымцева В. П.',
          groupName: '2ОИБАС-1925',
          room: 'ауд.317',
        ),
      ],
    );

    expect(merged.length, 2);
    expect(
      merged.map((Lesson l) => l.groupName).toSet(),
      <String>{'2ОИБАС-1825', '2ОИБАС-1925'},
    );
  });

  test('чётность недели сохраняется при слиянии', () {
    const Lesson numerator = Lesson(
      weekday: Weekday.wednesday,
      pairNumber: 3,
      subject: 'Иностранный язык профессиональной деятельности',
      teacherName: 'Лебедева Ю.В.',
      groupName: '2ОИБАС-1825',
      parity: WeekParity.numerator,
    );
    const Lesson denominator = Lesson(
      weekday: Weekday.wednesday,
      pairNumber: 3,
      subject: 'Иностранный язык профессиональной деятельности',
      teacherName: 'Князева К.М.',
      groupName: '2ОИБАС-1825',
      parity: WeekParity.denominator,
    );

    final List<Lesson> merged = merger.merge(
      semester: <Lesson>[numerator, denominator],
      daily: const <Lesson>[],
    );

    expect(merged.length, 2);
    expect(
      merged.map((Lesson l) => l.parity).toSet(),
      <WeekParity>{WeekParity.numerator, WeekParity.denominator},
    );
  });
}
