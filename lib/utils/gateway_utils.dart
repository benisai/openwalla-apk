import 'dart:io';

class GatewayUtils {
  const GatewayUtils._();

  static Future<String?> detectGatewayIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        if (!_isLocalNetworkInterface(interface.name)) continue;
        for (final address in interface.addresses) {
          final gateway = gatewayCandidate(address.address);
          if (!address.isLoopback && gateway != null) return gateway;
        }
      }
    } catch (_) {
      // Discovery is only a convenience. Login remains fully manual.
    }
    return null;
  }

  static String? gatewayCandidate(String localAddress) {
    final parts = localAddress.split('.');
    if (parts.length != 4) return null;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((value) => value == null || value < 0 || value > 255)) {
      return null;
    }
    return '${octets[0]}.${octets[1]}.${octets[2]}.1';
  }

  static bool _isLocalNetworkInterface(String interfaceName) {
    final name = interfaceName.toLowerCase();
    if (name.startsWith('rmnet') ||
        name.startsWith('ccmni') ||
        name.startsWith('pdp') ||
        name.startsWith('wwan') ||
        name.startsWith('cellular') ||
        name.startsWith('utun') ||
        name.startsWith('tun') ||
        name.startsWith('tap') ||
        name.startsWith('ppp')) {
      return false;
    }
    return name.contains('wlan') ||
        name.contains('wifi') ||
        name.startsWith('wl') ||
        name.startsWith('eth') ||
        name == 'en0' ||
        name == 'en1' ||
        name.startsWith('lan');
  }
}
