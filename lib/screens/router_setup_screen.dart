import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/models/dashboard_preferences.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/widgets/ssh_console_sheet.dart';

class RouterSetupScreen extends ConsumerStatefulWidget {
  final bool netifyOnly;

  const RouterSetupScreen({super.key, this.netifyOnly = false});

  @override
  ConsumerState<RouterSetupScreen> createState() => _RouterSetupScreenState();
}

class _RouterSetupScreenState extends ConsumerState<RouterSetupScreen> {
  static const _rawSetupBase =
      'https://raw.githubusercontent.com/benisai/openwalla-apk/main/openwrt-setup';

  static const _defaultFeatures = ['monitoring'];

  int _wizardStep = 0;
  bool _installAdblock = false;
  bool _installQosScripts = false;
  bool _installNetify = false;
  bool _installSimpleFlows = false;
  bool _installBanip = false;
  bool _installPbr = false;
  bool _isInstalling = false;
  bool _isUninstalling = false;
  bool _showDetails = false;
  String? _lastOutput;
  final Set<String> _uninstallFeatures = {};

  List<String> get _extraFeatures {
    if (widget.netifyOnly) return const ['netify'];
    return [
      if (_installAdblock) 'adblock',
      if (_installQosScripts) 'qos',
      if (_installSimpleFlows) 'conntrack',
      if (_installNetify) 'netify',
      if (_installBanip) 'banip',
      if (_installPbr) 'pbr',
    ];
  }

  List<String> get _selectedFeatures {
    if (widget.netifyOnly) return const ['netify'];
    return [..._defaultFeatures, ..._extraFeatures];
  }

  String get _setupCommand {
    final features = _selectedFeatures.join(' ');
    return [
      'export OPENWALLA_RAW_BASE=$_rawSetupBase',
      'export OPENWALLA_ROOT=/tmp/openwalla-app-setup',
      'fetch() { if command -v wget >/dev/null 2>&1; then wget -qO "\$2" "\$1"; else curl -fsSL "\$1" -o "\$2"; fi; }',
      'cd /tmp',
      'rm -rf "\$OPENWALLA_ROOT"',
      'rm -f setup-openwrt-router.sh',
      'fetch "\$OPENWALLA_RAW_BASE/setup-openwrt-router.sh" "setup-openwrt-router.sh"',
      'chmod 0755 setup-openwrt-router.sh',
      'sh ./setup-openwrt-router.sh $features',
    ].join(' && ');
  }

  String get _uninstallCommand {
    final features = _uninstallFeatures.join(' ');
    if (features.trim().isEmpty) return '';
    return [
      'export OPENWALLA_RAW_BASE=$_rawSetupBase',
      'export OPENWALLA_ROOT=/tmp/openwalla-app-setup',
      'fetch() { if command -v wget >/dev/null 2>&1; then wget -qO "\$2" "\$1"; else curl -fsSL "\$1" -o "\$2"; fi; }',
      'cd /tmp',
      'rm -rf "\$OPENWALLA_ROOT"',
      'rm -f setup-openwrt-router.sh',
      'fetch "\$OPENWALLA_RAW_BASE/setup-openwrt-router.sh" "setup-openwrt-router.sh"',
      'chmod 0755 setup-openwrt-router.sh',
      'sh ./setup-openwrt-router.sh uninstall $features',
    ].join(' && ');
  }

