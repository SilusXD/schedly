import 'package:flutter/material.dart';

import '../../core/date_utils.dart';
import '../../domain/models/lesson.dart';
import '../../domain/models/schedule.dart';
import '../../domain/models/weekday.dart';
import '../state/schedule_controller.dart';
import 'lesson_card.dart';

/// Двухколоночная сетка дневника: слева Пн–Ср, справа Чт–Сб.
///
/// Такая раскладка повторяет бумажный школьный дневник и позволяет видеть всю
/// неделю без прокрутки по горизонтали.
class DiaryColumns extends StatelessWidget {
  const DiaryColumns({
    super.key,
    required this.controller,
    required this.entityType,
    required this.entityName,
  });

  /// Состояние приложения.
  final ScheduleController controller;

  /// Тип сущности (преподаватель или группа).
  final ScheduleEntityType entityType;

  /// Имя преподавателя или название группы.
  final String entityName;

  @override
  Widget build(BuildContext context) {
    final EntitySchedule? entity = controller.entityOf(entityType, entityName);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: _DiaryColumn(
              days: Weekday.firstColumn,
              controller: controller,
              entityType: entityType,
              entityName: entityName,
              entity: entity,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _DiaryColumn(
              days: Weekday.secondColumn,
              controller: controller,
              entityType: entityType,
              entityName: entityName,
              entity: entity,
            ),
          ),
        ],
      ),
    );
  }
}

class _DiaryColumn extends StatelessWidget {
  const _DiaryColumn({
    required this.days,
    required this.controller,
    required this.entityType,
    required this.entityName,
    required this.entity,
  });

  final List<Weekday> days;
  final ScheduleController controller;
  final ScheduleEntityType entityType;
  final String entityName;
  final EntitySchedule? entity;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: days
          .map(
            (Weekday day) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _DaySection(
                weekday: day,
                lessons: entity?.lessonsFor(day) ?? const <Lesson>[],
                controller: controller,
                entityType: entityType,
                entityName: entityName,
              ),
            ),
          )
          .toList(),
    );
  }
}

class _DaySection extends StatelessWidget {
  const _DaySection({
    required this.weekday,
    required this.lessons,
    required this.controller,
    required this.entityType,
    required this.entityName,
  });

  final Weekday weekday;
  final List<Lesson> lessons;
  final ScheduleController controller;
  final ScheduleEntityType entityType;
  final String entityName;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  weekday.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_dateLabel() != null)
                Text(
                  _dateLabel()!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        if (lessons.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Text(
              'Занятий нет',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          ...lessons.map(
            (Lesson lesson) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LessonCard(
                key: ValueKey<String>(
                  controller.lessonKey(
                    entityType: entityType,
                    entityName: entityName,
                    lesson: lesson,
                  ),
                ),
                lesson: lesson,
                note: controller.noteFor(
                  entityType: entityType,
                  entityName: entityName,
                  lesson: lesson,
                ),
                showTeacher: entityType != ScheduleEntityType.group,
                showGroup: entityType == ScheduleEntityType.group,
                onHomeworkChanged: (String value) => controller.saveNote(
                  entityType: entityType,
                  entityName: entityName,
                  lesson: lesson,
                  homework: value,
                ),
                onNoteChanged: (String value) => controller.saveNote(
                  entityType: entityType,
                  entityName: entityName,
                  lesson: lesson,
                  personalNote: value,
                ),
                onDoneChanged: (bool value) => controller.saveNote(
                  entityType: entityType,
                  entityName: entityName,
                  lesson: lesson,
                  homeworkDone: value,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Дата конкретного дня недели (если известно расписание на неделю).
  String? _dateLabel() {
    final DateTime? weekStart = controller.schedule?.weekStart;
    if (weekStart == null) {
      return null;
    }
    final DateTime date = weekStart.add(Duration(days: weekday.isoNumber - 1));
    return formatRussianDayMonth(date);
  }
}
