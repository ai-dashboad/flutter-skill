import 'dart:io';

/// Launch a built-in demo app for instant testing — zero dependencies.
Future<void> runDemo(List<String> args) async {
  print('');
  print('🚀 Flutter Skill Demo');
  print('═══════════════════════════════════════════════════');
  print('');

  // Create temp Flutter project
  final tempDir = await Directory.systemTemp.createTemp('flutter_skill_demo_');
  final projectPath = tempDir.path;

  print('📦 Creating demo app...');

  // Check if flutter is available
  final flutterCheck = await Process.run('flutter', ['--version']);
  if (flutterCheck.exitCode != 0) {
    print('❌ Flutter not found. Please install Flutter first.');
    print('   https://flutter.dev/docs/get-started/install');
    exit(1);
  }

  // Create Flutter project
  final createResult = await Process.run(
    'flutter',
    ['create', '--project-name', 'flutter_skill_demo', '.'],
    workingDirectory: projectPath,
  );

  if (createResult.exitCode != 0) {
    print('❌ Failed to create demo project: ${createResult.stderr}');
    exit(1);
  }

  print('   ✅ Project created');

  // Add flutter_skill dependency
  print('📦 Adding flutter_skill...');
  final addResult = await Process.run(
    'flutter',
    ['pub', 'add', 'flutter_skill'],
    workingDirectory: projectPath,
  );

  if (addResult.exitCode != 0) {
    print('⚠️  Could not add flutter_skill from pub.dev, using path...');
  }

  // Write demo main.dart
  print('✍️  Writing demo app...');
  final mainFile = File('$projectPath/lib/main.dart');
  mainFile.writeAsStringSync(_demoAppCode);
  print('   ✅ Demo app ready');

  print('');
  print('🚀 Launching demo app...');
  print('');
  print('═══════════════════════════════════════════════════');
  print('  Demo is running! Tell your AI agent:');
  print('');
  print('  "Inspect the demo app and tap the + button"');
  print('  "Enter text in the search field"');
  print('  "Navigate to the settings tab"');
  print('  "Take a screenshot"');
  print('');
  print('  Press Ctrl+C to stop');
  print('═══════════════════════════════════════════════════');
  print('');

  // Launch with flutter-skill
  final process = await Process.start(
    'flutter',
    ['run'],
    workingDirectory: projectPath,
    mode: ProcessStartMode.inheritStdio,
  );

  // Handle cleanup on exit
  ProcessSignal.sigint.watch().listen((_) async {
    process.kill();
    await tempDir.delete(recursive: true);
    exit(0);
  });

  final exitCode = await process.exitCode;

  // Cleanup
  try {
    await tempDir.delete(recursive: true);
  } catch (_) {}

  exit(exitCode);
}

const String _demoAppCode = r"""
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_skill/flutter_skill.dart';

void main() {
  if (kDebugMode) {
    FlutterSkillBinding.ensureInitialized();
  }
  runApp(const FlutterSkillDemoApp());
}

class FlutterSkillDemoApp extends StatelessWidget {
  const FlutterSkillDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Skill Demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
      ),
      home: const DemoHomePage(),
    );
  }
}

class DemoHomePage extends StatefulWidget {
  const DemoHomePage({super.key});

  @override
  State<DemoHomePage> createState() => _DemoHomePageState();
}

class _DemoHomePageState extends State<DemoHomePage> {
  int _selectedTab = 0;
  int _counter = 0;
  bool _switchValue = false;
  double _sliderValue = 50;
  String _searchText = '';
  final _searchController = TextEditingController();

  final List<String> _items = [
    'Buy groceries',
    'Review pull request',
    'Call dentist',
    'Update dependencies',
    'Write documentation',
    'Go for a run',
    'Read a book',
    'Clean the kitchen',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        key: const Key('appBar'),
        title: const Text('Flutter Skill Demo'),
        actions: [
          IconButton(
            key: const Key('settings_button'),
            icon: const Icon(Icons.settings),
            onPressed: () => _showSettings(context),
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedTab,
        children: [
          _buildHomeTab(),
          _buildListTab(),
          _buildFormTab(),
        ],
      ),
      floatingActionButton: _selectedTab == 0
          ? FloatingActionButton(
              key: const Key('fab_increment'),
              onPressed: () => setState(() => _counter++),
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        key: const Key('bottom_nav'),
        selectedIndex: _selectedTab,
        onDestinationSelected: (i) => setState(() => _selectedTab = i),
        destinations: const [
          NavigationDestination(
            key: Key('tab_home'),
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            key: Key(  'tab_list'),
            icon: Icon(Icons.list),
            label: 'Tasks',
          ),
          NavigationDestination(
            key: Key('tab_form'),
            icon: Icon(Icons.edit),
            label: 'Form',
          ),
        ],
      ),
    );
  }

  Widget _buildHomeTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Welcome to Flutter Skill Demo!',
              key: Key('welcome_text'),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          Text('Counter: $_counter',
              key: const Key('counter_text'),
              style: const TextStyle(fontSize: 48)),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                key: const Key('decrement_button'),
                onPressed: () => setState(() => _counter--),
                child: const Text('Decrease'),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                key: const Key('reset_button'),
                onPressed: () => setState(() => _counter = 0),
                child: const Text('Reset'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildListTab() {
    final filtered = _items
        .where((i) => i.toLowerCase().contains(_searchText.toLowerCase()))
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            key: const Key('search_field'),
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: 'Search tasks...',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _searchText = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            key: const Key('task_list'),
            itemCount: filtered.length,
            itemBuilder: (ctx, i) => ListTile(
              key: Key('task_$i'),
              leading: Checkbox(
                key: Key('checkbox_$i'),
                value: false,
                onChanged: (_) {},
              ),
              title: Text(filtered[i]),
              trailing: IconButton(
                key: Key('delete_$i'),
                icon: const Icon(Icons.delete),
                onPressed: () => setState(() => _items.remove(filtered[i])),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFormTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Settings Form',
              key: Key('form_title'),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          TextField(
            key: const Key('name_field'),
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('email_field'),
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            key: const Key('notifications_switch'),
            title: const Text('Enable Notifications'),
            value: _switchValue,
            onChanged: (v) => setState(() => _switchValue = v),
          ),
          const SizedBox(height: 16),
          Text('Volume: ${_sliderValue.round()}%'),
          Slider(
            key: const Key('volume_slider'),
            value: _sliderValue,
            min: 0,
            max: 100,
            onChanged: (v) => setState(() => _sliderValue = v),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const Key('submit_button'),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    key: Key('success_snackbar'),
                    content: Text('Form submitted successfully!'),
                  ),
                );
              },
              child: const Text('Submit'),
            ),
          ),
        ],
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('settings_dialog'),
        title: const Text('Settings'),
        content: const Text('This is a demo dialog. AI agents can interact with dialogs too!'),
        actions: [
          TextButton(
            key: const Key('dialog_cancel'),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('dialog_ok'),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
""";
