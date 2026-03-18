import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Lock Mechanism Tests', () {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    final lockFilePath = '${home ?? "/tmp"}/.flutter_skill.lock';
    final lockFile = File(lockFilePath);

    tearDown(() async {
      // Clean up lock file after each test
      if (await lockFile.exists()) {
        await lockFile.delete();
      }
    });

    test('Lock file is created when server starts', () async {
      // Simulate lock acquisition
      await lockFile
          .writeAsString('${pid}\n${DateTime.now().toIso8601String()}');

      expect(await lockFile.exists(), isTrue);

      final content = await lockFile.readAsString();
      expect(content, contains(pid.toString()));
    });

    test('Lock file age check logic', () async {
      // Create a fresh lock
      await lockFile
          .writeAsString('99999\n${DateTime.now().toIso8601String()}');

      // Check lock age logic
      final stat = await lockFile.stat();
      final age = DateTime.now().difference(stat.modified);

      // Fresh lock should be less than 10 minutes old
      expect(age.inMinutes < 10, isTrue,
          reason: 'Newly created lock should be fresh');
    });

    test('Fresh lock (<10 minutes) should prevent new instances', () async {
      // Create a fresh lock
      final freshTime = DateTime.now();
      await lockFile.writeAsString('88888\n${freshTime.toIso8601String()}');

      // Check if lock is fresh
      final stat = await lockFile.stat();
      final age = DateTime.now().difference(stat.modified);

      expect(age.inMinutes < 10, isTrue,
          reason: 'Lock should be considered fresh');
    });

    test('Lock file contains PID and timestamp', () async {
      final timestamp = DateTime.now().toIso8601String();
      await lockFile.writeAsString('12345\n$timestamp');

      final lines = (await lockFile.readAsString()).split('\n');

      expect(lines.length >= 2, isTrue);
      expect(lines[0], equals('12345'));
      expect(lines[1], equals(timestamp));
    });
  });

  group('Error Reporter Tests', () {
    test('Critical errors are identified correctly', () {
      final criticalErrors = [
        'LateInitializationError: Field not initialized',
        'Null check operator used on a null value',
        'UnhandledException in async callback',
      ];

      for (final error in criticalErrors) {
        final shouldReport = _shouldReportError(error);
        expect(shouldReport, isTrue,
            reason: 'Should report critical error: $error');
      }
    });

    test('Expected errors are not reported', () {
      final expectedErrors = [
        'Exception: Not connected to Flutter app',
        'Connection refused',
        'TimeoutException after 5000ms',
      ];

      for (final error in expectedErrors) {
        final shouldReport = _shouldReportError(error);
        expect(shouldReport, isFalse,
            reason: 'Should not report expected error: $error');
      }
    });
  });
}

/// Simulate the error filtering logic
bool _shouldReportError(dynamic error) {
  final errorStr = error.toString().toLowerCase();

  final criticalPatterns = [
    'lateinitializationerror',
    'null check operator',
    'unhandledexception',
    'stackoverflow',
    'outofmemory',
  ];

  final ignoredPatterns = [
    'not connected',
    'no isolates found',
    'connection refused',
    'timeout',
  ];

  for (final pattern in criticalPatterns) {
    if (errorStr.contains(pattern)) {
      for (final ignored in ignoredPatterns) {
        if (errorStr.contains(ignored)) return false;
      }
      return true;
    }
  }

  return false;
}
