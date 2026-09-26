import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Уровень важности записи журнала.
enum LogLevel {
  debug('DEBUG'),
  info('INFO'),
  warning('WARN'),
  error('ERROR');

  const LogLevel(this.label);

  final String label;
}

/// Одна запись журнала.
@immutable
class LogEntry {
  const LogEntry({
    required this.time,
    required this.level,
    required this.message,
    this.error,
  });

  final DateTime time;
  final LogLevel level;
  final String message;
  final String? error;

  String get formatted {
    final String timeText = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
    final String suffix = error == null ? '' : ' | $error';
    return '[$timeText] ${level.label}: $message$suffix';
  }

  @override
  String toString() => formatted;
}

/// Простой журнал в памяти с ограниченным буфером.
///
/// Используется экраном диагностики: на iPhone без Mac нет удобного доступа к
/// системному логу, поэтому последние события хранятся прямо в приложении.
class AppLogger {
  AppLogger({this.bufferSize = 400});

  final int bufferSize;
  final Queue<LogEntry> _entries = Queue<LogEntry>();
  final List<void Function(LogEntry)> _listeners = <void Function(LogEntry)>[];

  /// Последние записи, от старых к новым.
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  void debug(String message) => _add(LogLevel.debug, message);

  void info(String message) => _add(LogLevel.info, message);

  void warning(String message, [Object? error]) =>
      _add(LogLevel.warning, message, error);

  void error(String message, [Object? error]) =>
      _add(LogLevel.error, message, error);

  /// Подписка на новые записи (для обновления экрана диагностики).
  void Function() addListener(void Function(LogEntry) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void clear() {
    _entries.clear();
  }

  void _add(LogLevel level, String message, [Object? error]) {
    final LogEntry entry = LogEntry(
      time: DateTime.now(),
      level: level,
      message: message,
      error: error?.toString(),
    );
    _entries.addLast(entry);
    while (_entries.length > bufferSize) {
      _entries.removeFirst();
    }
    if (kDebugMode) {
      debugPrint(entry.formatted);
    }
    for (final void Function(LogEntry) listener in List<void Function(LogEntry)>.of(_listeners)) {
      listener(entry);
    }
  }
}

/// Глобальный журнал приложения.
final AppLogger appLogger = AppLogger();
