import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:round_ai/core/errors/failures.dart';
import 'package:round_ai/core/errors/result.dart';
import 'package:round_ai/core/network/api_error.dart';
import 'package:round_ai/core/network/idempotency_key.dart';
import 'package:round_ai/core/sync/census_sync_mark.dart';
import 'package:round_ai/core/utils/json_utils.dart';
import 'package:round_ai/features/ai/models/ai_envelope.dart';
import 'package:round_ai/features/ai/repository/ai_repository.dart';
import 'package:round_ai/features/notes/models/note_section.dart';
import 'package:round_ai/features/notes/models/note_template.dart';
import 'package:round_ai/features/notes/repository/notes_repository.dart';

enum TemplatesPhase { loading, ready, failed }

const String noteOutdatedMessage =
    'Chart changed. Regenerate before marking reviewed.';

class NoteDraftState extends Equatable {
  const NoteDraftState({
    this.templatesPhase = TemplatesPhase.loading,
    this.templates = const <NoteTemplate>[],
    this.templatesError,
    this.selectedType,
    this.generating = false,
    this.envelope,
    this.content,
    this.error,
    this.savingKey,
    this.saveError,
    this.rewritingKey,
    this.proposal,
    this.rewriteError,
    this.reviewing = false,
    this.reviewError,
    this.flaggedSections = const <String>[],
    this.exporting = false,
    this.exportError,
  });

  final TemplatesPhase templatesPhase;
  final List<NoteTemplate> templates;
  final ApiError? templatesError;
  final String? selectedType;

  final bool generating;
  final AiEnvelope? envelope;
  final NoteContent? content;

  /// The last failed generation. A saved draft stays on screen.
  final ApiError? error;

  /// The section whose text is being saved.
  final String? savingKey;
  final ApiError? saveError;

  /// The section a rewrite was asked for, and what came back. The proposal
  /// is shown as before and after. Nothing changes until the user applies it.
  final String? rewritingKey;
  final RewriteProposal? proposal;
  final ApiError? rewriteError;

  final bool reviewing;
  final ApiError? reviewError;

  /// Section keys the backend named when it refused to mark reviewed.
  final List<String> flaggedSections;
  final bool exporting;
  final ApiError? exportError;

  NoteTemplate? get template {
    for (final NoteTemplate t in templates) {
      if (t.type == selectedType) return t;
    }
    return null;
  }

  bool get hasDraft => envelope != null;
  bool get isReviewed => envelope?.isReviewed ?? false;
  bool get outdated => envelope?.outdated ?? false;

  List<NoteSection> get sections => content?.sections ?? const <NoteSection>[];

  /// Why "Mark reviewed" is off. Empty when it can be used.
  List<String> get reviewBlockers {
    if (envelope == null || isReviewed) return const <String>[];
    return <String>[
      if (outdated) noteOutdatedMessage,
      for (final NoteSection s in sections)
        if (s.hasFlags) '${s.title} has a flag to resolve.',
      for (final NoteSection s in sections)
        if (s.hasPlaceholders)
          '${s.title} still has information that is not entered.',
    ];
  }

  bool get busy =>
      generating || savingKey != null || rewritingKey != null || reviewing;

  bool get canMarkReviewed =>
      hasDraft && !isReviewed && reviewBlockers.isEmpty && !busy;

  /// Only a reviewed version of the current chart can be copied out.
  bool get canExport => isReviewed && !outdated && !exporting;

  /// Sections to mark: flags, missing text, and any the backend named.
  Set<String> get markedSections => <String>{
    for (final NoteSection s in sections)
      if (s.hasFlags || s.hasPlaceholders) s.key,
    ...flaggedSections,
  };

