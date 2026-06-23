import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'safe_route_screen.dart';
import 'safety_profile_screen.dart';
import 'guidance_assistant_screen.dart';
import 'fake_call_screen.dart';
import '../../services/country_service.dart';
import '../../services/safety_guidance_service.dart';
import '../../services/quick_action_notification_service.dart';
import '../../models/safety_guidance.dart';
import '../panic_mode/panic_mode_screen.dart';
import '../history/history_screen.dart';
import '../../services/event_log_service.dart';
import '../../services/user_profile_service.dart';
import '../../models/event_log.dart';
import '../../models/user_profile.dart';
import '../../models/user_preferences.dart';
import '../../models/trusted_contact.dart';
import 'package:uuid/uuid.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  CountryInfo? _selectedCountry;
  List<SafetyGuidance> _tips = [];
  // ignore: unused_field
  HomeLocation? _homeLocation;

  // Feature 2: Quick Action notification toggle state
  bool _quickActionsEnabled = false;
  static const String _quickActionsKey = 'shesafe_quick_actions_enabled';

  final QuickActionNotificationService _quickActionSvc =
      QuickActionNotificationService();

  @override
  void initState() {
    super.initState();
    _loadCountry();
    _loadTips();
    _loadHomeLocation();
    _loadQuickActionsState();
  }

  Future<void> _loadHomeLocation() async {
    final loc = await UserProfileService().getHomeLocation();
    if (mounted) setState(() => _homeLocation = loc);
  }

  /// Restores the Quick Actions notification preference and re-shows the
  /// persistent notification if the user had it enabled.
  Future<void> _loadQuickActionsState() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_quickActionsKey) ?? false;
    if (mounted) {
      setState(() => _quickActionsEnabled = enabled);
      if (enabled) {
        await _quickActionSvc.init();
        await _quickActionSvc.showSafetyNotification();
      }
    }
  }

  Future<void> _toggleQuickActions(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_quickActionsKey, value);
    setState(() => _quickActionsEnabled = value);
    await _quickActionSvc.init();
    if (value) {
      await _quickActionSvc.showSafetyNotification();
    } else {
      await _quickActionSvc.dismissSafetyNotification();
    }
  }

  Future<void> _loadTips() async {
    final svc = SafetyGuidanceService();
    await svc.initialize();
    final all = svc.allEntries;
    if (all.isNotEmpty && mounted) {
      final shuffled = List.of(all)..shuffle();
      setState(() => _tips = shuffled.take(2).toList());
    }
  }

  Future<void> _loadCountry() async {
    final isSet = await CountryService().isCountrySet();
    if (!isSet) {
      // Show picker after first frame so the home screen has fully built
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showCountryPicker(context, required: true);
      });
    } else {
      final country = await CountryService().getSelectedCountry();
      if (mounted) setState(() => _selectedCountry = country);
    }
  }

  /// Bottom-sheet country picker.
  /// [required] = true prevents dismissal without choosing.
  Future<void> _showCountryPicker(BuildContext ctx,
      {bool required = false}) async {
    final picked = await showModalBottomSheet<CountryInfo>(
      context: ctx,
      isDismissible: !required,
      enableDrag: !required,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.92,
        builder: (__, scroll) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '🌍 Where are you based?',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'This helps SheSafe show nearby places and relevant examples.',
                    style:
                        TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: scroll,
                children: CountryService.countries
                    .map(
                      (c) => ListTile(
                        leading:
                            Text(c.flag, style: const TextStyle(fontSize: 26)),
                        title: Text(c.name),
                        subtitle: Text(c.hintShort,
                            style: const TextStyle(fontSize: 12)),
                        onTap: () => Navigator.of(__).pop(c),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );

    if (picked != null) {
      await CountryService().setSelectedCountry(picked);
      if (mounted) setState(() => _selectedCountry = picked);
    } else if (required && ctx.mounted) {
      // User swiped away without picking — re-show
      _showCountryPicker(ctx, required: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final eventLogService = EventLogService();
    final country = _selectedCountry;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SheSafe'),
        actions: [
          // Country flag — tap to change country
          TextButton(
            onPressed: () => _showCountryPicker(context),
            child: Text(
              country?.flag ?? '🌍',
              style: const TextStyle(fontSize: 22),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const HistoryScreen(),
                ),
              );
            },
            tooltip: 'Event History',
          ),
          IconButton(
            icon: const Icon(Icons.manage_accounts_outlined),
            tooltip: 'My Safety Profile',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const SafetyProfileScreen()),
              ).then((_) => setState(() {}));
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ──────────────────────────────────────────────────
              const Text(
                'Welcome Back',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Your safety system is ready',
                style: TextStyle(fontSize: 15, color: Colors.grey),
              ),

              // ── Hero shield ──────────────────────────────────────────────
              const SizedBox(height: 24),
              Center(
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.pink.shade100,
                    border: Border.all(
                      color: Colors.pink.shade300,
                      width: 4,
                    ),
                  ),
                  child: Icon(
                    Icons.shield,
                    size: 70,
                    color: Colors.pink.shade700,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  'System Active',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Center(
                child: Text(
                  'All safety features are configured',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
              ),

              // ── Buttons ──────────────────────────────────────────────────
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: () {
                  String destination = '';
                  showDialog(
                    context: context,
                    builder: (outerContext) {
                      String? errorText;
                      return StatefulBuilder(
                        builder: (context, setDialogState) => AlertDialog(
                          title: const Text('🗺️ Plan Safe Route'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(
                                decoration: InputDecoration(
                                  labelText: 'Enter Destination',
                                  hintText: country?.hintShort ?? 'e.g. Priory Street, Coventry',
                                  prefixIcon: const Icon(Icons.location_on),
                                  errorText: errorText,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onChanged: (value) {
                                  destination = value;
                                  // Clear the error once the user starts typing
                                  if (errorText != null && value.trim().isNotEmpty) {
                                    setDialogState(() => errorText = null);
                                  }
                                },
                              ),
                              const SizedBox(height: 16),
                              Builder(builder: (_) {
                                final eg = country?.examples ?? [
                                  'Priory Street, Coventry CV1 5FB',
                                  'London Bridge, London SE1 9BG',
                                  'Manchester Piccadilly M1 2QF',
                                ];
                                return Text(
                                  'Enter a place name, address or postcode.\n\nExamples:\n• ${eg[0]}\n• ${eg[1]}\n• ${eg[2]}',
                                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                                );
                              }),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton.icon(
                              onPressed: () {
                                final trimmed = destination.trim();
                                if (trimmed.isEmpty) {
                                  // Keep dialog open — show inline error
                                  setDialogState(() => errorText = 'Please enter a destination.');
                                  eventLogService.logEvent(
                                    type: EventType.safeRouteAttempted,
                                    outcome: EventOutcome.warning,
                                    description: 'Safe Route attempt blocked: destination field was empty',
                                    metadata: {'screen': 'HomeScreen', 'trigger': 'planSafeRouteDialog'},
                                  );
                                  debugPrint('[HomeScreen] Blocked — empty destination entered');
                                } else {
                                  eventLogService.logEvent(
                                    type: EventType.safeRouteAttempted,
                                    outcome: EventOutcome.info,
                                    description: 'Safe Route planning started',
                                    metadata: {'destination': trimmed},
                                  );
                                  debugPrint('[HomeScreen] Planning safe route to: "$trimmed"');
                                  Navigator.of(context).pop();
                                  Navigator.push(
                                    outerContext,
                                    MaterialPageRoute(
                                      builder: (_) => SafeRouteScreen(destination: trimmed),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.map),
                              label: const Text('Show Safe Route'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFB07080),
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
                icon: const Icon(Icons.map),
                label: const Text('Plan Safe Route',
                    style: TextStyle(fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFFB07080),
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  eventLogService.logEvent(
                    type: EventType.safetyModeActivated,
                    outcome: EventOutcome.success,
                    description: 'Safety monitoring activated',
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Safety Mode Activated! 🛡️'),
                      backgroundColor: Colors.purple,
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFF9B72CB),
                  foregroundColor: Colors.white,
                ),
                child: const Text('Activate Safety Mode',
                    style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const GuidanceAssistantScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.support_agent),
                label: const Text('Safety Assistant',
                    style: TextStyle(fontSize: 16)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Color(0xFF9B72CB), width: 2),
                  foregroundColor: const Color(0xFF9B72CB),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      settings: const RouteSettings(name: '/panic'),
                      builder: (context) => const PanicModeScreen(),
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Colors.red, width: 2),
                  foregroundColor: Colors.red,
                ),
                child: const Text('Emergency: Panic Mode',
                    style: TextStyle(fontSize: 16)),
              ),
              // ── Feature 1: Fake Phone Call ──────────────────────────────────
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const FakeCallScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.phone_in_talk),
                label: const Text('Fake Phone Call',
                    style: TextStyle(fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFFE8956D),
                  foregroundColor: Colors.white,
                ),
              ),

              // ── Feature 2: Lock-Screen Quick Action toggle ────────────────
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: _quickActionsEnabled
                      ? const Color(0xFF9B72CB).withValues(alpha: 0.1)
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _quickActionsEnabled
                        ? const Color(0xFF9B72CB).withValues(alpha: 0.5)
                        : Colors.grey.shade300,
                  ),
                ),
                child: SwitchListTile(
                  value: _quickActionsEnabled,
                  onChanged: _toggleQuickActions,
                  secondary: Icon(
                    Icons.lock_open_outlined,
                    color: _quickActionsEnabled
                      ? const Color(0xFF9B72CB)
                        : Colors.grey,
                  ),
                  title: const Text(
                    'Lock-Screen Quick Actions',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _quickActionsEnabled
                        ? 'Panic & Safe Word buttons visible without unlocking'
                        : 'Tap to show safety buttons on the lock screen',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade600),
                  ),
                  activeThumbColor: const Color(0xFF9B72CB),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              // ── Quick Safety Tips ─────────────────────────────────────
              if (_tips.isNotEmpty) ..._buildQuickTips(),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildQuickTips() {
    return [
      const SizedBox(height: 28),
      Row(
        children: [
          Icon(Icons.lightbulb_outline, size: 18, color: Colors.amber.shade700),
          const SizedBox(width: 6),
          Text(
            'Today\'s Safety Tips',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade800,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const GuidanceAssistantScreen(),
              ),
            ),
            child: Text(
              'See all →',
              style: TextStyle(
                fontSize: 13,
                color: const Color(0xFF9B72CB),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      ..._tips.map((tip) => _buildMiniTipCard(tip)),
    ];
  }

  Widget _buildMiniTipCard(SafetyGuidance tip) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFF9B72CB).withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tip.situation,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              tip.advice,
              style: TextStyle(
                fontSize: 12.5,
                color: Colors.grey.shade700,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              tip.category.displayName,
              style: TextStyle(
                fontSize: 11,
                color: const Color(0xFF9B72CB),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Future<void> _showHomeLocationDialog(BuildContext context) async {
    final TextEditingController searchCtrl = TextEditingController();
    final svc = UserProfileService();
    final currentHome = await svc.getHomeLocation();
    if (!context.mounted) return;

    await showDialog(
      context: context,
      builder: (dialogContext) {
        List<({double lat, double lon, String display})> results = [];
        bool isSearching = false;
        String? errorMsg;

        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            Future<void> search() async {
              final query = searchCtrl.text.trim();
              if (query.isEmpty) return;
              setDialogState(() {
                isSearching = true;
                errorMsg = null;
                results = [];
              });
              try {
                final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
                  'q': query,
                  'format': 'json',
                  'limit': '5',
                  'addressdetails': '0',
                });
                final response = await http.get(uri, headers: {
                  'User-Agent': 'SheSafe-FYP-App/1.0 (dissertation project)',
                  'Accept-Language': 'en',
                }).timeout(const Duration(seconds: 15));
                if (response.statusCode == 200) {
                  final data = jsonDecode(response.body) as List<dynamic>;
                  final parsed = data.map<({double lat, double lon, String display})>((r) => (
                    lat: double.parse(r['lat'] as String),
                    lon: double.parse(r['lon'] as String),
                    display: (r['display_name'] as String).split(',').take(3).join(',').trim(),
                  )).toList();
                  setDialogState(() {
                    results = parsed;
                    isSearching = false;
                    if (parsed.isEmpty) errorMsg = 'No results found. Try a different address.';
                  });
                } else {
                  setDialogState(() {
                    isSearching = false;
                    errorMsg = 'Search failed. Check your connection.';
                  });
                }
              } catch (e) {
                setDialogState(() {
                  isSearching = false;
                  errorMsg = 'Error: ${e.toString()}';
                });
              }
            }

            return AlertDialog(
              title: const Text('Set Home Location'),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (currentHome != null) ...[  
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.green.shade200),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.home, color: Color(0xFFB07080), size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Current: ${currentHome.label ?? "Home"}\n'
                                  '${currentHome.latitude.toStringAsFixed(4)}, '
                                  '${currentHome.longitude.toStringAsFixed(4)}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      const Text('Search for your home address:',
                          style: TextStyle(fontSize: 13, color: Colors.grey)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: searchCtrl,
                        decoration: InputDecoration(
                          hintText: 'e.g. 123 High Street, Coventry',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.search),
                            onPressed: search,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                        onSubmitted: (_) => search(),
                      ),
                      const SizedBox(height: 10),
                      if (isSearching)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(),
                          ),
                        ),
                      if (errorMsg != null)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(errorMsg!,
                              style: const TextStyle(color: Colors.red)),
                        ),
                      if (results.isNotEmpty) ...[  
                        const Divider(),
                        const Text('Tap to select:',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                        ...results.map(
                          (r) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.location_pin,
                                color: Colors.teal),
                            title: Text(r.display,
                                style: const TextStyle(fontSize: 13)),
                            onTap: () async {
                              Navigator.pop(dialogContext);
                              final saved = HomeLocation(
                                latitude: r.lat,
                                longitude: r.lon,
                                label: 'Home',
                                savedAt: DateTime.now(),
                              );
                              await svc.saveHomeLocation(saved);
                              if (context.mounted) {
                                setState(() => _homeLocation = saved);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                        'Home set to: ${r.display.split(',').first}'),
                                    backgroundColor: const Color(0xFFB07080),
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ignore: unused_element
  Future<void> _runProfileTest(BuildContext context) async {
    // Show a loading spinner immediately so the user sees feedback at once.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('Running profile checks…'),
            ],
          ),
        ),
      ),
    );

    final svc = UserProfileService();
    final results = <String>[];
    var allPassed = true;

    void log(String msg, {bool pass = true}) {
      final line = '${pass ? "✅" : "❌"} $msg';
      results.add(line);
      debugPrint('[ProfileTest] $line');
      if (!pass) allPassed = false;
    }

    try {
      // ── 1. Delete any previous test profile so we start clean ──────────
      await svc.deleteProfile();
      log('Old profile wiped');

      // ── 2. Create profile ───────────────────────────────────────────────
      final profile = await svc.createProfile();
      log('Profile created  →  userId: ${profile.userId.substring(0, 8)}…');

      // ── 3. Safe word ────────────────────────────────────────────────────
      await svc.setSafeWord('sunflower');
      final correctMatch  = await svc.verifySafeWord('sunflower');
      final wrongMatch    = await svc.verifySafeWord('wrongword');
      final capitalMatch  = await svc.verifySafeWord('Sunflower');
      log('Safe word set (PBKDF2-SHA256)');
      log('Correct word matches  → $correctMatch',  pass: correctMatch == true);
      log('Wrong word rejected   → $wrongMatch',    pass: wrongMatch == false);
      log('Capital rejected      → $capitalMatch',  pass: capitalMatch == false);

      // ── 4. Walking pace ─────────────────────────────────────────────────
      await svc.saveWalkingPace(WalkingPaceProfile(
        meanStepsPerSecond: 1.8,
        stdStepsPerSecond:  0.2,
        typicalSpeedMs:     1.4,
        minSpeedMs:         1.0,
        maxSpeedMs:         1.8,
        calibratedAt:       DateTime.now(),
      ));
      final pace = await svc.getWalkingPace();
      log('Walking pace saved  → ${pace?.typicalSpeedKmh.toStringAsFixed(1)} km/h',
          pass: pace != null);

      // ── 5. Trusted contact ──────────────────────────────────────────────
      await svc.saveTrustedContacts([
        TrustedContact(
          id:        const Uuid().v4(),
          name:      'Test Mum',
          phone:     '07700000000',
          isPrimary: true,
        ),
      ]);
      final contacts = await svc.getTrustedContacts();
      log('Contact saved  → ${contacts.firstOrNull?.name}',
          pass: contacts.length == 1);

      // ── 6. Home location ────────────────────────────────────────────────
      await svc.saveHomeLocation(HomeLocation(
        latitude:  52.4092,
        longitude: -1.5055,
        label:     'Home',
        savedAt:   DateTime.now(),
      ));
      final home = await svc.getHomeLocation();
      log('Home location saved  → ${home?.label} (${home?.latitude}, ${home?.longitude})',
          pass: home != null);

      // ── 7. Preferences ──────────────────────────────────────────────────
      await svc.savePreferences(const UserPreferences(
        riskRadiusMeters: 300,
        sensitivity:      RiskSensitivity.high,
      ));
      final prefs = await svc.getPreferences();
      log('Preferences saved  → radius=${prefs.riskRadiusMeters}m, '  
          'sensitivity=${prefs.sensitivity.name}',
          pass: prefs.riskRadiusMeters == 300);

      // ── 8. Reload full profile ──────────────────────────────────────────
      final loaded = await svc.loadProfile();
      log('Profile reloaded  → isFullyConfigured=${loaded?.isFullyConfigured}',
          pass: loaded?.isFullyConfigured == true);
      log('Primary contact  → ${loaded?.primaryContact?.name}',
          pass: loaded?.primaryContact?.name == 'Test Mum');

      // ── 9. hasSafeWord flag ─────────────────────────────────────────────
      log('hasSafeWord flag  → ${loaded?.hasSafeWord}',
          pass: loaded?.hasSafeWord == true);

    } catch (e, st) {
      results.add('❌ EXCEPTION: $e');
      debugPrint('[ProfileTest] ERROR: $e\n$st');
      allPassed = false;
    }

    // ── Show results in a dialog ─────────────────────────────────────────
    if (!context.mounted) return;
    Navigator.pop(context); // dismiss the loading spinner
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          allPassed ? '✅ All checks passed!' : '❌ Some checks failed',
          style: TextStyle(
            color: allPassed ? Colors.green : Colors.red,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Check the VS Code debug console for full output.\n',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              ...results.map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(r, style: const TextStyle(fontSize: 13,
                    fontFamily: 'monospace')),
              )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
