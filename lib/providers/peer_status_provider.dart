import 'dart:async';

import 'package:ecashapp/lib.dart' as rust_lib;
import 'package:ecashapp/lib.dart' show FederationId;
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/foundation.dart';

/// Provider for real-time peer connection status across all federations.
///
/// This provider manages stream subscriptions to peer status updates from Rust
/// and provides methods for widgets to check if peers are online.
class PeerStatusProvider extends ChangeNotifier {
  /// Map of federation ID string -> Map of peer ID -> online status
  final Map<String, Map<int, bool>> _peerStatus = {};

  /// Map of federation ID string -> peer names (for display purposes)
  final Map<String, Map<int, String>> _peerNames = {};

  /// Active stream subscriptions per federation
  final Map<String, StreamSubscription<FederationPeerStatus>> _subscriptions =
      {};

  /// Check if a specific peer is online
  bool isPeerOnline(String federationIdStr, int peerId) {
    return _peerStatus[federationIdStr]?[peerId] ?? false;
  }

  /// Get all peer statuses for a federation
  /// Returns null if not yet subscribed/loaded
  Map<int, bool>? getPeerStatus(String federationIdStr) {
    return _peerStatus[federationIdStr];
  }

  /// Get the peer name for a specific peer
  String? getPeerName(String federationIdStr, int peerId) {
    return _peerNames[federationIdStr]?[peerId];
  }

  /// Count online peers for a federation
  /// Returns 0 if federation not found or not yet loaded
  int onlinePeerCount(String federationIdStr) {
    final status = _peerStatus[federationIdStr];
    if (status == null) return 0;
    return status.values.where((online) => online).length;
  }

  /// Get total peer count for a federation
  /// Returns 0 if federation not found or not yet loaded
  int totalPeerCount(String federationIdStr) {
    return _peerStatus[federationIdStr]?.length ?? 0;
  }

  /// Check if all peers are online for a federation
  bool allPeersOnline(String federationIdStr) {
    final status = _peerStatus[federationIdStr];
    if (status == null || status.isEmpty) return false;
    return status.values.every((online) => online);
  }

  /// Check if we have status data for a federation
  bool hasStatusFor(String federationIdStr) {
    return _peerStatus.containsKey(federationIdStr);
  }

  /// Subscribe to peer status updates for a federation.
  /// Call this when a federation is loaded/joined.
  Future<void> subscribeToFederation(FederationId federationId) async {
    final federationIdStr = await rust_lib.federationIdToString(
      federationId: federationId,
    );

    // Don't subscribe twice
    if (_subscriptions.containsKey(federationIdStr)) {
      AppLogger.instance.info(
        'PeerStatusProvider: Already subscribed to $federationIdStr',
      );
      return;
    }

    AppLogger.instance.info(
      'PeerStatusProvider: Subscribing to peer status for $federationIdStr',
    );

    try {
      final stream = rust_lib.subscribePeerStatus(federationId: federationId);

      final subscription = stream.listen(
        (status) {
          _handlePeerStatusUpdate(federationIdStr, status);
        },
        onError: (error) {
          AppLogger.instance.error(
            'PeerStatusProvider: Error in peer status stream for $federationIdStr: $error',
          );
        },
        onDone: () {
          AppLogger.instance.info(
            'PeerStatusProvider: Peer status stream closed for $federationIdStr',
          );
          _subscriptions.remove(federationIdStr);
        },
      );

      _subscriptions[federationIdStr] = subscription;
    } catch (e) {
      AppLogger.instance.error(
        'PeerStatusProvider: Failed to subscribe to peer status for $federationIdStr: $e',
      );
    }
  }

  /// Handle a peer status update from the stream
  void _handlePeerStatusUpdate(
    String federationIdStr,
    FederationPeerStatus status,
  ) {
    final statusMap = <int, bool>{};
    final namesMap = <int, String>{};

    for (final peer in status.peers) {
      statusMap[peer.peerId] = peer.online;
      namesMap[peer.peerId] = peer.name;
    }

    final hasChanged =
        !mapEquals(_peerStatus[federationIdStr], statusMap) ||
        !mapEquals(_peerNames[federationIdStr], namesMap);

    if (hasChanged) {
      _peerStatus[federationIdStr] = statusMap;
      _peerNames[federationIdStr] = namesMap;
      notifyListeners();
    }
  }

  /// Unsubscribe from peer status updates for a federation.
  /// Call this when leaving a federation.
  Future<void> unsubscribeFromFederation(FederationId federationId) async {
    final federationIdStr = await rust_lib.federationIdToString(
      federationId: federationId,
    );

    unsubscribeFromFederationByString(federationIdStr);
  }

  /// Unsubscribe using the string form of federation ID
  void unsubscribeFromFederationByString(String federationIdStr) {
    final subscription = _subscriptions.remove(federationIdStr);
    if (subscription != null) {
      subscription.cancel();
      AppLogger.instance.info(
        'PeerStatusProvider: Unsubscribed from $federationIdStr',
      );
    }

    _peerStatus.remove(federationIdStr);
    _peerNames.remove(federationIdStr);
    notifyListeners();
  }

  /// Subscribe to all federations
  Future<void> subscribeToAllFederations(
    List<FederationSelector> federations,
  ) async {
    for (final fed in federations) {
      await subscribeToFederation(fed.federationId);
    }
  }

  @override
  void dispose() {
    // Cancel all subscriptions
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _peerStatus.clear();
    _peerNames.clear();
    super.dispose();
  }
}
