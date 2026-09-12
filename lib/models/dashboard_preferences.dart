enum DashboardFlowMode { detailed, simple }

class DashboardPreferences {
  final Set<String> enabledWirelessInterfaces;
  final Set<String> enabledWiredInterfaces;
  final bool wirelessInterfaceSelectionInitialized;
  final bool wiredInterfaceSelectionInitialized;
  final String? primaryThroughputInterface;
  final bool showAllThroughput;
  final bool showNetworkPerformanceCard;
  final bool showFlowsCard;
  final bool showStatisticsTab;
  final bool showWifiShortcut;
  final bool showSmartQueueShortcut;
  final bool showAdblockShortcut;
  final bool showVpnShortcut;
  final bool showSchedulerShortcut;
  final bool showInactiveWirelessNetworks;
  final int shortcutPanelVisibleCount;
  final List<String> shortcutOrder;
  final int liveThroughputRefreshSeconds;
  final DashboardFlowMode flowMode;

  DashboardPreferences({
    Set<String>? enabledWirelessInterfaces,
    Set<String>? enabledWiredInterfaces,
    this.wirelessInterfaceSelectionInitialized = false,
    this.wiredInterfaceSelectionInitialized = false,
    this.primaryThroughputInterface,
    this.showAllThroughput = true,
    this.showNetworkPerformanceCard = false,
    this.showFlowsCard = false,
    this.showStatisticsTab = true,
    this.showWifiShortcut = true,
    this.showSmartQueueShortcut = true,
    this.showAdblockShortcut = true,
    this.showVpnShortcut = true,
    this.showSchedulerShortcut = true,
    this.showInactiveWirelessNetworks = false,
    this.shortcutPanelVisibleCount = 6,
    List<String>? shortcutOrder,
    this.liveThroughputRefreshSeconds = 3,
    this.flowMode = DashboardFlowMode.detailed,
  }) : enabledWirelessInterfaces = enabledWirelessInterfaces ?? {},
       enabledWiredInterfaces = enabledWiredInterfaces ?? {},
       shortcutOrder = shortcutOrder ?? defaultShortcutOrder;

  static const defaultShortcutOrder = [
    'network',
    'dns',
    'wifi',
    'routes',
    'smart_queue',
    'adblock',
    'services',
    'vpn',
    'scheduler',
  ];

