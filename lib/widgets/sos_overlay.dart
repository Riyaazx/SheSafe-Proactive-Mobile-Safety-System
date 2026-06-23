import 'package:flutter/material.dart';
import '../app_navigator.dart';
import '../features/panic_mode/panic_mode_screen.dart';
import '../features/home/manage_trusted_contacts_screen.dart';
import '../services/secure_storage_service.dart';

/// A persistent SOS pill that floats over every screen except the home screen
/// and PanicModeScreen (both excluded via route names in [sosObserver]).
/// Inject via MaterialApp.builder.
class SosOverlay extends StatelessWidget {
  final Widget child;

  const SosOverlay({super.key, required this.child});

  Future<void> _onSosTap(BuildContext context) async {
    final contacts = await SecureStorageService().getTrustedContacts();
    final navContext = navigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;
    if (contacts.isEmpty) {
      final openContacts = await showDialog<bool>(
        context: navContext,
        builder: (ctx) => AlertDialog(
          title: const Text('No Trusted Contacts'),
          content: const Text(
            'You must add at least one trusted contact before '
            'activating Panic Mode.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('OK'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFB07080),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('Add Trusted Contact'),
            ),
          ],
        ),
      );
      if (openContacts == true && navContext.mounted) {
        await Navigator.of(navContext).push(
          MaterialPageRoute(
            builder: (_) => const ManageTrustedContactsScreen(),
          ),
        );
      }
      return;
    }
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        settings: const RouteSettings(name: '/panic'),
        builder: (_) => const PanicModeScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Stack(
      children: [
        child,
        // ── SOS pill — [sosObserver] drives [showSosButton] ───────────────
        Positioned(
          bottom: 20 + bottomPad,
          right: 16,
          child: ValueListenableBuilder<bool>(
            valueListenable: showSosButton,
            builder: (_, visible, _) {
              if (!visible) return const SizedBox.shrink();
              return ValueListenableBuilder<bool>(
                valueListenable: panicModeActive,
                builder: (_, panicActive, _) {
                  if (panicActive) return const SizedBox.shrink();
                  return GestureDetector(
                    onTap: () => _onSosTap(context),
                    child: Semantics(
                      label: 'SOS emergency button — open Panic Mode',
                      button: true,
                      hint: 'Activates emergency monitoring and alert',
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(30),
                          color: Colors.white,
                          border: Border.all(
                            color: const Color(0xFFE8355A),
                            width: 1.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(25),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Text(
                          'SOS',
                          style: TextStyle(
                            color: Color(0xFFE8355A),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2.5,
                            decoration: TextDecoration.none,
                            decorationColor: Colors.transparent,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
