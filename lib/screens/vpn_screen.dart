import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/state/app_state.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/widgets/openwrt_feature_gate.dart';

enum _VpnPanel { server, client }

class VpnScreen extends ConsumerStatefulWidget {
  const VpnScreen({super.key});

  @override
  ConsumerState<VpnScreen> createState() => _VpnScreenState();
}

class _VpnScreenState extends ConsumerState<VpnScreen> {
  _VpnPanel _panel = _VpnPanel.server;
  WireGuardServerSettings _settings = WireGuardServerSettings.defaults;
  WireGuardClientSettings _clientSettings = WireGuardClientSettings.defaults;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _hasStartedLoad = false;
  String? _error;

  final _portController = TextEditingController(text: '51820');
  final _vpnAddressController = TextEditingController(text: '10.8.0.1/24');
  final _clientConfigController = TextEditingController();
  final _clientAddressController = TextEditingController();
  final _clientDnsController = TextEditingController();
  final _clientPrivateKeyController = TextEditingController();
  final _clientPeerPublicKeyController = TextEditingController();
  final _clientPresharedKeyController = TextEditingController();
  final _clientEndpointHostController = TextEditingController();
  final _clientEndpointPortController = TextEditingController(text: '51820');
  final _clientAllowedIpsController = TextEditingController(
    text: '0.0.0.0/0, ::/0',
  );
  final _clientKeepaliveController = TextEditingController(text: '25');

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _portController.dispose();
    _vpnAddressController.dispose();
    _clientConfigController.dispose();
    _clientAddressController.dispose();
    _clientDnsController.dispose();
    _clientPrivateKeyController.dispose();
    _clientPeerPublicKeyController.dispose();
    _clientPresharedKeyController.dispose();
    _clientEndpointHostController.dispose();
    _clientEndpointPortController.dispose();
    _clientAllowedIpsController.dispose();
    _clientKeepaliveController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final appState = ref.read(appStateProvider);
      final settings = await appState.fetchWireGuardServerSettings();
      final clientSettings = await appState.fetchWireGuardClientSettings();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _clientSettings = clientSettings;
        _portController.text = settings.listenPort.toString();
        _vpnAddressController.text = settings.vpnAddress;
        _syncClientControllers(clientSettings);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Unable to load WireGuard server settings.';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveServer() async {
    final port = int.tryParse(_portController.text.trim());
    final vpnAddress = _vpnAddressController.text.trim();

