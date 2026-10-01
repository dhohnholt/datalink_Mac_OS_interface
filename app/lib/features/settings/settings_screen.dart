import 'dart:async';

import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/appearance.dart';
import '../../app/scope.dart';
import '../../hardware_check/hardware_check_card.dart';
import '../../ui/widgets.dart';
import 'upload_specification.dart';

const String appVersionLabel = '2.0.0';
const String privacyPolicyUrl = 'https://dhohnholt.github.io/datalink_Mac_OS_interface/privacy.html';
const String supportUrl = 'https://dhohnholt.github.io/datalink_Mac_OS_interface/';

/// Where scored reports go, what is sent, diagnostics, and the About details.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _api = TextEditingController();
  final _site = TextEditingController();
  final _token = TextEditingController();
  String? _addressError;
  String? _connectError;
  bool _busy = false;
  bool _seeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    final connection = Services.of(context).connection;
    unawaited(connection.ensureLoaded());
    _api.text = connection.apiUrl;
    _site.text = connection.siteUrl;
  }

  @override
  void dispose() {
    _api.dispose();
    _site.dispose();
    _token.dispose();
    super.dispose();
  }

  void _saveAddress() {
    final connection = Services.of(context).connection;
    setState(() => _addressError = null);
    try {
      connection.saveAddress(_api.text, _site.text);
      showToast(context, _api.text.trim().isEmpty ? 'Upload address cleared' : 'Upload address saved');
    } on UploadError catch (error) {
      setState(() => _addressError = error.message);
    }
  }

  Future<void> _connect() async {
    final connection = Services.of(context).connection;
    setState(() {
      _connectError = null;
      _busy = true;
    });
    try {
      await connection.connect(_token.text);
      // Do not leave the token sitting in a text box.
      _token.clear();
      if (mounted) showToast(context, 'Connected to your site');
    } on UploadError catch (error) {
      if (mounted) setState(() => _connectError = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final connection = Services.of(context).connection;
    final ok = await confirmDialog(
      context,
      title: 'Disconnect',
      message: "Disconnect from your site? The connection token is removed from this Mac's Keychain.",
      confirmLabel: 'Disconnect',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await connection.disconnect();
    if (mounted) showToast(context, 'Disconnected');
  }

  Future<void> _refresh() async {
    final connection = Services.of(context).connection;
    setState(() => _busy = true);
    try {
      final count = await connection.refresh();
      if (mounted) showToast(context, '$count test(s) available');
    } on UploadError catch (error) {
      if (mounted) showToast(context, error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final connection = services.connection;
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          SectionCard(
            title: 'Appearance',
            subtitle: 'Light, dark, or follow this Mac. Also under View > Appearance.',
            child: ListenableBuilder(
              listenable: services.appearance,
              builder: (context, _) => SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: [
                  for (final mode in ThemeMode.values)
                    ButtonSegment(value: mode, label: Text(Appearance.label(mode).replaceFirst('Match System', 'System'))),
                ],
                selected: {services.appearance.mode},
                onSelectionChanged: (selection) => services.appearance.set(selection.first),
              ),
            ),
          ),
          SectionCard(
            title: 'Send scored reports to your own site',
            subtitle: connection.status,
            trailing: Wrap(spacing: 8, children: [
              if (connection.siteUrl.isNotEmpty)
                OutlinedButton(
                  onPressed: () => services.actions.openUrl(connection.siteUrl),
                  child: const Text('Open your site'),
                ),
              if (connection.connected)
                TextButton(
                  onPressed: _disconnect,
                  style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                  child: const Text('Disconnect'),
                ),
            ]),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'DataLink can send a scored report straight to a website of your own, so a '
                  'class set of sheets becomes a page you can read and share without exporting '
                  'anything by hand. It sends the report for one session at a time, over HTTPS, '
                  'to an address you give it. Nothing leaves this Mac until you ask it to, and '
                  'nothing is sent anywhere by default.',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.start,
                  children: [
                    SizedBox(
                      width: 380,
                      child: TextField(
                        controller: _api,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Upload address',
                          hintText: 'https://example.org/functions/v1/datalink-api',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 320,
                      child: TextField(
                        controller: _site,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Site address (optional)',
                          hintText: 'https://example.org/reports',
                        ),
                      ),
                    ),
                    OutlinedButton(onPressed: _saveAddress, child: const Text('Save address')),
                  ],
                ),
                if (_addressError != null) _problem(context, _addressError!),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Do not have a site yet?'),
                  children: [
                    const Text(
                      'The button below copies a full specification of what DataLink sends and '
                      'what it expects back. Give it to an AI coding assistant, or to whoever '
                      'maintains your site, and it describes the whole contract: the two '
                      'requests, the shape of a scored report, the token format, the size limit '
                      'and how retries must be treated. It is the same specification this app '
                      'was built against.',
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: () async {
                          await Clipboard.setData(const ClipboardData(text: uploadSpecification));
                          if (context.mounted) showToast(context, 'Specification copied');
                        },
                        child: const Text('Copy the specification'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      uploadSpecification,
                      style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
                    ),
                  ],
                ),
                const Divider(height: 32),
                if (!connection.hasEndpoint)
                  const Text('Enter and save an upload address before connecting.')
                else if (!connection.connected) ...[
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.start,
                    children: [
                      SizedBox(
                        width: 380,
                        child: TextField(
                          controller: _token,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Connection token',
                            hintText: 'dlk_live_…',
                          ),
                          onSubmitted: (_) => _connect(),
                        ),
                      ),
                      FilledButton(
                        onPressed: _busy ? null : _connect,
                        child: const Text('Connect'),
                      ),
                    ],
                  ),
                  if (_connectError != null) _problem(context, _connectError!),
                ] else ...[
                  Text(connection.destinationSummary),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _refresh,
                      child: const Text('Refresh tests'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SectionCard(
            title: 'What is sent',
            subtitle: 'Only the scored report for the session you choose.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Bullet('Student IDs, names, per-question responses and scores for that test.'),
                const _Bullet('Per-question statistics and the class summary.'),
                _Bullet(
                  connection.hasEndpoint
                      ? 'Sent over HTTPS to ${connection.apiUrl}.'
                      : 'Sent over HTTPS to an address you set above. None is set, so nothing can be sent.',
                ),
                const _Bullet(
                  'Your token travels only as an authorization header, never in the report body, '
                  'and is never logged.',
                ),
                const _Bullet('No password, email, or other account credential is requested or transmitted.'),
              ],
            ),
          ),
          SectionCard(
            title: 'Diagnostics',
            subtitle: 'If the scanner will not connect, this says where it stopped.',
            child: const HardwareCheckCard(),
          ),
          SectionCard(
            title: 'About',
            subtitle: 'DataLink Scanner $appVersionLabel',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Nothing is collected. No analytics, no crash reporting, no account. Scanned '
                  'sheets, student names and student ID numbers are kept only on this Mac.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'DataLink Scanner is an independent project. It is not affiliated with or '
                  'endorsed by Apperson, the maker of the DataLink 1200.',
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 8, children: [
                  OutlinedButton(
                    onPressed: () => services.actions.openUrl(privacyPolicyUrl),
                    child: const Text('Privacy policy'),
                  ),
                  OutlinedButton(
                    onPressed: () => services.actions.openUrl(supportUrl),
                    child: const Text('Support'),
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _problem(BuildContext context, String message) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Semantics(
          liveRegion: true,
          child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ExcludeSemantics(child: Text('•  ')),
            Expanded(child: Text(text)),
          ],
        ),
      );
}
