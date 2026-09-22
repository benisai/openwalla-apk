import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/screens/router_setup_screen.dart';
import 'package:luci_mobile/state/app_state.dart';
import 'package:luci_mobile/widgets/ssh_console_sheet.dart';

class OpenwrtFeatureGate extends ConsumerStatefulWidget {
  final OpenwrtFeature feature;
  final String title;
  final String message;
  final String installLabel;
  final WidgetBuilder builder;

  const OpenwrtFeatureGate({
    super.key,
    required this.feature,
    required this.title,
    required this.message,
    required this.installLabel,
    required this.builder,
  });

  @override
  ConsumerState<OpenwrtFeatureGate> createState() => _OpenwrtFeatureGateState();
}

class _OpenwrtFeatureGateState extends ConsumerState<OpenwrtFeatureGate> {
  late Future<OpenwrtFeatureStatus> _statusFuture;
  bool _isInstalling = false;

  @override
  void initState() {
    super.initState();
    _statusFuture = _loadStatus(force: true);
  }

  Future<OpenwrtFeatureStatus> _loadStatus({bool force = false}) {
    return ref
        .read(appStateProvider)
        .getOpenwrtFeatureStatus(
          widget.feature,
          forceRefresh: force,
          context: context,
        );
  }

  Future<void> _recheck() async {
    setState(() => _statusFuture = _loadStatus(force: true));
    await _statusFuture;
  }

  Future<void> _install() async {
    setState(() => _isInstalling = true);
    final console = SshConsoleController(
      initialOutput:
          'Connecting to router over SSH...\nRunning ${widget.installLabel}...\n\nConsole output will appear here as the install runs.',
      running: true,
    );
    if (mounted) {
      unawaited(
        showSshConsoleSheet(
          context: context,
          controller: console,
          title: widget.installLabel,
        ).whenComplete(console.dispose),
      );
    }
    try {
      final outputBuffer = StringBuffer();
      final status = await ref
          .read(appStateProvider)
          .installOpenwrtFeature(
            widget.feature,
            context: context,
            onOutput: (chunk) {
              outputBuffer.write(chunk);
              console.setOutput(outputBuffer.toString().trimRight());
            },
          );
      if (!mounted) return;
      console.setOutput(
        outputBuffer.toString().trim().isEmpty
            ? '${status.label} install finished. The router did not return console output.'
            : outputBuffer.toString().trimRight(),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status.installed
                ? '${status.label} installed.'
                : '${status.label} install finished, but it was not detected yet.',
          ),
        ),
      );
      setState(() => _statusFuture = Future.value(status));
    } catch (e) {
      console.setOutput('Install failed.\n\n$e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Install failed: $e')));
    } finally {
      console.complete();
      if (mounted) setState(() => _isInstalling = false);
    }
  }

  void _openRouterSetup() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const RouterSetupScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OpenwrtFeatureStatus>(
      future: _statusFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final status = snapshot.data;
        if (status?.installed == true) {
          return widget.builder(context);
        }

        return _FeatureInstallPrompt(
          title: widget.title,
          message: widget.message,
          installLabel: widget.installLabel,
          isInstalling: _isInstalling,
          onInstall: _install,
          onRecheck: _recheck,
          onRouterSetup: _openRouterSetup,
        );
      },
    );
  }
}

class _FeatureInstallPrompt extends StatelessWidget {
  final String title;
  final String message;
  final String installLabel;
  final bool isInstalling;
  final VoidCallback onInstall;
  final VoidCallback onRecheck;
  final VoidCallback onRouterSetup;

  const _FeatureInstallPrompt({
    required this.title,
    required this.message,
    required this.installLabel,
    required this.isInstalling,
    required this.onInstall,
    required this.onRecheck,
    required this.onRouterSetup,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.inventory_2_rounded,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isInstalling ? null : onInstall,
                icon: isInstalling
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded),
                label: Text(isInstalling ? 'Installing' : installLabel),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isInstalling ? null : onRecheck,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Check Again'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isInstalling ? null : onRouterSetup,
                    icon: const Icon(Icons.router_rounded),
                    label: const Text('Router Setup'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
