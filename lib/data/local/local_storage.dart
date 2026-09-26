import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../core/app_logger.dart';

/// Имена локальных хранилищ (Hive).
class HiveBoxes {
  const HiveBoxes._();

  /// Разобранные расписания (ключ — `schedule_YYYY-MM-DD`).
  static const String schedules = 'schedules';

  /// Заметки и домашние задания (ключ — идентификатор пары).
  static const String notes = 'notes';

  /// Настройки приложения.
  static const String settings = 'settings';
}

/// Доступ к локальному хранилищу Hive.
///
/// Hive выбран за скорость и отсутствие нативной настройки: база — это файл в
/// каталоге приложения, что критично для оффлайн-режима на iOS.
class LocalStorage {
  LocalStorage({AppLogger? logger, this.initPathOverride})
      : _logger = logger ?? appLogger;

  final AppLogger _logger;

  /// Каталог для базы. Задаётся только в тестах: на устройстве используется
  /// штатный каталог приложения (`Hive.initFlutter`).
  final String? initPathOverride;

  bool _initialized = false;

  Box<String>? _schedules;
  Box<String>? _notes;
  Box<String>? _settings;

  /// Инициализирует Hive. Повторные вызовы безопасны.
  Future<void> init() async {
    if (_initialized) {
      return;
    }
    if (initPathOverride != null) {
      Hive.init(initPathOverride!);
    } else {
      await Hive.initFlutter();
    }
    _schedules = await Hive.openBox<String>(HiveBoxes.schedules);
    _notes = await Hive.openBox<String>(HiveBoxes.notes);
    _settings = await Hive.openBox<String>(HiveBoxes.settings);
    _initialized = true;
    _logger.info('Локальный кэш готов: расписаний ${_schedules!.length}, '
        'заметок ${_notes!.length}, настроек ${_settings!.length}');
  }

  /// Бокс расписаний.
  Box<String> get schedules => _require(_schedules, HiveBoxes.schedules);

  /// Бокс заметок.
  Box<String> get notes => _require(_notes, HiveBoxes.notes);

  /// Бокс настроек.
  Box<String> get settings => _require(_settings, HiveBoxes.settings);

  Box<String> _require(Box<String>? box, String name) {
    if (box == null) {
      throw StateError(
        'Хранилище «$name» не открыто: вызовите LocalStorage.init() до использования',
      );
    }
    return box;
  }

  /// Полностью очищает локальные данные (используется в настройках).
  Future<void> clearAll() async {
    await schedules.clear();
    await notes.clear();
    _logger.warning('Локальный кэш очищен пользователем');
  }
}
