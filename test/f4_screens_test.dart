import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:round_ai/core/errors/result.dart';
import 'package:round_ai/features/ai/models/ai_envelope.dart';
import 'package:round_ai/features/notes/models/note_template.dart';
import 'package:round_ai/features/notes/screens/note_draft_screen.dart';
import 'package:round_ai/features/patient/models/problem.dart';
import 'package:round_ai/features/problems/repository/problems_repository.dart';
import 'package:round_ai/features/problems/widgets/problems_card.dart';
import 'package:round_ai/shared/widgets/app_input.dart';

import 'support/fake_ai_repository.dart';
import 'support/fake_notes_problems.dart';

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// onPressed of the button that holds [label]. Icon buttons are subclasses,
/// so they are found by their base type.
VoidCallback? _onPressed(WidgetTester tester, String label) {
  return tester
      .widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (Widget w) => w is ButtonStyleButton,
          ),
        ),
      )
      .onPressed;
}

Future<void> _usePerField(WidgetTester tester) async {
  final Finder advanced = find.widgetWithText(ChoiceChip, 'Per-field (advanced)');
  // Templates-failed screens have no mode chips yet.
  if (advanced.evaluate().isEmpty) return;
  await tester.ensureVisible(advanced);
  await tester.tap(advanced);
  await tester.pumpAndSettle();
  expect(find.text('Generate draft'), findsOneWidget);
}

