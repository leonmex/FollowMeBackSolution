import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../domain/repositories/tracking_repository.dart';
import 'host/qr_generate_screen.dart';
import 'client/qr_scan_screen.dart';
import '../../domain/entities/connection_method.dart';
import '../../domain/entities/session_role.dart';
import 'host/nfc_generate_screen.dart';
import 'client/nfc_scan_screen.dart';
import 'host/host_map_screen.dart';
import 'client/client_status_screen.dart';

class RoleSelectionScreen extends StatefulWidget {
  final ConnectionMethod selectedMethod;

  const RoleSelectionScreen({super.key, required this.selectedMethod});

  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen> {
  Future<void> _checkPermissionsAndNavigate(
    BuildContext context,
    Widget targetScreen,
  ) async {
    // 1. Android 11+ crashes if locationAlways is requested simultaneously with others.
    // We must request base location (foreground), camera, and notification first.
    Map<Permission, PermissionStatus> baseStatuses = await [
      Permission.camera,
      Permission.location,
      Permission.notification,
    ].request();

    final cameraGranted = baseStatuses[Permission.camera]?.isGranted ?? false;
    final locationGranted =
        baseStatuses[Permission.location]?.isGranted ?? false;

    if (!cameraGranted || !locationGranted) {
      if (!context.mounted) return;
      _showPermissionDialog(context);
      return;
    }

    // 2. Only after foreground location is granted, we can safely request background location
    final alwaysStatus = await Permission.locationAlways.request();

    // We proceed if they grant background location, OR if they at least have foreground.
    // (Foreground is enough to run the foreground_task, though Always is ideal)
    if (alwaysStatus.isGranted || locationGranted) {
      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => targetScreen),
      );
    } else {
      if (!context.mounted) return;
      _showPermissionDialog(context);
    }
  }

  void _showPermissionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Permissions Required'),
          content: const Text(
            'This app requires:\n\n'
            '1. Camera (to scan QR pairs)\n'
            '2. Location "Allow all the time" (to share GPS when screen is off)\n'
            '3. Notifications (to keep the background service alive)\n\n'
            'Please grant these permissions in Android Settings.',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              child: const Text('Open Settings'),
              onPressed: () {
                openAppSettings();
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<TrackingRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('Select Your Role')),
      body: StreamBuilder<String>(
        stream: repo.connectionState,
        builder: (context, snapshot) {
          if (repo.isConnected) {
            return _buildActiveSessionUI(context, repo);
          }
          return _buildRoleSelectionUI(context);
        },
      ),
    );
  }

  Widget _buildRoleSelectionUI(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _RoleCard(
            title: 'Following (Host)',
            subtitle: widget.selectedMethod == ConnectionMethod.nfc
                ? 'Create a sharing link and wait for a tap.'
                : 'Track another device, view locations on a Map.',
            icon: Icons.map,
            color: const Color.fromARGB(255, 63, 181, 108),
            onTap: () => _checkPermissionsAndNavigate(
              context,
              widget.selectedMethod == ConnectionMethod.nfc
                  ? const NfcGenerateScreen()
                  : const QrGenerateScreen(),
            ),
          ),
          const SizedBox(height: 24),
          _RoleCard(
            title: 'Follower (Client)',
            subtitle: widget.selectedMethod == ConnectionMethod.nfc
                ? 'Tap your device to the Host.'
                : 'Share your location directly with a Host.',
            icon: Icons.person_pin,
            color: const Color.fromARGB(255, 105, 133, 225),
            onTap: () => _checkPermissionsAndNavigate(
              context,
              widget.selectedMethod == ConnectionMethod.nfc
                  ? const NfcScanScreen()
                  : const QrScanScreen(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveSessionUI(BuildContext context, TrackingRepository repo) {
    final bool isHost = repo.currentRole == SessionRole.host;
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.link, size: 80, color: Colors.green),
          const SizedBox(height: 24),
          Text(
            'Active Session (\${repo.currentRole})',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const Text(
            'You are currently connected. Close the connection to start a new session.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Return to Session'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: isHost
                  ? const Color.fromARGB(255, 63, 181, 108)
                  : const Color.fromARGB(255, 105, 133, 225),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => isHost
                      ? const HostMapScreen()
                      : const ClientStatusScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.close),
            label: const Text('Close Connection'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              foregroundColor: Colors.red,
            ),
            onPressed: () {
              repo.disconnect();
            },
          ),
        ],
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _RoleCard({
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
          padding: const EdgeInsets.all(24.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: color.withAlpha(26), // 10% opacity
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 40, color: color),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}
