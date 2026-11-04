import 'package:flutter/foundation.dart';

import 'library_state.dart';
import 'network_status.dart';

/// Stable page identities: changing dock membership never renumbers the pages
/// or disposes their reading/search/scroll state.
class HomeNavigation extends ChangeNotifier {
  HomeNavigation(this.preferences, this.network) {
    preferences.navigationChanges.addListener(_changed);
    network?.addListener(_changed);
    _value = _read();
  }

  final LibraryState preferences;
  final NetworkStatus? network;
  late ({bool localReader, bool cachedShelf, bool combinedShelf}) _value;

  ({bool localReader, bool cachedShelf, bool combinedShelf}) _read() => (
    localReader: preferences.localReaderMode,
    cachedShelf: preferences.adaptWhenOffline && (network?.offline ?? false),
    combinedShelf: preferences.combinedShelf,
  );

  bool get cachedShelf => _value.cachedShelf;
  bool get localReader => _value.localReader;
  bool get combinedShelf => _value.combinedShelf;
  bool get readableShelfOnly => cachedShelf || localReader;
  /// The library ships without the online discovery feed: every book comes in
  /// through the Wenku8 source or a local file, so the dock only keeps the
  /// shelf and the settings page. The other page identities stay allocated so
  /// their state (and any deep link) still resolves.
  List<int> get tabs => const [2, 3];

  int destination(int current) => tabs.contains(current)
      ? current
      : localReader
      ? combinedShelf
            ? 1
            : 2
      : 1;

  void _changed() {
    final next = _read();
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    preferences.navigationChanges.removeListener(_changed);
    network?.removeListener(_changed);
    super.dispose();
  }
}
