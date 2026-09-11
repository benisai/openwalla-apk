import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/screens/cpu_processes_screen.dart';
import 'package:luci_mobile/screens/memory_processes_screen.dart';
import 'package:luci_mobile/screens/system_logs_screen.dart';
import 'package:luci_mobile/state/app_state.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';

class SystemResourcesScreen extends ConsumerStatefulWidget {
  const SystemResourcesScreen({super.key});

  @override
  ConsumerState<SystemResourcesScreen> createState() =>
      _SystemResourcesScreenState();
}

class _SystemResourcesScreenState extends ConsumerState<SystemResourcesScreen> {
  static const _historyLimit = 36;
  static const _seedSampleCount = 18;

  SystemStorageDetails _storage = SystemStorageDetails.empty;
  bool _isLoadingStorage = true;
  final List<double> _cpuHistory = [];
  final List<double> _memoryHistory = [];
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _appendCurrentSample();
      await _loadStorage();
      _startRefreshTimer();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted) return;
      await ref.read(appStateProvider).fetchDashboardData();
      if (!mounted) return;
      setState(_appendCurrentSample);
    });
  }

  Future<void> _loadStorage() async {
    if (!mounted) return;
    setState(() => _isLoadingStorage = true);
    final storage = await ref
        .read(appStateProvider)
        .fetchSystemStorageDetails(context: context);
    if (!mounted) return;
    setState(() {
      _storage = storage;
      _isLoadingStorage = false;
    });
  }

  double _cpuPercent(Map<String, dynamic>? sysInfo) {
    final sampledCpu = sysInfo?['cpuUsagePercent'];
    if (sampledCpu is num) return sampledCpu.clamp(0, 100).toDouble();
    return _cpuHistory.isNotEmpty ? _cpuHistory.last : 0;
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  void _appendCurrentSample() {
    final dashboardData = ref.read(appStateProvider).dashboardData;
    final sysInfo = dashboardData?['sysInfo'] as Map<String, dynamic>?;
    final memory = sysInfo?['memory'] as Map?;

    final totalMem = _asInt(memory?['total']);
    final freeMem = _asInt(memory?['free']);
    final bufferedMem = _asInt(memory?['buffered']);
    final cachedMem = _asInt(memory?['cached']);
    final cacheBytes = cachedMem + bufferedMem;
    final usedMem = (totalMem - freeMem - cacheBytes).clamp(0, totalMem);
    final memoryPercent = totalMem > 0 ? (usedMem / totalMem) * 100 : 0.0;
    final cpuPercent = _cpuPercent(sysInfo);

    _seedHistoryIfNeeded(_cpuHistory, cpuPercent);
    _seedHistoryIfNeeded(_memoryHistory, memoryPercent);
    _pushSample(_cpuHistory, cpuPercent);
    _pushSample(_memoryHistory, memoryPercent);
  }

  void _seedHistoryIfNeeded(List<double> history, double currentValue) {
    if (history.isNotEmpty) return;

    for (var i = 0; i < _seedSampleCount; i++) {
      final progress = (i + 1) / _seedSampleCount;
      final wave = (math.sin(i * 0.78) * 3.2) + (math.cos(i * 0.41) * 1.8);
      final trend = (progress - 1) * 4;
      history.add((currentValue + wave + trend).clamp(0, 100).toDouble());
    }
  }

  void _pushSample(List<double> history, double value) {
    history.add(value.clamp(0, 100).toDouble());
    if (history.length > _historyLimit) {
      history.removeRange(0, history.length - _historyLimit);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    final mb = bytes / (1024 * 1024);
    if (mb < 1024) return '${mb.toStringAsFixed(mb >= 10 ? 1 : 1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(gb >= 10 ? 1 : 2)} GB';
  }

  String _releaseText(Map<String, dynamic>? boardInfo) {
    final release = boardInfo?['release'];
    if (release is Map) {
      final description = release['description']?.toString();
      final revision = release['revision']?.toString();
      return [
        if (description != null && description.isNotEmpty) description,
        if (revision != null && revision.isNotEmpty) revision,
      ].join(' ');
    }
    return boardInfo?['release']?.toString() ?? '-';
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final dashboardData = appState.dashboardData;
    final sysInfo = dashboardData?['sysInfo'] as Map<String, dynamic>?;
    final boardInfo = dashboardData?['boardInfo'] as Map<String, dynamic>?;
    final memory = sysInfo?['memory'] as Map?;
    final conntrack = dashboardData?['conntrack'] as Map?;

    final totalMem = _asInt(memory?['total']);
    final freeMem = _asInt(memory?['free']);
    final bufferedMem = _asInt(memory?['buffered']);
    final cachedMem = _asInt(memory?['cached']);
    final cacheBytes = cachedMem + bufferedMem;
    final usedMem = (totalMem - freeMem - cacheBytes)
        .clamp(0, totalMem)
        .toInt();
    final memoryPercent = totalMem > 0 ? (usedMem / totalMem) * 100 : 0.0;
    final cpuPercent = _cpuPercent(sysInfo);
    final connCount = _asInt(conntrack?['count']);
    final connMax = _asInt(conntrack?['max']);
    final connProgress = connMax > 0 ? connCount / connMax : 0.0;

    return Scaffold(
      appBar: const LuciAppBar(title: 'System Resources', showBack: true),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () async {
            await Future.wait([appState.fetchDashboardData(), _loadStorage()]);
            if (mounted) setState(_appendCurrentSample);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _ResourceGraphCard(
                icon: Icons.speed_rounded,
                title: 'CPU Usage',
                value: '${cpuPercent.round()}%',
                subtitle: '5 second samples',
                color: const Color(0xFF22C55E),
                samples: _cpuHistory,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const CpuProcessesScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _ResourceGraphCard(
                icon: Icons.memory_rounded,
                title: 'Memory Usage',
                value: '${memoryPercent.round()}%',
                subtitle:
                    '${_formatBytes(usedMem)} of ${_formatBytes(totalMem)}',
                color: const Color(0xFF18AEEA),
                samples: _memoryHistory,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const MemoryProcessesScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, constraints) {
                  final twoColumns = constraints.maxWidth >= 520;
                  final itemWidth = twoColumns
                      ? (constraints.maxWidth - 12) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _ResourceStatCard(
                        width: itemWidth,
                        icon: Icons.sync_rounded,
                        color: const Color(0xFFF59E0B),
                        title: 'RAM Cache',
                        value: _formatBytes(cacheBytes),
                        detail: 'Buffered and cached memory',
                        progress: totalMem > 0 ? cacheBytes / totalMem : 0,
                      ),
                      _ResourceStatCard(
                        width: itemWidth,
                        icon: Icons.account_tree_rounded,
                        color: const Color(0xFF8B5CF6),
                        title: 'Connections',
                        value: connMax > 0
                            ? '$connCount / $connMax'
                            : connCount.toString(),
                        detail: connProgress < 0.75
                            ? 'Table capacity healthy'
                            : 'Approaching table limit',
                        progress: connProgress,
                      ),
                      _ResourceStatCard(
                        width: itemWidth,
                        icon: Icons.storage_rounded,
                        color: const Color(0xFFFF424B),
                        title: 'User Storage',
                        value: _isLoadingStorage
                            ? 'Loading'
                            : _formatBytes(_storage.userFreeBytes),
                        detail: _storage.userTotalBytes > 0
                            ? 'Free of ${_formatBytes(_storage.userTotalBytes)}'
                            : 'Free space',
                        progress: _storage.userTotalBytes > 0
                            ? _storage.userFreeBytes / _storage.userTotalBytes
                            : 0,
                      ),
                      _ResourceStatCard(
                        width: itemWidth,
                        icon: Icons.developer_board_rounded,
                        color: const Color(0xFF10B981),
                        title: 'Temp Memory',
                        value: _isLoadingStorage
                            ? 'Loading'
                            : _formatBytes(_storage.tempFreeBytes),
                        detail: _storage.tempTotalBytes > 0
                            ? 'Free of ${_formatBytes(_storage.tempTotalBytes)}'
                            : 'Free space',
                        progress: _storage.tempTotalBytes > 0
                            ? _storage.tempFreeBytes / _storage.tempTotalBytes
                            : 0,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              _SystemInfoPanel(
                release: _releaseText(boardInfo),
                kernel: boardInfo?['kernel']?.toString() ?? '-',
                model: boardInfo?['model']?.toString() ?? '-',
                architecture:
                    boardInfo?['system']?.toString() ??
                    boardInfo?['architecture']?.toString() ??
                    '-',
              ),
              const SizedBox(height: 14),
              _LogsCard(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const SystemLogsScreen(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResourceGraphCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String subtitle;
  final Color color;
  final List<double> samples;
  final VoidCallback? onTap;

  const _ResourceGraphCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.color,
    required this.samples,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.chevron_right_rounded,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 92,
            child: CustomPaint(
              painter: _ResourceLinePainter(
                samples: List<double>.of(samples),
                color: color,
                gridColor: colorScheme.outlineVariant.withValues(alpha: 0.3),
                fillColor: color.withValues(alpha: 0.12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '0%',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Text(
                '100%',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );
  }
}

class _ResourceLinePainter extends CustomPainter {
  final List<double> samples;
  final Color color;
  final Color gridColor;
  final Color fillColor;

  const _ResourceLinePainter({
    required this.samples,
    required this.color,
    required this.gridColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final y in [0.0, size.height / 2, size.height]) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final trackPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.45)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      trackPaint,
    );

    if (samples.isEmpty) return;

    final points = <Offset>[];
    final count = math.max(samples.length, 2);
    for (var i = 0; i < samples.length; i++) {
      final x = samples.length == 1
          ? size.width
          : (i / (count - 1)) * size.width;
      final y = size.height - (samples[i].clamp(0, 100) / 100) * size.height;
      points.add(Offset(x, y));
    }
    if (points.length == 1) {
      points.insert(0, Offset(0, points.first.dy));
    }

    final fillPath = Path()..moveTo(points.first.dx, size.height);
    for (final point in points) {
      fillPath.lineTo(point.dx, point.dy);
    }
    fillPath
      ..lineTo(points.last.dx, size.height)
      ..close();
    canvas.drawPath(fillPath, Paint()..color = fillColor);

    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final previous = points[i - 1];
      final current = points[i];
      final midX = (previous.dx + current.dx) / 2;
      linePath.cubicTo(
        midX,
        previous.dy,
        midX,
        current.dy,
        current.dx,
        current.dy,
      );
    }
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(linePath, linePaint);

    canvas.drawCircle(points.last, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ResourceLinePainter oldDelegate) {
    return oldDelegate.samples != samples ||
        oldDelegate.color != color ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.fillColor != fillColor;
  }
}

class _ResourceStatCard extends StatelessWidget {
  final double width;
  final IconData icon;
  final Color color;
  final String title;
  final String value;
  final String detail;
  final double progress;

  const _ResourceStatCard({
    required this.width,
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.detail,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final safeProgress = progress.clamp(0, 1).toDouble();

    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, color: color, size: 19),
                  ),
                  const Spacer(),
                  Container(
                    width: 42,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: safeProgress,
                      child: Container(
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              Text(
                detail,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogsCard extends StatelessWidget {
  final VoidCallback onTap;

  const _LogsCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.article_rounded,
                  color: Color(0xFFF59E0B),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Logs',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Search recent router log entries',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SystemInfoPanel extends StatelessWidget {
  final String release;
  final String kernel;
  final String model;
  final String architecture;

  const _SystemInfoPanel({
    required this.release,
    required this.kernel,
    required this.model,
    required this.architecture,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF18AEEA).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.router_rounded,
                    color: Color(0xFF18AEEA),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Router Identity',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        release,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _InfoChip(
                  icon: Icons.terminal_rounded,
                  label: 'Kernel',
                  value: kernel,
                ),
                _InfoChip(
                  icon: Icons.devices_other_rounded,
                  label: 'Model',
                  value: model,
                ),
                _InfoChip(
                  icon: Icons.memory_rounded,
                  label: 'Platform',
                  value: architecture,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                    letterSpacing: 0,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
