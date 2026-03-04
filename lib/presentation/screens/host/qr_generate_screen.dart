import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../domain/repositories/tracking_repository.dart';
import 'host_map_screen.dart';

class QrGenerateScreen extends StatefulWidget {
  const QrGenerateScreen({super.key});

  @override
  State<QrGenerateScreen> createState() => _QrGenerateScreenState();
}

class _QrGenerateScreenState extends State<QrGenerateScreen> {
  String? _offerData;
  bool _isGenerating = true;
  bool _scanningForAnswer = false;

  late final MobileScannerController _scannerController;

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController();
    _generateOffer();
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _generateOffer() async {
    final repo = context.read<TrackingRepository>();
    try {
      final offer = await repo.createHostOffer();
      if (!mounted) return;
      setState(() {
        _offerData = offer;
        _isGenerating = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error generating Offer: \$e')));
    }
  }

  void _onAnswerScanned(BarcodeCapture capture) async {
    if (capture.barcodes.isEmpty) return;

    final answerJson = capture.barcodes.first.rawValue;
    if (answerJson != null) {
      final repo = context.read<TrackingRepository>();
      final navigator = Navigator.of(context);
      try {
        await repo.hostAcceptClientAnswer(answerJson);
        // Stop scanner to release camera resources
        await _scannerController.stop();

        // Navigation should only happen once per scan theoretically
        navigator.pushReplacement(
          MaterialPageRoute(builder: (context) => const HostMapScreen()),
        );
      } catch (e) {
        debugPrint("Error accepting answer: \$e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_scanningForAnswer) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scan Follower Android Answer')),
        body: MobileScanner(
          controller: _scannerController,
          onDetect: _onAnswerScanned,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Pairing Mode (Host)')),
      body: Center(
        child: _isGenerating
            ? const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Generating Secure P2P Tunnel...'),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Have the Follower scan this QR code',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  if (_offerData != null)
                    QrImageView(
                      data: _offerData!,
                      version: QrVersions.auto,
                      size: 250.0,
                    ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _scanningForAnswer = true;
                      });
                    },
                    child: const Text('I am ready to scan their response'),
                  ),
                ],
              ),
      ),
    );
  }
}
