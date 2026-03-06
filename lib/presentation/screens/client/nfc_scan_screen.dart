import 'dart:convert';
import 'dart:typed_data';
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
  bool _isProcessingAndWriting = false;

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
          NdefMessage? cachedMessage;
          dynamic ndefPlatform;

          if (isAndroid) {
            final ndef = NdefAndroid.from(tag);
            if (ndef == null) {
              _updateStatus('Tag is not NDEF format. Cannot read.', false);
              return;
            }
            isWritable = ndef.isWritable;
            cachedMessage = ndef.cachedNdefMessage;
            ndefPlatform = ndef;
          } else {
            final ndef = NdefIos.from(tag);
            if (ndef == null) {
              _updateStatus('Tag is not NDEF format. Cannot read.', false);
              return;
            }
            isWritable = ndef.status == NdefStatusIos.readWrite;
            cachedMessage = ndef.cachedNdefMessage;
            ndefPlatform = ndef;
          }

          if (!_isProcessingAndWriting) {
            // 1. Client reads the Host Offer
            try {
              if (cachedMessage == null || cachedMessage.records.isEmpty) {
                return;
              }

              final record = cachedMessage.records.first;
              final payload = record.payload;
              final languageCodeLength = payload[0] & 0x3F;
              final offerStr = String.fromCharCodes(
                payload.sublist(1 + languageCodeLength),
              );

              _updateStatus('Offer read! Generating Answer...', true);

              // Process Offer & Create Answer
              final repo = context.read<TrackingRepository>();
              final answerStr = await repo.clientProcessHostOffer(offerStr);

              // Write the Answer back to the tag
              if (!isWritable) {
                _updateStatus(
                  'Offer processed, but cannot write answer back (Not Writable).',
                  false,
                );
                return;
              }

              final answerRecord = _createTextRecord(answerStr);
              final msg = NdefMessage(records: [answerRecord]);

              if (isAndroid) {
                await ndefPlatform.writeNdefMessage(msg);
              } else {
                await ndefPlatform.writeNdef(msg);
              }

              _updateStatus(
                'Answer written successfully! You are connected.',
                false,
              );
              await NfcManager.instance.stopSession();

              if (!mounted) return;
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (context) => const ClientStatusScreen(),
                ),
              );
            } catch (e) {
              _updateStatus('Failed to read or process offer: $e', false);
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
        _isProcessingAndWriting = processing;
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
                _isProcessingAndWriting ? Icons.sync : Icons.tap_and_play,
                size: 80,
                color: _isProcessingAndWriting ? Colors.orange : Colors.teal,
              ),
              const SizedBox(height: 32),
              if (_isProcessingAndWriting) const CircularProgressIndicator(),
              if (!_isProcessingAndWriting)
                const SizedBox(height: 36), // Filler
              const SizedBox(height: 24),
              Text(
                _isProcessingAndWriting ? 'Processing...' : 'Ready to Connect',
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
