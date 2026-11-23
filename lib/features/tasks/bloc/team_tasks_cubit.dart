import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:round_ai/core/errors/failures.dart';
import 'package:round_ai/core/errors/result.dart';
import 'package:round_ai/core/network/api_error.dart';
import 'package:round_ai/core/di/injection_container.dart';
import 'package:round_ai/core/sync/census_sync_mark.dart';
import 'package:round_ai/core/sync/patient_status_store.dart';
import 'package:round_ai/features/census/models/patient_summary.dart';
import 'package:round_ai/features/census/repository/census_repository.dart';
import 'package:round_ai/features/tasks/models/patient_task.dart';
import 'package:round_ai/features/tasks/repository/tasks_repository.dart';

/// The open tasks of one patient.
class TeamTaskGroup extends Equatable {
  const TeamTaskGroup({required this.patient, required this.tasks});

  final PatientSummary patient;
  final List<PatientTask> tasks;

  @override
  List<Object> get props => <Object>[patient, tasks];
}

class TeamTasksState extends Equatable {
  const TeamTasksState({
    this.loading = true,
    this.groups = const <TeamTaskGroup>[],
    this.error,
    this.failedPatients = 0,
    this.busyId,
    this.actionError,
  });

  final bool loading;

  /// Patients with open tasks, in room order.
  final List<TeamTaskGroup> groups;

  /// The patient list could not be read.
  final ApiError? error;

  /// Patients whose tasks could not be read. The rest are still shown.
  final int failedPatients;
  final String? busyId;
  final ApiError? actionError;

  int get openCount =>
      groups.fold<int>(0, (int n, TeamTaskGroup g) => n + g.tasks.length);

  int overdueCount(DateTime now) => groups.fold<int>(
    0,
    (int n, TeamTaskGroup g) =>
        n + g.tasks.where((PatientTask t) => t.isOverdue(now)).length,
  );

  TeamTasksState copyWith({
    bool? loading,
    List<TeamTaskGroup>? groups,
    ApiError? error,
    bool clearError = false,
    int? failedPatients,
    String? busyId,
    bool clearBusy = false,
    ApiError? actionError,
    bool clearActionError = false,
  }) {
    return TeamTasksState(
      loading: loading ?? this.loading,
      groups: groups ?? this.groups,
      error: clearError ? null : error ?? this.error,
      failedPatients: failedPatients ?? this.failedPatients,
      busyId: clearBusy ? null : busyId ?? this.busyId,
      actionError: clearActionError ? null : actionError ?? this.actionError,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    loading,
    groups,
    error?.code,
    failedPatients,
    busyId,
    actionError?.code,
  ];
}

/// Open tasks across the selected team. There is no team-wide endpoint, so
/// the census says who has open tasks and each of those is read.
class TeamTasksCubit extends Cubit<TeamTasksState> {
  TeamTasksCubit(this._census, this._tasks) : super(const TeamTasksState());

  final CensusRepository _census;
  final TasksRepository _tasks;

  Future<void> load() async {
    // A reload keeps the list on screen. Only the first read shows a spinner.
    emit(state.copyWith(loading: state.groups.isEmpty, clearError: true));
    final Result<List<PatientSummary>> census = await _census.loadPatients();
    if (isClosed) return;
    if (census case Err<List<PatientSummary>>(:final failure)) {
      emit(state.copyWith(loading: false, error: failure.apiError));
      return;
    }
    PatientStatusStore? statusStore;
    try {
      statusStore = InjectionContainer.instance.patientStatusStore;
    } catch (_) {}
    final List<PatientSummary> patients = <PatientSummary>[
      for (final PatientSummary raw
          in (census as Ok<List<PatientSummary>>).value)
        if ((statusStore?.overlay(raw) ?? raw).openTasks > 0)
          statusStore?.overlay(raw) ?? raw,
    ];
    final List<Result<List<PatientTask>>> lists =
        await Future.wait<Result<List<PatientTask>>>(
          <Future<Result<List<PatientTask>>>>[
            for (final PatientSummary p in patients) _tasks.list(p.id),
          ],
        );
    if (isClosed) return;
    final List<TeamTaskGroup> groups = <TeamTaskGroup>[];
    int failed = 0;
    for (int i = 0; i < patients.length; i++) {
      switch (lists[i]) {
        case Err<List<PatientTask>>():
          failed++;
        case Ok<List<PatientTask>>(:final value):
          final List<PatientTask> open = <PatientTask>[
            for (final PatientTask t in value)
              if (t.status == TaskStatus.open) t,
          ];
          if (open.isNotEmpty) {
            groups.add(TeamTaskGroup(patient: patients[i], tasks: open));
          }
      }
    }
    emit(
      state.copyWith(
        loading: false,
        groups: groups,
        failedPatients: failed,
        clearActionError: true,
      ),
    );
  }

  Future<void> complete(PatientTask task) async {
    if (state.busyId != null) return;
    emit(state.copyWith(busyId: task.id, clearActionError: true));
    final Result<void> result = await _tasks.complete(task.id);
    if (isClosed) return;
    switch (result) {
      case Err<void>(:final failure):
        emit(state.copyWith(clearBusy: true, actionError: failure.apiError));
      case Ok<void>():
        markCensusDirty();
        emit(state.copyWith(clearBusy: true));
        await load();
    }
  }
}
