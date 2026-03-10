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

  void _onOfferScanned(BarcodeCapture capture) async {
    if (_isProcessing || capture.barcodes.isEmpty) return;

    final uuid = capture.barcodes.first.rawValue;
    if (uuid != null) {
      setState(() {
        _isProcessing = true;
      });

      final repo = context.read<TrackingRepository>();
      final navigator = Navigator.of(context);
      try {
        await repo.clientProcessHostOffer(uuid);

        await _scannerController.stop();
        if (!mounted) return;

        navigator.pushReplacement(
          MaterialPageRoute(builder: (context) => const ClientStatusScreen()),
        );
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isProcessing = false;
        });
        debugPrint("Error processing offer: $e");
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Host QR')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: _onOfferScanned,
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
