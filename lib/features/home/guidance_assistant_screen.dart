import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/safety_guidance_service.dart';
import '../../models/safety_guidance.dart';
import 'incident_report_screen.dart';
import 'helpline_contacts_screen.dart';

const _kAccent = Color(0xFFB07080);
const _kBg = Color(0xFFFFF0F5);
const _kSoft = Color(0xFFFFF5F8);
const _kBorder = Color(0xFFF2D5E2);

Color _mute(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation((hsl.saturation * 0.5).clamp(0.0, 1.0))
      .withLightness((hsl.lightness * 0.9 + 0.05).clamp(0.0, 1.0))
      .toColor();
}

/// C5 — Guidance / Assistant UI
///
/// A calm, chat-style support channel delivering evidence-based personal
/// safety advice. No medical diagnosis, no health or legal claims are made.
class GuidanceAssistantScreen extends StatefulWidget {
  const GuidanceAssistantScreen({super.key});

  @override
  State<GuidanceAssistantScreen> createState() =>
      _GuidanceAssistantScreenState();
}

// ─── Message model ─────────────────────────────────────────────────────────────

sealed class _ChatMessage {}

class _UserMessage extends _ChatMessage {
  final String text;
  _UserMessage(this.text);
}

class _AssistantMessage extends _ChatMessage {
  final List<SafetyGuidance> cards;
  final String? calmingMessage;
  _AssistantMessage({required this.cards, this.calmingMessage});
}

class _WelcomeMessage extends _ChatMessage {}

// ─── Screen state ───────────────────────────────────────────────────────────

class _GuidanceAssistantScreenState extends State<GuidanceAssistantScreen> {
  final SafetyGuidanceService _service = SafetyGuidanceService();
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final List<_ChatMessage> _messages = [_WelcomeMessage()];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _service.initialize();
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _submitQuery(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _textCtrl.clear();
    var results = _service.search(trimmed);
    // Always provide cards — fall back to curated set if nothing matched
    if (results.isEmpty) results = _getFallbackCards();
    setState(() {
      _messages.add(_UserMessage(trimmed));
      _messages.add(_AssistantMessage(
        cards: results,
        calmingMessage: _detectCalmingMessage(trimmed),
      ));
    });
    _scrollToBottom();
  }

  /// Returns a short calming sentence when emotional language is detected.
  String? _detectCalmingMessage(String query) {
    final lower = query.toLowerCase();
    const panicWords = [
      'panic', 'panicking', 'scared', 'terrified', 'frightened', 'afraid', 'fear'
    ];
    const anxietyPhysicalWords = [
      'anxious', 'anxiety', 'heartbeat', 'heart is racing', 'heart racing',
      'heart beating fast', 'racing heart', 'calm me down', 'calm me',
      'calm down', 'shaking', 'trembling', 'breathe', 'breathing fast',
      'chest tight', 'chest tightness', 'can\'t breathe', 'heart pounding',
    ];
    const stressWords = [
      'stressed', 'stress', 'overwhelmed', 'worried'
    ];
    const lostWords = [
      'lost', 'confused', "don't know", 'dont know', 'no idea',
      'what do i do', 'what should i do'
    ];
    const bullyWords = ['bully', 'bullied', 'bullying', 'cyberbully'];
    const helpWords = ['help', 'unsafe', 'danger', 'emergency', 'please'];
    const watchedWords = [
      'watched', 'watching', 'following me', 'being followed',
      'someone following', 'followed', 'someone is following',
    ];
    if (panicWords.any((w) => lower.contains(w))) {
      return "You're doing the right thing reaching out. "
          "Take a slow breath \u2014 you are not alone. Here's what can help:"
      ;
    }
    if (anxietyPhysicalWords.any((w) => lower.contains(w))) {
      return "Take a slow breath right now \u2014 in for 4 counts, hold for 2, out for 4. "
          "Your body is responding to stress and that is completely normal. "
          "You are safe. Here\u2019s what can help you feel grounded:";
    }
    if (bullyWords.any((w) => lower.contains(w))) {
      return "What you're going through is not okay, and it is not your fault. "
          "You deserve support. Here's what can help:";
    }
    if (lostWords.any((w) => lower.contains(w))) {
      return "That's okay \u2014 let's work through this together. "
          "Here's what might help right now:";
    }
    if (stressWords.any((w) => lower.contains(w))) {
      return "It's okay to feel this way. Let's take this one step at a time. "
          "Here's some guidance:";
    }
    if (watchedWords.any((w) => lower.contains(w))) {
      return "Your instincts are valid and you are doing the right thing by staying aware. "
          "Take a breath \u2014 you are not alone. Here\u2019s what to do right now:";
    }
    if (helpWords.any((w) => lower.contains(w))) {
      return "You matter and you deserve to feel safe. "
          "Here's what you can do:";
    }
    return null;
  }

