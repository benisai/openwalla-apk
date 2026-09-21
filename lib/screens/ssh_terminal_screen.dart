import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/services/ssh_service.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';

class SshTerminalScreen extends ConsumerStatefulWidget {
  const SshTerminalScreen({super.key});

  @override
  ConsumerState<SshTerminalScreen> createState() => _SshTerminalScreenState();
}

class _SshTerminalScreenState extends ConsumerState<SshTerminalScreen> {
  static final _ansiPattern = RegExp(
    r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))',
  );

  final _commandController = TextEditingController();
  final _scrollController = ScrollController();
  final _output = StringBuffer();
  SshShellConnection? _connection;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _connecting = true;
  bool _connected = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  @override
  void dispose() {
    _commandController.dispose();
    _scrollController.dispose();
    unawaited(_disconnect(updateState: false));
    super.dispose();
  }

  String _sshHost(String address) {
    final value = address.trim();
    if (value.contains('://')) return Uri.parse(value).host;
    final withoutPath = value.split('/').first;
    if (withoutPath.startsWith('[')) {
      final end = withoutPath.indexOf(']');
      return end > 0 ? withoutPath.substring(1, end) : withoutPath;
    }
    if (':'.allMatches(withoutPath).length == 1) {
      return withoutPath.split(':').first;
    }
    return withoutPath;
  }

  Future<void> _connect() async {
    await _disconnect(updateState: false);
    final router = ref.read(appStateProvider).selectedRouter;
    if (router == null) {
      setState(() {
        _connecting = false;
        _error = 'No router is selected.';
      });
      return;
    }
    if (router.username.trim().isEmpty || router.password.isEmpty) {
      setState(() {
        _connecting = false;
        _error = 'Saved router SSH credentials are missing.';
      });
      return;
    }

    setState(() {
      _connecting = true;
      _connected = false;
      _error = null;
      _output.clear();
      _output.writeln(
        'Connecting to ${router.username}@${_sshHost(router.ipAddress)}...',
      );
    });

    try {
      final connection = await SshService().connectShell(
        host: _sshHost(router.ipAddress),
        username: router.username,
        password: router.password,
      );
      if (!mounted) {
        await connection.close();
        return;
      }
      _connection = connection;
      _stdoutSubscription = connection.stdout.listen(_appendOutput);
      _stderrSubscription = connection.stderr.listen(_appendOutput);
      unawaited(
        connection.done.then((_) {
          if (!mounted || _connection != connection) return;
          setState(() {
            _connected = false;
            _connecting = false;
            _output.writeln('\nConnection closed.');
          });
          _scrollToBottom();
        }),
      );
      setState(() {
        _connecting = false;
        _connected = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _connected = false;
        _error = error.toString();
        _output.writeln('\nConnection failed.');
      });
    }
  }

  void _appendOutput(String chunk) {
    if (!mounted) return;
    setState(() => _output.write(chunk.replaceAll(_ansiPattern, '')));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  void _sendCommand() {
    final command = _commandController.text;
    if (!_connected || command.trim().isEmpty) return;
    _connection?.write('$command\n');
    _commandController.clear();
  }

  Future<void> _disconnect({bool updateState = true}) async {
    final connection = _connection;
    _connection = null;
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    await connection?.close();
    if (updateState && mounted) {
      setState(() {
        _connected = false;
        _connecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final router = ref.watch(appStateProvider).selectedRouter;
    return Scaffold(
      appBar: LuciAppBar(
        title: 'SSH Terminal',
        showBack: true,
        actions: [
          IconButton(
            tooltip: 'Clear terminal',
            onPressed: () => setState(() => _output.clear()),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(
            tooltip: _connected ? 'Disconnect' : 'Reconnect',
            onPressed: _connecting
                ? null
                : _connected
                ? _disconnect
                : _connect,
            icon: Icon(
              _connected ? Icons.link_off_rounded : Icons.refresh_rounded,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _connected
                          ? const Color(0xFF20CF70)
                          : _connecting
                          ? colors.tertiary
                          : colors.error,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _connecting
                          ? 'Connecting'
                          : _connected
                          ? '${router?.username}@${_sshHost(router?.ipAddress ?? '')}'
                          : 'Disconnected',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF090C12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: SelectableText(
                      _output.isEmpty
                          ? 'Waiting for terminal output...'
                          : _output.toString(),
                      style: const TextStyle(
                        color: Color(0xFFE5E7EB),
                        fontFamily: 'monospace',
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.error),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Send Ctrl+C',
                    onPressed: _connected
                        ? () => _connection?.write('\x03')
                        : null,
                    icon: const Icon(Icons.stop_rounded),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _commandController,
                      enabled: _connected,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        hintText: 'Enter command',
                        prefixText: r'$ ',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendCommand(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send command',
                    onPressed: _connected ? _sendCommand : null,
                    icon: const Icon(Icons.arrow_upward_rounded),
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
