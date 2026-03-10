import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';
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
  bool _isNavigating = false;

  @override
  void initState() {
    super.initState();
    _generateOffer();
  }

  @override
  void dispose() {
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
      // Start waiting for client to scan and respond via backend
      _waitForClientPairing();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error generating Offer: $e')));
    }
  }

  Future<void> _waitForClientPairing() async {
    if (_isNavigating) return;
    final repo = context.read<TrackingRepository>();
    final navigator = Navigator.of(context);

    try {
      await repo.waitForPairing();
      if (!mounted || _isNavigating) return;

      _isNavigating = true;
      navigator.pushReplacement(
        MaterialPageRoute(builder: (context) => const HostMapScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint("Error waiting for pairing: $e");
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Pairing timeout: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  const Text(
                    'Waiting for secure connection...',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  const CircularProgressIndicator(strokeWidth: 2),
                ],
              ),
      ),
    );
  }
}
