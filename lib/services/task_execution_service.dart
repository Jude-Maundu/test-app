import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum TaskStatus {
  idle,
  planning,
  waitingForPermission,
  waitingForAuthorization,
  executing,
  verifying,
  paused,
  completed,
  failed,
  cancelled,
}

class TaskStep {
  const TaskStep({
    required this.tool,
    required this.arguments,
    required this.status,
    required this.result,
    required this.createdAt,
    this.error,
    this.verified = false,
  });

  final String tool;
  final Map<String, dynamic> arguments;
  final String status;
  final String result;
  final DateTime createdAt;
  final String? error;
  final bool verified;

  Map<String, dynamic> toJson() => {
    'tool': tool,
    'arguments': arguments,
    'status': status,
    'result': result,
    'createdAt': createdAt.toIso8601String(),
    'error': error,
    'verified': verified,
  };

  factory TaskStep.fromJson(Map<String, dynamic> json) => TaskStep(
    tool: json['tool'] as String,
    arguments: Map<String, dynamic>.from(json['arguments'] as Map),
    status: json['status'] as String,
    result: json['result'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    error: json['error'] as String?,
    verified: json['verified'] as bool? ?? false,
  );
}

class TaskRecord {
  const TaskRecord({
    required this.id,
    required this.instruction,
    required this.status,
    required this.steps,
    required this.result,
    required this.error,
    required this.createdAt,
    required this.updatedAt,
    this.plan = const [],
  });

  final String id;
  final String instruction;
  final TaskStatus status;
  final List<TaskStep> steps;
  final List<String> plan;
  final String? result;
  final String? error;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'instruction': instruction,
    'status': status.name,
    'steps': steps.map((step) => step.toJson()).toList(),
    'plan': plan,
    'result': result,
    'error': error,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory TaskRecord.fromJson(Map<String, dynamic> json) => TaskRecord(
    id: json['id'] as String,
    instruction: json['instruction'] as String,
    status: TaskStatus.values.firstWhere(
      (status) => status.name == json['status'],
      orElse: () => TaskStatus.idle,
    ),
    steps: (json['steps'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map(TaskStep.fromJson)
        .toList(),
    plan: (json['plan'] as List<dynamic>?)?.whereType<String>().toList() ??
        const [],
    result: json['result'] as String?,
    error: json['error'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

class TaskExecutionService {
  TaskExecutionService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _storageKey = 'jarvis_task_history';
  static const int maxStepsPerTask = 8;
  static const int maxTasks = 25;

  final FlutterSecureStorage _storage;
  final List<TaskRecord> _tasks = [];
  bool _loaded = false;

  TaskRecord? get activeTask => _tasks
      .where(
        (task) => {
          TaskStatus.planning,
          TaskStatus.waitingForPermission,
          TaskStatus.waitingForAuthorization,
          TaskStatus.executing,
          TaskStatus.verifying,
          TaskStatus.paused,
        }.contains(task.status),
      )
      .firstOrNull;

  Future<TaskRecord?> getActiveTask() async {
    await _load();
    return activeTask;
  }

  Future<void> init() async {
    await _load();
  }

  Future<List<TaskRecord>> listRecentTasks() async {
    await _load();
    return List.unmodifiable(_tasks);
  }

  Future<TaskRecord?> getTask(String id) async {
    await _load();
    return _tasks.where((task) => task.id == id).firstOrNull;
  }

  Future<TaskRecord> createTask(String instruction) async {
    await _load();
    final now = DateTime.now();
    final task = TaskRecord(
      id: now.microsecondsSinceEpoch.toRadixString(36),
      instruction: instruction,
      status: TaskStatus.planning,
      steps: const [],
      plan: const [],
      result: null,
      error: null,
      createdAt: now,
      updatedAt: now,
    );
    _tasks.insert(0, task);
    await _save();
    return task;
  }

  Future<TaskRecord> setStatus(String id, TaskStatus status) async =>
      _update(id, (task) => _copy(task, status: status));

  Future<TaskRecord> setPlan(String id, List<String> plan) async =>
      _update(id, (task) => _copy(task, plan: plan));

  Future<TaskRecord> addStep(
    String id, {
    required String tool,
    required Map<String, dynamic> arguments,
    required String status,
    required String result,
    String? error,
    bool verified = false,
  }) async => _update(id, (task) {
    final step = TaskStep(
      tool: tool,
      arguments: Map.unmodifiable(arguments),
      status: status,
      result: result,
      error: error,
      verified: verified,
      createdAt: DateTime.now(),
    );
    return _copy(task, steps: [...task.steps, step]);
  });

  Future<TaskRecord> finish(
    String id, {
    required TaskStatus status,
    String? result,
    String? error,
  }) async => _update(
    id,
    (task) => _copy(task, status: status, result: result, error: error),
  );

  Future<TaskRecord?> cancelActiveTask() async {
    await _load();
    final task = activeTask;
    if (task == null) return null;
    return finish(task.id, status: TaskStatus.cancelled);
  }

  Future<void> _load() async {
    if (_loaded) return;
    final raw = await _storage.read(key: _storageKey);
    if (raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        throw const FormatException('Saved task history is not a list.');
      }
      _tasks
        ..clear()
        ..addAll(
          decoded
              .whereType<Map<String, dynamic>>()
              .map(TaskRecord.fromJson),
        );
    }
    _loaded = true;
  }

  Future<TaskRecord> _update(
    String id,
    TaskRecord Function(TaskRecord task) update,
  ) async {
    await _load();
    final index = _tasks.indexWhere((task) => task.id == id);
    if (index < 0) throw StateError('Task $id was not found.');
    _tasks[index] = update(_tasks[index]);
    await _save();
    return _tasks[index];
  }

  TaskRecord _copy(
    TaskRecord task, {
    TaskStatus? status,
    List<TaskStep>? steps,
    List<String>? plan,
    String? result,
    String? error,
  }) => TaskRecord(
    id: task.id,
    instruction: task.instruction,
    status: status ?? task.status,
    steps: steps ?? task.steps,
    plan: plan ?? task.plan,
    result: result ?? task.result,
    error: error ?? task.error,
    createdAt: task.createdAt,
    updatedAt: DateTime.now(),
  );

  Future<void> _save() => _storage.write(
    key: _storageKey,
    value: jsonEncode(_tasks.take(maxTasks).map((task) => task.toJson()).toList()),
  );
}
