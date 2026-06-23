import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/country_code.dart';

// =============================================================================
// Phone Input Field — Country Code Picker + E.164 Validated Phone Number
// =============================================================================
//
// A reusable compound widget that combines:
//   • A tappable country-code button (flag + dial code)
//   • A searchable country picker bottom sheet
//   • A phone number text field with dynamic length validation
//
// Usage:
//   PhoneInputField(
//     controller: _phoneCtrl,
//     selectedCountry: _country,
//     onCountryChanged: (c) => setState(() => _country = c),
//     onValidationChanged: (err) => setState(() => _phoneError = err),
//   )
//
// The controller holds only the national number (no dial code / '+').
// Call `selectedCountry.toE164(controller.text)` to get the full number.
// =============================================================================

class PhoneInputField extends StatefulWidget {
  /// Controller for the national number portion only (digits).
  final TextEditingController controller;

  /// Currently selected country (drives validation & prefix display).
  final CountryCode selectedCountry;

  /// Called when the user picks a different country from the sheet.
  final ValueChanged<CountryCode> onCountryChanged;

  /// Called whenever validation state changes. `null` = valid.
  final ValueChanged<String?>? onValidationChanged;

  const PhoneInputField({
    super.key,
    required this.controller,
    required this.selectedCountry,
    required this.onCountryChanged,
    this.onValidationChanged,
  });

  @override
  State<PhoneInputField> createState() => _PhoneInputFieldState();
}

class _PhoneInputFieldState extends State<PhoneInputField> {
  String? _errorText;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_validate);
  }

  @override
  void didUpdateWidget(covariant PhoneInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedCountry != widget.selectedCountry) {
      _validate();
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_validate);
      widget.controller.addListener(_validate);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_validate);
    super.dispose();
  }

  void _validate() {
    final digits = widget.controller.text.trim();
    String? error;
    if (digits.isNotEmpty) {
      error = widget.selectedCountry.validateNationalNumber(digits);
    }
    if (error != _errorText) {
      setState(() => _errorText = error);
      widget.onValidationChanged?.call(error);
    }
  }

  void _openCountryPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CountryPickerSheet(
        selectedIso: widget.selectedCountry.isoCode,
        onSelected: (country) {
          widget.onCountryChanged(country);
          Navigator.pop(context);
          _validate();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final country = widget.selectedCountry;
    final lengthHint = country.nationalNumberLengths.length == 1
        ? '${country.nationalNumberLengths.first} digits'
        : '${country.minLength}–${country.maxLength} digits';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Country code button ──
            InkWell(
              onTap: _openCountryPicker,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(country.flag, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 6),
                    Text(
                      '+${country.dialCode}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.arrow_drop_down,
                        size: 20, color: Colors.grey.shade600),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),

            // ── Phone number field ──
            Expanded(
              child: TextField(
                controller: widget.controller,
                decoration: InputDecoration(
                  labelText: 'Phone Number *',
                  hintText: lengthHint,
                  border: const OutlineInputBorder(),
                  errorText: _errorText,
                  errorMaxLines: 3,
                ),
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  // +1 to allow an optional trunk-prefix '0' (e.g. UK 07xxx)
                  LengthLimitingTextInputFormatter(country.maxLength + 1),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// Country Picker Bottom Sheet — searchable list of countries
// =============================================================================

class _CountryPickerSheet extends StatefulWidget {
  final String selectedIso;
  final ValueChanged<CountryCode> onSelected;

  const _CountryPickerSheet({
    required this.selectedIso,
    required this.onSelected,
  });

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  final _searchCtrl = TextEditingController();
  List<CountryCode> _filtered = CountryCode.all;

  void _onSearchChanged(String query) {
    final q = query.toLowerCase();
    setState(() {
      _filtered = CountryCode.all.where((c) {
        return c.name.toLowerCase().contains(q) ||
            c.dialCode.contains(q) ||
            c.isoCode.toLowerCase().contains(q);
      }).toList();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.7;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ──
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Text(
            'Select Country',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          // ── Search bar ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: 'Search by name or code…',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // ── Country list ──
          Flexible(
            child: ListView.builder(
              itemCount: _filtered.length,
              itemBuilder: (ctx, i) {
                final c = _filtered[i];
                final selected = c.isoCode == widget.selectedIso;
                final lengthInfo = c.nationalNumberLengths.length == 1
                    ? '${c.nationalNumberLengths.first} digits'
                    : '${c.minLength}–${c.maxLength} digits';

                return ListTile(
                  leading: Text(c.flag, style: const TextStyle(fontSize: 28)),
                  title: Text(
                    c.name,
                    style: TextStyle(
                      fontWeight:
                          selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text('+${c.dialCode}  •  $lengthInfo'),
                  trailing:
                      selected ? const Icon(Icons.check, color: Colors.green) : null,
                  onTap: () => widget.onSelected(c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
