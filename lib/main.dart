import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_config.dart';
import 'core/app_logger.dart';
import 'data/local/local_storage.dart';
import 'data/local/notes_store.dart';
import 'data/local/schedule_cache.dart';
import 'data/local/settings_store.dart';
import 'data/parser/schedule_parser.dart';
import 'data/pdf/pdf_text_extractor_factory.dart';
import 'data/remote/schedule_pdf_source.dart';
import 'data/repositories/offline_first_schedule_repository.dart';
import 'ui/state/schedule_controller.dart';

/// Точка входа приложения.
///
/// Зависимости собираются вручную: проект небольшой, и явная сборка читается
/// лучше, чем скрытая магия DI-контейнера.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final AppLogger logger = appLogger;
  final AppConfig config = AppConfig.fromEnvironment();

  try {
    final LocalStorage storage = LocalStorage(logger: logger);
    await storage.init();

    final SettingsStore settings = SettingsStore(storage, logger: logger);
    final ScheduleCache cache = ScheduleCache(storage, logger: logger);
    final NotesStore notes = NotesStore(storage, logger: logger);

    final SchedulePdfSource pdfSource = SchedulePdfSource(config: config, logger: logger);
    final OfflineFirstScheduleRepository repository = OfflineFirstScheduleRepository(
      config: config,
      cache: cache,
      notes: notes,
      settings: settings,
      pdfSource: pdfSource,
      extractor: createPdfTextExtractor(logger: logger),
      parser: ScheduleParser(logger: logger),
      logger: logger,
    );
    await repository.reloadCloudStorage();

    final ScheduleController controller = ScheduleController(
      repository: repository,
      settings: settings,
      config: config,
      logger: logger,
    );

    logger.info('Приложение запущено. Шаблон ссылки: ${settings.urlTemplate(config)}');
    runApp(SchedlyApp(controller: controller));
  } on Object catch (error, stackTrace) {
    logger.error('Критическая ошибка запуска: $error');
    debugPrint('$stackTrace');
    runApp(StartupErrorApp(message: error.toString()));
  }
}
