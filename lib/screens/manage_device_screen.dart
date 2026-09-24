import 'package:flutter/material.dart';
import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/screens/backup_restore_screen.dart';
import 'package:luci_mobile/screens/package_manager_screen.dart';
import 'package:luci_mobile/screens/reset_router_screen.dart';
import 'package:luci_mobile/screens/router_setup_screen.dart';
import 'package:luci_mobile/screens/ssh_terminal_screen.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';

class ManageDeviceScreen extends StatelessWidget {
  const ManageDeviceScreen({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const LuciAppBar(title: 'Manage Device', showBack: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          _DeviceManagementCard(
            children: [
              _DeviceManagementTile(
                icon: Icons.backup_rounded,
                color: colors.primary,
                title: 'Backup & Restore',
                subtitle: 'Openwalla state and router configuration',
                onTap: () => _open(context, const BackupRestoreScreen()),
              ),
              _DeviceManagementTile(
                icon: Icons.terminal_rounded,
                color: colors.primary,
                title: 'SSH Terminal',
                subtitle: 'Open a shell with saved router credentials',
                onTap: () => _open(context, const SshTerminalScreen()),
              ),
              _DeviceManagementTile(
                icon: Icons.inventory_2_rounded,
                color: colors.primary,
                title: 'Package Manager',
                subtitle: 'Install and remove OpenWrt software packages',
                onTap: () => _open(context, const PackageManagerScreen()),
              ),
              _DeviceManagementTile(
                icon: Icons.construction_rounded,
                color: colors.primary,
                title: 'Router Setup',
                subtitle: 'Install and update Openwalla router components',
                onTap: () => _open(context, const RouterSetupScreen()),
              ),
              _DeviceManagementTile(
                icon: Icons.settings_backup_restore_rounded,
                color: colors.error.withValues(alpha: 0.78),
                title: 'Reset Router',
                subtitle: 'Restore OpenWrt firmware defaults',
                onTap: () => _open(context, const ResetRouterScreen()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceManagementCard extends StatelessWidget {
  final List<Widget> children;

  const _DeviceManagementCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Column(
        children: ListTile.divideTiles(
          context: context,
          tiles: children,
        ).toList(),
      ),
    );
  }
}

class _DeviceManagementTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _DeviceManagementTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color),
      ),
      title: Text(title, style: LuciTextStyles.cardTitle(context)),
      subtitle: Text(subtitle, style: LuciTextStyles.cardSubtitle(context)),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}
