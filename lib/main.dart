import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import 'package:screen_brightness/screen_brightness.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Device Info',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const Bootstrap(),
    );
  }
}

class Keys {
  static const provisioned = 'provisioned_v1';
  static const imei = 'imei';
  static const imei2 = 'imei2';
  static const eid = 'eid';
  static const meid = 'meid';
  static const serial = 'serial';
  static const model = 'model';
  static const passSalt = 'pass_salt';
  static const passHash = 'pass_hash';
  static const recoverySalt = 'recovery_salt';
  static const recoveryHash = 'recovery_hash';
  static const failedCount = 'failed_count';
  static const lockoutUntilMs = 'lockout_until_ms';
  static const sealedAtMs = 'sealed_at_ms';
  static const editGraceUntilMs = 'edit_grace_until_ms';
}

const _editGraceDuration = Duration(minutes: 15);

class Store {
  static const _s = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: false),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static Future<String?> read(String k) => _s.read(key: k);
  static Future<void> write(String k, String v) => _s.write(key: k, value: v);
  static Future<void> wipe() => _s.deleteAll();
}

class CryptoUtil {
  static String randomHex(int bytes) {
    final r = Random.secure();
    return List<int>.generate(bytes, (_) => r.nextInt(256))
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String stretch(String value, String salt, {int iterations = 120000}) {
    var current = Uint8List.fromList(utf8.encode('$salt|$value'));
    for (var i = 0; i < iterations; i++) {
      current = Uint8List.fromList(sha256.convert(current).bytes);
    }
    return base64.encode(current);
  }

  static String recoveryCode() {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    final raw = List.generate(20, (_) => alphabet[r.nextInt(alphabet.length)]).join();
    return '${raw.substring(0, 4)}-${raw.substring(4, 8)}-${raw.substring(8, 12)}-${raw.substring(12, 16)}-${raw.substring(16, 20)}';
  }
}

bool luhn15(String digits) {
  if (digits.length != 15 || !RegExp(r'^\d{15}$').hasMatch(digits)) return false;
  var sum = 0;
  for (var i = 0; i < 15; i++) {
    var d = digits.codeUnitAt(14 - i) - 48;
    if (i.isOdd) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
  }
  return sum % 10 == 0;
}

class DeviceFields {
  String imei = '';
  String imei2 = '';
  String eid = '';
  String meid = '';
  String serial = '';
  String model = '';
}

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});
  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  bool _loading = true;
  bool _provisioned = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await Store.read(Keys.provisioned);
    if (mounted) {
      setState(() {
        _provisioned = p == '1';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_provisioned) {
      return DisplayPage(onReset: () => setState(() => _provisioned = false));
    }
    return SetupFlow(onDone: () => setState(() => _provisioned = true));
  }
}

