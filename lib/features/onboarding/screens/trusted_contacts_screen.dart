import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../controllers/onboarding_controller.dart';
import '../../../models/country_code.dart';
import '../../../models/trusted_contact.dart';
import '../../../widgets/phone_input_field.dart';

class TrustedContactsScreen extends StatefulWidget {
  const TrustedContactsScreen({super.key});

  @override
  State<TrustedContactsScreen> createState() => _TrustedContactsScreenState();
}

class _TrustedContactsScreenState extends State<TrustedContactsScreen> {
  @override
  Widget build(BuildContext context) {
    final controller = context.watch<OnboardingController>();
    final contacts = controller.data.trustedContacts;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => controller.previousStep(),
        ),
        title: const Text('Trusted Contacts'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Scrollable content ────────────────────────────────────────
            Expanded(
              child: contacts.isEmpty
                  // When empty — simple scroll so large text never clips
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Add Trusted Contacts',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'These people will be notified if you\'re in danger. You can add them now or skip and add later.',
                            style: TextStyle(fontSize: 16),
                          ),
                          const SizedBox(height: 24),
                          Card(
                            color: const Color(0xFFEDE7F6),
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Row(
                                children: [
                                  const Icon(Icons.info, color: Color(0xFF9B72CB)),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Text(
                                      'No contacts added yet. You can add contacts or skip this step.',
                                      style: TextStyle(fontSize: 14),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  // When contacts exist — header + scrollable list
                  : CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Add Trusted Contacts',
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'These people will be notified if you\'re in danger. You can add them now or skip and add later.',
                                  style: TextStyle(fontSize: 16),
                                ),
                                const SizedBox(height: 24),
                              ],
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final contactData = contacts[index];
                                final contact = TrustedContact.fromJson(contactData);
                                return _buildContactCard(context, controller, contact);
                              },
                              childCount: contacts.length,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
            // ── Sticky bottom buttons ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _showAddContactDialog(context, controller),
                    icon: const Icon(Icons.person_add),
                    label: const Text('Add Contact'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (contacts.isNotEmpty)
                    ElevatedButton(
                      onPressed: () => controller.nextStep(),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: const Color(0xFFB07080),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text(
                        'Continue',
                        style: TextStyle(fontSize: 18),
                      ),
                    )
                  else
                    TextButton(
                      onPressed: () => controller.nextStep(),
                      child: const Text(
                        'Skip for now',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactCard(
    BuildContext context,
    OnboardingController controller,
    TrustedContact contact,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFF8D7E3),
          child: Text(
            contact.name[0].toUpperCase(),
            style: const TextStyle(
              color: Color(0xFFB07080),
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          contact.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(contact.phone),
            if (contact.relationship != null)
              Text(
                contact.relationship!,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (contact.isPrimary)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8D7E3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Primary',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFFB07080),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            PopupMenuButton(
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: Row(
                    children: [
                      Icon(Icons.edit, size: 20),
                      SizedBox(width: 8),
                      Text('Edit'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete, size: 20, color: Colors.red),
                      SizedBox(width: 8),
                      Text('Delete', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
              onSelected: (value) {
                if (value == 'edit') {
                  _showEditContactDialog(context, controller, contact);
                } else if (value == 'delete') {
                  _showDeleteConfirmation(context, controller, contact);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAddContactDialog(
    BuildContext context,
    OnboardingController controller,
  ) {
    _showContactSheet(
      context: context,
      title: 'Add Trusted Contact',
      subtitle: 'This person will be notified during emergencies and when you arrive safely.',
      buttonLabel: 'Add Contact',
      buttonIcon: Icons.person_add_rounded,
      initialPrimary: controller.data.trustedContacts.isEmpty,
      onSave: (name, phone, relationship, isPrimary) {
        final contact = TrustedContact(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: name,
          phone: phone,
          relationship: relationship,
          isPrimary: isPrimary,
        );
        controller.addContact(contact);
        Permission.sms.request().ignore();
      },
    );
  }

  void _showEditContactDialog(
    BuildContext context,
    OnboardingController controller,
    TrustedContact contact,
  ) {
    final detectedCountry = CountryCode.detectFromE164(contact.phone);

    _showContactSheet(
      context: context,
      title: 'Edit Contact',
      subtitle: 'Update ${contact.name}\'s details below.',
      buttonLabel: 'Save Changes',
      buttonIcon: Icons.check_rounded,
      initialName: contact.name,
      initialPhone: detectedCountry?.extractNationalNumber(contact.phone) ??
          (contact.phone.startsWith('+') ? contact.phone.substring(1) : contact.phone),
      initialRelationship: contact.relationship,
      initialPrimary: contact.isPrimary,
      initialCountry: detectedCountry,
      onSave: (name, phone, relationship, isPrimary) {
        final updatedContact = contact.copyWith(
          name: name,
          phone: phone,
          relationship: relationship,
          isPrimary: isPrimary,
        );
        controller.updateContact(updatedContact);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Shared bottom-sheet builder for Add / Edit
  // ---------------------------------------------------------------------------

  void _showContactSheet({
    required BuildContext context,
    required String title,
    required String subtitle,
    required String buttonLabel,
    required IconData buttonIcon,
    required void Function(String name, String phone, String? relationship, bool isPrimary) onSave,
    String? initialName,
    String? initialPhone,
    String? initialRelationship,
    bool initialPrimary = false,
    CountryCode? initialCountry,
  }) {
    final nameCtrl = TextEditingController(text: initialName ?? '');
    final phoneCtrl = TextEditingController(text: initialPhone ?? '');
    final relCtrl = TextEditingController(text: initialRelationship ?? '');
    CountryCode selectedCountry = initialCountry ?? CountryCode.defaultCountry;
    bool isPrimary = initialPrimary;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: false,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        String? sheetError;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Drag handle ──
                    Center(
                      child: Container(
                        width: 40, height: 4,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),

                    // ── Header ──
                    Row(
                      children: [
                        Container(
                          width: 48, height: 48,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8D7E3),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.person_rounded,
                              color: Color(0xFFB07080), size: 26),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title,
                                  style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(height: 2),
                              Text(subtitle,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade600)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // ── Section: Personal Info ──
                    _sectionLabel('Personal Information'),
                    const SizedBox(height: 10),
                    TextField(
                      controller: nameCtrl,
                      decoration: InputDecoration(
                        labelText: 'Full Name',
                        hintText: 'e.g. Sarah Johnson',
                        prefixIcon: const Icon(Icons.badge_outlined, size: 20),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                        filled: true,
                        fillColor: Colors.grey.shade50,
                      ),
                      textCapitalization: TextCapitalization.words,
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: relCtrl,
                      decoration: InputDecoration(
                        labelText: 'Relationship (optional)',
                        hintText: 'e.g. Sister, Best Friend, Partner',
                        prefixIcon: const Icon(Icons.people_outline, size: 20),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                        filled: true,
                        fillColor: Colors.grey.shade50,
                      ),
                      textCapitalization: TextCapitalization.words,
                    ),
                    const SizedBox(height: 22),

                    // ── Section: Phone Number ──
                    _sectionLabel('Phone Number'),
                    const SizedBox(height: 10),
                    PhoneInputField(
                      controller: phoneCtrl,
                      selectedCountry: selectedCountry,
                      onCountryChanged: (c) =>
                          setSheetState(() => selectedCountry = c),
                      onValidationChanged: (_) => setSheetState(() {}),
                    ),
                    const SizedBox(height: 22),

                    // ── Section: Settings ──
                    _sectionLabel('Contact Settings'),
                    const SizedBox(height: 10),
                    Container(
                      decoration: BoxDecoration(
                        color: isPrimary
                            ? const Color(0xFFF8D7E3)
                            : Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isPrimary
                              ? const Color(0xFFF0B8CC)
                              : Colors.grey.shade200,
                        ),
                      ),
                      child: SwitchListTile(
                        title: const Text('Primary Contact',
                            style: TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15)),
                        subtitle: Text(
                          isPrimary
                              ? 'This person will be contacted first in emergencies'
                              : 'Toggle on to make this your first emergency contact',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        ),
                        value: isPrimary,
                        activeThumbColor: const Color(0xFFB07080),
                        onChanged: (v) =>
                            setSheetState(() => isPrimary = v),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // ── Inline validation error ──
                    if (sheetError != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red.shade300),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                color: Colors.red.shade700, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                sheetError!,
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.red.shade800),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // ── Action buttons ──
                    SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          final name = nameCtrl.text.trim();
                          final phone = phoneCtrl.text.trim();
                          if (name.isEmpty || phone.isEmpty) {
                            setSheetState(() => sheetError =
                                'Name and phone number are required');
                            return;
                          }
                          final valError =
                              selectedCountry.validateNationalNumber(phone);
                          if (valError != null) {
                            setSheetState(() => sheetError = valError);
                            return;
                          }
                          setSheetState(() => sheetError = null);
                          onSave(
                            name,
                            selectedCountry.toE164(phone),
                            relCtrl.text.trim().isEmpty
                                ? null
                                : relCtrl.text.trim(),
                            isPrimary,
                          );
                          Navigator.pop(ctx);
                        },
                        icon: Icon(buttonIcon),
                        label: Text(buttonLabel,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFB07080),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 48,
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text('Cancel',
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 15)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

  Widget _sectionLabel(String text) {
    return Row(
      children: [
        Container(
          width: 3, height: 16,
          decoration: BoxDecoration(
            color: const Color(0xFFB07080),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade700,
              letterSpacing: 0.5,
            )),
      ],
    );
  }

  void _showDeleteConfirmation(
    BuildContext context,
    OnboardingController controller,
    TrustedContact contact,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Contact'),
        content: Text('Are you sure you want to remove ${contact.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              controller.removeContact(contact.id);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
