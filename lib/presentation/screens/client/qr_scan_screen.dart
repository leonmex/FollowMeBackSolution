import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../../../domain/repositories/tracking_repository.dart';
import 'client_status_screen.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _isProcessing = false;
  String? _scannedUuid;

  late final MobileScannerController _scannerController;

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController();
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing || capture.barcodes.isEmpty) return;
    final uuid = capture.barcodes.first.rawValue;
    if (uuid != null && uuid != _scannedUuid) {
      setState(() {
        _scannedUuid = uuid;
      });
    }
  }

  Future<void> _connectToHost() async {
    if (_scannedUuid == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    final repo = context.read<TrackingRepository>();
    final navigator = Navigator.of(context);
    try {
      await repo.clientProcessHostOffer(_scannedUuid!);

      await _scannerController.stop();
      if (!mounted) return;

      navigator.pushReplacement(
        MaterialPageRoute(builder: (context) => const ClientStatusScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _scannedUuid = null; // Allow retry
      });
      debugPrint("Error processing offer: $e");
      final msg = e.toString().contains('Internet is requiered')
          ? e.toString().replaceAll('Exception: ', '')
          : 'Error: $e';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Host QR')),
      body: Stack(
        children: [
          MobileScanner(controller: _scannerController, onDetect: _onDetect),
          if (_scannedUuid != null && !_isProcessing)
            Positioned(
              bottom: 40,
              left: 20,
              right: 20,
              child: Card(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Host ID: ${_scannedUuid!.substring(0, 8)}...',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _connectToHost,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Connect to Host'),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _scannedUuid = null),
                        child: const Text('Retry Scan'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_isProcessing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text(
                      'Securing P2P Tunnel...',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
