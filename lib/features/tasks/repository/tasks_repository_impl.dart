import 'package:dio/dio.dart';
import 'package:round_ai/core/errors/failures.dart';
import 'package:round_ai/core/errors/result.dart';
import 'package:round_ai/core/network/api_client.dart';
import 'package:round_ai/core/network/api_endpoints.dart';
import 'package:round_ai/core/network/api_error.dart';
import 'package:round_ai/core/sync/census_sync_mark.dart';
import 'package:round_ai/core/utils/json_utils.dart';
import 'package:round_ai/features/tasks/models/patient_task.dart';
import 'package:round_ai/features/tasks/repository/tasks_repository.dart';

class TasksRepositoryImpl implements TasksRepository {
  TasksRepositoryImpl(this._client);

  final ApiClient _client;

  /// Owner and due time are sent only when the clinician gave them.
  static Map<String, String> _details(String? owner, DateTime? dueAt) {
    final String who = owner?.trim() ?? '';
    return <String, String>{
      if (who.isNotEmpty) 'owner': who,
      // Backend column / body field is `due`, not `due_at`.
      if (dueAt != null) 'due': dueAt.toUtc().toIso8601String(),
    };
  }

  @override
  Future<Result<List<PatientTask>>> list(String patientId) async {
    try {
      final Response<Object> response = await _client.get<Object>(
        ApiEndpoints.patientTaskList(patientId),
      );
      return Ok<List<PatientTask>>(
        Json.itemsOf(response.data, 'tasks')
            .map(
              (Map<String, dynamic> j) => PatientTask.fromJson(
                <String, dynamic>{'patient_id': patientId, ...j},
              ),
            )
            .where((PatientTask t) => t.id.isNotEmpty && t.title.isNotEmpty)
            .toList(),
      );
    } on ApiError catch (error) {
      return Err<List<PatientTask>>(ApiFailure(error));
    }
  }

  @override
  Future<Result<List<PatientTask>>> propose(
    String patientId, {
    required String idempotencyKey,
    CancelToken? cancelToken,
  }) async {
    try {
      final Response<Object> response = await _client.postAi<Object>(
        ApiEndpoints.tasksPropose(patientId),
        idempotencyKey: idempotencyKey,
        cancelToken: cancelToken,
      );
      // Envelope content is `{ task_ids, plan_date }` — not a task list.
      final Object? body = response.data;
      List<Map<String, dynamic>> items = Json.itemsOf(body, 'tasks');
      Set<String> ids = <String>{};
      if (body is Map) {
        final Map<String, dynamic> content = Json.map(body['content']);
        if (items.isEmpty) items = Json.maps(content['tasks']);
        final Object? rawIds = content['task_ids'] ?? body['task_ids'];
        if (rawIds is List) {
          ids = rawIds.map((Object? e) => e.toString()).toSet();
        }
      }
      if (items.isNotEmpty) {
        return Ok<List<PatientTask>>(
          items
              .map(
                (Map<String, dynamic> j) =>
                    PatientTask.fromJson(<String, dynamic>{
                      'patient_id': patientId,
                      ...j,
                      'state': 'proposed',
                    }),
              )
              .where((PatientTask t) => t.title.isNotEmpty)
              .toList(),
        );
      }
      // Resolve task_ids by reloading the patient task list.
      final Result<List<PatientTask>> listed = await list(patientId);
      return switch (listed) {
        Err<List<PatientTask>>() => listed,
        Ok<List<PatientTask>>(:final value) => Ok<List<PatientTask>>(
          <PatientTask>[
            for (final PatientTask t in value)
              if (ids.isEmpty
                  ? t.status == TaskStatus.proposed
                  : ids.contains(t.id))
                t,
          ],
        ),
      };
    } on ApiError catch (error) {
      return Err<List<PatientTask>>(ApiFailure(error));
    }
  }

  @override
  Future<Result<void>> add(
    String patientId, {
    required String title,
    String? owner,
    DateTime? dueAt,
  }) async {
    try {
      final Response<Object> response = await _client.post<Object>(
        ApiEndpoints.patientTaskList(patientId),
        data: <String, String>{
          // Backend: POST { text, owner?, due? }
          'text': title.trim(),
          ..._details(owner, dueAt),
        },
      );
      applyPatientStatusFromBody(response.data);
      return const Ok<void>(null);
    } on ApiError catch (error) {
      return Err<void>(ApiFailure(error));
    }
  }

  @override
  Future<Result<void>> accept(
    String taskId, {
    String? owner,
    DateTime? dueAt,
  }) async {
    try {
      final Response<Object> response = await _client.post<Object>(
        ApiEndpoints.taskAccept(taskId),
        data: _details(owner, dueAt),
      );
      applyPatientStatusFromBody(response.data);
      return const Ok<void>(null);
    } on ApiError catch (error) {
      return Err<void>(ApiFailure(error));
    }
  }

  @override
  Future<Result<void>> dismiss(String taskId) =>
      _post(ApiEndpoints.taskDismiss(taskId));

  @override
  Future<Result<void>> complete(String taskId) =>
      _post(ApiEndpoints.taskComplete(taskId));

  Future<Result<void>> _post(String path) async {
    try {
      final Response<Object> response = await _client.post<Object>(path);
      applyPatientStatusFromBody(response.data);
      return const Ok<void>(null);
    } on ApiError catch (error) {
      return Err<void>(ApiFailure(error));
    }
  }
}