class SetupFlow extends StatefulWidget {
  const SetupFlow({super.key, required this.onDone});
  final VoidCallback onDone;
  @override
  State<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends State<SetupFlow> {
  int _step = 0;
  final _fields = DeviceFields();
  String _passkey = '';
  String? _generatedRecovery;

  void _useFields(DeviceFields f) {
    setState(() {
      _fields.imei = f.imei;
      _fields.imei2 = f.imei2;
      _fields.eid = f.eid;
      _fields.meid = f.meid;
      _fields.serial = f.serial;
      _fields.model = f.model;
      _step = 1;
    });
  }

  void _onVerified() => setState(() => _step = 2);

  Future<void> _onPasskeySet(String pass) async {
    setState(() => _passkey = pass);
    await _commit();
  }

  Future<void> _commit() async {
    final passSalt = CryptoUtil.randomHex(16);
    final passHash = CryptoUtil.stretch(_passkey, passSalt);
    final recovery = CryptoUtil.recoveryCode();
    final recSalt = CryptoUtil.randomHex(16);
    final recHash = CryptoUtil.stretch(recovery, recSalt);

    await Store.write(Keys.imei, _fields.imei);
    await Store.write(Keys.imei2, _fields.imei2);
    await Store.write(Keys.eid, _fields.eid);
    await Store.write(Keys.meid, _fields.meid);
    await Store.write(Keys.serial, _fields.serial);
    await Store.write(Keys.model, _fields.model);
    await Store.write(Keys.passSalt, passSalt);
    await Store.write(Keys.passHash, passHash);
    await Store.write(Keys.recoverySalt, recSalt);
    await Store.write(Keys.recoveryHash, recHash);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await Store.write(Keys.sealedAtMs, nowMs.toString());
    await Store.write(Keys.editGraceUntilMs, (nowMs + _editGraceDuration.inMilliseconds).toString());
    await Store.write(Keys.provisioned, '1');

    if (mounted) setState(() => _generatedRecovery = recovery);
  }

  @override
  Widget build(BuildContext context) {
    if (_generatedRecovery != null) {
      return RecoveryCodePage(code: _generatedRecovery!, onAcknowledged: widget.onDone);
    }

    switch (_step) {
      case 0:
        return EntryStep(initial: _fields, onNext: _useFields);
      case 1:
        return VerifyStep(
          fields: _fields,
          onConfirmed: _onVerified,
          onBack: () => setState(() => _step = 0),
        );
      case 2:
        return PasskeyStep(onNext: _onPasskeySet, onBack: () => setState(() => _step = 1));
    }
    return const SizedBox.shrink();
  }
}

class EntryStep extends StatefulWidget {
  const EntryStep({super.key, required this.initial, required this.onNext});
  final DeviceFields initial;
  final void Function(DeviceFields) onNext;
  @override
  State<EntryStep> createState() => _EntryStepState();
}

class _EntryStepState extends State<EntryStep> {
  final _formKey = GlobalKey<FormState>();
  late final _imei = TextEditingController(text: widget.initial.imei);
  late final _imei2 = TextEditingController(text: widget.initial.imei2);
  late final _eid = TextEditingController(text: widget.initial.eid);
  late final _meid = TextEditingController(text: widget.initial.meid);
  late final _serial = TextEditingController(text: widget.initial.serial);
  late final _model = TextEditingController(text: widget.initial.model);

  @override
  void dispose() {
    for (final c in [_imei, _imei2, _eid, _meid, _serial, _model]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final f = DeviceFields()
      ..imei = _imei.text.trim()
      ..imei2 = _imei2.text.trim()
      ..eid = _eid.text.trim()
      ..meid = _meid.text.trim()
      ..serial = _serial.text.trim()
      ..model = _model.text.trim();
    widget.onNext(f);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Step 1 of 3: Enter device info'),
        automaticallyImplyLeading: false,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Read each value from this same phone\'s Settings → About, or by dialing *#06#. '
                'You will be asked to confirm the match in the next step. Once sealed, values cannot be edited.',
                style: TextStyle(fontSize: 14, color: Colors.black54),
              ),
            ),
            _digits(_imei, 'IMEI (required, 15 digits)', 15, required: true, luhn: true),
            _digits(_imei2, 'IMEI2 (optional, dual-SIM)', 15, luhn: true),
            _digits(_eid, 'EID (optional, up to 32 digits)', 32),
            _digits(_meid, 'MEID (optional, up to 14 chars)', 14, digitsOnly: false),
            TextFormField(controller: _serial, decoration: const InputDecoration(labelText: 'Serial number (optional)')),
            TextFormField(controller: _model, decoration: const InputDecoration(labelText: 'Model (optional)')),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submit,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Next: verify match'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _digits(TextEditingController c, String label, int max,
      {bool required = false, bool luhn = false, bool digitsOnly = true}) {
    return TextFormField(
      controller: c,
      decoration: InputDecoration(labelText: label),
      keyboardType: digitsOnly ? TextInputType.number : TextInputType.text,
      inputFormatters: [
        if (digitsOnly) FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(max),
      ],
      validator: (v) {
        final t = (v ?? '').trim();
        if (t.isEmpty) return required ? 'Required' : null;
        if (luhn && !luhn15(t)) return 'Not a valid 15-digit IMEI (Luhn check failed)';
        return null;
      },
    );
  }
}

class VerifyStep extends StatefulWidget {
  const VerifyStep({super.key, required this.fields, required this.onConfirmed, required this.onBack});
  final DeviceFields fields;
  final VoidCallback onConfirmed;
  final VoidCallback onBack;
  @override
  State<VerifyStep> createState() => _VerifyStepState();
}

