import '../../core/app_logger.dart';
import '../remote/http_client.dart';
import 'cloud_storage.dart';
import 's3_cloud_storage.dart';
import 'webdav_cloud_storage.dart';

/// Создаёт реализацию облачного хранилища по настройкам.
///
/// Возвращает `null`, если синхронизация отключена или настройки неполные:
/// приложение обязано работать и без облака (offline-first).
CloudStorage? createCloudStorage(
  CloudConfig config, {
  AppLogger? logger,
  RetryHttpClient? httpClient,
}) {
  if (!config.isConfigured) {
    (logger ?? appLogger).debug('Облачное хранилище не настроено — синхронизация отключена');
    return null;
  }

  switch (config.type) {
    case CloudProviderType.none:
      return null;
    case CloudProviderType.webdav:
      return WebDavCloudStorage(
        config: config,
        client: httpClient,
        logger: logger,
      );
    case CloudProviderType.s3:
      return S3CloudStorage(
        config: config,
        client: httpClient,
        logger: logger,
      );
  }
}

/// Подсказки для заполнения настроек — используются на экране облака.
class CloudProviderHints {
  const CloudProviderHints({
    required this.endpointExample,
    required this.regionExample,
    required this.accessKeyLabel,
    required this.secretKeyLabel,
    required this.notes,
  });

  final String endpointExample;
  final String regionExample;
  final String accessKeyLabel;
  final String secretKeyLabel;
  final List<String> notes;

  /// Подсказки для конкретного провайдера.
  static CloudProviderHints forType(CloudProviderType type) {
    switch (type) {
      case CloudProviderType.none:
        return const CloudProviderHints(
          endpointExample: '',
          regionExample: '',
          accessKeyLabel: '',
          secretKeyLabel: '',
          notes: <String>[
            'Расписание будет храниться только на этом устройстве.',
          ],
        );
      case CloudProviderType.webdav:
        return const CloudProviderHints(
          endpointExample: 'https://webdav.yandex.ru',
          regionExample: '',
          accessKeyLabel: 'Логин Яндекс.Диска',
          secretKeyLabel: 'Пароль приложения',
          notes: <String>[
            'Создайте пароль приложения в Яндекс ID: Безопасность → Пароли приложений → Файлы (WebDAV).',
            'Обычный пароль от аккаунта не подойдёт, нужен именно пароль приложения.',
            'Подходит также Nextcloud/ownCloud: адрес вида https://cloud.example.com/remote.php/dav/files/логин.',
          ],
        );
      case CloudProviderType.s3:
        return const CloudProviderHints(
          endpointExample: 'https://storage.yandexcloud.net',
          regionExample: 'ru-central1',
          accessKeyLabel: 'Key ID',
          secretKeyLabel: 'Secret key',
          notes: <String>[
            'Yandex Object Storage: адрес https://storage.yandexcloud.net, регион ru-central1.',
            'MinIO и большинство self-hosted S3 требуют адресацию path-style — включите её.',
            'Google Cloud Storage и Firebase Storage: адрес https://storage.googleapis.com, '
                'регион auto, ключи — HMAC-ключи сервисного аккаунта (GCS → Settings → Interoperability).',
            'AWS S3: адрес https://s3.<регион>.amazonaws.com, регион указывается явно.',
          ],
        );
    }
  }
}
