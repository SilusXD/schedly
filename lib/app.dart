import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'ui/screens/home_screen.dart';
import 'ui/state/schedule_controller.dart';
import 'ui/theme.dart';

/// Корневое приложение.
class SchedlyApp extends StatelessWidget {
  const SchedlyApp({super.key, required this.controller});

  /// Состояние расписания.
  final ScheduleController controller;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ScheduleController>.value(
      value: controller,
      child: MaterialApp(
        title: 'Дневник расписания',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        locale: const Locale('ru'),
        supportedLocales: const <Locale>[Locale('ru'), Locale('en')],
        localizationsDelegates: const <LocalizationsDelegate<Object>>[
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const HomeScreen(),
      ),
    );
  }
}

/// Экран аварийного завершения инициализации.
///
/// Показывается, если не удалось открыть локальную базу или создать сетевые
/// компоненты. Без этого пользователь увидел бы белый экран без объяснений.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.message});

  /// Текст ошибки.
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Дневник расписания',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      supportedLocales: const <Locale>[Locale('ru'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 12),
                const Text(
                  'Не удалось запустить приложение',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
