import 'dart:convert';

/// Приводит произвольный текст к «слагу» для использования в ключах заметок.
///
/// Особенности: `ё` → `е`, регистр не важен, всё кроме букв и цифр заменяется
/// на дефис, повторы дефисов схлопываются.
String slugify(String value) {
  final StringBuffer buffer = StringBuffer();
  bool lastWasDash = false;
  for (final int rune in value.trim().toLowerCase().runes) {
    final String ch = String.fromCharCode(rune);
    final bool isLetterOrDigit = RegExp(r'[a-zа-я0-9]').hasMatch(ch);
    if (isLetterOrDigit) {
      buffer.write(ch == 'ё' ? 'е' : ch);
      lastWasDash = false;
      continue;
    }
    if (!lastWasDash) {
      buffer.write('-');
      lastWasDash = true;
    }
  }
  String result = buffer.toString();
  while (result.startsWith('-')) {
    result = result.substring(1);
  }
  while (result.endsWith('-')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

/// Заметка (домашнее задание и личные пометки) к конкретной паре.
///
/// Ключ [lessonKey] строится из недели, сущности, дня, номера пары и предмета,
/// поэтому заметка остаётся привязанной к паре даже после перезагрузки
/// расписания — до тех пор, пока не изменится состав занятия.
class LessonNote {
  const LessonNote({
    required this.lessonKey,
    required this.updatedAt,
    this.homework = '',
    this.personalNote = '',
    this.homeworkDone = false,
    this.subject = '',
    this.weekKey = '',
  });

  /// Стабильный ключ пары (см. [buildLessonKey]).
  final String lessonKey;

  /// Текст домашнего задания.
  final String homework;

  /// Личные пометки (что взять с собой, вопросы преподавателю и т. п.).
  final String personalNote;

  /// Отметка «ДЗ выполнено».
  final bool homeworkDone;

  /// Предмет — храним денормализованно, чтобы список заметок был читаемым
  /// даже без загруженного расписания.
  final String subject;

  /// Ключ учебной недели (`2026-W12`).
  final String weekKey;

  /// Время последнего изменения.
  final DateTime updatedAt;

  /// Пустая ли заметка (такую запись можно удалять из хранилища).
  bool get isEmpty =>
      homework.trim().isEmpty && personalNote.trim().isEmpty && !homeworkDone;

  LessonNote copyWith({
    String? lessonKey,
    String? homework,
    String? personalNote,
    bool? homeworkDone,
    String? subject,
    String? weekKey,
    DateTime? updatedAt,
  }) {
    return LessonNote(
      lessonKey: lessonKey ?? this.lessonKey,
      homework: homework ?? this.homework,
      personalNote: personalNote ?? this.personalNote,
      homeworkDone: homeworkDone ?? this.homeworkDone,
      subject: subject ?? this.subject,
      weekKey: weekKey ?? this.weekKey,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'lessonKey': lessonKey,
        'homework': homework,
        'personalNote': personalNote,
        'homeworkDone': homeworkDone,
        'subject': subject,
        'weekKey': weekKey,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  String toJsonString() => jsonEncode(toJson());

  factory LessonNote.fromJson(Map<String, dynamic> json) {
    final DateTime? updated =
        json['updatedAt'] is String ? DateTime.tryParse(json['updatedAt'] as String) : null;
    return LessonNote(
      lessonKey: json['lessonKey'] is String ? json['lessonKey'] as String : '',
      homework: json['homework'] is String ? json['homework'] as String : '',
      personalNote: json['personalNote'] is String ? json['personalNote'] as String : '',
      homeworkDone: json['homeworkDone'] == true,
      subject: json['subject'] is String ? json['subject'] as String : '',
      weekKey: json['weekKey'] is String ? json['weekKey'] as String : '',
      updatedAt: (updated ?? DateTime.now()).toLocal(),
    );
  }

  static LessonNote? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    try {
      return LessonNote.fromJson(Map<String, dynamic>.from(raw));
    } on Object {
      return null;
    }
  }

  @override
  String toString() => 'LessonNote($lessonKey, homework: ${homework.length} симв.)';
}
