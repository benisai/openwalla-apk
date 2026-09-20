import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/models/router.dart';
import 'package:luci_mobile/services/router_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'router profiles retain custom ports and credentials through JSON',
    () async {
      final source = RouterService();
      await source.addRouter(
        Router(
          id: 'router-1',
          ipAddress: 'router.example:8443',
          username: 'root',
          password: 'secret',
          useHttps: true,
          lastKnownHostname: 'OpenWrt Lab',
        ),
      );

      final exported = source.exportRoutersAsJson();
      final decoded = jsonDecode(exported) as Map<String, dynamic>;
      expect(decoded['app'], 'Openwalla');
      expect(decoded['profiles'], hasLength(1));

      FlutterSecureStorage.setMockInitialValues({});
      final restored = RouterService();
      final result = await restored.importRoutersFromJson(exported);

      expect(result.success, isTrue);
      expect(result.importedCount, 1);
      expect(restored.routers.single.ipAddress, 'router.example:8443');
      expect(restored.routers.single.useHttps, isTrue);
      expect(restored.routers.single.password, 'secret');
      expect(restored.routers.single.lastKnownHostname, 'OpenWrt Lab');
    },
  );

  test('router profile import rejects unrelated JSON', () async {
    final service = RouterService();
    final result = await service.importRoutersFromJson('{"hello":"world"}');

    expect(result.success, isFalse);
    expect(result.errorMessage, contains('Expected'));
  });
}
