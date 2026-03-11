import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';
import 'package:ndef_record/ndef_record.dart';
import 'package:provider/provider.dart';
import '../../../domain/repositories/tracking_repository.dart';
import 'host_map_screen.dart';

class NfcGenerateScreen extends StatefulWidget {
  const NfcGenerateScreen({super.key});

  @override
  State<NfcGenerateScreen> createState() => _NfcGenerateScreenState();
}

class _NfcGenerateScreenState extends State<NfcGenerateScreen> {
  String? _offerData;
  bool _isGenerating = true;
  String _statusMessage = 'Generating Sharing Link...';
  bool _isNavigating = false;

  @override
  void initState() {
    super.initState();
    _generateOfferAndStartNfc();
  }

  @override
  void dispose() {
    NfcManager.instance.stopSession();
    super.dispose();
  }

  Future<void> _generateOfferAndStartNfc() async {
    final repo = context.read<TrackingRepository>();
    try {
      final offer = await repo.createHostOffer();
      if (!mounted) return;
      setState(() {
        _offerData = offer;
        _isGenerating = false;
        _statusMessage = 'Ready. Tap Client device to share Offer.';
      });
      _startNfcSession();
      _waitForClientPairing(); // Start polling loop immediately
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isGenerating = false;
        _statusMessage = e.toString().contains('Internet is requiered')
            ? e.toString().replaceAll('Exception: ', '')
            : 'Error generating Offer: $e';
      });
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
      await NfcManager.instance.stopSession();

      navigator.pushReplacement(
        MaterialPageRoute(builder: (context) => const HostMapScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint("Error waiting for pairing: $e");
    }
  }

  NdefRecord _createTextRecord(String text) {
    const languageCode = 'en';
    final textBytes = utf8.encode(text);
    final languageCodeBytes = utf8.encode(languageCode);
    final payload = Uint8List(1 + languageCodeBytes.length + textBytes.length);

    payload[0] = languageCodeBytes.length;
    payload.setRange(1, 1 + languageCodeBytes.length, languageCodeBytes);
    payload.setRange(1 + languageCodeBytes.length, payload.length, textBytes);

    return NdefRecord(
      typeNameFormat: TypeNameFormat.wellKnown,
      type: Uint8List.fromList([0x54]), // 'T'
      identifier: Uint8List.fromList([]),
      payload: payload,
    );
  }

  Future<void> _startNfcSession() async {
    try {
      await NfcManager.instance.startSession(
        pollingOptions: {
          NfcPollingOption.iso14443,
          NfcPollingOption.iso15693,
          NfcPollingOption.iso18092,
        },
        onDiscovered: (NfcTag tag) async {
          final isAndroid =
              Theme.of(context).platform == TargetPlatform.android;
          bool isWritable = false;
          dynamic ndefPlatform;

          if (isAndroid) {
            final ndef = NdefAndroid.from(tag);
            if (ndef == null) {
              _updateStatus('Tag is not NDEF format. Cannot write.');
              return;
            }
            isWritable = ndef.isWritable;
            ndefPlatform = ndef;
          } else {
            final ndef = NdefIos.from(tag);
            if (ndef == null) {
              _updateStatus('Tag is not NDEF format. Cannot write.');
              return;
            }
            isWritable = ndef.status == NdefStatusIos.readWrite;
            ndefPlatform = ndef;
          }

          if (!isWritable) {
            _updateStatus('NFC Tag is not writable.');
            return;
          }

          try {
            final record = _createTextRecord(_offerData!);
            final message = NdefMessage(records: [record]);
            if (isAndroid) {
              await ndefPlatform.writeNdefMessage(message);
            } else {
              await ndefPlatform.writeNdef(message);
            }
            _updateStatus(
              'Offer written successfully! Client device will now process it.',
            );
          } catch (e) {
            _updateStatus('Failed to write offer: $e');
          }
        },
      );
    } catch (e) {
      _updateStatus('NFC Error: $e');
    }
  }

  void _updateStatus(String msg) {
    if (mounted) {
      setState(() {
        _statusMessage = msg;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NFC Tap to Connect (Host)')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.nfc, size: 80, color: Colors.blueAccent),
              const SizedBox(height: 32),
              if (_isGenerating) const CircularProgressIndicator(),
              if (!_isGenerating) const SizedBox(height: 36),
              const SizedBox(height: 24),
              const Text(
                'Host Broadcasting UUID',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 32),
              const CircularProgressIndicator(strokeWidth: 2),
              const SizedBox(height: 8),
              const Text(
                'Waiting for Secure P2P Tunnel...',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
