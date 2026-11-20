import 'dart:async';

import 'package:dio/dio.dart';
import 'package:round_ai/core/errors/result.dart';
import 'package:round_ai/features/ai/models/ai_envelope.dart';
import 'package:round_ai/features/notes/models/note_section.dart';
import 'package:round_ai/features/notes/models/note_template.dart';
import 'package:round_ai/core/errors/failures.dart';
import 'package:round_ai/core/network/api_error.dart';
import 'package:round_ai/features/notes/repository/notes_repository.dart';
import 'package:round_ai/features/patient/models/problem.dart';
import 'package:round_ai/features/problems/models/coding_suggestion.dart';
import 'package:round_ai/features/problems/repository/problems_repository.dart';

/// The three templates the backend serves, as JSON.
List<Object> templatesJson() => <Object>[
  <String, Object>{
    'note_type': 'progress',
    'name': 'Progress note',
    'sections': <Object>[
      <String, Object>{
        'key': 'subjective',
        'title': 'Subjective',
        'source': 'clinician_subjective',
      },
      <String, Object>{'key': 'exam', 'title': 'Exam', 'source': 'exam'},
      <String, Object>{'key': 'data', 'title': 'Data', 'source': 'facts'},
      <String, Object>{'key': 'plan', 'title': 'Plan', 'source': 'plan'},
    ],
  },
  <String, Object>{
    'note_type': 'admit_hp',
    'name': 'Admission H&P',
    'sections': <Object>[
      for (final (String key, String title) in historyFields)
        <String, Object>{
          'key': key,
          'title': title,
          'source': 'clinician_history',
        },
      <String, Object>{
        'key': 'exam',
        'title': 'Exam',
        'source': 'clinician_exam',
      },
      <String, Object>{'key': 'data', 'title': 'Data', 'source': 'facts'},
      <String, Object>{
        'key': 'assessment_plan',
        'title': 'Assessment and Plan',
        'source': 'clinician_plan',
      },
    ],
  },
  <String, Object>{
    'note_type': 'icu',
    'name': 'ICU note',
    'sections': <Object>[
      <String, Object>{'key': 'update', 'title': 'Update', 'source': 'update'},
      <String, Object>{
        'key': 'support',
        'title': 'Support',
        'source': 'support',
      },
    ],
  },
];

List<NoteTemplate> sampleTemplates() => <NoteTemplate>[
  for (final Object t in templatesJson())
    NoteTemplate.fromJson(t as Map<String, dynamic>),
];

/// A note envelope. [sections] are the `content.sections` items.
AiEnvelope noteEnvelope({
  String id = 'n1',
  String review = 'draft',
  String status = 'draft',
  bool outdated = false,
  List<Object>? sections,
  List<Object>? issues,
}) {
  return AiEnvelope.fromJson(<String, dynamic>{
    'artifact_id': id,
    'operation': 'draft_note',
    'patient_id': 'p1',
    'context_revision': 3,
    'status': status,
    'review_state': review,
    'outdated': outdated,
    'requires_review': review != 'reviewed',
    'created_at': '2026-11-12T09:00:00Z',
    'content': <String, dynamic>{
      'validation_issues': issues ?? <Object>[],
      'sections':
          sections ??
          <Object>[
            <String, Object>{
              'key': 'subjective',
              'title': 'Subjective',
              'source': 'clinician_subjective',
              'text': 'Feels better today.',
            },
            <String, Object>{
              'key': 'data',
              'title': 'Data',
              'source': 'facts',
              'text': 'Creatinine 1.7.',
              'fact_ids': <String>['f1'],
            },
          ],
    },
  });
}

class FakeNotesRepository implements NotesRepository {
  Result<List<NoteTemplate>>? templatesResult;
  Result<AiEnvelope>? generated;
  Future<Result<AiEnvelope>> Function(String key)? onGenerate;
  Result<AiEnvelope>? saved;
  Result<RewriteProposal>? rewritten;
  Future<Result<RewriteProposal>> Function()? onRewrite;
  Result<String> exported = const Ok<String>('Clean note text');

  final List<String> generateKeys = <String>[];
  final List<Map<String, Object>> generateInputs = <Map<String, Object>>[];
  final List<String> generateTypes = <String>[];
  final List<(String, String)> saves = <(String, String)>[];
  final List<RewriteMode> rewriteModes = <RewriteMode>[];
  final List<String> rewriteKeys = <String>[];
  int templateCalls = 0;
  int exportCalls = 0;
  CancelToken? lastToken;

  @override
  Future<Result<List<NoteTemplate>>> templates() async {
    templateCalls++;
    return templatesResult ?? Ok<List<NoteTemplate>>(sampleTemplates());
  }

  Result<AiEnvelope?>? latest;
  int latestCalls = 0;

  @override
  Future<Result<AiEnvelope?>> latestNote(
    String patientId, {
    String? noteType,
  }) async {
    latestCalls++;
    return latest ?? const Ok<AiEnvelope?>(null);
  }

  List<String>? lastSourceIds;
  List<String>? lastApplyTo;

  @override
  Future<Result<AiEnvelope>> generate(
    String patientId, {
    required String noteType,
    required Map<String, Object> inputs,
    List<String>? inputsFromSourceIds,
    List<String>? applyTo,
    required String idempotencyKey,
    CancelToken? cancelToken,
  }) {
    generateKeys.add(idempotencyKey);
    generateInputs.add(inputs);
    generateTypes.add(noteType);
    lastSourceIds = inputsFromSourceIds;
    lastApplyTo = applyTo;
    lastToken = cancelToken;
    final Future<Result<AiEnvelope>> Function(String)? handler = onGenerate;
    if (handler != null) return handler(idempotencyKey);
    return Future<Result<AiEnvelope>>.value(
      generated ?? Ok<AiEnvelope>(noteEnvelope()),
    );
  }