  NoteDraftState copyWith({
    TemplatesPhase? templatesPhase,
    List<NoteTemplate>? templates,
    ApiError? templatesError,
    bool clearTemplatesError = false,
    String? selectedType,
    bool? generating,
    AiEnvelope? envelope,
    NoteContent? content,
    ApiError? error,
    bool clearError = false,
    String? savingKey,
    bool clearSaving = false,
    ApiError? saveError,
    bool clearSaveError = false,
    String? rewritingKey,
    bool clearRewriting = false,
    RewriteProposal? proposal,
    bool clearProposal = false,
    ApiError? rewriteError,
    bool clearRewriteError = false,
    bool? reviewing,
    ApiError? reviewError,
    bool clearReviewError = false,
    List<String>? flaggedSections,
    bool? exporting,
    ApiError? exportError,
    bool clearExportError = false,
  }) {
    return NoteDraftState(
      templatesPhase: templatesPhase ?? this.templatesPhase,
      templates: templates ?? this.templates,
      templatesError: clearTemplatesError
          ? null
          : templatesError ?? this.templatesError,
      selectedType: selectedType ?? this.selectedType,
      generating: generating ?? this.generating,
      envelope: envelope ?? this.envelope,
      content: content ?? this.content,
      error: clearError ? null : error ?? this.error,
      savingKey: clearSaving ? null : savingKey ?? this.savingKey,
      saveError: clearSaveError ? null : saveError ?? this.saveError,
      rewritingKey: clearRewriting ? null : rewritingKey ?? this.rewritingKey,
      proposal: clearProposal ? null : proposal ?? this.proposal,
      rewriteError: clearRewriteError
          ? null
          : rewriteError ?? this.rewriteError,
      reviewing: reviewing ?? this.reviewing,
      reviewError: clearReviewError ? null : reviewError ?? this.reviewError,
      flaggedSections: flaggedSections ?? this.flaggedSections,
      exporting: exporting ?? this.exporting,
      exportError: clearExportError ? null : exportError ?? this.exportError,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    templatesPhase,
    templates,
    templatesError?.code,
    selectedType,
    generating,
    envelope,
    content,
    error?.code,
    savingKey,
    saveError?.code,
    rewritingKey,
    proposal,
    rewriteError?.code,
    reviewing,
    reviewError?.code,
    flaggedSections,
    exporting,
    exportError?.code,
  ];
}

/// A note draft for one patient: pick a template, type what only the
/// clinician knows, generate, edit sections, review, copy out.
class NoteCubit extends Cubit<NoteDraftState> {
  NoteCubit(this._notes, this._ai, this.patientId)
    : super(const NoteDraftState());

  final NotesRepository _notes;
  final AiRepository _ai;
  final String patientId;

  String? _generateKey;
  String? _lastSignature;
  String? _rewriteKey;
  String? _lastRewrite;
  CancelToken? _cancel;

  Future<void> loadTemplates() async {
    emit(
      state.copyWith(
        templatesPhase: TemplatesPhase.loading,
        clearTemplatesError: true,
      ),
    );
    final Result<List<NoteTemplate>> result = await _notes.templates();
    if (isClosed) return;
    switch (result) {
      case Err<List<NoteTemplate>>(:final failure):
        emit(
          state.copyWith(
            templatesPhase: TemplatesPhase.failed,
            templatesError: failure.apiError,
          ),
        );
      case Ok<List<NoteTemplate>>(:final value):
        final NoteTemplate? first = value.isEmpty
            ? null
            : value.firstWhere(
                (NoteTemplate t) => t.type == 'progress',
                orElse: () => value.first,
              );
        emit(
          state.copyWith(
            templatesPhase: TemplatesPhase.ready,
            templates: value,
            selectedType: state.selectedType ?? first?.type,
          ),
        );
        // Bring back the last saved note so Copy / Reviewed are not lost
        // when the clinician leaves and reopens Notes.
        await loadLatestNote();
    }
  }

  /// Reads the newest `draft_note` artifact for this patient.
  Future<void> loadLatestNote({String? noteType}) async {
    if (state.generating) return;
    final Result<AiEnvelope?> result = await _notes.latestNote(
      patientId,
      // No type → any `draft_note:*`. Prefer an explicit type when asked.
      noteType: noteType,
    );
    if (isClosed) return;
    switch (result) {
      case Err<AiEnvelope?>():
        // Keep the empty compose screen; generation still works.
        return;
      case Ok<AiEnvelope?>(:final value):
        if (value == null) return;
        final String? type = _noteTypeOf(value) ?? state.selectedType;
        emit(_withDraft(value).copyWith(selectedType: type));
    }
  }

  /// `draft_note:progress` → `progress`, or `content.note_type`.
  static String? _noteTypeOf(AiEnvelope envelope) {
    final String fromContent = Json.string(envelope.content['note_type']);
    if (fromContent.isNotEmpty) return fromContent;
    final String op = envelope.operation;
    const String prefix = 'draft_note:';
    if (op.startsWith(prefix) && op.length > prefix.length) {
      return op.substring(prefix.length);
    }
    return null;
  }

