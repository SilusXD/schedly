import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/date_utils.dart';
import '../../data/cloud/cloud_storage.dart';
import '../../data/cloud/cloud_storage_factory.dart';
import '../state/schedule_controller.dart';
import 'diagnostics_screen.dart';

/// Экран настроек: ссылка на расписание, облачное хранилище, локальные данные.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _regionController = TextEditingController();
  final TextEditingController _bucketController = TextEditingController();
  final TextEditingController _accessKeyController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();
  final TextEditingController _basePathController = TextEditingController();

  CloudProviderType _provider = CloudProviderType.none;
  bool _usePathStyle = true;
  bool _autoSync = true;
  bool _autoRefresh = true;
  bool _isBusy = false;
  String _urlCheckResult = '';
  List<DateTime> _cachedDates = const <DateTime>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _urlController.dispose();
    _endpointController.dispose();
    _regionController.dispose();
    _bucketController.dispose();
    _accessKeyController.dispose();
    _secretController.dispose();
    _basePathController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ScheduleController controller = context.read<ScheduleController>();
    _urlController.text = controller.settings.urlTemplate(controller.config);
    _autoRefresh = controller.settings.autoRefresh();

    final CloudConfig cloud = await controller.settings.cloudConfig();
    final List<DateTime> dates = await controller.cachedDates();
    if (!mounted) {
      return;
    }
    setState(() {
      _provider = cloud.type;
      _endpointController.text = cloud.endpoint;
      _regionController.text = cloud.region;
      _bucketController.text = cloud.bucket;
      _accessKeyController.text = cloud.accessKey;
      _secretController.text = cloud.secretKey;
      _basePathController.text = cloud.basePath;
      _usePathStyle = cloud.usePathStyle;
      _autoSync = cloud.autoSync;
      _cachedDates = dates;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _isBusy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  void _show(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ScheduleController controller = context.watch<ScheduleController>();
    final CloudProviderHints hints = CloudProviderHints.forType(_provider);

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: <Widget>[
          if (_isBusy) const LinearProgressIndicator(minHeight: 2),
          _SectionTitle('Расписание'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Шаблон ссылки на PDF',
                      hintText: 'https://school.ru/schedule_{yyyy-MM-dd}.pdf',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Дата подставляется автоматически. Поддерживаются {yyyy}, {MM}, {dd}, '
                    '{yyyy-MM-dd}, {dd.MM.yyyy}, {dd-MM-yyyy}, {yyyyMMdd}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton(
                        onPressed: _isBusy
                            ? null
                            : () => _run(() async {
                                  await controller.settings
                                      .setUrlTemplate(_urlController.text);
                                  _show('Шаблон ссылки сохранён');
                                }),
                        child: const Text('Сохранить'),
                      ),
                      OutlinedButton(
                        onPressed: _isBusy
                            ? null
                            : () => _run(() async {
                                  final String result =
                                      await controller.checkUrl(_urlController.text);
                                  setState(() => _urlCheckResult = result);
                                }),
                        child: const Text('Проверить ссылку'),
                      ),
                    ],
                  ),
                  if (_urlCheckResult.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(_urlCheckResult, style: Theme.of(context).textTheme.bodySmall),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _autoRefresh,
                    title: const Text('Обновлять при запуске'),
                    subtitle: const Text('Скачивать расписание за сегодня при открытии'),
                    onChanged: (bool value) => _run(() async {
                      await controller.settings.setAutoRefresh(value);
                      setState(() => _autoRefresh = value);
                    }),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('Облачное хранилище'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    controller.cloudStatus,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<CloudProviderType>(
                    initialValue: _provider,
                    decoration: const InputDecoration(labelText: 'Хранилище'),
                    items: CloudProviderType.values
                        .map(
                          (CloudProviderType type) => DropdownMenuItem<CloudProviderType>(
                            value: type,
                            child: Text(type.title, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (CloudProviderType? value) {
                      if (value != null) {
                        setState(() => _provider = value);
                      }
                    },
                  ),
                  if (_provider != CloudProviderType.none) ...<Widget>[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _endpointController,
                      decoration: InputDecoration(
                        labelText: 'Адрес сервера',
                        hintText: hints.endpointExample,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_provider == CloudProviderType.s3) ...<Widget>[
                      TextField(
                        controller: _bucketController,
                        decoration: const InputDecoration(labelText: 'Бакет (bucket)'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _regionController,
                        decoration: InputDecoration(
                          labelText: 'Регион',
                          hintText: hints.regionExample,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    TextField(
                      controller: _accessKeyController,
                      decoration: InputDecoration(labelText: hints.accessKeyLabel),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _secretController,
                      obscureText: true,
                      decoration: InputDecoration(labelText: hints.secretKeyLabel),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _basePathController,
                      decoration: const InputDecoration(
                        labelText: 'Папка в хранилище',
                        hintText: 'schedly',
                      ),
                    ),
                    if (_provider == CloudProviderType.s3)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _usePathStyle,
                        title: const Text('Адресация path-style'),
                        subtitle: const Text('Нужна для MinIO и Yandex Object Storage'),
                        onChanged: (bool value) => setState(() => _usePathStyle = value),
                      ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _autoSync,
                      title: const Text('Автоматически выгружать расписание'),
                      onChanged: (bool value) => setState(() => _autoSync = value),
                    ),
                    const SizedBox(height: 4),
                    ...hints.notes.map(
                      (String note) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Text('• '),
                            Expanded(
                              child: Text(
                                note,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton(
                          onPressed: _isBusy ? null : _saveCloud,
                          child: const Text('Сохранить облако'),
                        ),
                        OutlinedButton(
                          onPressed: _isBusy ? null : _syncToCloud,
                          child: const Text('Выгрузить сейчас'),
                        ),
                        OutlinedButton(
                          onPressed: _isBusy ? null : _syncFromCloud,
                          child: const Text('Загрузить из облака'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('Локальные данные'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _cachedDates.isEmpty
                        ? 'Сохранённых расписаний нет.'
                        : 'Сохранены расписания: '
                            '${_cachedDates.map(formatIsoDate).join(', ')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _isBusy
                        ? null
                        : () => _run(() async {
                              await controller.clearCache();
                              final List<DateTime> dates = await controller.cachedDates();
                              setState(() => _cachedDates = dates);
                              _show('Кэш расписаний очищен');
                            }),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Очистить кэш расписаний'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Домашние задания и пометки хранятся отдельно и не удаляются.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('Диагностика'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Журнал и исходный текст PDF'),
              subtitle: const Text('Помогает понять, почему расписание не разобралось'),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => const DiagnosticsScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveCloud() => _run(() async {
        final ScheduleController controller = context.read<ScheduleController>();
        final CloudConfig config = CloudConfig(
          type: _provider,
          endpoint: _endpointController.text.trim(),
          region: _regionController.text.trim(),
          bucket: _bucketController.text.trim(),
          accessKey: _accessKeyController.text.trim(),
          secretKey: _secretController.text,
          basePath: _basePathController.text.trim().isEmpty
              ? 'schedly'
              : _basePathController.text.trim(),
          usePathStyle: _usePathStyle,
          autoSync: _autoSync,
        );
        await controller.settings.saveCloudConfig(config);
        await controller.reloadCloud();
        _show(config.isConfigured
            ? 'Настройки облака сохранены'
            : 'Настройки сохранены, но заполнены не полностью');
      });

  Future<void> _syncToCloud() => _run(() async {
        final ScheduleController controller = context.read<ScheduleController>();
        await controller.syncToCloud();
        _show(controller.statusMessage ?? 'Готово');
      });

  Future<void> _syncFromCloud() => _run(() async {
        final ScheduleController controller = context.read<ScheduleController>();
        await controller.syncFromCloud();
        _show(controller.statusMessage ?? 'Готово');
      });
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