  String? lastTranscript;
  Future<Result<AiEnvelope>> Function(String key)? onGenerateFromDictation;

  @override
  Future<Result<AiEnvelope>> generateFromDictation(
    String patientId, {
    required String noteType,
    String? transcript,
    List<String>? sourceIds,
    String? noteDate,
    List<Map<String, String>>? clarifications,
    required String idempotencyKey,
    CancelToken? cancelToken,
  }) {
    generateKeys.add(idempotencyKey);
    generateTypes.add(noteType);
    lastTranscript = transcript;
    lastSourceIds = sourceIds;
    lastToken = cancelToken;
    final Future<Result<AiEnvelope>> Function(String)? handler =
        onGenerateFromDictation;
    if (handler != null) return handler(idempotencyKey);
    return Future<Result<AiEnvelope>>.value(
      generated ?? Ok<AiEnvelope>(noteEnvelope()),
    );
  }

  @override
  Future<Result<AiEnvelope>> saveSection(
    String artifactId, {
    required String sectionKey,
    required String text,
  }) async {
    saves.add((sectionKey, text));
    return saved ?? Ok<AiEnvelope>(noteEnvelope(id: artifactId));
  }

  @override
  Future<Result<RewriteProposal>> rewrite(
    String artifactId, {
    required String sectionKey,
    required String before,
    required RewriteMode mode,
    required String idempotencyKey,
    CancelToken? cancelToken,
  }) {
    rewriteModes.add(mode);
    rewriteKeys.add(idempotencyKey);
    lastToken = cancelToken;
    final Future<Result<RewriteProposal>> Function()? handler = onRewrite;
    if (handler != null) return handler();
    return Future<Result<RewriteProposal>>.value(
      rewritten ??
          Ok<RewriteProposal>(
            RewriteProposal(
              sectionKey: sectionKey,
              mode: mode,
              before: before,
              after: 'Shorter text.',
            ),
          ),
    );
  }

  @override
  Future<Result<String>> export(String artifactId) async {
    exportCalls++;
    return exported;
  }
}

class FakeProblemsRepository implements ProblemsRepository {
  FakeProblemsRepository({List<Problem>? list}) : saved = list ?? <Problem>[];

  /// What the backend holds now. `decide` does not change it unless
  /// [applyDecisions] is true.
  List<Problem> saved;
  Result<List<Problem>>? listResult;
  Result<List<Problem>>? suggested;
  Future<Result<List<Problem>>> Function(String key)? onSuggest;
  Result<void> decision = const Ok<void>(null);
  Result<CodingSuggestResult>? codingSuggest;
  Result<AcceptedCodeSuggestion>? codingAccept;
  bool applyDecisions = false;

  final List<String> suggestKeys = <String>[];
  final List<(String, ProblemAction)> decisions = <(String, ProblemAction)>[];
  final List<String> codingSuggestKeys = <String>[];
  final List<(String, String)> codingAccepts = <(String, String)>[];
  int listCalls = 0;
  CancelToken? lastToken;

  @override
  Future<Result<List<Problem>>> list(String patientId) async {
    listCalls++;
    return listResult ?? Ok<List<Problem>>(List<Problem>.of(saved));
  }

  @override
  Future<Result<List<Problem>>> suggest(
    String patientId, {
    required String idempotencyKey,
    CancelToken? cancelToken,
  }) {
    suggestKeys.add(idempotencyKey);
    lastToken = cancelToken;
    final Future<Result<List<Problem>>> Function(String)? handler = onSuggest;
    if (handler != null) return handler(idempotencyKey);
    return Future<Result<List<Problem>>>.value(
      suggested ?? const Ok<List<Problem>>(<Problem>[]),
    );
  }

  @override
  Future<Result<void>> decide(
    String patientId,
    String problemId,
    ProblemAction action,
  ) async {
    decisions.add((problemId, action));
    if (decision is Ok<void> && applyDecisions) {
      saved = <Problem>[
        for (final Problem p in saved)
          p.id == problemId
              ? p.copyWith(state: action.resultingState)
              : p,
      ];
    }
    return decision;
  }

  @override
  Future<Result<CodingSuggestResult>> suggestCoding(
    String patientId, {
    required String problemId,
    required String idempotencyKey,
    CancelToken? cancelToken,
  }) async {
    codingSuggestKeys.add(idempotencyKey);
    lastToken = cancelToken;
    return codingSuggest ??
        Err<CodingSuggestResult>(
          ApiFailure(const ApiError(code: 'ai_disabled', message: '', status: 503)),
        );
  }

  @override
  Future<Result<AcceptedCodeSuggestion>> acceptCoding(
    String patientId,
    String problemId, {
    required String code,
    String? artifactId,
  }) async {
    codingAccepts.add((problemId, code));
    final Result<AcceptedCodeSuggestion> result =
        codingAccept ??
        Ok<AcceptedCodeSuggestion>(
          AcceptedCodeSuggestion(code: code, description: 'Accepted'),
        );
    if (result case Ok<AcceptedCodeSuggestion>(:final value)) {
      saved = <Problem>[
        for (final Problem p in saved)
          p.id == problemId ? p.copyWith(codeSuggestion: value) : p,
      ];
    }
    return result;
  }
}

Problem problem(
  String id,
  String label, {
  ProblemState state = ProblemState.suggested,
  List<String> factIds = const <String>[],
}) => Problem(id: id, label: label, state: state, factIds: factIds);
