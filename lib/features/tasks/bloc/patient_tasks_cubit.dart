import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:round_ai/core/errors/failures.dart';
import 'package:round_ai/core/errors/result.dart';
import 'package:round_ai/core/network/api_error.dart';
import 'package:round_ai/core/network/idempotency_key.dart';
import 'package:round_ai/core/sync/census_sync_mark.dart';
import 'package:round_ai/features/patient/models/patient_detail.dart';
import 'package:round_ai/features/patient/repository/patient_repository.dart';
import 'package:round_ai/features/tasks/models/patient_task.dart';
import 'package:round_ai/features/tasks/repository/tasks_repository.dart';

class PatientTasksState extends Equatable {
  const PatientTasksState({
    this.loading = true,
    this.tasks = const <PatientTask>[],
    this.hasPlan,
    this.proposing = false,
    this.busyId,
    this.adding = false,
    this.loadError,
    this.proposeError,
    this.actionError,
    this.proposedCount,
    this.changes = 0,
  });

  final bool loading;
  final List<PatientTask> tasks;

  /// Whether a plan is saved. `null` while it could not be read, in which
  /// case the server decides.
  final bool? hasPlan;
  final bool proposing;

  /// The task an action is running on.
  final String? busyId;
  final bool adding;
  final ApiError? loadError;
  final ApiError? proposeError;
  final ApiError? actionError;

  /// How many tasks the last proposal returned. `null` until it has run.
  final int? proposedCount;

  /// Goes up when a task is added, accepted, dismissed or completed.
  final int changes;

  List<PatientTask> get proposed => <PatientTask>[
    for (final PatientTask t in tasks)
      if (t.status == TaskStatus.proposed) t,
  ];
  List<PatientTask> get open => <PatientTask>[
    for (final PatientTask t in tasks)
      if (t.status == TaskStatus.open) t,
  ];
  List<PatientTask> get completed => <PatientTask>[
    for (final PatientTask t in tasks)
      if (t.status == TaskStatus.completed) t,
  ];

  bool get canPropose => hasPlan != false && !proposing && busyId == null;

  PatientTasksState copyWith({
    bool? loading,
    List<PatientTask>? tasks,
    bool? hasPlan,
    bool? proposing,
    String? busyId,
    bool clearBusy = false,
    bool? adding,
    ApiError? loadError,
    bool clearLoadError = false,
    ApiError? proposeError,
    bool clearProposeError = false,
    ApiError? actionError,
    bool clearActionError = false,
    int? proposedCount,
    int? changes,
  }) {
    return PatientTasksState(
      loading: loading ?? this.loading,
      tasks: tasks ?? this.tasks,
      hasPlan: hasPlan ?? this.hasPlan,
      proposing: proposing ?? this.proposing,
      busyId: clearBusy ? null : busyId ?? this.busyId,
      adding: adding ?? this.adding,
      loadError: clearLoadError ? null : loadError ?? this.loadError,
      proposeError: clearProposeError
          ? null
          : proposeError ?? this.proposeError,
      actionError: clearActionError ? null : actionError ?? this.actionError,
      proposedCount: proposedCount ?? this.proposedCount,
      changes: changes ?? this.changes,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    loading,
    tasks,
    hasPlan,
    proposing,
    busyId,
    adding,
    loadError?.code,
    proposeError?.code,
    actionError?.code,
    proposedCount,
    changes,
  ];
}

/// One patient's tasks. A proposed task is not a task until it is accepted.
class PatientTasksCubit extends Cubit<PatientTasksState> {
  PatientTasksCubit(this._tasks, this._patients, this.patientId)
    : super(const PatientTasksState());

  final TasksRepository _tasks;
  final PatientRepository _patients;
  final String patientId;

  String? _key;
  CancelToken? _cancel;