  Future<void> _copyCommand() async {
    final command = _setupCommand;
    if (command.isEmpty) {
      _showSnack('Choose at least one setup option first.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: command));
    if (!mounted) return;
    _showSnack('Router setup command copied.');
  }

  Future<void> _runSetup() async {
    final command = _setupCommand;
    if (command.isEmpty) {
      _showSnack('Choose at least one setup option first.');
      return;
    }

    setState(() {
      _isInstalling = true;
      _lastOutput =
          'Connecting to router over SSH...\nRunning Openwalla setup command...\n\nConsole output will appear here as the install runs.';
    });
    final console = SshConsoleController(
      initialOutput: _lastOutput!,
      running: true,
    );
    if (mounted) {
      unawaited(
        showSshConsoleSheet(
          context: context,
          controller: console,
          title: 'Openwalla Router Setup',
        ).whenComplete(console.dispose),
      );
    }

    try {
      final appState = ref.read(appStateProvider);
      final outputBuffer = StringBuffer();
      final output = await appState.runRouterSetupCommandViaSsh(
        command,
        onOutput: (chunk) {
          outputBuffer.write(chunk);
          console.setOutput(outputBuffer.toString().trimRight());
          if (!mounted) return;
          setState(() {
            _lastOutput = outputBuffer.toString().trimRight();
          });
        },
      );
      await _enableDashboardCardsForInstalledFeatures();
      if (!mounted) return;
      setState(() {
        _lastOutput = output.trim().isEmpty
            ? 'Setup finished. The router did not return console output.'
            : output.trim();
      });
      console.setOutput(_lastOutput!);
      _showSnack('Router setup finished.');
    } catch (e) {
      if (!mounted) return;
      console.setOutput(
        'SSH install failed. Make sure SSH is enabled on the router and the saved router username/password can log in as root. You can still copy the SSH command below and run it manually.\n\n$e',
      );
      setState(() {
        _lastOutput =
            'SSH install failed. Make sure SSH is enabled on the router and the saved router username/password can log in as root. You can still copy the SSH command below and run it manually.\n\n$e';
        _showDetails = true;
      });
      _showSnack('Router setup could not run over SSH.');
    } finally {
      console.complete();
      if (mounted) setState(() => _isInstalling = false);
    }
  }

  Future<void> _runUninstall() async {
    final command = _uninstallCommand;
    if (command.isEmpty) {
      _showSnack('Choose at least one component to remove.');
      return;
    }

    setState(() {
      _isUninstalling = true;
      _lastOutput =
          'Connecting to router over SSH...\nRemoving selected Openwalla components...\n\nConsole output will appear here as the uninstall runs.';
    });
    final console = SshConsoleController(
      initialOutput: _lastOutput!,
      running: true,
    );
    if (mounted) {
      unawaited(
        showSshConsoleSheet(
          context: context,
          controller: console,
          title: 'Remove Openwalla Components',
        ).whenComplete(console.dispose),
      );
    }

    try {
      final outputBuffer = StringBuffer();
      final output = await ref
          .read(appStateProvider)
          .runRouterSetupCommandViaSsh(
            command,
            onOutput: (chunk) {
              outputBuffer.write(chunk);
              console.setOutput(outputBuffer.toString().trimRight());
              if (!mounted) return;
              setState(() {
                _lastOutput = outputBuffer.toString().trimRight();
              });
            },
          );
      if (!mounted) return;
      setState(() {
        _lastOutput = output.trim().isEmpty
            ? 'Uninstall finished. The router did not return console output.'
            : output.trim();
      });
      console.setOutput(_lastOutput!);
      _showSnack('Selected components removed.');
    } catch (e) {
      if (!mounted) return;
      console.setOutput('SSH uninstall failed.\n\n$e');
      setState(() {
        _lastOutput = 'SSH uninstall failed.\n\n$e';
        _showDetails = true;
      });
      _showSnack('Could not remove selected components.');
    } finally {
      console.complete();
      if (mounted) setState(() => _isUninstalling = false);
    }
  }

  Future<void> _enableDashboardCardsForInstalledFeatures() async {
    final appState = ref.read(appStateProvider);
    final prefs = widget.netifyOnly
        ? appState.dashboardPreferences.copyWith(
            showFlowsCard: true,
            flowMode: DashboardFlowMode.detailed,
          )
        : appState.dashboardPreferences.copyWith(
            showNetworkPerformanceCard: true,
            showUsageCard: true,
            showMonthlyUsageCard: true,
            showFlowsCard: _installSimpleFlows || _installNetify,
            showStatisticsTab: true,
            flowMode: _installNetify
                ? DashboardFlowMode.detailed
                : _installSimpleFlows
                ? DashboardFlowMode.simple
                : appState.dashboardPreferences.flowMode,
          );

    await appState.saveDashboardPreferences(prefs);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _nextStep() {
    if (_wizardStep < _lastWizardStep) setState(() => _wizardStep += 1);
  }

  void _previousStep() {
    if (_wizardStep > 0) setState(() => _wizardStep -= 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final command = _setupCommand;
    final totalSteps = widget.netifyOnly ? 2 : 5;

    return Scaffold(
      appBar: const LuciAppBar(title: 'Router Setup', showBack: true),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [
            _WizardProgress(currentStep: _wizardStep, totalSteps: totalSteps),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: KeyedSubtree(
                key: ValueKey(_wizardStep),
                child: _buildWizardStep(theme, colorScheme),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                if (_wizardStep > 0)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isInstalling ? null : _previousStep,
                      icon: const Icon(Icons.arrow_back_rounded),
                      label: const Text('Back'),
                    ),
                  ),
                if (_wizardStep > 0) const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isInstalling
                        ? null
                        : _wizardStep == _lastWizardStep
                        ? _runSetup
                        : _nextStep,
                    icon: _isInstalling
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _wizardStep == _lastWizardStep
                                ? Icons.verified_user_outlined
                                : Icons.arrow_forward_rounded,
                          ),
                    label: Text(
                      _isInstalling
                          ? 'Installing'
                          : _wizardStep == _lastWizardStep
                          ? 'Install via SSH'
                          : 'Next',
                    ),
                  ),
                ),
              ],
            ),
            if (_wizardStep == _lastWizardStep) ...[
              const SizedBox(height: 10),
              Center(
                child: TextButton.icon(
                  onPressed: _isInstalling ? null : _copyCommand,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy SSH Command'),
                ),
              ),
            ],
            if (_wizardStep == _lastWizardStep) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.center,
                child: TextButton.icon(
                  onPressed: () => setState(() => _showDetails = !_showDetails),
                  icon: Icon(
                    _showDetails
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(_showDetails ? 'Hide Details' : 'Show Details'),
                ),
              ),
              if (_showDetails) ...[
                const SizedBox(height: 8),
                _CommandPreview(command: command),
              ],
              if (_lastOutput != null) ...[
                const SizedBox(height: 16),
                SshConsolePreview(
                  output: _lastOutput!,
                  isRunning: _isInstalling || _isUninstalling,
                ),
              ],
            ],
            if (!widget.netifyOnly) ...[
              const SizedBox(height: 20),
              _UninstallComponentsCard(
                selectedFeatures: _uninstallFeatures,
                enabled: !_isInstalling && !_isUninstalling,
                onChanged: (feature, selected) {
                  setState(() {
                    if (selected) {
                      _uninstallFeatures.add(feature);
                    } else {
                      _uninstallFeatures.remove(feature);
                    }
                  });
                },
                onRun: _runUninstall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWizardStep(ThemeData theme, ColorScheme colorScheme) {
    if (widget.netifyOnly) {
      return _wizardStep == 0
          ? _WizardIntroCard(
              title: 'Install Detailed Flow Support',
              subtitle:
                  'This focused setup installs Netify, sqlite support, the Openwalla Netify collector, and the helper service needed for Detailed Flow data. For best results, use a router with at least 512 MB RAM and a 4-core CPU.',
              icon: Icons.account_tree_rounded,
            )
          : _SetupPermissionCard(
              isInstalling: _isInstalling,
              extraSoftware: 0,
              featureCount: 1,
              onToggleDetails: () => setState(() => _showDetails = true),
            );
    }

    switch (_wizardStep) {
      case 0:
        return _WizardIntroCard(
          title: 'Welcome to Openwalla Router Setup',
          subtitle:
              'This wizard installs the OpenWrt packages and Openwalla helper scripts needed for dashboard monitoring, device inventory, usage, notifications, and router controls.',
          icon: Icons.router_rounded,
        );
      case 1:
        return _SetupFeatureCard(
          icon: Icons.inventory_2_outlined,
          title: 'Installing standard OpenWrt applications',
          subtitle:
              'uhttpd-mod-ubus, nlbwmon, vnstat2 when available, vnstat as a fallback, sqlite3-cli, conntrack, and qrencode.',
          child: const _InstallerList(
            items: [
              'uhttpd-mod-ubus',
              'Nlbwmon',
              'Vnstat2 or Vnstat',
              'sqlite3-cli',
              'conntrack',
              'qrencode',
            ],
          ),
        );
      case 2:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Would you like to install extra software?',
              style: theme.textTheme.titleLarge?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Make a selection now. These are optional packages and can be installed later.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            _ExtraSoftwareTile(
              icon: Icons.block_rounded,
              title: 'AdBlock',
              subtitle: 'DNS-based ad and tracker blocking.',
              value: _installAdblock,
              enabled: !_isInstalling,
              onChanged: (value) => setState(() => _installAdblock = value),
            ),
            _ExtraSoftwareTile(
              icon: Icons.speed_rounded,
              title: 'Smart Queue (SQM)',
              subtitle: 'Install sqm-scripts for traffic shaping.',
              value: _installQosScripts,
              enabled: !_isInstalling,
              onChanged: (value) => setState(() => _installQosScripts = value),
            ),
            _ExtraSoftwareTile(
              icon: Icons.account_tree_rounded,
              title: 'netify',
              subtitle:
                  'Detailed flow data for stronger routers. 512 MB RAM and a 4-core CPU are recommended.',
              value: _installNetify,
              enabled: !_isInstalling,
              onChanged: (value) => setState(() => _installNetify = value),
            ),
            _ExtraSoftwareTile(
              icon: Icons.route_rounded,
              title: 'Simple Flows',
              subtitle:
                  'Conntrack event flow history. 512 MB RAM and a 4-core CPU are recommended.',
              value: _installSimpleFlows,
              enabled: !_isInstalling,
              onChanged: (value) => setState(() => _installSimpleFlows = value),
            ),
            if (_installNetify || _installSimpleFlows)
              const _FlowInstallWarningCard(),
            _ExtraSoftwareTile(
              icon: Icons.shield_outlined,
              title: 'banip',
              subtitle: 'OpenWrt IP blocklist support.',
              value: _installBanip,
              enabled: !_isInstalling,
              onChanged: (value) => setState(() => _installBanip = value),
            ),
            _ExtraSoftwareTile(
              icon: Icons.alt_route_rounded,
              title: 'pbr',
              subtitle: 'Policy-based routing package support.',
              value: _installPbr,
              enabled: !_isInstalling,
              onChanged: (value) => setState(() => _installPbr = value),
            ),
          ],
        );
      case 3:
        return _SetupFeatureCard(
          icon: Icons.monitor_heart_outlined,
          title: 'Installing default Openwalla scripts',
          subtitle:
              'The app downloads the setup dispatcher with wget, then it fetches each selected feature bundle.',
          child: const _InstallerList(
            items: [
              'Ping, DNS, and speedtest monitors',
              'Notifications and device inventory',
              'Usage and per-device bandwidth helpers',
              'Internet blocking and state sync helpers',
            ],
          ),
        );
      default:
        return _SetupPermissionCard(
          isInstalling: _isInstalling,
          extraSoftware: _extraFeatures.length,
          featureCount: _selectedFeatures.length,
          onToggleDetails: () => setState(() => _showDetails = true),
        );
    }
  }

