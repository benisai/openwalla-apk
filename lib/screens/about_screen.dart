import 'package:flutter/material.dart';
import 'package:luci_mobile/config/app_config.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _openLink(BuildContext context, String url) async {
    final opened = await launchUrlString(
      url,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open this link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const LuciAppBar(title: 'About', showBack: true),
      body: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          final version = snapshot.hasData
              ? '${snapshot.data!.version} (${snapshot.data!.buildNumber})'
              : 'Loading';
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
            children: [
              Center(
                child: Image.asset(
                  'assets/branding/openwalla-mark.png',
                  width: 88,
                  height: 88,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Openwalla',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'OpenWrt router control',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListTile(
                  leading: Icon(
                    Icons.info_outline_rounded,
                    color: colors.primary,
                  ),
                  title: const Text('Version'),
                  trailing: Text(
                    version,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  leading: Icon(Icons.code_rounded, color: colors.primary),
                  title: const Text(
                    'Openwalla on GitHub',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: const Text('benisai/openwalla-apk'),
                  trailing: const Icon(Icons.open_in_new_rounded),
                  onTap: () =>
                      _openLink(context, AppConfig.githubRepositoryUrl),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Credits',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      leading: Icon(
                        Icons.account_tree_outlined,
                        color: colors.primary,
                      ),
                      title: const Text(
                        'Original Codebase',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: const Text('cogwheel0/luci-mobile'),
                      trailing: const Icon(Icons.open_in_new_rounded),
                      onTap: () => _openLink(
                        context,
                        'https://github.com/cogwheel0/luci-mobile',
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      leading: Icon(
                        Icons.fork_right_rounded,
                        color: colors.primary,
                      ),
                      title: const Text(
                        'Fork Codebase',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: const Text('nightcodex7/yala'),
                      trailing: const Icon(Icons.open_in_new_rounded),
                      onTap: () => _openLink(
                        context,
                        'https://github.com/nightcodex7/yala',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
