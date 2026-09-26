import 'dart:typed_data';

/// Файл в облачном хранилище.
class CloudFile {
  const CloudFile({
    required this.path,
    this.size = 0,
    this.modified,
    this.etag,
  });

  /// Путь относительно корня хранилища (например `schedules/schedule_2026-03-15.json`).
  final String path;

  /// Размер в байтах (0, если неизвестен).
  final int size;

  /// Время последнего изменения, если сервер его отдаёт.
  final DateTime? modified;

  /// ETag/хеш, если сервер его отдаёт.
  final String? etag;

  /// Имя файла без пути.
  String get fileName {
    final int index = path.lastIndexOf('/');
    return index < 0 ? path : path.substring(index + 1);
  }

  @override
  String toString() => 'CloudFile($path, $size байт)';
}

/// Ошибка обращения к облачному хранилищу.
class CloudStorageException implements Exception {
  CloudStorageException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  /// Ошибка авторизации (неверные ключи/пароль).
  bool get isAuthError => statusCode == 401 || statusCode == 403;

  /// Ошибка «не найдено».
  bool get isNotFound => statusCode == 404;

  @override
  String toString() => 'CloudStorageException: $message'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}'
      '${cause == null ? '' : ' | $cause'}';
}

/// Поддерживаемые облачные хранилища.
enum CloudProviderType {
  none('Не использовать'),
  webdav('WebDAV (Яндекс.Диск, Nextcloud, ownCloud)'),
  s3('S3-совместимое (Yandex Object Storage, MinIO, AWS S3, Google/Firebase Storage)');

  const CloudProviderType(this.title);

  final String title;
}

/// Настройки облачного хранилища.
///
/// Провайдер, адрес, регион и ключ доступа хранятся в локальной базе, а секрет
/// ([secretKey]) — в защищённом хранилище iOS Keychain.
class CloudConfig {
  const CloudConfig({
    this.type = CloudProviderType.none,
    this.endpoint = '',
    this.region = 'ru-central1',
    this.accessKey = '',
    this.secretKey = '',
    this.bucket = '',
    this.basePath = 'schedly',
    this.usePathStyle = true,
    this.autoSync = true,
  });

  /// Тип хранилища.
  final CloudProviderType type;

  /// Адрес сервера.
  ///
  /// * WebDAV: `https://webdav.yandex.ru`
  /// * S3/Yandex Object Storage: `https://storage.yandexcloud.net`
  /// * AWS S3: `https://s3.eu-central-1.amazonaws.com`
  /// * Google/Firebase Storage: `https://storage.googleapis.com`
  final String endpoint;

  /// Регион (для S3-подписи). Для Яндекс.Диска не используется.
  final String region;

  /// Идентификатор ключа (для WebDAV — логин).
  final String accessKey;

  /// Секретный ключ (для WebDAV — пароль приложения).
  final String secretKey;

  /// Имя бакета (только для S3-совместимых хранилищ).
  final String bucket;

  /// Корневая папка внутри хранилища.
  final String basePath;

  /// Использовать path-style адресацию (`endpoint/bucket/key`) вместо
  /// virtual-hosted (`bucket.endpoint/key`). Нужно для MinIO и Yandex Object Storage.
  final bool usePathStyle;

  /// Автоматически выгружать разобранное расписание в облако.
  final bool autoSync;

  /// Достаточно ли данных для работы с хранилищем.
  bool get isConfigured {
    if (type == CloudProviderType.none) {
      return false;
    }
    if (endpoint.trim().isEmpty || accessKey.trim().isEmpty || secretKey.isEmpty) {
      return false;
    }
    if (type == CloudProviderType.s3 && bucket.trim().isEmpty) {
      return false;
    }
    return true;
  }

  Uri? get baseUri => Uri.tryParse(endpoint.trim());

  CloudConfig copyWith({
    CloudProviderType? type,
    String? endpoint,
    String? region,
    String? accessKey,
    String? secretKey,
    String? bucket,
    String? basePath,
    bool? usePathStyle,
    bool? autoSync,
  }) {
    return CloudConfig(
      type: type ?? this.type,
      endpoint: endpoint ?? this.endpoint,
      region: region ?? this.region,
      accessKey: accessKey ?? this.accessKey,
      secretKey: secretKey ?? this.secretKey,
      bucket: bucket ?? this.bucket,
      basePath: basePath ?? this.basePath,
      usePathStyle: usePathStyle ?? this.usePathStyle,
      autoSync: autoSync ?? this.autoSync,
    );
  }

  /// Конфигурация без секрета — пригодна для сохранения в локальной базе.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type.name,
        'endpoint': endpoint,
        'region': region,
        'accessKey': accessKey,
        'bucket': bucket,
        'basePath': basePath,
        'usePathStyle': usePathStyle,
        'autoSync': autoSync,
      };

  factory CloudConfig.fromJson(Map<String, dynamic> json) {
    return CloudConfig(
      type: CloudProviderType.values.firstWhere(
        (CloudProviderType value) => value.name == json['type'],
        orElse: () => CloudProviderType.none,
      ),
      endpoint: json['endpoint'] is String ? json['endpoint'] as String : '',
      region: json['region'] is String ? json['region'] as String : 'ru-central1',
      accessKey: json['accessKey'] is String ? json['accessKey'] as String : '',
      bucket: json['bucket'] is String ? json['bucket'] as String : '',
      basePath: json['basePath'] is String ? json['basePath'] as String : 'schedly',
      usePathStyle: json['usePathStyle'] != false,
      autoSync: json['autoSync'] != false,
    );
  }

  @override
  String toString() => 'CloudConfig(${type.name}, endpoint: $endpoint, '
      'bucket: $bucket, basePath: $basePath, настроено: $isConfigured)';
}

/// Единый интерфейс облачного хранилища.
///
/// Реализации обязаны быть «мягкими» к отсутствию сети: методы бросают
/// [CloudStorageException], а вызывающий код (репозиторий) обязан поймать её и
/// перейти в оффлайн-режим, не теряя данные.
abstract interface class CloudStorage {
  /// Человекочитаемое имя хранилища (для интерфейса и журнала).
  String get displayName;

  /// Готово ли хранилище к работе (заполнены настройки).
  bool get isConfigured;

  /// Создаёт папку (и родительские папки), если её нет.
  Future<void> ensureFolder(String path);

  /// Список файлов в папке.
  Future<List<CloudFile>> list(String folder);

  /// Читает файл. Возвращает `null`, если файла нет.
  Future<Uint8List?> read(String path);

  /// Записывает (перезаписывает) файл.
  Future<void> write(
    String path,
    Uint8List bytes, {
    String? contentType,
  });

  /// Удаляет файл. Возвращает `true`, если файл был удалён.
  Future<bool> delete(String path);

  /// Проверяет существование файла.
  Future<bool> exists(String path);

  /// Освобождает ресурсы.
  void dispose();
}
