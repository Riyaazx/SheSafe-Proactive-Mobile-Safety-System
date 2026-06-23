import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'incident_report_screen.dart';

const _kAccent = Color(0xFFB07080);
const _kBg = Color(0xFFFFF0F5);
const _kSoft = Color(0xFFFFF5F8);
const _kBorder = Color(0xFFF2D5E2);

Color _muteColor(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation((hsl.saturation * 0.45).clamp(0.0, 1.0))
      .withLightness((hsl.lightness * 0.88 + 0.07).clamp(0.0, 1.0))
      .toColor();
}

/// Dedicated screen listing all helpline contacts, emergency numbers,
/// online reporting links, and support organisations in one place.
///
/// Sections are collapsible — tap a header to expand/collapse.
class HelplineContactsScreen extends StatelessWidget {
  const HelplineContactsScreen({super.key});

  // ── Dial / copy ─────────────────────────────────────────────────────────
  Future<void> _call(BuildContext ctx, String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (ctx.mounted) {
      await Clipboard.setData(ClipboardData(text: number));
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text('$number copied to clipboard')),
      );
    }
  }

  // ── Open URL ────────────────────────────────────────────────────────────
  // Skip canLaunchUrl (unreliable on Android 11+) — try launching directly.
  Future<void> _openUrl(BuildContext ctx, String url) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Could not open $url')),
        );
      }
    } catch (_) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Could not open $url')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        title: const Text('Helpline Contacts'),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            // ─── 1. EMERGENCY SERVICES ────────────────────────────
            _CollapsibleSection(
              icon: Icons.emergency,
              title: 'Emergency Services',
              color: Colors.red.shade700,
              subtitle: '999 · Silent 999 · Emergency SMS',
              children: [
                _callCard(
                  context: context,
                  icon: Icons.emergency,
                  iconColor: Colors.red,
                  title: 'Emergency — 999',
                  subtitle: 'Immediate danger to yourself or others',
                  number: '999',
                  buttonColor: Colors.red,
                ),
                _callCardWithInfo(
                  context: context,
                  icon: Icons.volume_off,
                  iconColor: Colors.red.shade800,
                  title: 'Silent 999 — Press 55',
                  infoLines: [
                    'If you can\'t talk, call 999 then press 55.',
                    'The operator will know you need help.',
                  ],
                  number: '999',
                  buttonLabel: 'Call 999 (Silent)',
                  buttonColor: Colors.red.shade800,
                ),
                _actionCard(
                  context: context,
                  icon: Icons.sms,
                  iconColor: Colors.red.shade600,
                  title: 'Emergency SMS to 999',
                  subtitle: 'Opens your SMS app — type your message & send to 999',
                  onTap: () => launchUrl(Uri.parse('sms:999'), mode: LaunchMode.externalApplication),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ─── 2. NON-EMERGENCY ─────────────────────────────────
            _CollapsibleSection(
              icon: Icons.local_police,
              title: 'Non-Emergency',
              color: Colors.blue.shade700,
              subtitle: '101 · 111 — police & NHS',
              children: [
                _callCard(
                  context: context,
                  icon: Icons.local_police,
                  iconColor: Colors.blue.shade700,
                  title: 'Non-Emergency Police — 101',
                  subtitle: 'Report a crime or enquiry that isn\'t an emergency',
                  number: '101',
                  buttonColor: Colors.blue.shade700,
                ),
                _callCard(
                  context: context,
                  icon: Icons.accessibility_new,
                  iconColor: Colors.blue.shade600,
                  title: 'Hearing / Speech — 18001 101',
                  subtitle: 'Textphone relay service for deaf or speech-impaired users',
                  number: '18001101',
                  buttonColor: Colors.blue.shade600,
                ),
                _callCard(
                  context: context,
                  icon: Icons.local_hospital,
                  iconColor: Colors.teal.shade600,
                  title: 'NHS Non-Emergency — 111',
                  subtitle: 'Medical advice when it\'s not life-threatening',
                  number: '111',
                  buttonColor: Colors.teal.shade600,
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ─── 3. HELPLINES & SUPPORT ───────────────────────────
            _CollapsibleSection(
              icon: Icons.phone_in_talk,
              title: 'Helplines & Support',
              color: Colors.purple.shade700,
              subtitle: '8 helplines — tap to see all',
              children: [
                _callCard(
                  context: context,
                  icon: Icons.child_care,
                  iconColor: Colors.green.shade700,
                  title: 'Childline — 0800 1111',
                  subtitle: 'Free & confidential support for under 19s',
                  number: '08001111',
                  buttonColor: Colors.green.shade700,
                ),
                _callCard(
                  context: context,
                  icon: Icons.favorite,
                  iconColor: Colors.purple.shade600,
                  title: 'Samaritans — 116 123',
                  subtitle: 'Emotional support, 24 hours a day, free',
                  number: '116123',
                  buttonColor: Colors.purple.shade600,
                ),
                _callCard(
                  context: context,
                  icon: Icons.woman,
                  iconColor: Colors.pink.shade600,
                  title: 'Women\'s Aid — 0808 2000 247',
                  subtitle: 'Domestic abuse helpline, 24/7, free',
                  number: '08082000247',
                  buttonColor: Colors.pink.shade600,
                ),
                _callCard(
                  context: context,
                  icon: Icons.shield,
                  iconColor: Colors.orange.shade700,
                  title: 'Victim Support — 0808 1689 111',
                  subtitle: '24/7 support for victims of crime',
                  number: '08081689111',
                  buttonColor: Colors.orange.shade700,
                ),
                _callCard(
                  context: context,
                  icon: Icons.visibility_off,
                  iconColor: Colors.indigo.shade600,
                  title: 'National Stalking Helpline — 0808 802 0300',
                  subtitle: 'Advice and support for stalking victims',
                  number: '08088020300',
                  buttonColor: Colors.indigo.shade600,
                ),
                _callCard(
                  context: context,
                  icon: Icons.support,
                  iconColor: Colors.cyan.shade700,
                  title: 'Rape Crisis — 0808 500 2222',
                  subtitle: 'Support for sexual violence survivors',
                  number: '08085002222',
                  buttonColor: Colors.cyan.shade700,
                ),
                _callCard(
                  context: context,
                  icon: Icons.phone_android,
                  iconColor: Colors.deepOrange.shade600,
                  title: 'Revenge Porn Helpline — 0345 6000 459',
                  subtitle: 'Image-based sexual abuse support',
                  number: '03456000459',
                  buttonColor: Colors.deepOrange.shade600,
                ),
                _callCard(
                  context: context,
                  icon: Icons.people,
                  iconColor: Colors.brown.shade600,
                  title: 'NSPCC — 0808 800 5000',
                  subtitle: 'Report concerns about a child\'s safety',
                  number: '08088005000',
                  buttonColor: Colors.brown.shade600,
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ─── 4. REPORT A CRIME ONLINE ─────────────────────────
            _CollapsibleSection(
              icon: Icons.language,
              title: 'Report a Crime Online',
              color: Colors.blue.shade700,
              subtitle: 'Official police.uk links by crime type',
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'These open the official police website in your browser. '
                    'Choose the category that matches what happened.',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                        height: 1.4,
                        fontStyle: FontStyle.italic),
                  ),
                ),
                _linkCard(
                  context: context,
                  icon: Icons.local_police,
                  iconColor: Colors.blue.shade700,
                  title: 'Report to Police Online',
                  subtitle: 'General reporting — opens police.uk',
                  url: 'https://www.police.uk/',
                ),
                _linkCard(
                  context: context,
                  icon: Icons.home_outlined,
                  iconColor: Colors.pink.shade700,
                  title: 'Report Domestic Abuse',
                  subtitle: 'Opens police.uk domestic abuse form',
                  url: 'https://www.police.uk/ro/report/domestic-abuse/a1/report-domestic-abuse/',
                ),
                _linkCard(
                  context: context,
                  icon: Icons.report_gmailerrorred,
                  iconColor: Colors.red.shade700,
                  title: 'Report Sexual Offences',
                  subtitle: 'Rape, sexual assault & other offences',
                  url: 'https://www.police.uk/ro/report/rsa/alpha-v1/v1/rape-sexual-assault-other-sexual-offences/',
                ),
                _linkCard(
                  context: context,
                  icon: Icons.visibility_off,
                  iconColor: Colors.indigo.shade600,
                  title: 'Stalking or Harassment',
                  subtitle: 'Report stalking or harassment online',
                  url: 'https://www.police.uk/pu/contact-us/stalking-harassment/',
                ),
                _linkCard(
                  context: context,
                  icon: Icons.local_bar,
                  iconColor: Colors.deepOrange.shade600,
                  title: 'Report Spiking',
                  subtitle: 'Drink or needle spiking',
                  url: 'https://www.police.uk/pu/contact-us/spiking/',
                ),
                _linkCard(
                  context: context,
                  icon: Icons.shopping_bag,
                  iconColor: Colors.brown.shade600,
                  title: 'Burglary, Theft, Assault',
                  subtitle: 'Theft, damaged property or assault',
                  url: 'https://www.police.uk/pu/contact-us/theft-damaged-property-or-assault/',
                ),
                _linkCard(
                  context: context,
                  icon: Icons.report,
                  iconColor: Colors.deepPurple.shade600,
                  title: 'Report Hate Crime',
                  subtitle: 'Opens police.uk hate crime form',
                  url: 'https://www.police.uk/ro/report/hate-crime/triage/v1/report-hate-crime/',
                ),
                _linkCard(
                  context: context,
                  icon: Icons.computer,
                  iconColor: Colors.cyan.shade700,
                  title: 'Cyber Crime, Fraud or Scam',
                  subtitle: 'Online fraud, phishing, hacking',
                  url: 'https://www.police.uk/pu/contact-us/cyber-crime-fraud-or-a-scam/',
                ),
                _linkCard(
                  context: context,
                  icon: Icons.flag_circle,
                  iconColor: Colors.teal.shade600,
                  title: 'Crimestoppers (Anonymous)',
                  subtitle: 'Report crime 100% anonymously',
                  url: 'https://crimestoppers-uk.org/',
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ─── 5. TEXT & CHAT ───────────────────────────────────
            _CollapsibleSection(
              icon: Icons.chat_bubble_outline,
              title: 'Text & Chat Services',
              color: Colors.teal.shade700,
              subtitle: 'Text SHOUT · Childline Chat',
              children: [
                _actionCard(
                  context: context,
                  icon: Icons.textsms,
                  iconColor: Colors.teal.shade600,
                  title: 'Text SHOUT to 85258',
                  subtitle: 'Free, 24/7 crisis text support — tap to open SMS',
                  onTap: () => launchUrl(Uri.parse('sms:85258?body=SHOUT'), mode: LaunchMode.externalApplication),
                ),
                _linkCard(
                  context: context,
                  icon: Icons.chat,
                  iconColor: Colors.green.shade600,
                  title: 'Childline Live Chat',
                  subtitle: 'Opens live 1-2-1 counsellor chat — tap "Start a chat" on the page',
                  url: 'https://www.childline.org.uk/get-support/1-2-1-counsellor-chat/',
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ─── 6. REPORT AN INCIDENT (in-app) ──────────────────
            _CollapsibleSection(
              icon: Icons.edit_note,
              title: 'Report an Incident',
              color: Colors.indigo.shade700,
              subtitle: 'Log incidents securely on your device',
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const IncidentReportScreen()),
                    ),
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('Open Incident Report Form'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      textStyle: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ─── TIP BOX (always visible) ─────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _kSoft,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lightbulb_outline,
                      size: 18, color: _kAccent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'All helplines listed here are free to call from UK mobiles '
                      'and landlines.',
                      style: TextStyle(
                        fontSize: 12,
                        color: const Color(0xFF7A3552),
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  // ── Section header (kept for potential reuse) ──────────────────────────

  // ── Call card (tap to dial) ───────────────────────────────────────────
  Widget _callCard({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String number,
    required Color buttonColor,
  }) {
    final tonedIcon = _muteColor(iconColor);
    final tonedButton = _muteColor(buttonColor);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: tonedIcon.withValues(alpha: 0.12),
          child: Icon(icon, size: 18, color: tonedIcon),
        ),
        title: Text(title,
            style:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        trailing: ElevatedButton(
          onPressed: () => _call(context, number),
          style: ElevatedButton.styleFrom(
            backgroundColor: tonedButton,
            foregroundColor: Colors.white,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          child: const Text('Call'),
        ),
      ),
    );
  }

  // ── Call card with info lines (info text + call button) ───────────────
  Widget _callCardWithInfo({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    required List<String> infoLines,
    required String number,
    required String buttonLabel,
    required Color buttonColor,
  }) {
    final tonedIcon = _muteColor(iconColor);
    final tonedButton = _muteColor(buttonColor);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: tonedIcon.withValues(alpha: 0.12),
                child: Icon(icon, size: 18, color: tonedIcon),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...infoLines.map((line) => Padding(
                padding: const EdgeInsets.only(left: 52, bottom: 3),
                child: Text(line,
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                        height: 1.4)),
              )),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _call(context, number),
              icon: const Icon(Icons.call, size: 16),
              label: Text(buttonLabel),
              style: ElevatedButton.styleFrom(
                backgroundColor: tonedButton,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Link card (tap to open URL) ───────────────────────────────────────
  Widget _linkCard({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String url,
  }) {
    final tonedIcon = _muteColor(iconColor);
    return InkWell(
      onTap: () => _openUrl(context, url),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: tonedIcon.withValues(alpha: 0.12),
              child: Icon(icon, size: 18, color: tonedIcon),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade500)),
                ],
              ),
            ),
            Icon(Icons.open_in_new,
                size: 16, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  // ── Action card (custom onTap — e.g. open SMS) ───────────────────────
  Widget _actionCard({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final tonedIcon = _muteColor(iconColor);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: tonedIcon.withValues(alpha: 0.12),
              child: Icon(icon, size: 18, color: tonedIcon),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade500)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios,
                size: 14, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  // ── Info card (no action, just displays text) ─────────────────────────
  // ignore: unused_element
  Widget _stepRow(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20, height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.indigo.shade700,
              shape: BoxShape.circle,
            ),
            child: Text(number,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.indigo.shade900,
                  height: 1.35,
                )),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _infoCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required List<String> lines,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: iconColor.withValues(alpha: 0.1),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ...lines.map((l) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(l,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                            height: 1.3,
                          )),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Collapsible section — shows a styled header with a dropdown arrow.
// Tap to expand/collapse the children.
// ═════════════════════════════════════════════════════════════════════════════
class _CollapsibleSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final String subtitle;
  final bool initiallyExpanded;
  final List<Widget> children;

  const _CollapsibleSection({
    required this.icon,
    required this.title,
    required this.color,
    required this.subtitle,
    required this.children,
    // ignore: unused_element_parameter
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final toned = _muteColor(color);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: toned.withValues(alpha: 0.28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: toned.withValues(alpha: 0.12),
            child: Icon(icon, size: 18, color: toned),
          ),
          title: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: toned,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade500,
            ),
          ),
          iconColor: toned,
          collapsedIconColor: toned.withValues(alpha: 0.5),
          children: [
            for (int i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}