  /// Curated fallback: mix of awareness + preparedness + general tips.
  List<SafetyGuidance> _getFallbackCards() {
    final pool = _service.getByCategories([
      GuidanceCategory.awareness,
      GuidanceCategory.preparedness,
      GuidanceCategory.general,
      GuidanceCategory.threatResponse,
    ]);
    final shuffled = List.of(pool)..shuffle();
    return shuffled.take(3).toList();
  }

  void _submitCategory(GuidanceCategory category) {
    final results = _service.getByCategories([category]);
    setState(() {
      _messages.add(_UserMessage(category.displayName));
      _messages.add(_AssistantMessage(cards: results));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1A),
        surfaceTintColor: Colors.transparent,
        title: const Row(
          children: [
            Icon(Icons.support_agent, color: _kAccent),
            SizedBox(width: 8),
            Text('Safety Assistant'),
          ],
        ),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildDisclaimerBanner(),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final msg = _messages[i];
                      if (msg is _WelcomeMessage) return _buildWelcome();
                      if (msg is _UserMessage) return _buildUserBubble(msg);
                      if (msg is _AssistantMessage) {
                        return _buildAssistantResponse(msg);
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                ),
                _buildInputBar(),
              ],
            ),
    );
  }

  // ── Disclaimer banner ────────────────────────────────────────────────────

  Widget _buildDisclaimerBanner() {
    return Container(
      width: double.infinity,
      color: _kSoft,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: _kAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'General safety information only — not a substitute for '
              'professional, medical, or legal advice. '
              'In an emergency, call 999.',
              style: TextStyle(
                fontSize: 11.5,
                color: const Color(0xFF7A3552),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Welcome card ─────────────────────────────────────────────────────────

  Widget _buildWelcome() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _assistantAvatar(),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _bubble(
                  color: Colors.white,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Hello, I am here to help.',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF7A3552),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Describe a situation you are facing, or tap a topic below '
                        'for calm, evidence-based safety advice.',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: Colors.grey.shade800,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: GuidanceCategory.values.map((cat) {
                    return ActionChip(
                      avatar: Icon(
                        _categoryIcon(cat),
                        size: 14,
                        color: _kAccent,
                      ),
                      label: Text(
                        cat.displayName,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF7A3552),
                        ),
                      ),
                      backgroundColor: _kSoft,
                      side: const BorderSide(color: _kBorder),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      onPressed: () => _submitCategory(cat),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── User bubble ──────────────────────────────────────────────────────────

  Widget _buildUserBubble(_UserMessage msg) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: _bubble(
          color: _kSoft,
          child: Text(
            msg.text,
            style: const TextStyle(color: Color(0xFF7A3552), fontSize: 14),
          ),
        ),
      ),
    );
  }

  // ── Assistant response ────────────────────────────────────────────────────

  Widget _buildAssistantResponse(_AssistantMessage msg) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _assistantAvatar(),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Calming message bubble (shown when emotional tone detected)
                if (msg.calmingMessage != null)
                  ..._buildCalmingBubble(msg.calmingMessage!),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 6),
                  child: Text(
                    '${msg.cards.length} tip${msg.cards.length == 1 ? '' : 's'}:',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
                ...msg.cards.map(_buildGuidanceCard),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCalmingBubble(String message) {
    return [
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _kSoft,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _kBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.self_improvement_outlined,
              size: 15, color: _kAccent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: Color(0xFF7A3552),
                  height: 1.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  // ── Guidance card ─────────────────────────────────────────────────────────

  static const _reportableCategories = {
    GuidanceCategory.threatResponse,
    GuidanceCategory.socialSafety,
    GuidanceCategory.digitalSafety,
    GuidanceCategory.general,
    GuidanceCategory.financialSafety,
  };

  Widget _buildGuidanceCard(SafetyGuidance g) {
    final showReport = _reportableCategories.contains(g.category);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _kBorder),
      ),
      child: ExpansionTile(
        tilePadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        childrenPadding:
            const EdgeInsets.fromLTRB(14, 0, 14, 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        leading: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: _kSoft,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            _categoryIcon(g.category),
            size: 18,
            color: _kAccent,
          ),
        ),
        title: Text(
          g.situation,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            g.category.displayName,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
          ),
        ),
        children: [
          const Divider(height: 1),
          const SizedBox(height: 10),
          _advisoryRow(
            icon: Icons.check_circle,
            iconColor: Colors.green.shade600,
            label: 'What to do',
            text: g.advice,
          ),
          const SizedBox(height: 12),
          _advisoryRow(
            icon: Icons.info_outline,
            iconColor: Colors.blue.shade600,
            label: 'Why this works',
            text: g.why,
          ),
          const SizedBox(height: 12),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.verified,
                    size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Source: ${g.source}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (showReport) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (_) => const _ReportSheet(),
                ),
                icon: const Icon(Icons.local_police, size: 16),
                label: const Text('Report to Police / Get Help'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kAccent,
                  side: const BorderSide(color: _kBorder),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  textStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _advisoryRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String text,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$label:',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                text,
                style:
                    const TextStyle(fontSize: 13, height: 1.4),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Input bar ─────────────────────────────────────────────────────────────

  Widget _buildInputBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textCtrl,
              textInputAction: TextInputAction.send,
              onSubmitted: _submitQuery,
              decoration: InputDecoration(
                hintText: 'e.g. being followed, dark street, low battery…',
                hintStyle: TextStyle(color: Colors.grey.shade400),
                filled: true,
                fillColor: _kSoft,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          CircleAvatar(
            radius: 24,
            backgroundColor: _kAccent,
            child: IconButton(
              icon:
                  const Icon(Icons.send, size: 18, color: Colors.white),
              onPressed: () => _submitQuery(_textCtrl.text),
            ),
          ),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _assistantAvatar() {
    return const CircleAvatar(
      radius: 18,
      backgroundColor: _kSoft,
      child: Icon(Icons.support_agent,
          size: 18, color: _kAccent),
    );
  }

  Widget _bubble({required Color color, required Widget child}) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  IconData _categoryIcon(GuidanceCategory category) {
    switch (category) {
      case GuidanceCategory.routeSafety:
        return Icons.map;
      case GuidanceCategory.threatResponse:
        return Icons.warning_amber;
      case GuidanceCategory.preparedness:
        return Icons.checklist;
      case GuidanceCategory.transportSafety:
        return Icons.directions_bus;
      case GuidanceCategory.awareness:
        return Icons.visibility;
      case GuidanceCategory.homeSafety:
        return Icons.home;
      case GuidanceCategory.exerciseSafety:
        return Icons.directions_run;
      case GuidanceCategory.financialSafety:
        return Icons.account_balance;
      case GuidanceCategory.socialSafety:
        return Icons.people;
      case GuidanceCategory.digitalSafety:
        return Icons.security;
      case GuidanceCategory.general:
        return Icons.info;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Report Sheet
// ─────────────────────────────────────────────────────────────────────────────
class _ReportSheet extends StatelessWidget {
  const _ReportSheet();

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
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.local_police, color: Colors.indigo.shade700),
                const Icon(Icons.local_police, color: _kAccent),
                const SizedBox(width: 8),
                Text(
                  'Report / Get Help',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF7A3552),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Tap a button to call directly, or visit the website.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 16),

            _CallTile(
              icon: Icons.emergency,
              iconColor: Colors.red,
              title: 'Emergency — 999',
              subtitle: 'Immediate danger to yourself or others',
              buttonColor: Colors.red,
              onTap: () => _call(context, '999'),
            ),
            const SizedBox(height: 10),
            _CallTile(
              icon: Icons.local_police,
              iconColor: Colors.blue.shade700,
              title: 'Non-Emergency Police — 101',
              subtitle: 'Report bullying, harassment, past incidents',
              buttonColor: Colors.blue.shade700,
              onTap: () => _call(context, '101'),
            ),
            const SizedBox(height: 10),
            _CallTile(
              icon: Icons.child_care,
              iconColor: Colors.green.shade700,
              title: 'Childline — 0800 1111',
              subtitle: 'Free & confidential — under 19s',
              buttonColor: Colors.green.shade700,
              onTap: () => _call(context, '08001111'),
            ),
            const SizedBox(height: 10),
            _CallTile(
              icon: Icons.favorite,
              iconColor: Colors.purple.shade600,
              title: 'Samaritans — 116 123',
              subtitle: 'Emotional support, 24/7, free',
              buttonColor: Colors.purple.shade600,
              onTap: () => _call(context, '116123'),
            ),
            const SizedBox(height: 14),

            Text(
              'Online Reporting',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 8),

            // ── In-app report button ──
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context); // close bottom sheet first
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const IncidentReportScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.edit_note, size: 18),
                label: const Text('Report an Incident'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Log incidents securely on your device — share with police or a trusted person anytime.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500, height: 1.4),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),

            // ── Helpline contacts button ──
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const HelplineContactsScreen(),
                    ),
                  );
                },
                icon: Icon(Icons.phone_in_talk, size: 16,
                    color: _kAccent),
                label: Text('View All Helpline Contacts',
                    style: const TextStyle(color: _kAccent)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _kBorder),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // ── Official external links ──
            Text(
              'Official online reporting (opens in your browser):',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade700),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _LinkChip(
                  label: 'Report to Police',
                  url: 'https://www.police.uk/',
                  onTap: (u) => _openUrl(context, u),
                ),
                _LinkChip(
                  label: 'Domestic Abuse',
                  url: 'https://www.police.uk/ro/report/domestic-abuse/a1/report-domestic-abuse/',
                  onTap: (u) => _openUrl(context, u),
                ),
                _LinkChip(
                  label: 'Hate Crime',
                  url: 'https://www.police.uk/ro/report/hate-crime/triage/v1/report-hate-crime/',
                  onTap: (u) => _openUrl(context, u),
                ),
                _LinkChip(
                  label: 'Report Fraud',
                  url: 'https://www.reportfraud.police.uk/',
                  onTap: (u) => _openUrl(context, u),
                ),
                _LinkChip(
                  label: 'Crimestoppers',
                  url: 'https://crimestoppers-uk.org/give-information',
                  onTap: (u) => _openUrl(context, u),
                ),
              ],
            ),
            const SizedBox(height: 14),

            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _kSoft,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _kBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lightbulb_outline,
                      size: 16, color: _kAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Before reporting: take screenshots, note dates, times '
                      'and witnesses. Evidence makes your report much stronger.',
                      style: TextStyle(
                          fontSize: 12,
                          color: const Color(0xFF7A3552),
                          height: 1.4),
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
}

class _CallTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Color buttonColor;
  final VoidCallback onTap;

  const _CallTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.buttonColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tonedIcon = _mute(iconColor);
    final tonedButton = _mute(buttonColor);
    return Container(
      decoration: BoxDecoration(
        color: _kSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
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
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: tonedButton,
            foregroundColor: Colors.white,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.bold),
          ),
          child: const Text('Call'),
        ),
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  final String label;
  final String url;
  final void Function(String) onTap;

  const _LinkChip(
      {required this.label, required this.url, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      avatar: const Icon(Icons.open_in_new, size: 13, color: _kAccent),
      backgroundColor: _kSoft,
      side: const BorderSide(color: _kBorder),
      onPressed: () => onTap(url),
    );
  }
}

