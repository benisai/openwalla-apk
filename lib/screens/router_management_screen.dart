import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/screens/backup_restore_screen.dart';
import 'package:luci_mobile/screens/reboot_countdown_screen.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';

class RouterManagementScreen extends ConsumerStatefulWidget {
  const RouterManagementScreen({super.key});

  @override
  ConsumerState<RouterManagementScreen> createState() =>
      _RouterManagementScreenState();
}

class _RouterManagementScreenState
    extends ConsumerState<RouterManagementScreen> {
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final appState = ref.read(appStateProvider);
    if (appState.dashboardData == null) {
      unawaited(appState.fetchDashboardData());
    }
  }

  Future<void> _showRebootConfirmation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.restart_alt_rounded),
            SizedBox(width: 12),
            Expanded(child: Text('Restart Router?')),
          ],
        ),
        content: const Text(
          'Connected devices will briefly lose network access while the router restarts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Restart'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const RebootCountdownDialog(
        duration: 60,
        maxAttempts: 2,
        sendRebootCommand: true,
      ),
    );
  }

  Future<void> _showFactoryResetConfirmation() async {
    final colors = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.warning_amber_rounded,
                color: colors.onErrorContainer,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Text('Perform Factory Reset?')),
          ],
        ),
        content: const Text(
          'This permanently erases custom settings, passwords, installed packages, and restores the firmware defaults.\n\nThe router will restart automatically. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Perform Factory Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _loading = true);
    final success = await ref
        .read(appStateProvider)
        .factoryReset(context: context);
    if (!mounted) return;
    setState(() => _loading = false);

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Factory reset could not be started.')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Factory reset started. Router rebooting.')),
    );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const RebootCountdownDialog(duration: 75, maxAttempts: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final colors = Theme.of(context).colorScheme;
    final board = appState.dashboardData?['boardInfo'];
    final boardInfo = board is Map ? board : const <String, dynamic>{};
    final release = boardInfo['release'];
    final releaseInfo = release is Map ? release : const <String, dynamic>{};
    final router = appState.selectedRouter;
    final busy = _loading || appState.isRebooting;

    String value(dynamic candidate, [String fallback = 'Unavailable']) {
      final text = candidate?.toString().trim() ?? '';
      return text.isEmpty ? fallback : text;
    }

    return Scaffold(
      appBar: const LuciAppBar(title: 'Router Management', showBack: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
        children: [
          _SectionHeading(
            icon: Icons.router_outlined,
            title: 'Router Information',
          ),
          const SizedBox(height: 10),
          _ManagementCard(
            child: Column(
              children: [
                _InfoRow(
                  label: 'Model',
                  value: value(
                    boardInfo['model'],
                    router?.lastKnownHostname ?? 'OpenWrt Router',
                  ),
                ),
                const Divider(height: 25),
                _InfoRow(
                  label: 'Firmware',
                  value: value(
                    releaseInfo['description'],
                    value(releaseInfo['release']),
                  ),
                ),
                const Divider(height: 25),
                _InfoRow(
                  label: 'Architecture',
                  value: value(
                    boardInfo['system'],
                    value(boardInfo['board_name']),
                  ),
                ),
                const Divider(height: 25),
                _InfoRow(label: 'Address', value: value(router?.ipAddress)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _SectionHeading(
            icon: Icons.settings_backup_restore_rounded,
            title: 'System Operations',
          ),
          const SizedBox(height: 10),
          _ManagementCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _ActionTile(
                  icon: Icons.restart_alt_rounded,
                  title: 'Restart Router',
                  subtitle: 'Restart OpenWrt and reconnect automatically',
                  onTap: busy ? null : _showRebootConfirmation,
                ),
                const Divider(height: 1, indent: 64),
                _ActionTile(
                  icon: Icons.archive_outlined,
                  title: 'Backup & Restore',
                  subtitle: 'Manage Openwalla state and scheduled backups',
                  onTap: busy
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const BackupRestoreScreen(),
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _SectionHeading(
            icon: Icons.restore_outlined,
            title: 'Restore & Reset Settings',
            color: colors.error,
          ),
          const SizedBox(height: 10),
          _ManagementCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Return the router firmware to its default state. This cannot be undone.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.error,
                    side: BorderSide(color: colors.error),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  onPressed: busy ? null : _showFactoryResetConfirmation,
                  icon: _loading
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.error,
                          ),
                        )
                      : const Icon(Icons.delete_forever_outlined),
                  label: Text(
                    _loading
                        ? 'Starting Factory Reset...'
                        : 'Perform Factory Reset',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.icon, required this.title, this.color});

  final IconData icon;
  final String title;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Icon(icon, size: 22, color: accent),
        const SizedBox(width: 10),
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

class _ManagementCard extends StatelessWidget {
  const _ManagementCard({
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: 0.35),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: colors.onPrimaryContainer),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}
