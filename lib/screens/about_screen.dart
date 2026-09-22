import 'package:flutter/material.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

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
            ],
          );
        },
      ),
    );
  }
}
