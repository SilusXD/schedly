/// Конфигурация приложения, переопределяемая при сборке через `--dart-define`.
///
/// Значения по умолчанию рассчитаны на работу «из коробки» в демонстрационном
/// режиме; рабочий шаблон ссылки на PDF пользователь задаёт на экране настроек
/// (он сохраняется в локальном хранилище и перекрывает [scheduleUrlTemplate]).
library;

/// Настройки, которые нельзя менять из интерфейса (задаются при сборке).
class AppConfig {
  const AppConfig({
    this.scheduleUrlTemplate = defaultScheduleUrlTemplate,
    this.schedulePageUrl = defaultSchedulePageUrl,
    this.fallbackDaysBack = 6,
    this.futureDaysForward = 0,
    this.downloadTimeout = const Duration(seconds: 30),
    this.headTimeout = const Duration(seconds: 12),
    this.maxDownloadAttempts = 3,
    this.initialRetryDelay = const Duration(milliseconds: 500),
    this.cloudFolder = 'schedules',
    this.rawPdfFolder = 'raw',
    this.maxCacheFiles = 14,
    this.logBufferSize = 400,
  });

  /// Значение по умолчанию для шаблона ссылки.
  ///
  /// Намеренно указывает на `example.com`: приложение не должно «угадывать»
  /// адрес учебного заведения. Реальный шаблон задаётся в настройках.
  static const String defaultScheduleUrlTemplate =
      'https://example.com/schedule_{yyyy-MM-dd}.pdf';

  /// Адрес страницы-каталога расписаний по умолчанию (КИП Фин.университета).
  ///
  /// Со страницы берутся ссылки на ежедневное «общее» расписание и на
  /// полугодовые файлы по курсам: имя файла содержит случайный хеш, поэтому
  /// собрать ссылку по шаблону с датой невозможно.
  static const String defaultSchedulePageUrl =
      'https://www.fa.ru/kip/students/schedule.php';

  /// Сколько часов считается «свежим» кэш полугодового расписания.
  static const int semesterCacheHours = 24;

  /// Шаблон ссылки на PDF (используется, когда страница-каталог не задана).
  final String scheduleUrlTemplate;

  /// Адрес страницы-каталога расписаний. Пустая строка отключает режим
  /// страницы и возвращает работу по шаблону с датой.
  final String schedulePageUrl;

  /// Сколько дней назад разрешено искать актуальный PDF, если за сегодня его нет.
  final int fallbackDaysBack;

  /// Сколько дней вперёд проверять (обычно 0 — будущих файлов не бывает).
  final int futureDaysForward;

  /// Таймаут скачивания PDF целиком.
  final Duration downloadTimeout;

  /// Таймаут проверочного HEAD-запроса.
  final Duration headTimeout;

  /// Сколько всего попыток скачивания (включая первую).
  final int maxDownloadAttempts;

  /// Базовая задержка перед повтором; далее растёт экспоненциально.
  final Duration initialRetryDelay;

  /// Папка в облачном хранилище для распарсенных JSON.
  final String cloudFolder;

  /// Папка в облачном хранилище для исходных PDF.
  final String rawPdfFolder;

  /// Сколько последних расписаний хранить в локальном кэше.
  final int maxCacheFiles;

  /// Сколько записей журнала держать в памяти для экрана диагностики.
  final int logBufferSize;

  /// Конфигурация, собранная из переменных окружения сборки.
  ///
  /// Поддерживаемые `--dart-define`:
  /// * `SCHEDULE_URL_TEMPLATE` — шаблон ссылки на PDF;
  /// * `CLOUD_FOLDER` — папка расписаний в облаке;
  /// * `FALLBACK_DAYS_BACK` — глубина поиска назад в днях.
  factory AppConfig.fromEnvironment() {
    const String urlTemplate = String.fromEnvironment(
      'SCHEDULE_URL_TEMPLATE',
      defaultValue: AppConfig.defaultScheduleUrlTemplate,
    );
    const String cloudFolder = String.fromEnvironment(
      'CLOUD_FOLDER',
      defaultValue: 'schedules',
    );
    const String pageUrl = String.fromEnvironment(
      'SCHEDULE_PAGE_URL',
      defaultValue: AppConfig.defaultSchedulePageUrl,
    );
    const int fallbackDays = int.fromEnvironment('FALLBACK_DAYS_BACK', defaultValue: 6);

    return AppConfig(
      scheduleUrlTemplate: urlTemplate.trim().isEmpty
          ? AppConfig.defaultScheduleUrlTemplate
          : urlTemplate.trim(),
      schedulePageUrl: pageUrl.trim(),
      cloudFolder: cloudFolder.trim().isEmpty ? 'schedules' : cloudFolder.trim(),
      fallbackDaysBack: fallbackDays < 0 ? 0 : fallbackDays,
    );
  }

  AppConfig copyWith({
    String? scheduleUrlTemplate,
    String? schedulePageUrl,
    int? fallbackDaysBack,
    int? futureDaysForward,
    Duration? downloadTimeout,
    Duration? headTimeout,
    int? maxDownloadAttempts,
    Duration? initialRetryDelay,
    String? cloudFolder,
    String? rawPdfFolder,
    int? maxCacheFiles,
    int? logBufferSize,
  }) {
    return AppConfig(
      scheduleUrlTemplate: scheduleUrlTemplate ?? this.scheduleUrlTemplate,
      schedulePageUrl: schedulePageUrl ?? this.schedulePageUrl,
      fallbackDaysBack: fallbackDaysBack ?? this.fallbackDaysBack,
      futureDaysForward: futureDaysForward ?? this.futureDaysForward,
      downloadTimeout: downloadTimeout ?? this.downloadTimeout,
      headTimeout: headTimeout ?? this.headTimeout,
      maxDownloadAttempts: maxDownloadAttempts ?? this.maxDownloadAttempts,
      initialRetryDelay: initialRetryDelay ?? this.initialRetryDelay,
      cloudFolder: cloudFolder ?? this.cloudFolder,
      rawPdfFolder: rawPdfFolder ?? this.rawPdfFolder,
      maxCacheFiles: maxCacheFiles ?? this.maxCacheFiles,
      logBufferSize: logBufferSize ?? this.logBufferSize,
    );
  }
}
