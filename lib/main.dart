import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const RtmUvApp());
}

class RtmUvApp extends StatelessWidget {
  const RtmUvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RTM UV Kalibrasi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF2F81F7),
          secondary: Color(0xFF8B5CF6),
          surface: Color(0xFF161B22),
          error: Color(0xFFDA3633),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF161B22),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF30363D)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0D1117),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF30363D)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF30363D)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF2F81F7)),
          ),
        ),
      ),
      home: const ControllerScreen(),
    );
  }
}

class LogEntry {
  final String time;
  final String tag;
  final String message;

  LogEntry(this.time, this.tag, this.message);
}

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  static const _btMethod = MethodChannel('com.maniakprint.rtm_uv_kalibrasi/bt');
  static const _btEvents =
      EventChannel('com.maniakprint.rtm_uv_kalibrasi/bt_rx');
  static const int _stepsPerUnit = 562;

  StreamSubscription<dynamic>? _rxSub;
  String _rxBuffer = '';
  Timer? _rxFlushTimer;
  Timer? _eepromTimer;

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isSimulation = false;
  String _connectedName = '';

  double _simEeprom = 16.90;
  double? _currentEeprom;
  String _eepromUpdated = 'Belum dibaca';
  String? _eepromFeedback;
  Color _eepromFeedbackColor = const Color(0xFF79C0FF);

  bool _holdMode = true;
  String? _activeJogCmd;

  final _eepromCtrl = TextEditingController(text: '16.90');
  final _calcTargetCtrl = TextEditingController(text: '100');
  final _calcActualCtrl = TextEditingController();
  final _unitsCtrl = TextEditingController(text: '1');
  final _rawCtrl = TextEditingController();
  final _logScrollCtrl = ScrollController();

  final List<LogEntry> _logs = [];

  @override
  void initState() {
    super.initState();
    _rxSub = _btEvents.receiveBroadcastStream().listen(
      _onBtEvent,
      onError: (Object err) => _addLog('ERR', 'Stream error: $err'),
    );
    _addLog('SYS',
        'Siap. Pair Bluetooth "RTM UV" di Pengaturan Android, lalu ketuk Hubungkan.');
  }

  @override
  void dispose() {
    _rxSub?.cancel();
    _rxFlushTimer?.cancel();
    _eepromTimer?.cancel();
    _eepromCtrl.dispose();
    _calcTargetCtrl.dispose();
    _calcActualCtrl.dispose();
    _unitsCtrl.dispose();
    _rawCtrl.dispose();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  String _nowTime() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  double? _parseLocaleDouble(String raw) {
    final normalized = raw.trim().replaceAll(',', '.');
    return double.tryParse(normalized);
  }

  String _formatFloat(double val) {
    final fixed4 = val.toStringAsFixed(4);
    final trimmed = fixed4.replaceFirst(RegExp(r'0+$'), '');
    final parts = trimmed.split('.');
    if (parts.length == 1) return '${parts[0]}.00';
    if (parts[1].length < 2) return '${parts[0]}.${parts[1].padRight(2, '0')}';
    return trimmed;
  }

  void _addLog(String tag, String message) {
    if (!mounted) return;
    setState(() {
      _logs.add(LogEntry(_nowTime(), tag, message));
      if (_logs.length > 200) {
        _logs.removeAt(0);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollCtrl.hasClients) {
        _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _setFeedback(String msg, Color color) {
    if (!mounted) return;
    setState(() {
      _eepromFeedback = msg;
      _eepromFeedbackColor = color;
    });
  }

  void _onBtEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'] as String? ?? '';
    final payload = event['payload'] as String? ?? '';

    if (type == 'disconnected') {
      _eepromTimer?.cancel();
      if (mounted) {
        setState(() {
          _isConnected = false;
          _connectedName = '';
          _activeJogCmd = null;
        });
      }
      _addLog('SYS', 'Koneksi Bluetooth terputus.');
      return;
    }

    if (type == 'data' && payload.isNotEmpty) {
      _rxBuffer += payload;
      _rxFlushTimer?.cancel();

      final lines = _rxBuffer.split(RegExp(r'\r?\n'));
      _rxBuffer = lines.removeLast();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) _handleIncomingLine(trimmed);
      }

      if (_rxBuffer.trim().isNotEmpty) {
        _rxFlushTimer = Timer(const Duration(milliseconds: 250), () {
          final leftover = _rxBuffer.trim();
          _rxBuffer = '';
          if (leftover.isNotEmpty) _handleIncomingLine(leftover);
        });
      }
    }
  }

  void _handleIncomingLine(String line) {
    _addLog('RX', line);

    final match = RegExp(
      r'(?:Value|Berhasil)\s+tersimpan:\s*([-+]?\d*\.?\d+)',
      caseSensitive: false,
    ).firstMatch(line);

    if (match != null) {
      _eepromTimer?.cancel();
      final val = double.tryParse(match.group(1) ?? '');
      if (val != null) {
        final isWrite = line.toLowerCase().contains('berhasil');
        setState(() {
          _currentEeprom = val;
          _eepromCtrl.text = _formatFloat(val);
          _eepromUpdated =
              '${isWrite ? 'Berhasil disimpan' : 'Terbaca dari EEPROM'} — ${_nowTime()}';
        });
        _setFeedback(
          isWrite
              ? 'Tersimpan di EEPROM: ${_formatFloat(val)}'
              : 'Nilai EEPROM terbaca: ${_formatFloat(val)}',
          const Color(0xFF56D364),
        );
      }
      return;
    }

    if (RegExp(r'(?:Value|Berhasil)\s+tersimpan:\s*nan', caseSensitive: false)
        .hasMatch(line)) {
      _eepromTimer?.cancel();
      setState(() {
        _currentEeprom = null;
        _eepromUpdated = 'EEPROM kosong (NaN)';
      });
      _setFeedback(
        'EEPROM masih kosong (NaN). Masukkan nilai (misal 16.90) lalu ketuk Simpan.',
        const Color(0xFFF0C674),
      );
    }
  }

  Future<void> _showDevicePicker() async {
    try {
      final granted =
          await _btMethod.invokeMethod<bool>('requestPermissions') ?? false;
      if (!granted) {
        _addLog('ERR', 'Izin Bluetooth ditolak.');
        _setFeedback(
          'Izin Bluetooth wajib diberikan agar aplikasi bisa terhubung ke RTM UV.',
          const Color(0xFFFF7B72),
        );
        return;
      }

      final rawDevices =
          await _btMethod.invokeMethod<List<dynamic>>('getPairedDevices') ?? [];
      final devices = rawDevices
          .map((e) => Map<String, String>.from(e as Map))
          .toList();

      if (!mounted) return;

      if (devices.isEmpty) {
        _addLog('ERR', 'Tidak ada perangkat Bluetooth ter-pair.');
        _setFeedback(
          'Belum ada perangkat ter-pair. Pair "RTM UV" dulu di Pengaturan Bluetooth HP.',
          const Color(0xFFF0C674),
        );
        return;
      }

      final selected = await showModalBottomSheet<Map<String, String>>(
        context: context,
        backgroundColor: const Color(0xFF161B22),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.bluetooth, color: Color(0xFF58A6FF)),
                    SizedBox(width: 8),
                    Text(
                      'Pilih Perangkat Bluetooth (RTM UV)',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              const Divider(color: Color(0xFF30363D)),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: devices.length,
                  itemBuilder: (_, i) {
                    final dev = devices[i];
                    final name = dev['name'] ?? 'Unknown';
                    final addr = dev['address'] ?? '';
                    final isRtm = name.toUpperCase().contains('RTM');
                    return ListTile(
                      leading: Icon(
                        Icons.bluetooth_connected,
                        color: isRtm
                            ? const Color(0xFF56D364)
                            : const Color(0xFF8B949E),
                      ),
                      title: Text(
                        name,
                        style: TextStyle(
                          fontWeight:
                              isRtm ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        addr,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12),
                      ),
                      onTap: () => Navigator.pop(ctx, dev),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );

      if (selected != null) {
        await _connectToDevice(
            selected['name'] ?? 'RTM UV', selected['address'] ?? '');
      }
    } on PlatformException catch (e) {
      _addLog('ERR', e.message ?? 'Gagal membaca daftar Bluetooth');
      _setFeedback(
          e.message ?? 'Gagal membaca daftar Bluetooth', const Color(0xFFFF7B72));
    }
  }

  Future<void> _connectToDevice(String name, String address) async {
    setState(() {
      _isConnecting = true;
      _isSimulation = false;
    });
    _addLog('SYS', 'Menghubungkan ke $name ($address)...');
    _setFeedback('Menghubungkan ke $name...', const Color(0xFF79C0FF));

    try {
      await _btMethod.invokeMethod('connect', {'address': address});
      if (!mounted) return;
      setState(() {
        _isConnected = true;
        _isConnecting = false;
        _connectedName = name;
      });
      _addLog('SYS', 'Terhubung ke $name. Membaca EEPROM...');
      Future.delayed(const Duration(milliseconds: 300), () {
        _sendCommand('t');
        Future.delayed(const Duration(milliseconds: 300), _requestReadEeprom);
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnected = false;
        _isConnecting = false;
      });
      _addLog('ERR', 'Gagal terhubung: ${e.message}');
      _setFeedback(
          'Gagal terhubung ke $name: ${e.message}', const Color(0xFFFF7B72));
    }
  }

  Future<void> _disconnect() async {
    await _btMethod.invokeMethod('disconnect');
    if (!mounted) return;
    setState(() {
      _isConnected = false;
      _connectedName = '';
      _activeJogCmd = null;
    });
    _addLog('SYS', 'Koneksi diputus.');
  }

  Future<bool> _sendCommand(String cmd) async {
    final clean = cmd.trim();
    if (clean.isEmpty) return false;

    if (_isSimulation) {
      _addLog('TX', clean);
      _simulateResponse(clean);
      return true;
    }

    if (!_isConnected) {
      _addLog('ERR', 'Belum terhubung. Perintah "$clean" tidak dikirim.');
      return false;
    }

    try {
      await _btMethod.invokeMethod('write', {'data': '$clean\n'});
      _addLog('TX', clean);
      return true;
    } on PlatformException catch (e) {
      _addLog('ERR', 'Gagal kirim "$clean": ${e.message}');
      return false;
    }
  }

  void _simulateResponse(String cmd) {
    Future.delayed(const Duration(milliseconds: 80), () {
      if (!mounted) return;
      if (cmd == 't') {
        _handleIncomingLine('ON');
      } else if (cmd.contains('%')) {
        final idx = cmd.indexOf('%');
        final val = double.tryParse(cmd.substring(0, idx));
        if (val != null && val > 0) {
          _simEeprom = val;
          _handleIncomingLine('Berhasil tersimpan: ${_formatFloat(_simEeprom)}');
        } else {
          _handleIncomingLine('Value tersimpan: ${_formatFloat(_simEeprom)}');
        }
      } else if (cmd.endsWith('!')) {
        final n = int.tryParse(cmd.substring(0, cmd.length - 1)) ?? 0;
        _addLog('SYS', '[SIM] Maju $n satuan (${n * _stepsPerUnit} step)');
      } else if (cmd.endsWith('?')) {
        final n = int.tryParse(cmd.substring(0, cmd.length - 1)) ?? 0;
        _addLog('SYS', '[SIM] Mundur $n satuan (${n * _stepsPerUnit} step)');
      } else if (cmd == 'O') {
        _addLog('SYS', '[SIM] Motor berhenti & posisi di-reset.');
      } else {
        _addLog('SYS', '[SIM] Perintah "$cmd" dieksekusi.');
      }
    });
  }

  Future<void> _requestReadEeprom() async {
    if (!_isConnected && !_isSimulation) {
      _setFeedback(
        'Belum terhubung. Ketuk "Hubungkan" atau "Simulasi" dulu.',
        const Color(0xFFFF7B72),
      );
      return;
    }
    _setFeedback('Membaca EEPROM (mengirim 0%)...', const Color(0xFF79C0FF));
    final ok = await _sendCommand('0%');
    if (!ok) return;

    _eepromTimer?.cancel();
    _eepromTimer = Timer(const Duration(milliseconds: 2500), () {
      _setFeedback(
        'Tidak ada balasan dari ESP32. Pastikan mesin dalam mode Standby (bukan mode Roll/Cetak).',
        const Color(0xFFF0C674),
      );
    });
  }

  Future<void> _requestWriteEeprom() async {
    if (!_isConnected && !_isSimulation) {
      _setFeedback(
        'Belum terhubung. Ketuk "Hubungkan" atau "Simulasi" dulu.',
        const Color(0xFFFF7B72),
      );
      return;
    }
    final val = _parseLocaleDouble(_eepromCtrl.text);
    if (val == null || val <= 0) {
      _setFeedback(
        'Nilai EEPROM harus berupa angka positif (> 0), misal 16.90.',
        const Color(0xFFFF7B72),
      );
      return;
    }
    final formatted = _formatFloat(val);
    _setFeedback(
      'Menyimpan $formatted ke EEPROM (mengirim $formatted%)...',
      const Color(0xFF79C0FF),
    );
    final ok = await _sendCommand('$formatted%');
    if (!ok) return;

    _eepromTimer?.cancel();
    _eepromTimer = Timer(const Duration(milliseconds: 2500), () {
      _setFeedback(
        'ESP32 tidak membalas. Jika mesin sedang di mode Roll/Cetak (BT_roll tidak mendukung %), tekan Restart (R) dulu.',
        const Color(0xFFF0C674),
      );
    });
  }

  void _nudgeEeprom(double delta) {
    final current = _parseLocaleDouble(_eepromCtrl.text) ?? 0;
    final next = (current + delta).clamp(0.01, 9999.0);
    setState(() {
      _eepromCtrl.text = _formatFloat(next);
    });
  }

  double? _calcSuggestion() {
    final base = _currentEeprom ?? _parseLocaleDouble(_eepromCtrl.text);
    final target = _parseLocaleDouble(_calcTargetCtrl.text);
    final actual = _parseLocaleDouble(_calcActualCtrl.text);
    if (base != null &&
        base > 0 &&
        target != null &&
        target > 0 &&
        actual != null &&
        actual > 0) {
      return base * (actual / target);
    }
    return null;
  }

  int _getMoveUnits() {
    final parsed = int.tryParse(_unitsCtrl.text.trim()) ?? 1;
    return parsed < 1 ? 1 : parsed;
  }

  Future<void> _confirmRestart() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Restart ESP32?'),
        content: const Text(
          'Kirim perintah Restart (R) ke modul? Koneksi Bluetooth akan terputus sementara.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFDA3633)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restart (R)'),
          ),
        ],
      ),
    );
    if (yes == true) {
      _sendCommand('R');
    }
  }

  Widget _buildJogButton(String label, String cmd) {
    final isActive = _activeJogCmd == cmd;
    return Expanded(
      child: Listener(
        onPointerDown: (_) {
          if (_holdMode) {
            if (_activeJogCmd != cmd) {
              setState(() => _activeJogCmd = cmd);
              _sendCommand(cmd);
            }
          } else {
            _sendCommand(cmd);
          }
        },
        onPointerUp: (_) {
          if (_holdMode && _activeJogCmd == cmd) {
            setState(() => _activeJogCmd = null);
            _sendCommand('O');
          }
        },
        onPointerCancel: (_) {
          if (_holdMode && _activeJogCmd == cmd) {
            setState(() => _activeJogCmd = null);
            _sendCommand('O');
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF2563EB) : const Color(0xFF1F2937),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF3B82F6)),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: isActive ? Colors.white : const Color(0xFF93C5FD),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final units = _getMoveUnits();
    final suggestion = _calcSuggestion();

    final statusColor = _isConnected
        ? const Color(0xFF2EA043)
        : _isSimulation
            ? const Color(0xFFD29922)
            : const Color(0xFF8B949E);
    final statusLabel = _isConnected
        ? 'Terhubung ($_connectedName)'
        : _isConnecting
            ? 'Menghubungkan...'
            : _isSimulation
                ? 'Mode Simulasi'
                : 'Terputus';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('RTM UV Controller',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text('Bluetooth Classic SPP — Android',
                style: TextStyle(fontSize: 11, color: Color(0xFF8B949E))),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFDA3633),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: () => _sendCommand('O'),
              child: const Text('STOP (O)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Connection Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          statusLabel,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _isConnected
                            ? null
                            : () {
                                setState(() => _isSimulation = !_isSimulation);
                                if (_isSimulation) {
                                  _addLog('SYS', 'Mode Simulasi aktif.');
                                  _requestReadEeprom();
                                } else {
                                  _addLog('SYS', 'Mode Simulasi nonaktif.');
                                }
                              },
                        child: Text(_isSimulation ? 'Keluar Sim' : 'Simulasi'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isConnected
                                ? const Color(0xFF30363D)
                                : const Color(0xFF2F81F7),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: _isConnecting
                              ? null
                              : (_isConnected ? _disconnect : _showDevicePicker),
                          icon: Icon(_isConnected
                              ? Icons.bluetooth_disabled
                              : Icons.bluetooth),
                          label: Text(_isConnected
                              ? 'Putuskan Bluetooth'
                              : 'Hubungkan Bluetooth (RTM UV)'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () => _sendCommand('t'),
                        child: const Text('Ping (t)'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // EEPROM Calibration Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Kalibrasi Faktor EEPROM (%)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090D12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF30363D)),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'NILAI TERSIMPAN DI EEPROM',
                          style:
                              TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _currentEeprom != null
                              ? _formatFloat(_currentEeprom!)
                              : '--.--',
                          style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            fontFamily: 'monospace',
                            color: Color(0xFF58A6FF),
                          ),
                        ),
                        Text(
                          _eepromUpdated,
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF8B949E)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _nudgeBtn('-0.10', -0.10),
                      const SizedBox(width: 4),
                      _nudgeBtn('-0.01', -0.01),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: _eepromCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _nudgeBtn('+0.01', 0.01),
                      const SizedBox(width: 4),
                      _nudgeBtn('+0.10', 0.10),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _requestReadEeprom,
                          child: const Text('Baca (0%)'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2F81F7),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: _requestWriteEeprom,
                          child: const Text('Simpan EEPROM (%)'),
                        ),
                      ),
                    ],
                  ),
                  if (_eepromFeedback != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _eepromFeedbackColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: _eepromFeedbackColor.withValues(alpha: 0.5)),
                      ),
                      child: Text(
                        _eepromFeedback!,
                        style: TextStyle(
                            fontSize: 12, color: _eepromFeedbackColor),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text(
                      'Kalkulator Kalibrasi Jarak (Opsional)',
                      style:
                          TextStyle(fontSize: 13, color: Color(0xFF79C0FF)),
                    ),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _calcTargetCtrl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'Target (mm)'),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _calcActualCtrl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'Hasil Ukur (mm)'),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Saran: ${suggestion != null ? _formatFloat(suggestion) : '-'}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF58A6FF),
                            ),
                          ),
                          ElevatedButton(
                            onPressed: suggestion == null
                                ? null
                                : () {
                                    setState(() {
                                      _eepromCtrl.text =
                                          _formatFloat(suggestion);
                                    });
                                    _setFeedback(
                                      'Saran ${_formatFloat(suggestion)} dimasukkan. Ketuk Simpan EEPROM (%) untuk menulis.',
                                      const Color(0xFF79C0FF),
                                    );
                                  },
                            child: const Text('Pakai Nilai'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Movement Control Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Kontrol Maju & Mundur',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2F81F7).withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${units * _stepsPerUnit} step',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: Color(0xFF79C0FF),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      SizedBox(
                        width: 78,
                        child: TextField(
                          controller: _unitsCtrl,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [1, 5, 10, 20, 50].map((v) {
                            return ActionChip(
                              label: Text('$v'),
                              onPressed: () => setState(() {
                                _unitsCtrl.text = '$v';
                              }),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0EA5E9),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: () => _sendCommand('$units!'),
                          child: Text('▲ MAJU ($units!)',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF8B5CF6),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: () => _sendCommand('$units?'),
                          child: Text('▼ MUNDUR ($units?)',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24, color: Color(0xFF30363D)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Jog Manual',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      Row(
                        children: [
                          const Text('Tahan jalan',
                              style: TextStyle(
                                  fontSize: 12, color: Color(0xFF8B949E))),
                          Switch(
                            value: _holdMode,
                            onChanged: (v) => setState(() => _holdMode = v),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      _buildJogButton('▲ Jog Maju (U)', 'U'),
                      const SizedBox(width: 8),
                      _buildJogButton('▼ Jog Mundur (M)', 'M'),
                    ],
                  ),
                  const Divider(height: 24, color: Color(0xFF30363D)),
                  const Text('Langkah Cepat (±9000 Step) & Sistem',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 3.1,
                    children: [
                      OutlinedButton(
                        onPressed: () => _sendCommand('C'),
                        child: const Text('Maju Cepat (C)'),
                      ),
                      OutlinedButton(
                        onPressed: () => _sendCommand('I'),
                        child: const Text('Mundur Cepat (I)'),
                      ),
                      OutlinedButton(
                        onPressed: () => _sendCommand('OPEN'),
                        child: const Text('Ulangi (OPEN)'),
                      ),
                      OutlinedButton(
                        onPressed: () => _sendCommand('LOCK'),
                        child: const Text('Ulangi (LOCK)'),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFDA3633),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => _sendCommand('O'),
                        child: const Text('STOP & RESET (O)'),
                      ),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFF0C674),
                          side: const BorderSide(color: Color(0xFFD29922)),
                        ),
                        onPressed: _confirmRestart,
                        child: const Text('Restart ESP32 (R)'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Serial Monitor Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Monitor Serial Bluetooth',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _logs.clear()),
                        child: const Text('Bersihkan'),
                      ),
                    ],
                  ),
                  Container(
                    height: 180,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090D12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF30363D)),
                    ),
                    child: ListView.builder(
                      controller: _logScrollCtrl,
                      itemCount: _logs.length,
                      itemBuilder: (_, i) {
                        final item = _logs[i];
                        final tagColor = switch (item.tag) {
                          'TX' => const Color(0xFF58A6FF),
                          'RX' => const Color(0xFF3FB950),
                          'ERR' => const Color(0xFFF85149),
                          _ => const Color(0xFFD29922),
                        };
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: RichText(
                            text: TextSpan(
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                color: Color(0xFFE6EDF3),
                              ),
                              children: [
                                TextSpan(
                                  text: '${item.time} ',
                                  style:
                                      const TextStyle(color: Color(0xFF6E7681)),
                                ),
                                TextSpan(
                                  text: item.tag.padRight(4),
                                  style: TextStyle(
                                      color: tagColor,
                                      fontWeight: FontWeight.bold),
                                ),
                                TextSpan(text: item.message),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _rawCtrl,
                          decoration: const InputDecoration(
                            hintText: 'Perintah manual (16.90%, 5!, O, t)...',
                          ),
                          onSubmitted: (val) {
                            if (val.trim().isNotEmpty) {
                              _sendCommand(val);
                              _rawCtrl.clear();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2F81F7),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                        ),
                        onPressed: () {
                          final val = _rawCtrl.text.trim();
                          if (val.isNotEmpty) {
                            _sendCommand(val);
                            _rawCtrl.clear();
                          }
                        },
                        child: const Text('Kirim'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _nudgeBtn(String label, double delta) {
    return SizedBox(
      width: 54,
      height: 44,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          side: const BorderSide(color: Color(0xFF30363D)),
        ),
        onPressed: () => _nudgeEeprom(delta),
        child: Text(
          label,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
      ),
    );
  }
}
