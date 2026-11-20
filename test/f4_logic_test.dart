import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:round_ai/core/errors/result.dart';
import 'package:round_ai/core/network/api_client.dart';
import 'package:round_ai/core/network/idempotency_key.dart';
import 'package:round_ai/core/storage/session_store.dart';
import 'package:round_ai/features/ai/models/ai_envelope.dart';
import 'package:round_ai/features/notes/bloc/note_cubit.dart';
import 'package:round_ai/features/notes/models/note_section.dart';
import 'package:round_ai/features/notes/models/note_template.dart';
import 'package:round_ai/features/notes/repository/notes_repository_impl.dart';
import 'package:round_ai/features/patient/models/problem.dart';
import 'package:round_ai/features/problems/bloc/problems_cubit.dart';
import 'package:round_ai/features/problems/repository/problems_repository.dart';
import 'package:round_ai/features/problems/repository/problems_repository_impl.dart';

import 'support/fake_adapter.dart';
import 'support/fake_ai_repository.dart';
import 'support/fake_notes_problems.dart';

Future<ApiClient> _client(FakeAdapter adapter) async {
  final SessionStore session = SessionStore(MemoryTokenStore());
  await session.save('tok', persist: false);
  return ApiClient(session: session, dio: fakeDio(adapter));
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

Map<String, Object> _noteBody(String id) => <String, Object>{
  'artifact_id': id,
  'operation': 'draft_note',
  'patient_id': 'p1',
  'context_revision': 2,
  'status': 'draft',
  'review_state': 'draft',
  'outdated': false,
  'created_at': '2026-11-12T09:00:00Z',
  'content': <String, Object>{
    'sections': <Object>[
      <String, Object>{'key': 'plan', 'text': 'Continue.'},
    ],
  },
};

NoteCubit _cubit(FakeNotesRepository notes, FakeAiRepository ai) =>
    NoteCubit(notes, ai, 'p1');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('note templates', () {
    test('sections keep their source and only some are typed', () {
      final NoteTemplate progress = sampleTemplates().first;
      expect(progress.type, 'progress');
      expect(progress.name, 'Progress note');
      expect(
        progress.sections.map((TemplateSection s) => s.source),
        <SectionSource>[
          SectionSource.clinicianSubjective,
          SectionSource.exam,
          SectionSource.facts,
          SectionSource.plan,
        ],
      );
      expect(progress.typedSections.map((TemplateSection s) => s.key), <String>[
        'subjective',
        'exam',
        'plan',
      ]);
    });

    test('an unknown source is generated, never typed', () {
      expect(SectionSource.parse('something_new'), SectionSource.facts);
      expect(SectionSource.parse(null).isTyped, isFalse);
    });

    test('history has the eight backend keys in order', () {
      expect(historyFields.map(((String, String) f) => f.$1), <String>[
        'chief_complaint',
        'hpi',
        'pmh',
        'medications',
        'allergies',
        'family_history',
        'social_history',
        'ros',
      ]);
    });

    test('the type may arrive as id and the name is humanised', () {
      final NoteTemplate t = NoteTemplate.fromJson(<String, dynamic>{
        'id': 'admit_hp',
        'sections': <Object>[],
      });
      expect(t.type, 'admit_hp');
      expect(t.name, 'Admit hp');
    });
  });

  group('note content', () {
    test('reads sections, flags, sources and chart facts', () {
      final NoteContent c = NoteContent.fromEnvelope(
        noteEnvelope(
          sections: <Object>[
            <String, Object>{
              'key': 'data',
              'title': 'Data',
              'source': 'facts',
              'text': 'Creatinine 9.9.',
              'fact_ids': <String>['f1', 'f2'],
              'flags': <Object>[
                <String, Object>{
                  'code': 'unsupported_number',
                  'message': '9.9 is not in the chart',
                },
                'needs_check',
              ],
            },
            <String, Object>{
              'key': 'plan',
              'source': 'plan',
              'text': 'Continue diuresis.',
            },
          ],
        ),
      );
      final NoteSection data = c.sections.first;
      expect(data.title, 'Data');
      expect(data.originLabel, 'From chart');
      expect(data.factIds, <String>['f1', 'f2']);
      expect(data.flags.map((NoteFlag f) => f.text), <String>[
        '9.9 is not in the chart',
        'Needs check',
      ]);
      expect(c.sections.last.title, 'Plan');
      expect(c.sections.last.originLabel, 'Clinician entered');
      expect(c.sections.last.hasFlags, isFalse);
    });

    test('an origin is only claimed when the backend says it', () {
      final NoteContent c = NoteContent.fromEnvelope(
        noteEnvelope(
          sections: <Object>[
            <String, Object>{'key': 'a', 'text': 'x'},
          ],
        ),
      );
      expect(c.sections.single.originLabel, isNull);
    });

    test('validation issues that name a section become its flags', () {
      final NoteContent c = NoteContent.fromEnvelope(
        noteEnvelope(
          sections: <Object>[
            <String, Object>{'key': 'data', 'text': 'x'},
            <String, Object>{'key': 'plan', 'text': 'y'},
          ],
          issues: <Object>[
            <String, Object>{
              'code': 'unsupported_number',
              'message': 'Number not in chart',
              'section': 'plan',
            },
            <String, Object>{'message': 'General issue'},
          ],
        ),
      );
      expect(c.sections.first.hasFlags, isFalse);
      expect(c.sections.last.flags.single.text, 'Number not in chart');
    });

    test('sections as a map are read too', () {
      final NoteContent c = NoteContent.fromEnvelope(
        AiEnvelope.fromJson(<String, dynamic>{
          'artifact_id': 'n',
          'content': <String, Object>{
            'sections': <String, Object>{'plan': 'Do it'},
          },
        }),
      );
      expect(c.sections.single.key, 'plan');
      expect(c.sections.single.title, 'Plan');
      expect(c.sections.single.text, 'Do it');
    });

    test('a "[... not entered]" marker is a placeholder', () {
      final NoteContent c = NoteContent.fromEnvelope(
        noteEnvelope(
          sections: <Object>[
            <String, Object>{'key': 'exam', 'text': 'Exam: [Exam not entered]'},
            <String, Object>{'key': 'plan', 'text': 'Fine.'},
          ],
        ),
      );
      expect(c.sections.first.hasPlaceholders, isTrue);
      expect(c.sections.last.hasPlaceholders, isFalse);
    });
  });

  group('NotesRepositoryImpl', () {
    test('templates are read as a bare list or wrapped', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) =>
            FakeReply(200, <String, Object>{'templates': templatesJson()}),
      );
      final NotesRepositoryImpl repo = NotesRepositoryImpl(await _client(a));
      final Result<List<NoteTemplate>> r = await repo.templates();
      expect(a.requests.single.path, '/templates');
      expect(
        (r as Ok<List<NoteTemplate>>).value.map((NoteTemplate t) => t.type),
        <String>['progress', 'admit_hp', 'icu'],
      );

      final FakeAdapter b = FakeAdapter(
        (RequestOptions o) => FakeReply(200, templatesJson()),
      );
      final Result<List<NoteTemplate>> r2 = await NotesRepositoryImpl(
        await _client(b),
      ).templates();
      expect((r2 as Ok<List<NoteTemplate>>).value, hasLength(3));
    });

    test('generate sends the type, the typed inputs and the key', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) => FakeReply(200, _noteBody('n1')),
      );
      final NotesRepositoryImpl repo = NotesRepositoryImpl(await _client(a));
      final Result<AiEnvelope> r = await repo.generate(
        'p1',
        noteType: 'admit_hp',
        inputs: <String, Object>{
          'history': <String, String>{'chief_complaint': 'Dyspnea'},
        },
        idempotencyKey: 'key-9',
      );
      expect((r as Ok<AiEnvelope>).value.artifactId, 'n1');
      final RequestOptions o = a.requests.single;
      expect(o.method, 'POST');
      expect(o.path, '/patients/p1/notes');
      expect(o.data, <String, Object>{
        'note_type': 'admit_hp',
        'history': <String, String>{'chief_complaint': 'Dyspnea'},
      });
      expect(o.headers[IdempotencyKey.header], 'key-9');
    });

    test('saving a section is a PATCH and returns the saved note', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) => FakeReply(200, _noteBody('n1')),
      );
      final NotesRepositoryImpl repo = NotesRepositoryImpl(await _client(a));
      final Result<AiEnvelope> r = await repo.saveSection(
        'n1',
        sectionKey: 'plan',
        text: 'New plan',
      );
      expect(r, isA<Ok<AiEnvelope>>());
      final RequestOptions o = a.requests.single;
      expect(o.method, 'PATCH');
      expect(o.path, '/artifacts/n1');
      expect(o.data, <String, Object>{
        'sections': <Object>[
          <String, String>{'key': 'plan', 'text': 'New plan'},
        ],
      });
    });

    test('a bare acknowledgement is followed by a read', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) => o.method == 'PATCH'
            ? const FakeReply(200, <String, Object>{'ok': true})
            : FakeReply(200, _noteBody('n1')),
      );
      final NotesRepositoryImpl repo = NotesRepositoryImpl(await _client(a));
      final Result<AiEnvelope> r = await repo.saveSection(
        'n1',
        sectionKey: 'plan',
        text: 't',
      );
      expect((r as Ok<AiEnvelope>).value.artifactId, 'n1');
      expect(a.requests.map((RequestOptions o) => o.method), <String>[
        'PATCH',
        'GET',
      ]);
    });

    test('rewrite sends the mode and reads the new text', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) => const FakeReply(200, <String, Object>{
          'content': <String, Object>{'after': 'Short.'},
        }),
      );
      final NotesRepositoryImpl repo = NotesRepositoryImpl(await _client(a));
      final Result<RewriteProposal> r = await repo.rewrite(
        'n1',
        sectionKey: 'plan',
        before: 'Long plan text',
        mode: RewriteMode.shorten,
        idempotencyKey: 'rk',
      );
      final RewriteProposal p = (r as Ok<RewriteProposal>).value;
      expect(p.before, 'Long plan text');
      expect(p.after, 'Short.');
      final RequestOptions o = a.requests.single;
      expect(o.path, '/artifacts/n1/sections/plan/rewrite');
      expect(o.data, <String, String>{'mode': 'shorten'});
      expect(o.headers[IdempotencyKey.header], 'rk');
    });

    test('an empty rewrite is an error, never an empty "after"', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) => const FakeReply(200, <String, Object>{}),
      );
      final Result<RewriteProposal> r =
          await NotesRepositoryImpl(await _client(a)).rewrite(
            'n1',
            sectionKey: 'plan',
            before: 'x',
            mode: RewriteMode.improve,
            idempotencyKey: 'k',
          );
      expect(r, isA<Err<RewriteProposal>>());
    });

    test('export reads plain text or an object', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) => const FakeReply(200, 'Plain note'),
      );
      final Result<String> r = await NotesRepositoryImpl(
        await _client(a),
      ).export('n1');
      expect((r as Ok<String>).value, 'Plain note');
      expect(a.requests.single.path, '/artifacts/n1/export');

      final FakeAdapter b = FakeAdapter(
        (RequestOptions o) =>
            const FakeReply(200, <String, Object>{'text': 'From object'}),
      );
      final Result<String> r2 = await NotesRepositoryImpl(
        await _client(b),
      ).export('n1');
      expect((r2 as Ok<String>).value, 'From object');
    });

    test('a server error is returned in our wording', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) => const FakeReply(429, <String, Object>{
          'error': <String, Object>{
            'code': 'rate_limited',
            'message': 'raw server text',
          },
        }),
      );
      final Result<AiEnvelope> r = await NotesRepositoryImpl(await _client(a))
          .generate(
            'p1',
            noteType: 'progress',
            inputs: const <String, Object>{},
            idempotencyKey: 'k',
          );
      final Err<AiEnvelope> e = r as Err<AiEnvelope>;
      expect(e.failure.message, isNot(contains('raw server text')));
    });
  });

  group('ProblemsRepositoryImpl', () {
    test('lists problems as a bare list or wrapped', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) => FakeReply(200, <String, Object>{
          'problems': <Object>[
            <String, Object>{
              'id': 'x1',
              'label': 'AKI',
              'state': 'documented',
              'fact_ids': <String>['f1'],
            },
          ],
        }),
      );
      final Result<List<Problem>> r = await ProblemsRepositoryImpl(
        await _client(a),
      ).list('p1');
      expect(a.requests.single.path, '/patients/p1/problems');
      final Problem p = (r as Ok<List<Problem>>).value.single;
      expect(p.state, ProblemState.documented);
      expect(p.factIds, <String>['f1']);
    });

    test(
      'suggestions are always suggestions, whatever the server says',
      () async {
        final FakeAdapter a = FakeAdapter(
          (RequestOptions o) => FakeReply(200, <Object>[
            <String, Object>{'id': 'a', 'label': 'CHF', 'state': 'confirmed'},
            <String, Object>{'id': 'b', 'label': 'AKI', 'state': 'rejected'},
            <String, Object>{'id': 'c', 'label': 'HTN'},
            <String, Object>{'id': 'd', 'label': 'DM', 'state': 'documented'},
          ]),
        );
        final Result<List<Problem>> r = await ProblemsRepositoryImpl(
          await _client(a),
        ).suggest('p1', idempotencyKey: 'sk');
        final List<Problem> list = (r as Ok<List<Problem>>).value;
        expect(list.map((Problem p) => p.state), <ProblemState>[
          ProblemState.suggested,
          ProblemState.suggested,
          ProblemState.suggested,
          ProblemState.documented,
        ]);
        expect(a.requests.single.method, 'POST');
        expect(a.requests.single.path, '/patients/p1/problems/suggest');
        expect(a.requests.single.headers[IdempotencyKey.header], 'sk');
      },
    );

    test('suggestions inside an envelope are read', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) => FakeReply(200, <String, Object>{
          'content': <String, Object>{
            'problems': <Object>[
              <String, Object>{'id': 'a', 'label': 'CHF'},
            ],
          },
        }),
      );
      final Result<List<Problem>> r = await ProblemsRepositoryImpl(
        await _client(a),
      ).suggest('p1', idempotencyKey: 'k');
      expect((r as Ok<List<Problem>>).value.single.label, 'CHF');
    });

    test('a decision sends the action', () async {
      final FakeAdapter a = FakeAdapter(
        (RequestOptions o) => const FakeReply(200, <String, Object>{}),
      );
      final Result<void> r = await ProblemsRepositoryImpl(
        await _client(a),
      ).decide('p1', 'x1', ProblemAction.differential);
      expect(r, isA<Ok<void>>());
      final RequestOptions o = a.requests.single;
      expect(o.path, '/patients/p1/problems/x1/decision');
      expect(o.data, <String, String>{'action': 'differential'});
    });

    test('actions map to the states a clinician chose', () {
      expect(ProblemAction.accept.resultingState, ProblemState.confirmed);
      expect(
        ProblemAction.differential.resultingState,
        ProblemState.differential,
      );
      expect(ProblemAction.reject.resultingState, ProblemState.rejected);
    });
  });

  group('NoteCubit', () {
    test('templates load and progress is the default', () async {
      final NoteCubit c = _cubit(FakeNotesRepository(), FakeAiRepository());
      await c.loadTemplates();
      expect(c.state.templatesPhase, TemplatesPhase.ready);
      expect(c.state.selectedType, 'progress');
      expect(c.state.template!.name, 'Progress note');
      await c.close();
    });

    test('opening Notes reloads the latest saved draft', () async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..latest = Ok<AiEnvelope?>(
          noteEnvelope(
            id: 'saved-1',
            review: 'reviewed',
            sections: <Object>[
              <String, Object>{
                'key': 'plan',
                'title': 'Plan',
                'source': 'clinician_plan',
                'text': 'Continue antibiotics.',
              },
            ],
          ),
        );
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      expect(notes.latestCalls, 1);
      expect(c.state.hasDraft, isTrue);
      expect(c.state.isReviewed, isTrue);
      expect(c.state.sections.single.text, 'Continue antibiotics.');
      await c.close();
    });

    test('a failed template load is reported and can be retried', () async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..templatesResult = Err<List<NoteTemplate>>(
          FakeAiRepository.failure('network_error'),
        );
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      expect(c.state.templatesPhase, TemplatesPhase.failed);
      expect(c.state.templatesError, isNotNull);
      notes.templatesResult = null;
      await c.loadTemplates();
      expect(c.state.templatesPhase, TemplatesPhase.ready);
      await c.close();
    });

    test('generate sends the type and inputs and shows the draft', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      c.selectTemplate('icu');
      await c.generate(<String, Object>{'update': 'Stable'});
      expect(notes.generateTypes, <String>['icu']);
      expect(notes.generateInputs.single, <String, Object>{'update': 'Stable'});
      expect(c.state.hasDraft, isTrue);
      expect(c.state.sections, hasLength(2));
      expect(c.state.generating, isFalse);
      await c.close();
    });

    test('the same key is used for a retry, a new one after success', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      int calls = 0;
      notes.onGenerate = (String key) async {
        calls++;
        return calls == 1
            ? Err<AiEnvelope>(FakeAiRepository.failure('network_error'))
            : Ok<AiEnvelope>(noteEnvelope());
      };
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      await c.generate(const <String, Object>{});
      expect(c.state.error, isNotNull);
      expect(c.state.hasDraft, isFalse);
      await c.generate(const <String, Object>{});
      expect(notes.generateKeys[0], notes.generateKeys[1]);
      expect(c.state.error, isNull);
      await c.generate(const <String, Object>{});
      expect(notes.generateKeys[2], isNot(notes.generateKeys[0]));
      await c.close();
    });

    test('cancel stops it without an error', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final Completer<Result<AiEnvelope>> never =
          Completer<Result<AiEnvelope>>();
      notes.onGenerate = (_) => never.future;
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      final Future<void> run = c.generate(const <String, Object>{});
      await _settle();
      expect(c.state.generating, isTrue);
      c.cancel();
      expect(notes.lastToken!.isCancelled, isTrue);
      never.complete(Err<AiEnvelope>(FakeAiRepository.failure('cancelled')));
      await run;
      expect(c.state.generating, isFalse);
      expect(c.state.error, isNull);
      await c.close();
    });

    test('a failed regenerate keeps the saved draft on screen', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      await c.generate(const <String, Object>{});
      notes.generated = Err<AiEnvelope>(FakeAiRepository.failure('ai_error'));
      await c.generate(const <String, Object>{});
      expect(c.state.error, isNotNull);
      expect(c.state.hasDraft, isTrue);
      await c.close();
    });

    test('review is blocked by flags, placeholders and outdated', () async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..generated = Ok<AiEnvelope>(
          noteEnvelope(
            outdated: true,
            sections: <Object>[
              <String, Object>{
                'key': 'data',
                'title': 'Data',
                'text': 'Cr 9.9',
                'flags': <Object>['unsupported_number'],
              },
              <String, Object>{
                'key': 'exam',
                'title': 'Exam',
                'text': '[Exam not entered]',
              },
            ],
          ),
        );
      final FakeAiRepository ai = FakeAiRepository();
      final NoteCubit c = _cubit(notes, ai);
      await c.loadTemplates();
      await c.generate(const <String, Object>{});
      expect(c.state.reviewBlockers, <String>[
        noteOutdatedMessage,
        'Data has a flag to resolve.',
        'Exam still has information that is not entered.',
      ]);
      expect(c.state.canMarkReviewed, isFalse);
      expect(c.state.markedSections, <String>{'data', 'exam'});
      await c.markReviewed();
      expect(ai.reviewed_, isEmpty);
      await c.close();
    });

    test('a clean draft can be reviewed, and the server can refuse', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
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
      final NoteCubit c = _cubit(notes, ai);
      await c.loadTemplates();
      await c.generate(const <String, Object>{});
      expect(c.state.canMarkReviewed, isTrue);
      await c.markReviewed();
      expect(ai.reviewed_, <String>['n1']);
      expect(c.state.reviewError, isNotNull);
      expect(c.state.flaggedSections, <String>['data']);
      expect(c.state.markedSections, contains('data'));
      expect(c.state.isReviewed, isFalse);

      ai.reviewed = null;
      await c.markReviewed();
      expect(c.state.isReviewed, isTrue);
      expect(c.state.reviewError, isNull);
      await c.close();
    });

    test('saving a section replaces the draft with the saved one', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      await c.generate(const <String, Object>{});
      notes.saved = Ok<AiEnvelope>(
        noteEnvelope(
          sections: <Object>[
            <String, Object>{'key': 'plan', 'title': 'Plan', 'text': 'Edited'},
          ],
        ),
      );
      await c.saveSection('plan', 'Edited');
      expect(notes.saves, <(String, String)>[('plan', 'Edited')]);
      expect(c.state.sections.single.text, 'Edited');
      expect(c.state.savingKey, isNull);
      await c.close();
    });

    test('a failed save keeps the text and reports it', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      await c.generate(const <String, Object>{});
      final String before = c.state.sections.first.text;
      notes.saved = Err<AiEnvelope>(FakeAiRepository.failure('network_error'));
      await c.saveSection('subjective', 'New');
      expect(c.state.saveError, isNotNull);
      expect(c.state.sections.first.text, before);
      await c.close();
    });

    test('a rewrite is only a proposal until it is applied', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      await c.generate(const <String, Object>{});
      await c.rewrite('subjective', RewriteMode.shorten);
      expect(c.state.proposal!.after, 'Shorter text.');
      expect(c.state.proposal!.before, 'Feels better today.');
      expect(notes.saves, isEmpty);
      expect(c.state.sections.first.text, 'Feels better today.');

      await c.applyProposal();
      expect(notes.saves, <(String, String)>[('subjective', 'Shorter text.')]);
      expect(c.state.proposal, isNull);
      await c.close();
    });

    test('keeping the current text saves nothing', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      await c.generate(const <String, Object>{});
      await c.rewrite('data', RewriteMode.expand);
      c.dismissProposal();
      expect(c.state.proposal, isNull);
      expect(notes.saves, isEmpty);
      await c.close();
    });

    test(
      'a failed rewrite changes nothing and keeps its key for retry',
      () async {
        final FakeNotesRepository notes = FakeNotesRepository()
          ..rewritten = Err<RewriteProposal>(
            FakeAiRepository.failure('network_error'),
          );
        final NoteCubit c = _cubit(notes, FakeAiRepository());
        await c.loadTemplates();
        await c.generate(const <String, Object>{});
        await c.rewrite('data', RewriteMode.improve);
        expect(c.state.rewriteError, isNotNull);
        expect(c.state.proposal, isNull);
        await c.rewrite('data', RewriteMode.improve);
        expect(notes.rewriteKeys[0], notes.rewriteKeys[1]);
        await c.close();
      },
    );

    test('export is only for a reviewed, current note', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final FakeAiRepository ai = FakeAiRepository();
      final NoteCubit c = _cubit(notes, ai);
      await c.loadTemplates();
      await c.generate(const <String, Object>{});
      expect(await c.export(), isNull);
      expect(notes.exportCalls, 0);

      await c.markReviewed();
      expect(c.state.canExport, isTrue);
      expect(await c.export(), 'Clean note text');
      expect(notes.exportCalls, 1);
      await c.close();
    });

    test('dictation: empty transcript never calls the API', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      await c.generateFromDictation(transcript: '   ');
      expect(notes.generateKeys, isEmpty);
      expect(c.state.error?.code, 'transcript_required');
      expect(c.state.hasDraft, isFalse);
      await c.close();
    });

    test('dictation: success, failure keeps prior draft, retry reuses key',
        () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      int calls = 0;
      notes.onGenerateFromDictation = (String key) async {
        calls++;
        return calls == 1
            ? Err<AiEnvelope>(FakeAiRepository.failure('network_error'))
            : Ok<AiEnvelope>(noteEnvelope(id: 'dict-1'));
      };
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      const String transcript =
          'Overnight oxygen need increased on 2 L nasal cannula.';
      await c.generateFromDictation(transcript: transcript);
      expect(c.state.error, isNotNull);
      expect(c.state.hasDraft, isFalse);
      expect(notes.lastTranscript, transcript);
      await c.generateFromDictation(transcript: transcript);
      expect(notes.generateKeys[0], notes.generateKeys[1]);
      expect(c.state.error, isNull);
      expect(c.state.hasDraft, isTrue);
      await c.close();
    });

    test('dictation: failed regenerate keeps prior draft on screen', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      await c.generateFromDictation(
        transcript: 'Patient reports fever overnight with chills.',
      );
      expect(c.state.hasDraft, isTrue);
      notes.generated = Err<AiEnvelope>(
        FakeAiRepository.failure('ai_invalid_output'),
      );
      await c.generateFromDictation(
        transcript: 'Patient reports fever overnight with chills.',
      );
      expect(c.state.error, isNotNull);
      expect(c.state.hasDraft, isTrue);
      await c.close();
    });

    test('a failed export reports and returns nothing', () async {
      final FakeNotesRepository notes = FakeNotesRepository()
        ..exported = Err<String>(FakeAiRepository.failure('network_error'));
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      await c.generate(const <String, Object>{});
      await c.markReviewed();
      expect(await c.export(), isNull);
      expect(c.state.exportError, isNotNull);
      await c.close();
    });

    test('the template cannot change while a draft is being written', () async {
      final FakeNotesRepository notes = FakeNotesRepository();
      final Completer<Result<AiEnvelope>> never =
          Completer<Result<AiEnvelope>>();
      notes.onGenerate = (_) => never.future;
      final NoteCubit c = _cubit(notes, FakeAiRepository());
      await c.loadTemplates();
      final Future<void> run = c.generate(const <String, Object>{});
      await _settle();
      c.selectTemplate('icu');
      expect(c.state.selectedType, 'progress');
      never.complete(Ok<AiEnvelope>(noteEnvelope()));
      await run;
      await c.close();
    });
  });

  group('ProblemsCubit', () {
    test('suggestions are shown as suggested and added to the list', () async {
      final FakeProblemsRepository repo =
          FakeProblemsRepository(
              list: <Problem>[
                problem('d1', 'CHF', state: ProblemState.documented),
              ],
            )
            ..suggested = Ok<List<Problem>>(<Problem>[
              problem('s1', 'AKI', factIds: const <String>['f1']),
            ]);
      final ProblemsCubit c = ProblemsCubit(repo, 'p1');
      await c.suggest();
      expect(c.state.suggestedCount, 1);
      final Problem aki = c.state.problems.firstWhere(
        (Problem p) => p.id == 's1',
      );
      expect(aki.state, ProblemState.suggested);
      expect(
        c.state.problems.firstWhere((Problem p) => p.id == 'd1').state,
        ProblemState.documented,
      );
      expect(
        c.state.problems.any((Problem p) => p.state == ProblemState.confirmed),
        isFalse,
      );
      await c.close();
    });

    test('none suggested is said, not invented', () async {
      final FakeProblemsRepository repo = FakeProblemsRepository();
      final ProblemsCubit c = ProblemsCubit(repo, 'p1');
      await c.suggest();
      expect(c.state.suggestedCount, 0);
      expect(c.state.problems, isEmpty);
      await c.close();
    });

    test('the key is kept for a retry and dropped after success', () async {
      final FakeProblemsRepository repo = FakeProblemsRepository();
      int calls = 0;
      repo.onSuggest = (String key) async {
        calls++;
        return calls == 1
            ? Err<List<Problem>>(FakeAiRepository.failure('network_error'))
            : const Ok<List<Problem>>(<Problem>[]);
      };
      final ProblemsCubit c = ProblemsCubit(repo, 'p1');
      await c.suggest();
      expect(c.state.error, isNotNull);
      await c.suggest();
      expect(repo.suggestKeys[0], repo.suggestKeys[1]);
      expect(c.state.error, isNull);
      await c.suggest();
      expect(repo.suggestKeys[2], isNot(repo.suggestKeys[0]));
      await c.close();
    });

    test('no reviewed facts is reported with its own kind', () async {
      final FakeProblemsRepository repo = FakeProblemsRepository()
        ..onSuggest = (_) async => Err<List<Problem>>(
          FakeAiRepository.failure('no_reviewed_facts', status: 409),
        );
      final ProblemsCubit c = ProblemsCubit(repo, 'p1');
      await c.suggest();
      expect(c.state.error!.code, 'no_reviewed_facts');
      expect(c.state.suggesting, isFalse);
      await c.close();
    });

    test('cancel stops it without an error', () async {
      final FakeProblemsRepository repo = FakeProblemsRepository();
      final Completer<Result<List<Problem>>> never =
          Completer<Result<List<Problem>>>();
      repo.onSuggest = (_) => never.future;
      final ProblemsCubit c = ProblemsCubit(repo, 'p1');
      final Future<void> run = c.suggest();
      await _settle();
      expect(c.state.suggesting, isTrue);
      c.cancel();
      expect(repo.lastToken!.isCancelled, isTrue);
      never.complete(Err<List<Problem>>(FakeAiRepository.failure('cancelled')));
      await run;
      expect(c.state.suggesting, isFalse);
      expect(c.state.error, isNull);
      await c.close();
    });

    test('a decision changes the state only after it is saved', () async {
      final FakeProblemsRepository repo = FakeProblemsRepository(
        list: <Problem>[problem('s1', 'AKI')],
      )..applyDecisions = true;
      final ProblemsCubit c = ProblemsCubit(
        repo,
        'p1',
        initial: <Problem>[problem('s1', 'AKI')],
      );
      await c.decide(c.state.problems.single, ProblemAction.accept);
      expect(repo.decisions, <(String, ProblemAction)>[
        ('s1', ProblemAction.accept),
      ]);
      expect(c.state.problems.single.state, ProblemState.confirmed);
      expect(c.state.changes, 1);
      expect(c.state.busyId, isNull);
      await c.close();
    });

    test('a failed decision leaves the suggestion a suggestion', () async {
      final FakeProblemsRepository repo = FakeProblemsRepository(
        list: <Problem>[problem('s1', 'AKI')],
      )..decision = Err<void>(FakeAiRepository.failure('network_error'));
      final ProblemsCubit c = ProblemsCubit(
        repo,
        'p1',
        initial: <Problem>[problem('s1', 'AKI')],
      );
      await c.decide(c.state.problems.single, ProblemAction.accept);
      expect(c.state.problems.single.state, ProblemState.suggested);
      expect(c.state.error, isNotNull);
      expect(c.state.changes, 0);
      expect(c.state.busyId, isNull);
      await c.close();
    });

    test('differential and reject are saved as such', () async {
      final FakeProblemsRepository repo = FakeProblemsRepository(
        list: <Problem>[problem('a', 'A'), problem('b', 'B')],
      )..applyDecisions = true;
      final ProblemsCubit c = ProblemsCubit(
        repo,
        'p1',
        initial: <Problem>[problem('a', 'A'), problem('b', 'B')],
      );
      await c.decide(c.state.problems[0], ProblemAction.differential);
      await c.decide(c.state.problems[1], ProblemAction.reject);
      expect(c.state.problems.map((Problem p) => p.state), <ProblemState>[
        ProblemState.differential,
        ProblemState.rejected,
      ]);
      await c.close();
    });

    test('a failed list read keeps what is shown', () async {
      final FakeProblemsRepository repo = FakeProblemsRepository()
        ..listResult = Err<List<Problem>>(
          FakeAiRepository.failure('network_error'),
        );
      final ProblemsCubit c = ProblemsCubit(
        repo,
        'p1',
        initial: <Problem>[problem('a', 'A')],
      );
      await c.load();
      expect(c.state.problems, hasLength(1));
      await c.close();
    });
  });
}