  int get _lastWizardStep => widget.netifyOnly ? 1 : 4;
}

class _SetupPermissionCard extends StatelessWidget {
  final bool isInstalling;
  final int extraSoftware;
  final int featureCount;
  final VoidCallback onToggleDetails;

  const _SetupPermissionCard({
    required this.isInstalling,
    required this.extraSoftware,
    required this.featureCount,
    required this.onToggleDetails,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const actionBlue = Color(0xFF2563EB);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: actionBlue.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.shield_outlined,
                    color: actionBlue,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Router access required',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Openwalla needs permission to install the selected packages and helper scripts on your router.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLowest.withValues(
                  alpha: 0.42,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.18),
                ),
              ),
              child: const Column(
                children: [
                  _PermissionLine(
                    icon: Icons.terminal_rounded,
                    text: 'Connect over SSH with the saved router login.',
                  ),
                  SizedBox(height: 10),
                  _PermissionLine(
                    icon: Icons.inventory_2_outlined,
                    text: 'Install standard OpenWrt application packages.',
                  ),
                  SizedBox(height: 10),
                  _PermissionLine(
                    icon: Icons.extension_outlined,
                    text: 'Install selected optional software packages.',
                  ),
                  SizedBox(height: 10),
                  _PermissionLine(
                    icon: Icons.monitor_heart_outlined,
                    text: 'Install selected Openwalla feature bundles.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Selected: $extraSoftware extra software option${extraSoftware == 1 ? '' : 's'} and $featureCount Openwalla feature bundle${featureCount == 1 ? '' : 's'}.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                Text(
                  'Want to inspect the SSH fallback?',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextButton(
                  onPressed: onToggleDetails,
                  child: const Text('Show details'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WizardProgress extends StatelessWidget {
  final int currentStep;
  final int totalSteps;

  const _WizardProgress({required this.currentStep, required this.totalSteps});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: List.generate(totalSteps, (index) {
        final active = index <= currentStep;
        return Expanded(
          child: Container(
            height: 5,
            margin: EdgeInsets.only(right: index == totalSteps - 1 ? 0 : 6),
            decoration: BoxDecoration(
              color: active
                  ? colorScheme.primary
                  : colorScheme.outlineVariant.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        );
      }),
    );
  }
}

class _WizardIntroCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;

  const _WizardIntroCard({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: colorScheme.primary, size: 28),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstallerList extends StatelessWidget {
  final List<String> items;

  const _InstallerList({required this.items});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items
          .map(
            (item) => Chip(
              avatar: Icon(
                Icons.check_circle_outline_rounded,
                size: 17,
                color: colorScheme.primary,
              ),
              label: Text(item),
            ),
          )
          .toList(),
    );
  }
}

class _ExtraSoftwareTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ExtraSoftwareTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: CheckboxListTile(
        value: value,
        onChanged: enabled ? (value) => onChanged(value ?? false) : null,
        controlAffinity: ListTileControlAffinity.trailing,
        secondary: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: colorScheme.primary),
        ),
        title: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _FlowInstallWarningCard extends StatelessWidget {
  const _FlowInstallWarningCard();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: colorScheme.errorContainer.withValues(alpha: 0.18),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Flow collectors can be heavy. Routers with less than 512 MB RAM or fewer than 4 CPU cores may slow down or crash.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UninstallComponentsCard extends StatelessWidget {
  final Set<String> selectedFeatures;
  final bool enabled;
  final void Function(String feature, bool selected) onChanged;
  final VoidCallback onRun;

  static const _items = [
    (
      feature: 'usage',
      title: 'Statistics',
      subtitle: 'vnstat/vnstat2 and nlbwmon packages.',
      icon: Icons.bar_chart_rounded,
    ),
    (
      feature: 'ping',
      title: 'Ping Monitor',
      subtitle: 'Latency helper and service.',
      icon: Icons.monitor_heart_outlined,
    ),
    (
      feature: 'dns',
      title: 'DNS Test',
      subtitle: 'DNS monitor helper and service.',
      icon: Icons.dns_rounded,
    ),
    (
      feature: 'speedtest',
      title: 'Speed Test',
      subtitle: 'Speedtest helper and cron job.',
      icon: Icons.speed_rounded,
    ),
    (
      feature: 'devices',
      title: 'Devices',
      subtitle: 'Device inventory collector.',
      icon: Icons.devices_rounded,
    ),
    (
      feature: 'bandwidth',
      title: 'Device Bandwidth',
      subtitle: 'Per-device usage collector.',
      icon: Icons.swap_vert_rounded,
    ),
    (
      feature: 'scheduler',
      title: 'Scheduler',
      subtitle: 'Scheduled device blocking helper.',
      icon: Icons.schedule_rounded,
    ),
    (
      feature: 'blocking',
      title: 'Internet Blocking',
      subtitle: 'Manual parental block helper.',
      icon: Icons.block_rounded,
    ),
    (
      feature: 'notifications',
      title: 'Notifications',
      subtitle: 'Notification database helper.',
      icon: Icons.notifications_rounded,
    ),
    (
      feature: 'netify',
      title: 'Detailed Flow',
      subtitle: 'Netify package and collector.',
      icon: Icons.account_tree_rounded,
    ),
    (
      feature: 'conntrack',
      title: 'Simple Flow',
      subtitle: 'Conntrack flow collector.',
      icon: Icons.route_rounded,
    ),
    (
      feature: 'adblock',
      title: 'AdBlock',
      subtitle: 'OpenWrt adblock package.',
      icon: Icons.shield_rounded,
    ),
    (
      feature: 'qos',
      title: 'Smart Queue',
      subtitle: 'SQM package support.',
      icon: Icons.tune_rounded,
    ),
    (
      feature: 'wireguard',
      title: 'WireGuard',
      subtitle: 'WireGuard package support.',
      icon: Icons.vpn_key_rounded,
    ),
  ];

  const _UninstallComponentsCard({
    required this.selectedFeatures,
    required this.enabled,
    required this.onChanged,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
        leading: Icon(Icons.delete_sweep_outlined, color: colorScheme.primary),
        title: Text(
          'Remove Installed Components',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        subtitle: Text(
          'Select Openwalla sub-apps to remove from this router.',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        children: [
          ..._items.map(
            (item) => CheckboxListTile(
              value: selectedFeatures.contains(item.feature),
              onChanged: enabled
                  ? (value) => onChanged(item.feature, value ?? false)
                  : null,
              controlAffinity: ListTileControlAffinity.trailing,
              secondary: Icon(item.icon, color: colorScheme.primary),
              title: Text(item.title),
              subtitle: Text(item.subtitle),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: enabled && selectedFeatures.isNotEmpty ? onRun : null,
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(
              selectedFeatures.isEmpty
                  ? 'Select Components'
                  : 'Remove Selected',
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionLine extends StatelessWidget {
  final IconData icon;
  final String text;

  const _PermissionLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const actionBlue = Color(0xFF2563EB);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: actionBlue, size: 17),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w800,
              height: 1.28,
            ),
          ),
        ),
      ],
    );
  }
}

class _SetupFeatureCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? child;

  const _SetupFeatureCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (child != null) ...[const SizedBox(height: 8), child!],
          ],
        ),
      ),
    );
  }
}

class _CommandPreview extends StatelessWidget {
  final String command;

  const _CommandPreview({required this.command});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'SSH Command',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            SelectableText(
              command.isEmpty ? 'Choose at least one setup option.' : command,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
