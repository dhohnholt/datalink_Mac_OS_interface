import 'dart:ui' show Tristate;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'accessibility_test.dart' as a;

/// What VoiceOver is told. Walks the semantics tree of each screen.
List<SemanticsNode> allNodes(WidgetTester tester) {
  final out = <SemanticsNode>[];
  void walk(SemanticsNode node) {
    out.add(node);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
  return out;
}

bool isHeader(SemanticsNode node) => node.getSemanticsData().flagsCollection.isHeader;

void main() {
  testWidgets('each screen has headings to navigate by', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final services = await a.open(tester);
      for (final entry in a.screens.entries) {
        await entry.value(tester, services, 1);
        final headings = [for (final n in allNodes(tester)) if (isHeader(n)) n.label];
        expect(headings.where((h) => h.isNotEmpty), isNotEmpty, reason: '${entry.key} has no headings');
        await a.tapTab(tester, 'Scan');
      }
    } finally {
      handle.dispose();
    }
  });

  testWidgets('the tabs say which one is chosen', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await a.open(tester);
      SemanticsData tab(String label) =>
          allNodes(tester).firstWhere((n) => n.label.startsWith(label) && n.getSemanticsData().flagsCollection.isSelected != Tristate.none).getSemanticsData();
      expect(tab('Scan').flagsCollection.isSelected, Tristate.isTrue);
      expect(tab('Paper').flagsCollection.isSelected, Tristate.isFalse);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('the Review pane announces how many items wait', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final services = await a.open(tester);
      await a.screens['Analysis · items']!(tester, services, 1);
      expect(find.bySemanticsLabel(RegExp(r'Review, \d+ items? to review')), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('a table cell that can be pressed says whose answer it is', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      final services = await a.open(tester);
      await a.screens['Sessions']!(tester, services, 1);
      expect(find.bySemanticsLabel(RegExp(r'Question 1, .*Ada')), findsWidgets);
    } finally {
      handle.dispose();
    }
  });
}
