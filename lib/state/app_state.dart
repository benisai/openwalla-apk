import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:luci_mobile/services/secure_storage_service.dart';
import 'package:luci_mobile/services/router_service.dart';
import 'package:luci_mobile/services/ssh_service.dart';
import 'package:luci_mobile/services/throughput_service.dart';
import 'package:luci_mobile/models/client.dart';
import 'package:luci_mobile/models/router.dart' as model;
import 'package:luci_mobile/models/dashboard_preferences.dart';
import 'package:luci_mobile/services/interfaces/auth_service_interface.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/services/api_service.dart';
import 'package:luci_mobile/services/service_factory.dart';
import 'package:luci_mobile/config/app_config.dart';
import 'package:luci_mobile/utils/http_client_manager.dart';
import 'package:luci_mobile/utils/logger.dart';

const int kOpenwallaPingTimelineSampleLimit = 420;

class PingMonitorSettings {
  final String target;
  final int thresholdMs;

  const PingMonitorSettings({required this.target, required this.thresholdMs});
}

class DnsMonitorSettings {
  final String hostname;

  const DnsMonitorSettings({required this.hostname});
}

class OpenwallaServiceStatus {
  final String name;
  final String label;
  final String category;
  final bool installed;
  final bool enabled;
  final bool running;
  final String statusText;

  const OpenwallaServiceStatus({
    required this.name,
    required this.label,
    required this.category,
    required this.installed,
    required this.enabled,
    required this.running,
    required this.statusText,
  });
}

class OpenwallaStateBackupStatus {
  final bool installed;
  final String stateDir;
  final int backupTimeMinutes;
  final DateTime? lastBackupAt;
  final int fileCount;
  final String size;
  final String message;

  const OpenwallaStateBackupStatus({
    required this.installed,
    required this.stateDir,
    required this.backupTimeMinutes,
    required this.lastBackupAt,
    required this.fileCount,
    required this.size,
    this.message = '',
  });

  factory OpenwallaStateBackupStatus.notInstalled([String message = '']) {
    return OpenwallaStateBackupStatus(
      installed: false,
      stateDir: '/overlay/openwalla-state',
      backupTimeMinutes: 720,
      lastBackupAt: null,
      fileCount: 0,
      size: '0 B',
      message: message,
    );
  }
}

enum OpenwrtFeature { wireguard, adblock, sqm }

class OpenwrtFeatureStatus {
  final OpenwrtFeature feature;
  final String label;
  final bool installed;
  final DateTime checkedAt;

  const OpenwrtFeatureStatus({
    required this.feature,
    required this.label,
    required this.installed,
    required this.checkedAt,
  });
}

class OpenwallaNotification {
  final int id;
  final DateTime timestamp;
  final String app;
  final String message;
  final bool archived;
  final bool deleted;

  const OpenwallaNotification({
    required this.id,
    required this.timestamp,
    required this.app,
    required this.message,
    required this.archived,
    required this.deleted,
  });

  static OpenwallaNotification? fromSqliteRow(String line) {
    final parts = line.split('|');
    if (parts.length < 6) return null;

    final id = int.tryParse(parts[0]);
    final timestampSeconds = int.tryParse(parts[1]);
    if (id == null || id <= 0 || timestampSeconds == null) return null;

    return OpenwallaNotification(
      id: id,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        timestampSeconds * 1000,
        isUtc: true,
      ),
      app: parts[2],
      message: parts[3],
      archived: parts[4] == '1',
      deleted: parts[5] == '1',
    );
  }
}

class OpenwrtFirewallRule {
  final String section;
  final String name;
  final String source;
  final String sourceIp;
  final String destination;
  final String protocol;
  final String port;
  final String action;
  final bool enabled;

  const OpenwrtFirewallRule({
    required this.section,
    required this.name,
    required this.source,
    required this.sourceIp,
    required this.destination,
    required this.protocol,
    required this.port,
    required this.action,
    required this.enabled,
  });

  bool get isOpenwallaRule {
    final lowerName = name.toLowerCase();
    final lowerSection = section.toLowerCase();
    return lowerName.startsWith('owrt_') ||
        lowerSection.startsWith('owrt_') ||
        lowerName.contains('owrt_');
  }

  bool get isBlocked {
    final normalized = action.toUpperCase();
    return normalized == 'REJECT' || normalized == 'DROP';
  }

  factory OpenwrtFirewallRule.fromUciSection(
    String section,
    Map<dynamic, dynamic> values,
  ) {
    String read(String key, String fallback) {
      final value = values[key];
      if (value is List) {
        final joined = value.map((entry) => entry.toString()).join(', ');
        return joined.trim().isEmpty ? fallback : joined;
      }
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? fallback : text;
    }

    return OpenwrtFirewallRule(
      section: section,
      name: read('name', section),
      source: read('src', 'Any'),
      sourceIp: read('src_ip', 'Any'),
      destination: read('dest_ip', read('dest', 'Any')),
      protocol: read('proto', 'Any'),
      port: read('dest_port', 'Any'),
      action: read('target', 'DROP').toUpperCase(),
      enabled: read('enabled', '1') != '0',
    );
  }
}

class OpenwrtPortForward {
  final String section;
  final String name;
  final String source;
  final String wanPort;
  final String protocol;
  final String destinationZone;
  final String destinationIp;
  final String destinationPort;
  final bool enabled;

  const OpenwrtPortForward({
    required this.section,
    required this.name,
    required this.source,
    required this.wanPort,
    required this.protocol,
    required this.destinationZone,
    required this.destinationIp,
    required this.destinationPort,
    required this.enabled,
  });

  factory OpenwrtPortForward.fromUciSection(
    String section,
    Map<dynamic, dynamic> values,
  ) {
    String read(String key, String fallback) {
      final value = values[key];
      if (value is List) {
        final joined = value.map((entry) => entry.toString()).join(', ');
        return joined.trim().isEmpty ? fallback : joined;
      }
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? fallback : text;
    }

    final disabled = read('disabled', '0') == '1';
    final explicitlyDisabled = read('enabled', '1') == '0';

    return OpenwrtPortForward(
      section: section,
      name: read('name', section),
      source: read('src', 'wan'),
      wanPort: read('src_dport', read('src_port', 'Any')),
      protocol: read('proto', 'tcp udp'),
      destinationZone: read('dest', 'lan'),
      destinationIp: read('dest_ip', 'Any'),
      destinationPort: read('dest_port', 'Any'),
      enabled: !disabled && !explicitlyDisabled,
    );
  }
}

class OpenwrtFirewallZone {
  final String section;
  final String name;
  final String networks;
  final String input;
  final String output;
  final String forward;
  final bool masquerading;
  final bool mtuFix;

  const OpenwrtFirewallZone({
    required this.section,
    required this.name,
    required this.networks,
    required this.input,
    required this.output,
    required this.forward,
    required this.masquerading,
    required this.mtuFix,
  });

  factory OpenwrtFirewallZone.fromUciSection(
    String section,
    Map<dynamic, dynamic> values,
  ) {
    String read(String key, String fallback) {
      final value = values[key];
      if (value is List) {
        final joined = value.map((entry) => entry.toString()).join(', ');
        return joined.trim().isEmpty ? fallback : joined;
      }
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? fallback : text;
    }

    return OpenwrtFirewallZone(
      section: section,
      name: read('name', section),
      networks: read('network', 'Any'),
      input: read('input', 'REJECT').toUpperCase(),
      output: read('output', 'REJECT').toUpperCase(),
      forward: read('forward', 'REJECT').toUpperCase(),
      masquerading: read('masq', '0') == '1',
      mtuFix: read('mtu_fix', '0') == '1',
    );
  }
}

class OpenwrtWirelessNetworkConfig {
  final String section;
  final String radioSection;
  final String ssid;
  final String password;
  final String encryption;
  final bool enabled;
  final bool hidden;
  final int? txPower;

  const OpenwrtWirelessNetworkConfig({
    required this.section,
    required this.radioSection,
    required this.ssid,
    required this.password,
    required this.encryption,
    required this.enabled,
    required this.hidden,
    required this.txPower,
  });

  OpenwrtWirelessNetworkConfig copyWith({
    String? ssid,
    String? password,
    String? encryption,
    bool? enabled,
    bool? hidden,
    int? txPower,
  }) {
    return OpenwrtWirelessNetworkConfig(
      section: section,
      radioSection: radioSection,
      ssid: ssid ?? this.ssid,
      password: password ?? this.password,
      encryption: encryption ?? this.encryption,
      enabled: enabled ?? this.enabled,
      hidden: hidden ?? this.hidden,
      txPower: txPower ?? this.txPower,
    );
  }

  static OpenwrtWirelessNetworkConfig fromUciSection(
    String section,
    Map<dynamic, dynamic> values, {
    Map<dynamic, dynamic>? radioValues,
  }) {
    String read(Map<dynamic, dynamic>? source, String key, String fallback) {
      final value = source?[key];
      if (value is List) {
        final joined = value.map((entry) => entry.toString()).join(' ');
        return joined.trim().isEmpty ? fallback : joined;
      }
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? fallback : text;
    }

    final radioSection = read(values, 'device', '');
    return OpenwrtWirelessNetworkConfig(
      section: section,
      radioSection: radioSection,
      ssid: read(values, 'ssid', ''),
      password: read(values, 'key', ''),
      encryption: read(values, 'encryption', 'psk2'),
      enabled:
          read(values, 'disabled', '0') != '1' &&
          read(radioValues, 'disabled', '0') != '1',
      hidden: read(values, 'hidden', '0') == '1',
      txPower: int.tryParse(read(radioValues, 'txpower', '')),
    );
  }
}

class OpenwrtStaticRoute {
  final String section;
  final String interfaceName;
  final String routeType;
  final String target;
  final String netmask;
  final String gateway;
  final String metric;
  final bool enabled;

  const OpenwrtStaticRoute({
    required this.section,
    required this.interfaceName,
    required this.routeType,
    required this.target,
    required this.netmask,
    required this.gateway,
    required this.metric,
    required this.enabled,
  });

  factory OpenwrtStaticRoute.fromUciSection(
    String section,
    Map<dynamic, dynamic> values,
  ) {
    String read(String key, String fallback) {
      final text = values[key]?.toString().trim();
      return text == null || text.isEmpty ? fallback : text;
    }

    return OpenwrtStaticRoute(
      section: section,
      interfaceName: read('interface', 'unspecified'),
      routeType: read('type', 'unicast'),
      target: read('target', '0.0.0.0'),
      netmask: read('netmask', ''),
      gateway: read('gateway', ''),
      metric: read('metric', '0'),
      enabled: read('disabled', '0') != '1',
    );
  }
}

class OpenwrtSqmQueue {
  final String section;
  final bool enabled;
  final String interfaceName;
  final int downloadKbps;
  final int uploadKbps;
  final String qdisc;
  final String script;
  final bool debugLogging;
  final String verbosity;

  const OpenwrtSqmQueue({
    required this.section,
    required this.enabled,
    required this.interfaceName,
    required this.downloadKbps,
    required this.uploadKbps,
    required this.qdisc,
    required this.script,
    required this.debugLogging,
    required this.verbosity,
  });

  factory OpenwrtSqmQueue.fromUciSection(
    String section,
    Map<dynamic, dynamic> values,
  ) {
    String read(String key, String fallback) {
      final text = values[key]?.toString().trim();
      return text == null || text.isEmpty ? fallback : text;
    }

    return OpenwrtSqmQueue(
      section: section,
      enabled: read('enabled', '0') == '1',
      interfaceName: read('interface', 'eth1'),
      downloadKbps: int.tryParse(read('download', '0')) ?? 0,
      uploadKbps: int.tryParse(read('upload', '0')) ?? 0,
      qdisc: read('qdisc', 'cake'),
      script: read('script', 'piece_of_cake.qos'),
      debugLogging: read('debug_logging', '0') == '1',
      verbosity: read('verbosity', '5'),
    );
  }
}

class OpenwrtDnsHostEntry {
  final String section;
  final String hostname;
  final String ipAddress;

  const OpenwrtDnsHostEntry({
    required this.section,
    required this.hostname,
    required this.ipAddress,
  });

  factory OpenwrtDnsHostEntry.fromUciSection(
    String section,
    Map<dynamic, dynamic> values,
  ) {
    String read(String key) => values[key]?.toString().trim() ?? '';

    return OpenwrtDnsHostEntry(
      section: section,
      hostname: read('name'),
      ipAddress: read('ip'),
    );
  }

  bool get isBlockedSinkhole => ipAddress.trim() == '127.0.0.1';
}

class OpenwrtAdblockSettings {
  final String section;
  final bool installed;
  final bool enabled;
  final bool safeSearch;
  final bool reportEnabled;
  final String triggerInterface;
  final String dnsBackend;
  final List<String> selectedFeeds;
  final String serviceStatus;

  const OpenwrtAdblockSettings({
    required this.section,
    required this.installed,
    required this.enabled,
    required this.safeSearch,
    required this.reportEnabled,
    required this.triggerInterface,
    required this.dnsBackend,
    required this.selectedFeeds,
    required this.serviceStatus,
  });

  OpenwrtAdblockSettings copyWith({
    String? section,
    bool? installed,
    bool? enabled,
    bool? safeSearch,
    bool? reportEnabled,
    String? triggerInterface,
    String? dnsBackend,
    List<String>? selectedFeeds,
    String? serviceStatus,
  }) {
    return OpenwrtAdblockSettings(
      section: section ?? this.section,
      installed: installed ?? this.installed,
      enabled: enabled ?? this.enabled,
      safeSearch: safeSearch ?? this.safeSearch,
      reportEnabled: reportEnabled ?? this.reportEnabled,
      triggerInterface: triggerInterface ?? this.triggerInterface,
      dnsBackend: dnsBackend ?? this.dnsBackend,
      selectedFeeds: selectedFeeds ?? this.selectedFeeds,
      serviceStatus: serviceStatus ?? this.serviceStatus,
    );
  }

  factory OpenwrtAdblockSettings.fromUciSection(
    String section,
    Map<dynamic, dynamic> values, {
    required bool installed,
    required String serviceStatus,
  }) {
    String read(String key, String fallback) {
      final value = values[key];
      if (value is List) {
        final joined = value.map((entry) => entry.toString()).join(' ');
        return joined.trim().isEmpty ? fallback : joined;
      }
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? fallback : text;
    }

    bool boolValue(String key, bool fallback) {
      final value = read(key, fallback ? '1' : '0').toLowerCase();
      return value == '1' || value == 'true' || value == 'yes';
    }

    List<String> readList(String key) {
      final value = values[key];
      if (value is List) {
        return value
            .map((entry) => entry.toString().trim())
            .where((entry) => entry.isNotEmpty)
            .toList();
      }
      final text = value?.toString().trim() ?? '';
      return text.isEmpty
          ? const []
          : text
                .split(RegExp(r'\s+'))
                .where((entry) => entry.isNotEmpty)
                .toList();
    }

    return OpenwrtAdblockSettings(
      section: section,
      installed: installed,
      enabled: boolValue('adb_enabled', false),
      safeSearch: boolValue('adb_safesearch', false),
      reportEnabled: boolValue('adb_report', false),
      triggerInterface: read('adb_trigger', 'wan'),
      dnsBackend: read('adb_dns', 'dnsmasq'),
      selectedFeeds: readList('adb_feed'),
      serviceStatus: serviceStatus,
    );
  }
}

class OpenwrtNetworkInterfaceConfig {
  final String section;
  final String interfaceName;
  final String protocol;
  final String ipAddress;
  final String netmask;
  final List<String> dnsServers;
  final String? dhcpSection;
  final bool dhcpEnabled;
  final int dhcpStart;
  final int dhcpLimit;
  final String leaseTime;

  const OpenwrtNetworkInterfaceConfig({
    required this.section,
    required this.interfaceName,
    required this.protocol,
    required this.ipAddress,
    required this.netmask,
    required this.dnsServers,
    required this.dhcpSection,
    required this.dhcpEnabled,
    required this.dhcpStart,
    required this.dhcpLimit,
    required this.leaseTime,
  });

  String get dnsText => dnsServers.join(' ');

  OpenwrtNetworkInterfaceConfig copyWith({
    String? protocol,
    String? ipAddress,
    String? netmask,
    List<String>? dnsServers,
    String? dhcpSection,
    bool? dhcpEnabled,
    int? dhcpStart,
    int? dhcpLimit,
    String? leaseTime,
  }) {
    return OpenwrtNetworkInterfaceConfig(
      section: section,
      interfaceName: interfaceName,
      protocol: protocol ?? this.protocol,
      ipAddress: ipAddress ?? this.ipAddress,
      netmask: netmask ?? this.netmask,
      dnsServers: dnsServers ?? this.dnsServers,
      dhcpSection: dhcpSection ?? this.dhcpSection,
      dhcpEnabled: dhcpEnabled ?? this.dhcpEnabled,
      dhcpStart: dhcpStart ?? this.dhcpStart,
      dhcpLimit: dhcpLimit ?? this.dhcpLimit,
      leaseTime: leaseTime ?? this.leaseTime,
    );
  }
}

class PingMonitorSample {
  final DateTime timestamp;
  final String target;
  final String status;
  final double? latencyMs;
  final String message;

  const PingMonitorSample({
    required this.timestamp,
    required this.target,
    required this.status,
    required this.latencyMs,
    required this.message,
  });

  bool get isOk => status.toUpperCase() == 'OK' && latencyMs != null;

  static PingMonitorSample? fromLine(String line) {
    final parts = line.split('|');
    if (parts.length < 5) return null;

    final timestamp = DateTime.tryParse(parts[0]);
    if (timestamp == null) return null;

    final latencyText = parts[3];
    return PingMonitorSample(
      timestamp: timestamp,
      target: parts[1],
      status: parts[2],
      latencyMs: latencyText == 'N/A' ? null : double.tryParse(latencyText),
      message: parts.sublist(4).join('|'),
    );
  }
}

class SpeedtestMonitorSample {
  final DateTime timestamp;
  final String status;
  final double? downloadMbps;
  final double? uploadMbps;
  final String server;
  final String message;

  const SpeedtestMonitorSample({
    required this.timestamp,
    required this.status,
    required this.downloadMbps,
    required this.uploadMbps,
    required this.server,
    required this.message,
  });

  bool get isOk =>
      status.toUpperCase() == 'OK' &&
      downloadMbps != null &&
      uploadMbps != null;

  static SpeedtestMonitorSample? fromLine(String line) {
    final parts = line.split('|');
    if (parts.length < 6) return null;

    final timestamp = DateTime.tryParse(parts[0]);
    if (timestamp == null) return null;

    final downloadText = parts[2];
    final uploadText = parts[3];
    return SpeedtestMonitorSample(
      timestamp: timestamp,
      status: parts[1],
      downloadMbps: downloadText == 'N/A'
          ? null
          : double.tryParse(downloadText),
      uploadMbps: uploadText == 'N/A' ? null : double.tryParse(uploadText),
      server: parts[4],
      message: parts.sublist(5).join('|'),
    );
  }
}

class SpeedtestMonitorSettings {
  final bool enabled;
  final DateTime? runDate;
  final int runHour;
  final int runMinute;

  const SpeedtestMonitorSettings({
    required this.enabled,
    required this.runDate,
    required this.runHour,
    required this.runMinute,
  });
}

class MonthlyUsageSettings {
  final int monthStartDay;
  final String interfaceName;
  final int monthlyLimitGb;

  const MonthlyUsageSettings({
    required this.monthStartDay,
    required this.interfaceName,
    this.monthlyLimitGb = 0,
  });
}

class VnstatUsageSample {
  final DateTime timestamp;
  final int downloadBytes;
  final int uploadBytes;

  const VnstatUsageSample({
    required this.timestamp,
    required this.downloadBytes,
    required this.uploadBytes,
  });
}

class NlbwDeviceUsage {
  final String mac;
  final String label;
  final int downloadBytes;
  final int uploadBytes;

  const NlbwDeviceUsage({
    required this.mac,
    required this.label,
    required this.downloadBytes,
    required this.uploadBytes,
  });

  int get totalBytes => downloadBytes + uploadBytes;
}

class NlbwProtocolUsage {
  final String protocol;
  final int downloadBytes;
  final int uploadBytes;

  const NlbwProtocolUsage({
    required this.protocol,
    required this.downloadBytes,
    required this.uploadBytes,
  });

  int get totalBytes => downloadBytes + uploadBytes;
}

class StatisticsPreloadData {
  final bool hasSupport;
  final MonthlyUsageSettings settings;
  final String interfaceName;
  final Map<String, List<VnstatUsageSample>> usageSamples;
  final List<NlbwDeviceUsage> topDevices;
  final List<NlbwProtocolUsage> protocolUsage;

  const StatisticsPreloadData({
    required this.hasSupport,
    required this.settings,
    required this.interfaceName,
    required this.usageSamples,
    required this.topDevices,
    required this.protocolUsage,
  });

  List<VnstatUsageSample>? samplesFor(String key) => usageSamples[key];
}

class LiveDeviceTrafficCounter {
  final String ip;
  final String mac;
  final int downloadBytes;
  final int uploadBytes;

  const LiveDeviceTrafficCounter({
    required this.ip,
    required this.mac,
    required this.downloadBytes,
    required this.uploadBytes,
  });
}

class OpenwallaDeviceRecord {
  final String mac;
  final String ip;
  final String hostname;
  final int totalUploadBytes;
  final int totalDownloadBytes;
  final String staticIpAddress;
  final String status;
  final bool quarantined;
  final String icon;
  final bool scheduledBlock;
  final String scheduleUntil;

  const OpenwallaDeviceRecord({
    required this.mac,
    required this.ip,
    required this.hostname,
    required this.totalUploadBytes,
    required this.totalDownloadBytes,
    required this.staticIpAddress,
    this.status = '',
    this.quarantined = false,
    this.icon = '',
    this.scheduledBlock = false,
    this.scheduleUntil = '',
  });
}

class OpenwallaDeviceSchedule {
  final int id;
  final String name;
  final String startTime;
  final String endTime;
  final bool enabled;
  final List<String> macAddresses;
  final int pauseUntil;

  const OpenwallaDeviceSchedule({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.enabled,
    required this.macAddresses,
    this.pauseUntil = 0,
  });

  bool get isNew => id <= 0;

  bool get isPaused {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return pauseUntil > now;
  }
}

class OpenwallaActiveSchedule {
  final String name;
  final String endTime;

  const OpenwallaActiveSchedule({required this.name, required this.endTime});
}

class WireGuardServerSettings {
  final bool installed;
  final bool configured;
  final bool enabled;
  final String interfaceName;
  final int listenPort;
  final String vpnAddress;
  final String internalIpAddress;
  final String publicKey;

  const WireGuardServerSettings({
    required this.installed,
    required this.configured,
    required this.enabled,
    required this.interfaceName,
    required this.listenPort,
    required this.vpnAddress,
    required this.internalIpAddress,
    required this.publicKey,
  });

  static const defaults = WireGuardServerSettings(
    installed: false,
    configured: false,
    enabled: true,
    interfaceName: 'owrt_wg_server',
    listenPort: 51820,
    vpnAddress: '10.8.0.1/24',
    internalIpAddress: '',
    publicKey: '',
  );
}

class WireGuardClientSettings {
  final bool installed;
  final bool configured;
  final bool enabled;
  final String interfaceName;
  final String address;
  final String dns;
  final String privateKey;
  final String peerPublicKey;
  final String presharedKey;
  final String endpointHost;
  final int endpointPort;
  final String allowedIps;
  final int persistentKeepalive;
  final bool routeAllowedIps;

  const WireGuardClientSettings({
    required this.installed,
    required this.configured,
    required this.enabled,
    required this.interfaceName,
    required this.address,
    required this.dns,
    required this.privateKey,
    required this.peerPublicKey,
    required this.presharedKey,
    required this.endpointHost,
    required this.endpointPort,
    required this.allowedIps,
    required this.persistentKeepalive,
    required this.routeAllowedIps,
  });

  static const defaults = WireGuardClientSettings(
    installed: false,
    configured: false,
    enabled: false,
    interfaceName: 'owrt_wg_client',
    address: '',
    dns: '',
    privateKey: '',
    peerPublicKey: '',
    presharedKey: '',
    endpointHost: '',
    endpointPort: 51820,
    allowedIps: '0.0.0.0/0, ::/0',
    persistentKeepalive: 25,
    routeAllowedIps: true,
  );
}

class SystemStorageDetails {
  final int userTotalBytes;
  final int userFreeBytes;
  final int tempTotalBytes;
  final int tempFreeBytes;

  const SystemStorageDetails({
    required this.userTotalBytes,
    required this.userFreeBytes,
    required this.tempTotalBytes,
    required this.tempFreeBytes,
  });

  static const empty = SystemStorageDetails(
    userTotalBytes: 0,
    userFreeBytes: 0,
    tempTotalBytes: 0,
    tempFreeBytes: 0,
  );
}

enum OpenwallaFlowProvider { none, netify, conntrack }

class OpenwallaFlowSummary {
  final OpenwallaFlowProvider provider;
  final int count;

  const OpenwallaFlowSummary({required this.provider, required this.count});

  static const none = OpenwallaFlowSummary(
    provider: OpenwallaFlowProvider.none,
    count: 0,
  );

  bool get isAvailable => provider != OpenwallaFlowProvider.none;
}

class NetifyFlow {
  final DateTime timestamp;
  final String deviceMac;
  final String localIp;
  final String localPort;
  final String destination;
  final String application;
  final String protocol;
  final String destinationIp;
  final String destinationPort;
  final String interfaceName;
  final int downloadedBytes;
  final int uploadedBytes;
  final int totalBytes;
  final String countryCode;
  final String region;
  final String direction;
  final String rawJson;

  const NetifyFlow({
    required this.timestamp,
    required this.deviceMac,
    required this.localIp,
    required this.localPort,
    required this.destination,
    required this.application,
    required this.protocol,
    required this.destinationIp,
    required this.destinationPort,
    required this.interfaceName,
    required this.downloadedBytes,
    required this.uploadedBytes,
    required this.totalBytes,
    required this.countryCode,
    required this.region,
    required this.direction,
    required this.rawJson,
  });

  static NetifyFlow? fromJsonLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return null;
      final decodedType = decoded['type']?.toString().toLowerCase();
      final nestedFlow = decoded['flow'];
      if (decodedType != 'flow' && nestedFlow is! Map) return null;
      final flow = nestedFlow is Map ? nestedFlow : decoded;

      final timestamp = _parseNetifyTimestamp(
        flow['last_seen_at'] ?? flow['first_seen_at'] ?? decoded['timeinsert'],
      );
      final sni = _firstString([
        _nestedString(flow, ['ssl', 'client_sni']),
        flow['client_sni'],
        _nestedString(flow, ['tls', 'client_sni']),
        flow['tls_client_sni'],
      ]);
      final destination = _firstString([
        sni,
        flow['host_server_name'],
        flow['server_name'],
        flow['fqdn'],
        flow['dns_host_name'],
        flow['host'],
        flow['hostname'],
        flow['other_ip'],
        flow['remote_ip'],
        'Unknown',
      ]);
      final application = _firstString([
        flow['detected_application_name'],
        flow['detected_app_name'],
        flow['application_name'],
        flow['app_name'],
        destination,
      ]);
      final destinationIp = _firstString([
        flow['other_ip'],
        flow['remote_ip'],
        flow['dst_ip'],
        flow['dest_ip'],
        '-',
      ]);
      final downloaded = _firstInt([
        flow['other_bytes'],
        flow['download_bytes'],
        flow['server_bytes'],
        flow['dst_bytes'],
        flow['dest_bytes'],
      ]);
      final uploaded = _firstInt([
        flow['local_bytes'],
        flow['upload_bytes'],
        flow['client_bytes'],
        flow['src_bytes'],
      ]);
      final total = _firstInt([flow['total_bytes'], downloaded + uploaded]);

