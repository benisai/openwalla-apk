class SystemResourceMetrics {
  const SystemResourceMetrics({
    required this.cpuUsagePercent,
    required this.load1m,
    required this.load5m,
    required this.load15m,
    required this.totalMemoryBytes,
    required this.freeMemoryBytes,
    required this.bufferedMemoryBytes,
    required this.cachedMemoryBytes,
  });

  factory SystemResourceMetrics.fromRouterData(
    Map<String, dynamic>? sysInfo, {
    Map<String, dynamic>? boardInfo,
  }) {
    final load = _parseLoad(sysInfo);
    final directCpu = _parseDirectCpu(sysInfo);
    final cpuUsage =
        directCpu ??
        _estimateCpuUsage(load.$1, _detectCpuCores(sysInfo, boardInfo));
    final memory = sysInfo?['memory'];

    return SystemResourceMetrics(
      cpuUsagePercent: cpuUsage.clamp(0, 100).toDouble(),
      load1m: load.$1,
      load5m: load.$2,
      load15m: load.$3,
      totalMemoryBytes: _asInt(memory is Map ? memory['total'] : null),
      freeMemoryBytes: _asInt(memory is Map ? memory['free'] : null),
      bufferedMemoryBytes: _asInt(memory is Map ? memory['buffered'] : null),
      cachedMemoryBytes: _asInt(memory is Map ? memory['cached'] : null),
    );
  }

  final double cpuUsagePercent;
  final double load1m;
  final double load5m;
  final double load15m;
  final int totalMemoryBytes;
  final int freeMemoryBytes;
  final int bufferedMemoryBytes;
  final int cachedMemoryBytes;

  int get usedMemoryBytes =>
      (totalMemoryBytes - freeMemoryBytes - bufferedMemoryBytes)
          .clamp(0, totalMemoryBytes)
          .toInt();

  double get memoryUsagePercent => totalMemoryBytes > 0
      ? (usedMemoryBytes / totalMemoryBytes * 100).clamp(0, 100).toDouble()
      : 0;

  static int _asInt(dynamic value) {
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static (double, double, double) _parseLoad(Map<String, dynamic>? sysInfo) {
    final raw =
        sysInfo?['load'] ??
        sysInfo?['sysload'] ??
        sysInfo?['cpu_load'] ??
        sysInfo?['loadavg'];
    final values = raw is List
        ? raw
        : raw is Map
        ? raw.values.toList()
        : raw == null
        ? const []
        : [raw];

    double valueAt(int index) {
      if (index >= values.length) return 0;
      final parsed = values[index] is num
          ? (values[index] as num).toDouble()
          : double.tryParse(values[index].toString().trim()) ?? 0;
      return parsed > 10 ? parsed / 65536 : parsed;
    }

    return (valueAt(0), valueAt(1), valueAt(2));
  }

  static double? _parseDirectCpu(Map<String, dynamic>? sysInfo) {
    final raw =
        sysInfo?['cpu'] ??
        sysInfo?['cpu_usage'] ??
        sysInfo?['cpuload'] ??
        sysInfo?['cpu_percent'];
    dynamic value = raw;
    if (raw is Map) {
      value = raw['usage'] ?? raw['percent'] ?? raw['load'] ?? raw['total'];
      if (value == null && raw['idle'] != null) {
        final idle = _asDouble(raw['idle']);
        return idle == null ? null : 100 - idle;
      }
    }
    final parsed = _asDouble(value);
    if (parsed == null) return null;
    if (parsed > 500) return parsed / 65536 * 100;
    if (parsed <= 1) return parsed * 100;
    return parsed;
  }

  static double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll('%', '').trim() ?? '');
  }

  static double _estimateCpuUsage(double load1m, int cores) {
    if (load1m <= 0.15) return load1m * 100;
    final loadPerCore = load1m / cores;
    if (loadPerCore <= 1) {
      return 15 + (loadPerCore - 0.15) * (35 / 0.85);
    }
    return 50 + (loadPerCore - 1) * 35;
  }

  static int _detectCpuCores(
    Map<String, dynamic>? sysInfo,
    Map<String, dynamic>? boardInfo,
  ) {
    final direct =
        sysInfo?['cpuCoreCount'] ??
        sysInfo?['cpus'] ??
        sysInfo?['cpu_count'] ??
        sysInfo?['cores'] ??
        boardInfo?['cpu_count'] ??
        boardInfo?['cores'];
    final count = _asInt(direct);
    if (count > 0) return count;

    final identity =
        '${boardInfo?['model'] ?? sysInfo?['model'] ?? ''} '
                '${boardInfo?['system'] ?? sysInfo?['system'] ?? ''}'
            .toLowerCase();
    if (identity.contains('octa') || identity.contains('8-core')) return 8;
    if (const [
      'quad',
      '4-core',
      'mt7621',
      'ipq401',
      'ipq806',
      'ipq6000',
      'ipq807',
      'mt7986',
      'mt7988',
      'rk3399',
      'rk3568',
      'bcm4908',
      'filogic 830',
    ].any(identity.contains)) {
      return 4;
    }
    return 2;
  }
}
