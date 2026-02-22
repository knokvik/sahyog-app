import 'dart:async';
import 'dart:io';

import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/models.dart';
import '../../theme/app_colors.dart';
import '../../core/connectivity_service.dart';
import '../../core/socket_service.dart';
import '../../core/ble_scanner_service.dart';
import '../assignments/assignments_tab.dart';
import '../coordinator/coordinator_dashboard_tab.dart';
import '../coordinator/coordinator_operations_tab.dart';
import '../coordinator/combined_sos_tab.dart';
import '../home/home_tab.dart';
import '../home/user_home_tab.dart';
import '../home/global_sos_indicator.dart';
import '../map/map_tab.dart';
import '../missing/missing_tab.dart';
import '../notifications/notifications_tab.dart';
import '../profile/profile_tab.dart';
import 'user_profile_completion_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.authState});

  final ClerkAuthState authState;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _loading = true;
  String _error = '';
  AppUser? _user;
  late final ApiClient _api;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(baseUrl: AppConfig.baseUrl, tokenProvider: _tokenProvider);
    _bootstrap();
  }

  @override
  void dispose() {
    ConnectivityService.instance.dispose();
    SocketService.instance.dispose();
    super.dispose();
  }

  Future<String?> _tokenProvider() async {
    try {
      final clerk.SessionToken token = await widget.authState.sessionToken();
      return token.jwt;
    } catch (_) {
      return null;
    }
  }

  Future<void> _bootstrap() async {
    try {
      setState(() {
        _loading = true;
        _error = '';
      });

      final syncRaw = await _api.post('/api/auth/sync');
      if (syncRaw is! Map<String, dynamic> ||
          syncRaw['user'] is! Map<String, dynamic>) {
        throw Exception('Invalid sync response from backend');
      }

      var user = AppUser.fromSync(syncRaw['user'] as Map<String, dynamic>);

      try {
        final meRaw = await _api.get('/api/users/me');
        if (meRaw is Map<String, dynamic>) {
          final me = AppUser.fromMe(meRaw);
          user = me.copyWith(
            name: user.name.isNotEmpty ? user.name : me.name,
            email: me.email.isNotEmpty ? me.email : user.email,
          );
        }
      } catch (_) {}

      if (!mounted) return;

      // Initialize background offline SOS sync
      ConnectivityService.instance.initialize(_api);

      // Initialize Real-time SOS alerts for coordinators and admins
      SocketService.instance.initialize(
        context,
        user.isCoordinator || user.isAdmin,
      );

      // Initialize BLE Mesh scanner for everyone (all users can relay)
      BleScannerService.instance.initialize(_api, user.id);
      BleScannerService.instance.startScanning();

      setState(() {
        _user = user;
        _loading = false;
      });
    } on SocketException catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Server Unreachable - Please check your connection.';
        _loading = false;
      });
    } on TimeoutException catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Connection Timed Out - Server Unreachable.';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_error.isNotEmpty || _user == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 60,
                  color: AppColors.criticalRed,
                ),
                const SizedBox(height: 10),
                Text(
                  _error.isEmpty ? 'Failed to load profile.' : _error,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _bootstrap, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }

    return RoleBasedAppShell(api: _api, user: _user!, onRefresh: _bootstrap);
  }
}

class RoleBasedAppShell extends StatelessWidget {
  const RoleBasedAppShell({
    super.key,
    required this.api,
    required this.user,
    required this.onRefresh,
  });

  final ApiClient api;
  final AppUser user;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    if (user.isCoordinator) {
      return CoordinatorAppShell(api: api, user: user);
    }
    if (user.isUser) {
      if ((user.phone?.isEmpty ?? true) ||
          (user.bloodGroup?.isEmpty ?? true) ||
          (user.address?.isEmpty ?? true)) {
        return UserProfileCompletionScreen(
          api: api,
          user: user,
          onCompleted: onRefresh,
        );
      }
      return UserAppShell(api: api, user: user);
    }
    return GeneralAppShell(api: api, user: user);
  }
}

