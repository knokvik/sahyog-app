import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../theme/app_colors.dart';
import 'app_search_delegate.dart';

class InlineSearchResults extends StatefulWidget {
  const InlineSearchResults({
    super.key,
    required this.api,
    required this.query,
    required this.onResultTap,
  });

  final ApiClient api;
  final String query;
  final void Function(SearchResult result) onResultTap;

  @override
  State<InlineSearchResults> createState() => _InlineSearchResultsState();
}

class _InlineSearchResultsState extends State<InlineSearchResults> {
  late Future<List<SearchResult>> _searchFuture;

  @override
  void initState() {
    super.initState();
    _searchFuture = _search(widget.query);
  }

  @override
  void didUpdateWidget(InlineSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      setState(() {
        _searchFuture = _search(widget.query);
      });
    }
  }

  Future<List<SearchResult>> _search(String q) async {
    if (q.trim().isEmpty) return [];

    final lowerQ = q.toLowerCase();
    final results = <SearchResult>[];

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
      final raw = await widget.api.get(path);
      if (raw is List) {
        return raw.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (_) {
      return [];
    }
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

  @override
  Widget build(BuildContext context) {
    if (widget.query.trim().isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 64),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Icon(Icons.search, size: 28, color: Colors.grey.shade400),
                const SizedBox(width: 8),
                Text(
                  'Waiting for search...',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return FutureBuilder<List<SearchResult>>(
      future: _searchFuture,
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
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Search failed: ${snapshot.error}',
                style: const TextStyle(color: AppColors.criticalRed),
              ),
            ),
          );
        }

        final results = snapshot.data ?? [];

        if (results.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 64),
                Icon(Icons.search_off, size: 56, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                Text(
                  'No results for "${widget.query}"',
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
                (result) => ListTile(
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
                  onTap: () => widget.onResultTap(result),
                ),
              ),
            ],
            const SizedBox(height: 100), // FAB padding padding
          ],
        );
      },
    );
  }
}
