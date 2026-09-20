import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/state/app_state.dart';

void main() {
  group('OpenwallaNotification', () {
    test('parses enriched notification rows', () {
      final notification = OpenwallaNotification.fromSqliteRow(
        '8|1789849887|ping-monitor|Connectivity restored|0|0|'
        'network_health|resolved|Internet connection restored|'
        'Connectivity was restored after 2m.|target=1.1.1.1',
      );

      expect(notification, isNotNull);
      expect(notification!.displayTitle, 'Internet connection restored');
      expect(
        notification.displayDetails,
        'Connectivity was restored after 2m.',
      );
      expect(notification.effectiveSeverity, 'resolved');
      expect(notification.effectiveCategory, 'network_health');
    });

    test('presents legacy ping rows with a useful title', () {
      final notification = OpenwallaNotification.fromSqliteRow(
        '4|1789849887|ping-monitor|'
        'Ping outage: target=1.1.1.1 result=outage reason=timeout|0|0',
      );

      expect(notification, isNotNull);
      expect(notification!.displayTitle, 'Internet connection lost');
      expect(notification.effectiveSeverity, 'critical');
      expect(notification.effectiveCategory, 'network_health');
    });
  });
}