      return NetifyFlow(
        timestamp: timestamp,
        deviceMac: _normalizeMac(
          _firstString([
            flow['local_mac'],
            flow['src_mac'],
            flow['client_mac'],
          ]),
        ),
        localIp: _firstString([flow['local_ip'], flow['src_ip'], '-']),
        localPort: _firstString([flow['local_port'], flow['src_port'], '']),
        destination: destination.isNotEmpty ? destination : destinationIp,
        application: application,
        protocol: _firstString([
          flow['detected_protocol_name'],
          flow['protocol_name'],
          flow['protocol'],
          'N/A',
        ]),
        destinationIp: destinationIp,
        destinationPort: _firstString([
          flow['other_port'],
          flow['remote_port'],
          flow['dst_port'],
          flow['dest_port'],
          '0',
        ]),
        interfaceName: _firstString([
          decoded['interface'],
          flow['interface'],
          flow['local_interface'],
          '-',
        ]),
        downloadedBytes: downloaded,
        uploadedBytes: uploaded,
        totalBytes: total,
        countryCode: _firstString([
          flow['other_country_code'],
          flow['country_code'],
          flow['country'],
          '',
        ]).toUpperCase(),
        region: _firstString([
          flow['other_country_name'],
          flow['country_name'],
          flow['region'],
          '',
        ]),
        direction: _firstString([flow['direction'], 'Outbound']),
        rawJson: line,
      );
    } catch (_) {
      return null;
    }
  }

  static NetifyFlow? fromConnectionFlowRow(String line) {
    final parts = line.split('|');
    if (parts.length < 7) return null;

    final timestampSeconds = int.tryParse(parts[1]);
    final timestamp = timestampSeconds == null
        ? DateTime.now().toUtc()
        : DateTime.fromMillisecondsSinceEpoch(
            timestampSeconds * 1000,
            isUtc: true,
          );
    final source = parts[3].trim();
    final destination = parts[4].trim();
    final destinationParts = _splitEndpoint(destination);
    final transferBytes = _parseTransferBytes(parts[5]);

    return NetifyFlow(
      timestamp: timestamp,
      deviceMac: '',
      localIp: source.isEmpty ? '-' : source,
      localPort: '',
      destination: destinationParts.$1.isEmpty ? '-' : destinationParts.$1,
      application: destinationParts.$1.isEmpty ? '-' : destinationParts.$1,
      protocol: parts[2].trim().isEmpty ? 'N/A' : parts[2].trim(),
      destinationIp: destinationParts.$1.isEmpty ? '-' : destinationParts.$1,
      destinationPort: destinationParts.$2,
      interfaceName: '-',
      downloadedBytes: transferBytes,
      uploadedBytes: 0,
      totalBytes: transferBytes,
      countryCode: '',
      region: '',
      direction: 'Outbound',
      rawJson: line,
    );
  }

  static DateTime _parseNetifyTimestamp(dynamic value) {
    final numeric = value is num ? value.toDouble() : double.tryParse('$value');
    if (numeric != null && numeric > 0) {
      final milliseconds = numeric > 1000000000000
          ? numeric.round()
          : (numeric * 1000).round();
      return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    }
    return DateTime.now().toUtc();
  }

  static dynamic _nestedString(Map flow, List<String> path) {
    dynamic current = flow;
    for (final key in path) {
      if (current is! Map) return null;
      current = current[key];
    }
    return current;
  }

  static String _firstString(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static int _firstInt(List<dynamic> values) {
    for (final value in values) {
      final parsed = value is num ? value.round() : int.tryParse('$value');
      if (parsed != null && parsed >= 0) return parsed;
    }
    return 0;
  }

  static (String, String) _splitEndpoint(String endpoint) {
    final trimmed = endpoint.trim();
    final match = RegExp(
      r'^((?:\d{1,3}\.){3}\d{1,3}):(\d+)$',
    ).firstMatch(trimmed);
    if (match == null) return (trimmed, '');
    return (match.group(1) ?? trimmed, match.group(2) ?? '');
  }

  static int _parseTransferBytes(String transfer) {
    final match = RegExp(r'^(\d+)').firstMatch(transfer.trim());
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  static String _normalizeMac(dynamic value) {
    if (value is List) {
      for (final entry in value) {
        final parsed = _normalizeMac(entry);
        if (parsed.isNotEmpty) return parsed;
      }
      return '';
    }
    final text = value?.toString().trim().toUpperCase() ?? '';
    if (text.isEmpty) return '';
    return text.split(RegExp(r'[\s,]+')).first.replaceAll('-', ':');
  }
}

class AppState extends ChangeNotifier {
  static AppState? _instance;
  late final Future<void> _initializationFuture;
  static const String _openwrtShellPath =
      r'PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH; ';
  static const String _wireGuardBinaryLookup =
      r'WG_BIN="$(command -v wg 2>/dev/null || true)"; '
      r'[ -x /usr/bin/wg ] && WG_BIN="/usr/bin/wg"; '
      r'[ -x /usr/sbin/wg ] && WG_BIN="/usr/sbin/wg"; '
      r'[ -x /sbin/wg ] && WG_BIN="/sbin/wg"; '
      r'[ -x /bin/wg ] && WG_BIN="/bin/wg"; ';

  String _withWireGuardBinaryLookup(String command) {
    return '$_openwrtShellPath$_wireGuardBinaryLookup$command';
  }

  static const List<({String name, String label, String category})>
  _managedServices = [
    (
      name: 'openwalla-ping-monitor',
      label: 'Ping Monitor',
      category: 'Openwalla',
    ),
    (
      name: 'openwalla-dns-monitor',
      label: 'DNS Monitor',
      category: 'Openwalla',
    ),
    (
      name: 'openwalla-devices-collector',
      label: 'Devices Collector',
      category: 'Openwalla',
    ),
    (
      name: 'openwalla-device-bandwidth-collector',
      label: 'Bandwidth Collector',
      category: 'Openwalla',
    ),
    (
      name: 'openwalla-connection-flows-collector',
      label: 'Simple Flow Collector',
      category: 'Openwalla',
    ),
    (
      name: 'openwalla-netify-collector',
      label: 'Detailed Flow Collector',
      category: 'Openwalla',
    ),
    (
      name: 'openwalla-device-quarantine',
      label: 'Device Quarantine',
      category: 'Openwalla',
    ),
    (name: 'openwalla-state-sync', label: 'State Sync', category: 'Openwalla'),
    (name: 'netifyd', label: 'Netify', category: 'Router'),
    (name: 'vnstat', label: 'vnStat', category: 'Router'),
    (name: 'nlbwmon', label: 'nlbwmon', category: 'Router'),
    (name: 'adblock', label: 'AdBlock', category: 'Router'),
    (name: 'sqm', label: 'Smart Queue', category: 'Router'),
  ];

  late final SecureStorageService _secureStorageService;
  IApiService? _apiService;
  IAuthService? _authService;
  RouterService? _routerService;
  ThroughputService? _throughputService;
  final HttpClientManager _httpClientManager = HttpClientManager();

  // Reviewer mode state
  bool _reviewerModeEnabled = false;
  bool get reviewerModeEnabled => _reviewerModeEnabled;

  bool _isLoading = false;
  String? _errorMessage;

  Map<String, dynamic>? _dashboardData;
  bool _isDashboardLoading = false;
  String? _dashboardError;

  Timer? _throughputTimer;
  Timer? _systemInfoTimer;
  Timer? _pollingTimer;
  int? _lastCpuTotalTicks;
  int? _lastCpuIdleTicks;
  double? _lastCpuUsagePercent;
  int _lastCpuCoreCount = 1;
  int _pollAttempts = 0;
  static const int _maxPollAttempts =
      40; // Max 40 attempts = ~5 minutes with backoff

  // Add rebooting state
  bool _isRebooting = false;
  bool get isRebooting => _isRebooting;

  // Theme mode state
  ThemeMode _themeMode = ThemeMode.system;
  static const String _themeModeKey = 'themeMode';

  // Clients view mode (selected router only by default for fast page loads)
  bool _clientsAggregateAllRouters = false;
  static const String _clientsAggregateKey = 'clients_aggregate_all';
  bool get clientsAggregateAllRouters => _clientsAggregateAllRouters;

  // Dashboard preferences state
  DashboardPreferences _dashboardPreferences = DashboardPreferences();
  DashboardPreferences get dashboardPreferences => _dashboardPreferences;
  StatisticsPreloadData? _statisticsPreloadData;
  Future<StatisticsPreloadData>? _statisticsPreloadFuture;
  StatisticsPreloadData? get statisticsPreloadData => _statisticsPreloadData;

  List<model.Router> get routers => _routerService?.routers ?? [];
  model.Router? get selectedRouter => _routerService?.selectedRouter;

  VoidCallback? onRouterBackOnline;

  // Add requestedTab for programmatic tab switching
  int? requestedTab;
  String? requestedInterfaceToScroll;

  void requestTab(int index, {String? interfaceToScroll}) {
    requestedTab = index;
    requestedInterfaceToScroll = interfaceToScroll;
    notifyListeners();
  }

  AppState._() {
    _initializationFuture = _initialize();
  }

  Future<void> get initialized => _initializationFuture;

  static AppState get instance {
    return _instance ??= AppState._();
  }

  Future<void> _initialize() async {
    await _loadReviewerMode();
    _initializeServices();
    await _loadThemeMode();
    await loadRouters(); // Load routers on app start (sets selectedRouter)
    await _migrateGlobalDashboardPreferencesIfNeeded(); // Proactively migrate legacy prefs
    await _loadClientsViewMode();
    await loadDashboardPreferences(); // Load prefs scoped to selected router
  }

  /// One-time migration: if a global 'dashboard_preferences' exists,
  /// copy it to each router-specific key that doesn't already have prefs.
  Future<void> _migrateGlobalDashboardPreferencesIfNeeded() async {
    try {
      final globalKey = 'dashboard_preferences';
      final globalJson = await _secureStorageService.readValue(globalKey);
      if (globalJson == null || globalJson.isEmpty) return;

      final routers = _routerService?.routers ?? const <model.Router>[];
      if (routers.isEmpty) return;

      // Validate JSON format before writing
      try {
        jsonDecode(globalJson);
      } catch (_) {
        return; // Not valid JSON; skip migration
      }

      for (final router in routers) {
        final key = 'dashboard_preferences:${router.id}';
        final existing = await _secureStorageService.readValue(key);
        if (existing == null || existing.isEmpty) {
          await _secureStorageService.writeValue(key, globalJson);
        }
      }

      // If all routers now have scoped prefs, remove the legacy global key
      var allHavePrefs = true;
      for (final router in routers) {
        final key = 'dashboard_preferences:${router.id}';
        final v = await _secureStorageService.readValue(key);
        if (v == null || v.isEmpty) {
          allHavePrefs = false;
          break;
        }
      }
      if (allHavePrefs) {
        await _secureStorageService.deleteValue(globalKey);
      }
    } catch (e, stack) {
      Logger.exception(
        'Failed migrating global dashboard preferences',
        e,
        stack,
      );
    }
  }

  Future<void> _loadReviewerMode() async {
    // Initialize secure storage service with default factory first
    ServiceContainer.configure(reviewerMode: false);
    _secureStorageService = ServiceContainer.instance.factory
        .createSecureStorageService();

    final stored = await _secureStorageService.readValue(
      AppConfig.reviewerModeKey,
    );
    _reviewerModeEnabled = stored == 'true';
  }

  void _initializeServices() {
    // Configure the service container based on reviewer mode
    ServiceContainer.configure(reviewerMode: _reviewerModeEnabled);

    // Create services using the factory
    final factory = ServiceContainer.instance.factory;
    _authService = factory.createAuthService();
    _apiService = factory.createApiService();
    _routerService = factory.createRouterService();
    _throughputService = factory.createThroughputService();
  }

  Future<void> setReviewerMode(bool enabled) async {
    _reviewerModeEnabled = enabled;
    await _secureStorageService.writeValue(
      AppConfig.reviewerModeKey,
      enabled.toString(),
    );
    _initializeServices();
    notifyListeners();
  }

  Future<void> _loadThemeMode() async {
    final stored = await _secureStorageService.readValue(_themeModeKey);
    if (stored == 'dark') {
      _themeMode = ThemeMode.dark;
    } else if (stored == 'light') {
      _themeMode = ThemeMode.light;
    } else if (stored == 'system') {
      _themeMode = ThemeMode.system;
    }
    notifyListeners();
  }

  ThemeMode get themeMode => _themeMode;
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _secureStorageService.writeValue(_themeModeKey, mode.name);
    notifyListeners();
  }

  Future<void> _loadClientsViewMode() async {
    final stored = await _secureStorageService.readValue(_clientsAggregateKey);
    if (stored == 'true') {
      await _secureStorageService.writeValue(_clientsAggregateKey, 'false');
    }
    _clientsAggregateAllRouters = false;
  }

  Future<void> setClientsAggregateAllRouters(bool aggregate) async {
    _clientsAggregateAllRouters = aggregate;
    await _secureStorageService.writeValue(
      _clientsAggregateKey,
      aggregate.toString(),
    );
    notifyListeners();
  }

  Future<void> loadDashboardPreferences() async {
    try {
      // Scope preferences by selected router if available
      final routerId = _routerService?.selectedRouter?.id;
      final key = routerId != null
          ? 'dashboard_preferences:$routerId'
          : 'dashboard_preferences';

      // Try router-specific key first
      String? json = await _secureStorageService.readValue(key);
      // Backward-compat: if missing, fall back to global key
      if ((json == null || json.isEmpty) && routerId != null) {
        json = await _secureStorageService.readValue('dashboard_preferences');
      }
      if (json != null && json.isNotEmpty) {
        _dashboardPreferences = DashboardPreferences.fromJson(jsonDecode(json));
        notifyListeners();
      }
    } catch (e, stack) {
      Logger.exception('Failed to load dashboard preferences', e, stack);
      _dashboardPreferences = DashboardPreferences();
    }
  }

  Future<void> saveDashboardPreferences(DashboardPreferences prefs) async {
    try {
      final previousRefreshSeconds =
          _dashboardPreferences.liveThroughputRefreshSeconds;
      _dashboardPreferences = prefs;
      clearStatisticsPreload();
      final routerId = _routerService?.selectedRouter?.id;
      final key = routerId != null
          ? 'dashboard_preferences:$routerId'
          : 'dashboard_preferences';
      await _secureStorageService.writeValue(key, jsonEncode(prefs.toJson()));
      if (previousRefreshSeconds != prefs.liveThroughputRefreshSeconds &&
          _throughputTimer != null) {
        _startThroughputTimer();
      }
      notifyListeners();
    } catch (e, stack) {
      Logger.exception('Failed to save dashboard preferences', e, stack);
      rethrow;
    }
  }

  void clearStatisticsPreload() {
    _statisticsPreloadData = null;
    _statisticsPreloadFuture = null;
  }

  Future<String> runRouterSetupCommand(
    String command, {
    BuildContext? context,
  }) async {
    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    final result = await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command: command,
      context: context,
    );
    return _commandOutput(result);
  }

  Future<String> runRouterSetupCommandViaSsh(
    String command, {
    void Function(String chunk)? onOutput,
  }) async {
    final router = _routerService?.selectedRouter;
    if (router == null) {
      throw StateError('No selected router connection is available');
    }
    if (router.username.trim().isEmpty || router.password.isEmpty) {
      throw StateError('Saved router SSH credentials are missing');
    }

    if (_reviewerModeEnabled) {
      const output =
          'Connecting with saved router credentials...\n'
          'Installing selected Openwalla setup components...\n'
          'Setup finished.';
      onOutput?.call(output);
      return output;
    }

    final result = await SshService().runCommand(
      host: router.ipAddress,
      username: router.username,
      password: router.password,
      command: command,
      onOutput: onOutput,
    );
    final output = result.output.trimRight();
    final setupCompleted = output.contains('[openwalla-setup] Setup complete.');
    if (result.exitCode != null && result.exitCode != 0) {
      if (setupCompleted) {
        return '$output\n\nOpenwalla setup completed. The router reported SSH exit code ${result.exitCode} after completion, which can happen on some OpenWrt service restarts.';
      }
      throw StateError(
        'Router setup command exited with code ${result.exitCode}.\n\n$output',
      );
    }
    return output;
  }

  String _buildOpenwallaSetupCommand(
    List<String> features, {
    String? postInstallCheck,
  }) {
    final featureArgs = features.where((feature) => feature.trim().isNotEmpty);
    final commandParts = [
      'export OPENWALLA_RAW_BASE=https://raw.githubusercontent.com/benisai/openwalla-apk/main/openwrt-setup',
      'export OPENWALLA_ROOT=/tmp/openwalla-app-setup',
      'fetch() { if command -v wget >/dev/null 2>&1; then wget -qO "\$2" "\$1"; else curl -fsSL "\$1" -o "\$2"; fi; }',
      'cd /tmp',
      'rm -rf "\$OPENWALLA_ROOT"',
      'rm -f setup-openwrt-router.sh',
      'fetch "\$OPENWALLA_RAW_BASE/setup-openwrt-router.sh" "setup-openwrt-router.sh"',
      'chmod 0755 setup-openwrt-router.sh',
      'sh ./setup-openwrt-router.sh ${featureArgs.join(' ')}',
      if (postInstallCheck != null && postInstallCheck.trim().isNotEmpty)
        postInstallCheck,
    ];
    return commandParts.join(' && ');
  }

  Future<String> installOpenwallaSetupFeatures(
    List<String> features, {
    String? postInstallCheck,
    void Function(String chunk)? onOutput,
  }) async {
    if (_reviewerModeEnabled) {
      const output =
          'Connecting with saved router credentials...\n'
          'Installing selected Openwalla setup components...\n'
          'Setup finished.';
      onOutput?.call(output);
      return output;
    }

    if (features.where((feature) => feature.trim().isNotEmpty).isEmpty) {
      throw StateError('Choose at least one setup feature to install');
    }

    final command = _buildOpenwallaSetupCommand(
      features,
      postInstallCheck: postInstallCheck,
    );
    return runRouterSetupCommandViaSsh(command, onOutput: onOutput);
  }

  Future<bool> hasStatisticsSupport({BuildContext? context}) async {
    if (_reviewerModeEnabled) return true;
    final hasInstalledCommand = await _routerCommandSucceeds(
      'if command -v vnstat >/dev/null 2>&1 || command -v nlbw >/dev/null 2>&1 || command -v nlbwmon >/dev/null 2>&1; then echo OK; else exit 1; fi',
      context: context,
    );
    if (hasInstalledCommand) return true;

    final vnstatInterfaces = await fetchVnstatInterfaceNames();
    return vnstatInterfaces.isNotEmpty;
  }

  Future<bool> hasNetworkPerformanceSupport({BuildContext? context}) async {
    if (_reviewerModeEnabled) return true;
    final hasInstalledScripts = await _routerCommandSucceeds(
      '[ -x /usr/bin/openwalla-ping-monitor ] && [ -x /usr/bin/openwalla-dns-monitor ] && [ -x /usr/bin/openwalla-speedtest-monitor ] && echo OK',
      context: context,
    );
    if (hasInstalledScripts) return true;

    try {
      final values = await _fetchOpenwallaUciValues();
      if (values is Map) {
        final hasPingConfig = values['ping_monitor'] is Map;
        final hasDnsConfig = values['dns_monitor'] is Map;
        final hasSpeedtestConfig = values['speedtest_monitor'] is Map;
        if (hasPingConfig || hasDnsConfig || hasSpeedtestConfig) {
          return true;
        }
      }
    } catch (e, stack) {
      Logger.debug('Optional network monitor config check failed: $e');
      Logger.debug('Optional network monitor config stack: $stack');
    }

    final pingSamples = await fetchPingMonitorSamples(limit: 1);
    return pingSamples.isNotEmpty;
  }

  Future<bool> hasNetifySupport({BuildContext? context}) async {
    if (_reviewerModeEnabled) return true;

    final hasNetifyTable = await _sqliteTableExists(
      dbExpression: _netifyDbExpression(),
      tableName: 'flow_raw',
      context: context,
    );
    if (hasNetifyTable) return true;

    final hasNetifyInstall = await _routerCommandSucceeds(
      'if [ -x /usr/bin/openwalla-netify-collector ] || [ -x /etc/init.d/openwalla-netify-collector ] || command -v netifyd >/dev/null 2>&1; then echo OK; else exit 1; fi',
    );
    if (hasNetifyInstall) return true;

    try {
      final values = await _fetchOpenwallaUciValues();
      if (values is Map) {
        final collector = values['collector'];
        final features = values['features'];
        final netifyFlag = features is Map ? features['netify'] : null;
        return collector is Map || netifyFlag?.toString() == '1';
      }
    } catch (e, stack) {
      Logger.debug('Optional Netify config check failed: $e');
      Logger.debug('Optional Netify config stack: $stack');
    }

    return false;
  }

  Future<StatisticsPreloadData> preloadStatisticsData({bool force = false}) {
    if (!force && _statisticsPreloadData != null) {
      return Future.value(_statisticsPreloadData);
    }
    if (!force && _statisticsPreloadFuture != null) {
      return _statisticsPreloadFuture!;
    }

    final future = _loadStatisticsPreloadData();
    _statisticsPreloadFuture = future;
    future
        .then((data) {
          if (_statisticsPreloadFuture == future) {
            _statisticsPreloadData = data;
          }
        })
        .whenComplete(() {
          if (_statisticsPreloadFuture == future) {
            _statisticsPreloadFuture = null;
          }
        });
    return future;
  }

  Future<StatisticsPreloadData> _loadStatisticsPreloadData() async {
    final hasSupport = await hasStatisticsSupport();
    final settings = await fetchMonthlyUsageSettings();
    final interfaceName = settings.interfaceName.isNotEmpty
        ? settings.interfaceName
        : _primaryVnstatInterfaceName();

    final usageSamples = <String, List<VnstatUsageSample>>{};
    var topDevices = const <NlbwDeviceUsage>[];
    var protocolUsage = const <NlbwProtocolUsage>[];

    if (hasSupport) {
      final results = await Future.wait<dynamic>([
        fetchVnstatUsageSamples(
          period: 'daily',
          interfaceName: interfaceName,
          limit: 45,
        ),
        fetchVnstatUsageSamples(
          period: '5min',
          interfaceName: interfaceName,
          limit: 12,
        ),
        fetchVnstatUsageSamples(
          period: 'hourly',
          interfaceName: interfaceName,
          limit: 12,
        ),
        fetchVnstatUsageSamples(
          period: 'hourly',
          interfaceName: interfaceName,
          limit: 24,
        ),
        fetchVnstatUsageSamples(
          period: 'daily',
          interfaceName: interfaceName,
          limit: 7,
        ),
        fetchNlbwTopDevices(limit: 5),
        fetchNlbwProtocolUsage(limit: 5),
      ]);
      usageSamples['monthly-summary'] = results[0] as List<VnstatUsageSample>;
      usageSamples['5min:12'] = results[1] as List<VnstatUsageSample>;
      usageSamples['hourly:12'] = results[2] as List<VnstatUsageSample>;
      usageSamples['hourly:24'] = results[3] as List<VnstatUsageSample>;
      usageSamples['daily:7'] = results[4] as List<VnstatUsageSample>;
      topDevices = results[5] as List<NlbwDeviceUsage>;
      protocolUsage = results[6] as List<NlbwProtocolUsage>;
    }

    return StatisticsPreloadData(
      hasSupport: hasSupport,
      settings: settings,
      interfaceName: interfaceName,
      usageSamples: usageSamples,
      topDevices: topDevices,
      protocolUsage: protocolUsage,
    );
  }

  String _primaryVnstatInterfaceName() {
    final interfaces =
        dashboardData?['interfaceDump']?['interface'] as List<dynamic>?;
    if (interfaces == null) return 'br-lan';
    final names = interfaces
        .whereType<Map<String, dynamic>>()
        .map((interface) => interface['interface']?.toString())
        .whereType<String>()
        .where((name) => name != 'loopback' && name != 'lo')
        .toList();
    return names.firstWhere(
      (name) => name == 'br-lan',
      orElse: () => names.isNotEmpty ? names.first : 'br-lan',
    );
  }

  Future<OpenwrtFeatureStatus> getOpenwrtFeatureStatus(
    OpenwrtFeature feature, {
    bool forceRefresh = false,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return OpenwrtFeatureStatus(
        feature: feature,
        label: _openwrtFeatureLabel(feature),
        installed: true,
        checkedAt: DateTime.now(),
      );
    }

    final cacheKey = _openwrtFeatureCacheKey(feature);
    if (!forceRefresh) {
      final cached = await _secureStorageService.readValue(cacheKey);
      final parsed = _parseOpenwrtFeatureCache(feature, cached);
      if (parsed != null) return parsed;
    }

    final installed = await _routerCommandSucceeds(
      _openwrtFeatureCheckCommand(feature),
    );
    final status = OpenwrtFeatureStatus(
      feature: feature,
      label: _openwrtFeatureLabel(feature),
      installed: installed,
      checkedAt: DateTime.now(),
    );
    await _saveOpenwrtFeatureStatus(status);
    return status;
  }

  Future<OpenwrtFeatureStatus> installOpenwrtFeature(
    OpenwrtFeature feature, {
    BuildContext? context,
    void Function(String chunk)? onOutput,
  }) async {
    if (_reviewerModeEnabled) {
      final status = OpenwrtFeatureStatus(
        feature: feature,
        label: _openwrtFeatureLabel(feature),
        installed: true,
        checkedAt: DateTime.now(),
      );
      await _saveOpenwrtFeatureStatus(status);
      return status;
    }

    final router = _routerService?.selectedRouter;
    if (router == null) {
      throw Exception('Router is not connected');
    }
    if (router.username.trim().isEmpty || router.password.isEmpty) {
      throw Exception('Saved router SSH credentials are missing');
    }

    final installerFeature = _openwrtFeatureInstallerFeature(feature);
    final output = await installOpenwallaSetupFeatures(
      [installerFeature],
      postInstallCheck: _openwrtFeatureCheckCommand(feature),
      onOutput: onOutput,
    );
    if (!output.contains('OK')) {
      throw Exception(
        output.trim().isEmpty ? 'Package install failed' : output,
      );
    }
    final status = OpenwrtFeatureStatus(
      feature: feature,
      label: _openwrtFeatureLabel(feature),
      installed: true,
      checkedAt: DateTime.now(),
    );
    await _saveOpenwrtFeatureStatus(status);
    return status;
  }

  String _openwrtFeatureLabel(OpenwrtFeature feature) {
    return switch (feature) {
      OpenwrtFeature.wireguard => 'WireGuard',
      OpenwrtFeature.adblock => 'AdBlock',
      OpenwrtFeature.sqm => 'SQM',
    };
  }

  String _openwrtFeatureInstallerFeature(OpenwrtFeature feature) {
    return switch (feature) {
      OpenwrtFeature.wireguard => 'wireguard',
      OpenwrtFeature.adblock => 'adblock',
      OpenwrtFeature.sqm => 'qos',
    };
  }

  String _openwrtFeatureCheckCommand(OpenwrtFeature feature) {
    return switch (feature) {
      OpenwrtFeature.wireguard => _withWireGuardBinaryLookup(
        '([ -n "\$WG_BIN" ] || uci -q show network 2>/dev/null | grep -q "proto=.*wireguard" || opkg list-installed 2>/dev/null | grep -Eq "^(wireguard-tools|luci-proto-wireguard|luci-app-wireguard) ") && echo OK',
      ),
      OpenwrtFeature.adblock =>
        r'([ -x /etc/init.d/adblock ] || command -v adblock >/dev/null 2>&1 || uci -q get adblock.global >/dev/null 2>&1 || opkg list-installed 2>/dev/null | grep -Eq "^(adblock|luci-app-adblock) ") && echo OK',
      OpenwrtFeature.sqm =>
        r'([ -x /etc/init.d/sqm ] || command -v sqm >/dev/null 2>&1 || [ -d /usr/lib/sqm ] || opkg list-installed 2>/dev/null | grep -Eq "^(sqm-scripts|luci-app-sqm) ") && echo OK',
    };
  }

  String _openwrtFeatureCacheKey(OpenwrtFeature feature) {
    final routerId = _routerService?.selectedRouter?.id ?? 'global';
    return 'openwrt_feature:${feature.name}:$routerId';
  }

  OpenwrtFeatureStatus? _parseOpenwrtFeatureCache(
    OpenwrtFeature feature,
    String? value,
  ) {
    if (value == null || value.isEmpty) return null;
    try {
      final data = jsonDecode(value);
      if (data is! Map) return null;
      final checkedAt = DateTime.tryParse(data['checkedAt']?.toString() ?? '');
      if (checkedAt == null) return null;
      return OpenwrtFeatureStatus(
        feature: feature,
        label: _openwrtFeatureLabel(feature),
        installed: data['installed'] == true,
        checkedAt: checkedAt,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveOpenwrtFeatureStatus(OpenwrtFeatureStatus status) async {
    await _secureStorageService.writeValue(
      _openwrtFeatureCacheKey(status.feature),
      jsonEncode({
        'installed': status.installed,
        'checkedAt': status.checkedAt.toIso8601String(),
      }),
    );
  }

  Future<bool> _routerCommandSucceeds(
    String command, {
    BuildContext? context,
  }) async {
    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return false;
    }
    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/bin/sh',
          'params': ['-c', command],
        },
        context: context,
      );
      final output = _commandOutput(result).trim();
      return output.contains('OK');
    } catch (e, stack) {
      Logger.debug('Optional router support check failed: $e');
      Logger.debug('Optional router support check stack: $stack');
      return false;
    }
  }

  String? get sysauth => _authService?.sysauth;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  void setError(String error) {
    _errorMessage = error;
    notifyListeners();
  }

  Map<String, dynamic>? get dashboardData => _dashboardData;
  List<double> get rxHistory => _throughputService?.rxHistory ?? [];
  List<double> get txHistory => _throughputService?.txHistory ?? [];
  double get currentRxRate => _throughputService?.currentRxRate ?? 0.0;
  double get currentTxRate => _throughputService?.currentTxRate ?? 0.0;
  bool get isDashboardLoading => _isDashboardLoading;
  String? get dashboardError => _dashboardError;

  // Interface-specific throughput getters
  List<double> getRxHistoryForInterface(String interface) {
    final deviceName = _getDeviceNameForInterface(interface);
    return _throughputService?.getRxHistoryForInterface(
          deviceName ?? interface,
        ) ??
        [];
  }

  List<double> getTxHistoryForInterface(String interface) {
    final deviceName = _getDeviceNameForInterface(interface);
    return _throughputService?.getTxHistoryForInterface(
          deviceName ?? interface,
        ) ??
        [];
  }

  double getCurrentRxRateForInterface(String interface) {
    final deviceName = _getDeviceNameForInterface(interface);
    return _throughputService?.getCurrentRxRateForInterface(
          deviceName ?? interface,
        ) ??
        0.0;
  }

  double getCurrentTxRateForInterface(String interface) {
    final deviceName = _getDeviceNameForInterface(interface);
    return _throughputService?.getCurrentTxRateForInterface(
          deviceName ?? interface,
        ) ??
        0.0;
  }

  void _resetCpuStatSample() {
    _lastCpuTotalTicks = null;
    _lastCpuIdleTicks = null;
    _lastCpuUsagePercent = null;
    _lastCpuCoreCount = 1;
  }

  Future<void> loadRouters() async {
    await _routerService?.loadRouters();
    notifyListeners();
  }

  Future<void> addRouter(model.Router router) async {
    await _routerService?.addRouter(router);
    notifyListeners();
  }

  Future<void> removeRouter(String id) async {
    if (_routerService == null) return;

    // Get the router before removing to clear its certificates
    final router = _routerService!.routers.firstWhere(
      (r) => r.id == id,
      orElse: () => throw Exception('Router not found'),
    );

    // Clear certificates for this specific router
    await _httpClientManager.clearCertificatesForHost(router.ipAddress);

    final needsSwitch = await _routerService!.removeRouter(id);
    if (needsSwitch && _routerService!.routers.isNotEmpty) {
      await selectRouter(_routerService!.routers.first.id);
    } else if (_routerService!.selectedRouter == null) {
      _dashboardData = null;
      notifyListeners();
    } else {
      notifyListeners();
    }
  }

  Future<void> selectRouter(String id, {BuildContext? context}) async {
    if (_routerService == null || _routerService!.routers.isEmpty) return;

    final found = _routerService!.selectRouter(id);
    if (found == null) return;

    _isLoading = true;
    _dashboardError = null;

    // Clear throughput data when switching routers to prevent mixing data from different routers
    _cancelThroughputTimer();
    _resetCpuStatSample();

    // Determine a safe context before any awaits
    final safeContext = context?.mounted == true
        ? context
        : null; // ignore: use_build_context_synchronously

    // Load router-scoped dashboard preferences immediately on selection
    await loadDashboardPreferences();

    notifyListeners();
    // ignore: use_build_context_synchronously
    final loginSuccess = await login(
      found.ipAddress,
      found.username,
      found.password,
      found.useHttps,
      fromRouter: true,
      context: safeContext, // ignore: use_build_context_synchronously
    );
    if (loginSuccess) {
      await fetchDashboardData();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> updateRouter(model.Router router) async {
    await _routerService?.updateRouter(router);
    notifyListeners();
  }

  Future<bool> login(
    String ip,
    String user,
    String pass,
    bool useHttps, {
    bool fromRouter = false,
    bool saveCredentials = true,
    BuildContext? context,
  }) async {
    _isLoading = true;
    _errorMessage = null;

    // Clear throughput data when logging in to prevent mixing data from different sessions
    _cancelThroughputTimer();
    _resetCpuStatSample();

    notifyListeners();

    try {
      await _authService!.login(
        ip,
        user,
        pass,
        useHttps,
        context: context,
        saveCredentials: saveCredentials,
      );

      // Check if authentication was successful
      if (_authService!.isAuthenticated) {
        // Get the actual protocol used (might be different due to redirect)
        final actualUseHttps = _authService!.useHttps;

        if (!fromRouter && saveCredentials) {
          // If not from router selection, add or update router with detected protocol
          if (_routerService != null) {
            final router = _routerService!.createRouter(
              ip,
              user,
              pass,
              actualUseHttps, // Use the detected protocol
            );
            final idx = _routerService!.routers.indexWhere(
              (r) => r.id == router.id,
            );
            if (idx == -1) {
              await addRouter(router);
            } else {
              await updateRouter(router);
            }
            await _routerService!.setSelectedRouter(router.id);
            await loadDashboardPreferences();
          }
        } else if (actualUseHttps != useHttps && _routerService != null) {
          // If we're logging in from a saved router and the protocol changed, update it
          final router = _routerService!.selectedRouter;
          if (router != null) {
            final updatedRouter = router.copyWith(useHttps: actualUseHttps);
            await updateRouter(updatedRouter);
            Logger.info(
              'Updated router protocol from ${useHttps ? "HTTPS" : "HTTP"} to ${actualUseHttps ? "HTTPS" : "HTTP"}',
            );
          }
        }
        await fetchDashboardData();
        _startThroughputTimer();
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage =
            'Login Failed: Invalid credentials or host unreachable.';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'An error occurred: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  void logout() {
    _authService?.logout().then((_) {});
    _dashboardData = null;
    _dashboardError = null;
    _cancelThroughputTimer();
    // Optionally, do not clear routers or selectedRouter
    notifyListeners();
  }

  Future<void> retryDashboardConnection({BuildContext? context}) async {
    final router = _routerService?.selectedRouter;
    if (router == null || _authService == null) {
      await fetchDashboardData();
      return;
    }

    _isDashboardLoading = true;
    _dashboardError = null;
    _cancelThroughputTimer();
    _httpClientManager.disposeClient(router.ipAddress, router.useHttps);
    notifyListeners();

    try {
      final safeContext = context?.mounted == true ? context : null;
      final loginSuccess = await _authService!.tryAutoLogin(
        router.ipAddress,
        router.username,
        router.password,
        router.useHttps,
        context: safeContext,
      );

      if (!loginSuccess || _authService?.sysauth == null) {
        _dashboardError =
            'Failed to reconnect. Please check your router credentials and network connection.';
        _dashboardData = null;
        return;
      }

      final actualUseHttps = _authService!.useHttps;
      if (actualUseHttps != router.useHttps) {
        await updateRouter(router.copyWith(useHttps: actualUseHttps));
      }

      await fetchDashboardData();
    } catch (e) {
      _dashboardError = 'Failed to reconnect: $e';
      _dashboardData = null;
    } finally {
      _isDashboardLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchDashboardData({bool allowAuthRetry = true}) async {
    if (_reviewerModeEnabled) {
      // For reviewer mode, return mock data immediately
      _isDashboardLoading = true;
      _dashboardError = null;
      notifyListeners();

      await Future.delayed(
        const Duration(milliseconds: 500),
      ); // Simulate network delay

      try {
        final results = await Future.wait([
          _apiService!.callSimple('system', 'board', {}),
          _apiService!.callSimple('system', 'info', {}),
          _apiService!.callSimple('network', 'device', {}),
          _apiService!.callSimple('network.interface', 'dump', {}),
          _apiService!.callSimple('wireless', 'devices', {}),
          _apiService!.callSimple('luci-rpc', 'getDHCPLeases', {}),
          _apiService!.callSimple('uci', 'get', {'config': 'wireless'}),
        ]);

        final interfaceDump = results[3][1] as Map<String, dynamic>;
        final rawDhcpData = results[5][1] as Map<String, dynamic>;
        final processedDhcpData = _processDhcpLeases(rawDhcpData);
        final associatedMacs = await _apiService!.fetchAssociatedStations();

        final selectedFlowProvider =
            _dashboardPreferences.flowMode == DashboardFlowMode.simple
            ? OpenwallaFlowProvider.conntrack
            : OpenwallaFlowProvider.netify;
        final flowSummary = selectedFlowProvider == OpenwallaFlowProvider.netify
            ? const OpenwallaFlowSummary(
                provider: OpenwallaFlowProvider.netify,
                count: 315188,
              )
            : const OpenwallaFlowSummary(
                provider: OpenwallaFlowProvider.conntrack,
                count: 1704,
              );
        final mockSysInfo = Map<String, dynamic>.from(results[1][1] as Map);
        mockSysInfo['cpuUsagePercent'] = 31.0;
        mockSysInfo['cpuCoreCount'] = 4;

        _dashboardData = {
          'boardInfo': results[0][1],
          'sysInfo': mockSysInfo,
          'networkDevices': results[2][1],
          'interfaceDump': interfaceDump,
          'wireless': results[4][1],
          'dhcpLeases': processedDhcpData,
          'uciWirelessConfig': results[6][1],
          'wan': _extractWanData(interfaceDump),
          'wireguard': <String, dynamic>{}, // Empty for reviewer mode
          'conntrack': {'count': 142, 'max': 1000},
          'pingSamples': await fetchPingMonitorSamples(),
          'flowProvider': flowSummary.provider,
          'flowSummary': flowSummary,
          'netifyFlowCount': flowSummary.count,
          'notificationCount': 2,
          'deviceCount': _countRouterDevices(processedDhcpData, associatedMacs),
          'rulesCount': _mockFirewallRules().length,
          '_lastUpdated':
              DateTime.now().millisecondsSinceEpoch, // Force UI updates
        };

        // Update throughput data with mock network data for reviewer mode
        if (_throughputService != null) {
          final networkData = results[2][1] as Map<String, dynamic>?;
          final wanDeviceNames = {
            'eth0',
            'wlan0',
            'br-lan',
          }; // Mock all devices

          // Check if we should track specific interface
          final prefs = _dashboardPreferences;
          String? specificInterface;
          if (!prefs.showAllThroughput &&
              prefs.primaryThroughputInterface != null) {
            // Map interface name to actual device name
            specificInterface = _getDeviceNameForInterface(
              prefs.primaryThroughputInterface!,
            );
          }

          _throughputService!.updateThroughput(
            networkData,
            wanDeviceNames,
            specificInterface: specificInterface,
          );
        }

        // Start throughput timer for reviewer mode
        _startThroughputTimer();
        _startSystemInfoTimer();

        // Schedule an immediate throughput update to get initial data faster
        Future.delayed(const Duration(milliseconds: 100), () {
          _updateThroughputOnly();
        });

        _isDashboardLoading = false;
        notifyListeners();
      } catch (e) {
        _dashboardError = 'Failed to fetch dashboard data: $e';
        _isDashboardLoading = false;
        notifyListeners();
      }
      return;
    }

    if (_routerService?.selectedRouter == null ||
        _authService?.sysauth == null) {
      return;
    }

    // If already loading, don't start another request (but this shouldn't prevent pull-to-refresh)
    // We'll let the new request proceed and the loading state will be handled properly
    final ip = _routerService!.selectedRouter!.ipAddress;
    final useHttps = _routerService!.selectedRouter!.useHttps;

    _isDashboardLoading = true;
    _dashboardError = null;
    notifyListeners();

    try {
      // Perform all API calls in parallel
      Future<dynamic> callOptionalRpc({
        required String object,
        required String method,
        Map<String, dynamic>? params,
      }) async {
        try {
          return await _apiService!.call(
            ip,
            _authService!.sysauth!,
            useHttps,
            object: object,
            method: method,
            params: params,
          );
        } catch (e, stack) {
          Logger.warning('Optional RPC $object.$method failed: $e');
          Logger.debug('Optional RPC $object.$method stack: $stack');
          return null;
        }
      }

      final wirelessFuture = callOptionalRpc(
        object: 'luci-rpc',
        method: 'getWirelessDevices',
        params: {},
      );

      // UCI wireless config is optional — wired-only routers may not have it
      final uciWirelessFuture = callOptionalRpc(
        object: 'uci',
        method: 'get',
        params: {'config': 'wireless'},
      );

      final conntrackFuture = _fetchConntrackData(ip, useHttps);
      final cpuUsagePercentFuture = _fetchCpuUsagePercent(ip, useHttps);
      final pingSamplesFuture = fetchPingMonitorSamples();
      final selectedFlowProvider =
          _dashboardPreferences.flowMode == DashboardFlowMode.simple
          ? OpenwallaFlowProvider.conntrack
          : OpenwallaFlowProvider.netify;
      final flowSummaryFuture = fetchOpenwallaFlowSummary(
        provider: selectedFlowProvider,
      );
      final notificationCountFuture = fetchNotificationCount();
      final rulesCountFuture = fetchFirewallRuleCount();
      final associatedMacsFuture = _apiService!
          .fetchAllAssociatedWirelessMacsWithContext(
            ipAddress: ip,
            sysauth: _authService!.sysauth!,
            useHttps: useHttps,
          )
          .catchError((e, stack) {
            Logger.warning('Optional associated station fetch failed: $e');
            Logger.debug('Optional associated station fetch stack: $stack');
            return <String, Set<String>>{};
          });

      final results = await Future.wait([
        _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'system',
          method: 'board',
          params: {},
        ),
        _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'system',
          method: 'info',
          params: {},
        ),
        _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'luci-rpc',
          method: 'getNetworkDevices',
          params: {},
        ),
        _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'network.interface',
          method: 'dump',
          params: {},
        ),
        _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'luci-rpc',
          method: 'getDHCPLeases',
          params: {},
        ),
      ]);

      // Helper to safely extract data and handle errors from LuCI's [status, data] responses
      dynamic getData(dynamic result) {
        if (result is List && result.length > 1) {
          if (result[0] == 0) {
            return result[1]; // Success
          } else {
            // Throw an exception with the error message from the API
            final errorMessage = result[1] is String
                ? result[1]
                : 'Unknown API Error';
            throw Exception(errorMessage);
          }
        }
        // Handle cases where the result is not in the expected format
        return result;
      }

      dynamic getOptionalData(dynamic result, String label) {
        try {
          return getData(result);
        } catch (e) {
          Logger.warning('Optional RPC $label returned error: $e');
          return null;
        }
      }

      final boardInfoData = getData(results[0]);
      final sysInfoData = getData(results[1]);
      final networkData = getData(results[2]) as Map<String, dynamic>?;
      final interfaceDump = getData(results[3]) as Map<String, dynamic>?;
      final dhcpLeases = getData(results[4]) as Map<String, dynamic>?;

      // Await optional wireless futures in parallel (won't throw — wired-only routers are fine)
      final optionalResults = await Future.wait([
        wirelessFuture,
        uciWirelessFuture,
        conntrackFuture,
        cpuUsagePercentFuture,
        pingSamplesFuture,
        flowSummaryFuture,
        notificationCountFuture,
        rulesCountFuture,
        associatedMacsFuture,
      ]);
      final wirelessRaw = optionalResults[0];
      final uciWirelessRaw = optionalResults[1];
      final conntrackData = optionalResults[2] as Map<String, int>;
      final cpuUsagePercent = optionalResults[3] as double?;
      final pingSamples = optionalResults[4] as List<PingMonitorSample>;
      final flowSummary = optionalResults[5] as OpenwallaFlowSummary;
      final notificationCount = optionalResults[6] as int;
      final rulesCount = optionalResults[7] as int;
      final associatedMacs = optionalResults[8] as Map<String, Set<String>>;

      Map<String, dynamic>? wirelessData;
      if (wirelessRaw != null) {
        final parsedWireless = getOptionalData(
          wirelessRaw,
          'luci-rpc.getWirelessDevices',
        );
        if (parsedWireless is Map<String, dynamic>) {
          wirelessData = parsedWireless;
        }
      }

      dynamic uciWirelessConfig;
      if (uciWirelessRaw != null) {
        uciWirelessConfig = getOptionalData(uciWirelessRaw, 'uci.get wireless');
      }

      // Fetch WireGuard peer information for WireGuard interfaces
      final wireguardData = <String, dynamic>{};
      if (interfaceDump != null && interfaceDump['interface'] is List) {
        // Check if there are any WireGuard interfaces
        final hasWireGuardInterfaces = interfaceDump['interface'].any((
          interface,
        ) {
          if (interface is Map<String, dynamic>) {
            final proto = interface['proto'] as String?;
            return proto == 'wireguard';
          }
          return false;
        });

        if (hasWireGuardInterfaces) {
          // Fetch all WireGuard data at once
          final allWireGuardData = await _apiService!.fetchWireGuardPeers(
            ipAddress: ip,
            sysauth: _authService!.sysauth!,
            useHttps: useHttps,
            interface: '', // Empty string to get all interfaces
          );

          if (allWireGuardData != null) {
            // The new endpoint returns data for all interfaces
            // We need to extract data for each WireGuard interface
            for (final interface in interfaceDump['interface']) {
              if (interface is Map<String, dynamic>) {
                final ifname = interface['interface'] as String?;
                final proto = interface['proto'] as String?;
                if (proto == 'wireguard' && ifname != null) {
                  // Look for this interface in the WireGuard data
                  final interfaceData = allWireGuardData[ifname];

                  if (interfaceData != null) {
                    wireguardData[ifname] = interfaceData;
                  }
                }
              }
            }
          }
        }
      }

      // Throughput calculation - collect ALL interface devices
      final wanDeviceNames = <String>{};
      if (interfaceDump != null && interfaceDump['interface'] is List) {
        for (final interface in interfaceDump['interface']) {
          if (interface is Map<String, dynamic>) {
            final ifname = interface['interface'] as String?;
            // Skip only loopback interface
            if (ifname != null && ifname != 'loopback' && ifname != 'lo') {
              final device = interface['device'] as String?;
              final l3Device = interface['l3_device'] as String?;
              if (device != null) {
                wanDeviceNames.add(device);
              }
              if (l3Device != null && l3Device != device) {
                wanDeviceNames.add(l3Device);
              }
            }
          }
        }
      }

      // Update throughput data using the service
      // Check if we should track specific interface
      final prefs = _dashboardPreferences;
      String? specificInterface;
      if (!prefs.showAllThroughput &&
          prefs.primaryThroughputInterface != null) {
        // Map interface name to actual device name
        specificInterface = _getDeviceNameForInterface(
          prefs.primaryThroughputInterface!,
        );
      }

      _throughputService?.updateThroughput(
        networkData,
        wanDeviceNames,
        specificInterface: specificInterface,
      );

      final sysInfoWithCpu = sysInfoData is Map
          ? Map<String, dynamic>.from(sysInfoData)
          : <String, dynamic>{};
      sysInfoWithCpu['cpuCoreCount'] = _lastCpuCoreCount;
      final previousSysInfo = _dashboardData?['sysInfo'];
      final previousCpuUsage = previousSysInfo is Map
          ? previousSysInfo['cpuUsagePercent']
          : null;
      final stableCpuUsage =
          cpuUsagePercent ??
          _lastCpuUsagePercent ??
          (previousCpuUsage is num ? previousCpuUsage.toDouble() : null);
      if (stableCpuUsage != null) {
        sysInfoWithCpu['cpuUsagePercent'] = stableCpuUsage;
      }

      _dashboardData = {
        'boardInfo': boardInfoData,
        'sysInfo': sysInfoWithCpu,
        'networkDevices': networkData,
        'interfaceDump': interfaceDump,
        'wireless': wirelessData ?? <String, dynamic>{},
        'dhcpLeases': dhcpLeases,
        'wan': _extractWanData(interfaceDump),
        'uciWirelessConfig': uciWirelessConfig,
        'wireguard': wireguardData,
        'conntrack': conntrackData,
        'pingSamples': pingSamples,
        'flowProvider': flowSummary.provider,
        'flowSummary': flowSummary,
        'netifyFlowCount': flowSummary.count,
        'notificationCount': notificationCount,
        'deviceCount': _countRouterDevices(dhcpLeases, associatedMacs),
        'rulesCount': rulesCount,
        '_lastUpdated':
            DateTime.now().millisecondsSinceEpoch, // Force UI updates
      };

      // Hybrid approach: update lastKnownHostname for the selected router
      final boardInfo = _dashboardData?['boardInfo'] as Map<String, dynamic>?;
      final hostname = boardInfo?['hostname']?.toString();
      if (hostname != null && hostname.isNotEmpty) {
        await _routerService?.updateSelectedRouterHostname(hostname);
      }

      // Ensure throughput timer is running
      _startThroughputTimer();
      _startSystemInfoTimer();

      // Schedule an immediate throughput update to get initial data faster
      Future.delayed(const Duration(milliseconds: 100), () {
        _updateThroughputOnly();
      });
    } catch (e) {
      if (allowAuthRetry && await _tryRefreshDashboardSession(e)) {
        return fetchDashboardData(allowAuthRetry: false);
      }

      final errorMessage = e.toString();
      if (errorMessage.contains('Access denied')) {
        _dashboardError = 'Access Denied: Check RPC permissions for this user.';
      } else {
        _dashboardError = 'Failed to fetch dashboard data: $e';
      }
      // Log error with stack trace for debugging
      // print('Dashboard fetch error: $e\n$stack');
      // Clear dashboard data when there's an error so we don't show stale data
      _dashboardData = null;
    } finally {
      _isDashboardLoading = false;
      notifyListeners();
    }
  }

  Future<bool> _tryRefreshDashboardSession(Object error) async {
    if (!_looksLikeExpiredSession(error)) return false;

    final router = _routerService?.selectedRouter;
    if (router == null || _authService == null) return false;
    if (router.username.trim().isEmpty || router.password.isEmpty) return false;

    Logger.info('Dashboard RPC failed with a likely stale session. Reauthing.');
    _httpClientManager.disposeClient(router.ipAddress, router.useHttps);

    final loginSuccess = await _authService!.tryAutoLogin(
      router.ipAddress,
      router.username,
      router.password,
      router.useHttps,
    );
    if (!loginSuccess || _authService?.sysauth == null) return false;

    final actualUseHttps = _authService!.useHttps;
    if (actualUseHttps != router.useHttps) {
      await updateRouter(router.copyWith(useHttps: actualUseHttps));
    }

    return true;
  }

  bool _looksLikeExpiredSession(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('access denied') ||
        text.contains('permission denied') ||
        text.contains('unauthorized') ||
        text.contains('forbidden') ||
        text.contains('invalid session') ||
        text.contains('session') ||
        text.contains('login');
  }

  Map<String, dynamic> _processDhcpLeases(Map<String, dynamic> rawDhcpData) {
    final stdout = rawDhcpData['stdout'] as String? ?? '';
    final leases = <Map<String, dynamic>>[];

    for (final line in stdout.split('\n')) {
      if (line.trim().isEmpty) continue;

      final parts = line.trim().split(' ');
      if (parts.length >= 5) {
        // Format: timestamp mac_address ip_address hostname client_id
        final timestamp = int.tryParse(parts[0]) ?? 0;
        final macAddress = parts[1];
        final ipAddress = parts[2];
        final hostname = parts[3];

        leases.add({
          'expires': timestamp,
          'macaddr': macAddress,
          'ipaddr': ipAddress,
          'hostname': hostname,
          'activetime': 0, // Default for mock data
          'leasetime': timestamp,
        });
      }
    }

    return {'dhcp_leases': leases};
  }

  Map<String, int> _parseConntrackData(dynamic rawData) {
    final raw = switch (rawData) {
      {'stdout': final stdout} => stdout?.toString() ?? '',
      {'data': final data} => data?.toString() ?? '',
      _ => rawData?.toString() ?? '',
    };
    final values = RegExp(r'\d+')
        .allMatches(raw)
        .map((match) => int.tryParse(match.group(0) ?? ''))
        .whereType<int>()
        .toList();

    return {
      'count': values.isNotEmpty ? values[0] : 0,
      'max': values.length > 1 && values[1] > 0 ? values[1] : 1000,
    };
  }

  int? _parseProcInt(String value) {
    return int.tryParse(value.trim().split(RegExp(r'\s+')).firstOrNull ?? '');
  }

  ({int total, int idle, int cores})? _parseCpuStat(String output) {
    var cores = 0;
    for (final candidate in output.split('\n')) {
      if (RegExp(r'^cpu\d+\s+').hasMatch(candidate)) cores += 1;
    }

    final line = output
        .split('\n')
        .firstWhere((line) => line.startsWith('cpu '), orElse: () => '');
    if (line.isEmpty) return null;

    final values = line
        .trim()
        .split(RegExp(r'\s+'))
        .skip(1)
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    if (values.length < 4) return null;

    final idle = values[3] + (values.length > 4 ? values[4] : 0);
    final total = values.fold<int>(0, (sum, value) => sum + value);
    if (total <= 0) return null;
    return (total: total, idle: idle, cores: cores > 0 ? cores : 1);
  }

  double? _parseTopCpuUsage(String output) {
    final line = output
        .split('\n')
        .firstWhere(
          (line) => line.trimLeft().startsWith('CPU:'),
          orElse: () => '',
        );
    if (line.isEmpty) return null;

    final idleMatch = RegExp(r'(\d+(?:\.\d+)?)%\s+idle').firstMatch(line);
    if (idleMatch != null) {
      final idle = double.tryParse(idleMatch.group(1) ?? '');
      if (idle != null) return (100 - idle).clamp(0, 100).toDouble();
    }

    var used = 0.0;
    for (final label in const ['usr', 'sys', 'nic', 'io', 'irq', 'sirq']) {
      final match = RegExp(r'(\d+(?:\.\d+)?)%\s+' + label).firstMatch(line);
      used += double.tryParse(match?.group(1) ?? '') ?? 0;
    }
    return used > 0 ? used.clamp(0, 100).toDouble() : null;
  }

  Future<double?> _fetchTopCpuUsagePercent(String ip, bool useHttps) async {
    if (_authService?.sysauth == null || _apiService == null) {
      return _lastCpuUsagePercent;
    }

    try {
      final result = await _apiService!.systemExec(
        ip,
        _authService!.sysauth!,
        useHttps,
        command: 'top -bn1 2>/dev/null | head -n 3',
      );
      final usage = _parseTopCpuUsage(_commandOutput(result));
      if (usage != null) _lastCpuUsagePercent = usage;
      return usage ?? _lastCpuUsagePercent;
    } catch (e, stack) {
      Logger.warning('Optional top CPU read failed: $e');
      Logger.debug('Optional top CPU read stack: $stack');
      return _lastCpuUsagePercent;
    }
  }

  Future<String?> _readProcStatViaFileExec(String ip, bool useHttps) async {
    if (_authService?.sysauth == null || _apiService == null) return null;
    try {
      final result = await _apiService!.call(
        ip,
        _authService!.sysauth!,
        useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/bin/cat',
          'params': ['/proc/stat'],
        },
      );
      final output = _commandOutput(result);
      return output.trim().isEmpty ? null : output;
    } catch (e, stack) {
      Logger.debug('Optional /proc/stat file.exec read failed: $e');
      Logger.debug('Optional /proc/stat file.exec stack: $stack');
      return null;
    }
  }

  Future<double?> _fetchCpuUsagePercent(String ip, bool useHttps) async {
    if (_authService?.sysauth == null || _apiService == null) {
      return _lastCpuUsagePercent;
    }

    final topUsage = await _fetchTopCpuUsagePercent(ip, useHttps);
    if (topUsage != null) {
      try {
        final result = await _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'file',
          method: 'read',
          params: {'path': '/proc/stat'},
        );
        final stat =
            _parseCpuStat(_commandOutput(result)) ??
            _parseCpuStat(await _readProcStatViaFileExec(ip, useHttps) ?? '');
        if (stat != null) {
          _lastCpuTotalTicks = stat.total;
          _lastCpuIdleTicks = stat.idle;
          _lastCpuCoreCount = stat.cores;
        }
      } catch (e, stack) {
        Logger.debug('Optional /proc/stat core count read failed: $e');
        Logger.debug('Optional /proc/stat core count stack: $stack');
      }
      return topUsage;
    }

    try {
      final result = await _apiService!.call(
        ip,
        _authService!.sysauth!,
        useHttps,
        object: 'file',
        method: 'read',
        params: {'path': '/proc/stat'},
      );
      final stat =
          _parseCpuStat(_commandOutput(result)) ??
          _parseCpuStat(await _readProcStatViaFileExec(ip, useHttps) ?? '');
      if (stat == null) return _fetchTopCpuUsagePercent(ip, useHttps);

      final previousTotal = _lastCpuTotalTicks;
      final previousIdle = _lastCpuIdleTicks;
      _lastCpuTotalTicks = stat.total;
      _lastCpuIdleTicks = stat.idle;
      _lastCpuCoreCount = stat.cores;

      if (previousTotal == null || previousIdle == null) {
        final sinceBootUsage = ((stat.total - stat.idle) / stat.total * 100)
            .clamp(0, 100)
            .toDouble();
        _lastCpuUsagePercent = sinceBootUsage;
        return sinceBootUsage;
      }

      final totalDelta = stat.total - previousTotal;
      final idleDelta = stat.idle - previousIdle;
      if (totalDelta <= 0) return _lastCpuUsagePercent;

      final usage = ((totalDelta - idleDelta) / totalDelta * 100)
          .clamp(0, 100)
          .toDouble();
      _lastCpuUsagePercent = usage;
      return usage;
    } catch (e, stack) {
      Logger.warning('Optional /proc/stat CPU read failed: $e');
      Logger.debug('Optional /proc/stat CPU read stack: $stack');
      return _fetchTopCpuUsagePercent(ip, useHttps);
    }
  }

  int _countRouterDevices(
    Map<String, dynamic>? dhcpLeases,
    Map<String, Set<String>> associatedMacs,
  ) {
    final macs = <String>{};
    final leases = dhcpLeases?['dhcp_leases'] as List<dynamic>? ?? const [];

    for (final lease in leases) {
      if (lease is Map) {
        final mac = lease['macaddr']?.toString();
        if (mac != null && mac.isNotEmpty) {
          macs.add(mac.toUpperCase().replaceAll('-', ':'));
        }
      }
    }

    for (final stations in associatedMacs.values) {
      for (final mac in stations) {
        if (mac.isNotEmpty) {
          macs.add(mac.toUpperCase().replaceAll('-', ':'));
        }
      }
    }

    return macs.length;
  }

  Future<Map<String, int>> _fetchConntrackData(String ip, bool useHttps) async {
    if (_authService?.sysauth == null) {
      return {'count': 0, 'max': 1000};
    }

    try {
      Future<int?> readCounter(String path) async {
        final result = await _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'file',
          method: 'read',
          params: {'path': path},
        );
        return _parseProcInt(_commandOutput(result));
      }

      final count =
          await readCounter('/proc/sys/net/netfilter/nf_conntrack_count') ??
          await readCounter('/proc/sys/net/ipv4/netfilter/ip_conntrack_count');
      final max =
          await readCounter('/proc/sys/net/netfilter/nf_conntrack_max') ??
          await readCounter('/proc/sys/net/ipv4/netfilter/ip_conntrack_max');

      if (count != null || max != null) {
        return {
          'count': count ?? 0,
          'max': max != null && max > 0 ? max : 1000,
        };
      }

      final fallback = await _apiService!.systemExec(
        ip,
        _authService!.sysauth!,
        useHttps,
        command:
            'cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || cat /proc/sys/net/ipv4/netfilter/ip_conntrack_count /proc/sys/net/ipv4/netfilter/ip_conntrack_max 2>/dev/null',
      );

      if (fallback is List && fallback.length > 1 && fallback[0] == 0) {
        return _parseConntrackData(fallback[1]);
      }
      return _parseConntrackData(fallback);
    } catch (e, stack) {
      Logger.warning('Optional system.exec conntrack failed: $e');
      Logger.debug('Optional system.exec conntrack stack: $stack');
      return {'count': 0, 'max': 1000};
    }
  }

  Future<SystemStorageDetails> fetchSystemStorageDetails({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return const SystemStorageDetails(
        userTotalBytes: 56 * 1024 * 1024,
        userFreeBytes: 56 * 1024 * 1024,
        tempTotalBytes: 117 * 1024 * 1024,
        tempFreeBytes: 116 * 1024 * 1024,
      );
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return SystemStorageDetails.empty;
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/bin/sh',
          'params': [
            '-c',
            'df -kP /overlay /tmp / 2>/dev/null || df -kP 2>/dev/null',
          ],
        },
        context: context,
      );
      return _parseSystemStorageDetails(_commandOutput(result));
    } catch (e, stack) {
      Logger.warning('Optional system storage fetch failed: $e');
      Logger.debug('Optional system storage stack: $stack');
      return SystemStorageDetails.empty;
    }
  }

  SystemStorageDetails _parseSystemStorageDetails(String output) {
    ({int total, int free})? user;
    ({int total, int free})? temp;

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('Filesystem')) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 6) continue;

      final totalKb = int.tryParse(parts[1]);
      final freeKb = int.tryParse(parts[3]);
      if (totalKb == null || freeKb == null) continue;

      final mount = parts.last;
      final values = (total: totalKb * 1024, free: freeKb * 1024);
      if (mount == '/tmp') {
        temp = values;
      } else if (mount == '/overlay' || mount == '/') {
        user ??= values;
      }
    }

    return SystemStorageDetails(
      userTotalBytes: user?.total ?? 0,
      userFreeBytes: user?.free ?? 0,
      tempTotalBytes: temp?.total ?? 0,
      tempFreeBytes: temp?.free ?? 0,
    );
  }

  String _sqliteCommand(String dbExpression, String sql) {
    final escapedSql = sql.replaceAll('"', r'\"').replaceAll(r'$', r'\$');
    return 'db="$dbExpression"; '
        'statement="$escapedSql"; '
        'if command -v sqlite3 >/dev/null 2>&1; then sqlite3 -batch -noheader -separator "|" "\$db" "\$statement"; '
        'elif command -v sqlite3-cli >/dev/null 2>&1; then sqlite3-cli -batch -noheader -separator "|" "\$db" "\$statement"; '
        'else echo "sqlite3 not installed" >&2; exit 127; fi';
  }

  String _sqliteTableExistsCommand(String dbExpression, String tableName) {
    final escapedTable = tableName
        .replaceAll('"', r'\"')
        .replaceAll(r'$', r'\$');
    return 'db="$dbExpression"; '
        '[ -f "\$db" ] || exit 0; '
        'statement="SELECT name FROM sqlite_master WHERE type = \'table\' AND name = \'$escapedTable\' LIMIT 1;"; '
        'if command -v sqlite3 >/dev/null 2>&1; then sqlite3 -batch -noheader "\$db" "\$statement"; '
        'elif command -v sqlite3-cli >/dev/null 2>&1; then sqlite3-cli -batch -noheader "\$db" "\$statement"; '
        'else echo "sqlite3 not installed" >&2; exit 127; fi';
  }

  String _connectionFlowsDbExpression() {
    return r'$(uci -q get openwalla.connection_flows.db_path 2>/dev/null || echo /tmp/openwalla-connection-flows.sqlite)';
  }

  String _netifyDbExpression() {
    return r'$(uci -q get openwalla.collector.db_path 2>/dev/null || echo /tmp/openwalla-netify.sqlite)';
  }

  String _notificationsDbExpression() {
    return r'$(uci -q get openwalla.notifications.db_path 2>/dev/null || echo /tmp/openwalla-notifications.sqlite)';
  }

  String _devicesDbExpression() {
    return r'$(uci -q get openwalla.devices.db_path 2>/dev/null || echo /tmp/openwalla-devices.sqlite)';
  }

  Future<String> _sqliteQueryOutput({
    required String dbExpression,
    required String sql,
    BuildContext? context,
  }) async {
    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) return '';

    final result = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'file',
      method: 'exec',
      params: {
        'command': '/bin/sh',
        'params': ['-c', _sqliteCommand(dbExpression, sql)],
      },
      context: context,
    );
    return _commandOutput(result);
  }

  Future<String> _sqliteQueryOutputForRouter({
    required model.Router router,
    required String sysauth,
    required bool useHttps,
    required String dbExpression,
    required String sql,
    BuildContext? context,
  }) async {
    if (_apiService == null) return '';

    final result = await _apiService!.call(
      router.ipAddress,
      sysauth,
      useHttps,
      object: 'file',
      method: 'exec',
      params: {
        'command': '/bin/sh',
        'params': ['-c', _sqliteCommand(dbExpression, sql)],
      },
      context: context,
    );
    return _commandOutput(result);
  }

  (Map<String, String>, Map<String, String>) _parseDeviceNameMapsOutput(
    String output,
  ) {
    final byMac = <String, String>{};
    final byIp = <String, String>{};

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('|');
      if (parts.length < 3) continue;

      final mac = _normalizeMacAddress(parts[0]);
      final ip = parts[1].trim();
      final hostname = parts.sublist(2).join('|').trim();
      if (hostname.isEmpty || hostname == '*') continue;
      if (mac.isNotEmpty && mac != 'N/A') byMac[mac] = hostname;
      if (ip.isNotEmpty) byIp[ip] = hostname;
    }

    return (byMac, byIp);
  }

  Future<(Map<String, String>, Map<String, String>)> fetchDeviceNameMaps({
    bool aggregateAllRouters = false,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return (
        {_mockQuarantineMac: 'Mock Quarantined Device'},
        {'10.0.0.250': 'Mock Quarantined Device'},
      );
    }

    const sql =
        "SELECT mac, ip, hostname FROM devices WHERE hostname != '' ORDER BY last_seen DESC;";

    if (!aggregateAllRouters) {
      try {
        final output = await _sqliteQueryOutput(
          dbExpression: _devicesDbExpression(),
          sql: sql,
          context: context,
        );
        return _parseDeviceNameMapsOutput(output);
      } catch (e, stack) {
        Logger.debug('Optional devices DB name map read failed: $e');
        Logger.debug('Optional devices DB name map stack: $stack');
        return (<String, String>{}, <String, String>{});
      }
    }

    final routers = _routerService?.routers ?? const <model.Router>[];
    if (routers.isEmpty || _apiService == null) {
      return (<String, String>{}, <String, String>{});
    }

    final byMac = <String, String>{};
    final byIp = <String, String>{};
    final tasks = routers.map((router) async {
      try {
        String? token;
        var useHttps = router.useHttps;
        if (_apiService is RealApiService) {
          final real = _apiService as RealApiService;
          final login = await real.loginWithProtocolDetection(
            router.ipAddress,
            router.username,
            router.password,
            router.useHttps,
          );
          token = login.token;
          useHttps = login.actualUseHttps;
        } else {
          token = _authService?.sysauth;
        }
        if (token == null) return (<String, String>{}, <String, String>{});
        final output = await _sqliteQueryOutputForRouter(
          router: router,
          sysauth: token,
          useHttps: useHttps,
          dbExpression: _devicesDbExpression(),
          sql: sql,
        );
        return _parseDeviceNameMapsOutput(output);
      } catch (e, stack) {
        Logger.debug('Optional aggregated devices DB name map failed: $e');
        Logger.debug('Optional aggregated devices DB name map stack: $stack');
        return (<String, String>{}, <String, String>{});
      }
    }).toList();

    final results = await Future.wait(tasks);
    for (final maps in results) {
      byMac.addAll(maps.$1);
      byIp.addAll(maps.$2);
    }
    return (byMac, byIp);
  }

  (Map<String, OpenwallaDeviceRecord>, Map<String, OpenwallaDeviceRecord>)
  _parseDeviceRecordsOutput(String output) {
    final byMac = <String, OpenwallaDeviceRecord>{};
    final byIp = <String, OpenwallaDeviceRecord>{};

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('|');
      if (parts.length < 5) continue;

      final mac = _normalizeMacAddress(parts[0]);
      final ip = parts[1].trim();
      final hostname = parts[2].trim();
      final totalUp = int.tryParse(parts[3].trim()) ?? 0;
      final totalDown = int.tryParse(parts[4].trim()) ?? 0;
      final staticIp = parts.length > 5 ? parts[5].trim() : '';
      final status = parts.length > 6 ? parts[6].trim() : '';
      final quarantined = parts.length > 7 && parts[7].trim() == '1';
      final icon = parts.length > 8 ? parts[8].trim() : '';
      final scheduledBlock = parts.length > 9 && parts[9].trim() == '1';
      final scheduleUntil = parts.length > 10 ? parts[10].trim() : '';
      final record = OpenwallaDeviceRecord(
        mac: mac,
        ip: ip,
        hostname: hostname,
        totalUploadBytes: totalUp,
        totalDownloadBytes: totalDown,
        staticIpAddress: staticIp,
        status: status,
        quarantined: quarantined,
        icon: icon,
        scheduledBlock: scheduledBlock || status == 'block-scheduled',
        scheduleUntil: scheduleUntil,
      );
      if (mac.isNotEmpty && mac != 'N/A') {
        byMac[mac] = _mergeDuplicateDeviceRecord(byMac[mac], record);
      }
      if (ip.isNotEmpty) {
        byIp[ip] = _mergeDuplicateDeviceRecord(byIp[ip], record);
      }
    }

    return (byMac, byIp);
  }

  OpenwallaDeviceRecord _mergeDuplicateDeviceRecord(
    OpenwallaDeviceRecord? existing,
    OpenwallaDeviceRecord incoming,
  ) {
    if (existing == null) return incoming;

    final existingLive = existing.status != 'offline' || existing.quarantined;
    final incomingLive = incoming.status != 'offline' || incoming.quarantined;
    final live = incomingLive && !existingLive ? incoming : existing;
    final custom = incomingLive && !existingLive ? existing : incoming;

    return OpenwallaDeviceRecord(
      mac: live.mac,
      ip: live.ip.isNotEmpty ? live.ip : custom.ip,
      hostname: custom.hostname.isNotEmpty ? custom.hostname : live.hostname,
      totalUploadBytes: live.totalUploadBytes,
      totalDownloadBytes: live.totalDownloadBytes,
      staticIpAddress: custom.staticIpAddress.isNotEmpty
          ? custom.staticIpAddress
          : live.staticIpAddress,
      status: live.status,
      quarantined: live.quarantined || custom.quarantined,
      icon: custom.icon.isNotEmpty ? custom.icon : live.icon,
      scheduledBlock: live.scheduledBlock || custom.scheduledBlock,
      scheduleUntil: custom.scheduleUntil.isNotEmpty
          ? custom.scheduleUntil
          : live.scheduleUntil,
    );
  }

  Future<
    (Map<String, OpenwallaDeviceRecord>, Map<String, OpenwallaDeviceRecord>)
  >
  fetchDeviceRecords({
    bool aggregateAllRouters = false,
    bool activeOnly = false,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      final record = OpenwallaDeviceRecord(
        mac: _mockQuarantineMac,
        ip: '10.0.0.250',
        hostname: 'Mock Quarantined Device',
        totalUploadBytes: 1960837,
        totalDownloadBytes: 192020,
        staticIpAddress: '10.0.0.250',
        status: 'blocked',
        quarantined: true,
        icon: 'router',
        scheduledBlock: false,
        scheduleUntil: '',
      );
      return ({record.mac: record}, {record.ip: record});
    }

    Future<
      (Map<String, OpenwallaDeviceRecord>, Map<String, OpenwallaDeviceRecord>)
    >
    readFor({model.Router? router, String? sysauth, bool? useHttps}) async {
      final where = activeOnly
          ? " WHERE status != 'offline' OR quarantined = 1"
          : "";
      final sqlWithStatic =
          "SELECT mac, ip, hostname, total_up, total_down, static_ip, status, quarantined, icon, scheduled_block, schedule_until FROM devices$where ORDER BY last_seen DESC;";
      final sqlWithoutSchedule =
          "SELECT mac, ip, hostname, total_up, total_down, static_ip, status, quarantined, icon FROM devices$where ORDER BY last_seen DESC;";
      final sqlWithoutIcon =
          "SELECT mac, ip, hostname, total_up, total_down, static_ip, status, quarantined, '' FROM devices$where ORDER BY last_seen DESC;";
      final sqlFallback =
          "SELECT mac, ip, hostname, total_up, total_down, '', status, quarantined, '' FROM devices$where ORDER BY last_seen DESC;";
      try {
        final output = router == null || sysauth == null || useHttps == null
            ? await _sqliteQueryOutput(
                dbExpression: _devicesDbExpression(),
                sql: sqlWithStatic,
                context: context,
              )
            : await _sqliteQueryOutputForRouter(
                router: router,
                sysauth: sysauth,
                useHttps: useHttps,
                dbExpression: _devicesDbExpression(),
                sql: sqlWithStatic,
              );
        return _parseDeviceRecordsOutput(output);
      } catch (_) {
        try {
          final output = router == null || sysauth == null || useHttps == null
              ? await _sqliteQueryOutput(
                  dbExpression: _devicesDbExpression(),
                  sql: sqlWithoutSchedule,
                )
              : await _sqliteQueryOutputForRouter(
                  router: router,
                  sysauth: sysauth,
                  useHttps: useHttps,
                  dbExpression: _devicesDbExpression(),
                  sql: sqlWithoutSchedule,
                );
          return _parseDeviceRecordsOutput(output);
        } catch (_) {
          try {
            final output = router == null || sysauth == null || useHttps == null
                ? await _sqliteQueryOutput(
                    dbExpression: _devicesDbExpression(),
                    sql: sqlWithoutIcon,
                  )
                : await _sqliteQueryOutputForRouter(
                    router: router,
                    sysauth: sysauth,
                    useHttps: useHttps,
                    dbExpression: _devicesDbExpression(),
                    sql: sqlWithoutIcon,
                  );
            return _parseDeviceRecordsOutput(output);
          } catch (_) {
            final output = router == null || sysauth == null || useHttps == null
                ? await _sqliteQueryOutput(
                    dbExpression: _devicesDbExpression(),
                    sql: sqlFallback,
                  )
                : await _sqliteQueryOutputForRouter(
                    router: router,
                    sysauth: sysauth,
                    useHttps: useHttps,
                    dbExpression: _devicesDbExpression(),
                    sql: sqlFallback,
                  );
            return _parseDeviceRecordsOutput(output);
          }
        }
      }
    }

    if (!aggregateAllRouters) {
      try {
        return await readFor();
      } catch (e, stack) {
        Logger.debug('Optional devices DB record read failed: $e');
        Logger.debug('Optional devices DB record stack: $stack');
        return (
          <String, OpenwallaDeviceRecord>{},
          <String, OpenwallaDeviceRecord>{},
        );
      }
    }

    final routers = _routerService?.routers ?? const <model.Router>[];
    if (routers.isEmpty || _apiService == null) {
      return (
        <String, OpenwallaDeviceRecord>{},
        <String, OpenwallaDeviceRecord>{},
      );
    }

    final byMac = <String, OpenwallaDeviceRecord>{};
    final byIp = <String, OpenwallaDeviceRecord>{};
    final tasks = routers.map((router) async {
      try {
        String? token;
        var useHttps = router.useHttps;
        if (_apiService is RealApiService) {
          final real = _apiService as RealApiService;
          final login = await real.loginWithProtocolDetection(
            router.ipAddress,
            router.username,
            router.password,
            router.useHttps,
          );
          token = login.token;
          useHttps = login.actualUseHttps;
        } else {
          token = _authService?.sysauth;
        }
        if (token == null) {
          return (
            <String, OpenwallaDeviceRecord>{},
            <String, OpenwallaDeviceRecord>{},
          );
        }
        return await readFor(
          router: router,
          sysauth: token,
          useHttps: useHttps,
        );
      } catch (e, stack) {
        Logger.debug('Optional aggregated devices DB record read failed: $e');
        Logger.debug('Optional aggregated devices DB record stack: $stack');
        return (
          <String, OpenwallaDeviceRecord>{},
          <String, OpenwallaDeviceRecord>{},
        );
      }
    }).toList();

    final results = await Future.wait(tasks);
    for (final maps in results) {
      byMac.addAll(maps.$1);
      byIp.addAll(maps.$2);
    }
    return (byMac, byIp);
  }

  List<Client> _clientsFromDeviceDbRecords(
    (Map<String, OpenwallaDeviceRecord>, Map<String, OpenwallaDeviceRecord>)
    deviceRecords,
  ) {
    final clients = deviceRecords.$1.values.map((record) {
      final hostname = record.hostname.trim();
      final ip = record.ip.trim();
      return Client(
        ipAddress: ip.isEmpty ? 'N/A' : ip,
        macAddress: record.mac,
        hostname: hostname.isEmpty ? 'Unknown' : hostname,
        connectionType: ConnectionType.unknown,
        isBlocked:
            record.quarantined ||
            record.status == 'blocked' ||
            record.status == 'block-scheduled' ||
            record.scheduledBlock,
        totalUploadBytes: record.totalUploadBytes,
        totalDownloadBytes: record.totalDownloadBytes,
        staticIpAddress: record.staticIpAddress.isEmpty
            ? null
            : record.staticIpAddress,
        status: record.quarantined
            ? 'blocked'
            : record.scheduledBlock
            ? 'block-scheduled'
            : record.status,
        deviceIcon: record.icon.isEmpty ? null : record.icon,
        scheduledBlockUntil: record.scheduleUntil.isEmpty
            ? null
            : record.scheduleUntil,
      );
    }).toList();

    clients.sort((a, b) {
      if (a.isBlocked != b.isBlocked) return a.isBlocked ? -1 : 1;
      return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
    });
    return clients;
  }

  Future<List<LiveDeviceTrafficCounter>> fetchLiveDeviceTrafficCounters({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return [
        LiveDeviceTrafficCounter(
          ip: '10.0.0.21',
          mac: '60:1D:9D:A9:1D:25',
          downloadBytes: 300000000 + (now * 180000),
          uploadBytes: 12000000 + (now * 12000),
        ),
        LiveDeviceTrafficCounter(
          ip: '10.0.0.42',
          mac: '96:72:CC:DC:FA:66',
          downloadBytes: 160000000 + (now * 92000),
          uploadBytes: 9000000 + (now * 8500),
        ),
        LiveDeviceTrafficCounter(
          ip: '10.0.0.77',
          mac: 'AA:BB:CC:DD:EE:77',
          downloadBytes: 60000000 + (now * 14000),
          uploadBytes: 5000000 + (now * 4000),
        ),
      ];
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/usr/bin/openwalla-device-traffic-summary',
          'params': const [],
        },
        context: context,
      );
      return _parseLiveDeviceTrafficCounters(_commandOutput(result));
    } catch (e, stack) {
      Logger.warning('Optional live device traffic fetch failed: $e');
      Logger.debug('Optional live device traffic stack: $stack');
      return const [];
    }
  }

  List<LiveDeviceTrafficCounter> _parseLiveDeviceTrafficCounters(
    String output,
  ) {
    final trimmed = output.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('[')) return const [];

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((row) {
            return LiveDeviceTrafficCounter(
              ip: row['ip']?.toString() ?? '',
              mac: _normalizeMacAddress(row['mac']?.toString() ?? ''),
              downloadBytes: _asInt(row['rx_bytes']),
              uploadBytes: _asInt(row['tx_bytes']),
            );
          })
          .where((row) => row.ip.isNotEmpty)
          .toList();
    } catch (e, stack) {
      Logger.debug('Unable to parse live device traffic output: $e');
      Logger.debug('Live device traffic parse stack: $stack');
      return const [];
    }
  }

  Future<bool> _sqliteTableExists({
    required String dbExpression,
    required String tableName,
    BuildContext? context,
  }) async {
    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return false;
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/bin/sh',
          'params': ['-c', _sqliteTableExistsCommand(dbExpression, tableName)],
        },
        context: context,
      );
      return _commandOutput(result).trim() == tableName;
    } catch (e, stack) {
      Logger.debug('Optional sqlite table check failed: $e');
      Logger.debug('Optional sqlite table check stack: $stack');
      return false;
    }
  }

  String _connectionFlowWhereClause(String? protocolFilter) {
    switch (protocolFilter?.toUpperCase()) {
      case 'HTTP':
        return "WHERE protocol = 'HTTP' OR destination LIKE '%:80'";
      case 'HTTPS':
        return "WHERE protocol = 'HTTPS' OR destination LIKE '%:443'";
      case 'DNS':
        return "WHERE protocol = 'DNS' OR destination LIKE '%:53'";
      default:
        return '';
    }
  }

  String _netifyRawWhereClause(String? protocolFilter, {int? hoursBack}) {
    final conditions = <String>[];
    final safeHours = hoursBack?.clamp(1, 168).toInt();
    if (safeHours != null) {
      conditions.add(
        "timeinsert >= strftime('%s','now') - ${safeHours * 3600}",
      );
    }

    return conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
  }

  bool _matchesNetifyProtocol(NetifyFlow flow, String? protocolFilter) {
    final normalized = protocolFilter?.trim().toUpperCase();
    if (normalized == null || normalized.isEmpty) return true;

    final protocol = flow.protocol.trim().toUpperCase();
    final port = flow.destinationPort.trim();
    return switch (normalized) {
      'HTTP' => protocol == 'HTTP' || port == '80',
      'HTTPS' => protocol == 'HTTP/S' || protocol == 'HTTPS' || port == '443',
      'DNS' => protocol == 'DNS' || port == '53',
      _ => true,
    };
  }

  Future<int> fetchNetifyFlowCount({
    String? protocolFilter,
    int? hoursBack,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return 315188;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) return 0;

    try {
      if (protocolFilter != null && protocolFilter.trim().isNotEmpty) {
        return await _fetchFilteredNetifyFlowCount(
          protocolFilter: protocolFilter,
          hoursBack: hoursBack,
          context: context,
        );
      }
      final output = await _sqliteQueryOutput(
        dbExpression: _netifyDbExpression(),
        sql:
            'SELECT COUNT(*) FROM flow_raw ${_netifyRawWhereClause(null, hoursBack: hoursBack)};',
        context: context,
      );
      return _parseSqliteCount(output);
    } catch (e, stack) {
      Logger.warning('Optional Netify raw flow count fetch failed: $e');
      Logger.debug('Optional Netify raw flow count stack: $stack');
      return 0;
    }
  }

  Future<OpenwallaFlowProvider> detectFlowProvider({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return OpenwallaFlowProvider.netify;

    final hasNetify = await _sqliteTableExists(
      dbExpression: _netifyDbExpression(),
      tableName: 'flow_raw',
      context: context,
    );
    if (hasNetify) return OpenwallaFlowProvider.netify;

    final hasConntrack = await _sqliteTableExists(
      dbExpression: _connectionFlowsDbExpression(),
      tableName: 'connection_flows',
    );
    if (hasConntrack) return OpenwallaFlowProvider.conntrack;

    return OpenwallaFlowProvider.none;
  }

  Future<OpenwallaFlowSummary> fetchOpenwallaFlowSummary({
    String? protocolFilter,
    int? hoursBack,
    OpenwallaFlowProvider? provider,
    BuildContext? context,
  }) async {
    final selectedProvider =
        provider ?? await detectFlowProvider(context: context);
    switch (selectedProvider) {
      case OpenwallaFlowProvider.netify:
        final hasNetify = _reviewerModeEnabled
            ? true
            : await _sqliteTableExists(
                dbExpression: _netifyDbExpression(),
                tableName: 'flow_raw',
              );
        if (!hasNetify) return OpenwallaFlowSummary.none;
        return OpenwallaFlowSummary(
          provider: selectedProvider,
          count: await fetchNetifyFlowCount(
            protocolFilter: protocolFilter,
            hoursBack: hoursBack,
          ),
        );
      case OpenwallaFlowProvider.conntrack:
        final hasConntrack = _reviewerModeEnabled
            ? true
            : await _sqliteTableExists(
                dbExpression: _connectionFlowsDbExpression(),
                tableName: 'connection_flows',
              );
        if (!hasConntrack) return OpenwallaFlowSummary.none;
        return OpenwallaFlowSummary(
          provider: selectedProvider,
          count: await fetchConnectionFlowCount(protocolFilter: protocolFilter),
        );
      case OpenwallaFlowProvider.none:
        return OpenwallaFlowSummary.none;
    }
  }

  Future<int> fetchConnectionFlowCount({
    String? protocolFilter,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return 1704;

    try {
      final output = await _sqliteQueryOutput(
        dbExpression: _connectionFlowsDbExpression(),
        sql:
            'SELECT COUNT(*) FROM connection_flows ${_connectionFlowWhereClause(protocolFilter)};',
        context: context,
      );
      return _parseSqliteCount(output);
    } catch (e, stack) {
      Logger.warning('Optional connection flow count fetch failed: $e');
      Logger.debug('Optional connection flow count stack: $stack');
      return 0;
    }
  }

  int _parseSqliteCount(String output) {
    final countText = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => RegExp(r'^\d+$').hasMatch(line))
        .lastOrNull;
    return int.tryParse(countText ?? '') ?? 0;
  }

  List<OpenwrtFirewallRule> _mockFirewallRules() {
    return const [
      OpenwrtFirewallRule(
        section: 'cfg0a92bd',
        name: 'owrt_block_unknown_device',
        source: 'lan',
        sourceIp: 'Any',
        destination: 'wan',
        protocol: 'all',
        port: 'Any',
        action: 'REJECT',
        enabled: true,
      ),
      OpenwrtFirewallRule(
        section: 'cfg0b31ac',
        name: 'owrt_allow_dns',
        source: 'lan',
        sourceIp: 'Any',
        destination: 'Any',
        protocol: 'udp',
        port: '53',
        action: 'ACCEPT',
        enabled: true,
      ),
      OpenwrtFirewallRule(
        section: 'cfg0c77aa',
        name: 'Allow-SSH-LAN',
        source: 'lan',
        sourceIp: 'Any',
        destination: 'device',
        protocol: 'tcp',
        port: '22',
        action: 'ACCEPT',
        enabled: true,
      ),
    ];
  }

  Map<dynamic, dynamic> _firewallValuesFromResult(dynamic result) {
    final data = _extractRpcData(result);
    if (data is Map && data['values'] is Map) {
      return data['values'] as Map<dynamic, dynamic>;
    }
    if (data is Map) return data;
    return const {};
  }

  List<OpenwrtFirewallRule> _parseFirewallRules(dynamic result) {
    final values = _firewallValuesFromResult(result);
    final rules = values.entries
        .where((entry) {
          final value = entry.value;
          return value is Map && value['.type'] == 'rule';
        })
        .map(
          (entry) => OpenwrtFirewallRule.fromUciSection(
            entry.key.toString(),
            entry.value as Map<dynamic, dynamic>,
          ),
        )
        .toList();

    rules.sort((a, b) {
      if (a.isOpenwallaRule != b.isOpenwallaRule) {
        return a.isOpenwallaRule ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return rules;
  }

  Future<List<OpenwrtFirewallRule>> fetchFirewallRules({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return _mockFirewallRules();

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'firewall'},
        context: context,
      );
      return _parseFirewallRules(result);
    } catch (e, stack) {
      Logger.warning('Optional firewall rules fetch failed: $e');
      Logger.debug('Optional firewall rules stack: $stack');
      return const [];
    }
  }

  Future<int> fetchFirewallRuleCount({BuildContext? context}) async {
    if (_reviewerModeEnabled) return _mockFirewallRules().length;
    final rules = await fetchFirewallRules(context: context);
    return rules.length;
  }

  List<OpenwrtPortForward> _mockPortForwards() {
    return const [
      OpenwrtPortForward(
        section: 'cfg0fredirect',
        name: 'Plex',
        source: 'wan',
        wanPort: '32400',
        protocol: 'tcp',
        destinationZone: 'lan',
        destinationIp: '10.0.0.25',
        destinationPort: '32400',
        enabled: true,
      ),
      OpenwrtPortForward(
        section: 'cfg10redirect',
        name: 'Game Console',
        source: 'wan',
        wanPort: '3074',
        protocol: 'udp',
        destinationZone: 'lan',
        destinationIp: '10.0.0.55',
        destinationPort: '3074',
        enabled: false,
      ),
    ];
  }

  Future<List<OpenwrtPortForward>> fetchPortForwards({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return _mockPortForwards();

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'firewall'},
        context: context,
      );
      final values = _firewallValuesFromResult(result);
      final forwards = values.entries
          .where((entry) {
            final value = entry.value;
            return value is Map && value['.type'] == 'redirect';
          })
          .map(
            (entry) => OpenwrtPortForward.fromUciSection(
              entry.key.toString(),
              entry.value as Map<dynamic, dynamic>,
            ),
          )
          .toList();
      forwards.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      return forwards;
    } catch (e, stack) {
      Logger.warning('Optional port forwards fetch failed: $e');
      Logger.debug('Optional port forwards stack: $stack');
      return const [];
    }
  }

  Future<void> addPortForward({
    required String name,
    required String sourceZone,
    required String externalPort,
    required String protocol,
    required String destinationZone,
    required String destinationIp,
    required String internalPort,
  }) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    final addResult = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'add',
      params: {'config': 'firewall', 'type': 'redirect'},
    );
    final section = _extractAddedSection(addResult);
    if (section == null || section.isEmpty) {
      throw StateError('Unable to create port forward section');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'firewall',
      section: section,
      values: {
        'name': name.trim(),
        'src': sourceZone.trim(),
        'src_dport': externalPort.trim(),
        'proto': protocol.trim(),
        'dest': destinationZone.trim(),
        'dest_ip': destinationIp.trim(),
        'dest_port': internalPort.trim(),
        'target': 'DNAT',
      },
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'firewall',
    );
    await _reloadFirewall(router, sysauth);
    notifyListeners();
  }

  Future<void> updatePortForward(
    OpenwrtPortForward forward, {
    required String name,
    required String sourceZone,
    required String externalPort,
    required String protocol,
    required String destinationZone,
    required String destinationIp,
    required String internalPort,
  }) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'firewall',
      section: forward.section,
      values: {
        'name': name.trim(),
        'src': sourceZone.trim(),
        'src_dport': externalPort.trim(),
        'proto': protocol.trim(),
        'dest': destinationZone.trim(),
        'dest_ip': destinationIp.trim(),
        'dest_port': internalPort.trim(),
        'target': 'DNAT',
      },
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'firewall',
    );
    await _reloadFirewall(router, sysauth);
    notifyListeners();
  }

  List<OpenwrtFirewallZone> _mockFirewallZones() {
    return const [
      OpenwrtFirewallZone(
        section: 'lan',
        name: 'lan',
        networks: 'lan',
        input: 'ACCEPT',
        output: 'ACCEPT',
        forward: 'ACCEPT',
        masquerading: false,
        mtuFix: false,
      ),
      OpenwrtFirewallZone(
        section: 'wan',
        name: 'wan',
        networks: 'wan, wan6',
        input: 'REJECT',
        output: 'ACCEPT',
        forward: 'REJECT',
        masquerading: true,
        mtuFix: true,
      ),
    ];
  }

  Future<List<OpenwrtFirewallZone>> fetchFirewallZones({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return _mockFirewallZones();

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'firewall'},
        context: context,
      );
      final values = _firewallValuesFromResult(result);
      final zones = values.entries
          .where((entry) {
            final value = entry.value;
            return value is Map && value['.type'] == 'zone';
          })
          .map(
            (entry) => OpenwrtFirewallZone.fromUciSection(
              entry.key.toString(),
              entry.value as Map<dynamic, dynamic>,
            ),
          )
          .toList();
      zones.sort((a, b) {
        if (a.name == 'lan' && b.name != 'lan') return -1;
        if (b.name == 'lan' && a.name != 'lan') return 1;
        if (a.name == 'wan' && b.name != 'wan') return -1;
        if (b.name == 'wan' && a.name != 'wan') return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return zones;
    } catch (e, stack) {
      Logger.warning('Optional firewall zones fetch failed: $e');
      Logger.debug('Optional firewall zones stack: $stack');
      return const [];
    }
  }

  Future<void> setFirewallRuleEnabled(
    OpenwrtFirewallRule rule,
    bool enabled,
  ) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'firewall',
      section: rule.section,
      values: {'enabled': enabled ? '1' : '0'},
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'firewall',
    );
    await _reloadFirewall(router, sysauth);
    notifyListeners();
  }

  Future<void> deleteFirewallRule(OpenwrtFirewallRule rule) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'delete',
      params: {'config': 'firewall', 'section': rule.section},
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'firewall',
    );
    await _reloadFirewall(router, sysauth);
    notifyListeners();
  }

  Future<void> _reloadFirewall(model.Router router, String sysauth) async {
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command:
          '/etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null || true',
    );
  }

  List<OpenwrtStaticRoute> _mockStaticRoutes() {
    return const [
      OpenwrtStaticRoute(
        section: 'route_openwalla_lab',
        interfaceName: 'lan',
        routeType: 'unicast',
        target: '10.20.30.0/24',
        netmask: '',
        gateway: '172.31.1.2',
        metric: '10',
        enabled: true,
      ),
    ];
  }

  Future<List<OpenwrtStaticRoute>> fetchStaticRoutes({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return _mockStaticRoutes();

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'network'},
        context: context,
      );
      final values = _extractUciValues(result);
      final routes =
          values.entries
              .where((entry) => entry.value['.type']?.toString() == 'route')
              .map(
                (entry) =>
                    OpenwrtStaticRoute.fromUciSection(entry.key, entry.value),
              )
              .toList()
            ..sort(
              (a, b) => a.interfaceName.toLowerCase().compareTo(
                b.interfaceName.toLowerCase(),
              ),
            );
      return routes;
    } catch (e, stack) {
      Logger.warning('Optional static routes fetch failed: $e');
      Logger.debug('Optional static routes stack: $stack');
      return const [];
    }
  }

  Future<void> addStaticRoute({
    required String interfaceName,
    required String routeType,
    required String target,
    required String gateway,
    String metric = '',
  }) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    final addResult = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'add',
      params: {'config': 'network', 'type': 'route'},
    );
    final section = _extractAddedSection(addResult);
    if (section == null || section.isEmpty) {
      throw StateError('Unable to create route section');
    }

    final values = <String, String>{
      'interface': interfaceName,
      'type': routeType,
      'target': target,
    };
    if (gateway.trim().isNotEmpty) values['gateway'] = gateway.trim();
    if (metric.trim().isNotEmpty) values['metric'] = metric.trim();

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'network',
      section: section,
      values: values,
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'network',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command: '/etc/init.d/network reload 2>/dev/null || ifup $interfaceName',
    );
    notifyListeners();
  }

  List<OpenwrtSqmQueue> _mockSqmQueues() {
    return const [
      OpenwrtSqmQueue(
        section: 'queue',
        enabled: true,
        interfaceName: 'eth1',
        downloadKbps: 85000,
        uploadKbps: 10000,
        qdisc: 'cake',
        script: 'piece_of_cake.qos',
        debugLogging: false,
        verbosity: '5',
      ),
    ];
  }

  Future<List<OpenwrtSqmQueue>> fetchSqmQueues({BuildContext? context}) async {
    if (_reviewerModeEnabled) return _mockSqmQueues();

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'sqm'},
        context: context,
      );
      final values = _extractUciValues(result);
      return values.entries
          .where((entry) => entry.value['.type']?.toString() == 'queue')
          .map(
            (entry) => OpenwrtSqmQueue.fromUciSection(entry.key, entry.value),
          )
          .toList();
    } catch (e, stack) {
      Logger.warning('Optional SQM fetch failed: $e');
      Logger.debug('Optional SQM stack: $stack');
      return const [];
    }
  }

  Future<void> saveSqmQueue(OpenwrtSqmQueue queue) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    var section = queue.section;
    if (section.isEmpty) {
      final addResult = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'add',
        params: {'config': 'sqm', 'type': 'queue'},
      );
      section = _extractAddedSection(addResult) ?? '';
      if (section.isEmpty) throw StateError('Unable to create SQM queue');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'sqm',
      section: section,
      values: {
        'enabled': queue.enabled ? '1' : '0',
        'interface': queue.interfaceName,
        'download': queue.downloadKbps.toString(),
        'upload': queue.uploadKbps.toString(),
        'qdisc': queue.qdisc,
        'script': queue.script,
        'debug_logging': queue.debugLogging ? '1' : '0',
        'verbosity': queue.verbosity,
      },
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'sqm',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command: '/etc/init.d/sqm restart 2>/dev/null || true',
    );
    notifyListeners();
  }

  List<OpenwrtDnsHostEntry> _mockDnsHostEntries() {
    return const [
      OpenwrtDnsHostEntry(
        section: 'cfg_dns_camera',
        hostname: 'camera.local',
        ipAddress: '10.0.0.50',
      ),
      OpenwrtDnsHostEntry(
        section: 'cfg_dns_nas',
        hostname: 'nas.local',
        ipAddress: '10.0.0.20',
      ),
    ];
  }

  Future<List<OpenwrtDnsHostEntry>> fetchDnsHostEntries({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return _mockDnsHostEntries();

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'dhcp'},
        context: context,
      );
      final values = _extractUciValues(result);
      final entries =
          values.entries
              .where((entry) => entry.value['.type']?.toString() == 'domain')
              .map(
                (entry) =>
                    OpenwrtDnsHostEntry.fromUciSection(entry.key, entry.value),
              )
              .where(
                (entry) =>
                    entry.hostname.trim().isNotEmpty ||
                    entry.ipAddress.trim().isNotEmpty,
              )
              .toList()
            ..sort(
              (a, b) =>
                  a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase()),
            );
      return entries;
    } catch (e, stack) {
      Logger.warning('Optional DNS host entries fetch failed: $e');
      Logger.debug('Optional DNS host entries stack: $stack');
      return const [];
    }
  }

  Future<void> saveDnsHostEntry(OpenwrtDnsHostEntry entry) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    var section = entry.section.trim();
    if (section.isEmpty) {
      final addResult = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'add',
        params: {'config': 'dhcp', 'type': 'domain'},
      );
      section = _extractAddedSection(addResult) ?? '';
      if (section.isEmpty) throw StateError('Unable to create DNS entry');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'dhcp',
      section: section,
      values: {'name': entry.hostname.trim(), 'ip': entry.ipAddress.trim()},
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'dhcp',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command: '/etc/init.d/dnsmasq restart 2>/dev/null || true',
    );
    notifyListeners();
  }

  Future<void> deleteDnsHostEntry(String section) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'delete',
      params: {'config': 'dhcp', 'section': section},
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'dhcp',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command: '/etc/init.d/dnsmasq restart 2>/dev/null || true',
    );
    notifyListeners();
  }

  OpenwrtAdblockSettings _mockAdblockSettings() {
    return const OpenwrtAdblockSettings(
      section: 'global',
      installed: true,
      enabled: true,
      safeSearch: false,
      reportEnabled: true,
      triggerInterface: 'wan',
      dnsBackend: 'dnsmasq',
      selectedFeeds: ['adguard', 'adguard_tracking', 'certpl'],
      serviceStatus: 'running',
    );
  }

  Future<OpenwrtAdblockSettings> fetchAdblockSettings({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return _mockAdblockSettings();

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const OpenwrtAdblockSettings(
        section: 'global',
        installed: false,
        enabled: false,
        safeSearch: false,
        reportEnabled: false,
        triggerInterface: 'wan',
        dnsBackend: 'dnsmasq',
        selectedFeeds: [],
        serviceStatus: 'Not connected',
      );
    }

    String statusText = 'unknown';
    var installed = false;
    try {
      final statusResult = await _apiService!.systemExec(
        router.ipAddress,
        sysauth,
        router.useHttps,
        command:
            '[ -x /etc/init.d/adblock ] && /etc/init.d/adblock status 2>&1 || echo "__OPENWALLA_ADBLOCK_MISSING__"',
      );
      final data = _extractRpcData(statusResult);
      final stdout = data is Map ? data['stdout']?.toString().trim() : '';
      statusText = stdout == null || stdout.isEmpty ? 'unknown' : stdout;
      installed = !statusText.contains('__OPENWALLA_ADBLOCK_MISSING__');
      if (!installed) statusText = 'AdBlock package is not installed';
    } catch (e) {
      Logger.warning('Optional AdBlock status fetch failed: $e');
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'adblock'},
      );
      final values = _extractUciValues(result);
      final entry =
          values.entries
              .where((entry) => entry.value['.type']?.toString() == 'adblock')
              .firstOrNull ??
          values.entries
              .where((entry) => entry.value.containsKey('adb_enabled'))
              .firstOrNull;
      if (entry == null) {
        return OpenwrtAdblockSettings(
          section: 'global',
          installed: installed,
          enabled: false,
          safeSearch: false,
          reportEnabled: false,
          triggerInterface: 'wan',
          dnsBackend: 'dnsmasq',
          selectedFeeds: const [],
          serviceStatus: statusText,
        );
      }
      return OpenwrtAdblockSettings.fromUciSection(
        entry.key,
        entry.value,
        installed: installed,
        serviceStatus: statusText,
      );
    } catch (e, stack) {
      Logger.warning('Optional AdBlock config fetch failed: $e');
      Logger.debug('Optional AdBlock config stack: $stack');
      return OpenwrtAdblockSettings(
        section: 'global',
        installed: installed,
        enabled: false,
        safeSearch: false,
        reportEnabled: false,
        triggerInterface: 'wan',
        dnsBackend: 'dnsmasq',
        selectedFeeds: const [],
        serviceStatus: statusText,
      );
    }
  }

  Future<void> saveAdblockSettings(OpenwrtAdblockSettings settings) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    var section = settings.section.trim().isEmpty ? 'global' : settings.section;
    try {
      await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'adblock', 'section': section},
      );
    } catch (_) {
      final addResult = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'add',
        params: {'config': 'adblock', 'type': 'adblock', 'name': 'global'},
      );
      section = _extractAddedSection(addResult) ?? section;
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'adblock',
      section: section,
      values: {
        'adb_enabled': settings.enabled ? '1' : '0',
        'adb_safesearch': settings.safeSearch ? '1' : '0',
        'adb_report': settings.reportEnabled ? '1' : '0',
        'adb_trigger': settings.triggerInterface.trim().isEmpty
            ? 'wan'
            : settings.triggerInterface.trim(),
        'adb_dns': settings.dnsBackend.trim().isEmpty
            ? 'dnsmasq'
            : settings.dnsBackend.trim(),
      },
    );
    final feedCommands = <String>[
      'uci -q delete adblock.$section.adb_feed',
      for (final feed in settings.selectedFeeds)
        if (RegExp(r'^[A-Za-z0-9_+-]+$').hasMatch(feed))
          "uci add_list adblock.$section.adb_feed='$feed'",
    ];
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command: feedCommands.join('; '),
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'adblock',
    );

    final command = settings.enabled
        ? '/etc/init.d/adblock enable 2>/dev/null; /etc/init.d/adblock reload 2>/dev/null || /etc/init.d/adblock restart 2>/dev/null || true'
        : '/etc/init.d/adblock stop 2>/dev/null; /etc/init.d/adblock disable 2>/dev/null || true';
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command: command,
    );
    notifyListeners();
  }

  Future<void> runAdblockServiceAction(String action) async {
    const allowed = {'start', 'stop', 'restart', 'reload', 'suspend', 'resume'};
    if (!allowed.contains(action)) {
      throw ArgumentError.value(action, 'action', 'Unsupported AdBlock action');
    }
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command: '/etc/init.d/adblock $action 2>/dev/null || true',
    );
    notifyListeners();
  }

  Future<OpenwrtNetworkInterfaceConfig?> fetchNetworkInterfaceConfig(
    String interfaceName, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return OpenwrtNetworkInterfaceConfig(
        section: interfaceName,
        interfaceName: interfaceName,
        protocol: interfaceName.toLowerCase() == 'wan' ? 'dhcp' : 'static',
        ipAddress: interfaceName.toLowerCase() == 'wan' ? '' : '192.168.10.1',
        netmask: interfaceName.toLowerCase() == 'wan' ? '' : '255.255.255.0',
        dnsServers: const ['1.1.1.1', '8.8.8.8'],
        dhcpSection: interfaceName.toLowerCase() == 'wan'
            ? null
            : interfaceName,
        dhcpEnabled: interfaceName.toLowerCase() != 'wan',
        dhcpStart: 100,
        dhcpLimit: 150,
        leaseTime: '12h',
      );
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return null;
    }

    final networkResult = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'get',
      params: {'config': 'network'},
      context: context,
    );
    final dhcpResult = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'get',
      params: {'config': 'dhcp'},
    );

    final networkValues = _extractUciValues(networkResult);
    final dhcpValues = _extractUciValues(dhcpResult);
    final normalized = interfaceName.toLowerCase();

    final networkEntry = networkValues.entries.where((entry) {
      return entry.key.toLowerCase() == normalized &&
          entry.value['.type']?.toString() == 'interface';
    }).firstOrNull;
    if (networkEntry == null) return null;

    final dhcpEntry = dhcpValues.entries.where((entry) {
      final value = entry.value;
      if (value['.type']?.toString() != 'dhcp') return false;
      final iface = value['interface']?.toString().toLowerCase();
      return entry.key.toLowerCase() == normalized || iface == normalized;
    }).firstOrNull;

    String stringValue(Map<String, dynamic> values, String key) {
      final value = values[key];
      if (value is List) {
        return value.map((entry) => entry.toString()).join(' ');
      }
      return value?.toString() ?? '';
    }

    int intValue(Map<String, dynamic>? values, String key, int fallback) {
      return int.tryParse(values?[key]?.toString() ?? '') ?? fallback;
    }

    final network = networkEntry.value;
    final dhcp = dhcpEntry?.value;
    final dnsText = stringValue(network, 'dns').trim();

    return OpenwrtNetworkInterfaceConfig(
      section: networkEntry.key,
      interfaceName: interfaceName,
      protocol: stringValue(network, 'proto').trim().isEmpty
          ? 'static'
          : stringValue(network, 'proto').trim(),
      ipAddress: stringValue(network, 'ipaddr').trim(),
      netmask: stringValue(network, 'netmask').trim(),
      dnsServers: dnsText.isEmpty ? const [] : dnsText.split(RegExp(r'\s+')),
      dhcpSection: dhcpEntry?.key,
      dhcpEnabled: dhcp == null ? false : dhcp['ignore']?.toString() != '1',
      dhcpStart: intValue(dhcp, 'start', 100),
      dhcpLimit: intValue(dhcp, 'limit', 150),
      leaseTime: dhcp?['leasetime']?.toString() ?? '12h',
    );
  }

  Future<void> saveNetworkInterfaceConfig(
    OpenwrtNetworkInterfaceConfig config, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    final networkValues = <String, String>{
      'proto': config.protocol,
      'ipaddr': config.ipAddress,
      'netmask': config.netmask,
    };
    if (config.dnsServers.isNotEmpty) {
      networkValues['dns'] = config.dnsServers.join(' ');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'network',
      section: config.section,
      values: networkValues,
      context: context,
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'network',
    );

    var dhcpSection = config.dhcpSection;
    if (dhcpSection == null || dhcpSection.isEmpty) {
      final addResult = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'add',
        params: {'config': 'dhcp', 'type': 'dhcp'},
      );
      dhcpSection = _extractAddedSection(addResult);
    }

    if (dhcpSection != null && dhcpSection.isNotEmpty) {
      await _apiService!.uciSet(
        router.ipAddress,
        sysauth,
        router.useHttps,
        config: 'dhcp',
        section: dhcpSection,
        values: {
          'interface': config.interfaceName,
          'ignore': config.dhcpEnabled ? '0' : '1',
          'start': config.dhcpStart.toString(),
          'limit': config.dhcpLimit.toString(),
          'leasetime': config.leaseTime,
        },
      );
      await _apiService!.uciCommit(
        router.ipAddress,
        sysauth,
        router.useHttps,
        config: 'dhcp',
      );
    }

    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command:
          '/etc/init.d/network reload 2>/dev/null; /etc/init.d/dnsmasq restart 2>/dev/null || true',
    );
    notifyListeners();
  }

  Future<OpenwrtWirelessNetworkConfig?> fetchWirelessNetworkConfig(
    String section, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return OpenwrtWirelessNetworkConfig(
        section: section,
        radioSection: 'radio0',
        ssid: 'Openwalla',
        password: 'openwalla-demo',
        encryption: 'psk2',
        enabled: true,
        hidden: false,
        txPower: 20,
      );
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return null;
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'wireless'},
        context: context,
      );
      final values = _extractUciValues(result);
      final ifaceValues = values[section];
      if (ifaceValues == null ||
          ifaceValues['.type']?.toString() != 'wifi-iface') {
        return null;
      }
      final radioSection = ifaceValues['device']?.toString() ?? '';
      return OpenwrtWirelessNetworkConfig.fromUciSection(
        section,
        ifaceValues,
        radioValues: values[radioSection],
      );
    } catch (e, stack) {
      Logger.warning('Optional wireless config fetch failed: $e');
      Logger.debug('Optional wireless config stack: $stack');
      return null;
    }
  }

  Future<void> saveWirelessNetworkConfig(
    OpenwrtWirelessNetworkConfig config, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    final sectionPattern = RegExp(r'^[A-Za-z0-9_]+$');
    if (!sectionPattern.hasMatch(config.section)) {
      throw StateError('Unsupported wireless section: ${config.section}');
    }
    if (config.radioSection.isNotEmpty &&
        !sectionPattern.hasMatch(config.radioSection)) {
      throw StateError('Unsupported radio section: ${config.radioSection}');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'wireless',
      section: config.section,
      values: {
        'ssid': config.ssid.trim(),
        'disabled': config.enabled ? '0' : '1',
        'hidden': config.hidden ? '1' : '0',
        'encryption': config.encryption.trim().isEmpty
            ? 'psk2'
            : config.encryption.trim(),
        'key': config.password,
      },
      context: context,
    );

    if (config.radioSection.isNotEmpty) {
      await _apiService!.uciSet(
        router.ipAddress,
        sysauth,
        router.useHttps,
        config: 'wireless',
        section: config.radioSection,
        values: {
          'disabled': config.enabled ? '0' : '1',
          if (config.txPower != null) 'txpower': config.txPower!.toString(),
        },
      );
    }

    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'wireless',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command: 'wifi reload',
    );
    await fetchDashboardData();
  }

  Future<int> fetchNotificationCount({BuildContext? context}) async {
    if (_reviewerModeEnabled) return 2;

    try {
      final output = await _sqliteQueryOutput(
        dbExpression: _notificationsDbExpression(),
        sql:
            'SELECT COUNT(*) FROM notifications WHERE "delete" = 0 AND archived = 0;',
        context: context,
      );
      return _parseSqliteCount(output);
    } catch (e, stack) {
      Logger.warning('Optional notification count fetch failed: $e');
      Logger.debug('Optional notification count stack: $stack');
      return 0;
    }
  }

  Future<int> refreshNotificationCount({BuildContext? context}) async {
    final count = await fetchNotificationCount(context: context);
    if (_dashboardData != null) {
      _dashboardData = {
        ..._dashboardData!,
        'notificationCount': count,
        '_lastUpdated': DateTime.now().millisecondsSinceEpoch,
      };
      notifyListeners();
    }
    return count;
  }

  Future<void> refreshDashboardSummaryCounts({BuildContext? context}) async {
    if (_reviewerModeEnabled) {
      if (_dashboardData != null) {
        _dashboardData = {
          ..._dashboardData!,
          'notificationCount': 2,
          'rulesCount': _mockFirewallRules().length,
          '_lastUpdated': DateTime.now().millisecondsSinceEpoch,
        };
        notifyListeners();
      }
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) return;

    int? deviceCount;
    final notificationCountFuture = fetchNotificationCount(context: context);
    final rulesCountFuture = fetchFirewallRuleCount();

    try {
      final dhcpResult = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'luci-rpc',
        method: 'getDHCPLeases',
        params: {},
        context: context,
      );
      Map<String, dynamic>? dhcpLeases;
      if (dhcpResult is List && dhcpResult.length > 1 && dhcpResult[0] == 0) {
        final data = dhcpResult[1];
        if (data is Map<String, dynamic>) dhcpLeases = data;
      } else if (dhcpResult is Map<String, dynamic>) {
        dhcpLeases = dhcpResult;
      }

      final associatedMacs = await _apiService!
          .fetchAllAssociatedWirelessMacsWithContext(
            ipAddress: router.ipAddress,
            sysauth: sysauth,
            useHttps: router.useHttps,
          )
          .catchError((e, stack) {
            Logger.warning(
              'Optional summary associated station fetch failed: $e',
            );
            Logger.debug('Optional summary associated station stack: $stack');
            return <String, Set<String>>{};
          });

      deviceCount = _countRouterDevices(dhcpLeases, associatedMacs);
    } catch (e, stack) {
      Logger.warning('Optional dashboard device count refresh failed: $e');
      Logger.debug('Optional dashboard device count refresh stack: $stack');
    }

    final notificationCount = await notificationCountFuture;
    final rulesCount = await rulesCountFuture;
    if (_dashboardData != null) {
      _dashboardData = {
        ..._dashboardData!,
        if (deviceCount != null) 'deviceCount': deviceCount,
        'notificationCount': notificationCount,
        'rulesCount': rulesCount,
        '_lastUpdated': DateTime.now().millisecondsSinceEpoch,
      };
      notifyListeners();
    }
  }

  Future<List<OpenwallaNotification>> fetchNotifications({
    int limit = 200,
    bool includeArchived = false,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      final now = DateTime.now().toUtc();
      return [
        OpenwallaNotification(
          id: 1,
          timestamp: now.subtract(const Duration(minutes: 4)),
          app: 'ping-monitor',
          message: 'Ping threshold exceeded: target=1.1.1.1 latency=124ms',
          archived: false,
          deleted: false,
        ),
        OpenwallaNotification(
          id: 2,
          timestamp: now.subtract(const Duration(minutes: 12)),
          app: 'device-quarantine',
          message: 'New device quarantined mac=AA:BB:CC:DD:EE:FF',
          archived: includeArchived,
          deleted: false,
        ),
      ];
    }

    try {
      final safeLimit = limit.clamp(1, 500).toInt();
      final archivedFilter = includeArchived ? '' : ' AND archived = 0';
      final output = await _sqliteQueryOutput(
        dbExpression: _notificationsDbExpression(),
        sql:
            'SELECT id, timestamp, app, msg, archived, "delete" FROM notifications WHERE "delete" = 0$archivedFilter ORDER BY timestamp DESC LIMIT $safeLimit;',
        context: context,
      );
      return output
          .split('\n')
          .map((line) => OpenwallaNotification.fromSqliteRow(line.trim()))
          .whereType<OpenwallaNotification>()
          .toList();
    } catch (e, stack) {
      Logger.warning('Optional notifications fetch failed: $e');
      Logger.debug('Optional notifications stack: $stack');
      return const [];
    }
  }

  Future<void> archiveNotification(int id, {BuildContext? context}) async {
    if (_reviewerModeEnabled) return;
    if (id <= 0) return;

    await _sqliteQueryOutput(
      dbExpression: _notificationsDbExpression(),
      sql: 'UPDATE notifications SET archived = 1 WHERE id = $id;',
      context: context,
    );
    await refreshNotificationCount();
  }

  Future<void> archiveAllNotifications({BuildContext? context}) async {
    if (_reviewerModeEnabled) return;

    await _sqliteQueryOutput(
      dbExpression: _notificationsDbExpression(),
      sql:
          'UPDATE notifications SET archived = 1 WHERE "delete" = 0 AND archived = 0;',
      context: context,
    );
    await refreshNotificationCount();
  }

  Future<void> deleteAllNotifications({BuildContext? context}) async {
    if (_reviewerModeEnabled) return;

    await _sqliteQueryOutput(
      dbExpression: _notificationsDbExpression(),
      sql: 'UPDATE notifications SET "delete" = 1 WHERE "delete" = 0;',
      context: context,
    );
    await refreshNotificationCount();
  }

  Future<List<NetifyFlow>> fetchNetifyFlows({
    int limit = 50,
    int offset = 0,
    String? protocolFilter,
    int? hoursBack,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      final now = DateTime.now().toUtc();
      final mockFlows = List<NetifyFlow>.generate(20, (index) {
        final hosts = [
          'aws-iot.wyzecam.com',
          'm3-us.iotbing.com',
          'api.eu.amplitude.com',
          'connectivitycheck.gstatic.com',
          'unifi',
        ];
        return NetifyFlow(
          timestamp: now.subtract(Duration(minutes: index * 4)),
          deviceMac: index.isEven ? 'D0:3F:27:81:6C:17' : 'AA:12:44:9B:2D:10',
          localIp: index.isEven ? '10.0.200.225' : '10.0.0.32',
          localPort: '${33399 + index}',
          destination: hosts[index % hosts.length],
          application: hosts[index % hosts.length],
          protocol: index % 3 == 0 ? 'HTTP/S' : 'HTTP',
          destinationIp: index % 3 == 0 ? '54.69.167.88' : '142.250.72.14',
          destinationPort: index % 3 == 0 ? '8883' : '443',
          interfaceName: 'wan',
          downloadedBytes: 31 + (index * 420),
          uploadedBytes: 31 + (index * 120),
          totalBytes: 62 + (index * 540),
          countryCode: index % 3 == 0 ? 'US' : '',
          region: index % 3 == 0 ? 'United States' : '',
          direction: 'Outbound',
          rawJson: '{}',
        );
      });
      final normalized = protocolFilter?.toUpperCase();
      final filteredByProtocol = normalized == null || normalized.isEmpty
          ? mockFlows
          : mockFlows.where((flow) {
              final protocol = flow.protocol.toUpperCase();
              return switch (normalized) {
                'HTTP' => protocol == 'HTTP' || flow.destinationPort == '80',
                'HTTPS' =>
                  protocol == 'HTTP/S' ||
                      protocol == 'HTTPS' ||
                      flow.destinationPort == '443',
                'DNS' => protocol == 'DNS' || flow.destinationPort == '53',
                _ => false,
              };
            }).toList();
      final safeHours = hoursBack?.clamp(1, 168).toInt();
      if (safeHours == null) return filteredByProtocol;
      final cutoff = now.subtract(Duration(hours: safeHours));
      return filteredByProtocol
          .where((flow) => !flow.timestamp.isBefore(cutoff))
          .toList();
    }

    final safeLimit = limit.clamp(1, 1000).toInt();
    final safeOffset = offset < 0 ? 0 : offset;
    if (protocolFilter != null && protocolFilter.trim().isNotEmpty) {
      return await _fetchFilteredNetifyRawFlows(
        limit: safeLimit,
        offset: safeOffset,
        protocolFilter: protocolFilter,
        hoursBack: hoursBack,
        context: context,
      );
    }

    final netifyFlows = await _fetchNetifyRawFlows(
      limit: safeLimit,
      offset: safeOffset,
      protocolFilter: null,
      hoursBack: hoursBack,
      context: context,
    );
    return netifyFlows;
  }

  Future<List<NetifyFlow>> fetchConnectionFlows({
    int limit = 50,
    int offset = 0,
    String? protocolFilter,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return const [];
    return await _fetchConnectionFlows(
      limit: limit.clamp(1, 500).toInt(),
      offset: offset < 0 ? 0 : offset,
      protocolFilter: protocolFilter,
      context: context,
    );
  }

  Future<String> blockNetifyFlowDomain({
    required String domain,
    required bool rootDomain,
  }) async {
    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    final exactDomain = _sanitizeDomain(domain);
    if (exactDomain.isEmpty) {
      throw ArgumentError('A valid domain is required');
    }
    final targetDomain = rootDomain
        ? (_extractRootDomain(exactDomain).isEmpty
              ? exactDomain
              : _extractRootDomain(exactDomain))
        : exactDomain;

    final dhcp = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'get',
      params: {'config': 'dhcp'},
    );
    final values = _extractUciValues(dhcp);
    String? targetSection;
    values.forEach((section, cfg) {
      if (targetSection != null) return;
      if (cfg['.type']?.toString() != 'domain') return;
      if ((cfg['name']?.toString().trim().toLowerCase() ?? '') ==
          targetDomain) {
        targetSection = section;
      }
    });

    if (targetSection == null) {
      final addResult = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'add',
        params: {'config': 'dhcp', 'type': 'domain'},
      );
      targetSection = _extractAddedSection(addResult);
    }
    if (targetSection == null || targetSection!.isEmpty) {
      throw StateError('Unable to create custom DNS entry');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'dhcp',
      section: targetSection!,
      values: {'name': targetDomain, 'ip': '127.0.0.1'},
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'dhcp',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command: '/etc/init.d/dnsmasq restart',
    );
    return targetDomain;
  }

  Future<void> blockNetifyFlowDestinationIp({
    required String destinationIp,
    String? sourceIp,
    required bool wholeNetwork,
  }) async {
    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    final destIp = destinationIp.trim();
    if (!_isValidIpAddress(destIp)) {
      throw ArgumentError('A valid destination IP address is required');
    }
    final srcIp = sourceIp?.trim() ?? '';
    if (!wholeNetwork && !_isValidIpAddress(srcIp)) {
      throw ArgumentError('A valid source device IP address is required');
    }

    final addResult = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'add',
      params: {'config': 'firewall', 'type': 'rule'},
    );
    final section = _extractAddedSection(addResult);
    if (section == null || section.isEmpty) {
      throw StateError('Unable to create firewall rule section');
    }

    final values = {
      'name': _buildFlowBlockRuleName(destIp),
      'src': 'lan',
      'dest': 'wan',
      'proto': 'all',
      'dest_ip': destIp,
      'target': 'REJECT',
      'enabled': '1',
      'family': _isIpv6Address(destIp) ? 'ipv6' : 'ipv4',
    };
    if (!wholeNetwork) values['src_ip'] = srcIp;

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'firewall',
      section: section,
      values: values,
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'firewall',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command:
          '/etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null || true',
    );
  }

  Future<List<NetifyFlow>> _fetchConnectionFlows({
    required int limit,
    required int offset,
    String? protocolFilter,
    BuildContext? context,
  }) async {
    try {
      final output = await _sqliteQueryOutput(
        dbExpression: _connectionFlowsDbExpression(),
        sql:
            'SELECT id,timeinsert,protocol,source,destination,transfer,status FROM connection_flows ${_connectionFlowWhereClause(protocolFilter)} ORDER BY id DESC LIMIT $limit OFFSET $offset;',
        context: context,
      );
      return output
          .split('\n')
          .map((line) => NetifyFlow.fromConnectionFlowRow(line.trim()))
          .whereType<NetifyFlow>()
          .toList();
    } catch (e, stack) {
      Logger.warning('Optional connection flows fetch failed: $e');
      Logger.debug('Optional connection flows stack: $stack');
      return const [];
    }
  }

  Future<int> _fetchFilteredNetifyFlowCount({
    required String protocolFilter,
    int? hoursBack,
    BuildContext? context,
  }) async {
    var rawOffset = 0;
    var count = 0;
    const batchSize = 1000;
    const maxScannedRows = 50000;

    while (rawOffset < maxScannedRows) {
      final batch = await _fetchNetifyRawFlows(
        limit: batchSize,
        offset: rawOffset,
        protocolFilter: null,
        hoursBack: hoursBack,
        context: context,
      );
      if (batch.isEmpty) break;
      count += batch
          .where((flow) => _matchesNetifyProtocol(flow, protocolFilter))
          .length;
      if (batch.length < batchSize) break;
      rawOffset += batch.length;
    }

    return count;
  }

  Future<List<NetifyFlow>> _fetchFilteredNetifyRawFlows({
    required int limit,
    required int offset,
    required String protocolFilter,
    int? hoursBack,
    BuildContext? context,
  }) async {
    var rawOffset = 0;
    var skippedMatches = 0;
    final matches = <NetifyFlow>[];
    const batchSize = 1000;
    const maxScannedRows = 50000;

    while (rawOffset < maxScannedRows && matches.length < limit) {
      final batch = await _fetchNetifyRawFlows(
        limit: batchSize,
        offset: rawOffset,
        protocolFilter: null,
        hoursBack: hoursBack,
        context: context,
      );
      if (batch.isEmpty) break;

      for (final flow in batch) {
        if (!_matchesNetifyProtocol(flow, protocolFilter)) continue;
        if (skippedMatches < offset) {
          skippedMatches++;
          continue;
        }
        matches.add(flow);
        if (matches.length >= limit) break;
      }

      if (batch.length < batchSize) break;
      rawOffset += batch.length;
    }

    return matches;
  }

  Future<List<NetifyFlow>> _fetchNetifyRawFlows({
    required int limit,
    required int offset,
    String? protocolFilter,
    int? hoursBack,
    BuildContext? context,
  }) async {
    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final output = await _sqliteQueryOutput(
        dbExpression: _netifyDbExpression(),
        sql:
            'SELECT json FROM flow_raw ${_netifyRawWhereClause(protocolFilter, hoursBack: hoursBack)} ORDER BY id DESC LIMIT $limit OFFSET $offset;',
        context: context,
      );
      return output
          .split('\n')
          .map((line) => NetifyFlow.fromJsonLine(line.trim()))
          .whereType<NetifyFlow>()
          .toList();
    } catch (e, stack) {
      Logger.warning('Optional Netify raw flows fetch failed: $e');
      Logger.debug('Optional Netify raw flows stack: $stack');
      return const [];
    }
  }

  String _commandOutput(dynamic result) {
    if (result is List && result.length > 1 && result[0] == 0) {
      return _commandOutput(result[1]);
    }
    if (result is Map) {
      final stdout = result['stdout'] ?? result['data'] ?? result['output'];
      final stderr = result['stderr'];
      final code = result['code'];
      final parts = <String>[];
      final stdoutText = stdout?.toString().trimRight() ?? '';
      final stderrText = stderr?.toString().trimRight() ?? '';
      if (stdoutText.isNotEmpty) parts.add(stdoutText);
      if (stderrText.isNotEmpty) parts.add(stderrText);
      if (code != null && code.toString() != '0') {
        parts.add('Exit code: $code');
      }
      if (parts.isNotEmpty) return parts.join('\n');
    }
    if (result is List && result.length > 1 && result[0] == 0) {
      return result[1]?.toString() ?? '';
    }
    return result?.toString() ?? '';
  }

  dynamic _extractRpcData(dynamic result) {
    if (result is List && result.length > 1) {
      return result[0] == 0 ? result[1] : null;
    }
    return result;
  }

  Future<Map?> _fetchOpenwallaUciValues({BuildContext? context}) async {
    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return null;
    }

    final result = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'get',
      params: {'config': 'openwalla'},
      context: context,
    );
    final data = _extractRpcData(result);
    return data is Map ? data['values'] as Map? : null;
  }

  Future<PingMonitorSettings> fetchPingMonitorSettings({
    BuildContext? context,
  }) async {
    const defaults = PingMonitorSettings(target: '1.1.1.1', thresholdMs: 100);
    if (_reviewerModeEnabled) return defaults;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return defaults;
    }

    try {
      final values = await _fetchOpenwallaUciValues(context: context);
      final ping = values is Map ? values['ping_monitor'] : null;

      if (ping is Map) {
        final target = ping['target']?.toString();
        final threshold = int.tryParse(ping['threshold']?.toString() ?? '');
        return PingMonitorSettings(
          target: target?.isNotEmpty == true ? target! : defaults.target,
          thresholdMs: threshold ?? defaults.thresholdMs,
        );
      }
    } catch (e, stack) {
      Logger.warning('Failed to fetch ping monitor settings: $e');
      Logger.debug('Ping monitor settings stack: $stack');
    }

    return defaults;
  }

  Future<void> savePingMonitorSettings(
    PingMonitorSettings settings, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw Exception('Router is not connected');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'openwalla',
      section: 'ping_monitor',
      values: {
        'target': settings.target,
        'threshold': settings.thresholdMs.toString(),
      },
      context: context,
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'openwalla',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command:
          '/etc/init.d/openwalla-ping-monitor restart >/dev/null 2>&1 || true',
    );
  }

  Future<DnsMonitorSettings> fetchDnsMonitorSettings({
    BuildContext? context,
  }) async {
    const defaults = DnsMonitorSettings(hostname: 'openwrt.org');
    if (_reviewerModeEnabled) return defaults;

    try {
      final values = await _fetchOpenwallaUciValues(context: context);
      final dns = values is Map ? values['dns_monitor'] : null;
      if (dns is Map) {
        final target = dns['target']?.toString();
        return DnsMonitorSettings(
          hostname: target?.isNotEmpty == true ? target! : defaults.hostname,
        );
      }
    } catch (e, stack) {
      Logger.warning('Failed to fetch DNS monitor settings: $e');
      Logger.debug('DNS monitor settings stack: $stack');
    }

    return defaults;
  }

  Future<void> saveDnsMonitorSettings(
    DnsMonitorSettings settings, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw Exception('Router is not connected');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'openwalla',
      section: 'dns_monitor',
      values: {'target': settings.hostname},
      context: context,
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'openwalla',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command:
          '/etc/init.d/openwalla-dns-monitor restart >/dev/null 2>&1 || true',
    );
  }

  Future<List<PingMonitorSample>> fetchPingMonitorSamples({
    int limit = kOpenwallaPingTimelineSampleLimit,
    BuildContext? context,
  }) async {
    final safeLimit = limit.clamp(1, 2000).toInt();
    if (_reviewerModeEnabled) {
      final now = DateTime.now().toUtc();
      return List<PingMonitorSample>.generate(safeLimit, (index) {
        final latency = 18.0 + ((index * 7) % 12);
        return PingMonitorSample(
          timestamp: now.subtract(Duration(minutes: safeLimit - 1 - index)),
          target: '1.1.1.1',
          status: 'OK',
          latencyMs: latency,
          message: 'reply',
        );
      });
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/bin/sh',
          'params': [
            '-c',
            r'file="$(uci -q get openwalla.ping_monitor.output_file 2>/dev/null || echo /tmp/openwalla-ping-monitor.txt)"; '
                'if [ -f "\$file" ]; then tail -n $safeLimit "\$file" 2>/dev/null; fi',
          ],
        },
        context: context,
      );
      final output = _commandOutput(result);
      return output
          .split('\n')
          .map((line) => PingMonitorSample.fromLine(line.trim()))
          .whereType<PingMonitorSample>()
          .toList();
    } catch (e, stack) {
      Logger.warning('Optional ping monitor samples fetch failed: $e');
      Logger.debug('Optional ping monitor samples stack: $stack');
      return const [];
    }
  }

  Future<List<SpeedtestMonitorSample>> fetchSpeedtestMonitorSamples({
    int limit = 30,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      final now = DateTime.now().toUtc();
      return List<SpeedtestMonitorSample>.generate(3, (index) {
        return SpeedtestMonitorSample(
          timestamp: now.subtract(Duration(days: 2 - index)),
          status: 'OK',
          downloadMbps: 360 + (index * 42),
          uploadMbps: 28 + (index * 4),
          server: 'Reviewer',
          message: 'speedtest completed',
        );
      });
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final safeLimit = limit.clamp(1, 365).toInt();
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/bin/sh',
          'params': [
            '-c',
            r'file="$(uci -q get openwalla.speedtest_monitor.output_file 2>/dev/null || echo /tmp/openwalla-speedtest-monitor.txt)"; '
                'if [ -f "\$file" ]; then tail -n $safeLimit "\$file" 2>/dev/null; fi',
          ],
        },
        context: context,
      );
      final output = _commandOutput(result);
      return output
          .split('\n')
          .map((line) => SpeedtestMonitorSample.fromLine(line.trim()))
          .whereType<SpeedtestMonitorSample>()
          .toList();
    } catch (e, stack) {
      Logger.warning('Optional speedtest monitor samples fetch failed: $e');
      Logger.debug('Optional speedtest monitor samples stack: $stack');
      return const [];
    }
  }

  Future<List<VnstatUsageSample>> fetchVnstatUsageSamples({
    required String period,
    String? interfaceName,
    int limit = 12,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      final now = DateTime.now();
      return List<VnstatUsageSample>.generate(limit, (index) {
        final total = (index + 2) * 42 * 1024 * 1024;
        return VnstatUsageSample(
          timestamp: now.subtract(Duration(days: limit - 1 - index)),
          downloadBytes: (total * 0.86).round(),
          uploadBytes: (total * 0.14).round(),
        );
      });
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    final commands = ['/usr/bin/vnstat', '/usr/sbin/vnstat', '/bin/vnstat'];
    final paramsVariants = _vnstatJsonParamVariants(period);
    for (final command in commands) {
      for (final paramsVariant in paramsVariants) {
        try {
          final result = await _apiService!.call(
            router.ipAddress,
            sysauth,
            router.useHttps,
            object: 'file',
            method: 'exec',
            params: {'command': command, 'params': paramsVariant},
            context: context,
          );
          final output = _commandOutput(result);
          if (output.trim().isEmpty) continue;
          final samples = _parseVnstatSamples(
            output,
            period: period,
            preferredInterface: interfaceName,
            limit: limit,
          );
          if (samples.isNotEmpty) return samples;
        } catch (e, stack) {
          Logger.debug(
            'Optional vnstat command $command ${paramsVariant.join(' ')} failed: $e',
          );
          Logger.debug('Optional vnstat stack: $stack');
        }
      }
    }
    return const [];
  }

  List<List<String>> _vnstatJsonParamVariants(String period) {
    final (mode, flag) = switch (period) {
      '5min' => ('5', '-5'),
      'hourly' => ('h', '-h'),
      'daily' => ('d', '-d'),
      'monthly' => ('m', '-m'),
      _ => (null, null),
    };
    return [
      const ['--json'],
      if (mode != null) ['--json', mode],
      if (flag != null) [flag, '--json'],
    ];
  }

  Future<List<String>> fetchVnstatInterfaceNames({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return const ['br-lan', 'wan', 'WG'];
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    final commands = ['/usr/bin/vnstat', '/usr/sbin/vnstat', '/bin/vnstat'];
    for (final command in commands) {
      try {
        final result = await _apiService!.call(
          router.ipAddress,
          sysauth,
          router.useHttps,
          object: 'file',
          method: 'exec',
          params: {
            'command': command,
            'params': ['--iflist'],
          },
          context: context,
        );
        final names = _parseVnstatIfList(_commandOutput(result));
        if (names.isNotEmpty) return names;
      } catch (e, stack) {
        Logger.debug('Optional vnstat --iflist command $command failed: $e');
        Logger.debug('Optional vnstat --iflist stack: $stack');
      }
    }

    return const [];
  }

  Future<List<NlbwDeviceUsage>> fetchNlbwTopDevices({
    int limit = 5,
    BuildContext? context,
  }) async {
    final safeLimit = limit.clamp(1, 20).toInt();
    if (_reviewerModeEnabled) {
      return [
        const NlbwDeviceUsage(
          mac: 'd0:3f:27:81:6c:17',
          label: 'WYZE_Living_Room',
          downloadBytes: 7423913984,
          uploadBytes: 491782144,
        ),
        const NlbwDeviceUsage(
          mac: '8c:85:90:aa:10:44',
          label: 'Pixel',
          downloadBytes: 2193629184,
          uploadBytes: 71303168,
        ),
        const NlbwDeviceUsage(
          mac: '54:ef:44:20:a9:71',
          label: 'Laptop',
          downloadBytes: 914358272,
          uploadBytes: 129499136,
        ),
      ].take(safeLimit).toList();
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/bin/sh',
          'params': [
            '-c',
            'command -v nlbw >/dev/null 2>&1 || exit 0; '
                'nlbw -c csv -g mac -o -rx_bytes -q 2>/dev/null | '
                'awk -v limit="$safeLimit" \''
                'BEGIN { OFS="|" } '
                'NR == 1 { for (i = 1; i <= NF; i++) idx[\$i] = i; next } '
                'NF > 0 && rows < limit { '
                'mac=tolower(\$idx["mac"]); rx=\$idx["rx_bytes"]+0; tx=\$idx["tx_bytes"]+0; '
                'if (mac ~ /^([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]\$/ && mac != "00:00:00:00:00:00") { print mac, rx, tx; rows++ } '
                '}\'',
          ],
        },
        context: context,
      );
      final rows = _parseNlbwDeviceUsage(_commandOutput(result));
      if (rows.isEmpty) return rows;
      final deviceNames = await fetchDeviceNameMaps();
      final namesByMac = <String, String>{...deviceNames.$1};
      final dhcpLeases =
          dashboardData?['dhcpLeases']?['dhcp_leases'] as List<dynamic>? ??
          const [];
      for (final lease in dhcpLeases) {
        if (lease is! Map) continue;
        final mac = _normalizeMacAddress(lease['macaddr']?.toString() ?? '');
        final hostname = lease['hostname']?.toString().trim() ?? '';
        if (mac.isNotEmpty && hostname.isNotEmpty && hostname != '*') {
          namesByMac.putIfAbsent(mac, () => hostname);
        }
      }
      return rows.map((row) {
        final name = namesByMac[_normalizeMacAddress(row.mac)];
        return NlbwDeviceUsage(
          mac: row.mac,
          label: name?.isNotEmpty == true ? name! : row.label,
          downloadBytes: row.downloadBytes,
          uploadBytes: row.uploadBytes,
        );
      }).toList();
    } catch (e, stack) {
      Logger.warning('Optional nlbw top devices fetch failed: $e');
      Logger.debug('Optional nlbw top devices stack: $stack');
      return const [];
    }
  }

  Future<List<NlbwProtocolUsage>> fetchNlbwProtocolUsage({
    int limit = 5,
    BuildContext? context,
  }) async {
    final safeLimit = limit.clamp(1, 20).toInt();
    if (_reviewerModeEnabled) {
      return [
        const NlbwProtocolUsage(
          protocol: 'Web & Streaming',
          downloadBytes: 8430000000,
          uploadBytes: 411000000,
        ),
        const NlbwProtocolUsage(
          protocol: 'Other',
          downloadBytes: 432350000,
          uploadBytes: 21200000,
        ),
        const NlbwProtocolUsage(
          protocol: 'Communication',
          downloadBytes: 12330000,
          uploadBytes: 4812000,
        ),
      ].take(safeLimit).toList();
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    for (final group in const ['layer7', 'proto', 'port']) {
      try {
        final result = await _apiService!.call(
          router.ipAddress,
          sysauth,
          router.useHttps,
          object: 'file',
          method: 'exec',
          params: {
            'command': '/bin/sh',
            'params': [
              '-c',
              'command -v nlbw >/dev/null 2>&1 || exit 0; '
                  'nlbw -c csv -g $group -o -rx_bytes -q 2>/dev/null | '
                  'awk -v limit="$safeLimit" -v group="$group" \''
                  'BEGIN { OFS="|" } '
                  'NR == 1 { for (i = 1; i <= NF; i++) idx[\$i] = i; next } '
                  'NF > 0 && rows < limit { '
                  'name=\$idx[group]; '
                  'if (name == "" && group == "layer7") name=\$idx["layer7"]; '
                  'if (name == "" && group == "proto") name=\$idx["proto"]; '
                  'if (name == "" && group == "port") name=\$idx["port"]; '
                  'rx=\$idx["rx_bytes"]+0; tx=\$idx["tx_bytes"]+0; '
                  'if (name != "" && (rx > 0 || tx > 0)) { print name, rx, tx; rows++ } '
                  '}\'',
            ],
          },
          context: context,
        );
        final rows = _parseNlbwProtocolUsage(_commandOutput(result));
        if (rows.isNotEmpty) return rows;
      } catch (e, stack) {
        Logger.debug('Optional nlbw protocol group $group failed: $e');
        Logger.debug('Optional nlbw protocol stack: $stack');
      }
    }

    return const [];
  }

  List<NlbwDeviceUsage> _parseNlbwDeviceUsage(String output) {
    return output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) {
          final parts = line.split('|');
          if (parts.length < 3) return null;
          final mac = parts[0].trim();
          final download = int.tryParse(parts[1].trim()) ?? 0;
          final upload = int.tryParse(parts[2].trim()) ?? 0;
          return NlbwDeviceUsage(
            mac: mac,
            label: 'Unknown device',
            downloadBytes: download,
            uploadBytes: upload,
          );
        })
        .whereType<NlbwDeviceUsage>()
        .where((row) => row.totalBytes > 0)
        .toList();
  }

  List<NlbwProtocolUsage> _parseNlbwProtocolUsage(String output) {
    return output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) {
          final parts = line.split('|');
          if (parts.length < 3) return null;
          final protocol = parts[0].trim();
          final download = int.tryParse(parts[1].trim()) ?? 0;
          final upload = int.tryParse(parts[2].trim()) ?? 0;
          return NlbwProtocolUsage(
            protocol: protocol.isEmpty ? 'Other' : protocol,
            downloadBytes: download,
            uploadBytes: upload,
          );
        })
        .whereType<NlbwProtocolUsage>()
        .where((row) => row.totalBytes > 0)
        .toList();
  }

  List<String> _parseVnstatIfList(String output) {
    final trimmed = output.trim();
    if (trimmed.isEmpty) return const [];

    final cleaned = trimmed
        .split('\n')
        .map(
          (line) => line.replaceFirst(RegExp(r'^Available interfaces:\s*'), ''),
        )
        .join(' ');
    final names =
        cleaned
            .split(RegExp(r'\s+'))
            .map((name) => name.trim())
            .where((name) => name.isNotEmpty && name != ':')
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  List<VnstatUsageSample> _parseVnstatSamples(
    String output, {
    required String period,
    String? preferredInterface,
    required int limit,
  }) {
    try {
      final payload = jsonDecode(output);
      if (payload is! Map<String, dynamic>) return const [];
      final interfaces = _vnstatInterfaces(payload['interfaces']);
      if (interfaces.isEmpty) return const [];
      final picked = _pickVnstatInterface(
        interfaces,
        period: period,
        preferredInterface: preferredInterface,
      );
      final rows = _vnstatPeriodRows(
        picked is Map ? picked['traffic'] : null,
        period,
      );
      final samples =
          rows
              .map((row) => _mapVnstatRow(row, period))
              .whereType<VnstatUsageSample>()
              .toList()
            ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return samples.length > limit
          ? samples.sublist(samples.length - limit)
          : samples;
    } catch (e, stack) {
      Logger.debug('Optional vnstat parse failed: $e');
      Logger.debug('Optional vnstat parse stack: $stack');
      return const [];
    }
  }

  List<Map> _vnstatInterfaces(dynamic rawInterfaces) {
    if (rawInterfaces is List) {
      return rawInterfaces.whereType<Map>().toList();
    }
    if (rawInterfaces is Map) {
      return rawInterfaces.entries.where((entry) => entry.value is Map).map((
        entry,
      ) {
        final value = Map<dynamic, dynamic>.from(entry.value as Map);
        value.putIfAbsent('name', () => entry.key.toString());
        return value;
      }).toList();
    }
    return const [];
  }

  dynamic _pickVnstatInterface(
    List<Map> interfaces, {
    required String period,
    String? preferredInterface,
  }) {
    final preferred = preferredInterface?.trim();
    final withRows = interfaces.where((interface) {
      return _vnstatPeriodRows(interface['traffic'], period).isNotEmpty;
    }).toList();
    if (withRows.isEmpty) return interfaces.firstOrNull;

    if (preferred != null && preferred.isNotEmpty) {
      final exact = withRows.where((interface) {
        return _vnstatInterfaceNames(interface).contains(preferred);
      }).firstOrNull;
      if (exact != null && _vnstatTrafficTotal(exact, period) > 0) {
        return exact;
      }

      final lower = preferred.toLowerCase();
      final caseInsensitive = withRows.where((interface) {
        return _vnstatInterfaceNames(
          interface,
        ).map((name) => name.toLowerCase()).contains(lower);
      }).firstOrNull;
      if (caseInsensitive != null &&
          _vnstatTrafficTotal(caseInsensitive, period) > 0) {
        return caseInsensitive;
      }
    }

    final withTraffic = withRows
      ..sort(
        (a, b) => _vnstatTrafficTotal(
          b,
          period,
        ).compareTo(_vnstatTrafficTotal(a, period)),
      );
    if (_vnstatTrafficTotal(withTraffic.first, period) > 0) {
      return withTraffic.first;
    }

    if (preferred != null && preferred.isNotEmpty) {
      final preferredWithRows = withRows.where((interface) {
        final names = _vnstatInterfaceNames(interface);
        return names.contains(preferred) ||
            names
                .map((name) => name.toLowerCase())
                .contains(preferred.toLowerCase());
      }).firstOrNull;
      if (preferredWithRows != null) return preferredWithRows;
    }

    return withRows.first;
  }

  Set<String> _vnstatInterfaceNames(Map interface) {
    return {
      interface['name']?.toString(),
      interface['id']?.toString(),
      interface['interface']?.toString(),
      interface['alias']?.toString(),
    }.whereType<String>().where((name) => name.trim().isNotEmpty).toSet();
  }

  int _vnstatTrafficTotal(Map interface, String period) {
    return _vnstatPeriodRows(interface['traffic'], period).fold<int>(0, (
      sum,
      row,
    ) {
      if (row is! Map) return sum;
      return sum +
          _vnstatBytes(
            row['rx'] ??
                row['rx_bytes'] ??
                row['received'] ??
                row['download'] ??
                row['down'],
          ) +
          _vnstatBytes(
            row['tx'] ??
                row['tx_bytes'] ??
                row['transmitted'] ??
                row['upload'] ??
                row['up'],
          );
    });
  }

  List _vnstatPeriodRows(dynamic traffic, String period) {
    if (traffic is! Map) return const [];
    final keys = switch (period) {
      '5min' => [
        'fiveminute',
        'fiveminutes',
        '5minute',
        '5minutes',
        'minute',
        'minutes',
        '5min',
        'five_minute',
        'five_minutes',
      ],
      'hourly' => ['hour', 'hours', 'hourly'],
      'daily' => ['day', 'days', 'daily'],
      'monthly' => ['month', 'months', 'monthly'],
      _ => const <String>[],
    };
    for (final key in keys) {
      final rows = traffic[key];
      if (rows is List) return rows;
    }
    return const [];
  }

  VnstatUsageSample? _mapVnstatRow(dynamic row, String period) {
    if (row is! Map) return null;
    final timestamp = _resolveVnstatTimestamp(row, period);
    if (timestamp == null) return null;
    return VnstatUsageSample(
      timestamp: timestamp,
      downloadBytes: _vnstatBytes(
        row['rx'] ??
            row['rx_bytes'] ??
            row['received'] ??
            row['download'] ??
            row['down'],
      ),
      uploadBytes: _vnstatBytes(
        row['tx'] ??
            row['tx_bytes'] ??
            row['transmitted'] ??
            row['upload'] ??
            row['up'],
      ),
    );
  }

  DateTime? _resolveVnstatTimestamp(Map row, String period) {
    final rawTimestamp = row['timestamp'] ?? row['begin'];
    if (rawTimestamp is num) {
      final milliseconds = rawTimestamp > 1000000000000
          ? rawTimestamp.toInt()
          : rawTimestamp.toInt() * 1000;
      return DateTime.fromMillisecondsSinceEpoch(milliseconds);
    }
    if (rawTimestamp is String) {
      final parsed = DateTime.tryParse(rawTimestamp);
      if (parsed != null) return parsed;
      final numericTimestamp = int.tryParse(rawTimestamp);
      if (numericTimestamp != null) {
        final milliseconds = numericTimestamp > 1000000000000
            ? numericTimestamp
            : numericTimestamp * 1000;
        return DateTime.fromMillisecondsSinceEpoch(milliseconds);
      }
    }

    final date = row['date'];
    int year;
    int month;
    int day;
    if (date is Map) {
      year = _asInt(date['year']);
      month = _asInt(date['month']);
      day = _asInt(date['day']);
    } else if (date is String) {
      final parsed = DateTime.tryParse(date);
      if (parsed == null) return null;
      year = parsed.year;
      month = parsed.month;
      day = parsed.day;
    } else {
      return null;
    }
    if (year <= 0 || month <= 0) return null;

    final time = row['time'];
    final timeMap = time is Map ? time : const {};
    var hour = _asInt(timeMap['hour'] ?? (date is Map ? date['hour'] : null));
    final minute = _asInt(
      timeMap['minute'] ??
          timeMap['min'] ??
          (date is Map ? date['minute'] : null),
    );
    if (time is String) {
      final parts = time.split(':');
      if (parts.isNotEmpty) hour = int.tryParse(parts[0]) ?? hour;
    }
    if ((period == 'hourly' || period == '5min') && hour == 0) {
      final maybeHour = _asInt(row['id']);
      if (maybeHour >= 0 && maybeHour <= 23) hour = maybeHour;
    }
    if (period == 'daily') return DateTime(year, month, day <= 0 ? 1 : day);
    if (period == 'monthly') return DateTime(year, month);
    return DateTime(year, month, day <= 0 ? 1 : day, hour, minute);
  }

  int _vnstatBytes(dynamic value) {
    if (value is int) return value < 0 ? 0 : value;
    if (value is num) return value < 0 ? 0 : value.round();
    if (value is Map) {
      return _vnstatBytes(
        value['bytes'] ?? value['value'] ?? value['total'] ?? value['amount'],
      );
    }
    final parsed = int.tryParse(value?.toString() ?? '') ?? 0;
    return parsed < 0 ? 0 : parsed;
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<SpeedtestMonitorSettings> fetchSpeedtestMonitorSettings({
    BuildContext? context,
  }) async {
    final defaults = SpeedtestMonitorSettings(
      enabled: true,
      runDate: DateTime.now(),
      runHour: 3,
      runMinute: 15,
    );
    if (_reviewerModeEnabled) return defaults;

    try {
      final values = await _fetchOpenwallaUciValues(context: context);
      final speedtest = values is Map ? values['speedtest_monitor'] : null;
      if (speedtest is Map) {
        final enabled = speedtest['enabled']?.toString() != '0';
        final runHour =
            int.tryParse(speedtest['run_hour']?.toString() ?? '') ??
            defaults.runHour;
        final runMinute =
            int.tryParse(speedtest['run_minute']?.toString() ?? '') ??
            defaults.runMinute;
        final runDate = DateTime.tryParse(
          speedtest['run_date']?.toString() ?? '',
        );
        return SpeedtestMonitorSettings(
          enabled: enabled,
          runDate: runDate ?? defaults.runDate,
          runHour: runHour.clamp(0, 23),
          runMinute: runMinute.clamp(0, 59),
        );
      }
    } catch (e, stack) {
      Logger.warning('Failed to fetch speedtest monitor settings: $e');
      Logger.debug('Speedtest settings stack: $stack');
    }

    return defaults;
  }

  Future<void> saveSpeedtestMonitorSettings(
    SpeedtestMonitorSettings settings, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw Exception('Router is not connected');
    }

    final runDate = settings.runDate;
    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'openwalla',
      section: 'speedtest_monitor',
      values: {
        'enabled': settings.enabled ? '1' : '0',
        'run_hour': settings.runHour.clamp(0, 23).toString(),
        'run_minute': settings.runMinute.clamp(0, 59).toString(),
        if (runDate != null)
          'run_date':
              '${runDate.year.toString().padLeft(4, '0')}-${runDate.month.toString().padLeft(2, '0')}-${runDate.day.toString().padLeft(2, '0')}',
      },
      context: context,
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'openwalla',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command:
          r'MARKER="# OPENWALLA_SPEEDTEST_MONITOR"; CRON="/etc/crontabs/root"; TMP="/tmp/.openwalla_cron_app.$$"; HOUR="$(uci -q get openwalla.speedtest_monitor.run_hour 2>/dev/null || echo 3)"; MINUTE="$(uci -q get openwalla.speedtest_monitor.run_minute 2>/dev/null || echo 15)"; ENABLED="$(uci -q get openwalla.speedtest_monitor.enabled 2>/dev/null || echo 1)"; case "$HOUR" in ""|*[!0-9]*) HOUR=3 ;; esac; case "$MINUTE" in ""|*[!0-9]*) MINUTE=15 ;; esac; [ "$HOUR" -gt 23 ] && HOUR=3; [ "$MINUTE" -gt 59 ] && MINUTE=15; if [ -f "$CRON" ]; then grep -v "$MARKER" "$CRON" >"$TMP" 2>/dev/null || : >"$TMP"; else : >"$TMP"; fi; if [ "$ENABLED" = "1" ]; then echo "$MINUTE $HOUR * * * /usr/bin/openwalla-speedtest-monitor --once >/tmp/openwalla-speedtest-monitor.last.log 2>&1 $MARKER" >>"$TMP"; fi; mv "$TMP" "$CRON"; /etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true',
    );
  }

  Future<MonthlyUsageSettings> fetchMonthlyUsageSettings({
    BuildContext? context,
  }) async {
    const defaults = MonthlyUsageSettings(
      monthStartDay: 1,
      interfaceName: 'br-lan',
      monthlyLimitGb: 0,
    );
    if (_reviewerModeEnabled) return defaults;

    try {
      final values = await _fetchOpenwallaUciValues(context: context);
      final dashboard = values is Map ? values['dashboard'] : null;
      if (dashboard is Map) {
        final monthStartDay =
            int.tryParse(dashboard['month_start_day']?.toString() ?? '') ??
            defaults.monthStartDay;
        final interfaceName = dashboard['vnstat_interface']?.toString();
        final monthlyLimitGb =
            int.tryParse(dashboard['monthly_limit_gb']?.toString() ?? '') ??
            defaults.monthlyLimitGb;
        return MonthlyUsageSettings(
          monthStartDay: monthStartDay.clamp(1, 31),
          interfaceName: interfaceName?.isNotEmpty == true
              ? interfaceName!
              : defaults.interfaceName,
          monthlyLimitGb: monthlyLimitGb.clamp(0, 100000),
        );
      }
    } catch (e, stack) {
      Logger.warning('Failed to fetch monthly usage settings: $e');
      Logger.debug('Monthly usage settings stack: $stack');
    }

    return defaults;
  }

  Future<void> saveMonthlyUsageSettings(
    MonthlyUsageSettings settings, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw Exception('Router is not connected');
    }

    await _apiService!.uciSet(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'openwalla',
      section: 'dashboard',
      values: {
        'month_start_day': settings.monthStartDay.clamp(1, 31).toString(),
        'vnstat_interface': settings.interfaceName,
        'monthly_limit_gb': settings.monthlyLimitGb.clamp(0, 100000).toString(),
      },
      context: context,
    );
    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'openwalla',
    );
  }

  Future<List<OpenwallaServiceStatus>> fetchOpenwallaServices({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return _managedServices.map((service) {
        final running = service.name != 'openwalla-netify-collector';
        return OpenwallaServiceStatus(
          name: service.name,
          label: service.label,
          category: service.category,
          installed: true,
          enabled: running,
          running: running,
          statusText: running ? 'running' : 'stopped',
        );
      }).toList();
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return const [];
    }

    final serviceNames = _managedServices
        .map((service) => service.name)
        .join(' ');
    final command =
        'for svc in $serviceNames; do '
        'if [ -x "/etc/init.d/\$svc" ]; then '
        'enabled=0; /etc/init.d/\$svc enabled >/dev/null 2>&1 && enabled=1; '
        'status="\$(/etc/init.d/\$svc status 2>&1 || true)"; '
        'running=0; '
        '/etc/init.d/\$svc running >/dev/null 2>&1 && running=1; '
        'echo "\$status" | grep -Eiq "running|active with|started" && running=1; '
        'if [ "\$running" = "0" ]; then '
        'case "\$svc" in '
        'openwalla-connection-flows-collector) pgrep -f "/usr/bin/openwalla-connection-flow-collector" >/dev/null 2>&1 && running=1 ;; '
        '*) pgrep -f "/usr/bin/\$svc" >/dev/null 2>&1 && running=1 ;; '
        'esac; '
        'fi; '
        'status="\$(printf "%s" "\$status" | tr "\\n\\r|" "   " | sed "s/[[:space:]][[:space:]]*/ /g")"; '
        '[ -n "\$status" ] || status="\$([ "\$running" = "1" ] && echo running || echo stopped)"; '
        'printf "%s|1|%s|%s|%s\\n" "\$svc" "\$enabled" "\$running" "\$status"; '
        'else printf "%s|0|0|0|not installed\\n" "\$svc"; fi; '
        'done';

    final result = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'file',
      method: 'exec',
      params: {
        'command': '/bin/sh',
        'params': ['-c', command],
      },
      context: context,
    );

    final output = _commandOutput(result);
    return output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map(_parseServiceStatusLine)
        .whereType<OpenwallaServiceStatus>()
        .toList();
  }

  Future<OpenwallaStateBackupStatus> fetchOpenwallaStateBackupStatus({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return OpenwallaStateBackupStatus(
        installed: true,
        stateDir: '/overlay/openwalla-state',
        backupTimeMinutes: 720,
        lastBackupAt: DateTime.now().subtract(const Duration(minutes: 8)),
        fileCount: 14,
        size: '3.2M',
      );
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return OpenwallaStateBackupStatus.notInstalled('Router is not connected');
    }

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/usr/bin/openwalla-state-sync',
          'params': ['status'],
        },
        context: context,
      );
      return _parseStateBackupStatus(_commandOutput(result));
    } catch (e, stack) {
      Logger.warning('Optional Openwalla state backup status failed: $e');
      Logger.debug('Optional Openwalla state backup status stack: $stack');
      return OpenwallaStateBackupStatus.notInstalled(e.toString());
    }
  }

  OpenwallaStateBackupStatus _parseStateBackupStatus(String output) {
    final values = <String, String>{};
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final separator = trimmed.indexOf('|');
      if (separator <= 0) continue;
      values[trimmed.substring(0, separator)] = trimmed.substring(
        separator + 1,
      );
    }

    if (values['installed'] != '1') {
      return OpenwallaStateBackupStatus.notInstalled(output.trim());
    }

    final lastEpoch = int.tryParse(values['last_backup_epoch'] ?? '');
    DateTime? lastBackupAt;
    if (lastEpoch != null && lastEpoch > 0) {
      lastBackupAt = DateTime.fromMillisecondsSinceEpoch(
        lastEpoch * 1000,
        isUtc: true,
      ).toLocal();
    }

    return OpenwallaStateBackupStatus(
      installed: true,
      stateDir: values['state_dir']?.isNotEmpty == true
          ? values['state_dir']!
          : '/overlay/openwalla-state',
      backupTimeMinutes: int.tryParse(values['backup_time_min'] ?? '') ?? 720,
      lastBackupAt: lastBackupAt,
      fileCount: int.tryParse(values['file_count'] ?? '') ?? 0,
      size: values['size']?.isNotEmpty == true ? values['size']! : '0 B',
    );
  }

  Future<String> runOpenwallaStateBackupAction(
    String action, {
    BuildContext? context,
  }) async {
    if (!const {'backup', 'save', 'restore'}.contains(action)) {
      throw Exception('Unsupported state backup action: $action');
    }
    if (_reviewerModeEnabled) {
      return action == 'restore'
          ? 'Reviewer restore completed'
          : 'Reviewer backup completed';
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw Exception('Router is not connected');
    }

    final result = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'file',
      method: 'exec',
      params: {
        'command': '/usr/bin/openwalla-state-sync',
        'params': [action],
      },
      context: context,
    );
    final output = _commandOutput(result).trim();
    return output.isEmpty ? 'Openwalla state $action completed.' : output;
  }

  OpenwallaServiceStatus? _parseServiceStatusLine(String line) {
    final parts = line.split('|');
    if (parts.length < 5) return null;
    final name = parts[0];
    final service = _managedService(name);
    if (service == null) return null;
    return OpenwallaServiceStatus(
      name: name,
      label: service.label,
      category: service.category,
      installed: parts[1] == '1',
      enabled: parts[2] == '1',
      running: parts[3] == '1',
      statusText: parts.sublist(4).join('|').trim(),
    );
  }

  ({String name, String label, String category})? _managedService(String name) {
    for (final service in _managedServices) {
      if (service.name == name) return service;
    }
    return null;
  }

  bool _isManagedService(String serviceName) {
    return _managedService(serviceName) != null;
  }

  Future<void> setOpenwallaServiceEnabled(
    String serviceName,
    bool enabled, {
    BuildContext? context,
  }) async {
    if (!_isManagedService(serviceName)) {
      throw Exception('Unsupported service: $serviceName');
    }
    if (_reviewerModeEnabled) return;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw Exception('Router is not connected');
    }

    final action = enabled ? 'enable' : 'disable';
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command:
          '[ -x /etc/init.d/$serviceName ] && /etc/init.d/$serviceName $action',
    );
  }

  Future<void> runOpenwallaServiceAction(
    String serviceName, {
    required String action,
    BuildContext? context,
  }) async {
    if (!_isManagedService(serviceName)) {
      throw Exception('Unsupported service: $serviceName');
    }
    if (!const {'start', 'stop', 'restart', 'reload'}.contains(action)) {
      throw Exception('Unsupported service action: $action');
    }
    if (_reviewerModeEnabled) return;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw Exception('Router is not connected');
    }

    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command:
          '[ -x /etc/init.d/$serviceName ] && /etc/init.d/$serviceName $action',
    );
  }

  Future<WireGuardServerSettings> fetchWireGuardServerSettings({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return const WireGuardServerSettings(
        installed: true,
        configured: true,
        enabled: true,
        interfaceName: 'owrt_wg_server',
        listenPort: 51820,
        vpnAddress: '10.8.0.1/24',
        internalIpAddress: '203.0.113.10',
        publicKey: 'reviewer-wireguard-public-key',
      );
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return WireGuardServerSettings.defaults;
    }

    const iface = 'owrt_wg_server';
    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/bin/sh',
          'params': [
            '-c',
            _withWireGuardBinaryLookup(
              r'IFACE="owrt_wg_server"; '
              r'installed=0; [ -n "$WG_BIN" ] && installed=1; '
              r'configured=0; [ "$(uci -q get network.$IFACE.proto 2>/dev/null)" = "wireguard" ] && configured=1; '
              r'enabled=1; [ "$(uci -q get network.$IFACE.disabled 2>/dev/null)" = "1" ] && enabled=0; '
              r'port="$(uci -q get network.$IFACE.listen_port 2>/dev/null || echo 51820)"; '
              r'addr="$(uci -q get network.$IFACE.addresses 2>/dev/null | awk "{print \$1}")"; [ -n "$addr" ] || addr="10.8.0.1/24"; '
              r'wan_ip="$(ifstatus wan 2>/dev/null | jsonfilter -e "@[\"ipv4-address\"][0].address" 2>/dev/null || true)"; '
              r'[ -n "$wan_ip" ] || wan_ip="$(uci -q get network.wan.ipaddr 2>/dev/null || true)"; '
              r'internal_ip="$(uci -q get firewall.owrt_wg_server.dest_ip 2>/dev/null || true)"; [ -n "$internal_ip" ] || internal_ip="$wan_ip"; '
              r'pub=""; priv="$(uci -q get network.$IFACE.private_key 2>/dev/null || true)"; '
              r'if [ -n "$priv" ] && [ -n "$WG_BIN" ]; then pub="$(printf "%s" "$priv" | "$WG_BIN" pubkey 2>/dev/null || true)"; fi; '
              r'printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$installed" "$configured" "$enabled" "$IFACE" "$port" "$addr" "$internal_ip" "$pub"',
            ),
          ],
        },
        context: context,
      );
      final parts = _commandOutput(result).trim().split('|');
      if (parts.length < 8) return WireGuardServerSettings.defaults;
      return WireGuardServerSettings(
        installed: parts[0] == '1',
        configured: parts[1] == '1',
        enabled: parts[2] != '0',
        interfaceName: parts[3].isEmpty ? iface : parts[3],
        listenPort: int.tryParse(parts[4]) ?? 51820,
        vpnAddress: parts[5].isEmpty ? '10.8.0.1/24' : parts[5],
        internalIpAddress: parts[6],
        publicKey: parts[7],
      );
    } catch (e, stack) {
      Logger.warning('Optional WireGuard server settings fetch failed: $e');
      Logger.debug('Optional WireGuard server settings stack: $stack');
      return WireGuardServerSettings.defaults;
    }
  }

  Future<void> saveWireGuardServerSettings(
    WireGuardServerSettings settings, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw Exception('Router is not connected');
    }

    final port = settings.listenPort.clamp(1, 65535);
    final vpnAddress = _shellQuote(settings.vpnAddress.trim());
    final internalIp = _shellQuote(settings.internalIpAddress.trim());
    final disabled = settings.enabled ? '0' : '1';
    final command = _withWireGuardBinaryLookup(
      'IFACE="owrt_wg_server"; '
      'PORT="$port"; '
      'VPN_ADDR=$vpnAddress; '
      'INTERNAL_IP=$internalIp; '
      '[ -n "\$WG_BIN" ] || { echo "wireguard-tools is not installed"; exit 1; }; '
      'mkdir -p /etc/wireguard; chmod 700 /etc/wireguard; '
      'KEY_FILE="/etc/wireguard/openwalla_wg_server.key"; '
      '[ -s "\$KEY_FILE" ] || "\$WG_BIN" genkey > "\$KEY_FILE"; chmod 600 "\$KEY_FILE"; '
      'VPN_KEY="\$(cat "\$KEY_FILE")"; '
      'uci -q delete network.\$IFACE; '
      'uci set network.\$IFACE="interface"; '
      'uci set network.\$IFACE.proto="wireguard"; '
      'uci set network.\$IFACE.private_key="\$VPN_KEY"; '
      'uci set network.\$IFACE.listen_port="\$PORT"; '
      'uci set network.\$IFACE.disabled="$disabled"; '
      'uci add_list network.\$IFACE.addresses="\$VPN_ADDR"; '
      'uci commit network; '
      'uci -q del_list firewall.lan.network="\$IFACE" 2>/dev/null || true; '
      'uci add_list firewall.lan.network="\$IFACE"; '
      'uci -q delete firewall.owrt_wg_server; '
      'uci set firewall.owrt_wg_server="rule"; '
      'uci set firewall.owrt_wg_server.name="owrt_wireguard_server"; '
      'uci set firewall.owrt_wg_server.src="wan"; '
      'uci set firewall.owrt_wg_server.proto="udp"; '
      'uci set firewall.owrt_wg_server.dest_port="\$PORT"; '
      'uci set firewall.owrt_wg_server.target="ACCEPT"; '
      '[ -n "\$INTERNAL_IP" ] && uci set firewall.owrt_wg_server.dest_ip="\$INTERNAL_IP"; '
      'uci commit firewall; '
      '/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1 || true; '
      'if [ "$disabled" = "0" ]; then ifup "\$IFACE" >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true; else ifdown "\$IFACE" >/dev/null 2>&1 || true; fi',
    );

    await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'file',
      method: 'exec',
      params: {
        'command': '/bin/sh',
        'params': ['-c', command],
      },
      context: context,
    );
  }

  Future<WireGuardClientSettings> fetchWireGuardClientSettings({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return const WireGuardClientSettings(
        installed: true,
        configured: true,
        enabled: false,
        interfaceName: 'owrt_wg_client',
        address: '10.64.0.2/32',
        dns: '10.64.0.1',
        privateKey: 'reviewer-wireguard-client-private-key',
        peerPublicKey: 'reviewer-wireguard-provider-public-key',
        presharedKey: '',
        endpointHost: 'vpn.example.com',
        endpointPort: 51820,
        allowedIps: '0.0.0.0/0, ::/0',
        persistentKeepalive: 25,
        routeAllowedIps: true,
      );
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return WireGuardClientSettings.defaults;
    }

    const iface = 'owrt_wg_client';
    try {
      final result = await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/bin/sh',
          'params': [
            '-c',
            _withWireGuardBinaryLookup(
              r"""find_peer() { uci -q show network | sed -n "s/^network\.\([^=]*\)=['\"]\{0,1\}wireguard_$1['\"]\{0,1\}$/\1/p" | head -n1; }; """
              r'IFACE="owrt_wg_client"; PEER="$(find_peer "$IFACE")"; '
              r'if [ "$(uci -q get network.$IFACE.proto 2>/dev/null)" != "wireguard" ]; then '
              r"""for cand in $(uci -q show network | sed -n "s/^network\.\([^.=]*\)\.proto=['\"]\{0,1\}wireguard['\"]\{0,1\}$/\1/p"); do """
              r'[ "$cand" = "owrt_wg_server" ] && continue; '
              r'[ -n "$(uci -q get network.$cand.listen_port 2>/dev/null)" ] && continue; '
              r'cand_peer="$(find_peer "$cand")"; [ -n "$cand_peer" ] || continue; '
              r'IFACE="$cand"; PEER="$cand_peer"; break; '
              r'done; '
              r'fi; '
              r'[ -n "$PEER" ] || PEER="$(find_peer "$IFACE")"; '
              r'installed=0; [ -n "$WG_BIN" ] && installed=1; '
              r'configured=0; [ "$(uci -q get network.$IFACE.proto 2>/dev/null)" = "wireguard" ] && configured=1; '
              r'enabled=1; [ "$(uci -q get network.$IFACE.disabled 2>/dev/null)" = "1" ] && enabled=0; '
              r'addr="$(uci -q get network.$IFACE.addresses 2>/dev/null | sed "s/ /, /g")"; '
              r'dns="$(uci -q get network.$IFACE.dns 2>/dev/null | sed "s/ /, /g")"; '
              r'private_key="$(uci -q get network.$IFACE.private_key 2>/dev/null || true)"; '
              r'public_key="$(uci -q get network.$PEER.public_key 2>/dev/null || true)"; '
              r'preshared_key="$(uci -q get network.$PEER.preshared_key 2>/dev/null || true)"; '
              r'endpoint_host="$(uci -q get network.$PEER.endpoint_host 2>/dev/null || true)"; '
              r'endpoint_port="$(uci -q get network.$PEER.endpoint_port 2>/dev/null || echo 51820)"; '
              r'allowed_ips="$(uci -q get network.$PEER.allowed_ips 2>/dev/null | sed "s/ /, /g")"; '
              r'keepalive="$(uci -q get network.$PEER.persistent_keepalive 2>/dev/null || echo 25)"; '
              r'route_allowed="$(uci -q get network.$PEER.route_allowed_ips 2>/dev/null || echo 1)"; '
              r'printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" "$installed" "$configured" "$enabled" "$IFACE" "$addr" "$dns" "$private_key" "$public_key" "$preshared_key" "$endpoint_host" "$endpoint_port" "$allowed_ips" "$keepalive" "$route_allowed"',
            ),
          ],
        },
        context: context,
      );
      final parts = _commandOutput(result).trim().split('|');
      if (parts.length < 14) return WireGuardClientSettings.defaults;
      return WireGuardClientSettings(
        installed: parts[0] == '1',
        configured: parts[1] == '1',
        enabled: parts[2] != '0',
        interfaceName: parts[3].isEmpty ? iface : parts[3],
        address: parts[4],
        dns: parts[5],
        privateKey: parts[6],
        peerPublicKey: parts[7],
        presharedKey: parts[8],
        endpointHost: parts[9],
        endpointPort: int.tryParse(parts[10]) ?? 51820,
        allowedIps: parts[11].isEmpty ? '0.0.0.0/0, ::/0' : parts[11],
        persistentKeepalive: int.tryParse(parts[12]) ?? 25,
        routeAllowedIps: parts[13] != '0',
      );
    } catch (e, stack) {
      Logger.warning('Optional WireGuard client settings fetch failed: $e');
      Logger.debug('Optional WireGuard client settings stack: $stack');
      return WireGuardClientSettings.defaults;
    }
  }

  Future<void> saveWireGuardClientSettings(
    WireGuardClientSettings settings, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) return;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw Exception('Router is not connected');
    }

    final disabled = settings.enabled ? '0' : '1';
    final address = _shellQuote(settings.address.trim());
    final dns = _shellQuote(settings.dns.trim());
    final privateKey = _shellQuote(settings.privateKey.trim());
    final peerPublicKey = _shellQuote(settings.peerPublicKey.trim());
    final presharedKey = _shellQuote(settings.presharedKey.trim());
    final endpointHost = _shellQuote(settings.endpointHost.trim());
    final endpointPort = settings.endpointPort.clamp(1, 65535);
    final allowedIps = _shellQuote(settings.allowedIps.trim());
    final keepalive = settings.persistentKeepalive.clamp(0, 65535);
    final routeAllowed = settings.routeAllowedIps ? '1' : '0';

    final command = _withWireGuardBinaryLookup(
      'IFACE="owrt_wg_client"; '
      'PEER="owrt_wg_client_peer"; '
      'ADDRESSES=$address; '
      'DNS_SERVERS=$dns; '
      'PRIVATE_KEY=$privateKey; '
      'PEER_PUBLIC_KEY=$peerPublicKey; '
      'PRESHARED_KEY=$presharedKey; '
      'ENDPOINT_HOST=$endpointHost; '
      'ENDPOINT_PORT="$endpointPort"; '
      'ALLOWED_IPS=$allowedIps; '
      'KEEPALIVE="$keepalive"; '
      'ROUTE_ALLOWED="$routeAllowed"; '
      '[ -n "\$WG_BIN" ] || { echo "wireguard-tools is not installed"; exit 1; }; '
      '[ -n "\$PRIVATE_KEY" ] || { echo "WireGuard client private key is required"; exit 1; }; '
      '[ -n "\$PEER_PUBLIC_KEY" ] || { echo "WireGuard peer public key is required"; exit 1; }; '
      '[ -n "\$ENDPOINT_HOST" ] || { echo "WireGuard endpoint host is required"; exit 1; }; '
      '[ -n "\$ADDRESSES" ] || { echo "WireGuard address is required"; exit 1; }; '
      'uci -q delete network.\$IFACE; '
      'uci -q delete network.\$PEER; '
      'uci set network.\$IFACE="interface"; '
      'uci set network.\$IFACE.proto="wireguard"; '
      'uci set network.\$IFACE.private_key="\$PRIVATE_KEY"; '
      'uci set network.\$IFACE.disabled="$disabled"; '
      'for value in \$(printf "%s" "\$ADDRESSES" | tr "," " "); do [ -n "\$value" ] && uci add_list network.\$IFACE.addresses="\$value"; done; '
      'if [ -n "\$DNS_SERVERS" ]; then uci set network.\$IFACE.peerdns="0"; for value in \$(printf "%s" "\$DNS_SERVERS" | tr "," " "); do [ -n "\$value" ] && uci add_list network.\$IFACE.dns="\$value"; done; fi; '
      'uci set network.\$PEER="wireguard_\$IFACE"; '
      'uci set network.\$PEER.public_key="\$PEER_PUBLIC_KEY"; '
      '[ -n "\$PRESHARED_KEY" ] && uci set network.\$PEER.preshared_key="\$PRESHARED_KEY"; '
      'uci set network.\$PEER.endpoint_host="\$ENDPOINT_HOST"; '
      'uci set network.\$PEER.endpoint_port="\$ENDPOINT_PORT"; '
      'uci set network.\$PEER.persistent_keepalive="\$KEEPALIVE"; '
      'uci set network.\$PEER.route_allowed_ips="\$ROUTE_ALLOWED"; '
      'for value in \$(printf "%s" "\$ALLOWED_IPS" | tr "," " "); do [ -n "\$value" ] && uci add_list network.\$PEER.allowed_ips="\$value"; done; '
      'uci commit network; '
      'uci -q del_list firewall.wan.network="\$IFACE" 2>/dev/null || true; '
      'uci add_list firewall.wan.network="\$IFACE"; '
      'uci commit firewall; '
      '/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1 || true; '
      'if [ "$disabled" = "0" ]; then ifdown "\$IFACE" >/dev/null 2>&1 || true; ifup "\$IFACE" >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true; else ifdown "\$IFACE" >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true; fi',
    );

    await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'file',
      method: 'exec',
      params: {
        'command': '/bin/sh',
        'params': ['-c', command],
      },
      context: context,
    );
  }

  String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  List<String> dashboardInterfaceNames() {
    final interfaces =
        _dashboardData?['interfaceDump']?['interface'] as List<dynamic>?;
    final names = interfaces
        ?.whereType<Map<String, dynamic>>()
        .map((interface) => interface['interface']?.toString())
        .whereType<String>()
        .where((name) => name != 'loopback' && name != 'lo')
        .toSet()
        .toList();

    if (names == null || names.isEmpty) {
      return const ['br-lan', 'wan', 'eth0', 'eth1'];
    }
    names.sort();
    return names;
  }

  Map<String, dynamic>? _extractWanData(Map<String, dynamic>? interfaceDump) {
    if (interfaceDump == null || interfaceDump['interface'] == null) {
      return null;
    }
    try {
      for (var interface in interfaceDump['interface']) {
        if (interface['route'] is List) {
          for (var route in interface['route']) {
            if (route is Map &&
                route['target'] == '0.0.0.0' &&
                route['mask'] == 0) {
              return interface;
            }
          }
        }
      }
    } catch (e) {
      // print('WAN data extraction error: $e');
      return null;
    }
    return null;
  }

  String? _getDeviceNameForInterface(String interfaceName) {
    // Handle wireless format: "SSID (deviceName)"
    if (interfaceName.contains('(')) {
      final match = RegExp(r'\(([^)]+)\)').firstMatch(interfaceName);
      return match?.group(1);
    }

    // Map interface names to their actual device names from interface dump
    final interfaceDump =
        _dashboardData?['interfaceDump'] as Map<String, dynamic>?;
    if (interfaceDump != null && interfaceDump['interface'] is List) {
      for (final interface in interfaceDump['interface']) {
        if (interface is Map<String, dynamic>) {
          final ifname = interface['interface'] as String?;
          if (ifname == interfaceName) {
            // Return the device or l3_device field
            return (interface['device'] ?? interface['l3_device']) as String?;
          }
        }
      }
    }

    // If not found in interface dump, check if it's already a device name
    // (e.g., eth0, br-lan, wlan0)
    return interfaceName;
  }

  void _startThroughputTimer() {
    _throughputTimer?.cancel();
    // Don't start timer if we're rebooting
    if (_isRebooting) {
      return;
    }
    _throughputTimer = Timer.periodic(
      Duration(seconds: _dashboardPreferences.liveThroughputRefreshSeconds),
      (timer) {
        _updateThroughputOnly();
      },
    );
  }

  void _startSystemInfoTimer() {
    _systemInfoTimer?.cancel();
    if (_isRebooting) {
      return;
    }
    _systemInfoTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _updateSystemInfoOnly();
    });
  }

  Future<void> _updateSystemInfoOnly() async {
    if (_isRebooting || _dashboardData == null) {
      return;
    }

    if (_reviewerModeEnabled) {
      try {
        final result = await _apiService!.callSimple('system', 'info', {});
        if (result is List && result.length > 1 && result[0] == 0) {
          _dashboardData = {
            ...?_dashboardData,
            'sysInfo': result[1],
            '_lastUpdated': DateTime.now().millisecondsSinceEpoch,
          };
          notifyListeners();
        }
      } catch (e) {
        Logger.debug('Reviewer system info refresh failed: $e');
      }
      return;
    }

    if (_routerService?.selectedRouter == null ||
        _authService?.sysauth == null) {
      return;
    }

    final ip = _routerService!.selectedRouter!.ipAddress;
    final useHttps = _routerService!.selectedRouter!.useHttps;

    try {
      final conntrackFuture = _fetchConntrackData(ip, useHttps);
      final result = await _apiService!.call(
        ip,
        _authService!.sysauth!,
        useHttps,
        object: 'system',
        method: 'info',
        params: {},
      );

      if (result is List && result.length > 1 && result[0] == 0) {
        final conntrackData = await conntrackFuture;
        _dashboardData = {
          ...?_dashboardData,
          'sysInfo': result[1],
          'conntrack': conntrackData,
          '_lastUpdated': DateTime.now().millisecondsSinceEpoch,
        };
        notifyListeners();
      }
    } catch (e) {
      Logger.debug('System info refresh failed: $e');
    }
  }

  /// Updates only throughput data without refetching the entire dashboard
  Future<void> _updateThroughputOnly() async {
    // Don't try to update throughput during reboot
    if (_isRebooting) {
      return;
    }

    if (_reviewerModeEnabled) {
      // For reviewer mode, get network devices data only
      try {
        final result = await _apiService!.callSimple('network', 'device', {});
        final networkData = result[1] as Map<String, dynamic>?;
        final wanDeviceNames = {'eth0'}; // Mock WAN device

        // Check if we should track specific interface
        final prefs = _dashboardPreferences;
        String? specificInterface;
        if (!prefs.showAllThroughput &&
            prefs.primaryThroughputInterface != null) {
          // Extract device name from interface ID (format: "SSID (deviceName)" or just "deviceName")
          final interfaceId = prefs.primaryThroughputInterface!;
          if (interfaceId.contains('(')) {
            // Wireless format: "SSID (deviceName)"
            final match = RegExp(r'\(([^)]+)\)').firstMatch(interfaceId);
            specificInterface = match?.group(1);
          } else {
            // Wired format: just device name
            specificInterface = interfaceId;
          }
        }

        _throughputService?.updateThroughput(
          networkData,
          wanDeviceNames,
          specificInterface: specificInterface,
        );
        notifyListeners();
      } catch (e) {
        // Don't log throughput update errors as they're non-critical
      }
      return;
    }

    if (_routerService?.selectedRouter == null ||
        _authService?.sysauth == null) {
      return;
    }

    final ip = _routerService!.selectedRouter!.ipAddress;
    final useHttps = _routerService!.selectedRouter!.useHttps;

    try {
      // Only fetch network devices for throughput calculation
      final result = await _apiService!.call(
        ip,
        _authService!.sysauth!,
        useHttps,
        object: 'luci-rpc',
        method: 'getNetworkDevices',
        params: {},
      );

      if (result is List && result.length > 1 && result[0] == 0) {
        final networkData = result[1] as Map<String, dynamic>?;

        // Get ALL device names from cached dashboard data (except loopback)
        final wanDeviceNames = <String>{};
        final interfaceDump =
            _dashboardData?['interfaceDump'] as Map<String, dynamic>?;
        if (interfaceDump != null && interfaceDump['interface'] is List) {
          for (final interface in interfaceDump['interface']) {
            if (interface is Map<String, dynamic>) {
              final ifname = interface['interface'] as String?;
              final device = interface['device'] as String?;
              final l3Device = interface['l3_device'] as String?;
              // Include all interfaces except loopback
              if (ifname != null && ifname != 'loopback' && ifname != 'lo') {
                if (device != null) wanDeviceNames.add(device);
                if (l3Device != null && l3Device != device) {
                  wanDeviceNames.add(l3Device);
                }
              }
            }
          }
        }

        // Check if we should track specific interface
        final prefs = _dashboardPreferences;
        String? specificInterface;
        if (!prefs.showAllThroughput &&
            prefs.primaryThroughputInterface != null) {
          // Extract device name from interface ID (format: "SSID (deviceName)" or just "deviceName")
          final interfaceId = prefs.primaryThroughputInterface!;
          if (interfaceId.contains('(')) {
            // Wireless format: "SSID (deviceName)"
            final match = RegExp(r'\(([^)]+)\)').firstMatch(interfaceId);
            specificInterface = match?.group(1);
          } else {
            // Wired format: just device name
            specificInterface = interfaceId;
          }
        }

        _throughputService?.updateThroughput(
          networkData,
          wanDeviceNames,
          specificInterface: specificInterface,
        );
        notifyListeners();
      }
    } catch (e) {
      // Don't log throughput update errors as they're non-critical
    }
  }

  void _cancelThroughputTimer() {
    _throughputTimer?.cancel();
    _systemInfoTimer?.cancel();
    _throughputService?.clear();
  }

  Future<bool> reboot({BuildContext? context}) async {
    if (_authService?.sysauth == null || _authService?.ipAddress == null) {
      return false;
    }

    // Cancel throughput timer before starting reboot to prevent "client closed" errors
    _cancelThroughputTimer();

    _isRebooting = true;
    notifyListeners();

    try {
      final result = await _apiService!.reboot(
        _authService!.ipAddress!,
        _authService!.sysauth!,
        _authService!.useHttps,
        context: context,
      );
      // Wait 30 seconds before starting to poll for router availability
      // Some routers take longer to reboot
      Future.delayed(const Duration(seconds: 30), () {
        _pollRouterAvailability();
      });
      return result;
    } catch (e) {
      _isRebooting = false;
      notifyListeners();
      return false;
    }
  }

  void _pollRouterAvailability() {
    // Reset poll attempts
    _pollAttempts = 0;
    _pollingTimer?.cancel();

    // Start polling with exponential backoff
    _scheduleNextPoll();
  }

  void _scheduleNextPoll() {
    if (_pollAttempts >= _maxPollAttempts) {
      // Max attempts reached, stop polling
      _isRebooting = false;
      notifyListeners();
      // print('[Reboot] Timeout: Router did not come back online after $_maxPollAttempts attempts');

      // Show a user-friendly message
      if (onRouterBackOnline != null) {
        // Reuse the callback to show timeout message
        onRouterBackOnline!();
      }
      return;
    }

    // Calculate delay with exponential backoff: 3s, 3s, 5s, 8s, 12s, 18s, then 20s intervals
    int delaySeconds;
    if (_pollAttempts < 2) {
      delaySeconds = 3;
    } else if (_pollAttempts < 4) {
      delaySeconds = 5;
    } else if (_pollAttempts < 6) {
      delaySeconds = 8;
    } else if (_pollAttempts < 8) {
      delaySeconds = 12;
    } else if (_pollAttempts < 10) {
      delaySeconds = 18;
    } else {
      delaySeconds = 20; // Cap at 20 seconds for remaining attempts
    }

    _pollingTimer = Timer(Duration(seconds: delaySeconds), () async {
      _pollAttempts++;
      final available = await _pingRouter();

      if (available) {
        // Router is back online
        _pollingTimer?.cancel();
        _pollingTimer = null;
        _isRebooting = false;
        _pollAttempts = 0;
        notifyListeners();

        // Notify UI that router is back online
        if (onRouterBackOnline != null) {
          onRouterBackOnline!();
        }

        // Force relogin
        if (_routerService?.selectedRouter != null) {
          await login(
            _routerService!.selectedRouter!.ipAddress,
            _routerService!.selectedRouter!.username,
            _routerService!.selectedRouter!.password,
            _routerService!.selectedRouter!.useHttps,
          );
        }
      } else {
        // Schedule next poll
        _scheduleNextPoll();
      }
    });
  }

  Future<bool> _pingRouter() async {
    if (_authService?.ipAddress == null) return false;

    // Clear cached HTTP clients for this host to avoid stale connections
    if (_pollAttempts == 0) {
      _httpClientManager.disposeClient(
        _authService!.ipAddress!,
        _authService!.useHttps,
      );
    }

    // Try multiple endpoints in order
    final scheme = _authService!.useHttps ? 'https' : 'http';
    final endpoints = [
      '/', // Root
      '/cgi-bin/luci/', // LuCI login page
      '/cgi-bin/luci/admin', // Admin page
    ];

    for (final endpoint in endpoints) {
      try {
        final url = '$scheme://${_authService!.ipAddress}$endpoint';

        // Create a fresh Dio client for pinging to avoid certificate/connection issues
        final dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
            sendTimeout: const Duration(seconds: 5),
            followRedirects: false,
            validateStatus: (code) => code != null && code >= 200 && code < 500,
          ),
        );

        if (_authService!.useHttps) {
          final adapter = IOHttpClientAdapter();
          adapter.createHttpClient = () {
            final httpClient = HttpClient();
            httpClient.connectionTimeout = const Duration(seconds: 5);
            // Accept any cert for ping only
            httpClient.badCertificateCallback = (cert, host, port) => true;
            return httpClient;
          };
          dio.httpClientAdapter = adapter;
        }

        // print('[Ping] Attempt $_pollAttempts: Checking $url');
        final response = await dio.get(url);
        // print('[Ping] Response from $endpoint: ${response.statusCode}');

        // Accept various status codes as "alive"
        final isAlive =
            response.statusCode != null &&
            response.statusCode! >= 200 &&
            response.statusCode! < 500;

        if (isAlive) {
          if (_pollAttempts > 5) {
            // If we've been polling for a while and get a response,
            // wait a bit more to ensure services are fully started
            await Future.delayed(const Duration(seconds: 5));
          }
          return true;
        }
      } catch (e) {
        // Try next endpoint
        if (endpoint == endpoints.last) {
          // print('[Ping] All endpoints failed on attempt $_pollAttempts');
          // print('[Ping] Last error: ${e.toString()}');

          if (e is SocketException) {
            // print('[Ping] Socket error: ${e.message}, OS Error: ${e.osError}');
          } else if (e is HandshakeException) {
            // print('[Ping] SSL handshake error - router may still be starting');
          }
        }
      }
    }

    return false;
  }

  Future<bool> checkRouterAvailability() async {
    if (_reviewerModeEnabled || _authService?.ipAddress == null) {
      return _reviewerModeEnabled;
    }
    return await _authService!.checkRouterAvailability(
      _authService!.ipAddress!,
      _authService!.useHttps,
    );
  }

  Future<bool> setWirelessRadioState(
    String device,
    bool enabled, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      // Simulate operation for reviewer mode
      await Future.delayed(const Duration(milliseconds: 500));
      await fetchDashboardData();
      return true;
    }

    if (_authService?.sysauth == null || _authService?.ipAddress == null) {
      return false;
    }

    try {
      // 1. Set the disabled state
      await _apiService!.uciSet(
        _authService!.ipAddress!,
        _authService!.sysauth!,
        _authService!.useHttps,
        config: 'wireless',
        section: device,
        values: {'disabled': enabled ? '0' : '1'},
        context: context,
      );

      // 2. Commit the changes
      await _apiService!.uciCommit(
        _authService!.ipAddress!,
        _authService!.sysauth!,
        _authService!.useHttps,
        config: 'wireless',
        context: context?.mounted == true ? context : null,
      );

      // 3. Reload wifi to apply changes
      await _apiService!.systemExec(
        _authService!.ipAddress!,
        _authService!.sysauth!,
        _authService!.useHttps,
        command: 'wifi reload',
        context: context?.mounted == true ? context : null,
      );

      // Refresh dashboard data to reflect the change
      await fetchDashboardData();

      return true;
    } catch (e) {
      _dashboardError = 'Failed to toggle Wi-Fi: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> tryAutoLogin({BuildContext? context}) async {
    if (_reviewerModeEnabled) {
      return await _authService!.tryAutoLogin(
        null,
        null,
        null,
        null,
        context: context,
      );
    }
    return await _authService?.tryAutoLogin(
          null,
          null,
          null,
          null,
          context: context,
        ) ??
        false;
  }

  /// Fetch all associated wireless MAC addresses from all wireless interfaces
  Future<Set<String>> fetchAllAssociatedWirelessMacs() async {
    if (_reviewerModeEnabled) {
      // Use the interface method for mock/reviewer mode
      final stationsMap = await _apiService!.fetchAssociatedStations();
      final macs = <String>{};
      stationsMap.forEach((_, stations) {
        macs.addAll(stations.map((m) => m.toLowerCase()));
      });
      return macs;
    } else {
      // Use the context-aware method for real API calls
      if (_routerService?.selectedRouter == null ||
          _authService?.sysauth == null) {
        return {};
      }

      final ip = _routerService!.selectedRouter!.ipAddress;
      final useHttps = _routerService!.selectedRouter!.useHttps;

      final stationsMap = await _apiService!
          .fetchAllAssociatedWirelessMacsWithContext(
            ipAddress: ip,
            sysauth: _authService!.sysauth!,
            useHttps: useHttps,
          );
      final macs = <String>{};
      stationsMap.forEach((_, stations) {
        macs.addAll(stations.map((m) => m.toLowerCase()));
      });
      return macs;
    }
  }

  @override
  void dispose() {
    _throughputTimer?.cancel();
    _systemInfoTimer?.cancel();
    _pollingTimer?.cancel();
    _pollAttempts = 0;
    _isRebooting = false;
    super.dispose();
  }

  /// Aggregates DHCP leases across all configured routers and classifies clients
  /// as wireless if their MAC appears in any router's associated stations list.
  Future<List<Client>> fetchAggregatedClients() async {
    try {
      final activeDeviceRecords = await fetchDeviceRecords(
        aggregateAllRouters: true,
      );
      if (activeDeviceRecords.$1.isNotEmpty) {
        final quarantinedMacs = await fetchAggregatedQuarantinedMacs();
        return _applyQuarantineState(
          _clientsFromDeviceDbRecords(activeDeviceRecords),
          quarantinedMacs,
        );
      }

      final quarantinedMacsFuture = fetchAggregatedQuarantinedMacs();
      final deviceRecordsFuture = fetchDeviceRecords(aggregateAllRouters: true);
      // Build a union of wireless MACs across all routers
      final wirelessMacs = await fetchAllAssociatedWirelessMacsAggregated();
      final normalizedWireless = wirelessMacs
          .map((m) => m.toUpperCase().replaceAll('-', ':'))
          .toSet();

      // Aggregate leases across routers
      final leases = await fetchAggregatedDhcpLeases();

      // Convert to Client models with connection type
      final clients = <String, Client>{}; // key by normalized MAC
      for (final lease in leases) {
        final client = Client.fromLease(lease);
        final macNorm = client.macAddress.toUpperCase().replaceAll('-', ':');
        final isWireless = normalizedWireless.contains(macNorm);
        // If confirmed wireless by assoclist, mark wireless; otherwise keep heuristic
        final enriched = isWireless
            ? client.copyWith(connectionType: ConnectionType.wireless)
            : client;
        // Prefer entries that have more info (hostname length as heuristic)
        if (!clients.containsKey(macNorm) ||
            (enriched.hostname.isNotEmpty &&
                enriched.hostname.length >
                    (clients[macNorm]?.hostname.length ?? 0))) {
          clients[macNorm] = enriched;
        }
      }

      // Add wireless stations not in DHCP leases (AP-mode fallback)
      for (final mac in normalizedWireless) {
        if (!clients.containsKey(mac)) {
          clients[mac] = Client.fromWirelessStation(mac);
        }
      }

      final quarantinedMacs = await quarantinedMacsFuture;
      final deviceRecords = await deviceRecordsFuture;
      final list = _applyQuarantineState(
        _applyDeviceDbRecords(clients.values, deviceRecords),
        quarantinedMacs,
      );

      // Sort: wireless > wired > unknown, then by hostname
      list.sort((a, b) {
        if (a.isBlocked != b.isBlocked) return a.isBlocked ? -1 : 1;
        int typeOrder(ConnectionType t) {
          switch (t) {
            case ConnectionType.wireless:
              return 0;
            case ConnectionType.wired:
              return 1;
            default:
              return 2;
          }
        }

        final cmpType = typeOrder(
          a.connectionType,
        ).compareTo(typeOrder(b.connectionType));
        if (cmpType != 0) return cmpType;
        return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
      });
      return list;
    } catch (e, stack) {
      Logger.exception('Failed to aggregate clients', e, stack);
      return [];
    }
  }

  /// Returns clients for the currently selected router only
  Future<List<Client>> fetchClientsForSelectedRouter() async {
    try {
      if (_reviewerModeEnabled) {
        final quarantinedMacs = await fetchQuarantinedMacsForSelectedRouter();
        final deviceRecords = await fetchDeviceRecords();
        final stationsMap = await _apiService!.fetchAssociatedStations();
        final macs = <String>{};
        stationsMap.forEach((_, stations) {
          macs.addAll(stations.map((m) => m.toLowerCase()));
        });
        final result = await _apiService!.callSimple(
          'luci-rpc',
          'getDHCPLeases',
          {},
        );
        final leases = <Map<String, dynamic>>[];
        if (result is List && result.length > 1 && result[0] == 0) {
          final data = result[1] as Map<String, dynamic>;
          leases.addAll(
            (data['dhcp_leases'] as List<dynamic>? ?? [])
                .cast<Map<String, dynamic>>(),
          );
        }
        // Normalize wireless MACs for consistent lookup
        final normalizedMacs = macs
            .map((m) => m.toUpperCase().replaceAll('-', ':'))
            .toSet();
        final clientMap = <String, Client>{};
        for (final l in leases) {
          final c = Client.fromLease(l);
          final macNorm = c.macAddress.toUpperCase().replaceAll('-', ':');
          final isWireless = normalizedMacs.contains(macNorm);
          clientMap[macNorm] = isWireless
              ? c.copyWith(connectionType: ConnectionType.wireless)
              : c;
        }
        // Add wireless stations not in DHCP leases (AP-mode fallback)
        for (final mac in normalizedMacs) {
          if (!clientMap.containsKey(mac)) {
            clientMap[mac] = Client.fromWirelessStation(mac);
          }
        }
        final reviewerClients = _applyQuarantineState(
          _applyDeviceDbRecords(clientMap.values, deviceRecords),
          quarantinedMacs,
          includeMockDevice: true,
        );
        reviewerClients.sort((a, b) {
          if (a.isBlocked != b.isBlocked) return a.isBlocked ? -1 : 1;
          int typeOrder(ConnectionType t) {
            switch (t) {
              case ConnectionType.wireless:
                return 0;
              case ConnectionType.wired:
                return 1;
              default:
                return 2;
            }
          }

          final cmpType = typeOrder(
            a.connectionType,
          ).compareTo(typeOrder(b.connectionType));
          if (cmpType != 0) return cmpType;
          return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
        });
        return reviewerClients;
      }

      if (_routerService?.selectedRouter == null ||
          _authService?.sysauth == null) {
        return [];
      }
      final router = _routerService!.selectedRouter!;

      final activeDeviceRecords = await fetchDeviceRecords();
      if (activeDeviceRecords.$1.isNotEmpty) {
        final quarantinedMacs = await fetchQuarantinedMacsForSelectedRouter();
        return _applyQuarantineState(
          _clientsFromDeviceDbRecords(activeDeviceRecords),
          quarantinedMacs,
        );
      }

      final stationsFuture = _apiService!
          .fetchAllAssociatedWirelessMacsWithContext(
            ipAddress: router.ipAddress,
            sysauth: _authService!.sysauth!,
            useHttps: router.useHttps,
          )
          .catchError((_) => <String, Set<String>>{});
      final leasesFuture = _apiService!
          .call(
            router.ipAddress,
            _authService!.sysauth!,
            router.useHttps,
            object: 'luci-rpc',
            method: 'getDHCPLeases',
            params: {},
          )
          .catchError((_) => null);
      final deviceRecordsFuture = fetchDeviceRecords();
      final quarantinedMacsFuture = fetchQuarantinedMacsForSelectedRouter();

      final stationsMap = await stationsFuture;
      final wireless = <String>{};
      stationsMap.forEach(
        (_, s) => wireless.addAll(s.map((m) => m.toLowerCase())),
      );

      final callRes = await leasesFuture;
      final leases = <Map<String, dynamic>>[];
      if (callRes is List && callRes.length > 1 && callRes[0] == 0) {
        final data = callRes[1] as Map<String, dynamic>;
        leases.addAll(
          (data['dhcp_leases'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>(),
        );
      }

      // Normalize wireless MACs for consistent lookup
      final normalizedWireless = wireless
          .map((m) => m.toUpperCase().replaceAll('-', ':'))
          .toSet();

      final clientMap = <String, Client>{};
      for (final l in leases) {
        final c = Client.fromLease(l);
        final macNorm = c.macAddress.toUpperCase().replaceAll('-', ':');
        final isWireless = normalizedWireless.contains(macNorm);
        clientMap[macNorm] = isWireless
            ? c.copyWith(connectionType: ConnectionType.wireless)
            : c;
      }

      // Add wireless stations not in DHCP leases (AP-mode fallback)
      for (final mac in normalizedWireless) {
        if (!clientMap.containsKey(mac)) {
          clientMap[mac] = Client.fromWirelessStation(mac);
        }
      }

      final clients = clientMap.values.toList();
      final deviceRecords = await deviceRecordsFuture;
      final quarantinedMacs = await quarantinedMacsFuture;
      final markedClients = _applyQuarantineState(
        _applyDeviceDbRecords(clients, deviceRecords),
        quarantinedMacs,
      );

      // Sort similar to aggregated
      markedClients.sort((a, b) {
        if (a.isBlocked != b.isBlocked) return a.isBlocked ? -1 : 1;
        int typeOrder(ConnectionType t) {
          switch (t) {
            case ConnectionType.wireless:
              return 0;
            case ConnectionType.wired:
              return 1;
            default:
              return 2;
          }
        }

        final cmpType = typeOrder(
          a.connectionType,
        ).compareTo(typeOrder(b.connectionType));
        if (cmpType != 0) return cmpType;
        return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
      });
      return markedClients;
    } catch (e, stack) {
      Logger.exception('Failed to fetch clients for selected router', e, stack);
      return [];
    }
  }

  Future<bool> refreshOpenwallaDeviceInventory({BuildContext? context}) async {
    if (_reviewerModeEnabled) return true;

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      return false;
    }

    try {
      await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'file',
        method: 'exec',
        params: {
          'command': '/usr/bin/openwalla-devices-collector',
          'params': ['--once'],
        },
        context: context,
      );
      return true;
    } catch (e, stack) {
      Logger.debug('Optional manual devices collector refresh failed: $e');
      Logger.debug('Optional manual devices collector refresh stack: $stack');
      return false;
    }
  }

  String _normalizeMacAddress(String mac) =>
      mac.trim().toUpperCase().replaceAll('-', ':');

  static const String _openwallaParentalRulePrefix = 'owrt_parental_';
  static const List<String> _blockedFirewallRulePrefixes = [
    _openwallaParentalRulePrefix,
    'openwalla_parental_',
    'moci_parental_',
    'openwalla_quarantine_',
    'openwalla_schedule_',
  ];

  static const String _mockQuarantineMac = 'AA:BB:CC:DD:EE:FF';

  Client _mockQuarantinedClient() {
    return Client(
      ipAddress: '10.0.0.250',
      macAddress: _mockQuarantineMac,
      hostname: 'Mock Quarantined Device',
      vendor: 'Openwalla Demo',
      dnsName: 'mock-quarantine.local',
      connectionType: ConnectionType.wireless,
      isBlocked: true,
    );
  }

  List<Client> _applyQuarantineState(
    Iterable<Client> clients,
    Set<String> quarantinedMacs, {
    bool includeMockDevice = false,
  }) {
    final normalizedBlocked = quarantinedMacs.map(_normalizeMacAddress).toSet();
    if (includeMockDevice) normalizedBlocked.add(_mockQuarantineMac);

    final clientMap = <String, Client>{};
    for (final client in clients) {
      final mac = _normalizeMacAddress(client.macAddress);
      if (mac.isEmpty || mac == 'N/A') {
        clientMap[mac] = client;
        continue;
      }
      final blocked = client.isBlocked || normalizedBlocked.contains(mac);
      clientMap[mac] = client.copyWith(
        isBlocked: blocked,
        status: blocked ? 'blocked' : client.status,
      );
    }

    if (includeMockDevice && !clientMap.containsKey(_mockQuarantineMac)) {
      clientMap[_mockQuarantineMac] = _mockQuarantinedClient();
    }

    return clientMap.values.toList();
  }

  Iterable<Client> _applyDeviceDbRecords(
    Iterable<Client> clients,
    (Map<String, OpenwallaDeviceRecord>, Map<String, OpenwallaDeviceRecord>)
    deviceRecords,
  ) sync* {
    final byMac = deviceRecords.$1;
    final byIp = deviceRecords.$2;
    for (final client in clients) {
      final mac = _normalizeMacAddress(client.macAddress);
      final record = byMac[mac] ?? byIp[client.ipAddress];
      if (record == null) {
        yield client;
        continue;
      }
      final hostname = record.hostname.trim();
      final isScheduled =
          record.scheduledBlock || record.status == 'block-scheduled';
      final isBlocked =
          record.quarantined || record.status == 'blocked' || isScheduled;
      yield client.copyWith(
        hostname: hostname.isEmpty ? client.hostname : hostname,
        isBlocked: isBlocked,
        totalUploadBytes: record.totalUploadBytes,
        totalDownloadBytes: record.totalDownloadBytes,
        staticIpAddress: record.staticIpAddress.isEmpty
            ? null
            : record.staticIpAddress,
        status: record.quarantined || record.status == 'blocked'
            ? 'blocked'
            : isScheduled
            ? 'block-scheduled'
            : client.status,
        deviceIcon: record.icon.isEmpty ? client.deviceIcon : record.icon,
        scheduledBlockUntil: record.scheduleUntil.isEmpty
            ? client.scheduledBlockUntil
            : record.scheduleUntil,
      );
    }
  }

  Future<Set<String>> fetchQuarantinedMacsForSelectedRouter() async {
    if (_reviewerModeEnabled) return {_mockQuarantineMac};
    if (_routerService?.selectedRouter == null ||
        _authService?.sysauth == null ||
        _apiService == null) {
      return {};
    }

    final router = _routerService!.selectedRouter!;
    try {
      final dbMacs = await _fetchQuarantinedMacsFromDevicesDbForRouter(
        router: router,
        sysauth: _authService!.sysauth!,
        useHttps: router.useHttps,
      );

      final result = await _apiService!.call(
        router.ipAddress,
        _authService!.sysauth!,
        router.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'firewall'},
      );
      return {...dbMacs, ..._extractQuarantinedMacs(result)};
    } catch (e, stack) {
      Logger.warning('Optional quarantine firewall read failed: $e');
      Logger.debug('Optional quarantine firewall stack: $stack');
      return {};
    }
  }

  Future<Set<String>> fetchAggregatedQuarantinedMacs() async {
    if (_reviewerModeEnabled) return {_mockQuarantineMac};

    final routers = _routerService?.routers ?? const <model.Router>[];
    if (routers.isEmpty || _apiService == null) return {};

    final tasks = routers.map((router) async {
      try {
        String? token;
        var useHttps = router.useHttps;
        if (_apiService is RealApiService) {
          final real = _apiService as RealApiService;
          final login = await real.loginWithProtocolDetection(
            router.ipAddress,
            router.username,
            router.password,
            router.useHttps,
          );
          token = login.token;
          useHttps = login.actualUseHttps;
        } else {
          token = _authService?.sysauth;
        }
        if (token == null) return <String>{};
        final dbMacs = await _fetchQuarantinedMacsFromDevicesDbForRouter(
          router: router,
          sysauth: token,
          useHttps: useHttps,
        );

        final result = await _apiService!.call(
          router.ipAddress,
          token,
          useHttps,
          object: 'uci',
          method: 'get',
          params: {'config': 'firewall'},
        );
        return {...dbMacs, ..._extractQuarantinedMacs(result)};
      } catch (e, stack) {
        Logger.warning('Optional aggregated quarantine read failed: $e');
        Logger.debug('Optional aggregated quarantine stack: $stack');
        return <String>{};
      }
    }).toList();

    final results = await Future.wait(tasks);
    return results.fold<Set<String>>(<String>{}, (acc, macs) {
      acc.addAll(macs.map(_normalizeMacAddress));
      return acc;
    });
  }

  Future<Set<String>> _fetchQuarantinedMacsFromDevicesDbForRouter({
    required model.Router router,
    required String sysauth,
    required bool useHttps,
    BuildContext? context,
  }) async {
    try {
      String output;
      try {
        output = await _sqliteQueryOutputForRouter(
          router: router,
          sysauth: sysauth,
          useHttps: useHttps,
          dbExpression: _devicesDbExpression(),
          sql:
              "SELECT mac FROM devices WHERE quarantined = 1 OR status IN ('blocked', 'block-scheduled') OR scheduled_block = 1;",
          context: context,
        );
      } catch (_) {
        output = await _sqliteQueryOutputForRouter(
          router: router,
          sysauth: sysauth,
          useHttps: useHttps,
          dbExpression: _devicesDbExpression(),
          sql:
              "SELECT mac FROM devices WHERE quarantined = 1 OR status IN ('blocked', 'block-scheduled');",
        );
      }
      final macs = output
          .split('\n')
          .map((line) => line.trim())
          .where(
            (line) => RegExp(
              r'^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$',
            ).hasMatch(line),
          )
          .map(_normalizeMacAddress)
          .toSet();
      return macs;
    } catch (e, stack) {
      Logger.debug('Optional devices DB quarantine read failed: $e');
      Logger.debug('Optional devices DB quarantine stack: $stack');
      return {};
    }
  }

  Set<String> _extractQuarantinedMacs(dynamic result) {
    dynamic data = result;
    if (result is List && result.length > 1 && result[0] == 0) {
      data = result[1];
    }

    final values = data is Map ? data['values'] : null;
    final rules = values is Map
        ? values.values
        : data is Map
        ? data.values
        : const [];
    final macs = <String>{};
    for (final rule in rules) {
      if (rule is! Map) continue;
      final name = rule['name']?.toString() ?? '';
      final matchesOpenwallaBlock = _blockedFirewallRulePrefixes.any(
        name.startsWith,
      );
      if (!matchesOpenwallaBlock) continue;
      if ((rule['enabled']?.toString() ?? '1') == '0') continue;
      final srcMac = rule['src_mac']?.toString() ?? '';
      if (RegExp(r'^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$').hasMatch(srcMac)) {
        macs.add(_normalizeMacAddress(srcMac));
      }
    }
    return macs;
  }

  Future<List<OpenwallaDeviceSchedule>> fetchDeviceSchedules({
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      return const [
        OpenwallaDeviceSchedule(
          id: 1,
          name: 'Kids',
          startTime: '21:00',
          endTime: '07:00',
          enabled: true,
          macAddresses: [_mockQuarantineMac],
        ),
      ];
    }
    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) return [];

    final output = await _runOpenwallaScheduler(['list'], context: context);
    final schedules = <OpenwallaDeviceSchedule>[];
    for (final line in output.split('\n')) {
      final parts = line.trim().split('|');
      if (parts.length < 6) continue;
      schedules.add(
        OpenwallaDeviceSchedule(
          id: int.tryParse(parts[0]) ?? 0,
          name: parts[1].trim().isEmpty ? 'Kids' : parts[1].trim(),
          startTime: parts[2].trim().isEmpty ? '21:00' : parts[2].trim(),
          endTime: parts[3].trim().isEmpty ? '07:00' : parts[3].trim(),
          enabled: parts[4].trim() == '1',
          macAddresses: parts[5]
              .split(',')
              .map(_normalizeMacAddress)
              .where((mac) => mac.isNotEmpty)
              .toList(),
          pauseUntil: parts.length > 6 ? int.tryParse(parts[6].trim()) ?? 0 : 0,
        ),
      );
    }
    return schedules;
  }

  Future<OpenwallaActiveSchedule?> fetchActiveScheduleForMac(
    String mac, {
    BuildContext? context,
  }) async {
    final normalizedMac = _normalizeMacAddress(mac);
    if (!RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(normalizedMac)) {
      return null;
    }
    if (_reviewerModeEnabled) {
      return const OpenwallaActiveSchedule(name: 'Kids', endTime: '07:00');
    }
    try {
      final output = await _runOpenwallaScheduler([
        'active-for-mac',
        normalizedMac,
      ], context: context);
      final parts = output.trim().split('|');
      if (parts.length < 2 || parts[0].trim().isEmpty) return null;
      return OpenwallaActiveSchedule(
        name: parts[0].trim(),
        endTime: parts[1].trim(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDeviceSchedule(
    OpenwallaDeviceSchedule schedule, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }
    final args = [
      'save',
      schedule.isNew ? 'new' : schedule.id.toString(),
      schedule.name,
      schedule.startTime,
      schedule.endTime,
      schedule.enabled ? '1' : '0',
      ...schedule.macAddresses.map(_normalizeMacAddress),
    ];
    await _runOpenwallaScheduler(args, context: context);
    await fetchDashboardData();
    notifyListeners();
  }

  Future<void> pauseDeviceSchedule(
    OpenwallaDeviceSchedule schedule,
    Duration duration, {
    BuildContext? context,
  }) async {
    if (schedule.isNew || _reviewerModeEnabled) return;
    final minutes = duration.inMinutes.clamp(1, 10080);
    await _runOpenwallaScheduler([
      'pause',
      schedule.id.toString(),
      minutes.toString(),
    ], context: context);
    await fetchDashboardData();
    notifyListeners();
  }

  Future<void> resumeDeviceSchedule(
    OpenwallaDeviceSchedule schedule, {
    BuildContext? context,
  }) async {
    if (schedule.isNew || _reviewerModeEnabled) return;
    await _runOpenwallaScheduler([
      'resume',
      schedule.id.toString(),
    ], context: context);
    await fetchDashboardData();
    notifyListeners();
  }

  Future<void> deleteDeviceSchedule(
    OpenwallaDeviceSchedule schedule, {
    BuildContext? context,
  }) async {
    if (schedule.isNew || _reviewerModeEnabled) return;
    await _runOpenwallaScheduler([
      'delete',
      schedule.id.toString(),
    ], context: context);
    await fetchDashboardData();
    notifyListeners();
  }

  Future<String> _runOpenwallaScheduler(
    List<String> args, {
    BuildContext? context,
  }) async {
    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }
    final result = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'file',
      method: 'exec',
      params: {'command': '/usr/bin/openwalla-scheduler', 'params': args},
      context: context,
    );
    return _commandOutput(result);
  }

  Future<void> setClientInternetBlocked(Client client, bool blocked) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    final normalizedMac = _normalizeMacAddress(client.macAddress);
    if (!RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(normalizedMac)) {
      throw ArgumentError('A valid device MAC address is required');
    }

    final firewall = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'get',
      params: {'config': 'firewall'},
    );
    final values = _extractUciValues(firewall);
    final sectionsForMac = _blockedFirewallSectionsForMac(
      values,
      normalizedMac,
    );

    if (blocked) {
      final parentalSections = sectionsForMac
          .where((entry) => entry.name.startsWith(_openwallaParentalRulePrefix))
          .toList();
      if (parentalSections.isEmpty) {
        final addResult = await _apiService!.call(
          router.ipAddress,
          sysauth,
          router.useHttps,
          object: 'uci',
          method: 'add',
          params: {'config': 'firewall', 'type': 'rule'},
        );
        final section = _extractAddedSection(addResult);
        if (section == null || section.isEmpty) {
          throw StateError('Unable to create firewall rule section');
        }
        await _apiService!.uciSet(
          router.ipAddress,
          sysauth,
          router.useHttps,
          config: 'firewall',
          section: section,
          values: {
            'name': _buildParentalRuleName(client, normalizedMac),
            'src': 'lan',
            'dest': 'wan',
            'src_mac': normalizedMac,
            'proto': 'all',
            'target': 'REJECT',
            'family': 'any',
            'enabled': '1',
          },
        );
      } else {
        for (final entry in parentalSections) {
          await _apiService!.uciSet(
            router.ipAddress,
            sysauth,
            router.useHttps,
            config: 'firewall',
            section: entry.section,
            values: {
              'src': 'lan',
              'dest': 'wan',
              'src_mac': normalizedMac,
              'proto': 'all',
              'target': 'REJECT',
              'family': 'any',
              'enabled': '1',
            },
          );
        }
      }
      await _updateDeviceDbBlockedState(
        router: router,
        sysauth: sysauth,
        useHttps: router.useHttps,
        mac: normalizedMac,
        blocked: true,
      );
    } else {
      for (final entry in sectionsForMac) {
        await _apiService!.call(
          router.ipAddress,
          sysauth,
          router.useHttps,
          object: 'uci',
          method: 'delete',
          params: {'config': 'firewall', 'section': entry.section},
        );
      }
      await _updateDeviceDbBlockedState(
        router: router,
        sysauth: sysauth,
        useHttps: router.useHttps,
        mac: normalizedMac,
        blocked: false,
      );
    }

    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'firewall',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command:
          '/etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null || true',
    );
    notifyListeners();
  }

  Future<void> saveClientDeviceSettings(
    Client client, {
    required String hostname,
    required bool staticIpEnabled,
    required String staticIpAddress,
    required String deviceIcon,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    final normalizedMac = _normalizeMacAddress(client.macAddress);
    if (!RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(normalizedMac)) {
      throw ArgumentError('A valid device MAC address is required');
    }

    final cleanName = hostname.trim().isEmpty
        ? client.hostname
        : hostname.trim();
    final cleanStaticIp = staticIpEnabled ? staticIpAddress.trim() : '';
    final cleanDeviceIcon = deviceIcon.trim();
    if (cleanStaticIp.isNotEmpty && !_isValidIpAddress(cleanStaticIp)) {
      throw ArgumentError('A valid static IP address is required');
    }

    final dbCommand = _deviceSettingsDbCommand(
      mac: normalizedMac,
      ip: client.ipAddress == 'N/A' ? '' : client.ipAddress,
      hostname: cleanName,
      staticIpAddress: cleanStaticIp,
      deviceIcon: cleanDeviceIcon,
    );
    await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'file',
      method: 'exec',
      params: {
        'command': '/bin/sh',
        'params': ['-c', dbCommand],
      },
      context: context,
    );

    final dhcp = await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'uci',
      method: 'get',
      params: {'config': 'dhcp'},
    );
    final dhcpValues = _extractUciValues(dhcp);
    String? hostSection;
    dhcpValues.forEach((section, values) {
      if (hostSection != null) return;
      if (values['.type']?.toString() != 'host') return;
      final mac = _normalizeMacAddress(values['mac']?.toString() ?? '');
      if (mac == normalizedMac) hostSection = section;
    });

    if (cleanStaticIp.isNotEmpty) {
      if (hostSection == null || hostSection!.isEmpty) {
        final addResult = await _apiService!.call(
          router.ipAddress,
          sysauth,
          router.useHttps,
          object: 'uci',
          method: 'add',
          params: {'config': 'dhcp', 'type': 'host'},
        );
        hostSection = _extractAddedSection(addResult);
      }
      if (hostSection == null || hostSection!.isEmpty) {
        throw StateError('Unable to create DHCP host reservation');
      }
      await _apiService!.uciSet(
        router.ipAddress,
        sysauth,
        router.useHttps,
        config: 'dhcp',
        section: hostSection!,
        values: {
          'name': _sanitizeDhcpHostName(cleanName),
          'mac': normalizedMac,
          'ip': cleanStaticIp,
        },
      );
    } else if (hostSection != null && hostSection!.isNotEmpty) {
      await _apiService!.call(
        router.ipAddress,
        sysauth,
        router.useHttps,
        object: 'uci',
        method: 'delete',
        params: {'config': 'dhcp', 'section': hostSection, 'option': 'ip'},
      );
    }

    await _apiService!.uciCommit(
      router.ipAddress,
      sysauth,
      router.useHttps,
      config: 'dhcp',
    );
    await _apiService!.systemExec(
      router.ipAddress,
      sysauth,
      router.useHttps,
      command:
          '/etc/init.d/dnsmasq restart 2>/dev/null || /etc/init.d/odhcpd restart 2>/dev/null || true',
    );
    await fetchDashboardData();
  }

  Future<void> saveClientDeviceIdentity(
    Client client, {
    required String hostname,
    required String deviceIcon,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      notifyListeners();
      return;
    }

    final router = _routerService?.selectedRouter;
    final sysauth = _authService?.sysauth;
    if (router == null || sysauth == null || _apiService == null) {
      throw StateError('No selected router connection is available');
    }

    final normalizedMac = _normalizeMacAddress(client.macAddress);
    if (!RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(normalizedMac)) {
      throw ArgumentError('A valid device MAC address is required');
    }

    final cleanName = hostname.trim().isEmpty
        ? client.hostname
        : hostname.trim();
    final dbCommand = _deviceIdentityDbCommand(
      mac: normalizedMac,
      ip: client.ipAddress == 'N/A' ? '' : client.ipAddress,
      hostname: cleanName,
      deviceIcon: deviceIcon.trim(),
    );
    await _apiService!.call(
      router.ipAddress,
      sysauth,
      router.useHttps,
      object: 'file',
      method: 'exec',
      params: {
        'command': '/bin/sh',
        'params': ['-c', dbCommand],
      },
      context: context,
    );
    notifyListeners();
  }

  String _deviceIdentityDbCommand({
    required String mac,
    required String ip,
    required String hostname,
    required String deviceIcon,
  }) {
    final escMac = mac.toLowerCase().replaceAll("'", "''");
    final escIp = ip.replaceAll("'", "''");
    final escHostname = hostname.replaceAll("'", "''");
    final escDeviceIcon = deviceIcon.replaceAll("'", "''");
    final upsertSql =
        "INSERT INTO devices (mac, ip, hostname, icon) VALUES ('$escMac', '$escIp', '$escHostname', '$escDeviceIcon') ON CONFLICT(mac) DO UPDATE SET hostname=excluded.hostname, icon=excluded.icon, ip=CASE WHEN excluded.ip != '' THEN excluded.ip ELSE devices.ip END;";
    return 'db="${_devicesDbExpression()}"; '
        'if command -v sqlite3 >/dev/null 2>&1; then sqlite=sqlite3; '
        'elif command -v sqlite3-cli >/dev/null 2>&1; then sqlite=sqlite3-cli; '
        'else echo "sqlite3 not installed" >&2; exit 127; fi; '
        '"\$sqlite" "\$db" ${_shellQuote(upsertSql)}';
  }

  String _deviceSettingsDbCommand({
    required String mac,
    required String ip,
    required String hostname,
    required String staticIpAddress,
    required String deviceIcon,
  }) {
    final escMac = mac.toLowerCase().replaceAll("'", "''");
    final escIp = ip.replaceAll("'", "''");
    final escHostname = hostname.replaceAll("'", "''");
    final escStaticIp = staticIpAddress.replaceAll("'", "''");
    final escDeviceIcon = deviceIcon.replaceAll("'", "''");
    const createSql =
        "CREATE TABLE IF NOT EXISTS devices (mac TEXT PRIMARY KEY, ip TEXT NOT NULL DEFAULT '', hostname TEXT NOT NULL DEFAULT '', vendor TEXT NOT NULL DEFAULT '', quarantined INTEGER NOT NULL DEFAULT 0, last_seen INTEGER NOT NULL DEFAULT 0, total_up INTEGER NOT NULL DEFAULT 0, total_down INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'offline', static_ip TEXT NOT NULL DEFAULT '', icon TEXT NOT NULL DEFAULT '', scheduled_block INTEGER NOT NULL DEFAULT 0, schedule_until TEXT NOT NULL DEFAULT '');";
    final upsertSql =
        "DELETE FROM devices WHERE lower(mac) = '$escMac' AND mac != '$escMac'; INSERT INTO devices (mac, ip, hostname, static_ip, icon, last_seen, status) VALUES ('$escMac', '$escIp', '$escHostname', '$escStaticIp', '$escDeviceIcon', strftime('%s','now'), 'online') ON CONFLICT(mac) DO UPDATE SET hostname=excluded.hostname, ip=CASE WHEN excluded.ip != '' THEN excluded.ip ELSE devices.ip END, static_ip=excluded.static_ip, icon=excluded.icon, last_seen=excluded.last_seen, status=CASE WHEN devices.quarantined=1 THEN 'blocked' WHEN devices.scheduled_block=1 THEN 'block-scheduled' ELSE 'online' END;";
    return 'db="${_devicesDbExpression()}"; '
        'if command -v sqlite3 >/dev/null 2>&1; then sqlite=sqlite3; '
        'elif command -v sqlite3-cli >/dev/null 2>&1; then sqlite=sqlite3-cli; '
        'else echo "sqlite3 not installed" >&2; exit 127; fi; '
        '"\$sqlite" "\$db" ${_shellQuote(createSql)}; '
        '"\$sqlite" "\$db" "ALTER TABLE devices ADD COLUMN static_ip TEXT NOT NULL DEFAULT \'\';" 2>/dev/null || true; '
        '"\$sqlite" "\$db" "ALTER TABLE devices ADD COLUMN icon TEXT NOT NULL DEFAULT \'\';" 2>/dev/null || true; '
        '"\$sqlite" "\$db" "ALTER TABLE devices ADD COLUMN scheduled_block INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true; '
        '"\$sqlite" "\$db" "ALTER TABLE devices ADD COLUMN schedule_until TEXT NOT NULL DEFAULT \'\';" 2>/dev/null || true; '
        '"\$sqlite" "\$db" ${_shellQuote(upsertSql)}';
  }

  String _sanitizeDhcpHostName(String hostname) {
    final sanitized = hostname
        .trim()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '');
    return sanitized.isEmpty ? 'openwalla-device' : sanitized;
  }

  Map<String, Map<String, dynamic>> _extractUciValues(dynamic result) {
    final data = _extractRpcData(result);
    final rawValues = data is Map && data['values'] is Map
        ? data['values'] as Map
        : data is Map
        ? data
        : const {};
    final values = <String, Map<String, dynamic>>{};
    rawValues.forEach((key, value) {
      if (value is Map) {
        values[key.toString()] = Map<String, dynamic>.from(value);
      }
    });
    return values;
  }

  List<({String section, String name})> _blockedFirewallSectionsForMac(
    Map<String, Map<String, dynamic>> values,
    String mac,
  ) {
    final matches = <({String section, String name})>[];
    values.forEach((section, cfg) {
      if (cfg['.type']?.toString() != 'rule') return;
      final name = cfg['name']?.toString().trim() ?? '';
      if (!_blockedFirewallRulePrefixes.any(name.startsWith)) return;
      final srcMac = _normalizeMacAddress(
        cfg['src_mac']?.toString() ?? cfg['src_mac_address']?.toString() ?? '',
      );
      if (srcMac == mac) matches.add((section: section, name: name));
    });
    return matches;
  }

  String? _extractAddedSection(dynamic result) {
    final data = _extractRpcData(result);
    if (data is Map) {
      return (data['section'] ?? data['name'])?.toString();
    }
    if (data is String) return data;
    return null;
  }

  String _buildParentalRuleName(Client client, String mac) {
    final sanitizedHost = client.hostname
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '')
        .toLowerCase();
    if (sanitizedHost.isNotEmpty && sanitizedHost != 'unknown') {
      final end = sanitizedHost.length > 32 ? 32 : sanitizedHost.length;
      return '$_openwallaParentalRulePrefix${sanitizedHost.substring(0, end)}';
    }
    return '$_openwallaParentalRulePrefix${mac.replaceAll(':', '')}';
  }

  String _buildFlowBlockRuleName(String destinationIp) {
    final hint = destinationIp
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9.:-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return 'owrt_flow_block_${hint.isEmpty ? 'ip' : hint}_$stamp';
  }

  String _sanitizeDomain(String value) {
    final domain = value.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (domain.isEmpty) return '';
    if (domain.length > 253 ||
        domain.startsWith('.') ||
        domain.endsWith('.') ||
        domain.contains('..')) {
      return '';
    }
    if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(domain)) return '';
    if (_isValidIpAddress(domain)) return '';
    return domain;
  }

  String _extractRootDomain(String domain) {
    final sanitized = _sanitizeDomain(domain);
    if (sanitized.isEmpty) return '';
    final parts = sanitized
        .split('.')
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length < 2) return sanitized;

    const secondLevelTlds = {
      'co.uk',
      'org.uk',
      'ac.uk',
      'gov.uk',
      'co.jp',
      'com.au',
      'net.au',
      'org.au',
      'co.nz',
    };
    final lastTwo = parts.sublist(parts.length - 2).join('.');
    if (parts.length >= 3 && secondLevelTlds.contains(lastTwo)) {
      return parts.sublist(parts.length - 3).join('.');
    }
    return lastTwo;
  }

  bool _isValidIpAddress(String value) =>
      InternetAddress.tryParse(value.trim()) != null;

  bool _isIpv6Address(String value) =>
      InternetAddress.tryParse(value.trim())?.type == InternetAddressType.IPv6;

  Future<void> _updateDeviceDbBlockedState({
    required model.Router router,
    required String sysauth,
    required bool useHttps,
    required String mac,
    required bool blocked,
    BuildContext? context,
  }) async {
    final escMac = mac.toLowerCase().replaceAll("'", "''");
    const createSql =
        "CREATE TABLE IF NOT EXISTS devices (mac TEXT PRIMARY KEY, ip TEXT NOT NULL DEFAULT '', hostname TEXT NOT NULL DEFAULT '', vendor TEXT NOT NULL DEFAULT '', quarantined INTEGER NOT NULL DEFAULT 0, last_seen INTEGER NOT NULL DEFAULT 0, total_up INTEGER NOT NULL DEFAULT 0, total_down INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'offline');";
    final sql = blocked
        ? "$createSql DELETE FROM devices WHERE lower(mac) = '$escMac' AND mac != '$escMac'; INSERT INTO devices (mac, last_seen, status, quarantined) VALUES ('$escMac', strftime('%s','now'), 'blocked', 1) ON CONFLICT(mac) DO UPDATE SET status='blocked', quarantined=1, last_seen=strftime('%s','now');"
        : "$createSql DELETE FROM devices WHERE lower(mac) = '$escMac' AND mac != '$escMac'; UPDATE devices SET quarantined = 0, status = 'online', last_seen=strftime('%s','now') WHERE mac = '$escMac';";
    try {
      await _sqliteQueryOutputForRouter(
        router: router,
        sysauth: sysauth,
        useHttps: useHttps,
        dbExpression: _devicesDbExpression(),
        sql: sql,
        context: context,
      );
    } catch (e, stack) {
      Logger.debug('Optional devices DB blocked-state update failed: $e');
      Logger.debug('Optional devices DB blocked-state update stack: $stack');
    }
  }

  /// Returns a union set of associated wireless MAC addresses across all routers
  Future<Set<String>> fetchAllAssociatedWirelessMacsAggregated() async {
    try {
      if (_reviewerModeEnabled) {
        final stationsMap = await _apiService!.fetchAssociatedStations();
        final macs = <String>{};
        stationsMap.forEach((_, stations) {
          macs.addAll(stations.map((m) => m.toLowerCase()));
        });
        return macs;
      }

      final routers = _routerService?.routers ?? const <model.Router>[];
      if (routers.isEmpty) return {};

      final tasks = routers.map((r) async {
        try {
          if (_apiService is RealApiService) {
            final real = _apiService as RealApiService;
            final res = await real.loginWithProtocolDetection(
              r.ipAddress,
              r.username,
              r.password,
              r.useHttps,
            );
            if (res.token == null) return <String>{};
            final map = await _apiService!
                .fetchAllAssociatedWirelessMacsWithContext(
                  ipAddress: r.ipAddress,
                  sysauth: res.token!,
                  useHttps: res.actualUseHttps,
                );
            final set = <String>{};
            map.forEach((_, stations) {
              set.addAll(stations.map((m) => m.toLowerCase()));
            });
            return set;
          }
        } catch (e) {
          // Skip router on failure
        }
        return <String>{};
      }).toList();

      final results = await Future.wait(tasks);
      return results.fold<Set<String>>(<String>{}, (acc, s) => acc..addAll(s));
    } catch (e, stack) {
      Logger.exception('Failed to aggregate wireless MACs', e, stack);
      return {};
    }
  }

  /// Returns a combined list of DHCP lease maps from all routers
  Future<List<Map<String, dynamic>>> fetchAggregatedDhcpLeases() async {
    try {
      if (_reviewerModeEnabled) {
        // Use mock data
        final result = await _apiService!.callSimple(
          'luci-rpc',
          'getDHCPLeases',
          {},
        );
        if (result is List && result.length > 1 && result[0] == 0) {
          final data = result[1] as Map<String, dynamic>;
          final leases = (data['dhcp_leases'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          return leases;
        }
        return [];
      }

      final routers = _routerService?.routers ?? const <model.Router>[];
      if (routers.isEmpty) return [];

      final tasks = routers.map((r) async {
        try {
          if (_apiService is RealApiService) {
            final real = _apiService as RealApiService;
            final res = await real.loginWithProtocolDetection(
              r.ipAddress,
              r.username,
              r.password,
              r.useHttps,
            );
            if (res.token == null) return <Map<String, dynamic>>[];
            final callRes = await _apiService!.call(
              r.ipAddress,
              res.token!,
              res.actualUseHttps,
              object: 'luci-rpc',
              method: 'getDHCPLeases',
              params: {},
            );
            if (callRes is List && callRes.length > 1 && callRes[0] == 0) {
              final data = callRes[1] as Map<String, dynamic>;
              final leases = (data['dhcp_leases'] as List<dynamic>? ?? [])
                  .cast<Map<String, dynamic>>();
              return leases;
            }
          }
        } catch (e) {
          // Skip router on failure
        }
        return <Map<String, dynamic>>[];
      }).toList();

      final results = await Future.wait(tasks);
      // Deduplicate by MAC + IP
      final seen = <String, Map<String, dynamic>>{};
      for (final list in results) {
        for (final lease in list) {
          final mac = (lease['macaddr']?.toString() ?? '').toUpperCase();
          final ip = lease['ipaddr']?.toString() ?? '';
          final key = '$mac|$ip';
          if (!seen.containsKey(key)) {
            seen[key] = lease;
          }
        }
      }
      return seen.values.toList();
    } catch (e, stack) {
      Logger.exception('Failed to aggregate DHCP leases', e, stack);
      return [];
    }
  }
}
