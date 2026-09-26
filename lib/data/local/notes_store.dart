import 'dart:convert';

import '../../core/app_logger.dart';
import '../../domain/models/lesson_note.dart';
import 'local_storage.dart';

/// Локальное хранилище домашних заданий и личных пометок.
///
/// Заметки живут только на устройстве: это личные записи ученика/студента,
/// они не выгружаются в облако и не теряются при обновлении расписания.
class NotesStore {
  NotesStore(this._storage, {AppLogger? logger}) : _logger = logger ?? appLogger;

  final LocalStorage _storage;
  final AppLogger _logger;

  /// Все заметки, ключ — идентификатор пары.
  Map<String, LessonNote> all() {
    final Map<String, LessonNote> result = <String, LessonNote>{};
    for (final MapEntry<dynamic, String> entry in _storage.notes.toMap().entries) {
      final LessonNote? note = _decode(entry.value);
      if (note != null && note.lessonKey.isNotEmpty) {
        result[note.lessonKey] = note;
      }
    }
    return result;
  }

  /// Заметки конкретной учебной недели (ключ вида `2026-W12`).
  Map<String, LessonNote> forWeek(String weekKey) {
    final Map<String, LessonNote> result = <String, LessonNote>{};
    for (final MapEntry<String, LessonNote> entry in all().entries) {
      if (entry.value.weekKey == weekKey) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// Заметка по ключу пары.
  LessonNote? get(String lessonKey) => _decode(_storage.notes.get(lessonKey));

  /// Сохраняет заметку. Пустая заметка удаляется, чтобы не мусорить в базе.
  Future<void> save(LessonNote note) async {
    if (note.isEmpty) {
      await _storage.notes.delete(note.lessonKey);
      _logger.debug('Пустая заметка удалена: ${note.lessonKey}');
      return;
    }
    await _storage.notes.put(note.lessonKey, jsonEncode(note.toJson()));
  }

  /// Удаляет заметку.
  Future<void> remove(String lessonKey) => _storage.notes.delete(lessonKey);

  /// Количество сохранённых заметок.
  int get count => _storage.notes.length;

  /// Полная очистка заметок.
  Future<void> clear() => _storage.notes.clear();

  LessonNote? _decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      final LessonNote? note = LessonNote.tryParse(decoded);
      if (note == null) {
        _logger.warning('Повреждённая запись заметки будет проигнорирована');
      }
      return note;
    } on FormatException catch (error) {
      _logger.warning('Не удалось разобрать заметку из локальной базы', error);
      return null;
    }
  }
}
