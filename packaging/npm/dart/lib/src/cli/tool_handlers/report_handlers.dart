part of '../server.dart';

extension _ReportHandlers on FlutterMcpServer {
  /// Generate test report from recorded steps
  Future<dynamic> _generateReport(Map<String, dynamic> args) async {
    final format = (args['format'] as String?) ?? 'html';
    final title = (args['title'] as String?) ?? 'Flutter Skill Test Report';
    final outputPath = args['output_path'] as String?;
    // ignore: unused_local_variable
    final includeScreenshots = (args['include_screenshots'] as bool?) ?? true;
    final now = DateTime.now();

    final steps = _recordedSteps;
    final passed = steps.where((s) => s['result'] == true).length;
    final failed = steps.length - passed;
    final passRate = steps.isEmpty ? 100.0 : (passed / steps.length * 100);

    if (format == 'json') {
      final report = {
        'title': title,
        'generated_at': now.toIso8601String(),
        'version': currentVersion,
        'summary': {
          'total': steps.length,
          'passed': passed,
          'failed': failed,
          'pass_rate': passRate
        },
        'steps': steps,
      };
      if (outputPath != null) {
        await File(outputPath)
            .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        return {
          'format': 'json',
          'output_path': outputPath,
          'step_count': steps.length
        };
      }
      return report;
    }

    if (format == 'markdown') {
      final buf = StringBuffer();
      buf.writeln('# $title');
      buf.writeln('');
      buf.writeln('**Generated:** ${now.toIso8601String()}  ');
      buf.writeln('**Version:** flutter-skill v$currentVersion  ');
      buf.writeln(
          '**Summary:** $passed passed, $failed failed (${passRate.toStringAsFixed(1)}%)');
      buf.writeln('');
      buf.writeln('| # | Tool | Args | Result | Duration |');
      buf.writeln('|---|------|------|--------|----------|');
      for (final step in steps) {
        final stepNum = step['step'] ?? '-';
        final tool = step['tool'] ?? '';
        final argsStr = jsonEncode(step['params'] ?? {});
        final result = step['result'] == true ? '✅ Pass' : '❌ Fail';
        final dur = step['duration_ms'] ?? '-';
        buf.writeln('| $stepNum | $tool | `$argsStr` | $result | ${dur}ms |');
      }
      final md = buf.toString();
      if (outputPath != null) {
        await File(outputPath).writeAsString(md);
        return {
          'format': 'markdown',
          'output_path': outputPath,
          'step_count': steps.length
        };
      }
      return {'format': 'markdown', 'content': md, 'step_count': steps.length};
    }

    // HTML format
    final stepsHtml = StringBuffer();
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final rowClass = i % 2 == 0 ? 'even' : 'odd';
      final resultClass = step['result'] == true ? 'pass' : 'fail';
      final resultText = step['result'] == true ? '✅ Pass' : '❌ Fail';
      final argsStr = _htmlEscape(jsonEncode(step['params'] ?? {}));
      stepsHtml.writeln('<tr class="$rowClass">');
      stepsHtml.writeln('  <td>${step['step'] ?? i + 1}</td>');
      stepsHtml.writeln(
          '  <td><code>${_htmlEscape(step['tool'] ?? '')}</code></td>');
      stepsHtml.writeln('  <td><code>$argsStr</code></td>');
      stepsHtml.writeln('  <td class="$resultClass">$resultText</td>');
      stepsHtml.writeln('  <td>${step['duration_ms'] ?? '-'}ms</td>');
      stepsHtml.writeln('</tr>');
    }

