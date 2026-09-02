import 'package:flutter/material.dart';
import 'package:flutter_skill/flutter_skill.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for resolving an element from the `key` an agent supplies.
///
/// Agents address widgets by a single opaque string, so lookup has to cover
/// more than `ValueKey<String>`: design-system widgets often expose nothing but
/// `Semantics(identifier: ...)`, and keys are frequently built from ints or
/// enums. Matches also have to be ordered — a route pushed on top stays behind
/// the still-mounted route below it in a pre-order walk.
void main() {
  Element? find(String key) =>
      FlutterSkillBinding.findElementByKeyForTesting(key);

  group('element lookup by key', () {
    testWidgets('should resolve a ValueKey<String>', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Text('hello', key: ValueKey<String>('greeting')),
      ));

      expect(find('greeting')?.widget, isA<Text>());
    });

    testWidgets('should resolve a key whose value is not a String',
        (tester) async {
      // Keys built from ints or enums previously never matched, because lookup
      // tested for ValueKey<String> specifically.
      await tester.pumpWidget(const MaterialApp(
        home: Text('row', key: ValueKey<int>(42)),
      ));

      expect(find('42')?.widget, isA<Text>());
    });

    testWidgets('should resolve a Semantics identifier', (tester) async {
      // The design-system shape from the report: the editable is wrapped and
      // its key is private, so the identifier is the only handle an agent has.
      await tester.pumpWidget(MaterialApp(
        home: Material(
          child: Semantics(
            identifier: 'email_field',
            child: TextField(),
          ),
        ),
      ));

      final element = find('email_field');
      expect(element, isNotNull);
      expect(element!.widget, isA<Semantics>());

      // Lookup must land somewhere that still contains the editable, otherwise
      // enter_text cannot descend to it.
      expect(
        descendantEditableText(element),
        isNotNull,
        reason: 'enter_text resolves the EditableText below the match',
      );
    });

    testWidgets('should resolve a Semantics label', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Semantics(
          label: 'Submit order',
          child: SizedBox(width: 10, height: 10),
        ),
      ));

      expect(find('Submit order')?.widget, isA<Semantics>());
    });

    testWidgets('should prefer a widget key over a semantics label',
        (tester) async {
      // A label is human-readable text and can collide with an unrelated
      // widget's key, so the real key has to win.
      await tester.pumpWidget(MaterialApp(
        home: Column(
          children: [
            Semantics(label: 'submit', child: SizedBox(width: 1, height: 1)),
            Text('Submit', key: ValueKey<String>('submit')),
          ],
        ),
      ));

      expect(find('submit')?.widget, isA<Text>());
    });

    testWidgets('should prefer the topmost route when a key appears twice',
        (tester) async {
      // The background route stays mounted under a pushed route and is visited
      // first, so returning the first match would tap an invisible widget.
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: const Text('background', key: ValueKey<String>('shared')),
      ));

      navigatorKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Text('foreground', key: ValueKey<String>('shared')),
      ));
      await tester.pumpAndSettle();

      expect((find('shared')!.widget as Text).data, 'foreground');
    });

    testWidgets('should return null when nothing matches', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('hello')));

      expect(find('no_such_key'), isNull);
    });
  });
}

/// Mirrors the descent `enter_text` performs from a matched element down to the
/// editable it wraps.
Element? descendantEditableText(Element root) {
  Element? found;
  void visit(Element element) {
    if (found != null) return;
    if (element.widget is EditableText) {
      found = element;
      return;
    }
    element.visitChildren(visit);
  }

  visit(root);
  return found;
}