class UserAppShell extends StatefulWidget {
  const UserAppShell({super.key, required this.api, required this.user});

  final ApiClient api;
  final AppUser user;

  @override
  State<UserAppShell> createState() => _UserAppShellState();
}

class _UserAppShellState extends State<UserAppShell> {
  int _index = 0;
  final ValueNotifier<int> _refreshNotifier = ValueNotifier(0);

  static const _titles = ['Dashboard', 'Map', 'Missing', 'Profile'];

  @override
  Widget build(BuildContext context) {
    final tabs = [
      UserHomeTab(
        key: ValueKey('u_home_${_index}_${_refreshNotifier.value}'),
        api: widget.api,
        user: widget.user,
      ),
      MapTab(
        key: ValueKey('u_map_${_index}_${_refreshNotifier.value}'),
        api: widget.api,
      ),
      MissingTab(
        key: ValueKey('u_missing_${_index}_${_refreshNotifier.value}'),
        api: widget.api,
      ),
      ProfileTab(
        key: ValueKey('u_prof_${_index}_${_refreshNotifier.value}'),
        api: widget.api,
        user: widget.user,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 24,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'lib/assets/favicon.png',
                width: 28,
                height: 28,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _titles[_index],
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            const _RoleChip(label: 'CITIZEN', color: Colors.orange),
          ],
        ),
        actions: [
          _RefreshControl(
            onRefresh: () {
              setState(() => _refreshNotifier.value++);
            },
          ),
          IconButton(
            onPressed: () => Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (ctx, anim, secondaryAnim) =>
                    NotificationsTab(api: widget.api, user: widget.user),
                transitionsBuilder: (ctx, anim, secondaryAnim, child) {
                  return FadeTransition(opacity: anim, child: child);
                },
              ),
            ),
            icon: const Icon(Icons.notifications_none),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: tabs[_index],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_alt_outlined),
            selectedIcon: Icon(Icons.people_alt),
            label: 'Missing',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class GeneralAppShell extends StatefulWidget {
  const GeneralAppShell({super.key, required this.api, required this.user});

  final ApiClient api;
  final AppUser user;

  @override
  State<GeneralAppShell> createState() => _GeneralAppShellState();
}

class _GeneralAppShellState extends State<GeneralAppShell> {
  int _index = 0;
  final ValueNotifier<int> _refreshNotifier = ValueNotifier(0);

  static const _titles = ['Dashboard', 'Map', 'SOS', 'Tasks', 'Profile'];

  @override
  Widget build(BuildContext context) {
    final tabs = [
      HomeTab(
        key: ValueKey('home_${_index}_${_refreshNotifier.value}'),
        api: widget.api,
        user: widget.user,
      ),
      MapTab(
        key: ValueKey('map_${_index}_${_refreshNotifier.value}'),
        api: widget.api,
      ),
      CombinedSosTab(
        key: ValueKey('sos_${_index}_${_refreshNotifier.value}'),
        api: widget.api,
        user: widget.user,
      ),
      AssignmentsTab(
        key: ValueKey('asn_${_index}_${_refreshNotifier.value}'),
        api: widget.api,
        user: widget.user,
      ),
      ProfileTab(
        key: ValueKey('prof_${_index}_${_refreshNotifier.value}'),
        api: widget.api,
        user: widget.user,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 24,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'lib/assets/favicon.png',
                width: 28,
                height: 28,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _titles[_index],
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            const _RoleChip(label: 'VOLUNTEER', color: AppColors.primaryGreen),
          ],
        ),
        actions: [
          _RefreshControl(
            onRefresh: () {
              setState(() => _refreshNotifier.value++);
            },
          ),
          IconButton(
            onPressed: () => Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (ctx, anim, secondaryAnim) =>
                    NotificationsTab(api: widget.api, user: widget.user),
                transitionsBuilder: (ctx, anim, secondaryAnim, child) {
                  return FadeTransition(opacity: anim, child: child);
                },
              ),
            ),
            icon: const Icon(Icons.notifications_none),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: tabs[_index],
      ),
      floatingActionButton: GlobalSosIndicator(
        onTap: () {
          setState(() => _index = 2); // Switch to SOS Tab
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.sos_outlined),
            selectedIcon: Icon(Icons.sos),
            label: 'SOS',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment),
            label: 'Tasks',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class CoordinatorAppShell extends StatefulWidget {
  const CoordinatorAppShell({super.key, required this.api, required this.user});

  final ApiClient api;
  final AppUser user;

  @override
  State<CoordinatorAppShell> createState() => _CoordinatorAppShellState();
}

class _CoordinatorAppShellState extends State<CoordinatorAppShell> {
  int _index = 0;
  int _operationsTabIndex = 0;
  final ValueNotifier<int> _refreshNotifier = ValueNotifier(0);

