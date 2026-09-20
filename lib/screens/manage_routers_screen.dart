import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/models/router.dart' as model;
import 'package:luci_mobile/widgets/luci_app_bar.dart';

class ManageRoutersScreen extends ConsumerStatefulWidget {
  const ManageRoutersScreen({super.key});

  @override
  ConsumerState<ManageRoutersScreen> createState() =>
      _ManageRoutersScreenState();
}

class _ManageRoutersScreenState extends ConsumerState<ManageRoutersScreen> {
  bool _busy = false;

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _importProfiles() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      final bytes = picked?.files.single.bytes;
      if (bytes == null) return;
      final result = await ref
          .read(appStateProvider)
          .importRouterProfiles(utf8.decode(bytes, allowMalformed: true));
      if (!mounted) return;
      if (!result.success) {
        _message(result.errorMessage ?? 'Unable to import router profiles.');
        return;
      }
      _message(
        'Imported ${result.importedCount} and updated ${result.updatedCount} router profiles.',
      );
    } catch (error) {
      _message('Unable to import profiles: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportProfiles() async {
    if (_busy) return;
    final appState = ref.read(appStateProvider);
    if (appState.routers.isEmpty) {
      _message('There are no saved routers to export.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export router profiles?'),
        content: const Text(
          'The JSON backup includes router addresses, usernames, and passwords. Store it securely.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('Export'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final json = appState.exportRouterProfiles();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Openwalla Router Profiles',
        fileName: 'openwalla-router-profiles.json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: utf8.encode(json),
      );
      if (path != null) _message('Router profiles exported.');
    } catch (error) {
      _message('Unable to export profiles: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteRouter(model.Router router) async {
    final name = router.lastKnownHostname?.isNotEmpty == true
        ? router.lastKnownHostname!
        : router.ipAddress;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete saved router?'),
        content: Text('Remove $name from this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(appStateProvider).removeSavedRouterProfile(router.id);
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final routers = appState.routers;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: LuciAppBar(
        title: 'Manage Routers',
        showBack: true,
        actions: [
          IconButton(
            tooltip: 'Import JSON',
            onPressed: _busy ? null : _importProfiles,
            icon: const Icon(Icons.file_download_outlined),
          ),
          IconButton(
            tooltip: 'Export JSON',
            onPressed: _busy || routers.isEmpty ? null : _exportProfiles,
            icon: const Icon(Icons.file_upload_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: routers.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(28),
                children: [
                  const SizedBox(height: 64),
                  Icon(
                    Icons.router_outlined,
                    size: 58,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No Saved Routers',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Import an Openwalla JSON backup or return to login to add a router.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 22),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _importProfiles,
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('Import JSON'),
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                itemCount: routers.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  if (index == routers.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _busy ? null : _importProfiles,
                              icon: const Icon(Icons.file_download_outlined),
                              label: const Text('Import JSON'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _busy ? null : _exportProfiles,
                              icon: const Icon(Icons.file_upload_outlined),
                              label: const Text('Export JSON'),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  final router = routers[index];
                  final title = router.lastKnownHostname?.isNotEmpty == true
                      ? router.lastKnownHostname!
                      : router.ipAddress;
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(router),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: colors.primary.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.router_rounded,
                                color: colors.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w900),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${router.useHttps ? 'HTTPS' : 'HTTP'} | ${router.username} | ${router.ipAddress}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Delete router',
                              onPressed: _busy
                                  ? null
                                  : () => _deleteRouter(router),
                              icon: Icon(
                                Icons.delete_outline_rounded,
                                color: colors.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
