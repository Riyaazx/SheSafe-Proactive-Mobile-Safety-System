import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import '../../models/event_log.dart';
import '../../services/event_log_service.dart';

const _kAccent = Color(0xFFB07080);
const _kBg = Color(0xFFFFF0F5);
const _kSoftSurface = Color(0xFFFFF5F8);
const _kText = Color(0xFF1A1A1A);

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final EventLogService _eventLogService = EventLogService();
  List<EventLog> _events = [];
  List<EventLog> _filteredEvents = [];
  bool _isLoading = true;
  EventType? _selectedTypeFilter;
  EventOutcome? _selectedOutcomeFilter;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    setState(() => _isLoading = true);
    
    try {
      final events = await _eventLogService.getAllEvents();
      setState(() {
        _events = events;
        _filteredEvents = events;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading events: $e'),
            backgroundColor: _kAccent,
          ),
        );
      }
    }
  }

  void _applyFilters() {
    setState(() {
      _filteredEvents = _events.where((event) {
        if (_selectedTypeFilter != null && event.type != _selectedTypeFilter) {
          return false;
        }
        if (_selectedOutcomeFilter != null && event.outcome != _selectedOutcomeFilter) {
          return false;
        }
        return true;
      }).toList();
    });
  }

  void _clearFilters() {
    setState(() {
      _selectedTypeFilter = null;
      _selectedOutcomeFilter = null;
      _filteredEvents = _events;
    });
  }

  Future<void> _exportEvents() async {
    try {
      final exportText = await _eventLogService.exportEvents();
      
      // Show export options dialog
      if (!mounted) return;
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Export Events'),
          content: const Text('How would you like to export the event history?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                await Share.share(
                  exportText,
                  subject: 'SheSafe Event History Report',
                );
              },
              icon: const Icon(Icons.share),
              label: const Text('Share as Text'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error exporting events: $e'),
          backgroundColor: _kAccent,
        ),
      );
    }
  }

  void _showFilterDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Filter Events'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Event Type',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('All Types'),
                    selected: _selectedTypeFilter == null,
                    onSelected: (selected) {
                      setState(() => _selectedTypeFilter = null);
                    },
                  ),
                  ...EventType.values.map((type) => FilterChip(
                    label: Text(_getShortTypeName(type)),
                    selected: _selectedTypeFilter == type,
                    onSelected: (selected) {
                      setState(() {
                        _selectedTypeFilter = selected ? type : null;
                      });
                    },
                  )),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Outcome',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('All Outcomes'),
                    selected: _selectedOutcomeFilter == null,
                    onSelected: (selected) {
                      setState(() => _selectedOutcomeFilter = null);
                    },
                  ),
                  ...EventOutcome.values.map((outcome) => FilterChip(
                    label: Text(_getOutcomeName(outcome)),
                    selected: _selectedOutcomeFilter == outcome,
                    selectedColor: _getOutcomeColor(outcome).withValues(alpha: 0.3),
                    onSelected: (selected) {
                      setState(() {
                        _selectedOutcomeFilter = selected ? outcome : null;
                      });
                    },
                  )),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _clearFilters();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
          ElevatedButton(
            onPressed: () {
              _applyFilters();
              Navigator.pop(context);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _kText,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text('Event History'),
        actions: [
          if (_selectedTypeFilter != null || _selectedOutcomeFilter != null)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: _clearFilters,
              tooltip: 'Clear filters',
            ),
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: _showFilterDialog,
            tooltip: 'Filter events',
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _filteredEvents.isNotEmpty ? _exportEvents : null,
            tooltip: 'Export report',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _kAccent))
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_filteredEvents.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.history,
              size: 80,
              color: Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              _events.isEmpty
                  ? 'No events yet'
                  : 'No events match the filters',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey.shade600,
              ),
            ),
            if (_events.isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Events will appear here as you use the app',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade500,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (_events.isNotEmpty && _filteredEvents.isEmpty) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _clearFilters,
                child: const Text('Clear Filters'),
              ),
            ],
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadEvents,
      child: Column(
        children: [
          if (_selectedTypeFilter != null || _selectedOutcomeFilter != null)
            Container(
              padding: const EdgeInsets.all(12),
              color: _kSoftSurface,
              child: Row(
                children: [
                  const Icon(Icons.filter_alt, size: 20, color: _kAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Filtered: ${_filteredEvents.length} of ${_events.length} events',
                      style: const TextStyle(color: _kAccent),
                    ),
                  ),
                  TextButton(
                    onPressed: _clearFilters,
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _filteredEvents.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final event = _filteredEvents[index];
                return _buildEventCard(event);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventCard(EventLog event) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFF2D5E2)),
      ),
      child: InkWell(
        onTap: () => _showEventDetails(event),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icon with outcome color
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: event.outcomeColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  event.icon,
                    color: _getOutcomeColor(event.outcome),
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              // Event details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            event.typeName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        _buildOutcomeBadge(event.outcome),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      event.description,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.access_time,
                          size: 14,
                          color: Colors.grey.shade500,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatEventTime(event.timestamp),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: Colors.grey,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOutcomeBadge(EventOutcome outcome) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _getOutcomeColor(outcome).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _getOutcomeColor(outcome).withValues(alpha: 0.3),
        ),
      ),
      child: Text(
        _getOutcomeName(outcome),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: _getOutcomeColor(outcome),
        ),
      ),
    );
  }

  void _showEventDetails(EventLog event) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(24),
          child: ListView(
            controller: scrollController,
            children: [
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: event.outcomeColor.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      event.icon,
                      color: event.outcomeColor,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.typeName,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _buildOutcomeBadge(event.outcome),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _buildDetailRow(
                Icons.access_time,
                'Timestamp',
                DateFormat('MMM d, y \'at\' h:mm a').format(event.timestamp),
              ),
              const SizedBox(height: 16),
              _buildDetailRow(
                Icons.description,
                'Description',
                event.description,
              ),
              if (event.metadata != null && event.metadata!.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  'Additional Information',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ...event.metadata!.entries.map((entry) {
                  if (!_isSensitiveKey(entry.key)) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${entry.key}:',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: Colors.grey.shade700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              entry.value.toString(),
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                }),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Colors.grey.shade600),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatEventTime(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes} min ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
    } else {
      return DateFormat('MMM d, y').format(timestamp);
    }
  }

  String _getShortTypeName(EventType type) {
    switch (type) {
      case EventType.safeRouteGenerated:
        return 'Safe Route';
      case EventType.riskZoneDetected:
        return 'Risk Zone';
      case EventType.panicModeActivated:
        return 'Panic On';
      case EventType.panicModeDeactivated:
        return 'Panic Off';
      case EventType.safeWordVerified:
        return 'Verified';
      case EventType.safeWordFailed:
        return 'Failed';
      case EventType.trustedContactAlerted:
        return 'Alert Sent';
      case EventType.safetyModeActivated:
        return 'Safety Mode';
      case EventType.calibrationCompleted:
        return 'Calibration';
      case EventType.locationPermissionGranted:
        return 'Location ON';
      case EventType.locationPermissionDenied:
        return 'Location OFF';
      case EventType.appLaunched:
        return 'App Launch';
      case EventType.motionBaselineCalibrated:
        return 'Motion Cal';
      case EventType.motionAnomalyDetected:
        return 'Motion Alert';
      case EventType.motionConcernTriggered:
        return 'Motion Concern';
      case EventType.escalationStageChanged:
        return 'Escalation';
      case EventType.checkInPromptShown:
        return 'Check-In';
      case EventType.checkInResponseReceived:
        return 'Check-In Resp';
      case EventType.countdownStarted:
        return 'Countdown';
      case EventType.countdownCancelled:
        return 'Cancelled';
      case EventType.emergencyAlertDispatched:
        return 'Alert Sent';
      case EventType.arrivalNotificationSent:
        return 'Arrived Safe';
      case EventType.walkCompleted:
        return 'Walk Done';
      case EventType.safeRouteAttempted:
        return 'Route Attempt';
    }
  }

  String _getOutcomeName(EventOutcome outcome) {
    switch (outcome) {
      case EventOutcome.success:
        return 'Success';
      case EventOutcome.warning:
        return 'Warning';
      case EventOutcome.failure:
        return 'Failed';
      case EventOutcome.info:
        return 'Info';
    }
  }

  Color _getOutcomeColor(EventOutcome outcome) {
    switch (outcome) {
      case EventOutcome.success:
        return _kAccent;
      case EventOutcome.warning:
        return const Color(0xFFC07A3A);
      case EventOutcome.failure:
        return const Color(0xFFB85B74);
      case EventOutcome.info:
        return const Color(0xFFA77B95);
    }
  }

  bool _isSensitiveKey(String key) {
    const sensitiveKeys = [
      'location',
      'coordinates',
      'latitude',
      'longitude',
      'address',
      'phone',
      'contact',
      'password',
      'token',
    ];
    return sensitiveKeys.any((sensitive) => 
      key.toLowerCase().contains(sensitive));
  }
}