class _VerifyStepState extends State<VerifyStep> {
  bool _attested = false;

  @override
  Widget build(BuildContext context) {
    final rows = <_Row>[
      _Row('IMEI', widget.fields.imei),
      if (widget.fields.imei2.isNotEmpty) _Row('IMEI2', widget.fields.imei2),
      if (widget.fields.eid.isNotEmpty) _Row('EID', widget.fields.eid),
      if (widget.fields.meid.isNotEmpty) _Row('MEID', widget.fields.meid),
      if (widget.fields.serial.isNotEmpty) _Row('Serial', widget.fields.serial),
      if (widget.fields.model.isNotEmpty) _Row('Model', widget.fields.model),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Step 2 of 3: Verify match')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.shade100,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.shade700),
            ),
            child: const Text(
              'On this same phone, dial *#06# (or open Settings → About) and confirm every value below matches what the device itself reports. Only confirm if every value is identical. Once sealed, no one can change these — even with the admin passkey.',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(height: 16),
          ...rows.map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 70, child: Text(r.label, style: const TextStyle(fontWeight: FontWeight.w600))),
                    Expanded(child: SelectableText(r.value, style: const TextStyle(fontFamily: 'monospace'))),
                  ],
                ),
              )),
          const Divider(height: 32),
          CheckboxListTile(
            value: _attested,
            onChanged: (v) => setState(() => _attested = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text(
              'I have visually compared every value above against this device\'s own *#06# / About output, and every value matches.',
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.onBack,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Back'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _attested ? widget.onConfirmed : null,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Confirm match'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Row {
  _Row(this.label, this.value);
  final String label;
  final String value;
}

class PasskeyStep extends StatefulWidget {
  const PasskeyStep({super.key, required this.onNext, required this.onBack});
  final void Function(String) onNext;
  final VoidCallback onBack;
  @override
  State<PasskeyStep> createState() => _PasskeyStepState();
}

class _PasskeyStepState extends State<PasskeyStep> {
  final _formKey = GlobalKey<FormState>();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    widget.onNext(_pass.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Step 3 of 3: Admin passkey')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Set a passkey that will be required to factory-reset this device\'s sealed info. '
              'A one-time recovery code will be shown next. The passkey CANNOT be used to edit values — only to wipe and re-provision.',
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Admin passkey (min 6 characters)'),
              validator: (v) => (v ?? '').length < 6 ? 'At least 6 characters' : null,
            ),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm passkey'),
              validator: (v) => v != _pass.text ? 'Does not match' : null,
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : widget.onBack,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Back'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(_saving ? 'Sealing…' : 'Seal device'),
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

class RecoveryCodePage extends StatelessWidget {
  const RecoveryCodePage({super.key, required this.code, required this.onAcknowledged});
  final String code;
  final VoidCallback onAcknowledged;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('One-time recovery code'), automaticallyImplyLeading: false),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'WRITE THIS DOWN OR PHOTOGRAPH IT NOW.\n\n'
              'This code is shown ONCE. If the admin passkey is ever lost, this code is the '
              'only way to factory-reset this device without wiping it through Android/iOS settings.',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade400),
              ),
              child: SelectableText(
                code,
                style: const TextStyle(fontSize: 22, fontFamily: 'monospace', letterSpacing: 1.4),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: onAcknowledged,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('I have saved this code', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DisplayPage extends StatefulWidget {
  const DisplayPage({super.key, required this.onReset});
  final VoidCallback onReset;
  @override
  State<DisplayPage> createState() => _DisplayPageState();
}

class _DisplayPageState extends State<DisplayPage> {
  Map<String, String> _values = {};
  bool _loading = true;
  DateTime? _sealedAt;

  @override
  void initState() {
    super.initState();
    _bumpBrightness();
    _load();
  }

  @override
  void dispose() {
    _restoreBrightness();
    super.dispose();
  }

  Future<void> _bumpBrightness() async {
    try {
      await ScreenBrightness().setScreenBrightness(1.0);
    } catch (_) {}
  }

  Future<void> _restoreBrightness() async {
    try {
      await ScreenBrightness().resetScreenBrightness();
    } catch (_) {}
  }

  Future<void> _load() async {
    final values = <String, String>{};
    for (final k in [Keys.imei, Keys.imei2, Keys.eid, Keys.meid, Keys.serial, Keys.model]) {
      final v = await Store.read(k) ?? '';
      if (v.isNotEmpty) values[k] = v;
    }
    final ts = await Store.read(Keys.sealedAtMs);
    DateTime? sealed;
    if (ts != null) {
      final ms = int.tryParse(ts);
      if (ms != null) sealed = DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (mounted) {
      setState(() {
        _values = values;
        _sealedAt = sealed;
        _loading = false;
      });
    }
  }

  Future<void> _attemptAdmin() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const PasskeyDialog(),
    );
    if (ok == true && mounted) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AdminPage(onReset: widget.onReset, onChanged: _load),
      ));
      _load();
    }
  }

  Future<void> _showVerifyInstructions() async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Verify match'),
        content: const Text(
          'On this same phone, dial *#06# or open Settings → About. '
          'Compare every value shown on this screen against what the device itself displays. '
          'If anything differs, contact IT — do not accept this barcode at checkout.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final rows = <_RowSpec>[
      if (_values[Keys.eid] != null) _RowSpec('EID', _values[Keys.eid]!),
      if (_values[Keys.imei] != null) _RowSpec('IMEI', _values[Keys.imei]!),
      if (_values[Keys.imei2] != null) _RowSpec('IMEI2', _values[Keys.imei2]!),
      if (_values[Keys.meid] != null) _RowSpec('MEID', _values[Keys.meid]!),
      if (_values[Keys.serial] != null) _RowSpec('Serial', _values[Keys.serial]!),
    ];

    final sealedText = _sealedAt == null
        ? 'Sealed: unknown'
        : 'Sealed: ${DateFormat('yyyy-MM-dd HH:mm').format(_sealedAt!)}';

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                onLongPress: _attemptAdmin,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Device Info',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.black),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              if (_values[Keys.model] != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _values[Keys.model]!,
                    style: const TextStyle(fontSize: 14, color: Colors.black54),
                    textAlign: TextAlign.center,
                  ),
                ),
              ...rows.map(_renderRow),
              const SizedBox(height: 16),
              Center(
                child: TextButton.icon(
                  onPressed: _showVerifyInstructions,
                  icon: const Icon(Icons.verified_user_outlined, size: 18),
                  label: const Text('Verify against *#06#'),
                ),
              ),
              Center(
                child: Text(
                  sealedText,
                  style: const TextStyle(fontSize: 11, color: Colors.black45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _renderRow(_RowSpec r) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${r.label}  ${r.value}',
            style: const TextStyle(fontSize: 15, color: Colors.black87, fontWeight: FontWeight.w500),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 72,
            child: BarcodeWidget(
              barcode: Barcode.code128(escapes: false),
              data: r.value,
              drawText: false,
              color: Colors.black,
              backgroundColor: Colors.white,
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}

class _RowSpec {
  _RowSpec(this.label, this.value);
  final String label;
  final String value;
}

class PasskeyDialog extends StatefulWidget {
  const PasskeyDialog({super.key});
  @override
  State<PasskeyDialog> createState() => _PasskeyDialogState();
}

class _PasskeyDialogState extends State<PasskeyDialog> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _busy = false;
  int _lockoutSeconds = 0;
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    _checkLockout();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _lockTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkLockout() async {
    final raw = await Store.read(Keys.lockoutUntilMs) ?? '0';
    final ms = int.tryParse(raw) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (ms > now) {
      setState(() => _lockoutSeconds = ((ms - now) / 1000).ceil());
      _lockTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        final remaining = ((ms - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
        if (remaining <= 0) {
          t.cancel();
          if (mounted) setState(() => _lockoutSeconds = 0);
        } else if (mounted) {
          setState(() => _lockoutSeconds = remaining);
        }
      });
    }
  }

  Future<void> _submit() async {
    if (_lockoutSeconds > 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final passSalt = await Store.read(Keys.passSalt) ?? '';
      final passExpected = await Store.read(Keys.passHash) ?? '';
      final passActual = CryptoUtil.stretch(_ctrl.text.trim(), passSalt);
      if (passActual == passExpected && passExpected.isNotEmpty) {
        await Store.write(Keys.failedCount, '0');
        await Store.write(Keys.lockoutUntilMs, '0');
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      final recSalt = await Store.read(Keys.recoverySalt) ?? '';
      final recExpected = await Store.read(Keys.recoveryHash) ?? '';
      final recActual = CryptoUtil.stretch(_ctrl.text.trim().toUpperCase(), recSalt);
      if (recActual == recExpected && recExpected.isNotEmpty) {
        await Store.write(Keys.failedCount, '0');
        await Store.write(Keys.lockoutUntilMs, '0');
        if (mounted) Navigator.of(context).pop(true);
        return;
      }

      final fails = (int.tryParse(await Store.read(Keys.failedCount) ?? '0') ?? 0) + 1;
      await Store.write(Keys.failedCount, fails.toString());
      if (fails >= 5) {
        final shift = (fails - 5).clamp(0, 6);
        final delay = Duration(seconds: 30 * (1 << shift));
        final until = DateTime.now().add(delay).millisecondsSinceEpoch;
        await Store.write(Keys.lockoutUntilMs, until.toString());
        _checkLockout();
      }
      if (mounted) setState(() => _error = 'Incorrect passkey');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Admin'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _ctrl,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(labelText: 'Passkey or recovery code', errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
          if (_lockoutSeconds > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Too many attempts. Try again in ${_lockoutSeconds}s.',
                style: const TextStyle(color: Colors.red),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          onPressed: (_busy || _lockoutSeconds > 0) ? null : _submit,
          child: Text(_busy ? '…' : 'Unlock'),
        ),
      ],
    );
  }
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.onReset, required this.onChanged});
  final VoidCallback onReset;
  final VoidCallback onChanged;
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  int _graceRemainingSec = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadGrace();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadGrace() async {
    final raw = await Store.read(Keys.editGraceUntilMs) ?? '0';
    final ms = int.tryParse(raw) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (ms <= now) {
      if (mounted) setState(() => _graceRemainingSec = 0);
      return;
    }
    setState(() => _graceRemainingSec = ((ms - now) / 1000).ceil());
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      final remaining = ((ms - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
      if (remaining <= 0) {
        t.cancel();
        if (mounted) setState(() => _graceRemainingSec = 0);
      } else if (mounted) {
        setState(() => _graceRemainingSec = remaining);
      }
    });
  }

  Future<void> _factoryReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Wipe all data?'),
        content: const Text(
          'This will erase the stored device info, admin passkey, and recovery code. Cannot be undone. The next launch will start a fresh provisioning.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Wipe'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await Store.wipe();
      widget.onReset();
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _openEdit() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EditPage()));
    widget.onChanged();
    _loadGrace();
  }

  String _formatRemaining(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final graceActive = _graceRemainingSec > 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: ListView(
        children: [
          if (graceActive)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade700),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Typo-fix window: ${_formatRemaining(_graceRemainingSec)} remaining',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'You can edit stored values within this window to correct provisioning typos. After the window expires, values are permanently locked — the only change path becomes factory reset.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Stored device-info values are sealed and cannot be edited. Admin actions are limited to changing the passkey or factory-resetting and re-provisioning from scratch.',
                style: TextStyle(fontSize: 13, color: Colors.black54, fontStyle: FontStyle.italic),
              ),
            ),
          if (graceActive)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit values (typo fix)'),
              subtitle: Text('Window closes in ${_formatRemaining(_graceRemainingSec)}'),
              onTap: _openEdit,
            ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('Change admin passkey'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChangePassPage())),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('Factory reset', style: TextStyle(color: Colors.red)),
            subtitle: const Text('Wipe everything and re-provision'),
            onTap: _factoryReset,
          ),
        ],
      ),
    );
  }
}