  static const _titles = ['Dashboard', 'Map', 'Operations', 'SOS', 'Profile'];

  @override
  Widget build(BuildContext context) {
    final tabs = [
      CoordinatorDashboardTab(
        key: ValueKey('c_dash_${_refreshNotifier.value}'),
        api: widget.api,
        user: widget.user,
        onNavigate: (index) {
          if (index >= 10) {
            // sub-navigation to operations
            setState(() {
              _index = 2; // Operations tab
              _operationsTabIndex = index - 10;
            });
          } else {
            // Adjust index if navigating to something after the removed Alerts tab
            // Original: 0:Dashboard, 1:Map, 2:Operations, 3:Alerts, 4:SOS, 5:Profile
            // New: 0:Dashboard, 1:Map, 2:Operations, 3:SOS, 4:Profile
            int targetIndex = index;
            if (index > 3) targetIndex = index - 1;
            setState(() => _index = targetIndex);
          }
        },
      ),
      MapTab(key: ValueKey('c_map_${_refreshNotifier.value}'), api: widget.api),
      CoordinatorOperationsTab(
        key: ValueKey('c_ops_${_operationsTabIndex}_${_refreshNotifier.value}'),
        api: widget.api,
        initialTabIndex: _operationsTabIndex,
      ),
      CombinedSosTab(
        key: ValueKey('c_sos_${_refreshNotifier.value}'),
        api: widget.api,
        user: widget.user,
      ),
      ProfileTab(
        key: ValueKey('c_prof_${_refreshNotifier.value}'),
        api: widget.api,
        user: widget.user,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 24, // spacing horizontally for header
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'lib/assets/favicon.png',
                width: 28,
                height: 28,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _titles[_index],
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            const _RoleChip(label: 'COORDINATOR', color: AppColors.infoBlue),
          ],
        ),
        actions: [
          _RefreshControl(
            onRefresh: () {
              setState(() => _refreshNotifier.value++);
            },
          ),
          IconButton(
            onPressed: () => Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (ctx, anim, secondaryAnim) =>
                    NotificationsTab(api: widget.api, user: widget.user),
                transitionsBuilder: (ctx, anim, secondaryAnim, child) {
                  return FadeTransition(opacity: anim, child: child);
                },
              ),
            ),
            icon: const Icon(Icons.notifications_none),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: tabs[_index],
      ),
      floatingActionButton: GlobalSosIndicator(
        onTap: () {
          setState(() => _index = 3); // Switch to SOS Tab
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.admin_panel_settings_outlined),
            selectedIcon: Icon(Icons.admin_panel_settings),
            label: 'Operations',
          ),
          NavigationDestination(
            icon: Icon(Icons.sos_outlined),
            selectedIcon: Icon(Icons.sos),
            label: 'SOS',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _RefreshControl extends StatefulWidget {
  const _RefreshControl({required this.onRefresh});
  final VoidCallback onRefresh;

  @override
  State<_RefreshControl> createState() => _RefreshControlState();
}

class _RefreshControlState extends State<_RefreshControl>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _handle() {
    _ctrl.forward(from: 0);
    widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _ctrl,
      child: IconButton(onPressed: _handle, icon: const Icon(Icons.refresh)),
    );
  }
}
