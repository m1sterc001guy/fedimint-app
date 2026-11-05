import 'dart:async';

import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/screens/statecoins/statecoin_widgets.dart';
import 'package:ecashapp/statechain.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/foundation.dart';

/// A federation's statecoins, for the dashboard's Statecoin tab. While
/// started, it claims coins sent to us and reloads the list every few
/// seconds, so incoming coins and status changes show up on their own.
class StatecoinWallet extends ChangeNotifier {
  static const _refreshInterval = Duration(seconds: 3);

  final FederationSelector fed;

  /// Called with the number of coins a refresh claimed.
  final void Function(int count) onClaimed;

  StatecoinWallet({required this.fed, required this.onClaimed});

  List<Statecoin>? _coins;
  Timer? _timer;
  bool _listing = false;
  bool _claiming = false;
  bool _disposed = false;

  /// A coin that cannot be claimed fails again on every refresh; log it once.
  final Set<String> _loggedClaimFailures = {};

  /// The coins we hold first, then the ones we sent, pegged out or exited.
  /// Null until first loaded.
  List<Statecoin>? get coins => _coins;

  /// Coins that can be sent, pegged out or exited.
  List<Statecoin> get spendable => [
    for (final coin in _coins ?? const <Statecoin>[])
      if (coin.isOwned && coin.status == StatecoinStatus.active) coin,
  ];

  BigInt get spendableMsats => spendable.fold(
    BigInt.zero,
    (sum, coin) => sum + (coin.amountSats ?? BigInt.zero) * BigInt.from(1000),
  );

  /// The federation could not be reached on the last refresh, so statuses are
  /// the last ones it reported, corrected by what the chain shows.
  bool get federationStale =>
      _coins?.any((coin) => coin.federationStale) ?? false;

  void start() {
    _timer ??= Timer.periodic(_refreshInterval, (_) => refresh());
    refresh();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Claims coins sent to us and reloads the list. Claiming needs the
  /// federation and listing does not, so the claim runs on its own: an
  /// unreachable federation must not hold up the coins we already have.
  Future<void> refresh() async {
    unawaited(_claim());
    await _list();
  }

  Future<void> _list() async {
    if (_listing) return;
    _listing = true;

    try {
      final coins = await statechainList(federationId: fed.federationId);
      final sorted = [
        ...coins.where((coin) => coin.isHeld),
        ...coins.where((coin) => !coin.isHeld),
      ];
      if (_disposed || listEquals(sorted, _coins)) return;
      _coins = sorted;
      notifyListeners();
    } catch (e) {
      AppLogger.instance.warn('Could not load statecoins: $e');
    } finally {
      _listing = false;
    }
  }

  Future<void> _claim() async {
    if (_claiming) return;
    _claiming = true;

    final StatecoinClaim claim;
    try {
      claim = await statechainClaim(federationId: fed.federationId);
    } catch (e) {
      AppLogger.instance.warn('Could not claim statecoins: $e');
      return;
    } finally {
      _claiming = false;
    }

    for (final failure in claim.failed) {
      if (_loggedClaimFailures.add(failure)) {
        AppLogger.instance.error('Could not claim statecoin $failure');
      }
    }

    if (claim.claimed.isNotEmpty && !_disposed) {
      onClaimed(claim.claimed.length);
      await _list();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
