import 'package:flutter/material.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';
import 'package:ndef_record/ndef_record.dart';
import 'package:provider/provider.dart';
import '../../../domain/repositories/tracking_repository.dart';
import 'client_status_screen.dart';

class NfcScanScreen extends StatefulWidget {
  const NfcScanScreen({super.key});

  @override
  State<NfcScanScreen> createState() => _NfcScanScreenState();
}

class _NfcScanScreenState extends State<NfcScanScreen> {
  String _statusMessage =
      'Hold your device near the Host to read the connection offer.';
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _startNfcSession();
  }

  @override
  void dispose() {
    NfcManager.instance.stopSession();
    super.dispose();
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
          NdefMessage? cachedMessage;

          if (isAndroid) {
            final ndef = NdefAndroid.from(tag);
            if (ndef == null) {
              _updateStatus('Tag is not NDEF format. Cannot read.', false);
              return;
            }
            cachedMessage = ndef.cachedNdefMessage;
          } else {
            final ndef = NdefIos.from(tag);
            if (ndef == null) {
              _updateStatus('Tag is not NDEF format. Cannot read.', false);
              return;
            }
            cachedMessage = ndef.status == NdefStatusIos.readWrite
                ? ndef.cachedNdefMessage
                : null; // Fallback or handle differently if needed

            // Re-read if needed, but usually cached is enough
            cachedMessage ??= ndef.cachedNdefMessage;
          }

          if (!_isProcessing) {
            // 1. Client reads the Host Offer (UUID)
            try {
              if (cachedMessage == null || cachedMessage.records.isEmpty) {
                return;
              }

              final record = cachedMessage.records.first;
              final payload = record.payload;

              // NDEF Text record handling
              final languageCodeLength = payload[0] & 0x3F;
              final uuid = String.fromCharCodes(
                payload.sublist(1 + languageCodeLength),
              );

              _updateStatus(
                'UUID read! Re-establishing direct tunnel...',
                true,
              );

              // Process UUID via backend mailbox
              final repo = context.read<TrackingRepository>();
              final navigator = Navigator.of(context);

              await repo.clientProcessHostOffer(uuid);

              // 2. Pair complete (Answer posted to backend)
              _updateStatus('Pairing complete! Connecting...', false);
              await NfcManager.instance.stopSession();

              if (!mounted) return;
              navigator.pushReplacement(
                MaterialPageRoute(
                  builder: (context) => const ClientStatusScreen(),
                ),
              );
            } catch (e) {
              final msg = e.toString().contains('Internet is requiered')
                  ? e.toString().replaceAll('Exception: ', '')
                  : 'Failed to process connection: $e';
              _updateStatus(msg, false);
            }
          }
        },
      );
    } catch (e) {
      _updateStatus('NFC Error: $e', false);
    }
  }

  void _updateStatus(String msg, bool processing) {
    if (mounted) {
      setState(() {
        _statusMessage = msg;
        _isProcessing = processing;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NFC Tap to Connect (Client)')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _isProcessing ? Icons.sync : Icons.tap_and_play,
                size: 80,
                color: _isProcessing ? Colors.orange : Colors.teal,
              ),
              const SizedBox(height: 32),
              if (_isProcessing) const CircularProgressIndicator(),
              if (!_isProcessing) const SizedBox(height: 36),
              const SizedBox(height: 24),
              Text(
                _isProcessing ? 'Processing Pairing...' : 'Ready to Connect',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
