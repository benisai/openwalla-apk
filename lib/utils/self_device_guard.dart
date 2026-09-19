import 'dart:io';

import 'package:flutter/material.dart';

class SelfDeviceGuard {
  static Future<bool> checkSelfActionGuardrail(
    BuildContext context, {
    required String actionName,
    String? targetMac,
    String? targetIp,
    String? targetHostname,
  }) async {
    if (targetIp == null || targetIp.isEmpty) return true;
    final addresses = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: true,
      );
      for (final interface in interfaces) {
        addresses.addAll(interface.addresses.map((address) => address.address));
      }
    } catch (_) {
      return true;
    }
    if (!addresses.contains(targetIp) || !context.mounted) return true;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Managing Device Warning'),
            content: Text(
              '$actionName may disconnect this device from the router. Proceed anyway?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Proceed'),
              ),
            ],
          ),
        ) ??
        false;
  }
}