  DashboardPreferences copyWith({
    Set<String>? enabledWirelessInterfaces,
    Set<String>? enabledWiredInterfaces,
    bool? wirelessInterfaceSelectionInitialized,
    bool? wiredInterfaceSelectionInitialized,
    String? primaryThroughputInterface,
    bool? showAllThroughput,
    bool? showNetworkPerformanceCard,
    bool? showFlowsCard,
    bool? showStatisticsTab,
    bool? showWifiShortcut,
    bool? showSmartQueueShortcut,
    bool? showAdblockShortcut,
    bool? showVpnShortcut,
    bool? showSchedulerShortcut,
    bool? showInactiveWirelessNetworks,
    int? shortcutPanelVisibleCount,
    List<String>? shortcutOrder,
    int? liveThroughputRefreshSeconds,
    DashboardFlowMode? flowMode,
  }) {
    return DashboardPreferences(
      enabledWirelessInterfaces:
          enabledWirelessInterfaces ?? this.enabledWirelessInterfaces,
      enabledWiredInterfaces:
          enabledWiredInterfaces ?? this.enabledWiredInterfaces,
      wirelessInterfaceSelectionInitialized:
          wirelessInterfaceSelectionInitialized ??
          this.wirelessInterfaceSelectionInitialized,
      wiredInterfaceSelectionInitialized:
          wiredInterfaceSelectionInitialized ??
          this.wiredInterfaceSelectionInitialized,
      primaryThroughputInterface:
          primaryThroughputInterface ?? this.primaryThroughputInterface,
      showAllThroughput: showAllThroughput ?? this.showAllThroughput,
      showNetworkPerformanceCard:
          showNetworkPerformanceCard ?? this.showNetworkPerformanceCard,
      showFlowsCard: showFlowsCard ?? this.showFlowsCard,
      showStatisticsTab: showStatisticsTab ?? this.showStatisticsTab,
      showWifiShortcut: showWifiShortcut ?? this.showWifiShortcut,
      showSmartQueueShortcut:
          showSmartQueueShortcut ?? this.showSmartQueueShortcut,
      showAdblockShortcut: showAdblockShortcut ?? this.showAdblockShortcut,
      showVpnShortcut: showVpnShortcut ?? this.showVpnShortcut,
      showSchedulerShortcut:
          showSchedulerShortcut ?? this.showSchedulerShortcut,
      showInactiveWirelessNetworks:
          showInactiveWirelessNetworks ?? this.showInactiveWirelessNetworks,
      shortcutPanelVisibleCount:
          shortcutPanelVisibleCount ?? this.shortcutPanelVisibleCount,
      shortcutOrder: shortcutOrder ?? this.shortcutOrder,
      liveThroughputRefreshSeconds:
          liveThroughputRefreshSeconds ?? this.liveThroughputRefreshSeconds,
      flowMode: flowMode ?? this.flowMode,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabledWirelessInterfaces': enabledWirelessInterfaces.toList(),
    'enabledWiredInterfaces': enabledWiredInterfaces.toList(),
    'wirelessInterfaceSelectionInitialized':
        wirelessInterfaceSelectionInitialized,
    'wiredInterfaceSelectionInitialized': wiredInterfaceSelectionInitialized,
    'primaryThroughputInterface': primaryThroughputInterface,
    'showAllThroughput': showAllThroughput,
    'showNetworkPerformanceCard': showNetworkPerformanceCard,
    'showFlowsCard': showFlowsCard,
    'showStatisticsTab': showStatisticsTab,
    'showWifiShortcut': showWifiShortcut,
    'showSmartQueueShortcut': showSmartQueueShortcut,
    'showAdblockShortcut': showAdblockShortcut,
    'showVpnShortcut': showVpnShortcut,
    'showSchedulerShortcut': showSchedulerShortcut,
    'showInactiveWirelessNetworks': showInactiveWirelessNetworks,
    'shortcutPanelVisibleCount': shortcutPanelVisibleCount,
    'shortcutOrder': shortcutOrder,
    'liveThroughputRefreshSeconds': liveThroughputRefreshSeconds,
    'flowMode': flowMode.name,
  };

  factory DashboardPreferences.fromJson(Map<String, dynamic> json) {
    return DashboardPreferences(
      enabledWirelessInterfaces: Set<String>.from(
        json['enabledWirelessInterfaces'] ?? [],
      ),
      enabledWiredInterfaces: Set<String>.from(
        json['enabledWiredInterfaces'] ?? [],
      ),
      wirelessInterfaceSelectionInitialized:
          json['wirelessInterfaceSelectionInitialized'] == true,
      wiredInterfaceSelectionInitialized:
          json['wiredInterfaceSelectionInitialized'] == true,
      primaryThroughputInterface: json['primaryThroughputInterface'],
      showAllThroughput: json['showAllThroughput'] ?? true,
      showNetworkPerformanceCard: json['showNetworkPerformanceCard'] ?? false,
      showFlowsCard: json['showFlowsCard'] ?? false,
      showStatisticsTab: json['showStatisticsTab'] ?? true,
      showWifiShortcut: json['showWifiShortcut'] ?? true,
      showSmartQueueShortcut: json['showSmartQueueShortcut'] ?? true,
      showAdblockShortcut: json['showAdblockShortcut'] ?? true,
      showVpnShortcut: json['showVpnShortcut'] ?? true,
      showSchedulerShortcut: json['showSchedulerShortcut'] ?? true,
      showInactiveWirelessNetworks:
          json['showInactiveWirelessNetworks'] == true,
      shortcutPanelVisibleCount: _parseShortcutPanelVisibleCount(
        json['shortcutPanelVisibleCount'],
      ),
      shortcutOrder: _parseShortcutOrder(json['shortcutOrder']),
      liveThroughputRefreshSeconds: _parseLiveThroughputRefreshSeconds(
        json['liveThroughputRefreshSeconds'],
      ),
      flowMode: DashboardFlowMode.values.firstWhere(
        (mode) => mode.name == json['flowMode']?.toString(),
        orElse: () => DashboardFlowMode.detailed,
      ),
    );
  }

  static int _parseShortcutPanelVisibleCount(dynamic value) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    return parsed == 3 ? 3 : 6;
  }

  static int _parseLiveThroughputRefreshSeconds(dynamic value) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    return const {2, 3, 5, 10}.contains(parsed) ? parsed! : 3;
  }

  static List<String> _parseShortcutOrder(dynamic value) {
    final raw = value is List
        ? value.map((item) => item.toString()).toList()
        : const <String>[];
    final clean = raw
        .where((item) => defaultShortcutOrder.contains(item))
        .toSet()
        .toList();
    return [
      ...clean,
      ...defaultShortcutOrder.where((item) => !clean.contains(item)),
    ];
  }

  static DashboardPreferences get defaultPreferences => DashboardPreferences();
}
