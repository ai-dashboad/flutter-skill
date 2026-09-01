part of '../server.dart';

extension _RecordingHandlers on FlutterMcpServer {
  /// Test recording and video tools
  /// Returns null if the tool is not handled.
  Future<dynamic> _handleRecordingTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'record_start') {
      _isRecording = true;
      _recordedSteps.clear();
      _recordingStartTime = DateTime.now();
      return {"recording": true, "message": "Recording started"};
    }

    if (name == 'record_stop') {
      _isRecording = false;
      final duration = _recordingStartTime != null
          ? DateTime.now().difference(_recordingStartTime!).inMilliseconds
          : 0;
      return {
        "steps": _recordedSteps,
        "duration_ms": duration,
        "step_count": _recordedSteps.length
      };
    }

    if (name == 'record_export') {
      final format = args['format'] as String;
      String code;
      switch (format) {
        case 'json':
          code = jsonEncode(_recordedSteps);
          break;
        case 'jest':
          code = _exportJest();
          break;
        case 'pytest':
          code = _exportPytest();
          break;
        case 'dart_test':
          code = _exportDartTest();
          break;
        case 'playwright':
          code = _exportPlaywright();
          break;
        case 'cypress':
          code = _exportCypress();
          break;
        case 'selenium':
          code = _exportSelenium();
          break;
        case 'xcuitest':
          code = _exportXCUITest();
          break;
        case 'espresso':
          code = _exportEspresso();
          break;
        case 'detox':
          code = _exportDetox();
          break;
        case 'maestro':
          code = _exportMaestro();
          break;
        default:
          code = jsonEncode(_recordedSteps);
      }
      return {
        "format": format,
        "code": code,
        "step_count": _recordedSteps.length
      };
    }

    // Video recording tools
    if (name == 'video_start') {
      if (_videoProcess != null) {
        return {
          "success": false,
          "error": "Video recording already in progress"
        };
      }
      final platform = await _detectSimulatorPlatform();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = args['path'] as String? ??
          '${Directory.systemTemp.path}/flutter_skill_video_$timestamp.${platform == 'ios' ? 'mov' : 'mp4'}';
      try {
        Process process;
        if (platform == 'ios') {
          process = await Process.start(
              'xcrun', ['simctl', 'io', 'booted', 'recordVideo', path]);
          _videoProcess = process;
          _videoPath = path;
        } else {
          // Android: record on device, pull later
          final devicePath = '/sdcard/flutter_skill_video_$timestamp.mp4';
          final adb = _findAdb();
          process = await Process.start(adb,
              ['-s', 'emulator-5554', 'shell', 'screenrecord', devicePath]);
          _videoProcess = process;
          _videoPath = path; // local path for after pull
          _videoDevicePath = devicePath;
        }
        _videoPlatform = platform;
        return {"recording": true, "platform": platform, "path": path};
      } catch (e) {
        return {"success": false, "error": e.toString()};
      }
    }

    if (name == 'video_stop') {
      if (_videoProcess == null) {
        return {"success": false, "error": "No video recording in progress"};
      }
      try {
        _videoProcess!.kill(ProcessSignal.sigint);
        await _videoProcess!.exitCode.timeout(const Duration(seconds: 5),
            onTimeout: () {
          _videoProcess!.kill();
          return -1;
        });
      } catch (_) {}
      final path = _videoPath;
      final platform = _videoPlatform;
      final devicePath = _videoDevicePath;
      _videoProcess = null;
      _videoPath = null;
      _videoPlatform = null;
      _videoDevicePath = null;
      // For Android, pull the file from device
      if (platform == 'android' && devicePath != null && path != null) {
        try {
          await Process.run(
              _findAdb(), ['-s', 'emulator-5554', 'pull', devicePath, path]);
        } catch (_) {}
      }
      return {"path": path, "platform": platform, "success": true};
    }

    // Parallel multi-device tools

    return null; // Not handled by this group
  }
}
