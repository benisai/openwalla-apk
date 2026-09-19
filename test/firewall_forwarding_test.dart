import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/state/app_state.dart';

void main() {
  test('parses enabled inter-zone forwarding', () {
    final forwarding = OpenwrtFirewallForwarding.fromUciSection({
      'src': 'lan',
      'dest': 'wan',
    });

    expect(forwarding.source, 'lan');
    expect(forwarding.destination, 'wan');
    expect(forwarding.enabled, isTrue);
  });

  test('honors both OpenWrt disabled representations', () {
    expect(
      OpenwrtFirewallForwarding.fromUciSection({
        'src': 'guest',
        'dest': 'wan',
        'disabled': '1',
      }).enabled,
      isFalse,
    );
    expect(
      OpenwrtFirewallForwarding.fromUciSection({
        'src': 'guest',
        'dest': 'lan',
        'enabled': '0',
      }).enabled,
      isFalse,
    );
  });
}
