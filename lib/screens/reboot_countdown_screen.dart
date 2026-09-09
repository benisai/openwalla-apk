import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/screens/login_screen.dart';

class RebootCountdownDialog extends ConsumerStatefulWidget {
  const RebootCountdownDialog({
    super.key,
    this.duration = 60,
    this.maxAttempts = 2,
  });

  final int duration;
  final int maxAttempts;

  @override
  ConsumerState<RebootCountdownDialog> createState() =>
      _RebootCountdownDialogState();
}

class _RebootCountdownDialogState extends ConsumerState<RebootCountdownDialog> {
  Timer? _timer;
  late int _secondsRemaining;
  int _attempt = 1;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = widget.duration;
    _startCountdown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() {
      _checking = false;
      _secondsRemaining = widget.duration;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_secondsRemaining <= 1) {
        _timer?.cancel();
        unawaited(_tryReconnect());
        return;
      }
      setState(() => _secondsRemaining--);
    });
  }

  Future<void> _tryReconnect() async {
    setState(() {
      _checking = true;
      _secondsRemaining = 0;
    });

    final appState = ref.read(appStateProvider);
    await appState.retryDashboardConnection();
    if (!mounted) return;

    final reconnected =
        appState.dashboardData != null && appState.dashboardError == null;
    if (reconnected) {
      appState.finishRebootRecovery();
      appState.requestTab(0);
      final navigator = Navigator.of(context, rootNavigator: true);
      navigator.pop();
      unawaited(navigator.pushNamedAndRemoveUntil('/', (_) => false));
      return;
    }

    if (_attempt < widget.maxAttempts) {
      _attempt++;
      _startCountdown();
      return;
    }

    appState.finishRebootRecovery();
    appState.logout();
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.pop();
    unawaited(
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final progress = _checking
        ? 1.0
        : 1 - (_secondsRemaining / widget.duration).clamp(0.0, 1.0);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 146,
                  height: 146,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 10,
                    strokeCap: StrokeCap.round,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                  ),
                ),
                if (_checking)
                  const SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(strokeWidth: 4),
                  )
                else
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$_secondsRemaining',
                        style: theme.textTheme.displaySmall?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'seconds',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 26),
            Text(
              _checking ? 'Checking Connection' : 'Rebooting Router',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _checking
                  ? 'Trying to log back into the router now.'
                  : 'Attempt $_attempt of ${widget.maxAttempts}. Openwalla will try to reconnect when the timer finishes.',
              textAlign: TextAlign.center,
              style: LuciTextStyles.cardSubtitle(
                context,
              ).copyWith(height: 1.35),
            ),
          ],
        ),
      ),
    );
  }
}
