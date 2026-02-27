import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../theme/app_colors.dart';

/// Result categories for the global search.
enum SearchCategory { volunteer, task, sos, zone }

/// A single search result item.
class SearchResult {
  final SearchCategory category;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Map<String, dynamic> raw;

  const SearchResult({
    required this.category,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.raw,
  });
}

/// Global search delegate used for the coordinator/volunteer app bars.
///
/// Searches across volunteers, tasks, SOS alerts, and zones.
/// When a result is tapped, [onResultTap] is called with the result
/// so the parent shell can navigate to the right tab/detail.
class AppSearchDelegate extends SearchDelegate<SearchResult?> {
  AppSearchDelegate({required this.api, required this.onResultTap})
    : super(
        searchFieldLabel: 'Search volunteers, tasks, SOS...',
        searchFieldStyle: const TextStyle(fontSize: 16),
      );

  final ApiClient api;
  final void Function(SearchResult result) onResultTap;

  @override
  ThemeData appBarTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      appBarTheme: theme.appBarTheme.copyWith(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 16),
        border: InputBorder.none,
      ),
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: const Icon(Icons.arrow_back),
      ),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return _buildSearchResults(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.isEmpty) {
      return _buildEmptyState();
    }
    return _buildSearchResults(context);
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            'Search across the app',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Find volunteers, tasks, SOS alerts, zones...',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults(BuildContext context) {
    return FutureBuilder<List<SearchResult>>(
      future: _search(query),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32.0),
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Search failed: ${snapshot.error}',
              style: const TextStyle(color: AppColors.criticalRed),
            ),
          );
        }

        final results = snapshot.data ?? [];

        if (results.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_off, size: 56, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                Text(
                  'No results for "$query"',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          );
        }

        // Group results by category
        final grouped = <SearchCategory, List<SearchResult>>{};
        for (final r in results) {
          grouped.putIfAbsent(r.category, () => []).add(r);
        }

        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final entry in grouped.entries) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  _categoryLabel(entry.key),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Colors.grey.shade500,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              ...entry.value.map(
                (result) => _ResultTile(
                  result: result,
                  onTap: () {
                    close(context, result);
                    onResultTap(result);
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  String _categoryLabel(SearchCategory cat) {
    switch (cat) {
      case SearchCategory.volunteer:
        return 'VOLUNTEERS';
      case SearchCategory.task:
        return 'TASKS';
      case SearchCategory.sos:
        return 'SOS ALERTS';
      case SearchCategory.zone:
        return 'ZONES';
    }
  }

  Future<List<SearchResult>> _search(String q) async {
    if (q.trim().isEmpty) return [];

    final lowerQ = q.toLowerCase();
    final results = <SearchResult>[];

    // Search in parallel across different data sources
    final futures = await Future.wait([
      _safeGet('/api/v1/coordinator/volunteers'),
      _safeGet('/api/v1/coordinator/tasks'),
      _safeGet('/api/v1/coordinator/sos'),
      _safeGet('/api/v1/coordinator/zones'),
    ]);

    final volunteers = futures[0];
    final tasks = futures[1];
    final sosList = futures[2];
    final zones = futures[3];

    // Search volunteers
    for (final v in volunteers) {
      final name = (v['full_name'] ?? '').toString().toLowerCase();
      final email = (v['email'] ?? '').toString().toLowerCase();
      if (name.contains(lowerQ) || email.contains(lowerQ)) {
        results.add(
          SearchResult(
            category: SearchCategory.volunteer,
            title: (v['full_name'] ?? 'Unnamed').toString(),
            subtitle: (v['email'] ?? '').toString(),
            icon: Icons.person,
            color: AppColors.primaryGreen,
            raw: v,
          ),
        );
      }
    }

    // Search tasks
    for (final t in tasks) {
      final title = (t['title'] ?? t['type'] ?? '').toString().toLowerCase();
      final desc = (t['description'] ?? '').toString().toLowerCase();
      final status = (t['status'] ?? '').toString().toLowerCase();
      if (title.contains(lowerQ) ||
          desc.contains(lowerQ) ||
          status.contains(lowerQ)) {
        results.add(
          SearchResult(
            category: SearchCategory.task,
            title: (t['title'] ?? t['type'] ?? 'Task').toString(),
            subtitle:
                '${(t['status'] ?? 'pending').toString().toUpperCase()} — ${(t['description'] ?? 'No description').toString()}',
            icon: Icons.assignment,
            color: Colors.blueAccent,
            raw: t,
          ),
        );
      }
    }

    // Search SOS
    for (final s in sosList) {
      final reporter = (s['reporter_name'] ?? s['volunteer_name'] ?? '')
          .toString()
          .toLowerCase();
      final status = (s['status'] ?? '').toString().toLowerCase();
      final id = (s['id'] ?? '').toString().toLowerCase();
      if (reporter.contains(lowerQ) ||
          status.contains(lowerQ) ||
          id.contains(lowerQ)) {
        results.add(
          SearchResult(
            category: SearchCategory.sos,
            title:
                'SOS — ${(s['reporter_name'] ?? s['volunteer_name'] ?? 'Unknown').toString()}',
            subtitle:
                '${(s['status'] ?? 'active').toString().toUpperCase()} • ${(s['created_at'] ?? '').toString()}',
            icon: Icons.sos,
            color: AppColors.criticalRed,
            raw: s,
          ),
        );
      }
    }

    // Search zones
    for (final z in zones) {
      final name = (z['name'] ?? '').toString().toLowerCase();
      final severity = (z['severity'] ?? '').toString().toLowerCase();
      if (name.contains(lowerQ) || severity.contains(lowerQ)) {
        results.add(
          SearchResult(
            category: SearchCategory.zone,
            title: (z['name'] ?? 'Zone').toString(),
            subtitle:
                'Severity: ${(z['severity'] ?? 'unknown').toString().toUpperCase()}',
            icon: Icons.location_on,
            color: Colors.orange,
            raw: z,
          ),
        );
      }
    }

    return results;
  }

  Future<List<Map<String, dynamic>>> _safeGet(String path) async {
    try {
      final raw = await api.get(path);
      if (raw is List) {
        return raw.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (_) {
      return [];
    }
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result, required this.onTap});

  final SearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: result.color.withValues(alpha: 0.15),
        child: Icon(result.icon, color: result.color, size: 20),
      ),
      title: Text(
        result.title,
        style: const TextStyle(fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        result.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
      ),
      trailing: Icon(
        Icons.arrow_forward_ios,
        size: 14,
        color: Colors.grey.shade400,
      ),
      onTap: onTap,
    );
  }
}
