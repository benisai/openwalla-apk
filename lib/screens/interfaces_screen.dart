import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:flutter/services.dart';
import 'package:luci_mobile/models/interface.dart';
import 'package:luci_mobile/state/app_state.dart';
import 'dart:math';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/screens/router_dashboard_settings_screen.dart';
import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/widgets/luci_loading_states.dart';
import 'package:luci_mobile/widgets/luci_refresh_components.dart';
import 'package:qr_flutter/qr_flutter.dart';

class InterfacesScreen extends ConsumerStatefulWidget {
  final String? scrollToInterface;
  final VoidCallback? onScrollComplete;
  final bool wirelessOnly;

  const InterfacesScreen({
    super.key,
    this.scrollToInterface,
    this.onScrollComplete,
    this.wirelessOnly = false,
  });

  @override
  ConsumerState<InterfacesScreen> createState() => _InterfacesScreenState();
}

class _InterfacesScreenState extends ConsumerState<InterfacesScreen> {
  final ScrollController _scrollController = ScrollController();
  final PageController _networkPageController = PageController();
  final PageController _wirelessPageController = PageController();
  String? _targetInterface;
  String? _expandedInterface;
  final Map<String, GlobalKey> _interfaceKeys = {};
  int _networkPanelIndex = 0;
  int _wirelessPanelIndex = 0;
  bool _isLoadingNetworkPanels = false;
  List<OpenwrtPortForward> _portForwards = const [];
  List<OpenwrtFirewallZone> _firewallZones = const [];

  /// Safely extract a String from a UCI config value that may be a List or String.
  static String _uciString(dynamic value, [String fallback = '']) {
    if (value is String) return value;
    if (value is List) {
      return value.isNotEmpty ? value.first.toString() : fallback;
    }
    return value?.toString() ?? fallback;
  }

  // Unified key generator for all interfaces
  String _interfaceKey({String? name, String? ssid, String? deviceName}) {
    if (ssid != null && ssid.trim().isNotEmpty) {
      return ssid.trim(); // SSID is case sensitive
    } else if (deviceName != null && deviceName.trim().isNotEmpty) {
      return deviceName.trim().toLowerCase();
    } else if (name != null && name.trim().isNotEmpty) {
      return name.trim().toLowerCase();
    }
    return '';
  }

  // Unified key generator and matcher for all interfaces
  String _normalizeInterfaceKey(String? value) {
    return (value ?? '').trim().toLowerCase();
  }

  String _interfaceKeyForWireless({
    String? ssid,
    String? radioName,
    String? deviceName,
    String? name,
  }) {
    final radio = (radioName ?? '').trim();
    final ssidTrimmed = (ssid ?? '').trim();

    // If SSID is empty, we need to ensure uniqueness even with same radio
    if (ssidTrimmed.isEmpty) {
      // Use device name as fallback for uniqueness
      final device = (deviceName ?? '').trim();
      if (device.isNotEmpty && device != radio) {
        return '${ssidTrimmed.toLowerCase()}__${device.toLowerCase()}';
      }
      // Use interface name as fallback
      final interfaceName = (name ?? '').trim();
      if (interfaceName.isNotEmpty && interfaceName != radio) {
        return '${ssidTrimmed.toLowerCase()}__${interfaceName.toLowerCase()}';
      }
      // If all names are the same, add a unique suffix
      return '${ssidTrimmed.toLowerCase()}__${radio.toLowerCase()}_${DateTime.now().millisecondsSinceEpoch}';
    }

    // If SSID is not empty, use SSID + radio
    return '${ssidTrimmed.toLowerCase()}__${radio.toLowerCase()}';
  }

  bool _isLoopbackInterface(Map<String, dynamic> iface) {
    final names = [
      iface['interface'],
      iface['device'],
      iface['l3_device'],
      iface['ifname'],
    ].map((value) => value?.toString().toLowerCase().trim());

    return names.any((name) => name == 'loopback' || name == 'lo');
  }

