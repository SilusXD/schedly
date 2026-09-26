import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// Разбор конфигурации GitHub Actions.
///
/// Сами workflow локально не запускаются, поэтому тест проверяет то, что можно
/// проверить без GitHub: файлы синтаксически корректны и содержат ключевые
/// шаги — иначе ошибка выяснилась бы только при пуше.
void main() {
  Map<dynamic, dynamic> loadWorkflow(String fileName) {
    final File file = File('.github/workflows/$fileName');
    expect(file.existsSync(), isTrue, reason: 'нет файла $fileName');
    final Object? document = loadYaml(file.readAsStringSync());
    expect(document, isA<Map<dynamic, dynamic>>(), reason: '$fileName — не YAML-словарь');
    return document! as Map<dynamic, dynamic>;
  }

  List<Map<dynamic, dynamic>> stepsOf(Map<dynamic, dynamic> workflow) {
    final Map<dynamic, dynamic> jobs = workflow['jobs'] as Map<dynamic, dynamic>;
    final Map<dynamic, dynamic> job = jobs.values.first as Map<dynamic, dynamic>;
    return (job['steps'] as List<dynamic>).cast<Map<dynamic, dynamic>>();
  }

  /// Секция триггеров (`on`).
  ///
  /// Разные YAML-парсеры читают ключ `on` либо как строку, либо как логическое
  /// `true`, поэтому ищем его оба варианта.
  Map<dynamic, dynamic> triggersOf(Map<dynamic, dynamic> workflow) {
    final Object? on = workflow['on'] ?? workflow[true];
    return on is Map<dynamic, dynamic> ? on : <dynamic, dynamic>{};
  }

  group('workflow сборки iOS', () {
    late Map<dynamic, dynamic> workflow;

    setUpAll(() {
      workflow = loadWorkflow('ios.yml');
    });

    test('запускается по тегу и вручную', () {
      final Map<dynamic, dynamic> jobs = workflow['jobs'] as Map<dynamic, dynamic>;
      expect(jobs.keys, contains('build-ios'));

      final Map<dynamic, dynamic> triggers = triggersOf(workflow);
      expect(triggers.keys, contains('push'));
      expect(triggers.keys, contains('workflow_dispatch'));

      final Map<dynamic, dynamic> push = triggers['push'] as Map<dynamic, dynamic>;
      expect(push['tags'], contains('v*'));

      final Map<dynamic, dynamic> dispatches =
          triggers['workflow_dispatch'] as Map<dynamic, dynamic>;
      final Map<dynamic, dynamic> inputs = dispatches['inputs'] as Map<dynamic, dynamic>;
      expect(inputs.keys, contains('release_tag'));
      expect(inputs.keys, contains('schedule_url_template'));
    });

    test('сборка идёт без подписи и упаковывается в .ipa', () {
      final String buildStep = stepsOf(workflow)
          .map((Map<dynamic, dynamic> step) => step['run']?.toString() ?? '')
          .join('\n');

      expect(buildStep, contains('flutter build ios'));
      expect(buildStep, contains('--no-codesign'));
      expect(buildStep, contains('Schedly-unsigned.ipa'));
      expect(buildStep, contains('Payload'));
    });

    test('есть права на публикацию релиза', () {
      final Map<dynamic, dynamic> permissions =
          workflow['permissions'] as Map<dynamic, dynamic>;
      expect(permissions['contents'], 'write');
    });

    test('шаг публикации .ipa в Releases настроен', () {
      final Map<dynamic, dynamic> releaseStep = stepsOf(workflow).firstWhere(
        (Map<dynamic, dynamic> step) =>
            (step['name']?.toString() ?? '').contains('Releases'),
        orElse: () => <dynamic, dynamic>{},
      );

      expect(releaseStep, isNotEmpty, reason: 'не найден шаг публикации релиза');
      final String run = releaseStep['run'] as String;
      expect(run, contains('gh release create'));
      expect(run, contains('gh release upload'));
      expect(run, contains('Schedly-unsigned.ipa'));
      expect(run, contains('--clobber'), reason: 'повторный запуск не должен падать');
      expect(releaseStep['env'], isNotNull);

      final String condition = releaseStep['if'] as String;
      expect(condition, contains('workflow_dispatch'));
      expect(condition, contains('tag'));
    });

    test('артефакты по-прежнему выгружаются', () {
      final Iterable<String> names = stepsOf(workflow)
          .map((Map<dynamic, dynamic> step) => step['name']?.toString() ?? '');
      expect(names.any((String name) => name.contains('.ipa')), isTrue);
      expect(names.any((String name) => name.contains('dSYM')), isTrue);
    });
  });

  group('workflow проверок', () {
    test('запускает анализ и тесты', () {
      final Map<dynamic, dynamic> workflow = loadWorkflow('ci.yml');
      final String runs = stepsOf(workflow)
          .map((Map<dynamic, dynamic> step) => step['run']?.toString() ?? '')
          .join('\n');
      expect(runs, contains('flutter pub get'));
      expect(runs, contains('flutter analyze'));
      expect(runs, contains('flutter test'));
    });
  });
}
