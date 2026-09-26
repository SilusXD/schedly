import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/date_utils.dart';
import '../../domain/models/schedule.dart';
import '../state/schedule_controller.dart';
import '../widgets/offline_banner.dart';
import 'diagnostics_screen.dart';
import 'entity_schedule_screen.dart';
import 'settings_screen.dart';

/// Главный экран: вкладки «Преподаватели» и «Группы» с поиском.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 2, vsync: this);
  final TextEditingController _searchController = TextEditingController();
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        return;
      }
      context
          .read<ScheduleController>()
          .setTab(ScheduleEntityType.values[_tabController.index]);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await context.read<ScheduleController>().initialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ScheduleController controller = context.watch<ScheduleController>();
    final List<String> names = controller.visibleNames;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Дневник расписания'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Обновить расписание',
            onPressed: controller.isLoading ? null : () => controller.refresh(),
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: 'Ещё',
            onSelected: (String value) {
              switch (value) {
                case 'diagnostics':
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => const DiagnosticsScreen(),
                    ),
                  );
                case 'settings':
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => const SettingsScreen(),
                    ),
                  );
              }
            },
            itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'diagnostics',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.bug_report_outlined),
                  title: Text('Диагностика'),
                ),
              ),
              PopupMenuItem<String>(
                value: 'settings',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.settings_outlined),
                  title: Text('Настройки'),
                ),
              ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const <Widget>[
            Tab(text: 'Преподаватели'),
            Tab(text: 'Группы'),
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          OfflineBanner(
            isVisible: controller.isOfflineData || !controller.isOnline,
            isStale: controller.isStale,
            message: controller.isOfflineData ? controller.result?.message : null,
          ),
          if (controller.isLoading) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              controller: _searchController,
              onChanged: controller.setQuery,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Поиск',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: controller.query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Очистить',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          controller.setQuery('');
                        },
                      ),
              ),
            ),
          ),
          if (controller.statusMessage != null && controller.statusMessage!.isNotEmpty)
            _StatusLine(
              message: controller.statusMessage!,
              onDismiss: controller.clearStatus,
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => controller.refresh(),
              child: _buildBody(context, controller, names),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ScheduleController controller,
    List<String> names,
  ) {
    if (controller.schedule == null) {
      return _EmptyState(controller: controller);
    }
    if (names.isEmpty) {
      return ListView(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              controller.query.isEmpty
                  ? 'В расписании нет данных для этой вкладки.'
                  : 'Ничего не найдено по запросу «${controller.query}».',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      );
    }

    final ScheduleEntityType type = controller.tab;
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: names.length,
      separatorBuilder: (BuildContext context, int index) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final String name = names[index];
        final EntitySchedule? entity = controller.entityOf(type, name);
        final int lessonCount = entity?.lessonCount ?? 0;
        return ListTile(
          title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            lessonCount == 0
                ? 'Нет занятий'
                : 'Занятий: $lessonCount · ${_dayList(entity)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => EntityScheduleScreen(
                entityType: type,
                entityName: name,
              ),
            ),
          ),
        );
      },
    );
  }

  static String _dayList(EntitySchedule? entity) {
    if (entity == null || entity.lessons.isEmpty) {
      return '';
    }
    final List<String> days = entity.activeWeekdays
        .map((dynamic day) => day.shortTitle as String)
        .toList();
    return days.join(', ');
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 4, 4),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          IconButton(
            tooltip: 'Скрыть',
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.controller});

  final ScheduleController controller;

  @override
  Widget build(BuildContext context) {
    final List<String> details = controller.result?.errorDetails ?? const <String>[];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        const SizedBox(height: 40),
        Icon(
          Icons.event_busy_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          controller.result?.message ?? 'Расписание недоступно',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Проверьте ссылку на PDF в настройках и повторите попытку. '
          'Последнее сохранённое расписание: '
          '${controller.schedule == null ? 'нет' : formatRussianDate(controller.schedule!.scheduleDate)}.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (details.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: details
                    .map(
                      (String line) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $line', style: Theme.of(context).textTheme.bodySmall),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: controller.isLoading ? null : () => controller.refresh(),
          icon: const Icon(Icons.refresh),
          label: const Text('Повторить загрузку'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => const SettingsScreen(),
            ),
          ),
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Открыть настройки'),
        ),
      ],
    );
  }
}
