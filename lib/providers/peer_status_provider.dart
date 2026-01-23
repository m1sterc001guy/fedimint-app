import 'dart:async';

import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/foundation.dart';

class PeerStatusProvider extends ChangeNotifier {
  final Map<String, Map<int, bool>> _peerStatus = {};

  final Map<String, Map<int, String>> _peerNames = {};

  final Map<String, StreamSubscription<FederationPeerStatus>> _subscriptions =
      {};

  void printPeerStatus(FederationId federationId) async {
    final federationIdStr = await federationIdToString(
      federationId: federationId,
    );
    final statuses = _peerStatus[federationIdStr]!;
    //final names = _peerNames[federationId];

    AppLogger.instance.info("PeerStatus len: ${_peerStatus.length}");
    AppLogger.instance.info("PeerNames len: ${_peerNames.length}");

    bool? status = statuses[1];
    AppLogger.instance.info("Status for peer 1: $status");
  }

  Future<void> subscribeToFederation(FederationId federationId) async {
    //final federationIdStr = await federationIdToString(federationId: federationId);
    /*
    if (_subscriptions.containsKey(federationIdStr)) {
      AppLogger.instance.info("PeerStatusProvider: Already subscribed to federation");
      return;
    }
    */

    try {
      AppLogger.instance.info(
        "PeerStatusProvider: subscribing to peer status...",
      );
      final stream = subscribePeerStatus(federationId: federationId);

      final subscription = stream.listen(
        (event) async {
          AppLogger.instance.info(
            "PeerStatusProvider: received update, handling update",
          );
          //_handlePeerStatusUpdate(federationIdStr, event);
        },
        onError: (error) {
          AppLogger.instance.error(
            'PeerStatusProvider: Error in peer status stream: $error',
          );
        },
        onDone: () {
          AppLogger.instance.info(
            'PeerStatusProvider: Peer status stream closed',
          );
          //_subscriptions.remove(federationIdStr);
        },
      );

      //_subscriptions[federationIdStr] = subscription;
    } catch (e) {
      AppLogger.instance.error(
        "PeerStatusProvider: Failed to subscribe to peer status: $e",
      );
    }
  }

  void unsubscribeFromFederation(FederationId federationId) {
    final subscription = _subscriptions.remove(federationId);
    if (subscription != null) {
      subscription.cancel();
    }

    _peerStatus.remove(federationId);
    _peerNames.remove(federationId);
    notifyListeners();
  }

  void _handlePeerStatusUpdate(
    String federationIdStr,
    FederationPeerStatus status,
  ) {
    final statusMap = <int, bool>{};
    final namesMap = <int, String>{};

    for (final peer in status.peers) {
      bool online = peer.online;
      String name = peer.name;
      statusMap[peer.peerId] = online;
      namesMap[peer.peerId] = name;
      AppLogger.instance.info("UPDATING Name: $name Online: $online");
    }

    final hasChanged =
        !mapEquals(_peerStatus[federationIdStr], statusMap) ||
        !mapEquals(_peerNames[federationIdStr], namesMap);

    AppLogger.instance.info("hasChanged: $hasChanged");

    if (hasChanged) {
      _peerStatus[federationIdStr] = statusMap;
      _peerNames[federationIdStr] = namesMap;
      notifyListeners();
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
