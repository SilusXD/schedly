import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_logger.dart';
import '../../core/date_utils.dart';
import '../../domain/models/schedule.dart';
import '../state/schedule_controller.dart';

/// Экран диагностики.
///
/// На iPhone без Mac нет удобного доступа к системному логу, поэтому приложение
/// держит собственный журнал, а также показывает извлечённый из PDF текст и
/// предупреждения парсера — именно они нужны, чтобы понять, почему расписание
/// не разобралось.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  void Function()? _unsubscribe;
  bool _showRawText = false;

  @override
  void initState() {
    super.initState();
    _unsubscribe = appLogger.addListener((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ScheduleController controller = context.watch<ScheduleController>();
    final ParsedSchedule? schedule = controller.schedule;
    final List<String> warnings = schedule?.warnings ?? const <String>[];
    final String? rawText = schedule?.rawText;
    final List<LogEntry> entries = appLogger.entries.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Диагностика'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Очистить журнал',
            onPressed: () => setState(appLogger.clear),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Состояние', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  _KeyValue('Источник данных', controller.result?.source.title ?? '—'),
                  _KeyValue(
                    'Дата расписания',
                    schedule == null ? '—' : formatRussianDate(schedule.scheduleDate),
                  ),
                  _KeyValue(
                    'Разобрано',
                    schedule == null ? '—' : schedule.parsedAt.toLocal().toString(),
                  ),
                  _KeyValue('Версия парсера', schedule?.parserVersion ?? '—'),
                  _KeyValue('Занятий', '${schedule?.lessonCount ?? 0}'),
                  _KeyValue(
                    'Преподавателей / групп',
                    '${schedule?.teachers.length ?? 0} / ${schedule?.groups.length ?? 0}',
                  ),
                  _KeyValue('Ссылка', schedule?.sourceUrl ?? '—'),
                  _KeyValue('Облако', controller.cloudStatus),
                ],
              ),
            ),
          ),
          if (controller.result?.errorDetails.isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Причины сбоя', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 6),
                    ...controller.result!.errorDetails.map(
                      (String line) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $line',
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Предупреждения парсера',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  if (warnings.isEmpty)
                    Text('Нет', style: Theme.of(context).textTheme.bodySmall)
                  else
                    ...warnings.map(
                      (String line) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $line',
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.text_snippet_outlined),
                  title: const Text('Извлечённый текст PDF'),
                  subtitle: Text(
                    rawText == null || rawText.isEmpty
                        ? 'Нет данных — расписание ещё не разбиралось'
                        : '${rawText.length} символов',
                  ),
                  trailing: IconButton(
                    tooltip: 'Скопировать',
                    onPressed: rawText == null || rawText.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(ClipboardData(text: rawText));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Текст скопирован')),
                              );
                            }
                          },
                    icon: const Icon(Icons.copy_all_outlined),
                  ),
                ),
                if (rawText != null && rawText.isNotEmpty) ...<Widget>[
                  const Divider(height: 1),
                  TextButton(
                    onPressed: () => setState(() => _showRawText = !_showRawText),
                    child: Text(_showRawText ? 'Скрыть текст' : 'Показать текст'),
                  ),
                  if (_showRawText)
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 380),
                      padding: const EdgeInsets.all(12),
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: SingleChildScrollView(
                        child: SelectableText(
                          rawText,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Журнал (${entries.length})',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  if (entries.isEmpty)
                    Text('Пока пусто', style: Theme.of(context).textTheme.bodySmall)
                  else
                    ...entries.take(200).map(
                          (LogEntry entry) => Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              entry.formatted,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: switch (entry.level) {
                                  LogLevel.error =>
                                    Theme.of(context).colorScheme.error,
                                  LogLevel.warning => Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  _ => null,
                                },
                              ),
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 150,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