class EditPage extends StatefulWidget {
  const EditPage({super.key});
  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  final _formKey = GlobalKey<FormState>();
  final _imei = TextEditingController();
  final _imei2 = TextEditingController();
  final _eid = TextEditingController();
  final _meid = TextEditingController();
  final _serial = TextEditingController();
  final _model = TextEditingController();
  bool _loaded = false;
  bool _windowClosed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final graceRaw = await Store.read(Keys.editGraceUntilMs) ?? '0';
    final graceMs = int.tryParse(graceRaw) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch >= graceMs) {
      if (mounted) setState(() => _windowClosed = true);
      return;
    }
    _imei.text = await Store.read(Keys.imei) ?? '';
    _imei2.text = await Store.read(Keys.imei2) ?? '';
    _eid.text = await Store.read(Keys.eid) ?? '';
    _meid.text = await Store.read(Keys.meid) ?? '';
    _serial.text = await Store.read(Keys.serial) ?? '';
    _model.text = await Store.read(Keys.model) ?? '';
    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    for (final c in [_imei, _imei2, _eid, _meid, _serial, _model]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final graceRaw = await Store.read(Keys.editGraceUntilMs) ?? '0';
    final graceMs = int.tryParse(graceRaw) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch >= graceMs) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Edit window closed while you were typing. Values are now permanently sealed.')),
        );
        Navigator.of(context).pop();
      }
      return;
    }

    final fields = DeviceFields()
      ..imei = _imei.text.trim()
      ..imei2 = _imei2.text.trim()
      ..eid = _eid.text.trim()
      ..meid = _meid.text.trim()
      ..serial = _serial.text.trim()
      ..model = _model.text.trim();

    if (!mounted) return;
    final confirmed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Verify corrected values'), automaticallyImplyLeading: false),
          body: VerifyStep(
            fields: fields,
            onConfirmed: () => Navigator.of(context).pop(true),
            onBack: () => Navigator.of(context).pop(false),
          ),
        ),
      ),
    );
    if (confirmed != true) return;

    await Store.write(Keys.imei, fields.imei);
    await Store.write(Keys.imei2, fields.imei2);
    await Store.write(Keys.eid, fields.eid);
    await Store.write(Keys.meid, fields.meid);
    await Store.write(Keys.serial, fields.serial);
    await Store.write(Keys.model, fields.model);

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_windowClosed) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit window closed')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text(
              'The typo-fix window has closed. Stored values are now permanently sealed. To make a change, use Factory reset and re-provision the device.',
              style: TextStyle(fontSize: 15),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('Edit values (typo fix)')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade700),
              ),
              child: const Text(
                'Only use this to correct a provisioning typo. Saving will re-run the verify step and require you to re-attest the new values against *#06#.',
                style: TextStyle(fontSize: 13),
              ),
            ),
            TextFormField(
              controller: _imei,
              decoration: const InputDecoration(labelText: 'IMEI'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(15)],
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return 'Required';
                if (!luhn15(t)) return 'Not a valid 15-digit IMEI';
                return null;
              },
            ),
            TextFormField(
              controller: _imei2,
              decoration: const InputDecoration(labelText: 'IMEI2'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(15)],
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return null;
                if (!luhn15(t)) return 'Not a valid 15-digit IMEI';
                return null;
              },
            ),
            TextFormField(
              controller: _eid,
              decoration: const InputDecoration(labelText: 'EID'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(32)],
            ),
            TextFormField(
              controller: _meid,
              decoration: const InputDecoration(labelText: 'MEID'),
              inputFormatters: [LengthLimitingTextInputFormatter(14)],
            ),
            TextFormField(controller: _serial, decoration: const InputDecoration(labelText: 'Serial')),
            TextFormField(controller: _model, decoration: const InputDecoration(labelText: 'Model')),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _save,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Save (will re-verify)'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChangePassPage extends StatefulWidget {
  const ChangePassPage({super.key});
  @override
  State<ChangePassPage> createState() => _ChangePassPageState();
}

class _ChangePassPageState extends State<ChangePassPage> {
  final _formKey = GlobalKey<FormState>();
  final _new = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final salt = CryptoUtil.randomHex(16);
    final hash = CryptoUtil.stretch(_new.text.trim(), salt);
    await Store.write(Keys.passSalt, salt);
    await Store.write(Keys.passHash, hash);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change passkey')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _new,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New passkey (min 6 characters)'),
              validator: (v) => (v ?? '').length < 6 ? 'At least 6 characters' : null,
            ),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm'),
              validator: (v) => v != _new.text ? 'Does not match' : null,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _save,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