Future<void> _pumpNote(
  WidgetTester tester,
  FakeNotesRepository notes,
  FakeAiRepository ai, {
  bool aiOff = false,
  bool scribeMode = false,
}) async {
  _wide(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: NoteDraftScreen(
        patientId: 'p1',
        notesRepository: notes,
        aiRepository: ai,
        aiOff: aiOff,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (!scribeMode) await _usePerField(tester);
}

Future<void> _seedAdvancedField(WidgetTester tester) async {
  final Finder fields = find.byType(TextField);
  expect(fields, findsWidgets);
  for (final Element el in fields.evaluate()) {
    final TextEditingController? c = (el.widget as TextField).controller;
    if (c != null && c.text.trim().isNotEmpty) return;
  }
  await tester.enterText(fields.first, 'Clinical update entered for test.');
  await tester.pump();
}

Future<void> _generate(WidgetTester tester) async {
  final Finder btn = find.text('Generate draft');
  expect(btn, findsOneWidget);
  await _seedAdvancedField(tester);
  await tester.ensureVisible(btn);
  await tester.tap(btn);
  await tester.pumpAndSettle();
}

Future<void> _pumpProblems(
  WidgetTester tester,
  FakeProblemsRepository repo, {
  List<Problem> initial = const <Problem>[],
  bool aiOff = false,
  VoidCallback? onChanged,
}) async {
  _wide(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProblemsCard(
            patientId: 'p1',
            initial: initial,
            aiOff: aiOff,
            onChanged: onChanged ?? () {},
            repository: repo,
            aiRepository: FakeAiRepository(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

AiEnvelope _flagged() => noteEnvelope(
  sections: <Object>[
    <String, Object>{
      'key': 'data',
      'title': 'Data',
      'source': 'facts',
      'text': 'Creatinine 9.9.',
      'fact_ids': <String>['f1'],
      'flags': <Object>[
        <String, Object>{
          'code': 'unsupported_number',
          'message': '9.9 is not in the chart',
        },
      ],
    },
    <String, Object>{
      'key': 'exam',
      'title': 'Exam',
      'source': 'exam',
      'text': 'Exam: [Exam not entered]',
    },
  ],
);

void main() {
  group('note screen', () {
    testWidgets('the form is built from the template sources', (
      WidgetTester tester,
    ) async {
      await _pumpNote(tester, FakeNotesRepository(), FakeAiRepository());
      expect(find.text('Progress note'), findsOneWidget);
      expect(find.text('Admission H&P'), findsOneWidget);
      expect(find.text('ICU note'), findsOneWidget);
      // Typed sections get a field, generated ones do not.
      expect(find.widgetWithText(TextField, 'Subjective'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Exam'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Plan'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Data'), findsNothing);
      expect(
        find.textContaining('Written from confirmed chart facts: Data'),
        findsOneWidget,
      );
      // The privacy hint sits under every free-text field.
      expect(find.text(FreeTextHint.text), findsNWidgets(3));
      // Nothing is an AI draft before one exists.
      expect(find.text('Draft · review required'), findsNothing);
      expect(find.text('Mark reviewed'), findsNothing);
    });

    testWidgets('history shows its eight fields', (WidgetTester tester) async {
      await _pumpNote(tester, FakeNotesRepository(), FakeAiRepository());
      await tester.tap(find.text('Admission H&P'));
      await tester.pumpAndSettle();
      for (final (String _, String label) in historyFields) {
        expect(find.widgetWithText(TextField, label), findsOneWidget);
      }
      // Eight history fields + exam + plan.
      expect(find.text(FreeTextHint.text), findsNWidgets(10));
    });

    testWidgets('only what was typed is sent', (WidgetTester tester) async {
      final FakeNotesRepository notes = FakeNotesRepository();
      await _pumpNote(tester, notes, FakeAiRepository());
      // Prefer label-based find; fall back to first clinician TextField.
      Finder subjective = find.widgetWithText(TextField, 'Subjective');
      if (subjective.evaluate().isEmpty) {
        subjective = find.byType(TextField).first;
      }
      await tester.enterText(subjective, ' Feels better ');
      await tester.pump();
      await tester.tap(find.text('Generate draft'));
      await tester.pumpAndSettle();
      expect(notes.generateTypes, <String>['progress']);
      expect(notes.generateInputs.single, <String, Object>{
        'subjective': 'Feels better',
      });
    });

    testWidgets('typed history is sent as a map of its keys', (
      WidgetTester tester,
    ) async {
      final FakeNotesRepository notes = FakeNotesRepository();
      await _pumpNote(tester, notes, FakeAiRepository());
      await tester.tap(find.text('Admission H&P'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Chief complaint'),
        'Dyspnea',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Allergies'),
        'PCN',
      );
      await _generate(tester);
      expect(notes.generateTypes, <String>['admit_hp']);
      expect(notes.generateInputs.single, <String, Object>{
        'history': <String, String>{
          'chief_complaint': 'Dyspnea',
          'allergies': 'PCN',
        },
      });
    });

    testWidgets('a draft is labelled and its sections are cards', (
      WidgetTester tester,
    ) async {
      await _pumpNote(tester, FakeNotesRepository(), FakeAiRepository());
      await _generate(tester);
      expect(find.text('Draft · review required'), findsOneWidget);
      expect(find.text('Draft ready'), findsOneWidget);
      expect(find.text('Feels better today.'), findsOneWidget);
      expect(find.text('Creatinine 1.7.'), findsOneWidget);
      expect(find.text('Clinician entered'), findsOneWidget);
      expect(find.text('From chart'), findsOneWidget);
      expect(find.text('Source 1'), findsOneWidget);
      expect(_onPressed(tester, 'Mark reviewed'), isNotNull);
      expect(find.text('Regenerate draft'), findsOneWidget);
      // The template cannot be switched under a draft.
      final ChoiceChip chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'ICU note'),
      );
      expect(chip.onSelected, isNull);
    });

    testWidgets('a source chip opens the chart source', (
      WidgetTester tester,
    ) async {
      final FakeAiRepository ai = FakeAiRepository();
      await _pumpNote(tester, FakeNotesRepository(), ai);
      await _generate(tester);
      await tester.tap(find.text('Source 1'));
      await tester.pumpAndSettle();
      expect(ai.sourceRequests, <String>['f1']);
      expect(find.text('“Cr 1.7 this morning”'), findsOneWidget);
    });

    testWidgets('flags and "Not entered" disable review with reasons', (
      WidgetTester tester,
    ) async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..generated = Ok<AiEnvelope>(_flagged());
      await _pumpNote(tester, notes, FakeAiRepository());
      await _generate(tester);
      expect(find.text('9.9 is not in the chart'), findsOneWidget);
      expect(find.text('Exam: [Exam not entered]'), findsOneWidget);
      expect(_onPressed(tester, 'Mark reviewed'), isNull);
      expect(find.text('Data has a flag to resolve.'), findsOneWidget);
      expect(
        find.text('Exam still has information that is not entered.'),
        findsOneWidget,
      );
    });

    testWidgets('an outdated draft says so and cannot be reviewed', (
      WidgetTester tester,
    ) async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..generated = Ok<AiEnvelope>(noteEnvelope(outdated: true));
      await _pumpNote(tester, notes, FakeAiRepository());
      await _generate(tester);
      expect(find.text('Outdated'), findsWidgets);
      expect(find.textContaining('The chart changed after'), findsOneWidget);
      expect(_onPressed(tester, 'Mark reviewed'), isNull);
    });

    testWidgets('a partial result is announced', (WidgetTester tester) async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..generated = Ok<AiEnvelope>(noteEnvelope(status: 'partial'));
      await _pumpNote(tester, notes, FakeAiRepository());
      await _generate(tester);
      expect(find.textContaining('Partial result. '), findsOneWidget);
    });

    testWidgets('copy is off until reviewed, then copies clean text', (
      WidgetTester tester,
    ) async {
      final List<MethodCall> calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final FakeNotesRepository notes = FakeNotesRepository();
      await _pumpNote(tester, notes, FakeAiRepository());
      await _generate(tester);
      expect(_onPressed(tester, 'Copy note text'), isNull);
      expect(
        find.text('Copying is available after the note is reviewed.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Mark reviewed'));
      await tester.pumpAndSettle();
      expect(find.text('Reviewed'), findsWidgets);
      expect(find.text('Draft · review required'), findsNothing);
      expect(find.text('Mark reviewed'), findsNothing);
      expect(_onPressed(tester, 'Copy note text'), isNotNull);

      await tester.tap(find.text('Copy note text'));
      await tester.pumpAndSettle();
      expect(notes.exportCalls, 1);
      final MethodCall set = calls.firstWhere(
        (MethodCall c) => c.method == 'Clipboard.setData',
      );
      expect(
        (set.arguments as Map<Object?, Object?>)['text'],
        'Clean note text',
      );
      expect(find.text('Note text copied.'), findsOneWidget);
    });

    testWidgets('a refused review marks the sections the server named', (
      WidgetTester tester,
    ) async {
      final FakeAiRepository ai = FakeAiRepository()
        ..reviewed = Err<AiEnvelope>(
          FakeAiRepository.failure(
            'unresolved_flags',
            status: 409,
            details: <String, dynamic>{
              'sections': <String>['data'],
            },
          ),
        );
      await _pumpNote(tester, FakeNotesRepository(), ai);
      await _generate(tester);
      await tester.tap(find.text('Mark reviewed'));
      await tester.pumpAndSettle();
      expect(find.text('1 section is marked above.'), findsOneWidget);
      expect(find.text('raw'), findsNothing);
    });

    testWidgets('edit saves with the typed text', (WidgetTester tester) async {
      final FakeNotesRepository notes = FakeNotesRepository();
      await _pumpNote(tester, notes, FakeAiRepository());
      await _generate(tester);
      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();
      expect(find.text('Edit Subjective'), findsOneWidget);
      // The hint is also under the edit field.
      expect(find.text(FreeTextHint.text), findsWidgets);
      await tester.enterText(find.byType(TextField).last, 'Much better');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(notes.saves, <(String, String)>[('subjective', 'Much better')]);
    });

    testWidgets('rewrite shows before and after, and Apply saves', (
      WidgetTester tester,
    ) async {
      final FakeNotesRepository notes = FakeNotesRepository();
      await _pumpNote(tester, notes, FakeAiRepository());
      await _generate(tester);
      await tester.tap(find.text('Rewrite').first);
      await tester.pumpAndSettle();
      for (final String mode in <String>[
        'Regenerate',
        'Shorten',
        'Expand',
        'Improve',
      ]) {
        expect(find.text(mode), findsOneWidget);
      }
      await tester.tap(find.text('Shorten'));
      await tester.pumpAndSettle();
      expect(find.text('Shorten: Subjective'), findsOneWidget);
      expect(find.text('Before'), findsOneWidget);
      expect(find.text('After'), findsOneWidget);
      expect(find.text('Shorter text.'), findsOneWidget);
      // Nothing was saved yet.
      expect(notes.saves, isEmpty);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(notes.saves, <(String, String)>[('subjective', 'Shorter text.')]);
    });

    testWidgets('Keep current saves nothing', (WidgetTester tester) async {
      final FakeNotesRepository notes = FakeNotesRepository();
      await _pumpNote(tester, notes, FakeAiRepository());
      await _generate(tester);
      await tester.tap(find.text('Rewrite').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expand'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep current'));
      await tester.pumpAndSettle();
      expect(notes.saves, isEmpty);
      expect(find.text('Feels better today.'), findsOneWidget);
    });

    testWidgets('a failed generate reads plainly and Retry works', (
      WidgetTester tester,
    ) async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..generated = Err<AiEnvelope>(
          FakeAiRepository.failure('network_error'),
        );
      await _pumpNote(tester, notes, FakeAiRepository());
      await _generate(tester);
      expect(find.text('raw'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      notes.generated = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Feels better today.'), findsOneWidget);
      expect(notes.generateKeys[0], notes.generateKeys[1]);
    });

    testWidgets('no confirmed facts offers the facts screen', (
      WidgetTester tester,
    ) async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..generated = Err<AiEnvelope>(
          FakeAiRepository.failure('no_reviewed_facts', status: 409),
        );
      await _pumpNote(tester, notes, FakeAiRepository());
      await _generate(tester);
      expect(find.text('Review chart facts first'), findsOneWidget);
    });

    testWidgets('cancel stops the draft', (WidgetTester tester) async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final Completer<Result<AiEnvelope>> never =
          Completer<Result<AiEnvelope>>();
      notes.onGenerate = (_) => never.future;
      await _pumpNote(tester, notes, FakeAiRepository());
      await _seedAdvancedField(tester);
      await tester.tap(find.text('Generate draft'));
      await tester.pump();
      expect(find.textContaining('Writing the draft'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      expect(notes.lastToken!.isCancelled, isTrue);
      never.complete(Err<AiEnvelope>(FakeAiRepository.failure('cancelled')));
      await tester.pumpAndSettle();
      expect(find.text('Generate draft'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('AI off disables generating and says so', (
      WidgetTester tester,
    ) async {
      await _pumpNote(
        tester,
        FakeNotesRepository(),
        FakeAiRepository(),
        aiOff: true,
      );
      expect(_onPressed(tester, 'Generate draft'), isNull);
      expect(find.text(noteAiOffMessage), findsOneWidget);
    });

    testWidgets('dictation generate stays disabled until text is entered', (
      WidgetTester tester,
    ) async {
      await _pumpNote(
        tester,
        FakeNotesRepository(),
        FakeAiRepository(),
        scribeMode: true,
      );
      expect(find.text('Write note from dictation'), findsWidgets);
      expect(_onPressed(tester, 'Write note from dictation'), isNull);
      await tester.enterText(
        find.widgetWithText(TextField, 'Dictation'),
        'Overnight creatinine rose; continue IVF and check labs.',
      );
      await tester.pump();
      expect(_onPressed(tester, 'Write note from dictation'), isNotNull);
    });

    testWidgets('dictation failure keeps text and offers retry', (
      WidgetTester tester,
    ) async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..generated = Err<AiEnvelope>(
          FakeAiRepository.failure('internal', status: 500),
        );
      await _pumpNote(tester, notes, FakeAiRepository(), scribeMode: true);
      const String typed =
          'Patient had fever overnight. Plan continue IVF and check labs.';
      await tester.enterText(find.widgetWithText(TextField, 'Dictation'), typed);
      await tester.pump();
      await tester.tap(find.text('Write note from dictation').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Note generation failed'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Dictation'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.widgetWithText(TextField, 'Dictation')).controller?.text,
        typed,
      );
    });

    testWidgets('templates that fail to load can be retried', (
      WidgetTester tester,
    ) async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..templatesResult = Err<List<NoteTemplate>>(
          FakeAiRepository.failure('network_error'),
        );
      await _pumpNote(tester, notes, FakeAiRepository());
      expect(find.text('Note templates could not be loaded.'), findsOneWidget);
      notes.templatesResult = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Progress note'), findsOneWidget);
    });
  });

  group('problems card', () {
    testWidgets('states are labelled and a suggestion is never "Confirmed"', (
      WidgetTester tester,
    ) async {
      final List<Problem> list = <Problem>[
        problem('d1', 'CHF', state: ProblemState.documented),
        problem('s1', 'AKI'),
        problem('c1', 'HTN', state: ProblemState.confirmed),
        problem('f1', 'PE', state: ProblemState.differential),
        problem('r1', 'Sepsis', state: ProblemState.rejected),
      ];
      await _pumpProblems(
        tester,
        FakeProblemsRepository(list: list),
        initial: list,
      );
      expect(find.text('Documented in source'), findsOneWidget);
      expect(find.text('Suggested by AI'), findsOneWidget);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.text('Differential'), findsNWidgets(3));
      expect(find.text('Rejected'), findsOneWidget);
      // Only the suggestion carries the AI label.
      expect(find.text('AI draft · review required'), findsOneWidget);
      // Accept is for suggestions, Confirm for documented ones.
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Confirm'), findsOneWidget);
    });

    testWidgets('an empty list still offers Suggest problems', (
      WidgetTester tester,
    ) async {
      await _pumpProblems(tester, FakeProblemsRepository());
      expect(find.textContaining('No problems yet'), findsOneWidget);
      expect(_onPressed(tester, 'Suggest problems'), isNotNull);
    });

    testWidgets(
      'suggest shows new suggestions with Accept / Differential / Reject',
      (WidgetTester tester) async {
        final FakeProblemsRepository repo = FakeProblemsRepository()
          ..suggested = Ok<List<Problem>>(<Problem>[
            problem('s1', 'AKI', factIds: const <String>['f1']),
            problem('s2', 'Hyponatremia'),
          ]);
        await _pumpProblems(tester, repo);
        await tester.tap(find.text('Suggest problems'));
        await tester.pumpAndSettle();
        expect(find.text('AKI'), findsOneWidget);
        expect(find.text('Hyponatremia'), findsOneWidget);
        expect(find.text('Suggested by AI'), findsNWidgets(2));
        expect(find.text('AI draft · review required'), findsNWidgets(2));
        expect(find.text('Confirmed'), findsNothing);
        expect(find.text('Accept'), findsNWidgets(2));
        expect(find.text('Differential'), findsNWidgets(2));
        expect(find.text('Reject'), findsNWidgets(2));
        expect(find.text('Source (1 fact)'), findsOneWidget);
      },
    );

    testWidgets('no suggestions says so', (WidgetTester tester) async {
      await _pumpProblems(tester, FakeProblemsRepository());
      await tester.tap(find.text('Suggest problems'));
      await tester.pumpAndSettle();
      expect(
        find.text('No problems were suggested from the confirmed facts.'),
        findsOneWidget,
      );
    });

    testWidgets('Accept confirms only after the save, and tells the screen', (
      WidgetTester tester,
    ) async {
      int changed = 0;
      final FakeProblemsRepository repo = FakeProblemsRepository(
        list: <Problem>[problem('s1', 'AKI')],
      )..applyDecisions = true;
      await _pumpProblems(
        tester,
        repo,
        initial: <Problem>[problem('s1', 'AKI')],
        onChanged: () => changed++,
      );
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(repo.decisions, <(String, ProblemAction)>[
        ('s1', ProblemAction.accept),
      ]);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.text('Suggested by AI'), findsNothing);
      expect(find.text('AI draft · review required'), findsNothing);
      expect(changed, 1);
    });

    testWidgets('Reject strikes the problem and records it', (
      WidgetTester tester,
    ) async {
      final FakeProblemsRepository repo = FakeProblemsRepository(
        list: <Problem>[problem('s1', 'AKI')],
      )..applyDecisions = true;
      await _pumpProblems(
        tester,
        repo,
        initial: <Problem>[problem('s1', 'AKI')],
      );
      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();
      expect(repo.decisions.single.$2, ProblemAction.reject);
      expect(find.text('Rejected'), findsOneWidget);
      expect(find.text('Reject'), findsNothing);
    });

    testWidgets('a failed decision leaves the suggestion and says why', (
      WidgetTester tester,
    ) async {
      final FakeProblemsRepository repo = FakeProblemsRepository(
        list: <Problem>[problem('s1', 'AKI')],
      )..decision = Err<void>(FakeAiRepository.failure('network_error'));
      await _pumpProblems(
        tester,
        repo,
        initial: <Problem>[problem('s1', 'AKI')],
      );
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(find.text('Suggested by AI'), findsOneWidget);
      expect(find.text('Confirmed'), findsNothing);
      expect(find.text('raw'), findsNothing);
    });

    testWidgets('no confirmed facts offers the facts screen', (
      WidgetTester tester,
    ) async {
      final FakeProblemsRepository repo = FakeProblemsRepository()
        ..onSuggest = (_) async => Err<List<Problem>>(
          FakeAiRepository.failure('no_reviewed_facts', status: 409),
        );
      await _pumpProblems(tester, repo);
      await tester.tap(find.text('Suggest problems'));
      await tester.pumpAndSettle();
      expect(find.text('Review chart facts first'), findsOneWidget);
    });

    testWidgets('a failed suggest can be retried with the same key', (
      WidgetTester tester,
    ) async {
      final FakeProblemsRepository repo = FakeProblemsRepository();
      int calls = 0;
      repo.onSuggest = (_) async {
        calls++;
        return calls == 1
            ? Err<List<Problem>>(FakeAiRepository.failure('network_error'))
            : Ok<List<Problem>>(<Problem>[problem('s1', 'AKI')]);
      };
      await _pumpProblems(tester, repo);
      await tester.tap(find.text('Suggest problems'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('AKI'), findsOneWidget);
      expect(repo.suggestKeys[0], repo.suggestKeys[1]);
    });

    testWidgets('AI off disables Suggest and says so', (
      WidgetTester tester,
    ) async {
      await _pumpProblems(tester, FakeProblemsRepository(), aiOff: true);
      expect(_onPressed(tester, 'Suggest problems'), isNull);
      expect(find.text(problemsAiOffMessage), findsOneWidget);
    });
  });
}
