import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/app_config.dart';
import '../../core/app_logger.dart';
import '../cloud/cloud_storage.dart';
import 'local_storage.dart';

/// Настройки приложения: шаблон ссылки на расписание и параметры облака.
///
/// Не секретные значения хранятся в Hive, а пароли и секретные ключи — в
/// защищённом хранилище iOS Keychain ([FlutterSecureStorage]). Это важно:
/// локальная база лежит в открытом виде внутри контейнера приложения.
class SettingsStore {
  SettingsStore(
    this._storage, {
    FlutterSecureStorage? secureStorage,
    AppLogger? logger,
  })  : _secure = secureStorage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            ),
        _logger = logger ?? appLogger;

  final LocalStorage _storage;
  final FlutterSecureStorage _secure;
  final AppLogger _logger;

  static const String _urlTemplateKey = 'scheduleUrlTemplate';
  static const String _pageUrlKey = 'schedulePageUrl';
  static const String _cloudConfigKey = 'cloudConfig';
  static const String _lastSyncKey = 'lastCloudSyncAt';
  static const String _autoRefreshKey = 'autoRefreshEnabled';
  static const String _myGroupKey = 'myGroup';

  /// Ключ в Keychain, под которым лежит секрет облака.
  static const String cloudSecretStorageKey = 'schedly.cloud.secret';

  /// Шаблон ссылки на PDF расписания.
  String urlTemplate(AppConfig fallback) {
    final String? value = _storage.settings.get(_urlTemplateKey);
    if (value == null || value.trim().isEmpty) {
      return fallback.scheduleUrlTemplate;
    }
    return value;
  }

  /// Сохраняет шаблон ссылки.
  Future<void> setUrlTemplate(String template) async {
    await _storage.settings.put(_urlTemplateKey, template.trim());
    _logger.info('Шаблон ссылки обновлён: ${template.trim()}');
  }

  /// Адрес страницы-каталога расписаний.
  ///
  /// Если адрес задан, приложение берёт ссылки со страницы (ежедневное
  /// «общее» расписание и полугодовые файлы), а шаблон с датой не используется.
  String pageUrl(AppConfig fallback) {
    final String? value = _storage.settings.get(_pageUrlKey);
    if (value == null) {
      return fallback.schedulePageUrl;
    }
    return value.trim();
  }

  /// Сохраняет адрес страницы-каталога.
  Future<void> setPageUrl(String url) async {
    await _storage.settings.put(_pageUrlKey, url.trim());
    _logger.info('Адрес страницы расписания: ${url.trim()}');
  }

  /// Группа пользователя (нужна для выбора полугодового расписания).
  String myGroup() => _storage.settings.get(_myGroupKey)?.trim() ?? '';

  /// Сохраняет группу пользователя.
  Future<void> setMyGroup(String group) async {
    await _storage.settings.put(_myGroupKey, group.trim());
    _logger.info('Выбрана группа: ${group.trim()}');
  }

  /// Включено ли автоматическое обновление при запуске.
  bool autoRefresh() => _storage.settings.get(_autoRefreshKey) != 'false';

  /// Включает/выключает автоматическое обновление.
  Future<void> setAutoRefresh(bool enabled) =>
      _storage.settings.put(_autoRefreshKey, enabled ? 'true' : 'false');

  /// Время последней успешной синхронизации с облаком.
  DateTime? lastCloudSync() {
    final String? raw = _storage.settings.get(_lastSyncKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// Запоминает время успешной синхронизации.
  Future<void> setLastCloudSync(DateTime time) =>
      _storage.settings.put(_lastSyncKey, time.toIso8601String());

  /// Настройки облака вместе с секретом.
  Future<CloudConfig> cloudConfig() async {
    CloudConfig config = const CloudConfig();
    final String? raw = _storage.settings.get(_cloudConfigKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          config = CloudConfig.fromJson(Map<String, dynamic>.from(decoded));
        }
      } on FormatException catch (error) {
        _logger.warning('Настройки облака повреждены, используются значения по умолчанию', error);
      }
    }

    String secret = '';
    try {
      secret = await _secure.read(key: cloudSecretStorageKey) ?? '';
    } on Object catch (error) {
      _logger.warning('Не удалось прочитать секрет облака из Keychain', error);
    }

    return config.copyWith(secretKey: secret);
  }

  /// Сохраняет настройки облака; секрет уходит в Keychain.
  Future<void> saveCloudConfig(CloudConfig config) async {
    await _storage.settings.put(_cloudConfigKey, jsonEncode(config.toJson()));
    try {
      if (config.secretKey.isEmpty) {
        await _secure.delete(key: cloudSecretStorageKey);
      } else {
        await _secure.write(key: cloudSecretStorageKey, value: config.secretKey);
      }
    } on Object catch (error) {
      _logger.error('Не удалось сохранить секрет облака в Keychain', error);
      rethrow;
    }
    _logger.info('Настройки облака сохранены: $config');
  }

  /// Удаляет настройки облака и секрет.
  Future<void> clearCloudConfig() async {
    await _storage.settings.delete(_cloudConfigKey);
    try {
      await _secure.delete(key: cloudSecretStorageKey);
    } on Object catch (error) {
      _logger.warning('Не удалось удалить секрет облака', error);
    }
  }
}
