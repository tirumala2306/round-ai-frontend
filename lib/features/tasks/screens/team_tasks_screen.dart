import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:round_ai/core/di/injection_container.dart';
import 'package:round_ai/core/router/app_routes.dart';
import 'package:round_ai/core/theme/app_colors.dart';
import 'package:round_ai/core/theme/app_typography.dart';
import 'package:round_ai/features/census/repository/census_repository.dart';
import 'package:round_ai/features/tasks/bloc/team_tasks_cubit.dart';
import 'package:round_ai/features/tasks/models/patient_task.dart';
import 'package:round_ai/features/tasks/repository/tasks_repository.dart';
import 'package:round_ai/features/tasks/widgets/task_tile.dart';
import 'package:round_ai/shared/widgets/ai_error_box.dart';
import 'package:round_ai/shared/widgets/retry_view.dart';
import 'package:round_ai/shared/widgets/skeleton.dart';

/// Open tasks across the selected team, grouped by patient in room order.
/// Nothing here is ranked or prioritised by AI.
class TeamTasksScreen extends StatelessWidget {
  const TeamTasksScreen({
    this.censusRepository,
    this.tasksRepository,
    super.key,
  });

  final CensusRepository? censusRepository;
  final TasksRepository? tasksRepository;

  @override
  Widget build(BuildContext context) {
    final InjectionContainer di = InjectionContainer.instance;
    return BlocProvider<TeamTasksCubit>(
      create: (_) => TeamTasksCubit(
        censusRepository ?? di.censusRepository,
        tasksRepository ?? di.tasksRepository,
      )..load(),
      child: const _TeamView(),
    );
  }
}

class _TeamView extends StatefulWidget {
  const _TeamView();

  @override
  State<_TeamView> createState() => _TeamViewState();
}

class _TeamViewState extends State<_TeamView> {
  ValueNotifier<int>? _sync;
  int _seen = 0;

  @override
  void initState() {
    super.initState();
    try {
      _sync = InjectionContainer.instance.censusSync.revision;
      _seen = _sync!.value;
      _sync!.addListener(_onCensusSync);
    } catch (_) {}
  }

  void _onCensusSync() {
    final ValueNotifier<int>? sync = _sync;
    if (sync == null || !mounted) return;
    if (sync.value == _seen) return;
    _seen = sync.value;
    context.read<TeamTasksCubit>().load();
  }

  @override
  void dispose() {
    _sync?.removeListener(_onCensusSync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return BlocBuilder<TeamTasksCubit, TeamTasksState>(
      builder: (BuildContext context, TeamTasksState state) {
        final TeamTasksCubit cubit = context.read<TeamTasksCubit>();
        final DateTime now = DateTime.now();
        return Scaffold(
          backgroundColor: colors.background,
          body: SafeArea(
            child: state.loading
                ? const SkeletonList(count: 3)
                : state.error != null
                ? RetryView(
                    title: 'Tasks could not be loaded.',
                    message: state.error!.userMessage,
                    onRetry: cubit.load,
                  )
                : RefreshIndicator(
                    onRefresh: cubit.load,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                      children: <Widget>[
                        Text(
                          'COMMAND CENTER',
                          style: AppTypography.semiBold(
                            fontSize: 11,
                            color: colors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tasks',
                          style: AppTypography.bold(
                            fontSize: 28,
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: _Stat(
                                value: '${state.openCount}',
                                label: 'Open',
                                color: colors.primary,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _Stat(
                                value: '${state.overdueCount(now)}',
                                label: 'Overdue',
                                color: state.overdueCount(now) > 0
                                    ? colors.critical
                                    : colors.textMuted,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Overdue means past the due time set on the task.',
                          style: AppTypography.regular(
                            fontSize: 11,
                            color: colors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (state.failedPatients > 0)
                          _Notice(
                            text: state.failedPatients == 1
                                ? 'Tasks for 1 patient could not be loaded. '
                                      'Pull down to try again.'
                                : 'Tasks for ${state.failedPatients} patients '
                                      'could not be loaded. Pull down to try again.',
                          ),
                        if (state.actionError != null)
                          AiErrorBox(error: state.actionError!),
                        if (state.groups.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 24),
                            child: Text(
                              'No open tasks for this team. Add one from a '
                              'patient.',
                              textAlign: TextAlign.center,
                              style: AppTypography.regular(
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                        for (final TeamTaskGroup g in state.groups) ...<Widget>[
                          InkWell(
                            onTap: () => context.push<Object>(
                              AppRoutes.patientTasksPath(g.patient.id),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      g.patient.room.isEmpty
                                          ? g.patient.displayName
                                          : '${g.patient.displayName} · '
                                                'Room ${g.patient.room}',
                                      style: AppTypography.semiBold(
                                        fontSize: 15,
                                        color: colors.textPrimary,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    color: colors.textMuted,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          for (final PatientTask t in g.tasks)
                            TaskTile(
                              task: t,
                              now: now,
                              busy: state.busyId == t.id,
                              onComplete: state.busyId != null
                                  ? null
                                  : () => cubit.complete(t),
                            ),
                        ],
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.color});

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(value, style: AppTypography.bold(fontSize: 26, color: color)),
          const SizedBox(height: 2),
          Text(
            label,
            style: AppTypography.regular(
              fontSize: 12,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.warningSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: AppTypography.regular(
          fontSize: 12,
          height: 1.4,
          color: colors.warning,
        ),
      ),
    );
  }
}
