import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class PermissionService {
  static final PermissionService _instance = PermissionService._internal();
  factory PermissionService() => _instance;
  PermissionService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Initialize notifications plugin
  Future<void> initNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _notificationsPlugin.initialize(settings);
  }

  // Check location permission status
  Future<ph.PermissionStatus> checkLocationPermission() async {
    return await ph.Permission.location.status;
  }

  // Request location permission
  Future<ph.PermissionStatus> requestLocationPermission() async {
    final status = await ph.Permission.location.request();
    return status;
  }

  // Request location always permission (for background tracking)
  Future<ph.PermissionStatus> requestLocationAlwaysPermission() async {
    final status = await ph.Permission.locationAlways.request();
    return status;
  }

  // Check microphone permission status
  Future<ph.PermissionStatus> checkMicrophonePermission() async {
    return await ph.Permission.microphone.status;
  }

  // Request microphone permission
  Future<ph.PermissionStatus> requestMicrophonePermission() async {
    final status = await ph.Permission.microphone.request();
    return status;
  }

  // Check notification permission status
  Future<ph.PermissionStatus> checkNotificationPermission() async {
    return await ph.Permission.notification.status;
  }

  // Request notification permission
  Future<ph.PermissionStatus> requestNotificationPermission() async {
    final status = await ph.Permission.notification.request();
    return status;
  }

  // Check contacts permission status
  Future<ph.PermissionStatus> checkContactsPermission() async {
    return await ph.Permission.contacts.status;
  }

  // Request contacts permission
  Future<ph.PermissionStatus> requestContactsPermission() async {
    final status = await ph.Permission.contacts.request();
    return status;
  }

  // Open app settings — navigates the user to the system settings screen so
  // they can manually grant permanently-denied permissions.
  // Uses the permission_handler top-level function (not recursive self-call).
  Future<bool> openAppSettings() async {
    return await ph.openAppSettings();
  }

  // Check if all critical permissions are granted
  Future<Map<String, bool>> checkAllPermissions() async {
    final locationStatus = await checkLocationPermission();
    final micStatus = await checkMicrophonePermission();
    final notificationStatus = await checkNotificationPermission();

    return {
      'location': locationStatus.isGranted,
      'microphone': micStatus.isGranted,
      'notification': notificationStatus.isGranted,
    };
  }

  // Get permission status as string
  String getPermissionStatusText(ph.PermissionStatus status) {
    switch (status) {
      case ph.PermissionStatus.granted:
        return 'Granted';
      case ph.PermissionStatus.denied:
        return 'Denied';
      case ph.PermissionStatus.permanentlyDenied:
        return 'Permanently Denied';
      case ph.PermissionStatus.restricted:
        return 'Restricted';
      case ph.PermissionStatus.limited:
        return 'Limited';
      case ph.PermissionStatus.provisional:
        return 'Provisional';
    }
  }

  // Check if permission is permanently denied
  bool isPermanentlyDenied(ph.PermissionStatus status) {
    return status.isPermanentlyDenied;
  }

  // Request all critical permissions at once
  Future<Map<String, ph.PermissionStatus>> requestAllPermissions() async {
    final Map<ph.Permission, ph.PermissionStatus> statuses = await [
      ph.Permission.location,
      ph.Permission.notification,
    ].request();

    return {
      'location': statuses[ph.Permission.location]!,
      'notification': statuses[ph.Permission.notification]!,
    };
  }
}
