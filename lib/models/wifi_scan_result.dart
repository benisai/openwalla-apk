class WifiScanResult {
  final String ssid;
  final String bssid;
  final String mode;
  final int channel;
  final int? frequency;
  final int signal;
  final int quality;
  final int qualityMax;
  final WifiEncryption encryption;

  const WifiScanResult({
    required this.ssid,
    required this.bssid,
    required this.mode,
    required this.channel,
    this.frequency,
    required this.signal,
    required this.quality,
    required this.qualityMax,
    required this.encryption,
  });

  factory WifiScanResult.fromJson(Map<String, dynamic> json) {
    return WifiScanResult(
      ssid: _safeString(json['ssid']),
      bssid: _safeString(json['bssid']),
      mode: _safeString(json['mode'], 'Unknown'),
      channel: _safeInt(json['channel']),
      frequency: _safeFrequency(json['frequency']),
      signal: _safeInt(json['signal'], -100),
      quality: _safeInt(json['quality']),
      qualityMax: _safeInt(json['quality_max'], 100),
      encryption: WifiEncryption.fromJson(
        json['encryption'] is Map<String, dynamic>
            ? json['encryption'] as Map<String, dynamic>
            : const {},
      ),
    );
  }

  static String _safeString(dynamic value, [String fallback = '']) {
    final text = value?.toString() ?? fallback;
    return text.trim().isEmpty ? fallback : text;
  }

  static int _safeInt(dynamic value, [int fallback = 0]) {
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static int? _safeFrequency(dynamic value) {
    final parsed = _safeInt(value);
    if (parsed >= 2400 && parsed <= 2500) return parsed;
    if (parsed >= 4900 && parsed <= 7125) return parsed;
    return null;
  }

  int get qualityPercent {
    if (qualityMax <= 0) return 0;
    return ((quality / qualityMax) * 100).round().clamp(0, 100);
  }

  String get band {
    final mhz = frequency;
    if (mhz != null) {
      if (mhz >= 5925) return '6 GHz';
      if (mhz >= 5000) return '5 GHz';
      if (mhz >= 4900) return '4.9 GHz';
      return '2.4 GHz';
    }
    if (channel >= 1 && channel <= 14) return '2.4 GHz';
    if (channel >= 32) return '5 GHz';
    return 'Unknown';
  }
}

class WifiEncryption {
  final bool enabled;
  final String description;
  final bool wep;
  final int wpa;
  final List<String> authSuites;

  const WifiEncryption({
    required this.enabled,
    required this.description,
    required this.wep,
    required this.wpa,
    required this.authSuites,
  });

  factory WifiEncryption.fromJson(Map<String, dynamic> json) {
    final rawWpa = json['wpa'];
    var wpaVersion = 0;
    if (rawWpa is int) {
      wpaVersion = rawWpa;
    } else if (rawWpa is List) {
      for (final value in rawWpa) {
        final parsed = WifiScanResult._safeInt(value);
        if (parsed > wpaVersion) wpaVersion = parsed;
      }
    }
    final authSuites = [
      ..._toStringList(json['auth_suites']),
      ..._toStringList(json['authentication']),
    ];
    final wep = json['wep'] == true;
    final enabled = json['enabled'] == true || wep || wpaVersion > 0;
    final description = json['description']?.toString().trim();
    return WifiEncryption(
      enabled: enabled,
      description: description == null || description.isEmpty
          ? _buildDescription(enabled, wep, wpaVersion, authSuites)
          : description,
      wep: wep,
      wpa: wpaVersion,
      authSuites: authSuites,
    );
  }

  static List<String> _toStringList(dynamic value) {
    if (value is! List) return const [];
    return value.map((entry) => entry.toString().toUpperCase()).toList();
  }

  static String _buildDescription(
    bool enabled,
    bool wep,
    int wpa,
    List<String> auth,
  ) {
    if (!enabled) return 'Open';
    if (wep) return 'WEP';
    final label = wpa >= 3
        ? 'WPA3'
        : wpa >= 2
        ? 'WPA2'
        : 'WPA';
    return auth.isEmpty ? label : '$label ${auth.join('/')}';
  }

  String get shortLabel {
    if (!enabled) return 'Open';
    if (wep) return 'WEP';
    if (description.contains('WPA3')) return 'WPA3';
    if (description.contains('WPA2')) return 'WPA2';
    if (description.contains('WPA')) return 'WPA';
    return description;
  }

  String get openwrtEncryption {
    if (!enabled) return 'none';
    if (wep) return 'wep-open';
    final hasSae = authSuites.contains('SAE');
    final hasPsk = authSuites.contains('PSK');
    final hasOwe = authSuites.contains('OWE');
    final hasEap = authSuites.contains('EAP') || authSuites.contains('802.1X');
    if (hasOwe) return 'owe';
    if (hasEap && !hasSae && !hasPsk) return 'wpa-eap';
    if (hasSae && hasPsk) return 'sae-mixed';
    if (hasSae) return 'sae';
    if (wpa >= 2) return 'psk2';
    return 'psk';
  }
}
