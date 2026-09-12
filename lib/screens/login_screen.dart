import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:luci_mobile/config/app_config.dart';
import 'package:luci_mobile/models/router.dart' as model;
import 'package:luci_mobile/services/secure_storage_service.dart';
import 'package:luci_mobile/utils/url_parser.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _ipController = TextEditingController();
  final _usernameController = TextEditingController(text: 'root');
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _isCheckingAutoLogin = true;
  bool _passwordVisible = false;
  bool _advancedLogin = false;
  bool _saveCredentials = true;
  late AnimationController _logoAnimController;
  late AnimationController _progressAnimController;
  bool _isActivatingReviewerMode = false;
  @override
  void initState() {
    super.initState();
    _checkReviewerModeAndAutoLogin();
    _logoAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _progressAnimController = AnimationController(
      vsync: this,
      duration: AppConfig.reviewerModeActivationDuration,
    );
    _logoAnimController.forward();
  }

  Future<void> _checkReviewerModeAndAutoLogin() async {
    // Check if reviewer mode is enabled
    final secureStorage = SecureStorageService();
    final reviewerModeEnabled = await secureStorage.readValue(
      AppConfig.reviewerModeKey,
    );

    if (reviewerModeEnabled == 'true' && mounted) {
      // Navigate directly to main screen in reviewer mode
      unawaited(Navigator.of(context).pushReplacementNamed('/'));
    } else {
      // Try auto login
      unawaited(_tryAutoLogin());
    }
  }

  void _startReviewerModeActivation() {
    setState(() {
      _isActivatingReviewerMode = true;
    });

    // Start progress animation
    _progressAnimController.forward();

    // Start a timer to check if the user has held for 5 seconds
    Future.delayed(AppConfig.reviewerModeActivationDuration, () {
      if (_isActivatingReviewerMode && mounted) {
        _showReviewerModeDialog();
      }
    });
  }

  void _cancelReviewerModeActivation() {
    setState(() {
      _isActivatingReviewerMode = false;
    });
    // Reset progress animation
    _progressAnimController.reset();
  }

  void _showReviewerModeDialog() {
    _confirmationController.clear();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Activate Reviewer Mode?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This will enable reviewer mode which bypasses authentication '
                'and provides mock data for app demonstration purposes.',
              ),
              const SizedBox(height: 16),
              const Text(
                'To confirm, type "REVIEWER" below:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _confirmationController,
                decoration: const InputDecoration(
                  hintText: 'Type REVIEWER',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setDialogState(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _confirmationController.text == 'REVIEWER'
                  ? () {
                      Navigator.of(context).pop();
                      _activateReviewerMode();
                    }
                  : null,
              child: const Text('Activate'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _activateReviewerMode() async {
    final appState = ref.read(appStateProvider);
    await appState.setReviewerMode(true);

    if (mounted) {
      unawaited(Navigator.of(context).pushReplacementNamed('/'));
    }
  }

  @override
  void dispose() {
    _ipController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmationController.dispose();
    _logoAnimController.dispose();
    _progressAnimController.dispose();
    super.dispose();
  }

  Future<void> _tryAutoLogin() async {
    final appState = ref.read(appStateProvider);
    await appState.initialized;
    if (!mounted) return;

    if (appState.consumeSkipNextAutoLogin()) {
      final savedRouter =
          appState.selectedRouter ??
          (appState.routers.isNotEmpty ? appState.routers.first : null);
      if (savedRouter != null) _prefillRouter(savedRouter);
      if (mounted) setState(() => _isCheckingAutoLogin = false);
      return;
    }

    final savedRouter =
        appState.selectedRouter ??
        (appState.routers.isNotEmpty ? appState.routers.first : null);

    if (savedRouter != null) {
      _prefillRouter(savedRouter);

      if (savedRouter.password.isNotEmpty) {
        final success = await appState.login(
          savedRouter.ipAddress,
          savedRouter.username.trim().isEmpty ? 'root' : savedRouter.username,
          savedRouter.password,
          savedRouter.useHttps,
          fromRouter: true,
          saveCredentials: true,
          context: context,
        );
        if (success && mounted) {
          unawaited(Navigator.of(context).pushReplacementNamed('/'));
          return;
        }
      }

      if (mounted) setState(() => _isCheckingAutoLogin = false);
      return;
    }

    final success = await appState.tryAutoLogin(context: context);
    if (success && mounted) {
      unawaited(Navigator.of(context).pushReplacementNamed('/'));
    } else {
      if (mounted) {
        setState(() {
          _isCheckingAutoLogin = false;
        });
      }
    }
  }

  void _prefillRouter(model.Router router) {
    _ipController.text = router.useHttps
        ? 'https://${router.ipAddress}'
        : router.ipAddress;
    _usernameController.text = router.username.trim().isEmpty
        ? 'root'
        : router.username;
    _passwordController.text = router.password;
    _saveCredentials = true;
  }

  String _routerSubtitle(model.Router router) {
    final protocol = router.useHttps ? 'https' : 'http';
    final user = router.username.trim().isEmpty ? 'root' : router.username;
    return '$protocol • $user';
  }

  Future<bool> _confirmDeleteSavedRouter(model.Router router) async {
    final label = router.lastKnownHostname?.isNotEmpty == true
        ? router.lastKnownHostname!
        : router.ipAddress;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete saved router?'),
            content: Text('Remove $label from saved routers on this device?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _showSavedRoutersSheet() async {
    var routers = List<model.Router>.of(ref.read(appStateProvider).routers);
    if (routers.isEmpty) return;

    final selected = await showModalBottomSheet<model.Router>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.router_rounded, color: colorScheme.primary),
                        const SizedBox(width: 10),
                        Text(
                          'Saved Routers',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ...routers.map((router) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Material(
                          color: colorScheme.surfaceContainerHighest.withValues(
                            alpha: 0.26,
                          ),
                          borderRadius: BorderRadius.circular(16),
                          child: ListTile(
                            onTap: () => Navigator.of(context).pop(router),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            leading: Icon(
                              Icons.router_rounded,
                              color: colorScheme.primary,
                            ),
                            title: Text(
                              router.lastKnownHostname?.isNotEmpty == true
                                  ? router.lastKnownHostname!
                                  : router.ipAddress,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            subtitle: Text(_routerSubtitle(router)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Delete saved router',
                                  onPressed: () async {
                                    final confirmed =
                                        await _confirmDeleteSavedRouter(router);
                                    if (!confirmed ||
                                        !mounted ||
                                        !context.mounted) {
                                      return;
                                    }
                                    await ref
                                        .read(appStateProvider)
                                        .removeRouter(router.id);
                                    if (!mounted || !context.mounted) return;
                                    final updatedRouters = ref
                                        .read(appStateProvider)
                                        .routers;
                                    if (updatedRouters.isEmpty) {
                                      Navigator.of(context).pop();
                                      return;
                                    }
                                    setSheetState(() {
                                      routers = List<model.Router>.of(
                                        updatedRouters,
                                      );
                                    });
                                  },
                                  icon: Icon(
                                    Icons.delete_outline_rounded,
                                    color: colorScheme.error,
                                  ),
                                ),
                                const Icon(Icons.chevron_right_rounded),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (selected == null || !mounted) {
      final selectedRouter = ref.read(appStateProvider).selectedRouter;
      if (selectedRouter != null && mounted) {
        setState(() => _prefillRouter(selectedRouter));
      }
      return;
    }
    setState(() => _prefillRouter(selected));
  }

  Future<void> _connect() async {
    if (_formKey.currentState!.validate()) {
      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));

      final appState = ref.read(appStateProvider);
      final input = _ipController.text.trim();
      final user = _usernameController.text;
      final pass = _passwordController.text;

      // Parse the input to extract host, port, and protocol
      final parsedUrl = UrlParser.parse(input);

      if (!parsedUrl.isValid) {
        // Show error message
        appState.setError(parsedUrl.error ?? 'Invalid address format');
        return;
      }

      // Use the parsed values
      final success = await appState.login(
        parsedUrl.hostWithPort,
        user,
        pass,
        parsedUrl.useHttps,
        fromRouter: false,
        saveCredentials: _saveCredentials,
        context: context,
      );

      if (success && mounted) {
        FocusManager.instance.primaryFocus?.unfocus();
        unawaited(
          SystemChannels.textInput.invokeMethod<void>('TextInput.hide'),
        );
        unawaited(Navigator.of(context).pushReplacementNamed('/'));
      }
    }
  }

  Future<void> _openGitHubIssues() async {
    final url = AppConfig.githubIssuesUrl;
    final success = await launchUrlString(
      url,
      mode: LaunchMode.externalApplication,
    );
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not open GitHub issues'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  InputDecoration _loginInputDecoration({
    required BuildContext context,
    required IconData icon,
    String? hintText,
    String? helperText,
    Widget? suffixIcon,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return InputDecoration(
      isDense: false,
      hintText: hintText,
      helperText: helperText,
      helperMaxLines: 2,
      helperStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.78),
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      prefixIcon: Icon(icon),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.36),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.36),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(
          color: colorScheme.primary.withValues(alpha: 0.78),
          width: 1.4,
        ),
      ),
    );
  }

  Widget _loginField({
    Key? key,
    required BuildContext context,
    String? label,
    required Widget child,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Padding(
            padding: const EdgeInsets.only(left: 22, bottom: 6),
            child: Text(
              label,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.86),
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
        child,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingAutoLogin) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  colorScheme.surfaceContainerLowest,
                  colorScheme.surface,
                  colorScheme.surfaceContainer,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          Center(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 32,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(height: 32),
                        GestureDetector(
                          onLongPress: () {
                            _startReviewerModeActivation();
                          },
                          onLongPressUp: () {
                            _cancelReviewerModeActivation();
                          },
                          child: Column(
                            children: [
                              Column(
                                children: [
                                  Text(
                                    'Openwalla',
                                    style: textTheme.headlineLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Connect to your OpenWrt router',
                                    style: textTheme.titleMedium?.copyWith(
                                      color: colorScheme.onSurface.withValues(
                                        alpha: 0.8,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Fast. Secure. Open source.',
                                    style: textTheme.bodySmall?.copyWith(
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                child: _isActivatingReviewerMode
                                    ? Padding(
                                        key: const ValueKey('progress'),
                                        padding: const EdgeInsets.only(top: 24),
                                        child: AnimatedBuilder(
                                          animation: _progressAnimController,
                                          builder: (context, child) {
                                            return Column(
                                              children: [
                                                Text(
                                                  'Hold to activate reviewer mode...',
                                                  style: textTheme.bodySmall
                                                      ?.copyWith(
                                                        color:
                                                            colorScheme.primary,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize: 13,
                                                      ),
                                                ),
                                                const SizedBox(height: 12),
                                                Container(
                                                  width: 280,
                                                  height: 6,
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                    color: colorScheme
                                                        .surfaceContainerHighest
                                                        .withValues(alpha: 0.4),
                                                    border: Border.all(
                                                      color: colorScheme.outline
                                                          .withValues(
                                                            alpha: 0.15,
                                                          ),
                                                      width: 0.5,
                                                    ),
                                                  ),
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                    child: LinearProgressIndicator(
                                                      value:
                                                          _progressAnimController
                                                              .value,
                                                      backgroundColor:
                                                          Colors.transparent,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                            Color
                                                          >(
                                                            colorScheme.primary
                                                                .withValues(
                                                                  alpha: 0.9,
                                                                ),
                                                          ),
                                                      minHeight: 6,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      )
                                    : const SizedBox(
                                        key: ValueKey('empty'),
                                        height: 0,
                                      ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                            child: Card(
                              elevation: 0,
                              color: colorScheme.surface.withValues(
                                alpha: 0.94,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                                side: BorderSide(
                                  color: colorScheme.outline.withValues(
                                    alpha: 0.14,
                                  ),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18.0,
                                  vertical: 16.0,
                                ),
                                child: Form(
                                  key: _formKey,
                                  child: Builder(
                                    builder: (context) {
                                      final appState = ref.watch(
                                        appStateProvider,
                                      );
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        mainAxisSize: MainAxisSize.min,
                                        children: <Widget>[
                                          _loginField(
                                            context: context,
                                            child: Tooltip(
                                              message:
                                                  'Enter the IP address, hostname, or full URL of your router',
                                              child: TextFormField(
                                                controller: _ipController,
                                                autofocus: true,
                                                autofillHints: const [
                                                  AutofillHints.url,
                                                  AutofillHints.username,
                                                ],
                                                decoration: _loginInputDecoration(
                                                  context: context,
                                                  icon: Icons.shield_outlined,
                                                  helperText:
                                                      '192.168.1.1, router.local:8080, or https://192.168.1.1',
                                                  suffixIcon:
                                                      appState.routers.isEmpty
                                                      ? null
                                                      : IconButton(
                                                          tooltip:
                                                              'Saved routers',
                                                          onPressed:
                                                              _showSavedRoutersSheet,
                                                          icon: const Icon(
                                                            Icons
                                                                .arrow_drop_down_rounded,
                                                          ),
                                                        ),
                                                ),
                                                textInputAction:
                                                    TextInputAction.next,
                                                validator: (value) {
                                                  if (value == null ||
                                                      value.isEmpty) {
                                                    return 'Please enter the router address';
                                                  }
                                                  final parsed =
                                                      UrlParser.parse(value);
                                                  if (!parsed.isValid) {
                                                    return parsed.error ??
                                                        'Invalid address format';
                                                  }
                                                  return null;
                                                },
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 16),
                                          AnimatedSwitcher(
                                            duration: const Duration(
                                              milliseconds: 180,
                                            ),
                                            child: _advancedLogin
                                                ? _loginField(
                                                    key: const ValueKey(
                                                      'username',
                                                    ),
                                                    context: context,
                                                    label: 'Username',
                                                    child: Tooltip(
                                                      message:
                                                          'Enter your router username',
                                                      child: TextFormField(
                                                        controller:
                                                            _usernameController,
                                                        autofillHints: const [
                                                          AutofillHints
                                                              .username,
                                                        ],
                                                        decoration:
                                                            _loginInputDecoration(
                                                              context: context,
                                                              icon: Icons
                                                                  .person_outline,
                                                              helperText:
                                                                  'Default is root',
                                                            ),
                                                        textInputAction:
                                                            TextInputAction
                                                                .next,
                                                        validator: (value) {
                                                          if (value == null ||
                                                              value.isEmpty) {
                                                            return 'Please enter the username';
                                                          }
                                                          return null;
                                                        },
                                                      ),
                                                    ),
                                                  )
                                                : const SizedBox.shrink(),
                                          ),
                                          if (_advancedLogin)
                                            const SizedBox(height: 14),
                                          _loginField(
                                            context: context,
                                            child: Tooltip(
                                              message:
                                                  'Enter your router password',
                                              child: TextFormField(
                                                controller: _passwordController,
                                                obscureText: !_passwordVisible,
                                                autofillHints: const [
                                                  AutofillHints.password,
                                                ],
                                                decoration: _loginInputDecoration(
                                                  context: context,
                                                  icon: Icons.lock_outline,
                                                  hintText: 'Password',
                                                  suffixIcon: IconButton(
                                                    icon: Icon(
                                                      _passwordVisible
                                                          ? Icons
                                                                .visibility_outlined
                                                          : Icons
                                                                .visibility_off_outlined,
                                                    ),
                                                    onPressed: () => setState(
                                                      () => _passwordVisible =
                                                          !_passwordVisible,
                                                    ),
                                                    tooltip: _passwordVisible
                                                        ? 'Hide password'
                                                        : 'Show password',
                                                  ),
                                                ),
                                                textInputAction:
                                                    TextInputAction.done,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 18),
                                          Row(
                                            children: [
                                              Checkbox(
                                                value: _saveCredentials,
                                                onChanged: appState.isLoading
                                                    ? null
                                                    : (value) => setState(
                                                        () => _saveCredentials =
                                                            value ?? true,
                                                      ),
                                                visualDensity:
                                                    VisualDensity.compact,
                                              ),
                                              const SizedBox(width: 4),
                                              Expanded(
                                                child: GestureDetector(
                                                  behavior:
                                                      HitTestBehavior.opaque,
                                                  onTap: appState.isLoading
                                                      ? null
                                                      : () => setState(
                                                          () => _saveCredentials =
                                                              !_saveCredentials,
                                                        ),
                                                  child: Text(
                                                    'Save credentials',
                                                    style: textTheme.bodyMedium
                                                        ?.copyWith(
                                                          color: colorScheme
                                                              .onSurfaceVariant,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                              TextButton.icon(
                                                onPressed: () => setState(
                                                  () => _advancedLogin =
                                                      !_advancedLogin,
                                                ),
                                                icon: Icon(
                                                  _advancedLogin
                                                      ? Icons.expand_less
                                                      : Icons.tune_rounded,
                                                  size: 18,
                                                ),
                                                label: Text(
                                                  _advancedLogin
                                                      ? 'Hide User'
                                                      : 'Show User',
                                                ),
                                              ),
                                            ],
                                          ),
                                          AnimatedSwitcher(
                                            duration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            child: appState.errorMessage != null
                                                ? Padding(
                                                    key: const ValueKey(
                                                      'error',
                                                    ),
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 12.0,
                                                        ),
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                            10,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: colorScheme
                                                            .errorContainer
                                                            .withValues(
                                                              alpha: 1,
                                                            ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                      child: Row(
                                                        children: [
                                                          Icon(
                                                            Icons.error_outline,
                                                            color: colorScheme
                                                                .onErrorContainer,
                                                          ),
                                                          const SizedBox(
                                                            width: 12,
                                                          ),
                                                          Expanded(
                                                            child: Text(
                                                              appState
                                                                  .errorMessage!,
                                                              style: textTheme
                                                                  .bodyMedium
                                                                  ?.copyWith(
                                                                    color: colorScheme
                                                                        .onErrorContainer,
                                                                  ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  )
                                                : const SizedBox.shrink(),
                                          ),
                                          const SizedBox(height: 16),
                                          TweenAnimationBuilder<double>(
                                            duration: const Duration(
                                              milliseconds: 100,
                                            ),
                                            tween: Tween<double>(
                                              begin: 1,
                                              end: appState.isLoading
                                                  ? 0.98
                                                  : 1,
                                            ),
                                            builder: (context, scale, child) {
                                              return Transform.scale(
                                                scale: scale,
                                                child: child,
                                              );
                                            },
                                            child: SizedBox(
                                              width: double.infinity,
                                              child: ElevatedButton(
                                                onPressed: appState.isLoading
                                                    ? null
                                                    : _connect,
                                                style: ElevatedButton.styleFrom(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 18,
                                                      ),
                                                  textStyle: const TextStyle(
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          14,
                                                        ),
                                                  ),
                                                  elevation: 4,
                                                  backgroundColor:
                                                      colorScheme.primary,
                                                  foregroundColor:
                                                      colorScheme.onPrimary,
                                                ),
                                                child: appState.isLoading
                                                    ? const SizedBox(
                                                        height: 26,
                                                        width: 26,
                                                        child:
                                                            CircularProgressIndicator(
                                                              strokeWidth: 3,
                                                              color:
                                                                  Colors.white,
                                                            ),
                                                      )
                                                    : Row(
                                                        mainAxisAlignment:
                                                            MainAxisAlignment
                                                                .center,
                                                        children: const [
                                                          Icon(Icons.login),
                                                          SizedBox(width: 12),
                                                          Text('Connect'),
                                                        ],
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Tooltip(
                          message: 'Open GitHub issues for support',
                          child: TextButton(
                            onPressed: _openGitHubIssues,
                            style: TextButton.styleFrom(
                              foregroundColor: colorScheme.primary,
                            ),
                            child: const Text('Need help?'),
                          ),
                        ),
                        FutureBuilder<PackageInfo>(
                          future: PackageInfo.fromPlatform(),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return const SizedBox.shrink();
                            }
                            final info = snapshot.data!;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8.0),
                              child: Text(
                                'Version ${info.version}',
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