    if (port == null || port < 1 || port > 65535) {
      _showSnack('Enter a UDP port between 1 and 65535.');
      return;
    }
    if (!_looksLikeCidr(vpnAddress)) {
      _showSnack('Enter the VPN address as CIDR, like 10.8.0.1/24.');
      return;
    }
    setState(() => _isSaving = true);
    try {
      final updated = WireGuardServerSettings(
        installed: _settings.installed,
        configured: _settings.configured,
        enabled: _settings.enabled,
        interfaceName: _settings.interfaceName,
        listenPort: port,
        vpnAddress: vpnAddress,
        internalIpAddress: '',
        publicKey: _settings.publicKey,
      );
      await ref
          .read(appStateProvider)
          .saveWireGuardServerSettings(updated, context: context);
      if (!mounted) return;
      _showSnack('WireGuard server settings saved.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showSnack('Failed to save WireGuard server: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveClient() async {
    final endpointPort = int.tryParse(
      _clientEndpointPortController.text.trim(),
    );
    final keepalive = int.tryParse(_clientKeepaliveController.text.trim());
    final address = _clientAddressController.text.trim();

    if (address.isEmpty) {
      _showSnack('Import or enter the WireGuard client address.');
      return;
    }
    if (!address
        .split(',')
        .map((value) => value.trim())
        .every(_looksLikeIpCidr)) {
      _showSnack('Enter client addresses as CIDR values, like 10.64.0.2/32.');
      return;
    }
    if (_clientPrivateKeyController.text.trim().isEmpty) {
      _showSnack('WireGuard client private key is required.');
      return;
    }
    if (_clientPeerPublicKeyController.text.trim().isEmpty) {
      _showSnack('WireGuard peer public key is required.');
      return;
    }
    if (_clientEndpointHostController.text.trim().isEmpty) {
      _showSnack('WireGuard endpoint host is required.');
      return;
    }
    if (endpointPort == null || endpointPort < 1 || endpointPort > 65535) {
      _showSnack('Enter an endpoint port between 1 and 65535.');
      return;
    }
    if (keepalive == null || keepalive < 0 || keepalive > 65535) {
      _showSnack('Enter a keepalive value from 0 to 65535.');
      return;
    }

    final updated = WireGuardClientSettings(
      installed: _clientSettings.installed,
      configured: _clientSettings.configured,
      enabled: _clientSettings.enabled,
      interfaceName: _clientSettings.interfaceName,
      address: address,
      dns: _clientDnsController.text.trim(),
      privateKey: _clientPrivateKeyController.text.trim(),
      peerPublicKey: _clientPeerPublicKeyController.text.trim(),
      presharedKey: _clientPresharedKeyController.text.trim(),
      endpointHost: _clientEndpointHostController.text.trim(),
      endpointPort: endpointPort,
      allowedIps: _clientAllowedIpsController.text.trim(),
      persistentKeepalive: keepalive,
      routeAllowedIps: _clientSettings.routeAllowedIps,
    );

    setState(() => _isSaving = true);
    try {
      await ref
          .read(appStateProvider)
          .saveWireGuardClientSettings(updated, context: context);
      if (!mounted) return;
      _showSnack('WireGuard client settings saved.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showSnack('Failed to save WireGuard client: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _syncClientControllers(WireGuardClientSettings settings) {
    _clientAddressController.text = settings.address;
    _clientDnsController.text = settings.dns;
    _clientPrivateKeyController.text = settings.privateKey;
    _clientPeerPublicKeyController.text = settings.peerPublicKey;
    _clientPresharedKeyController.text = settings.presharedKey;
    _clientEndpointHostController.text = settings.endpointHost;
    _clientEndpointPortController.text = settings.endpointPort.toString();
    _clientAllowedIpsController.text = settings.allowedIps;
    _clientKeepaliveController.text = settings.persistentKeepalive.toString();
  }

  Future<void> _pickClientConfig() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['conf', 'txt'],
        withData: true,
      );
      final file = result?.files.single;
      final bytes = file?.bytes;
      if (bytes == null) return;
      final configText = utf8.decode(bytes, allowMalformed: true);
      _clientConfigController.text = configText;
      _importClientConfig(configText);
    } catch (e) {
      _showSnack('Unable to read WireGuard config: $e');
    }
  }

  void _importClientConfig([String? configText]) {
    final parsed = _ParsedWireGuardConfig.parse(
      configText ?? _clientConfigController.text,
    );
    if (parsed == null) {
      _showSnack('This does not look like a WireGuard client config.');
      return;
    }

    final endpoint = _splitEndpoint(parsed.endpoint);
    setState(() {
      _clientAddressController.text = parsed.address;
      _clientDnsController.text = parsed.dns;
      _clientPrivateKeyController.text = parsed.privateKey;
      _clientPeerPublicKeyController.text = parsed.peerPublicKey;
      _clientPresharedKeyController.text = parsed.presharedKey;
      _clientEndpointHostController.text = endpoint.$1;
      _clientEndpointPortController.text = endpoint.$2.toString();
      _clientAllowedIpsController.text = parsed.allowedIps.isEmpty
          ? '0.0.0.0/0, ::/0'
          : parsed.allowedIps;
      _clientKeepaliveController.text = parsed.persistentKeepalive.isEmpty
          ? '25'
          : parsed.persistentKeepalive;
      _clientSettings = WireGuardClientSettings(
        installed: _clientSettings.installed,
        configured: _clientSettings.configured,
        enabled: _clientSettings.enabled,
        interfaceName: _clientSettings.interfaceName,
        address: _clientAddressController.text,
        dns: _clientDnsController.text,
        privateKey: _clientPrivateKeyController.text,
        peerPublicKey: _clientPeerPublicKeyController.text,
        presharedKey: _clientPresharedKeyController.text,
        endpointHost: _clientEndpointHostController.text,
        endpointPort: int.tryParse(_clientEndpointPortController.text) ?? 51820,
        allowedIps: _clientAllowedIpsController.text,
        persistentKeepalive:
            int.tryParse(_clientKeepaliveController.text) ?? 25,
        routeAllowedIps: _clientSettings.routeAllowedIps,
      );
    });
    _showSnack('WireGuard config imported. Review and save to apply.');
  }

  (String, int) _splitEndpoint(String endpoint) {
    final value = endpoint.trim();
    if (value.startsWith('[')) {
      final end = value.indexOf(']');
      if (end > 0) {
        final host = value.substring(1, end);
        final port = value.length > end + 2 && value[end + 1] == ':'
            ? int.tryParse(value.substring(end + 2)) ?? 51820
            : 51820;
        return (host, port);
      }
    }
    final separator = value.lastIndexOf(':');
    if (separator <= 0) return (value, 51820);
    return (
      value.substring(0, separator),
      int.tryParse(value.substring(separator + 1)) ?? 51820,
    );
  }

  bool _looksLikeIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      final number = int.tryParse(part);
      return number != null && number >= 0 && number <= 255;
    });
  }

  bool _looksLikeCidr(String value) {
    final parts = value.split('/');
    if (parts.length != 2 || !_looksLikeIpv4(parts[0])) return false;
    final prefix = int.tryParse(parts[1]);
    return prefix != null && prefix >= 1 && prefix <= 32;
  }

  bool _looksLikeIpCidr(String value) {
    final trimmed = value.trim();
    if (trimmed.contains(':')) return trimmed.contains('/');
    return _looksLikeCidr(trimmed);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _updateEnabled(bool enabled) {
    setState(() {
      _settings = WireGuardServerSettings(
        installed: _settings.installed,
        configured: _settings.configured,
        enabled: enabled,
        interfaceName: _settings.interfaceName,
        listenPort: _settings.listenPort,
        vpnAddress: _settings.vpnAddress,
        internalIpAddress: _settings.internalIpAddress,
        publicKey: _settings.publicKey,
      );
    });
  }

  void _updateClientEnabled(bool enabled) {
    setState(() {
      _clientSettings = WireGuardClientSettings(
        installed: _clientSettings.installed,
        configured: _clientSettings.configured,
        enabled: enabled,
        interfaceName: _clientSettings.interfaceName,
        address: _clientSettings.address,
        dns: _clientSettings.dns,
        privateKey: _clientSettings.privateKey,
        peerPublicKey: _clientSettings.peerPublicKey,
        presharedKey: _clientSettings.presharedKey,
        endpointHost: _clientSettings.endpointHost,
        endpointPort: _clientSettings.endpointPort,
        allowedIps: _clientSettings.allowedIps,
        persistentKeepalive: _clientSettings.persistentKeepalive,
        routeAllowedIps: _clientSettings.routeAllowedIps,
      );
    });
  }

  void _updateClientRouteAllowed(bool routeAllowedIps) {
    setState(() {
      _clientSettings = WireGuardClientSettings(
        installed: _clientSettings.installed,
        configured: _clientSettings.configured,
        enabled: _clientSettings.enabled,
        interfaceName: _clientSettings.interfaceName,
        address: _clientSettings.address,
        dns: _clientSettings.dns,
        privateKey: _clientSettings.privateKey,
        peerPublicKey: _clientSettings.peerPublicKey,
        presharedKey: _clientSettings.presharedKey,
        endpointHost: _clientSettings.endpointHost,
        endpointPort: _clientSettings.endpointPort,
        allowedIps: _clientSettings.allowedIps,
        persistentKeepalive: _clientSettings.persistentKeepalive,
        routeAllowedIps: routeAllowedIps,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const LuciAppBar(title: 'VPN', showBack: true),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Text(
                'WireGuard VPN',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Configure WireGuard server access on this router.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 16),
              OpenwrtFeatureGate(
                feature: OpenwrtFeature.wireguard,
                title: 'WireGuard is not installed',
                message:
                    'Install wireguard-tools on this OpenWrt router before configuring VPN server or client settings.',
                installLabel: 'Install WireGuard',
                builder: (_) => _buildInstalledContent(colorScheme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstalledContent(ColorScheme colorScheme) {
    if (!_hasStartedLoad) {
      _hasStartedLoad = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    return Column(
      children: [
        SegmentedButton<_VpnPanel>(
          segments: const [
            ButtonSegment(
              value: _VpnPanel.server,
              label: Text('Server'),
              icon: Icon(Icons.dns_rounded),
            ),
            ButtonSegment(
              value: _VpnPanel.client,
              label: Text('Client'),
              icon: Icon(Icons.vpn_lock_rounded),
            ),
          ],
          selected: {_panel},
          onSelectionChanged: (selection) {
            setState(() => _panel = selection.first);
          },
        ),
        const SizedBox(height: 16),
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 60),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          _VpnPanelCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_error!, style: TextStyle(color: colorScheme.error)),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                ),
              ],
            ),
          )
        else if (_panel == _VpnPanel.server)
          _buildServerPanel()
        else
          _buildClientPanel(),
      ],
    );
  }

  Widget _buildServerPanel() {
    final colorScheme = Theme.of(context).colorScheme;
    return _VpnPanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'WireGuard Server',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              _StatusPill(
                label: _settings.configured ? 'Configured' : 'Not configured',
                color: _settings.configured
                    ? const Color(0xFF20CF70)
                    : colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (!_settings.installed)
            _WarningBox(
              message:
                  'wireguard-tools is not installed. Install it from Router Setup or opkg before saving.',
            ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable Server'),
            subtitle: Text(_settings.interfaceName),
            value: _settings.enabled,
            onChanged: _isSaving ? null : _updateEnabled,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _portController,
            decoration: const InputDecoration(
              labelText: 'Listen Port',
              helperText: 'The UDP port exposed on WAN.',
              prefixIcon: Icon(Icons.settings_ethernet_rounded),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            enabled: !_isSaving,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _vpnAddressController,
            decoration: const InputDecoration(
              labelText: 'VPN Address',
              helperText: 'Server tunnel address, for example 10.8.0.1/24.',
              prefixIcon: Icon(Icons.vpn_key_rounded),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.text,
            enabled: !_isSaving,
          ),
          const SizedBox(height: 14),
          _DetailRow(label: 'Interface', value: _settings.interfaceName),
          _DetailRow(label: 'Firewall zone', value: 'LAN'),
          _DetailRow(
            label: 'WAN access',
            value: 'UDP ${_portController.text.trim()}',
          ),
          _DetailRow(label: 'Public key', value: _settings.publicKey),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _saveServer,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded),
              label: Text(_isSaving ? 'Saving' : 'Save Server'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClientPanel() {
    final colorScheme = Theme.of(context).colorScheme;
    return _VpnPanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'WireGuard Client',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              _StatusPill(
                label: _clientSettings.configured
                    ? 'Configured'
                    : 'Not configured',
                color: _clientSettings.configured
                    ? const Color(0xFF20CF70)
                    : colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (!_clientSettings.installed)
            _WarningBox(
              message:
                  'wireguard-tools is not installed. Install WireGuard from Router Setup or opkg before saving.',
            ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable Client'),
            subtitle: Text(
              _clientSettings.interfaceName == 'owrt_wg_client'
                  ? _clientSettings.interfaceName
                  : 'Detected existing client: ${_clientSettings.interfaceName}',
            ),
            value: _clientSettings.enabled,
            onChanged: _isSaving ? null : _updateClientEnabled,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Route Allowed IPs'),
            subtitle: const Text(
              'Use the AllowedIPs from the config as router routes.',
            ),
            value: _clientSettings.routeAllowedIps,
            onChanged: _isSaving ? null : _updateClientRouteAllowed,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _isSaving ? null : _pickClientConfig,
            icon: const Icon(Icons.upload_file_rounded),
            label: const Text('Upload Config File'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientConfigController,
            decoration: InputDecoration(
              labelText: 'Paste WireGuard Config',
              helperText: 'Optional fallback for .conf files.',
              prefixIcon: const Icon(Icons.description_rounded),
              suffixIcon: IconButton(
                tooltip: 'Import pasted config',
                onPressed: _isSaving ? null : () => _importClientConfig(),
                icon: const Icon(Icons.input_rounded),
              ),
              border: const OutlineInputBorder(),
            ),
            minLines: 4,
            maxLines: 8,
            enabled: !_isSaving,
          ),
          const SizedBox(height: 16),
          _VpnSectionLabel(label: 'Interface'),
          const SizedBox(height: 8),
          TextField(
            controller: _clientAddressController,
            decoration: const InputDecoration(
              labelText: 'Address',
              helperText: 'Client tunnel address, for example 10.64.0.2/32.',
              prefixIcon: Icon(Icons.tag_rounded),
              border: OutlineInputBorder(),
            ),
            enabled: !_isSaving,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientDnsController,
            decoration: const InputDecoration(
              labelText: 'DNS Servers',
              helperText: 'Comma-separated DNS servers from the config.',
              prefixIcon: Icon(Icons.dns_rounded),
              border: OutlineInputBorder(),
            ),
            enabled: !_isSaving,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientPrivateKeyController,
            decoration: const InputDecoration(
              labelText: 'Private Key',
              prefixIcon: Icon(Icons.key_rounded),
              border: OutlineInputBorder(),
            ),
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            enabled: !_isSaving,
          ),
          const SizedBox(height: 16),
          _VpnSectionLabel(label: 'Peer'),
          const SizedBox(height: 8),
          TextField(
            controller: _clientPeerPublicKeyController,
            decoration: const InputDecoration(
              labelText: 'Public Key',
              prefixIcon: Icon(Icons.vpn_key_rounded),
              border: OutlineInputBorder(),
            ),
            enabled: !_isSaving,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientPresharedKeyController,
            decoration: const InputDecoration(
              labelText: 'Preshared Key',
              prefixIcon: Icon(Icons.lock_rounded),
              border: OutlineInputBorder(),
            ),
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            enabled: !_isSaving,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _clientEndpointHostController,
                  decoration: const InputDecoration(
                    labelText: 'Endpoint Host',
                    prefixIcon: Icon(Icons.public_rounded),
                    border: OutlineInputBorder(),
                  ),
                  enabled: !_isSaving,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _clientEndpointPortController,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  enabled: !_isSaving,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientAllowedIpsController,
            decoration: const InputDecoration(
              labelText: 'Allowed IPs',
              helperText: 'Common full tunnel: 0.0.0.0/0, ::/0.',
              prefixIcon: Icon(Icons.route_rounded),
              border: OutlineInputBorder(),
            ),
            enabled: !_isSaving,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _clientKeepaliveController,
            decoration: const InputDecoration(
              labelText: 'Persistent Keepalive',
              helperText: 'Usually 25 for provider VPN clients.',
              prefixIcon: Icon(Icons.timer_rounded),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            enabled: !_isSaving,
          ),
          const SizedBox(height: 14),
          _WarningBox(
            message:
                'Saving places the Openwalla WireGuard client interface in the WAN firewall zone and does not modify LAN or WAN interfaces.',
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _saveClient,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded),
              label: Text(_isSaving ? 'Saving' : 'Save Client'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ParsedWireGuardConfig {
  final String privateKey;
  final String address;
  final String dns;
  final String peerPublicKey;
  final String presharedKey;
  final String endpoint;
  final String allowedIps;
  final String persistentKeepalive;

  const _ParsedWireGuardConfig({
    required this.privateKey,
    required this.address,
    required this.dns,
    required this.peerPublicKey,
    required this.presharedKey,
    required this.endpoint,
    required this.allowedIps,
    required this.persistentKeepalive,
  });

  static _ParsedWireGuardConfig? parse(String input) {
    final sections = <String, Map<String, String>>{};
    String? section;
    for (final rawLine in const LineSplitter().convert(input)) {
      final line = rawLine.split('#').first.split(';').first.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1).trim().toLowerCase();
        sections.putIfAbsent(section, () => <String, String>{});
        continue;
      }
      final equals = line.indexOf('=');
      if (section == null || equals <= 0) continue;
      final key = line.substring(0, equals).trim().toLowerCase();
      final value = line.substring(equals + 1).trim();
      sections[section]![key] = value;
    }

    final interface = sections['interface'];
    final peer = sections['peer'];
    if (interface == null || peer == null) return null;
    final privateKey = interface['privatekey'] ?? '';
    final address = interface['address'] ?? '';
    final peerPublicKey = peer['publickey'] ?? '';
    final endpoint = peer['endpoint'] ?? '';
    if (privateKey.isEmpty ||
        address.isEmpty ||
        peerPublicKey.isEmpty ||
        endpoint.isEmpty) {
      return null;
    }
    return _ParsedWireGuardConfig(
      privateKey: privateKey,
      address: address,
      dns: interface['dns'] ?? '',
      peerPublicKey: peerPublicKey,
      presharedKey: peer['presharedkey'] ?? '',
      endpoint: endpoint,
      allowedIps: peer['allowedips'] ?? '',
      persistentKeepalive: peer['persistentkeepalive'] ?? '',
    );
  }
}

class _VpnSectionLabel extends StatelessWidget {
  final String label;

  const _VpnSectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w900,
        letterSpacing: 0,
      ),
    );
  }
}

class _VpnPanelCard extends StatelessWidget {
  final Widget child;

  const _VpnPanelCard({required this.child});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.42),
        ),
      ),
      child: child,
    );
  }
}

class _WarningBox extends StatelessWidget {
  final String message;

  const _WarningBox({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onErrorContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 98,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w800,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