  @override
  void initState() {
    super.initState();
    _targetInterface = widget.scrollToInterface;
    if (!widget.wirelessOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadNetworkPanels());
    }
    if (_targetInterface != null) {
      // Delay scrolling to allow the widget to build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToInterface(_targetInterface!);
      });
    }
  }

  @override
  void didUpdateWidget(InterfacesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Handle parameter changes (important for iOS navigation)
    if (widget.scrollToInterface != oldWidget.scrollToInterface) {
      _targetInterface = widget.scrollToInterface;
      if (_targetInterface != null) {
        // Delay scrolling to allow the widget to build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToInterface(_targetInterface!);
        });
      } else {
        // Clear target interface if no new target is provided
        setState(() {
          _targetInterface = null;
        });
      }
    }
  }

  @override
  void dispose() {
    // Clear target interface when widget is disposed
    _targetInterface = null;
    _scrollController.dispose();
    _networkPageController.dispose();
    _wirelessPageController.dispose();
    super.dispose();
  }

  Future<void> _refreshNetworkData() async {
    await ref.read(appStateProvider).fetchDashboardData();
    if (!widget.wirelessOnly) await _loadNetworkPanels();
  }

  Future<void> _loadNetworkPanels() async {
    if (!mounted) return;
    setState(() => _isLoadingNetworkPanels = true);
    try {
      final appState = ref.read(appStateProvider);
      final results = await Future.wait([
        appState.fetchPortForwards(context: context),
        appState.fetchFirewallZones(context: context),
      ]);
      if (!mounted) return;
      setState(() {
        _portForwards = results[0] as List<OpenwrtPortForward>;
        _firewallZones = results[1] as List<OpenwrtFirewallZone>;
        _isLoadingNetworkPanels = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingNetworkPanels = false);
    }
  }

  void _scrollToInterface(String interfaceName) {
    if (!_scrollController.hasClients) return;

    // Find the target interface and calculate its position
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        // Get the app state to access interface data
        final appState = ref.read(appStateProvider);
        final dashboardData = appState.dashboardData;

        if (dashboardData != null) {
          // Check wired interfaces first
          final wiredInterfaces =
              dashboardData['interfaceDump']?['interface'] as List<dynamic>?;
          if (wiredInterfaces != null) {
            for (int i = 0; i < wiredInterfaces.length; i++) {
              final iface = wiredInterfaces[i] as Map<String, dynamic>;
              if (_isLoopbackInterface(iface)) continue;
              final name = iface['interface'] as String? ?? '';
              final keyStr = _interfaceKey(name: name);
              // Use exact matching only
              if (keyStr == interfaceName.toLowerCase()) {
                _scrollToExpandedCard(keyStr);
                return;
              }
            }
          }

          // If not found in wired, check wireless interfaces
          final wirelessData =
              dashboardData['wireless'] as Map<String, dynamic>?;
          if (wirelessData != null) {
            final normalizedTarget = _normalizeInterfaceKey(interfaceName);
            wirelessData.forEach((radioName, radioData) {
              final interfaces = radioData['interfaces'] as List<dynamic>?;
              if (interfaces != null) {
                for (var i = 0; i < interfaces.length; i++) {
                  final interface = interfaces[i];
                  final config = interface['config'] ?? {};
                  final iwinfo = interface['iwinfo'] ?? {};
                  final deviceName = _uciString(config['device'], radioName);
                  final ssid = _uciString(iwinfo['ssid']).isNotEmpty
                      ? _uciString(iwinfo['ssid'])
                      : _uciString(config['ssid']);
                  final name = interface['name'] ?? '';
                  final keyStr = _interfaceKeyForWireless(
                    ssid: ssid,
                    radioName: radioName,
                    deviceName: deviceName,
                    name: name,
                  );
                  // Generate all possible normalized keys for matching
                  final ssidKey = _normalizeInterfaceKey(ssid);
                  final deviceKey = _normalizeInterfaceKey(deviceName);
                  final nameKey = _normalizeInterfaceKey(name);
                  // Match against all possible keys
                  if (normalizedTarget == ssidKey ||
                      normalizedTarget == deviceKey ||
                      normalizedTarget == nameKey) {
                    _scrollToExpandedCard(keyStr);
                    return;
                  }
                }
              }
            });
          }
        }

        // If not found, use section-based scrolling
        if (interfaceName.toLowerCase().contains('wifi') ||
            interfaceName.toLowerCase().contains('wireless') ||
            interfaceName.toLowerCase().contains('radio')) {
          _scrollToSection(200); // Wireless section
        } else {
          _scrollToSection(80); // Wired section
        }
      }
    });
  }

  double _headerOffset(BuildContext context) {
    // App bar (56) + section header (60)
    return 116.0;
  }

  void _scrollToExpandedCard(String keyStr, {int retry = 0}) {
    if (!mounted) return;

    // Set the expanded interface
    if (_expandedInterface != keyStr) {
      setState(() {
        _expandedInterface = keyStr;
      });

      // Wait for the expansion animation to complete (400ms) before calculating scroll
      Future.delayed(const Duration(milliseconds: 450), () {
        if (mounted) _performScrollToCard(keyStr, retry: retry);
      });
    } else {
      // Already expanded, perform scroll immediately
      _performScrollToCard(keyStr, retry: retry);
    }
  }

  void _performScrollToCard(String keyStr, {int retry = 0}) {
    if (!mounted) return;

    final key = _interfaceKeys[keyStr];
    final currentContext = context; // Store context

    final ctx = key?.currentContext;
    if (ctx == null) {
      if (retry < 5) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) _performScrollToCard(keyStr, retry: retry + 1);
        });
      }
      return;
    }

    final headerOffset = _headerOffset(currentContext);
    final renderBox = ctx.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      if (retry < 5) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) _performScrollToCard(keyStr, retry: retry + 1);
        });
      }
      return;
    }

    final cardOffset = renderBox.localToGlobal(Offset.zero).dy;
    final cardHeight = renderBox.size.height;
    final scrollableBox = _scrollController.position.hasContentDimensions
        ? _scrollController.position.context.storageContext.findRenderObject()
              as RenderBox?
        : null;
    final scrollableTop = scrollableBox?.localToGlobal(Offset.zero).dy ?? 0.0;
    final visibleTop = scrollableTop + headerOffset;
    final visibleBottom = MediaQuery.of(currentContext).size.height;
    final cardBottom = cardOffset + cardHeight;

    // Calculate how much of the card is visible
    final visibleCardTop = max(cardOffset, visibleTop);
    final visibleCardBottom = min(cardBottom, visibleBottom);
    final visibleCardHeight = max(0.0, visibleCardBottom - visibleCardTop);
    final cardVisibilityRatio = cardHeight > 0
        ? visibleCardHeight / cardHeight
        : 0.0;

    // Only scroll if less than 90% of the card is visible
    final needsScroll = cardVisibilityRatio < 0.9;

    if (needsScroll) {
      // Calculate optimal scroll position to center the card
      final screenHeight = MediaQuery.of(currentContext).size.height;
      final availableHeight = screenHeight - headerOffset;
      final targetPosition =
          cardOffset - headerOffset - (availableHeight - cardHeight) / 2;
      final clampedPosition = targetPosition.clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );

      _scrollController
          .animateTo(
            clampedPosition,
            duration: const Duration(milliseconds: 500),
            curve: Curves.fastOutSlowIn,
          )
          .then((_) {
            if (mounted) {
              setState(() {
                _targetInterface = null;
              });
              widget.onScrollComplete?.call();
            }
          });
    } else {
      if (mounted) {
        setState(() {
          _targetInterface = null;
        });
        widget.onScrollComplete?.call();
      }
    }
  }

  void _scrollToSection(double targetPosition) {
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return;
    }

    final maxScroll = _scrollController.position.maxScrollExtent;
    final clampedPosition = targetPosition.clamp(0.0, maxScroll);

    _scrollController
        .animateTo(
          clampedPosition,
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeInOut,
        )
        .then((_) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              setState(() {
                _targetInterface = null;
              });
              widget.onScrollComplete?.call();
            }
          });
        });
  }

  void _showNetworkInterfaceSettings() {
    showDialog<void>(
      context: context,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Network Interfaces',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0,
                              ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: RouterDashboardSettingsScreen(
                    title: 'Network Interfaces',
                    showThroughput: false,
                    showDashboardCards: false,
                    showShortcutPanel: false,
                    showWirelessInterfaces: false,
                    embedded: true,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showEditInterfaceSheet(NetworkInterface iface) async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) =>
          _NetworkInterfaceEditSheet(interfaceName: iface.name),
    );
    if (updated == true && mounted) {
      await ref.read(appStateProvider).fetchDashboardData();
    }
  }

  Future<void> _showEditWirelessSheet(String section) async {
    if (section.isEmpty) return;
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _WirelessNetworkEditSheet(section: section),
    );
    if (updated == true && mounted) {
      await ref.read(appStateProvider).fetchDashboardData();
    }
  }

  Future<void> _showWirelessDisplaySettings() async {
    final appState = ref.read(appStateProvider);
    final current = appState.dashboardPreferences.showInactiveWirelessNetworks;
    final next = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        var showInactive = current;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Wi-Fi Display',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Choose whether disabled Wi-Fi networks are shown on this page.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Show inactive Wi-Fi networks'),
                      subtitle: const Text('Disabled radios and SSIDs'),
                      value: showInactive,
                      onChanged: (value) =>
                          setSheetState(() => showInactive = value),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () =>
                            Navigator.of(context).pop(showInactive),
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (next == null || next == current) return;
    await appState.saveDashboardPreferences(
      appState.dashboardPreferences.copyWith(
        showInactiveWirelessNetworks: next,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _showWirelessInfoSheet(Map<String, dynamic> iface) async {
    final details = iface['details'];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.wifi_rounded,
                        color: colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            iface['ssid']?.toString().isNotEmpty == true
                                ? iface['ssid'].toString()
                                : 'Wi-Fi Info',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w900),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            iface['subtitle']?.toString() ?? '',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.34,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.32),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildInfoSheetRow(
                        context,
                        'Status',
                        iface['isEnabled'] == true ? 'Active' : 'Inactive',
                      ),
                      _buildInfoSheetRow(
                        context,
                        'Radio',
                        iface['radioName']?.toString() ?? 'N/A',
                      ),
                      _buildInfoSheetRow(
                        context,
                        'Interface',
                        iface['interfaceName']?.toString() ?? 'N/A',
                      ),
                      if (details is Map)
                        ...details.entries.map(
                          (entry) => _buildInfoSheetRow(
                            context,
                            entry.key.toString(),
                            entry.value?.toString() ?? 'N/A',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoSheetRow(BuildContext context, String label, String value) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value.isEmpty ? 'N/A' : value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showShareWifiDialog(Map<String, dynamic> iface) async {
    final ssid = iface['ssid']?.toString() ?? '';
    if (ssid.trim().isEmpty) return;
    final password = iface['password']?.toString() ?? '';
    final encryption = iface['encryption']?.toString() ?? '';
    final hidden = iface['hidden'] == true;
    final qrData = _wifiQrPayload(
      ssid: ssid,
      password: password,
      encryption: encryption,
      hidden: hidden,
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) =>
          _ShareWifiSheet(ssid: ssid, password: password, qrData: qrData),
    );
  }

  String _wifiQrPayload({
    required String ssid,
    required String password,
    required String encryption,
    required bool hidden,
  }) {
    final normalized = encryption.toLowerCase();
    final authType = normalized.contains('wep')
        ? 'WEP'
        : normalized == 'none' || normalized == 'nopass'
        ? 'nopass'
        : 'WPA';
    final escapedSsid = _escapeWifiQrValue(ssid);
    final escapedPassword = _escapeWifiQrValue(password);
    return 'WIFI:T:$authType;S:$escapedSsid;P:$escapedPassword;H:${hidden ? 'true' : 'false'};;';
  }

  String _escapeWifiQrValue(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll(';', r'\;')
        .replaceAll(',', r'\,')
        .replaceAll(':', r'\:');
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.read(appStateProvider);

    return Scaffold(
      appBar: LuciAppBar(
        title: widget.wirelessOnly ? 'Wi-Fi' : 'Network',
        showBack: true,
        actions: widget.wirelessOnly
            ? [
                IconButton(
                  tooltip: 'Wi-Fi display settings',
                  icon: const Icon(Icons.settings_rounded),
                  onPressed: _showWirelessDisplaySettings,
                ),
              ]
            : [
                IconButton(
                  tooltip: 'Network interface settings',
                  icon: const Icon(Icons.settings_rounded),
                  onPressed: _showNetworkInterfaceSettings,
                ),
              ],
      ),
      body: SafeArea(
        top: true,
        bottom: false,
        child: Stack(
          children: [
            LuciPullToRefresh(
              onRefresh: _refreshNetworkData,
              child: Builder(
                builder: (context) {
                  final watchedAppState = ref.watch(appStateProvider);
                  final isLoading = watchedAppState.isDashboardLoading;
                  final dashboardError = watchedAppState.dashboardError;
                  final dashboardData = watchedAppState.dashboardData;

                  if (isLoading && dashboardData == null) {
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: LuciSpacing.md),
                      child: Column(
                        children: [
                          SizedBox(height: LuciSpacing.md),
                          // Interface cards skeleton
                          Expanded(
                            child: ListView.separated(
                              itemCount: 4,
                              separatorBuilder: (context, index) =>
                                  SizedBox(height: LuciSpacing.md),
                              itemBuilder: (context, index) => LuciCardSkeleton(
                                showTitle: true,
                                showSubtitle: true,
                                contentLines: 3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  if (dashboardError != null && dashboardData == null) {
                    return LuciErrorDisplay(
                      title: 'Failed to Load Network',
                      message:
                          'Could not connect to the router. Please check your network connection and router settings.',
                      actionLabel: 'Retry',
                      onAction: () =>
                          appState.retryDashboardConnection(context: context),
                      icon: Icons.wifi_off_rounded,
                    );
                  }

                  if (dashboardData == null) {
                    return LuciEmptyState(
                      title: 'No Network Data',
                      message:
                          'Unable to fetch network information. Pull down to refresh or tap the button below.',
                      icon: Icons.device_hub_outlined,
                      actionLabel: 'Fetch Data',
                      onAction: () => appState.fetchDashboardData(),
                    );
                  }

                  return CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      if (widget.wirelessOnly) ...[
                        _buildWirelessInterfacesList(),
                      ] else ...[
                        SliverFillRemaining(
                          child: Column(
                            children: [
                              _NetworkPanelSwitcher(
                                selectedIndex: _networkPanelIndex,
                                onSelected: _selectNetworkPanel,
                              ),
                              Expanded(
                                child: PageView(
                                  controller: _networkPageController,
                                  onPageChanged: (index) => setState(
                                    () => _networkPanelIndex = index,
                                  ),
                                  children: [
                                    CustomScrollView(
                                      slivers: [_buildWiredInterfacesList()],
                                    ),
                                    _PortForwardingPanel(
                                      isLoading: _isLoadingNetworkPanels,
                                      forwards: _portForwards,
                                      onRefresh: _loadNetworkPanels,
                                      onAdd: _showAddPortForwardSheet,
                                      onEdit: _showAddPortForwardSheet,
                                    ),
                                    _FirewallZonesPanel(
                                      isLoading: _isLoadingNetworkPanels,
                                      zones: _firewallZones,
                                      onRefresh: _loadNetworkPanels,
                                    ),
                                  ],
                                ),
                              ),
                              _NetworkPanelDots(
                                count: 3,
                                currentIndex: _networkPanelIndex,
                              ),
                              const SizedBox(height: 12),
                            ],
                          ),
                        ),
                      ],
                      if (widget.wirelessOnly)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.only(bottom: 16),
                            child: SizedBox.shrink(),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _selectNetworkPanel(int index) {
    setState(() => _networkPanelIndex = index);
    _networkPageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _selectWirelessPanel(int index) {
    setState(() => _wirelessPanelIndex = index);
    _wirelessPageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _showAddPortForwardSheet([OpenwrtPortForward? forward]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _AddPortForwardSheet(forward: forward),
    );
    if (saved == true) await _loadNetworkPanels();
  }

  Widget _buildWiredInterfacesList() {
    final appState = ref.watch(appStateProvider);
    final dynamic detailedData = appState.dashboardData?['interfaceDump'];
    final dynamic statsDataSource = appState.dashboardData?['networkDevices'];
    final enabledWiredInterfaces =
        appState.dashboardPreferences.enabledWiredInterfaces;
    var interfacesList = <NetworkInterface>[];

    if (detailedData is Map &&
        detailedData.containsKey('interface') &&
        detailedData['interface'] is List) {
      final List<dynamic> interfaceDataList = detailedData['interface'];
      final Map<String, dynamic> networkStatsMap = statsDataSource is Map
          ? Map<String, dynamic>.from(statsDataSource)
          : <String, dynamic>{};

      interfacesList = interfaceDataList
          .whereType<Map<String, dynamic>>()
          .where(
            (detailedInterfaceMap) =>
                !_isLoopbackInterface(detailedInterfaceMap),
          )
          .where((detailedInterfaceMap) {
            if (enabledWiredInterfaces.isEmpty) return true;
            final name = detailedInterfaceMap['interface']?.toString() ?? '';
            return enabledWiredInterfaces.contains(name);
          })
          .map((detailedInterfaceMap) {
            final mutableInterfaceMap = Map<String, dynamic>.from(
              detailedInterfaceMap,
            );
            final stats = mutableInterfaceMap['stats'];
            if (stats == null || (stats is Map && stats.isEmpty)) {
              final String? deviceName =
                  mutableInterfaceMap['l3_device'] ??
                  mutableInterfaceMap['device'];
              if (deviceName != null) {
                final statsContainer = networkStatsMap[deviceName];
                if (statsContainer is Map && statsContainer['stats'] is Map) {
                  mutableInterfaceMap['stats'] = statsContainer['stats'];
                }
              }
            }
            return NetworkInterface.fromJson(mutableInterfaceMap);
          })
          .toList();
    }

    final interfaces = interfacesList;
    if (interfaces.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final iface = interfaces[index];
        final isTargetInterface =
            _targetInterface != null &&
            iface.name.toLowerCase() == _targetInterface!.toLowerCase();

        final keyStr = _interfaceKey(name: iface.name);
        final key = _interfaceKeys.putIfAbsent(keyStr, () => GlobalKey());
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: _UnifiedNetworkCard(
            key: key,
            name: iface.name.toUpperCase(),
            subtitle: _buildMinimalInterfaceSubtitle(iface),
            isUp: iface.isUp,
            icon: _getInterfaceIcon(iface.protocol),
            details: _buildWiredDetails(context, iface),
            initiallyExpanded:
                isTargetInterface || _expandedInterface == keyStr,
          ),
        );
      }, childCount: interfaces.length),
    );
  }

  Widget _buildWirelessInterfacesList() {
    final appState = ref.watch(appStateProvider);
    final dashboardData = appState.dashboardData;
    final wirelessData = dashboardData?['wireless'] as Map<String, dynamic>?;
    final uciWirelessConfig = dashboardData?['uciWirelessConfig'];
    final interfacesList = <Map<String, dynamic>>[];

    final uciRadios = <String, Map>{};
    final uciInterfaces = <String, Map>{};

    final uciValues = uciWirelessConfig?['values'] as Map?;
    if (uciValues != null) {
      uciValues.forEach((key, value) {
        final typedValue = value as Map?;
        if (typedValue?['.type'] == 'wifi-device') {
          uciRadios[key] = typedValue!;
        } else if (typedValue?['.type'] == 'wifi-iface') {
          uciInterfaces[key] = typedValue!;
        }
      });
    }

    final runtimeInterfaces = <String>{};
    if (wirelessData != null) {
      wirelessData.forEach((radioName, radioData) {
        final interfaces = radioData['interfaces'] as List<dynamic>?;
        if (interfaces != null) {
          for (final iface in interfaces) {
            final config = iface['config'] ?? {};
            final iwinfo = iface['iwinfo'] ?? {};
            final uciName = iface['section'] as String?;
            final uciConfig = uciName == null ? null : uciInterfaces[uciName];
            final ifaceConfig = uciConfig ?? config;
            if (uciName != null) {
              runtimeInterfaces.add(uciName);
            }

            final isRadioEnabled = uciRadios[radioName]?['disabled'] != '1';
            final isIfaceEnabled = ifaceConfig['disabled'] != '1';
            final isEnabled = isRadioEnabled && isIfaceEnabled;
            final hidden = _uciString(ifaceConfig['hidden'], '0') == '1';
            final encryption = _uciString(ifaceConfig['encryption'], 'N/A');
            final password = _uciString(ifaceConfig['key']);
            final txPower = _uciString(uciRadios[radioName]?['txpower']);

            final name = iface['name'] ?? '';
            final ssid = _uciString(iwinfo['ssid']).isNotEmpty
                ? _uciString(iwinfo['ssid'])
                : _uciString(ifaceConfig['ssid']);
            final deviceName = _uciString(ifaceConfig['device'], radioName);
            final mode =
                _uciString(ifaceConfig['mode']).toUpperCase().isNotEmpty
                ? _uciString(ifaceConfig['mode']).toUpperCase()
                : (iwinfo['mode']?.toString().toUpperCase() ?? 'N/A');
            final isSta =
                mode == 'STA' ||
                mode.contains('CLIENT') ||
                _uciString(ifaceConfig['ssid']).toUpperCase() == 'STA' ||
                _uciString(iwinfo['ssid']).toUpperCase() == 'STA';
            interfacesList.add({
              'section': uciName ?? '',
              'name': _uciString(ifaceConfig['ssid']).isNotEmpty
                  ? _uciString(ifaceConfig['ssid'])
                  : (iwinfo['ssid']?.toString() ?? 'Unnamed'),
              'subtitle':
                  '$mode • Ch. ${iwinfo['channel']?.toString() ?? _uciString(ifaceConfig['channel'], 'N/A')}',
              'isEnabled': isEnabled,
              'deviceName': deviceName,
              'radioName': radioName,
              'ssid': ssid,
              'password': password,
              'encryption': encryption,
              'hidden': hidden,
              'mode': mode,
              'isSta': isSta,
              'interfaceName': name,
              'details': {
                'Device': _uciString(ifaceConfig['device'], radioName),
                'Mode': _uciString(ifaceConfig['mode']).isNotEmpty
                    ? _uciString(ifaceConfig['mode'])
                    : (iwinfo['mode']?.toString() ?? 'N/A'),
                'Channel':
                    iwinfo['channel']?.toString() ??
                    _uciString(ifaceConfig['channel'], 'N/A'),
                'Signal': '${iwinfo['signal']?.toString() ?? '--'} dBm',
                'Network': (ifaceConfig['network'] is List)
                    ? (ifaceConfig['network'] as List).join(', ')
                    : _uciString(ifaceConfig['network'], 'N/A'),
                'Security': encryption,
                'SSID Visibility': hidden ? 'Hidden' : 'Visible',
                'TX Power': txPower.isEmpty ? 'Auto' : '$txPower dBm',
              },
            });
          }
        }
      });
    }

    uciInterfaces.forEach((uciName, config) {
      if (!runtimeInterfaces.contains(uciName)) {
        final radioName = _uciString(config['device']);
        final isRadioEnabled = uciRadios[radioName]?['disabled'] != '1';
        final isIfaceEnabled = _uciString(config['disabled']) != '1';
        final isEnabled = isRadioEnabled && isIfaceEnabled;

        final name = _uciString(config['ssid'], 'Unnamed');
        final hidden = _uciString(config['hidden'], '0') == '1';
        final encryption = _uciString(config['encryption'], 'N/A');
        final mode = _uciString(config['mode'], 'N/A').toUpperCase();
        final isSta =
            mode == 'STA' ||
            mode.contains('CLIENT') ||
            _uciString(config['ssid']).toUpperCase() == 'STA';
        final txPower = _uciString(uciRadios[radioName]?['txpower']);
        interfacesList.add({
          'section': uciName,
          'name': name,
          'subtitle': '$mode • Disabled',
          'isEnabled': isEnabled,
          'deviceName': radioName,
          'radioName': radioName,
          'ssid': name,
          'password': _uciString(config['key']),
          'encryption': encryption,
          'hidden': hidden,
          'mode': mode,
          'isSta': isSta,
          'interfaceName': name,
          'details': {
            'Device': radioName,
            'Mode': _uciString(config['mode'], 'N/A'),
            'SSID': _uciString(config['ssid'], 'N/A'),
            'Network': (config['network'] is List)
                ? (config['network'] as List).join(', ')
                : _uciString(config['network'], 'N/A'),
            'Security': encryption,
            'SSID Visibility': hidden ? 'Hidden' : 'Visible',
            'TX Power': txPower.isEmpty ? 'Auto' : '$txPower dBm',
          },
        });
      }
    });

    final activeInterfaces = interfacesList
        .where((iface) => iface['isEnabled'] == true)
        .toList();
    final disabledInterfaces = interfacesList
        .where((iface) => iface['isEnabled'] != true)
        .toList();
    if (activeInterfaces.isEmpty && disabledInterfaces.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final showInactive =
        appState.dashboardPreferences.showInactiveWirelessNetworks;
    final mainActive = activeInterfaces
        .where((iface) => iface['isSta'] != true)
        .toList();
    final staActive = activeInterfaces
        .where((iface) => iface['isSta'] == true)
        .toList();
    final mainDisabled = showInactive
        ? disabledInterfaces.where((iface) => iface['isSta'] != true).toList()
        : <Map<String, dynamic>>[];
    final staDisabled = showInactive
        ? disabledInterfaces.where((iface) => iface['isSta'] == true).toList()
        : <Map<String, dynamic>>[];
    final hasSta = staActive.isNotEmpty || staDisabled.isNotEmpty;

    if (!hasSta) {
      return _buildWirelessSliver(mainActive, mainDisabled);
    }

    if (_wirelessPanelIndex > 1) _wirelessPanelIndex = 0;
    return SliverFillRemaining(
      child: Column(
        children: [
          _WirelessPanelSwitcher(
            selectedIndex: _wirelessPanelIndex,
            onSelected: _selectWirelessPanel,
          ),
          Expanded(
            child: PageView(
              controller: _wirelessPageController,
              onPageChanged: (index) =>
                  setState(() => _wirelessPanelIndex = index),
              children: [
                CustomScrollView(
                  slivers: [_buildWirelessSliver(mainActive, mainDisabled)],
                ),
                CustomScrollView(
                  slivers: [_buildWirelessSliver(staActive, staDisabled)],
                ),
              ],
            ),
          ),
          _NetworkPanelDots(count: 2, currentIndex: _wirelessPanelIndex),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildWirelessSliver(
    List<Map<String, dynamic>> activeInterfaces,
    List<Map<String, dynamic>> disabledInterfaces,
  ) {
    if (activeInterfaces.isEmpty && disabledInterfaces.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index >= activeInterfaces.length) {
            return _buildDisabledWirelessSection(context, disabledInterfaces);
          }
          final iface = activeInterfaces[index];
          return _buildWirelessCard(context, iface);
        },
        childCount:
            activeInterfaces.length + (disabledInterfaces.isEmpty ? 0 : 1),
      ),
    );
  }

  Widget _buildWirelessCard(BuildContext context, Map<String, dynamic> iface) {
    final deviceName = iface['deviceName'] ?? '';
    final radioName = iface['radioName'] ?? '';
    final ssid = iface['ssid'] ?? '';
    final name = iface['interfaceName'] ?? '';
    final keyStr = _interfaceKeyForWireless(
      ssid: ssid,
      radioName: radioName,
      deviceName: deviceName,
      name: name,
    );
    final key = _interfaceKeys.putIfAbsent(keyStr, () => GlobalKey());
    final displayName = ssid.toString().isNotEmpty
        ? ssid.toString()
        : deviceName.toString();

    final isTargetInterface =
        _targetInterface != null &&
        (_normalizeInterfaceKey(ssid) ==
                _normalizeInterfaceKey(_targetInterface!) ||
            _normalizeInterfaceKey(deviceName) ==
                _normalizeInterfaceKey(_targetInterface!) ||
            _normalizeInterfaceKey(name) ==
                _normalizeInterfaceKey(_targetInterface!));

    final shouldExpand = isTargetInterface || _expandedInterface == keyStr;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: _UnifiedNetworkCard(
        key: key,
        name: displayName,
        subtitle: iface['subtitle'],
        isUp: iface['isEnabled'],
        icon: Icons.wifi,
        details: _buildWirelessDetails(context, iface),
        initiallyExpanded: shouldExpand,
      ),
    );
  }

  Widget _buildDisabledWirelessSection(
    BuildContext context,
    List<Map<String, dynamic>> disabledInterfaces,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.42),
          ),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            collapsedShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            leading: Icon(
              Icons.wifi_off_rounded,
              color: colorScheme.onSurfaceVariant,
            ),
            title: Text(
              'Disabled Wi-Fi',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            subtitle: Text(
              '${disabledInterfaces.length} radio or SSID ${disabledInterfaces.length == 1 ? 'is' : 'are'} off',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            children: [
              for (final iface in disabledInterfaces)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
                  child: _buildWirelessCard(context, iface),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWirelessDetails(
    BuildContext context,
    Map<String, dynamic> iface,
  ) {
    final section = iface['section']?.toString() ?? '';
    final password = iface['password']?.toString() ?? '';
    final canShare =
        iface['isEnabled'] == true &&
        (iface['ssid']?.toString().trim().isNotEmpty ?? false);
    return Column(
      children: [
        _buildDetailRow(context, 'SSID', iface['ssid']?.toString() ?? 'N/A'),
        _buildDetailRow(
          context,
          'Password',
          password.isEmpty ? 'No password set' : password,
          onTap: password.isEmpty
              ? null
              : () => _copyToClipboard(context, password, 'Wi-Fi password'),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              if (section.isNotEmpty)
                FilledButton.tonalIcon(
                  onPressed: () => _showEditWirelessSheet(section),
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('Edit Wi-Fi'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              FilledButton.tonalIcon(
                onPressed: () => _showWirelessInfoSheet(iface),
                icon: const Icon(Icons.info_outline_rounded, size: 18),
                label: const Text('Info'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              if (canShare)
                FilledButton.icon(
                  onPressed: () => _showShareWifiDialog(iface),
                  icon: const Icon(Icons.qr_code_rounded, size: 18),
                  label: const Text('Share Wi-Fi'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _buildWiredDetails(BuildContext context, NetworkInterface interface) {
    final canEditLan = _normalizeInterfaceKey(interface.name) == 'lan';
    return Column(
      children: [
        _buildDetailRow(context, 'Device', interface.device),
        _buildDetailRow(context, 'Uptime', interface.formattedUptime),
        if (interface.ipAddress != null)
          _buildDetailRow(
            context,
            'IP Address',
            interface.ipAddress!,
            onTap: () =>
                _copyToClipboard(context, interface.ipAddress!, 'IP Address'),
          ),
        if (interface.ipv6Addresses != null &&
            interface.ipv6Addresses!.isNotEmpty)
          ...interface.ipv6Addresses!.map(
            (ipv6) => _buildDetailRow(
              context,
              'IPv6 Address',
              ipv6,
              onTap: () => _copyToClipboard(context, ipv6, 'IPv6 Address'),
            ),
          ),
        if (interface.gateway != null)
          _buildDetailRow(
            context,
            'Gateway',
            interface.gateway!,
            onTap: () =>
                _copyToClipboard(context, interface.gateway!, 'Gateway IP'),
          ),
        if (interface.dnsServers.isNotEmpty)
          _buildDetailRow(
            context,
            'DNS',
            interface.dnsServers.join(', '),
            onTap: () => _copyToClipboard(
              context,
              interface.dnsServers.join(', '),
              'DNS Servers',
            ),
          ),
        // Add WireGuard peer information if this is a WireGuard interface
        if (interface.protocol.toLowerCase() == 'wireguard') ...[
          Builder(
            builder: (context) {
              return _buildWireGuardPeersSection(context, interface.name);
            },
          ),
        ],
        const Divider(height: 1, indent: 16, endIndent: 16),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: _buildStatsRow(context, interface.stats),
        ),
        if (canEditLan) ...[
          const SizedBox(height: 8),
          const Divider(height: 1, indent: 16, endIndent: 16),
          const SizedBox(height: 12),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: () => _showEditInterfaceSheet(interface),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('Edit LAN Settings'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }

  Widget _buildWireGuardPeersSection(
    BuildContext context,
    String interfaceName,
  ) {
    final appState = ref.watch(appStateProvider);
    final wireguardData =
        appState.dashboardData?['wireguard'] as Map<String, dynamic>?;
    final peerData = wireguardData?[interfaceName];
    if (peerData == null) {
      return const SizedBox.shrink();
    }
    final peers = peerData['peers'] as Map<String, dynamic>?;
    if (peers == null || peers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: const Divider(height: 24, thickness: 1, indent: 0, endIndent: 0),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1, thickness: 1, indent: 0, endIndent: 0),
          const SizedBox(height: 8),
          ...peers.values.map(
            (peer) =>
                _buildCohesivePeerRow(context, peer as Map<String, dynamic>),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildCohesivePeerRow(
    BuildContext context,
    Map<String, dynamic> peer,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final publicKey = peer['public_key'] as String? ?? 'Unknown';
    final endpoint = peer['endpoint'] as String? ?? 'N/A';
    final peerName = peer['name'] as String?;
    int lastHandshake = 0;
    final rawHandshake = peer['last_handshake'] ?? peer['latest_handshake'];
    if (rawHandshake != null) {
      if (rawHandshake is int) {
        lastHandshake = rawHandshake;
      } else if (rawHandshake is String) {
        lastHandshake = int.tryParse(rawHandshake) ?? 0;
      }
    }
    final displayKey = publicKey.length > 16
        ? '${publicKey.substring(0, 8)}...${publicKey.substring(publicKey.length - 8)}'
        : publicKey;
    String formatHandshakeTime(int timestamp) {
      if (timestamp == 0) return 'Never';
      final now = DateTime.now();
      final handshakeTime = DateTime.fromMillisecondsSinceEpoch(
        timestamp * 1000,
      );
      final difference = now.difference(handshakeTime);
      if (difference.inSeconds < 0) return 'Never';
      if (difference.inDays > 0) {
        return '${difference.inDays}d ago';
      } else if (difference.inHours > 0) {
        return '${difference.inHours}h ago';
      } else if (difference.inMinutes > 0) {
        return '${difference.inMinutes}m ago';
      } else {
        return '${difference.inSeconds}s ago';
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.vpn_key, size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  displayKey,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (peerName != null && peerName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                peerName,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      'Last Handshake',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatHandshakeTime(lastHandshake),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                        color: colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      'Endpoint',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      endpoint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                        color: colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(
    BuildContext context,
    String title,
    String value, {
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface,
              ),
            ),
            Row(
              children: [
                Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                  ),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                ),
                if (onTap != null)
                  GestureDetector(
                    onTap: onTap,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8.0),
                      child: Icon(
                        Icons.copy_all_outlined,
                        size: 16,
                        semanticLabel: 'Copy',
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildStatsRow(BuildContext context, Map<String, dynamic> stats) {
    String formatBytes(int bytes) {
      if (bytes <= 0) return '0 B';
      const suffixes = ["B", "KB", "MB", "GB", "TB"];
      var i = (log(bytes) / log(1024)).floor();
      return '${(bytes / pow(1024, i)).toStringAsFixed(2)} ${suffixes[i]}';
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildStatColumn(
          context,
          'Received',
          formatBytes(stats['rx_bytes'] ?? 0),
          Icons.arrow_downward,
          Colors.green,
        ),
        _buildStatColumn(
          context,
          'Transmitted',
          formatBytes(stats['tx_bytes'] ?? 0),
          Icons.arrow_upward,
          Colors.blue,
        ),
      ],
    );
  }

  Widget _buildStatColumn(
    BuildContext context,
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  IconData _getInterfaceIcon(String protocol) {
    switch (protocol.toLowerCase()) {
      case 'wireguard':
        return Icons.shield_outlined;
      case 'static':
        return Icons.settings_ethernet;
      case 'dhcp':
        return Icons.dns_outlined;
      default:
        return Icons.device_hub_outlined;
    }
  }

  String _buildMinimalInterfaceSubtitle(NetworkInterface iface) {
    final v4 = iface.ipAddress;
    final v6s = iface.ipv6Addresses ?? [];
    final v6 = v6s.isNotEmpty ? v6s.first : null;
    String? shown;
    int extra = 0;
    if (v4 != null) {
      shown = v4;
      if (v6 != null) extra++;
    } else if (v6 != null) {
      shown = v6;
    }
    if (shown == null) return iface.protocol;
    if (extra > 0) {
      return '${iface.protocol} • $shown  +$extra';
    } else {
      return '${iface.protocol} • $shown';
    }
  }
}

class LuciSectionHeader extends StatelessWidget {
  final String title;
  const LuciSectionHeader(this.title, {super.key});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _NetworkPanelSwitcher extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _NetworkPanelSwitcher({
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const tabs = ['Interfaces', 'Port Forwarding', 'Zones'];
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        children: List.generate(tabs.length, (index) {
          final selected = selectedIndex == index;
          return Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(7),
              onTap: () => onSelected(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? colorScheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  tabs[index],
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected
                        ? colorScheme.onPrimary
                        : colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _WirelessPanelSwitcher extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _WirelessPanelSwitcher({
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const tabs = ['Wi-Fi', 'STA'];
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        children: List.generate(tabs.length, (index) {
          final selected = selectedIndex == index;
          return Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(7),
              onTap: () => onSelected(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? colorScheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  tabs[index],
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected
                        ? colorScheme.onPrimary
                        : colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _NetworkPanelDots extends StatelessWidget {
  final int count;
  final int currentIndex;

  const _NetworkPanelDots({required this.count, required this.currentIndex});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(
        count,
        (index) => AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: index == currentIndex ? 16 : 6,
          height: 6,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: index == currentIndex
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant.withValues(alpha: 0.34),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }
}

class _PortForwardingPanel extends StatelessWidget {
  final bool isLoading;
  final List<OpenwrtPortForward> forwards;
  final Future<void> Function() onRefresh;
  final VoidCallback onAdd;
  final ValueChanged<OpenwrtPortForward> onEdit;

  const _PortForwardingPanel({
    required this.isLoading,
    required this.forwards,
    required this.onRefresh,
    required this.onAdd,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading && forwards.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final header = _NetworkPanelActionHeader(
      title: 'Port Forwarding',
      count: forwards.length,
      buttonLabel: 'Add',
      icon: Icons.add_rounded,
      onPressed: onAdd,
    );
    if (forwards.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          header,
          _NetworkPanelEmptyState(
            icon: Icons.low_priority_rounded,
            title: 'No Port Forwards',
            message: 'No firewall redirect rules were found on this router.',
            onRefresh: onRefresh,
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        header,
        ...forwards.map(
          (forward) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PortForwardCard(
              forward: forward,
              onTap: () => onEdit(forward),
            ),
          ),
        ),
      ],
    );
  }
}

class _PortForwardCard extends StatelessWidget {
  final OpenwrtPortForward forward;
  final VoidCallback onTap;

  const _PortForwardCard({required this.forward, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor = forward.enabled
        ? const Color(0xFF20CF70)
        : colorScheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.42),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      forward.name,
                      style: LuciTextStyles.cardTitle(context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _NetworkBadge(
                    label: forward.enabled ? 'Enabled' : 'Disabled',
                    color: statusColor,
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.edit_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _NetworkValueBlock(
                      label: '${forward.source.toUpperCase()} Port',
                      value: forward.wanPort,
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _NetworkValueBlock(
                      label: forward.destinationZone.toUpperCase(),
                      value:
                          '${forward.destinationIp}:${forward.destinationPort}',
                      alignEnd: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                forward.protocol.toUpperCase(),
                style: LuciTextStyles.cardSubtitle(
                  context,
                ).copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FirewallZonesPanel extends StatelessWidget {
  final bool isLoading;
  final List<OpenwrtFirewallZone> zones;
  final Future<void> Function() onRefresh;

  const _FirewallZonesPanel({
    required this.isLoading,
    required this.zones,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading && zones.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (zones.isEmpty) {
      return _NetworkPanelEmptyState(
        icon: Icons.security_rounded,
        title: 'No Firewall Zones',
        message: 'No firewall zone sections were found on this router.',
        onRefresh: onRefresh,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        _NetworkPanelHeader('Firewall Zones', zones.length),
        ...zones.map((zone) => _FirewallZoneCard(zone: zone)),
      ],
    );
  }
}

class _FirewallZoneCard extends StatelessWidget {
  final OpenwrtFirewallZone zone;

  const _FirewallZoneCard({required this.zone});

  Color _policyColor(BuildContext context, String policy) {
    final action = policy.toUpperCase();
    if (action == 'ACCEPT') return const Color(0xFF20CF70);
    if (action == 'REJECT' || action == 'DROP') {
      return Theme.of(context).colorScheme.error;
    }
    return Theme.of(context).colorScheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.42),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  zone.name.toLowerCase() == 'wan'
                      ? Icons.public_rounded
                      : Icons.device_hub_rounded,
                  color: colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  zone.name.toUpperCase(),
                  style: LuciTextStyles.cardTitle(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (zone.masquerading)
                const _NetworkBadge(label: 'NAT', color: Color(0xFFF27C24)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Networks: ${zone.networks}',
            style: LuciTextStyles.cardSubtitle(
              context,
            ).copyWith(fontWeight: FontWeight.w800),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _NetworkBadge(
                label: 'Input ${zone.input}',
                color: _policyColor(context, zone.input),
              ),
              _NetworkBadge(
                label: 'Output ${zone.output}',
                color: _policyColor(context, zone.output),
              ),
              _NetworkBadge(
                label: 'Forward ${zone.forward}',
                color: _policyColor(context, zone.forward),
              ),
              if (zone.mtuFix)
                _NetworkBadge(
                  label: 'MTU Fix',
                  color: colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NetworkPanelHeader extends StatelessWidget {
  final String title;
  final int count;

  const _NetworkPanelHeader(this.title, this.count);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
      child: Text(
        '$title ($count)',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _NetworkPanelActionHeader extends StatelessWidget {
  final String title;
  final int count;
  final String buttonLabel;
  final IconData icon;
  final VoidCallback onPressed;

  const _NetworkPanelActionHeader({
    required this.title,
    required this.count,
    required this.buttonLabel,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$title ($count)',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(buttonLabel),
          ),
        ],
      ),
    );
  }
}

class _NetworkPanelEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Future<void> Function() onRefresh;

  const _NetworkPanelEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
      child: Column(
        children: [
          Icon(icon, size: 54, color: colorScheme.onSurfaceVariant),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: LuciTextStyles.cardSubtitle(context),
          ),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Refresh'),
            ),
          ),
        ],
      ),
    );
  }
}

class _NetworkBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _NetworkBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
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

class _NetworkValueBlock extends StatelessWidget {
  final String label;
  final String value;
  final bool alignEnd;

  const _NetworkValueBlock({
    required this.label,
    required this.value,
    this.alignEnd = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: LuciTextStyles.detailLabel(context),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        Text(
          value,
          textAlign: alignEnd ? TextAlign.right : TextAlign.left,
          style: LuciTextStyles.detailValue(
            context,
          ).copyWith(color: colorScheme.onSurface, fontWeight: FontWeight.w900),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _AddPortForwardSheet extends ConsumerStatefulWidget {
  final OpenwrtPortForward? forward;

  const _AddPortForwardSheet({this.forward});

  @override
  ConsumerState<_AddPortForwardSheet> createState() =>
      _AddPortForwardSheetState();
}

class _AddPortForwardSheetState extends ConsumerState<_AddPortForwardSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _externalPortController = TextEditingController();
  final _destinationIpController = TextEditingController();
  final _internalPortController = TextEditingController();
  String _sourceZone = 'wan';
  String _destinationZone = 'lan';
  String _protocol = 'tcp';
  bool _isSaving = false;

  bool get _isEditing => widget.forward != null;

  @override
  void initState() {
    super.initState();
    final forward = widget.forward;
    if (forward == null) return;
    _nameController.text = forward.name;
    _externalPortController.text = forward.wanPort == 'Any'
        ? ''
        : forward.wanPort;
    _destinationIpController.text = forward.destinationIp == 'Any'
        ? ''
        : forward.destinationIp;
    _internalPortController.text = forward.destinationPort == 'Any'
        ? ''
        : forward.destinationPort;
    _sourceZone = forward.source;
    _destinationZone = forward.destinationZone;
    _protocol = _normalizeProtocol(forward.protocol);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _externalPortController.dispose();
    _destinationIpController.dispose();
    _internalPortController.dispose();
    super.dispose();
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    return null;
  }

  String? _portValidator(String? value) {
    final error = _required(value);
    if (error != null) return error;
    final port = int.tryParse(value!.trim());
    if (port == null || port < 1 || port > 65535) {
      return 'Use a port from 1 to 65535';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final appState = ref.read(appStateProvider);
      final forward = widget.forward;
      if (forward == null) {
        await appState.addPortForward(
          name: _nameController.text,
          sourceZone: _sourceZone,
          externalPort: _externalPortController.text,
          protocol: _protocol,
          destinationZone: _destinationZone,
          destinationIp: _destinationIpController.text,
          internalPort: _internalPortController.text,
        );
      } else {
        await appState.updatePortForward(
          forward,
          name: _nameController.text,
          sourceZone: _sourceZone,
          externalPort: _externalPortController.text,
          protocol: _protocol,
          destinationZone: _destinationZone,
          destinationIp: _destinationIpController.text,
          internalPort: _internalPortController.text,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _isEditing ? 'Port forward updated.' : 'Port forward added.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _isEditing
                ? 'Failed to update port forward: $e'
                : 'Failed to add port forward: $e',
          ),
        ),
      );
    }
  }

  List<DropdownMenuItem<String>> _zoneItems(String selected) {
    final zones = <String>{'wan', 'lan', selected};
    return zones
        .where((zone) => zone.trim().isNotEmpty)
        .map((zone) => DropdownMenuItem(value: zone, child: Text(zone)))
        .toList();
  }

  List<DropdownMenuItem<String>> _protocolItems(String selected) {
    final protocols = <String>{'tcp', 'udp', 'tcp udp', selected};
    return protocols
        .where((protocol) => protocol.trim().isNotEmpty)
        .map(
          (protocol) => DropdownMenuItem(
            value: protocol,
            child: Text(protocol.toUpperCase().replaceAll(' ', '/')),
          ),
        )
        .toList();
  }

  String _normalizeProtocol(String value) {
    return value
        .toLowerCase()
        .replaceAll(',', ' ')
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 16),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              _isEditing ? 'Edit Port Forward' : 'Add Port Forward',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: _required,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _sourceZone,
                    decoration: const InputDecoration(labelText: 'From Zone'),
                    items: _zoneItems(_sourceZone),
                    onChanged: (value) =>
                        setState(() => _sourceZone = value ?? 'wan'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _destinationZone,
                    decoration: const InputDecoration(labelText: 'To Zone'),
                    items: _zoneItems(_destinationZone),
                    onChanged: (value) =>
                        setState(() => _destinationZone = value ?? 'lan'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _externalPortController,
                    decoration: const InputDecoration(labelText: 'WAN Port'),
                    keyboardType: TextInputType.number,
                    validator: _portValidator,
                    textInputAction: TextInputAction.next,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _protocol,
                    decoration: const InputDecoration(labelText: 'Protocol'),
                    items: _protocolItems(_protocol),
                    onChanged: (value) =>
                        setState(() => _protocol = value ?? 'tcp'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _destinationIpController,
              decoration: const InputDecoration(labelText: 'Destination IP'),
              validator: _required,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _internalPortController,
              decoration: const InputDecoration(labelText: 'Destination Port'),
              keyboardType: TextInputType.number,
              validator: _portValidator,
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isSaving
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isSaving ? null : _save,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _isEditing ? Icons.save_rounded : Icons.add_rounded,
                          ),
                    label: Text(
                      _isSaving
                          ? _isEditing
                                ? 'Saving'
                                : 'Adding'
                          : _isEditing
                          ? 'Save'
                          : 'Add',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareWifiSheet extends StatelessWidget {
  final String ssid;
  final String password;
  final String qrData;

  const _ShareWifiSheet({
    required this.ssid,
    required this.password,
    required this.qrData,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Share Wi-Fi',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              ssid,
              textAlign: TextAlign.left,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: QrImageView(
                data: qrData,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Password',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.45,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.42),
                ),
              ),
              child: SelectableText(
                password.isEmpty ? 'No password set' : password,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: password.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: password));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Wi-Fi password copied.'),
                              ),
                            );
                          },
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copy'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NetworkInterfaceEditSheet extends ConsumerStatefulWidget {
  final String interfaceName;

  const _NetworkInterfaceEditSheet({required this.interfaceName});

  @override
  ConsumerState<_NetworkInterfaceEditSheet> createState() =>
      _NetworkInterfaceEditSheetState();
}

class _NetworkInterfaceEditSheetState
    extends ConsumerState<_NetworkInterfaceEditSheet> {
  final _ipController = TextEditingController();
  final _netmaskController = TextEditingController();
  final _dnsController = TextEditingController();
  final _startIpController = TextEditingController();
  final _endIpController = TextEditingController();
  final _leaseTimeController = TextEditingController();
  OpenwrtNetworkInterfaceConfig? _config;
  var _protocol = 'static';
  var _dhcpEnabled = false;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _ipController.dispose();
    _netmaskController.dispose();
    _dnsController.dispose();
    _startIpController.dispose();
    _endIpController.dispose();
    _leaseTimeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await ref
        .read(appStateProvider)
        .fetchNetworkInterfaceConfig(widget.interfaceName, context: context);
    if (!mounted) return;
    if (config == null) {
      setState(() => _isLoading = false);
      return;
    }
    _config = config;
    _protocol = config.protocol;
    _dhcpEnabled = config.dhcpEnabled;
    _ipController.text = config.ipAddress;
    _netmaskController.text = config.netmask;
    _dnsController.text = config.dnsText;
    _startIpController.text = _offsetToIp(
      config.ipAddress,
      config.netmask,
      config.dhcpStart,
    );
    _endIpController.text = _offsetToIp(
      config.ipAddress,
      config.netmask,
      config.dhcpStart + config.dhcpLimit - 1,
    );
    _leaseTimeController.text = config.leaseTime;
    setState(() => _isLoading = false);
  }

  String _offsetToIp(String routerIp, String netmask, int offset) {
    final router = _ipv4ToInt(routerIp);
    final mask = _ipv4ToInt(netmask);
    if (router == null || mask == null || offset <= 0) {
      return offset.toString();
    }
    return _intToIpv4((router & mask) + offset);
  }

  int _dhcpOffsetOrNumber(
    String value,
    int fallback,
    int routerIp,
    int netmask,
  ) {
    final trimmed = value.trim();
    final ip = _ipv4ToInt(trimmed);
    if (ip != null) return ip - (routerIp & netmask);
    return int.tryParse(trimmed) ?? fallback;
  }

  int? _ipv4ToInt(String value) {
    final parts = value.trim().split('.');
    if (parts.length != 4) return null;
    var result = 0;
    for (final part in parts) {
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return null;
      result = (result << 8) + octet;
    }
    return result;
  }

  String _intToIpv4(int value) {
    return [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ].join('.');
  }

  bool _isContiguousNetmask(int mask) {
    final inverted = (~mask) & 0xffffffff;
    return mask != 0 && (inverted & (inverted + 1)) == 0;
  }

  String? _validateLanConfig({
    required String ipAddress,
    required String netmask,
    required int dhcpStart,
    required int dhcpEnd,
  }) {
    final routerIp = _ipv4ToInt(ipAddress);
    if (routerIp == null) return 'Enter a valid LAN IPv4 address.';

    final mask = _ipv4ToInt(netmask);
    if (mask == null || !_isContiguousNetmask(mask)) {
      return 'Enter a valid contiguous subnet mask.';
    }

    if (!_dhcpEnabled) return null;

    final network = routerIp & mask;
    final broadcast = network | ((~mask) & 0xffffffff);
    final startIp = network + dhcpStart;
    final endIp = network + dhcpEnd;

    if (dhcpStart <= 0 || dhcpEnd <= 0 || startIp > endIp) {
      return 'Enter a valid DHCP start and end IP range.';
    }
    if (startIp <= network || endIp >= broadcast) {
      return 'DHCP range must stay inside the LAN subnet and cannot use the network or broadcast address.';
    }
    if (routerIp >= startIp && routerIp <= endIp) {
      return 'DHCP range cannot include the router LAN IP address.';
    }
    return null;
  }

  Future<void> _save() async {
    final current = _config;
    if (current == null) return;
    final ipAddress = _ipController.text.trim();
    final netmask = _netmaskController.text.trim();
    final routerIp = _ipv4ToInt(ipAddress);
    final mask = _ipv4ToInt(netmask);
    final start = routerIp == null || mask == null
        ? current.dhcpStart
        : _dhcpOffsetOrNumber(
            _startIpController.text,
            current.dhcpStart,
            routerIp,
            mask,
          ).clamp(1, 65534);
    final end = routerIp == null || mask == null
        ? current.dhcpStart + current.dhcpLimit - 1
        : _dhcpOffsetOrNumber(
            _endIpController.text,
            current.dhcpStart + current.dhcpLimit - 1,
            routerIp,
            mask,
          ).clamp(1, 65534);
    final validationError = _validateLanConfig(
      ipAddress: ipAddress,
      netmask: netmask,
      dhcpStart: start,
      dhcpEnd: end,
    );
    if (validationError != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validationError)));
      return;
    }

    final dnsServers = _dnsController.text
        .split(RegExp(r'[\s,]+'))
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList();

    final next = current.copyWith(
      protocol: _protocol,
      ipAddress: ipAddress,
      netmask: netmask,
      dnsServers: dnsServers,
      dhcpEnabled: _dhcpEnabled,
      dhcpStart: start,
      dhcpLimit: end - start + 1,
      leaseTime: _leaseTimeController.text.trim().isEmpty
          ? '12h'
          : _leaseTimeController.text.trim(),
    );

    setState(() => _isSaving = true);
    try {
      await ref
          .read(appStateProvider)
          .saveNetworkInterfaceConfig(next, context: context);
      if (!mounted) return;
      final changedLanAddress =
          current.ipAddress.trim() != next.ipAddress.trim() ||
          current.netmask.trim() != next.netmask.trim();
      if (changedLanAddress) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('LAN address updated'),
            content: Text(
              'The router may now be reachable at ${next.ipAddress}. Log out and log back in with the new IP address if the app disconnects.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Got it'),
              ),
            ],
          ),
        );
        if (!mounted) return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save interface: $e')));
      setState(() => _isSaving = false);
    }
  }

  bool get _showDhcp {
    final name = widget.interfaceName.toLowerCase();
    return name == 'lan' || _config?.dhcpSection != null;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          0,
          18,
          MediaQuery.of(context).viewInsets.bottom + 18,
        ),
        child: _isLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 44),
                child: Center(child: CircularProgressIndicator()),
              )
            : _config == null
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('Unable to load ${widget.interfaceName}.'),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer.withValues(
                              alpha: 0.55,
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.router_rounded,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${widget.interfaceName.toUpperCase()} Settings',
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(
                                      color: colorScheme.onSurface,
                                      fontWeight: FontWeight.w900,
                                    ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'IPv4 and DHCP configuration',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Close',
                          onPressed: _isSaving
                              ? null
                              : () => Navigator.of(context).pop(false),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Text(
                      'IPv4',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _FormPanel(
                      children: [
                        DropdownButtonFormField<String>(
                          initialValue: _protocol,
                          decoration: const InputDecoration(
                            labelText: 'Protocol',
                            prefixIcon: Icon(Icons.settings_ethernet_rounded),
                          ),
                          items: const ['static', 'dhcp', 'dhcpv6', 'wireguard']
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(value),
                                ),
                              )
                              .toList(),
                          onChanged: _isSaving
                              ? null
                              : (value) => setState(
                                  () => _protocol = value ?? _protocol,
                                ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _ipController,
                          enabled: !_isSaving,
                          decoration: const InputDecoration(
                            labelText: 'IP Address',
                            hintText: '192.168.10.1',
                            prefixIcon: Icon(Icons.dns_rounded),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _netmaskController,
                          enabled: !_isSaving,
                          decoration: const InputDecoration(
                            labelText: 'Subnet Mask',
                            hintText: '255.255.255.0',
                            prefixIcon: Icon(Icons.grid_4x4_rounded),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _dnsController,
                          enabled: !_isSaving,
                          decoration: const InputDecoration(
                            labelText: 'Upstream DNS Servers',
                            hintText: '1.1.1.1 8.8.8.8',
                            prefixIcon: Icon(Icons.travel_explore_rounded),
                          ),
                        ),
                      ],
                    ),
                    if (_showDhcp) ...[
                      const SizedBox(height: 16),
                      Text(
                        'DHCPv4 Server',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _FormPanel(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.36),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('DHCPv4 Server'),
                              subtitle: const Text(
                                'Assign addresses to LAN devices',
                              ),
                              value: _dhcpEnabled,
                              onChanged: _isSaving
                                  ? null
                                  : (value) =>
                                        setState(() => _dhcpEnabled = value),
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _startIpController,
                            enabled: !_isSaving && _dhcpEnabled,
                            decoration: const InputDecoration(
                              labelText: 'Start IP Address',
                              hintText: '192.168.10.100',
                              prefixIcon: Icon(Icons.first_page_rounded),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _endIpController,
                            enabled: !_isSaving && _dhcpEnabled,
                            decoration: const InputDecoration(
                              labelText: 'End IP Address',
                              hintText: '192.168.10.249',
                              prefixIcon: Icon(Icons.last_page_rounded),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _leaseTimeController,
                            enabled: !_isSaving && _dhcpEnabled,
                            decoration: const InputDecoration(
                              labelText: 'Lease Time',
                              hintText: '12h',
                              prefixIcon: Icon(Icons.schedule_rounded),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _isSaving
                                ? null
                                : () => Navigator.of(context).pop(false),
                            child: const Text('Dismiss'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _isSaving ? null : _save,
                            icon: _isSaving
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.save_rounded),
                            label: const Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _WirelessNetworkEditSheet extends ConsumerStatefulWidget {
  final String section;

  const _WirelessNetworkEditSheet({required this.section});

  @override
  ConsumerState<_WirelessNetworkEditSheet> createState() =>
      _WirelessNetworkEditSheetState();
}

class _WirelessNetworkEditSheetState
    extends ConsumerState<_WirelessNetworkEditSheet> {
  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();
  final _txPowerController = TextEditingController();
  OpenwrtWirelessNetworkConfig? _config;
  bool _enabled = true;
  bool _hidden = false;
  bool _showPassword = false;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    _txPowerController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await ref
        .read(appStateProvider)
        .fetchWirelessNetworkConfig(widget.section, context: context);
    if (!mounted) return;
    if (config == null) {
      setState(() => _isLoading = false);
      return;
    }
    _config = config;
    _ssidController.text = config.ssid;
    _passwordController.text = config.password;
    _txPowerController.text = config.txPower?.toString() ?? '';
    _enabled = config.enabled;
    _hidden = config.hidden;
    setState(() => _isLoading = false);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    final current = _config;
    if (current == null) return;
    final ssid = _ssidController.text.trim();
    if (ssid.isEmpty) {
      _showError('SSID is required.');
      return;
    }
    final password = _passwordController.text;
    final encryption = current.encryption.trim().isEmpty
        ? 'psk2'
        : current.encryption.trim();
    if (encryption != 'none' && password.isNotEmpty && password.length < 8) {
      _showError('Wi-Fi password must be at least 8 characters.');
      return;
    }
    final txText = _txPowerController.text.trim();
    final txPower = txText.isEmpty ? null : int.tryParse(txText);
    if (txText.isNotEmpty && (txPower == null || txPower < 0 || txPower > 40)) {
      _showError('TX power must be a number from 0 to 40.');
      return;
    }

    final next = current.copyWith(
      ssid: ssid,
      password: password,
      enabled: _enabled,
      hidden: _hidden,
      txPower: txPower,
    );

    setState(() => _isSaving = true);
    try {
      await ref
          .read(appStateProvider)
          .saveWirelessNetworkConfig(next, context: context);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      _showError('Failed to save Wi-Fi settings: $e');
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          0,
          18,
          MediaQuery.of(context).viewInsets.bottom + 18,
        ),
        child: _isLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 44),
                child: Center(child: CircularProgressIndicator()),
              )
            : _config == null
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('Unable to load ${widget.section}.'),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Edit Wi-Fi',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w900),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: _isSaving
                              ? null
                              : () => Navigator.of(context).pop(false),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _config!.radioSection.isEmpty
                          ? widget.section
                          : '${widget.section} on ${_config!.radioSection}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _FormPanel(
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Wi-Fi On'),
                          subtitle: const Text('Enable or disable this SSID'),
                          value: _enabled,
                          onChanged: _isSaving
                              ? null
                              : (value) => setState(() => _enabled = value),
                        ),
                        const Divider(height: 20),
                        TextField(
                          controller: _ssidController,
                          enabled: !_isSaving,
                          decoration: const InputDecoration(
                            labelText: 'SSID',
                            hintText: 'Openwalla',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passwordController,
                          enabled: !_isSaving,
                          obscureText: !_showPassword,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            hintText: 'At least 8 characters',
                            suffixIcon: IconButton(
                              tooltip: _showPassword
                                  ? 'Hide password'
                                  : 'Show password',
                              onPressed: _isSaving
                                  ? null
                                  : () => setState(
                                      () => _showPassword = !_showPassword,
                                    ),
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off_rounded
                                    : Icons.visibility_rounded,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Radio',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _FormPanel(
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('SSID Visible'),
                          subtitle: const Text(
                            'Hide the network name when off',
                          ),
                          value: !_hidden,
                          onChanged: _isSaving
                              ? null
                              : (value) => setState(() => _hidden = !value),
                        ),
                        const Divider(height: 20),
                        TextField(
                          controller: _txPowerController,
                          enabled: !_isSaving,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'TX Power',
                            hintText: 'Auto',
                            suffixText: 'dBm',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _isSaving
                                ? null
                                : () => Navigator.of(context).pop(false),
                            child: const Text('Dismiss'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _isSaving ? null : _save,
                            icon: _isSaving
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.save_rounded),
                            label: const Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _FormPanel extends StatelessWidget {
  final List<Widget> children;

  const _FormPanel({required this.children});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.28),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _UnifiedNetworkCard extends StatefulWidget {
  final String name;
  final String subtitle;
  final bool isUp;
  final IconData icon;
  final Widget details;
  final bool initiallyExpanded;

  const _UnifiedNetworkCard({
    required this.name,
    required this.subtitle,
    required this.isUp,
    required this.icon,
    required this.details,
    this.initiallyExpanded = false,
    super.key,
  });

  @override
  State<_UnifiedNetworkCard> createState() => _UnifiedNetworkCardState();
}

class _UnifiedNetworkCardState extends State<_UnifiedNetworkCard>
    with SingleTickerProviderStateMixin {
  bool _isExpanded = false;
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    if (widget.initiallyExpanded) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _UnifiedNetworkCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initiallyExpanded != oldWidget.initiallyExpanded) {
      setState(() {
        _isExpanded = widget.initiallyExpanded;
        if (_isExpanded) {
          _controller.forward();
        } else {
          _controller.reverse();
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleExpand() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final card = Card(
      elevation: _isExpanded ? 6 : 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: LuciCardStyles.standardRadius,
        side: BorderSide(
          color: widget.initiallyExpanded && _isExpanded
              ? colorScheme.primary.withValues(alpha: 0.3)
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.10),
          width: widget.initiallyExpanded && _isExpanded ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedScale(
        scale: widget.initiallyExpanded && _isExpanded ? 1.02 : 1.0,
        duration: LuciAnimations.standard,
        curve: Curves.easeOutBack,
        child: Column(
          children: [
            InkWell(
              onTap: _toggleExpand,
              borderRadius: LuciCardStyles.standardRadius,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LuciSpacing.lg,
                  vertical: 10.0,
                ),
                child: Row(
                  children: [
                    Stack(
                      alignment: Alignment.topRight,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8.0),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer.withValues(
                              alpha: 0.13,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: AnimatedScale(
                            scale: widget.initiallyExpanded && _isExpanded
                                ? 1.1
                                : 1.0,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.elasticOut,
                            child: Icon(
                              widget.icon,
                              color: widget.isUp
                                  ? colorScheme.primary
                                  : colorScheme.onSurface,
                              size: 22,
                              semanticLabel: 'Interface icon',
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Tooltip(
                            message: widget.isUp
                                ? 'Interface is up'
                                : 'Interface is down',
                            child: LuciStatusIndicators.statusDot(
                              context,
                              widget.isUp,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.name,
                            style: LuciTextStyles.cardTitle(context),
                            semanticsLabel: 'Interface name: ${widget.name}',
                          ),
                          const SizedBox(height: LuciSpacing.xs),
                          Container(
                            margin: const EdgeInsets.only(right: 32),
                            child: Divider(
                              color: colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.10),
                              thickness: 1,
                              height: 8,
                            ),
                          ),
                          Text(
                            widget.subtitle,
                            style: LuciTextStyles.cardSubtitle(context),
                            semanticsLabel:
                                'Interface details: ${widget.subtitle}',
                          ),
                        ],
                      ),
                    ),
                    if (!widget.isUp)
                      Padding(
                        padding: const EdgeInsets.only(right: LuciSpacing.xs),
                        child: LuciStatusIndicators.statusChip(
                          context,
                          'OFF',
                          false,
                        ),
                      ),
                    const SizedBox(width: LuciSpacing.sm),
                    Icon(
                      _isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: colorScheme.onSurfaceVariant,
                      size: 26,
                      semanticLabel: _isExpanded
                          ? 'Collapse details'
                          : 'Expand details',
                    ),
                  ],
                ),
              ),
            ),
            if (_isExpanded)
              Column(
                children: [
                  const Divider(height: 1, indent: 18, endIndent: 18),
                  widget.details,
                ],
              ),
          ],
        ),
      ),
    );

    if (!widget.isUp) {
      return ColorFiltered(
        colorFilter: const ColorFilter.matrix([
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]),
        child: card,
      );
    }
    return card;
  }
}
