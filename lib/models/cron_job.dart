class CronJob {
  const CronJob({
    required this.expression,
    required this.command,
    required this.isEnabled,
    required this.sourceLineIndex,
  });

  final String expression;
  final String command;
  final bool isEnabled;
  final int sourceLineIndex;

  String get cronLine => '${isEnabled ? '' : '# '}$expression $command';

  CronJob copyWith({
    String? expression,
    String? command,
    bool? isEnabled,
    int? sourceLineIndex,
  }) {
    return CronJob(
      expression: expression ?? this.expression,
      command: command ?? this.command,
      isEnabled: isEnabled ?? this.isEnabled,
      sourceLineIndex: sourceLineIndex ?? this.sourceLineIndex,
    );
  }
}

class CronDocument {
  const CronDocument({required this.lines, required this.jobs});

  final List<String> lines;
  final List<CronJob> jobs;

  factory CronDocument.parse(String content) {
    final lines = content.isEmpty ? <String>[] : content.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final jobs = <CronJob>[];

    for (var index = 0; index < lines.length; index++) {
      final parsed = parseCronLine(lines[index], sourceLineIndex: index);
      if (parsed != null) jobs.add(parsed);
    }
    return CronDocument(lines: lines, jobs: jobs);
  }

  static CronJob? parseCronLine(String line, {required int sourceLineIndex}) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    final isEnabled = !trimmed.startsWith('#');
    final clean = isEnabled ? trimmed : trimmed.substring(1).trim();
    final parts = clean.split(RegExp(r'\s+'));
    if (parts.length < 6) return null;
    final expression = parts.take(5).join(' ');
    if (CronSchedule.validate(expression) != null) return null;
    return CronJob(
      expression: expression,
      command: parts.skip(5).join(' '),
      isEnabled: isEnabled,
      sourceLineIndex: sourceLineIndex,
    );
  }

  String replace(CronJob original, CronJob replacement) {
    final updated = [...lines];
    updated[original.sourceLineIndex] = replacement.cronLine;
    return _serialize(updated);
  }

  String delete(CronJob job) {
    final updated = [...lines]..removeAt(job.sourceLineIndex);
    return _serialize(updated);
  }

  String append(CronJob job) => _serialize([...lines, job.cronLine]);

  static String _serialize(List<String> lines) {
    return lines.isEmpty ? '' : '${lines.join('\n')}\n';
  }
}

class CronPreset {
  const CronPreset(this.label, this.expression);

  final String label;
  final String expression;
}

const cronPresets = <CronPreset>[
  CronPreset('Every 5 Minutes', '*/5 * * * *'),
  CronPreset('Every 15 Minutes', '*/15 * * * *'),
  CronPreset('Every Hour', '0 * * * *'),
  CronPreset('Every Day at Midnight', '0 0 * * *'),
  CronPreset('Every Day at 4:00 AM', '0 4 * * *'),
  CronPreset('Every Weekday at Midnight', '0 0 * * 1-5'),
  CronPreset('Every Sunday at Midnight', '0 0 * * 0'),
  CronPreset('First Day of Every Month', '0 0 1 * *'),
  CronPreset('Custom Expression', ''),
];

class CronSchedule {
  static String? validate(String expression) {
    final parts = expression.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) {
      return 'Enter 5 fields: minute hour day month weekday';
    }
    final fields = [
      (parts[0], 'Minute', 0, 59),
      (parts[1], 'Hour', 0, 23),
      (parts[2], 'Day', 1, 31),
      (parts[3], 'Month', 1, 12),
      (parts[4], 'Weekday', 0, 7),
    ];
    for (final field in fields) {
      final error = _validateField(field.$1, field.$2, field.$3, field.$4);
      if (error != null) return error;
    }
    return null;
  }

  static String? _validateField(String value, String name, int min, int max) {
    if (value == '*') return null;
    if (value.contains('/')) {
      final pieces = value.split('/');
      if (pieces.length != 2 ||
          int.tryParse(pieces[1]) == null ||
          int.parse(pieces[1]) <= 0) {
        return 'Invalid $name step';
      }
      return pieces[0] == '*'
          ? null
          : _validateField(pieces[0], name, min, max);
    }
    if (value.contains(',')) {
      for (final item in value.split(',')) {
        final error = _validateField(item, name, min, max);
        if (error != null) return error;
      }
      return null;
    }
    if (value.contains('-')) {
      final pieces = value.split('-');
      if (pieces.length != 2) return 'Invalid $name range';
      final start = int.tryParse(pieces[0]);
      final end = int.tryParse(pieces[1]);
      if (start == null || end == null || start > end) {
        return 'Invalid $name range';
      }
      if (start < min || end > max) return '$name must be $min-$max';
      return null;
    }
    final number = int.tryParse(value);
    if (number == null || number < min || number > max) {
      return '$name must be $min-$max';
    }
    return null;
  }

  static String describe(String expression) {
    final exact = cronPresets.where(
      (preset) => preset.expression == expression,
    );
    if (exact.isNotEmpty && exact.first.expression.isNotEmpty) {
      return exact.first.label;
    }
    if (validate(expression) != null) return 'Custom schedule';
    final parts = expression.trim().split(RegExp(r'\s+'));
    final minute = parts[0];
    final hour = parts[1];
    final day = parts[2];
    final month = parts[3];
    final weekday = parts[4];
    if (minute == '*' &&
        hour == '*' &&
        day == '*' &&
        month == '*' &&
        weekday == '*') {
      return 'Every minute';
    }
    if (minute.startsWith('*/') &&
        hour == '*' &&
        day == '*' &&
        month == '*' &&
        weekday == '*') {
      return 'Every ${minute.substring(2)} minutes';
    }
    final parsedHour = int.tryParse(hour);
    final parsedMinute = int.tryParse(minute);
    if (parsedHour != null && parsedMinute != null) {
      final period = parsedHour >= 12 ? 'PM' : 'AM';
      final hour12 = parsedHour == 0
          ? 12
          : (parsedHour > 12 ? parsedHour - 12 : parsedHour);
      final time = '$hour12:${parsedMinute.toString().padLeft(2, '0')} $period';
      if (day == '*' && month == '*' && weekday == '*') {
        return 'Every day at $time';
      }
      if (day == '*' && month == '*' && (weekday == '0' || weekday == '7')) {
        return 'Every Sunday at $time';
      }
      if (day == '*' && month == '*' && weekday == '1-5') {
        return 'Weekdays at $time';
      }
      if (day != '*' && month == '*' && weekday == '*') {
        return 'Day $day of each month at $time';
      }
    }
    return 'Cron schedule: $expression';
  }
}
