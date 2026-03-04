import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../domain/repositories/tracking_repository.dart';
import 'client_status_screen.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _isProcessing = false;
  String? _answerData;

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
    if (_isProcessing || _answerData != null) return;

    final offerJson = capture.barcodes.first.rawValue;
    if (offerJson != null) {
      setState(() {
        _isProcessing = true;
      });

      final repo = context.read<TrackingRepository>();
      try {
        final answer = await repo.clientProcessHostOffer(offerJson);
        setState(() {
          _answerData = answer;
          _isProcessing = false;
        });
      } catch (e) {
        setState(() {
          _isProcessing = false;
        });
        debugPrint("Error processing offer: \$e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_answerData != null) {
      // Show the answer QR code for the host to scan
      return Scaffold(
        appBar: AppBar(title: const Text('Show this to Host')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Let the Host scan this response QR',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              QrImageView(
                data: _answerData!,
                version: QrVersions.auto,
                size: 250.0,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () async {
                  await _scannerController.stop();
                  if (!context.mounted) return;
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ClientStatusScreen(),
                    ),
                  );
                },
                child: const Text('Host has scanned successfully'),
              ),
            ],
          ),
        ),
      );
    }

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
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
