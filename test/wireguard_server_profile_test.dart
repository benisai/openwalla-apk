import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/state/app_state.dart';

void main() {
  test('server profile generates an importable WireGuard config', () {
    const profile = WireGuardServerProfile(
      section: 'owrt_wg_peer_test',
      name: 'Phone',
      address: '10.8.0.2/32',
      endpoint: 'vpn.example.com',
      dns: '10.8.0.1',
      allowedIps: '0.0.0.0/0, ::/0',
      privateKey: 'client-private-key',
      publicKey: 'client-public-key',
      serverPublicKey: 'server-public-key',
      listenPort: 51820,
    );

    expect(profile.config, contains('[Interface]'));
    expect(profile.config, contains('PrivateKey = client-private-key'));
    expect(profile.config, contains('Address = 10.8.0.2/32'));
    expect(profile.config, contains('[Peer]'));
    expect(profile.config, contains('PublicKey = server-public-key'));
    expect(profile.config, contains('Endpoint = vpn.example.com:51820'));
    expect(profile.config, contains('AllowedIPs = 0.0.0.0/0, ::/0'));
  });
}
