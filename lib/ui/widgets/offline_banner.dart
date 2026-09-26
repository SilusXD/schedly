import 'package:flutter/material.dart';

/// Баннер оффлайн-режима.
///
/// Показывается, когда данные взяты не из сети (кэш или облако) либо система
/// сообщает об отсутствии подключения. Пользователь должен понимать, почему
/// расписание может быть не самым свежим.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({
    super.key,
    required this.isVisible,
    this.isStale = false,
    this.message,
  });

  /// Показывать ли баннер.
  final bool isVisible;

  /// Устарели ли данные (кэш не за сегодня).
  final bool isStale;

  /// Дополнительное пояснение.
  final String? message;

  @override
  Widget build(BuildContext context) {
    if (!isVisible) {
      return const SizedBox.shrink();
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String text = message == null || message!.isEmpty
        ? (isStale
            ? 'Оффлайн-режим: показано сохранённое расписание за прошлую дату'
            : 'Оффлайн-режим: показаны сохранённые данные')
        : message!;

    return Material(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(Icons.cloud_off_outlined, size: 20, color: scheme.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
