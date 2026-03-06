import 'package:flutter/material.dart';
import 'package:nfc_manager/nfc_manager.dart';
import '../../domain/entities/connection_method.dart';
import 'role_selection_screen.dart';

class EstablishConnectionScreen extends StatelessWidget {
  const EstablishConnectionScreen({super.key});

  Future<void> _handleConnectionMethodSelection(
    BuildContext context,
    ConnectionMethod method,
  ) async {
    if (method == ConnectionMethod.nfc) {
      // Check if NFC is available on this device
      NfcAvailability availability = await NfcManager.instance
          .checkAvailability();
      if (availability != NfcAvailability.enabled) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'NFC is not supported or is disabled on this device. Please use QR Code instead or enable NFC in settings.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
        return; // Stop navigation
      }
    }

    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RoleSelectionScreen(selectedMethod: method),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect Devices')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.cast_connected, size: 80, color: Colors.indigo),
              const SizedBox(height: 24),
              const Text(
                'How would you like to connect?',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose a method to link your devices securely.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 48),
              _ConnectionMethodCard(
                title: 'Tap to Connect (NFC)',
                subtitle:
                    'Hold devices back-to-back to instantly connect Host with Client.',
                icon: Icons.nfc,
                color: Colors.blueAccent,
                onTap: () => _handleConnectionMethodSelection(
                  context,
                  ConnectionMethod.nfc,
                ),
              ),
              const SizedBox(height: 20),
              _ConnectionMethodCard(
                title: 'Scan QR Code',
                subtitle:
                    'Scan a code on the Host screen with the Client camera.',
                icon: Icons.qr_code_scanner,
                color: Colors.teal,
                onTap: () => _handleConnectionMethodSelection(
                  context,
                  ConnectionMethod.qr,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionMethodCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ConnectionMethodCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: color.withAlpha(26), // 10% opacity
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 36, color: color),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                color: Colors.grey.shade400,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