    final html = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${_htmlEscape(title)}</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f7fa; color: #333; }
  .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 32px 40px; }
  .header h1 { font-size: 28px; margin-bottom: 8px; }
  .header .meta { opacity: 0.85; font-size: 14px; }
  .summary { display: flex; gap: 24px; padding: 24px 40px; background: white; border-bottom: 1px solid #e2e8f0; }
  .summary .stat { text-align: center; }
  .summary .stat .value { font-size: 32px; font-weight: 700; }
  .summary .stat .label { font-size: 12px; text-transform: uppercase; color: #718096; margin-top: 4px; }
  .stat.passed .value { color: #38a169; }
  .stat.failed .value { color: #e53e3e; }
  .stat.rate .value { color: #667eea; }
  .content { padding: 24px 40px; }
  table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  th { background: #edf2f7; padding: 12px 16px; text-align: left; font-size: 13px; text-transform: uppercase; color: #4a5568; border-bottom: 2px solid #e2e8f0; }
  td { padding: 10px 16px; border-bottom: 1px solid #edf2f7; font-size: 14px; }
  tr.odd { background: #f7fafc; }
  tr.even { background: white; }
  td.pass { color: #38a169; font-weight: 600; }
  td.fail { color: #e53e3e; font-weight: 600; }
  code { background: #edf2f7; padding: 2px 6px; border-radius: 4px; font-size: 12px; word-break: break-all; }
  .footer { padding: 24px 40px; text-align: center; color: #a0aec0; font-size: 13px; }
  .screenshots img { max-width: 200px; cursor: pointer; border-radius: 4px; margin: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.12); transition: transform 0.2s; }
  .screenshots img:hover { transform: scale(1.05); }
  .screenshots img.expanded { max-width: 100%; }
</style>
<script>
function toggleImg(el) { el.classList.toggle('expanded'); }
</script>
</head>
<body>
<div class="header">
  <h1>${_htmlEscape(title)}</h1>
  <div class="meta">${now.toIso8601String()} &bull; flutter-skill v$currentVersion</div>
</div>
<div class="summary">
  <div class="stat"><div class="value">${steps.length}</div><div class="label">Total Steps</div></div>
  <div class="stat passed"><div class="value">$passed</div><div class="label">Passed</div></div>
  <div class="stat failed"><div class="value">$failed</div><div class="label">Failed</div></div>
  <div class="stat rate"><div class="value">${passRate.toStringAsFixed(1)}%</div><div class="label">Pass Rate</div></div>
</div>
<div class="content">
  <table>
    <thead><tr><th>#</th><th>Tool</th><th>Args</th><th>Result</th><th>Duration</th></tr></thead>
    <tbody>$stepsHtml</tbody>
  </table>
</div>
<div class="footer">Generated by flutter-skill v$currentVersion</div>
</body>
</html>''';

    if (outputPath != null) {
      await File(outputPath).writeAsString(html);
      return {
        'format': 'html',
        'output_path': outputPath,
        'step_count': steps.length
      };
    }
    return {'format': 'html', 'content': html, 'step_count': steps.length};
  }

  String _htmlEscape(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  String _exportJest() {
    final buf = StringBuffer();
    buf.writeln("const { FlutterSkill } = require('flutter-skill');");
    buf.writeln("");
    buf.writeln("describe('Recorded Test', () => {");
    buf.writeln("  let skill;");
    buf.writeln("");
    buf.writeln("  beforeAll(async () => {");
    buf.writeln("    skill = new FlutterSkill();");
    buf.writeln("    await skill.connect();");
    buf.writeln("  });");
    buf.writeln("");
    buf.writeln("  afterAll(async () => { await skill.disconnect(); });");
    buf.writeln("");
    buf.writeln("  test('recorded flow', async () => {");
    for (final step in _recordedSteps) {
      final tool = step['tool'];
      final params = step['params'] as Map<String, dynamic>? ?? {};
      buf.writeln("    await skill.$tool(${jsonEncode(params)});");
    }
    buf.writeln("  });");
    buf.writeln("});");
    return buf.toString();
  }

  /// Export recorded steps as pytest
  String _exportPytest() {
    final buf = StringBuffer();
    buf.writeln("import subprocess");
    buf.writeln("import json");
    buf.writeln("");
    buf.writeln("def call_tool(name, params):");
    buf.writeln("    # Implement MCP tool call via your preferred method");
    buf.writeln("    pass");
    buf.writeln("");
    buf.writeln("def test_recorded_flow():");
    for (final step in _recordedSteps) {
      buf.writeln(
          "    call_tool('${step['tool']}', ${jsonEncode(step['params'] ?? {})})");
    }
    return buf.toString();
  }

  /// Export recorded steps as Dart test
  String _exportDartTest() {
    final buf = StringBuffer();
    buf.writeln("import 'package:test/test.dart';");
    buf.writeln("");
    buf.writeln("void main() {");
    buf.writeln("  test('recorded flow', () async {");
    for (final step in _recordedSteps) {
      final tool = step['tool'];
      final params = step['params'] as Map<String, dynamic>? ?? {};
      buf.writeln("    await driver.$tool(${jsonEncode(params)});");
    }
    buf.writeln("  });");
    buf.writeln("}");
    return buf.toString();
  }

  /// Export recorded steps as Playwright test
  String _exportPlaywright() {
    final buf = StringBuffer();
    buf.writeln("const { test, expect } = require('@playwright/test');");
    buf.writeln("");
    buf.writeln("test('recorded test', async ({ page }) => {");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      final selector = key != null ? '[data-testid="$key"]' : null;
      switch (tool) {
        case 'tap':
          if (selector != null) {
            buf.writeln("  await page.click('$selector');");
          } else if (text != null) {
            buf.writeln("  await page.click('text=$text');");
          }
          break;
        case 'enter_text':
          final value =
              params['value'] as String? ?? params['text'] as String? ?? '';
          if (selector != null) {
            buf.writeln(
                "  await page.fill('$selector', '${_escapeJs(value)}');");
          }
          break;
        case 'swipe':
          buf.writeln("  // swipe: ${jsonEncode(params)}");
          break;
        case 'screenshot':
          buf.writeln("  await page.screenshot({ path: 'screenshot.png' });");
          break;
        case 'scroll':
          final dx = params['dx'] ?? 0;
          final dy = params['dy'] ?? 0;
          buf.writeln("  await page.mouse.wheel($dx, $dy);");
          break;
        default:
          buf.writeln("  // $tool: ${jsonEncode(params)}");
      }
    }
    buf.writeln("});");
    return buf.toString();
  }

  /// Export recorded steps as Cypress test
  String _exportCypress() {
    final buf = StringBuffer();
    buf.writeln("describe('recorded test', () => {");
    buf.writeln("  it('should complete flow', () => {");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      final selector = key != null ? '[data-testid="$key"]' : null;
      switch (tool) {
        case 'tap':
          if (selector != null) {
            buf.writeln("    cy.get('$selector').click();");
          } else if (text != null) {
            buf.writeln("    cy.contains('$text').click();");
          }
          break;
        case 'enter_text':
          final value =
              params['value'] as String? ?? params['text'] as String? ?? '';
          if (selector != null) {
            buf.writeln("    cy.get('$selector').type('${_escapeJs(value)}');");
          }
          break;
        case 'swipe':
          buf.writeln("    // swipe: ${jsonEncode(params)}");
          break;
        case 'screenshot':
          buf.writeln("    cy.screenshot();");
          break;
        case 'scroll':
          final dy = params['dy'] ?? 0;
          buf.writeln("    cy.scrollTo(0, $dy);");
          break;
        default:
          buf.writeln("    // $tool: ${jsonEncode(params)}");
      }
    }
    buf.writeln("  });");
    buf.writeln("});");
    return buf.toString();
  }

  /// Export recorded steps as Selenium (Python) test
  String _exportSelenium() {
    final buf = StringBuffer();
    buf.writeln("from selenium import webdriver");
    buf.writeln("from selenium.webdriver.common.by import By");
    buf.writeln("from selenium.webdriver.common.keys import Keys");
    buf.writeln("");
    buf.writeln("driver = webdriver.Chrome()");
    buf.writeln("");
    buf.writeln("try:");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      final selector = key != null ? '[data-testid="$key"]' : null;
      switch (tool) {
        case 'tap':
          if (selector != null) {
            buf.writeln(
                "    driver.find_element(By.CSS_SELECTOR, '$selector').click()");
          } else if (text != null) {
            buf.writeln(
                "    driver.find_element(By.XPATH, '//*[text()=\"${_escapePy(text)}\"]').click()");
          }
          break;
        case 'enter_text':
          final value =
              params['value'] as String? ?? params['text'] as String? ?? '';
          if (selector != null) {
            buf.writeln(
                "    el = driver.find_element(By.CSS_SELECTOR, '$selector')");
            buf.writeln("    el.clear()");
            buf.writeln("    el.send_keys('${_escapePy(value)}')");
          }
          break;
        case 'swipe':
          buf.writeln("    # swipe: ${jsonEncode(params)}");
          break;
        case 'screenshot':
          buf.writeln("    driver.save_screenshot('screenshot.png')");
          break;
        case 'scroll':
          final dy = params['dy'] ?? 0;
          buf.writeln("    driver.execute_script('window.scrollBy(0, $dy)')");
          break;
        default:
          buf.writeln("    # $tool: ${jsonEncode(params)}");
      }
    }
    buf.writeln("finally:");
    buf.writeln("    driver.quit()");
    return buf.toString();
  }

  /// Export recorded steps as XCUITest (Swift)
  String _exportXCUITest() {
    final buf = StringBuffer();
    buf.writeln("import XCTest");
    buf.writeln("");
    buf.writeln("class RecordedTest: XCTestCase {");
    buf.writeln("    func testRecordedFlow() {");
    buf.writeln("        let app = XCUIApplication()");
    buf.writeln("        app.launch()");
    buf.writeln("");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      final identifier = key ?? text ?? 'unknown';
      switch (tool) {
        case 'tap':
          buf.writeln('        app.buttons["$identifier"].tap()');
          break;
        case 'enter_text':
          final value =
              params['value'] as String? ?? params['text'] as String? ?? '';
          buf.writeln(
              '        let ${_swiftVar(identifier)}Field = app.textFields["$identifier"]');
          buf.writeln('        ${_swiftVar(identifier)}Field.tap()');
          buf.writeln(
              '        ${_swiftVar(identifier)}Field.typeText("${_escapeSwift(value)}")');
          break;
        case 'swipe':
          final direction = params['direction'] as String? ?? 'up';
          buf.writeln(
              '        app.swipe${direction[0].toUpperCase()}${direction.substring(1)}()');
          break;
        case 'screenshot':
          buf.writeln('        let screenshot = XCUIScreen.main.screenshot()');
          buf.writeln(
              '        let attachment = XCTAttachment(screenshot: screenshot)');
          buf.writeln('        add(attachment)');
          break;
        default:
          buf.writeln('        // $tool: ${jsonEncode(params)}');
      }
    }
    buf.writeln("    }");
    buf.writeln("}");
    return buf.toString();
  }

  /// Export recorded steps as Espresso (Kotlin)
  String _exportEspresso() {
    final buf = StringBuffer();
    buf.writeln("import androidx.test.ext.junit.runners.AndroidJUnit4");
    buf.writeln("import androidx.test.espresso.Espresso.onView");
    buf.writeln("import androidx.test.espresso.action.ViewActions.*");
    buf.writeln("import androidx.test.espresso.matcher.ViewMatchers.*");
    buf.writeln("import org.junit.Test");
    buf.writeln("import org.junit.runner.RunWith");
    buf.writeln("");
    buf.writeln("@RunWith(AndroidJUnit4::class)");
    buf.writeln("class RecordedTest {");
    buf.writeln("    @Test");
    buf.writeln("    fun testRecordedFlow() {");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      switch (tool) {
        case 'tap':
          if (key != null) {
            buf.writeln(
                '        onView(withContentDescription("$key")).perform(click())');
          } else if (text != null) {
            buf.writeln('        onView(withText("$text")).perform(click())');
          }
          break;
        case 'enter_text':
          final value =
              params['value'] as String? ?? params['text'] as String? ?? '';
          if (key != null) {
            buf.writeln(
                '        onView(withContentDescription("$key")).perform(replaceText("${_escapeKotlin(value)}"))');
          }
          break;
        case 'swipe':
          final direction = params['direction'] as String? ?? 'up';
          buf.writeln(
              '        onView(withId(android.R.id.content)).perform(swipe${direction[0].toUpperCase()}${direction.substring(1)}())');
          break;
        case 'screenshot':
          buf.writeln(
              '        // Take screenshot via UiAutomator or test rule');
          break;
        default:
          buf.writeln('        // $tool: ${jsonEncode(params)}');
      }
    }
    buf.writeln("    }");
    buf.writeln("}");
    return buf.toString();
  }

  String _escapeJs(String s) =>
      s.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
  String _escapePy(String s) =>
      s.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
  String _escapeSwift(String s) =>
      s.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  String _escapeKotlin(String s) =>
      s.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  String _swiftVar(String s) =>
      s.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

  /// Export recorded steps as Detox (JavaScript) test
  String _exportDetox() {
    final buf = StringBuffer();
    buf.writeln("const { device, element, by, expect } = require('detox');");
    buf.writeln("");
    buf.writeln("describe('Recorded Test', () => {");
    buf.writeln("  beforeAll(async () => {");
    buf.writeln("    await device.launchApp();");
    buf.writeln("  });");
    buf.writeln("");
    buf.writeln("  afterAll(async () => {");
    buf.writeln("    await device.terminateApp();");
    buf.writeln("  });");
    buf.writeln("");
    buf.writeln("  it('should complete recorded flow', async () => {");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      switch (tool) {
        case 'tap':
          if (key != null) {
            buf.writeln("    // Tap element with testID '$key'");
            buf.writeln("    await element(by.id('$key')).tap();");
          } else if (text != null) {
            buf.writeln("    // Tap element with text '$text'");
            buf.writeln(
                "    await element(by.text('${_escapeJs(text)}')).tap();");
          }
          break;
        case 'enter_text':
          final value =
              params['value'] as String? ?? params['text'] as String? ?? '';
          if (key != null) {
            buf.writeln("    // Type text into '$key'");
            buf.writeln(
                "    await element(by.id('$key')).typeText('${_escapeJs(value)}');");
          }
          break;
        case 'swipe':
          final direction = params['direction'] as String? ?? 'up';
          if (key != null) {
            buf.writeln("    // Swipe $direction on '$key'");
            buf.writeln(
                "    await element(by.id('$key')).swipe('$direction');");
          } else {
            buf.writeln("    // Swipe $direction on screen");
            buf.writeln(
                "    await element(by.id('scrollView')).swipe('$direction');");
          }
          break;
        case 'screenshot':
          buf.writeln("    // Take screenshot");
          buf.writeln(
              "    await device.takeScreenshot('step_${_recordedSteps.indexOf(step)}');");
          break;
        case 'scroll':
          final dy = (params['dy'] ?? 200) as num;
          final direction = dy > 0 ? 'down' : 'up';
          buf.writeln("    // Scroll $direction");
          buf.writeln(
              "    await element(by.id('scrollView')).scroll(${dy.abs()}, '$direction');");
          break;
        case 'assert_visible':
          if (key != null) {
            buf.writeln("    // Assert '$key' is visible");
            buf.writeln(
                "    await expect(element(by.id('$key'))).toBeVisible();");
          } else if (text != null) {
            buf.writeln("    // Assert text '$text' is visible");
            buf.writeln(
                "    await expect(element(by.text('${_escapeJs(text)}'))).toBeVisible();");
          }
          break;
        default:
          buf.writeln("    // $tool: ${jsonEncode(params)}");
      }
    }
    buf.writeln("  });");
    buf.writeln("});");
    return buf.toString();
  }

  /// Export recorded steps as Maestro (YAML) flow
  String _exportMaestro() {
    final buf = StringBuffer();
    buf.writeln("# Maestro Flow - Recorded Test");
    buf.writeln("# Run with: maestro test recorded_flow.yaml");
    buf.writeln("appId: com.example.app  # TODO: Replace with your app ID");
    buf.writeln("---");
    for (final step in _recordedSteps) {
      final tool = step['tool'] as String;
      final params = step['params'] as Map<String, dynamic>? ?? {};
      final key = params['key'] as String?;
      final text = params['text'] as String?;
      switch (tool) {
        case 'tap':
          if (key != null) {
            buf.writeln("# Tap element with testID '$key'");
            buf.writeln("- tapOn:");
            buf.writeln("    id: \"$key\"");
          } else if (text != null) {
            buf.writeln("# Tap element with text '$text'");
            buf.writeln("- tapOn: \"${_escapeYaml(text)}\"");
          }
          break;
        case 'enter_text':
          final value =
              params['value'] as String? ?? params['text'] as String? ?? '';
          if (key != null) {
            buf.writeln("# Type text into '$key'");
            buf.writeln("- tapOn:");
            buf.writeln("    id: \"$key\"");
            buf.writeln("- inputText: \"${_escapeYaml(value)}\"");
          } else {
            buf.writeln("# Type text");
            buf.writeln("- inputText: \"${_escapeYaml(value)}\"");
          }
          break;
        case 'swipe':
          final direction = params['direction'] as String? ?? 'up';
          buf.writeln("# Swipe $direction");
          switch (direction) {
            case 'up':
              buf.writeln("- swipe:");
              buf.writeln("    direction: UP");
              break;
            case 'down':
              buf.writeln("- swipe:");
              buf.writeln("    direction: DOWN");
              break;
            case 'left':
              buf.writeln("- swipe:");
              buf.writeln("    direction: LEFT");
              break;
            case 'right':
              buf.writeln("- swipe:");
              buf.writeln("    direction: RIGHT");
              break;
          }
          break;
        case 'screenshot':
          buf.writeln("# Take screenshot");
          buf.writeln("- takeScreenshot: step_${_recordedSteps.indexOf(step)}");
          break;
        case 'scroll':
          final dy = params['dy'] ?? 200;
          final direction = (dy as num) > 0 ? 'DOWN' : 'UP';
          buf.writeln("# Scroll $direction");
          buf.writeln("- scroll:");
          buf.writeln("    direction: $direction");
          break;
        case 'assert_visible':
          if (key != null) {
            buf.writeln("# Assert '$key' is visible");
            buf.writeln("- assertVisible:");
            buf.writeln("    id: \"$key\"");
          } else if (text != null) {
            buf.writeln("# Assert text '$text' is visible");
            buf.writeln("- assertVisible: \"${_escapeYaml(text)}\"");
          }
          break;
        case 'wait':
          final ms = params['timeout_ms'] ?? params['ms'] ?? 1000;
          buf.writeln("# Wait");
          buf.writeln("- extendedWaitUntil:");
          buf.writeln("    visible: \".*\"");
          buf.writeln("    timeout: $ms");
          break;
        default:
          buf.writeln("# $tool: ${jsonEncode(params)}");
      }
    }
    return buf.toString();
  }

  String _escapeYaml(String s) => s.replaceAll('"', '\\"');
}