  void selectTemplate(String type) {
    if (state.generating) return;
    emit(state.copyWith(selectedType: type));
  }

  /// Makes the draft. [inputs] holds only what the clinician typed. The
  /// Idempotency-Key is kept while a retry can help.
  Future<void> generate(
    Map<String, Object> inputs, {
    List<String>? inputsFromSourceIds,
    List<String>? applyTo,
  }) async {
    final String? type = state.selectedType;
    if (type == null || state.generating) return;
    // Different text or another template is a different action, so a new
    // key. Only an unchanged retry reuses it.
    final String signature =
        '$type|${jsonEncode(inputs)}|${jsonEncode(inputsFromSourceIds ?? const <String>[])}|${jsonEncode(applyTo ?? const <String>[])}';
    if (signature != _lastSignature) _generateKey = null;
    _lastSignature = signature;
    _generateKey ??= IdempotencyKey.create();
    final CancelToken token = _cancel = CancelToken();
    emit(
      state.copyWith(
        generating: true,
        clearError: true,
        clearReviewError: true,
        flaggedSections: const <String>[],
      ),
    );
    final Result<AiEnvelope> result = await _notes.generate(
      patientId,
      noteType: type,
      inputs: inputs,
      inputsFromSourceIds: inputsFromSourceIds,
      applyTo: applyTo,
      idempotencyKey: _generateKey!,
      cancelToken: token,
    );
    if (isClosed) return;
    switch (result) {
      case Err<AiEnvelope>(:final failure):
        final ApiError error = failure.apiError;
        if (error.kind == ApiErrorKind.cancelled) {
          _generateKey = null;
          emit(state.copyWith(generating: false));
          return;
        }
        if (!error.isRetryable) _generateKey = null;
        emit(state.copyWith(generating: false, error: error));
      case Ok<AiEnvelope>(:final value):
        _generateKey = null;
        markCensusDirty();
        emit(_withDraft(value, generating: false));
    }
  }

  /// Scribe: one messy dictation → structured note with span citations.
  Future<void> generateFromDictation({
    required String transcript,
    List<String>? sourceIds,
    List<Map<String, String>>? clarifications,
  }) async {
    final String? type = state.selectedType;
    if (type == null || state.generating) return;
    final String trimmed = transcript.trim();
    // Match UI gate and backend transcript_required — never call the API empty.
    if (trimmed.length < 12) {
      emit(
        state.copyWith(
          generating: false,
          error: const ApiError(
            code: 'transcript_required',
            message:
                'Enter a usable clinical update (at least a short sentence) before writing the note.',
          ),
        ),
      );
      return;
    }
    final String signature =
        'dictation|$type|$trimmed|${jsonEncode(sourceIds ?? const <String>[])}|${jsonEncode(clarifications ?? const <Map<String, String>>[])}';
    if (signature != _lastSignature) _generateKey = null;
    _lastSignature = signature;
    _generateKey ??= IdempotencyKey.create();
    final CancelToken token = _cancel = CancelToken();
    emit(
      state.copyWith(
        generating: true,
        clearError: true,
        clearReviewError: true,
        flaggedSections: const <String>[],
      ),
    );
    final Result<AiEnvelope> result = await _notes.generateFromDictation(
      patientId,
      noteType: type,
      transcript: trimmed,
      sourceIds: sourceIds,
      clarifications: clarifications,
      idempotencyKey: _generateKey!,
      cancelToken: token,
    );
    if (isClosed) return;
    switch (result) {
      case Err<AiEnvelope>(:final failure):
        final ApiError error = failure.apiError;
        if (error.kind == ApiErrorKind.cancelled) {
          _generateKey = null;
          emit(state.copyWith(generating: false));
          return;
        }
        if (!error.isRetryable) _generateKey = null;
        emit(state.copyWith(generating: false, error: error));
      case Ok<AiEnvelope>(:final value):
        _generateKey = null;
        markCensusDirty();
        emit(_withDraft(value, generating: false));
    }
  }

  void cancel() => _cancel?.cancel();

  NoteDraftState _withDraft(AiEnvelope envelope, {bool generating = false}) {
    return NoteDraftState(
      templatesPhase: state.templatesPhase,
      templates: state.templates,
      selectedType: state.selectedType,
      generating: generating,
      envelope: envelope,
      content: NoteContent.fromEnvelope(envelope),
    );
  }

