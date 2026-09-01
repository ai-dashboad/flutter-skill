import 'dart:io';
import '../diagnostics/error_reporter.dart';

/// CLI command to manually report errors
Future<void> runReportError(List<String> args) async {
  stdout.writeln('🐛 flutter-skill Error Reporter');
  stdout.writeln('');

  // Check for GitHub token
  final token = Platform.environment['GITHUB_TOKEN'];
  if (token == null) {
    stderr.writeln('⚠️  GITHUB_TOKEN environment variable not set.');
    stderr.writeln(
        'To enable auto-reporting, set your GitHub personal access token:');
    stderr.writeln('  export GITHUB_TOKEN=your_token_here');
    stderr.writeln('');
    stderr.writeln('Or manually create an issue at:');
    stderr.writeln('  https://github.com/your-org/flutter-skill/issues/new');
    exit(1);
  }

  // Interactive error report
  stdout.write('Error title: ');
  final title = stdin.readLineSync() ?? 'Untitled Error';

  stdout.writeln('');
  stdout.writeln('Error description (end with Ctrl+D or empty line):');
  final descriptionLines = <String>[];
  while (true) {
    final line = stdin.readLineSync();
    if (line == null || line.isEmpty) break;
    descriptionLines.add(line);
  }
  final description = descriptionLines.join('\n');

  // Collect system info
  final diagnostics = {
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'dart_version': Platform.version,
  };

  final reporter = ErrorReporter(
    owner: 'your-org', // TODO: Replace with actual org
    repo: 'flutter-skill',
    githubToken: token,
  );

  // Check for similar issues first
  stdout.writeln('');
  stdout.writeln('Searching for similar issues...');
  final similarIssues = await reporter.findSimilarIssues(title);

  if (similarIssues.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Found ${similarIssues.length} similar issue(s):');
    for (final issue in similarIssues.take(3)) {
      stdout.writeln('  - [${issue['state']}] ${issue['title']}');
      stdout.writeln('    ${issue['url']}');
    }
    stdout.writeln('');
    stdout.write('Continue creating a new issue? (y/n): ');
    final answer = stdin.readLineSync();
    if (answer?.toLowerCase() != 'y') {
      stdout.writeln('Cancelled.');
      exit(0);
    }
  }

  // Create issue
  stdout.writeln('');
  stdout.writeln('Creating GitHub issue...');

  try {
    final issueUrl = await reporter.reportError(
      errorType: 'User Report',
      errorMessage: title,
      stackTrace: StackTrace.fromString(description),
      context: diagnostics,
      autoCreate: true,
    );

    if (issueUrl != null) {
      stdout.writeln('');
      stdout.writeln('✅ Issue created successfully!');
      stdout.writeln('   $issueUrl');
    } else {
      stderr.writeln('');
      stderr.writeln('❌ Failed to create issue.');
      stderr.writeln('Please create manually at:');
      stderr.writeln('  https://github.com/your-org/flutter-skill/issues/new');
    }
  } catch (e) {
    stderr.writeln('');
    stderr.writeln('❌ Error: $e');
    exit(1);
  }
}
