import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/date_utils.dart';
import '../../domain/models/schedule.dart';
import '../state/schedule_controller.dart';
import '../widgets/diary_columns.dart';
import '../widgets/offline_banner.dart';

/// Экран расписания одной сущности в виде дневника.
class EntityScheduleScreen extends StatelessWidget {
  const EntityScheduleScreen({
    super.key,
    required this.entityType,
    required this.entityName,
  });

  /// Тип сущности.
  final ScheduleEntityType entityType;

  /// Имя сущности.
  final String entityName;

  @override
  Widget build(BuildContext context) {
    final ScheduleController controller = context.watch<ScheduleController>();
    final EntitySchedule? entity = controller.entityOf(entityType, entityName);
    final DateTime? date = controller.schedule?.scheduleDate;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(entityName, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              date == null
                  ? entityType.singularTitle
                  : '${dateOnly(date) == dateOnly(DateTime.now()) ? 'Сегодня, ' : ''}'
                      '${formatRussianDate(date)} · занятий: ${entity?.lessonCount ?? 0}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          OfflineBanner(
            isVisible: controller.isOfflineData || !controller.isOnline,
            isStale: controller.isStale,
          ),
          Expanded(
            child: entity == null
                ? const _NoEntityData()
                : DiaryColumns(
                    controller: controller,
                    entityType: entityType,
                    entityName: entityName,
                  ),
          ),
        ],
      ),
    );
  }
}

class _NoEntityData extends StatelessWidget {
  const _NoEntityData();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Для этой записи нет занятий в текущем расписании.\n'
          'Обновите расписание на главном экране.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