  /// Saves text the clinician wrote or applied for one section.
  Future<void> saveSection(String key, String text) async {
    final AiEnvelope? envelope = state.envelope;
    if (envelope == null || state.busy) return;
    emit(
      state.copyWith(
        savingKey: key,
        clearSaveError: true,
        clearReviewError: true,
        flaggedSections: const <String>[],
      ),
    );
    final Result<AiEnvelope> result = await _notes.saveSection(
      envelope.artifactId,
      sectionKey: key,
      text: text,
    );
    if (isClosed) return;
    switch (result) {
      case Err<AiEnvelope>(:final failure):
        emit(state.copyWith(clearSaving: true, saveError: failure.apiError));
      case Ok<AiEnvelope>(:final value):
        emit(_withDraft(value));
    }
  }

  /// Asks for new text for a section. It is only a proposal.
  Future<void> rewrite(String key, RewriteMode mode) async {
    final AiEnvelope? envelope = state.envelope;
    if (envelope == null || state.busy) return;
    NoteSection? section;
    for (final NoteSection s in state.sections) {
      if (s.key == key) section = s;
    }
    if (section == null) return;
    // Another section or mode is a different action, so a new key.
    final String signature = '$key|${mode.wire}|${section.text}';
    if (signature != _lastRewrite) _rewriteKey = null;
    _lastRewrite = signature;
    _rewriteKey ??= IdempotencyKey.create();
    final CancelToken token = _cancel = CancelToken();
    emit(
      state.copyWith(
        rewritingKey: key,
        clearRewriteError: true,
        clearProposal: true,
      ),
    );
    final Result<RewriteProposal> result = await _notes.rewrite(
      envelope.artifactId,
      sectionKey: key,
      before: section.text,
      mode: mode,
      idempotencyKey: _rewriteKey!,
      cancelToken: token,
    );
    if (isClosed) return;
    switch (result) {
      case Err<RewriteProposal>(:final failure):
        final ApiError error = failure.apiError;
        if (error.kind == ApiErrorKind.cancelled) {
          _rewriteKey = null;
          emit(state.copyWith(clearRewriting: true));
          return;
        }
        if (!error.isRetryable) _rewriteKey = null;
        emit(state.copyWith(clearRewriting: true, rewriteError: error));
      case Ok<RewriteProposal>(:final value):
        _rewriteKey = null;
        emit(state.copyWith(clearRewriting: true, proposal: value));
    }
  }

  /// The user said keep the current text. Nothing is saved.
  void dismissProposal() => emit(state.copyWith(clearProposal: true));

  /// The user tapped Apply: the proposed text is saved with PATCH.
  Future<void> applyProposal() async {
    final RewriteProposal? p = state.proposal;
    if (p == null) return;
    emit(state.copyWith(clearProposal: true));
    await saveSection(p.sectionKey, p.after);
  }

  Future<void> markReviewed() async {
    final AiEnvelope? envelope = state.envelope;
    if (envelope == null || !state.canMarkReviewed) return;
    emit(
      state.copyWith(
        reviewing: true,
        clearReviewError: true,
        flaggedSections: const <String>[],
      ),
    );
    final Result<AiEnvelope> result = await _ai.markReviewed(
      envelope.artifactId,
    );
    if (isClosed) return;
    switch (result) {
      case Err<AiEnvelope>(:final failure):
        final ApiError error = failure.apiError;
        emit(
          state.copyWith(
            reviewing: false,
            reviewError: error,
            flaggedSections: error.sections,
          ),
        );
      case Ok<AiEnvelope>(:final value):
        markCensusDirty();
        emit(_withDraft(value));
    }
  }

  /// The clean text of a reviewed note, or `null` when it cannot be copied.
  Future<String?> export() async {
    final AiEnvelope? envelope = state.envelope;
    if (envelope == null || !state.canExport) return null;
    emit(state.copyWith(exporting: true, clearExportError: true));
    final Result<String> result = await _notes.export(envelope.artifactId);
    if (isClosed) return null;
    switch (result) {
      case Err<String>(:final failure):
        emit(state.copyWith(exporting: false, exportError: failure.apiError));
        return null;
      case Ok<String>(:final value):
        emit(state.copyWith(exporting: false));
        return value.isEmpty ? null : value;
    }
  }

  @override
  Future<void> close() {
    _cancel?.cancel();
    return super.close();
  }
}
