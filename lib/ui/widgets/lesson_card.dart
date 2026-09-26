import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/models/lesson.dart';
import '../../domain/models/lesson_note.dart';

/// Карточка одной пары в дневнике.
///
/// Внутри — номер пары, время, предмет, аудитория, а также поля для домашнего
/// задания и личных пометок. Домашнее задание сохраняется автоматически с
/// небольшой задержкой, чтобы не писать в базу на каждое нажатие клавиши.
class LessonCard extends StatefulWidget {
  const LessonCard({
    super.key,
    required this.lesson,
    required this.note,
    required this.onHomeworkChanged,
    required this.onNoteChanged,
    required this.onDoneChanged,
    this.showTeacher = true,
    this.showGroup = false,
  });

  /// Занятие.
  final Lesson lesson;

  /// Сохранённая заметка (может быть `null`).
  final LessonNote? note;

  /// Сохранение домашнего задания.
  final ValueChanged<String> onHomeworkChanged;

  /// Сохранение личной пометки.
  final ValueChanged<String> onNoteChanged;

  /// Переключение отметки «выполнено».
  final ValueChanged<bool> onDoneChanged;

  /// Показывать ли преподавателя (на вкладке групп — да).
  final bool showTeacher;

  /// Показывать ли группу (на вкладке преподавателей — да).
  final bool showGroup;

  @override
  State<LessonCard> createState() => _LessonCardState();
}

class _LessonCardState extends State<LessonCard> {
  late final TextEditingController _homeworkController =
      TextEditingController(text: widget.note?.homework ?? '');
  Timer? _debounce;
  String _savedHomework = '';

  @override
  void initState() {
    super.initState();
    _savedHomework = widget.note?.homework ?? '';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // Досохраняем то, что пользователь не успел «дописать» до ухода с экрана.
    if (_homeworkController.text != _savedHomework) {
      widget.onHomeworkChanged(_homeworkController.text);
    }
    _homeworkController.dispose();
    super.dispose();
  }

  void _onHomeworkChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () {
      _savedHomework = value;
      widget.onHomeworkChanged(value);
    });
  }

  Future<void> _editPersonalNote() async {
    final TextEditingController controller =
        TextEditingController(text: widget.note?.personalNote ?? '');
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Личная пометка'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: 'Например: взять конспект, сдать долг по теме 3',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null) {
      widget.onNoteChanged(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final LessonNote? note = widget.note;
    final bool hasNote = (note?.personalNote ?? '').isNotEmpty;
    final bool done = note?.homeworkDone ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _PairBadge(pairNumber: widget.lesson.pairNumber),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.lesson.subject.isEmpty
                            ? 'Занятие не указано'
                            : widget.lesson.subject,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          decoration: done ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.lesson.timeRange.isEmpty
                            ? 'Время не указано'
                            : widget.lesson.timeRange,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Личная пометка',
                  visualDensity: VisualDensity.compact,
                  onPressed: _editPersonalNote,
                  icon: Icon(
                    hasNote ? Icons.sticky_note_2 : Icons.sticky_note_2_outlined,
                    size: 20,
                    color: hasNote ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (_metaLine().isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _metaLine(),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _homeworkController,
              onChanged: _onHomeworkChanged,
              maxLines: 4,
              minLines: 1,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: 'Домашнее задание',
                isDense: true,
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                prefixIcon: IconButton(
                  tooltip: done ? 'Отметить как невыполненное' : 'Отметить как выполненное',
                  onPressed: () => widget.onDoneChanged(!done),
                  icon: Icon(
                    done ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 20,
                    color: done ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (hasNote) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                note!.personalNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _metaLine() {
    final List<Widget> chips = <Widget>[];
    if (widget.lesson.room.isNotEmpty) {
      chips.add(_MetaChip(icon: Icons.meeting_room_outlined, text: widget.lesson.room));
    }
    if (widget.showTeacher && widget.lesson.teacherName.isNotEmpty) {
      chips.add(_MetaChip(icon: Icons.person_outline, text: widget.lesson.teacherName));
    }
    if (widget.showGroup && widget.lesson.groupName.isNotEmpty) {
      chips.add(_MetaChip(icon: Icons.groups_outlined, text: widget.lesson.groupName));
    }
    if (widget.lesson.subgroup.isNotEmpty) {
      chips.add(_MetaChip(icon: Icons.call_split, text: widget.lesson.subgroup));
    }
    // Обозначения группы бывают перечислены через запятую — показываем их
    // отдельно, чтобы карточка читалась как в расписании.
    if (widget.lesson.parity != WeekParity.both) {
      chips.add(_MetaChip(
        icon: Icons.event_repeat_outlined,
        text: widget.lesson.parity == WeekParity.numerator
            ? 'нечётная неделя'
            : 'чётная неделя',
      ));
    }
    if (widget.lesson.isReplacement) {
      chips.add(_MetaChip(
        icon: Icons.swap_horiz,
        text: widget.lesson.plannedTeacherName.isEmpty
            ? 'замена'
            : 'замена (по плану: ${widget.lesson.plannedTeacherName})',
        highlight: true,
      ));
    }
    return chips;
  }
}

class _PairBadge extends StatelessWidget {
  const _PairBadge({required this.pairNumber});

  final int pairNumber;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (pairNumber <= 0) {
      return const SizedBox(width: 4);
    }
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$pairNumber',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.text, this.highlight = false});

  final IconData icon;
  final String text;

  /// Выделить чип цветом (используется для замены).
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background =
        highlight ? scheme.tertiaryContainer : scheme.surfaceContainerHighest;
    final Color foreground =
        highlight ? scheme.onTertiaryContainer : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: foreground),
          const SizedBox(width: 4),
          Text(
            text,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}