  Future<void> load() async {
    emit(state.copyWith(loading: true, clearLoadError: true));
    final List<Object> both = await Future.wait<Object>(<Future<Object>>[
      _tasks.list(patientId),
      _patients.loadDetail(patientId),
    ]);
    if (isClosed) return;
    final Result<List<PatientTask>> list = both[0] as Result<List<PatientTask>>;
    final Result<PatientDetail> detail = both[1] as Result<PatientDetail>;
    final bool? hasPlan = switch (detail) {
      Ok<PatientDetail>(:final value) => value.planToday.isNotEmpty,
      Err<PatientDetail>() => null,
    };
    switch (list) {
      case Err<List<PatientTask>>(:final failure):
        emit(
          state.copyWith(
            loading: false,
            hasPlan: hasPlan,
            loadError: failure.apiError,
          ),
        );
      case Ok<List<PatientTask>>(:final value):
        emit(state.copyWith(loading: false, tasks: value, hasPlan: hasPlan));
    }
  }

  Future<void> _reloadTasks() async {
    final Result<List<PatientTask>> list = await _tasks.list(patientId);
    if (isClosed) return;
    if (list case Ok<List<PatientTask>>(:final value)) {
      emit(state.copyWith(tasks: value));
    }
  }

  /// Asks for tasks from the saved plan. Without a plan nothing is sent.
  Future<void> propose() async {
    if (!state.canPropose) return;
    _key ??= IdempotencyKey.create();
    final CancelToken token = _cancel = CancelToken();
    emit(state.copyWith(proposing: true, clearProposeError: true));
    final Result<List<PatientTask>> result = await _tasks.propose(
      patientId,
      idempotencyKey: _key!,
      cancelToken: token,
    );
    if (isClosed) return;
    switch (result) {
      case Err<List<PatientTask>>(:final failure):
        final ApiError error = failure.apiError;
        if (error.kind == ApiErrorKind.cancelled) {
          _key = null;
          emit(state.copyWith(proposing: false));
          return;
        }
        if (!error.isRetryable) _key = null;
        emit(state.copyWith(proposing: false, proposeError: error));
      case Ok<List<PatientTask>>(:final value):
        _key = null;
        final Set<String> have = state.tasks
            .map((PatientTask t) => t.id)
            .toSet();
        emit(
          state.copyWith(
            proposing: false,
            proposedCount: value.length,
            tasks: <PatientTask>[
              ...state.tasks,
              for (final PatientTask t in value)
                if (!have.contains(t.id)) t,
            ],
          ),
        );
        await _reloadTasks();
    }
  }

  void cancelPropose() => _cancel?.cancel();

  Future<void> _act(String id, Future<Result<void>> Function() action) async {
    if (state.busyId != null) return;
    emit(state.copyWith(busyId: id, clearActionError: true));
    final Result<void> result = await action();
    if (isClosed) return;
    switch (result) {
      case Err<void>(:final failure):
        emit(state.copyWith(clearBusy: true, actionError: failure.apiError));
      case Ok<void>():
        markCensusDirty();
        emit(state.copyWith(clearBusy: true, changes: state.changes + 1));
        await _reloadTasks();
    }
  }

  /// The clinician accepted a proposal. Owner and due time are optional.
  Future<void> accept(PatientTask task, {String? owner, DateTime? dueAt}) =>
      _act(task.id, () => _tasks.accept(task.id, owner: owner, dueAt: dueAt));

  Future<void> dismiss(PatientTask task) =>
      _act(task.id, () => _tasks.dismiss(task.id));

  Future<void> complete(PatientTask task) =>
      _act(task.id, () => _tasks.complete(task.id));

  /// A task the clinician typed. It is open at once.
  Future<bool> add({
    required String title,
    String? owner,
    DateTime? dueAt,
  }) async {
    if (state.adding || title.trim().isEmpty) return false;
    emit(state.copyWith(adding: true, clearActionError: true));
    final Result<void> result = await _tasks.add(
      patientId,
      title: title,
      owner: owner,
      dueAt: dueAt,
    );
    if (isClosed) return false;
    switch (result) {
      case Err<void>(:final failure):
        emit(state.copyWith(adding: false, actionError: failure.apiError));
        return false;
      case Ok<void>():
        markCensusDirty();
        emit(state.copyWith(adding: false, changes: state.changes + 1));
        await _reloadTasks();
        return true;
    }
  }

  @override
  Future<void> close() {
    _cancel?.cancel();
    return super.close();
  }
}
