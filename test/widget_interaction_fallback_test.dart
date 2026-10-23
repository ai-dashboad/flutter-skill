import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_skill/flutter_skill.dart';

void main() {
  testWidgets(
      'recognizes and invokes fallback callbacks for Material 3 buttons and list tiles',
      (tester) async {
    var buttonActivations = 0;
    bool? checkboxValue;
    bool? switchValue;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              Semantics(
                identifier: 'grant-control',
                child: FilledButton(
                  key: const ValueKey('filled'),
                  onPressed: () => buttonActivations++,
                  child: const Text('Grant'),
                ),
              ),
              CheckboxListTile(
                key: const ValueKey('checkbox'),
                value: checkboxValue ?? false,
                onChanged: (value) => setState(() => checkboxValue = value),
                title: const Text('Consent'),
              ),
              SwitchListTile(
                key: const ValueKey('switch'),
                value: switchValue ?? false,
                onChanged: (value) => setState(() => switchValue = value),
                title: const Text('Enabled'),
              ),
            ],
          ),
        ),
      ),
    ));

    final button =
        tester.widget<FilledButton>(find.byKey(const ValueKey('filled')));
    final checkbox =
        tester.widget<CheckboxListTile>(find.byKey(const ValueKey('checkbox')));
    final switchTile =
        tester.widget<SwitchListTile>(find.byKey(const ValueKey('switch')));

    expect(FlutterSkillBinding.supportsInteractionForTesting(button), isTrue);
    expect(FlutterSkillBinding.supportsInteractionForTesting(checkbox), isTrue);
    expect(
        FlutterSkillBinding.supportsInteractionForTesting(switchTile), isTrue);

    final entries =
        FlutterSkillBinding.inspectInteractiveElementsForTesting()['elements']
            as List<dynamic>;
    Map<String, dynamic> discovered(String key) => entries
        .cast<Map<String, dynamic>>()
        .firstWhere((entry) => entry['key'] == key);
    expect(discovered('filled')['type'], 'FilledButton');
    expect(discovered('filled')['enabled'], isTrue);
    expect(discovered('filled')['identifier'], 'grant-control');
    expect(discovered('checkbox')['type'], 'CheckboxListTile');
    expect(discovered('checkbox')['value'], isFalse);
    expect(discovered('switch')['type'], 'SwitchListTile');
    expect(discovered('switch')['value'], isFalse);

    FlutterSkillBinding.invokeFallbackCallbackForTesting(
        tester.element(find.byKey(const ValueKey('filled'))));
    FlutterSkillBinding.invokeFallbackCallbackForTesting(
        tester.element(find.byKey(const ValueKey('checkbox'))));
    FlutterSkillBinding.invokeFallbackCallbackForTesting(
        tester.element(find.byKey(const ValueKey('switch'))));

    await tester.pump();
    expect(buttonActivations, 1);
    expect(checkboxValue, isTrue);
    expect(switchValue, isTrue);
    expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const ValueKey('checkbox')))
            .value,
        isTrue);
    expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('switch')))
            .value,
        isTrue);
  });
}
