import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/recovery_progress.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/ln_address_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';

import 'package:ecashapp/lib.dart';
import 'package:ecashapp/ln_address.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/number_pad.dart';
import 'package:ecashapp/screens/lightning_send/recipient_entry.dart';
import 'package:ecashapp/screens/transactions_screen.dart';
import 'package:ecashapp/onchain_receive.dart';
import 'package:ecashapp/scan.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/models.dart';

import 'package:ecashapp/screens/federation_expiry_screen.dart';
import 'package:ecashapp/screens/my_wallet_screen.dart';
import 'package:ecashapp/screens/statecoins/statecoin_deposit.dart';
import 'package:ecashapp/screens/statecoins/statecoin_details.dart';
import 'package:ecashapp/screens/statecoins/statecoin_list.dart';
import 'package:ecashapp/screens/statecoins/statecoin_receive.dart';
import 'package:ecashapp/screens/statecoins/statecoin_wallet.dart';
import 'package:ecashapp/widgets/dashboard_balance.dart';
import 'package:ecashapp/widgets/empty_transactions.dart';
import 'package:ecashapp/widgets/federation_expiry_banner.dart';
import 'package:ecashapp/widgets/glass_nav_bar.dart';
import 'package:ecashapp/widgets/leave_federation_dialog.dart';
import 'package:ecashapp/widgets/pending_deposit_item.dart';
import 'package:ecashapp/widgets/transaction_item.dart';

class Dashboard extends StatefulWidget {
  final FederationSelector fed;
  final bool recovering;
  final VoidCallback onLeaveFederation;

  /// Selects a freshly joined federation. Needed here because the shutdown
  /// details screen lets the user join the announced successor.
  final void Function(FederationSelector fed, bool recovering) onJoin;

  const Dashboard({
    super.key,
    required this.fed,
    required this.recovering,
    required this.onLeaveFederation,
    required this.onJoin,
  });

  @override
  _DashboardState createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  BigInt? balanceMsats;
  bool isLoadingBalance = true;
  late bool recovering;

  /// Recovery progress per payment type. Keeping one entry per tab stops a
  /// tab whose modules report nothing from showing the previously selected
  /// tab's bar.
  final Map<PaymentType, double> _recoveryProgress = {};
  PaymentType _selectedPaymentType = PaymentType.lightning;
  Map<FiatCurrency, int> _btcPrices = {};
  bool _isLoadingPrices = false;
  bool _pricesFailed = false;
  VoidCallback? _pendingAction;
  LightningAddressConfig? _lnAddressConfig;

  /// The Statecoin tab follows the payment type tabs, on federations that
  /// run the statechain module.
  bool _statechainSupported = false;
  bool _statecoinTab = false;
  late final StatecoinWallet _statecoins;

  /// Guardian-announced shutdown, read from the cached federation meta. Either
  /// being set puts the warning banner under the balance.
  BigInt? _expiryTimestamp;
  String? _successorInvite;
  bool get _isShuttingDown =>
      _expiryTimestamp != null || _successorInvite != null;

  /// Once the guardians have set a shutdown date, taking in more funds only
  /// deepens the hole the user has to dig out of; receiving is closed.
  bool get _receiveDisabled => _expiryTimestamp != null;

  List<Transaction> _recentTransactions = [];
  bool _isLoadingTransactions = true;

  final ScrollController _scrollController = ScrollController();
  static const double _headerMinExtent = 64.0;

  /// At rest the balance gets this share of the visible screen, with the
  /// first transactions peeking below it.
  static const double _headerExpandedFraction = 0.6;
  static const double _headerMinExpandedExtent = 210.0;
  bool _isUserDragScroll = false;

  final Map<String, DepositEventKind> _depositMap = {};
  late final StreamSubscription<DepositEventKind> _depositSubscription;

  late Stream<MultimintEvent> events;
  late StreamSubscription<MultimintEvent> _subscription;

  @override
  void initState() {
    super.initState();
    recovering = widget.recovering;
    _loadBalance();
    _loadBtcPrices();
    _loadLightningAddress();
    _loadFederationMeta();
    _loadRecentTransactions();
    _loadStatechainSupport();
    _statecoins = StatecoinWallet(
      fed: widget.fed,
      onClaimed: _onStatecoinsClaimed,
    )..addListener(_onStatecoinsChanged);

    final depositEvents =
        subscribeDeposits(
          federationId: widget.fed.federationId,
        ).asBroadcastStream();

    _depositSubscription = depositEvents.listen((e) {
      String txOutpoint;
      switch (e) {
        case DepositEventKind_Mempool(field0: final evt):
          txOutpoint = evt.outpoint;
        case DepositEventKind_AwaitingConfs(field0: final evt):
          txOutpoint = evt.outpoint;
        case DepositEventKind_Confirmed(field0: final evt):
          txOutpoint = evt.outpoint;
        case DepositEventKind_Claimed(field0: final evt):
          txOutpoint = evt.outpoint;
      }
      if (!mounted) return;
      if (e is DepositEventKind_Claimed) {
        setState(() => _depositMap.remove(txOutpoint));
        // Delay to ensure the claimed deposit is in the operation log
        Timer(const Duration(milliseconds: 100), () {
          if (mounted) {
            _loadBalance();
            _loadRecentTransactions();
          }
        });
      } else {
        setState(() => _depositMap[txOutpoint] = e);
      }
    });

    events = subscribeMultimintEvents().asBroadcastStream();
    _subscription = events.listen((event) async {
      if (event is MultimintEvent_Lightning) {
        final ln = event.field0.$2;
        if (ln is LightningEventKind_InvoicePaid) {
          final federationIdString = await federationIdToString(
            federationId: event.field0.$1,
          );
          final selectorIdString = await federationIdToString(
            federationId: widget.fed.federationId,
          );
          if (federationIdString == selectorIdString) {
            _loadBalance();
            _loadRecentTransactions();
          }
        } else if (ln is LightningEventKind_PaymentSent) {
          final federationIdString = await federationIdToString(
            federationId: event.field0.$1,
          );
          final selectorIdString = await federationIdToString(
            federationId: widget.fed.federationId,
          );
          if (federationIdString == selectorIdString) {
            _loadBalance();
            _loadRecentTransactions();
          }
        }
      } else if (event is MultimintEvent_RecoveryDone) {
        final recoveredFedId = event.field0;
        final currFederationId = await federationIdToString(
          federationId: widget.fed.federationId,
        );
        if (currFederationId == recoveredFedId) {
          if (!mounted) return;
          setState(() => recovering = false);
          _loadBalance();
          _loadLightningAddress();
          _loadRecentTransactions();
        }
      } else if (event is MultimintEvent_Ecash) {
        final federationIdString = await federationIdToString(
          federationId: event.field0.$1,
        );
        final selectorIdString = await federationIdToString(
          federationId: widget.fed.federationId,
        );
        if (federationIdString == selectorIdString) {
          _loadBalance();
          _loadRecentTransactions();
        }
      } else if (event is MultimintEvent_MetaUpdated) {
        final selectorIdString = await federationIdToString(
          federationId: widget.fed.federationId,
        );
        if (event.field0 == selectorIdString) {
          _loadFederationMeta();
        }
      }
    });
  }

  @override
  void dispose() {
    _depositSubscription.cancel();
    _subscription.cancel();
    _scrollController.dispose();
    _statecoins.dispose();
    super.dispose();
  }

  /// Header height at rest, excluding the shutdown banner. The body runs
  /// under the nav bar, so the fraction applies to the part left visible.
  double _expandedExtent(double viewportHeight) => max(
    _headerMinExpandedExtent,
    (viewportHeight - GlassNavBar.bodyInset(context)) * _headerExpandedFraction,
  );

  double _collapseRange(double viewportHeight) =>
      _expandedExtent(viewportHeight) - _headerMinExtent;

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _isUserDragScroll = notification.dragDetails != null;
      return false;
    }
    if (notification is! ScrollEndNotification) return false;
    if (!_isUserDragScroll) return false;
    _isUserDragScroll = false;
    if (!_scrollController.hasClients) return false;
    final position = _scrollController.position;
    final collapseRange = _collapseRange(position.viewportDimension);
    if (position.maxScrollExtent < collapseRange) return false;
    final offset = position.pixels;
    if (offset <= 0 || offset >= collapseRange) return false;
    final target = offset < collapseRange / 2 ? 0.0 : collapseRange;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    });
    return false;
  }

  void _scheduleAction(VoidCallback action) {
    setState(() => _pendingAction = action);
  }

  Future<void> _loadBalance() async {
    if (recovering) return;
    final BigInt bal;
    try {
      bal = await balance(federationId: widget.fed.federationId);
    } catch (e) {
      // Expected when the federation was left while this screen is still up,
      // and possible transiently while a module is starting. Keep the last
      // known figure rather than showing a misleading zero.
      AppLogger.instance.warn('Could not load balance: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      balanceMsats = bal;
      isLoadingBalance = false;
    });
  }

  Future<void> _loadBtcPrices() async {
    setState(() {
      _isLoadingPrices = true;
      _pricesFailed = false;
    });

    final prices = await fetchAllBtcPrices();

    if (!mounted) return;
    setState(() {
      _btcPrices = prices;
      _isLoadingPrices = false;
      _pricesFailed = prices.isEmpty;
    });
  }

  Future<void> _loadLightningAddress() async {
    final config = await getLnAddressConfig(
      federationId: widget.fed.federationId,
    );
    if (!mounted) return;
    setState(() {
      _lnAddressConfig = config;
    });
  }

  /// Reads the shutdown announcement off the cached meta. The background cache
  /// task keeps that fresh and publishes MetaUpdated when the guardians change
  /// it, so this is a local read that never waits on a guardian.
  Future<void> _loadFederationMeta() async {
    final FederationMeta meta;
    try {
      meta = await getFederationMeta(federationId: widget.fed.federationId);
    } catch (e) {
      // Expected when the federation was left while this screen is still up.
      AppLogger.instance.warn('Could not load federation meta: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _expiryTimestamp = meta.expiryTimestamp;
      _successorInvite = meta.successorInvite;
    });
  }

  void _openShutdownDetails() {
    final lnAddress = _lnAddressConfig;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => FederationExpiryScreen(
              federationName: widget.fed.federationName,
              expiryTimestamp: _expiryTimestamp,
              successorInvite: _successorInvite,
              balanceMsats: balanceMsats,
              lightningAddress:
                  lnAddress != null
                      ? '${lnAddress.username}@${lnAddress.domain}'
                      : null,
              loadBalance: () => balance(federationId: widget.fed.federationId),
              loadLightningAddress: _lightningAddressString,
              onSendOnchain: _openOnchainSend,
              onOpenLightningAddress: _openLightningAddressScreen,
              onJoin: widget.onJoin,
              onLeaveFederation: _confirmLeaveFederation,
            ),
      ),
    ).then((_) {
      // The checklist may have moved the balance or dropped the address.
      // It may also have left the federation, in which case this dashboard
      // is on its way out and there is nothing left to reload for.
      if (!mounted) return;
      _loadBalance();
      _loadLightningAddress();
      _loadRecentTransactions();
    });
  }

  Future<String?> _lightningAddressString() async {
    final config = await getLnAddressConfig(
      federationId: widget.fed.federationId,
    );
    return config == null ? null : '${config.username}@${config.domain}';
  }

  /// The on-chain send flow, pushed above whatever is showing so the user
  /// returns to where they started once it is done.
  Future<void> _openOnchainSend() => Navigator.push(
    context,
    MaterialPageRoute(
      builder:
          (_) => NumberPad(
            fed: widget.fed,
            paymentType: PaymentType.onchain,
            btcPrices: _btcPrices,
            onWithdrawCompleted: null,
          ),
    ),
  );

  /// The Lightning Address screen with this federation already selected. The
  /// screen pops itself after a change, and the caller re-reads the address
  /// then, so no app-level refresh is needed here.
  Future<void> _openLightningAddressScreen() async {
    final feds = await federations();
    final federationId = await federationIdToString(
      federationId: widget.fed.federationId,
    );
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => LightningAddressScreen(
              federations: feds,
              initialFederationId: federationId,
              onLnAddressChanged: (_, _) {},
            ),
      ),
    );
  }

  Future<void> _confirmLeaveFederation() => showLeaveFederationDialog(
    context,
    fed: widget.fed,
    onLeaveFederation: widget.onLeaveFederation,
  );

  List<String> _getModulesForPaymentType() {
    switch (_selectedPaymentType) {
      case PaymentType.lightning:
        return ['ln', 'lnv2'];
      case PaymentType.onchain:
        return ['wallet', 'walletv2'];
      case PaymentType.ecash:
        return ['mint', 'mintv2'];
    }
  }

  Future<void> _loadRecentTransactions() async {
    if (recovering) return;
    final List<Transaction> txs;
    try {
      txs = await transactions(
        federationId: widget.fed.federationId,
        modules: _getModulesForPaymentType(),
      );
    } catch (e) {
      // Expected when the federation was left while this screen is still up:
      // the leave dialog pops its routes before the app root has swapped the
      // dashboard out, so a reload can still land here. Keep the last list.
      AppLogger.instance.warn('Could not load transactions: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _recentTransactions = txs.take(20).toList();
      _isLoadingTransactions = false;
    });
  }

  /// Pull-to-refresh. Prices are left out so the fiat figure doesn't flash its
  /// loading state on every pull.
  Future<void> _refresh() => Future.wait([
    _loadBalance(),
    _loadRecentTransactions(),
    if (_statecoinTab) _statecoins.refresh(),
  ]);

  void _onSendPressed() async {
    if (_selectedPaymentType == PaymentType.lightning) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => RecipientEntry(fed: widget.fed, btcPrices: _btcPrices),
        ),
      );
    } else if (_selectedPaymentType == PaymentType.ecash ||
        _selectedPaymentType == PaymentType.onchain) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => NumberPad(
                fed: widget.fed,
                paymentType: _selectedPaymentType,
                btcPrices: _btcPrices,
                onWithdrawCompleted: null,
              ),
        ),
      );
    }
    _loadBalance();
    _loadRecentTransactions();
  }

  /// Explains why receiving is closed, if it is.
  bool _rejectReceive() {
    if (!_receiveDisabled) return false;
    ToastService().show(
      message: context.l10n.federationExpiryReceiveDisabled,
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: const Icon(Icons.error),
    );
    return true;
  }

  void _onReceivePressed() async {
    if (_rejectReceive()) return;
    if (_selectedPaymentType == PaymentType.lightning) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => NumberPad(
                fed: widget.fed,
                paymentType: _selectedPaymentType,
                btcPrices: _btcPrices,
                onWithdrawCompleted: null,
              ),
        ),
      );
    } else if (_selectedPaymentType == PaymentType.onchain) {
      await showAppModalBottomSheet(
        context: context,
        childBuilder: () async {
          return OnChainReceiveContent(fed: widget.fed);
        },
        heightFactor: 0.8,
      );
    } else if (_selectedPaymentType == PaymentType.ecash) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => ScanQRPage(
                selectedFed: widget.fed,
                paymentType: _selectedPaymentType,
                onPay: (_, _) {},
              ),
        ),
      );
    }
    _loadBalance();
    _loadRecentTransactions();
  }

  Future<void> _loadStatechainSupport() async {
    final supported = await statechainSupported(
      federationId: widget.fed.federationId,
    );
    if (!mounted) return;
    setState(() => _statechainSupported = supported);
  }

  void _onStatecoinsChanged() {
    if (mounted) setState(() {});
  }

  void _onStatecoinsClaimed(int count) {
    if (!mounted) return;
    ToastService().show(
      message: context.l10n.statecoinReceived(count),
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: const Icon(Icons.call_received),
    );
  }

  Future<void> _openStatecoinSheet(Widget sheet) async {
    await showAppModalBottomSheet(
      context: context,
      fitContent: true,
      childBuilder: () async => sheet,
    );
    _statecoins.refresh();
  }

  void _onStatecoinReceive(Widget sheet) {
    if (_rejectReceive()) return;
    _openStatecoinSheet(sheet);
  }

  Future<void> _onStatecoinAction(StatecoinAction action) async {
    final coin = await pickStatecoin(context, _statecoins.spendable);
    if (coin == null || !mounted) return;
    await _openStatecoinSheet(
      StatecoinDetails(fed: widget.fed, coin: coin, action: action),
    );
  }

  List<SpeedDialChild> _statecoinMenu() => [
    SpeedDialChild(
      child: const Icon(Icons.add),
      label: context.l10n.statecoinDeposit,
      backgroundColor: _receiveDisabled ? Colors.grey : Colors.green,
      onTap:
          () => _scheduleAction(
            () => _onStatecoinReceive(StatecoinDepositSheet(fed: widget.fed)),
          ),
    ),
    SpeedDialChild(
      child: const Icon(Icons.download),
      label: context.l10n.receive,
      backgroundColor: _receiveDisabled ? Colors.grey : Colors.green,
      onTap:
          () => _scheduleAction(
            () => _onStatecoinReceive(StatecoinReceiveSheet(fed: widget.fed)),
          ),
    ),
    if (_statecoins.spendable.isNotEmpty) ...[
      SpeedDialChild(
        child: const Icon(Icons.upload),
        label: context.l10n.send,
        backgroundColor: Colors.blue,
        onTap:
            () =>
                _scheduleAction(() => _onStatecoinAction(StatecoinAction.send)),
      ),
      SpeedDialChild(
        child: const Icon(Icons.logout),
        label: context.l10n.statecoinPegOut,
        backgroundColor: Colors.orange,
        onTap:
            () => _scheduleAction(
              () => _onStatecoinAction(StatecoinAction.pegOut),
            ),
      ),
      SpeedDialChild(
        child: const Icon(Icons.lock_clock),
        label: context.l10n.statecoinExit,
        backgroundColor: Colors.redAccent,
        onTap:
            () =>
                _scheduleAction(() => _onStatecoinAction(StatecoinAction.exit)),
      ),
    ],
  ];

  List<Widget> _statecoinSlivers(double bottomInset) {
    final coins = _statecoins.coins;

    if (coins == null) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }

    if (coins.isEmpty) {
      return [
        SliverPadding(
          padding: EdgeInsets.only(bottom: bottomInset),
          sliver: const SliverToBoxAdapter(child: StatecoinEmptyState()),
        ),
      ];
    }

    return [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => StatecoinItem(
            coin: coins[index],
            onTap:
                () => _openStatecoinSheet(
                  StatecoinDetails(fed: widget.fed, coin: coins[index]),
                ),
          ),
          childCount: coins.length,
        ),
      ),
    ];
  }

  void _openMyWallet() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => MyWalletScreen(
              fed: widget.fed,
              onAddressesUpdated: _loadBalance,
              onLeaveFederation: widget.onLeaveFederation,
            ),
      ),
    );
  }

  void _openAllTransactions() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => TransactionsScreen(
              fed: widget.fed,
              paymentType: _selectedPaymentType,
              onClaimed: () {
                _loadBalance();
                _loadRecentTransactions();
              },
              onWithdrawCompleted: () => _loadRecentTransactions(),
            ),
      ),
    ).then((_) {
      _loadRecentTransactions();
    });
  }

  Future<void> _loadProgress(PaymentType paymentType) async {
    if (recovering) {
      final progress = await getModuleRecoveryProgress(
        federationId: widget.fed.federationId,
        recoveryModule: paymentType.recoveryModule,
      );

      if (progress.$2 > 0) {
        double rawProgress = progress.$1.toDouble() / progress.$2.toDouble();
        setState(
          () => _recoveryProgress[paymentType] = rawProgress.clamp(0.0, 1.0),
        );
      }

      AppLogger.instance.info(
        "$paymentType progress: ${_recoveryProgress[paymentType] ?? 0.0} complete: ${progress.$1} total: ${progress.$2}",
      );
    }
  }

  List<DepositEventKind> get _pendingDeposits {
    if (_selectedPaymentType != PaymentType.onchain) return [];
    final pending = _depositMap.values.toList();
    pending.sort((a, b) {
      final aM = a is DepositEventKind_Mempool;
      final bM = b is DepositEventKind_Mempool;
      if (aM && !bM) return -1;
      if (!aM && bM) return 1;
      final na =
          a is DepositEventKind_AwaitingConfs ? a.field0.needed : BigInt.zero;
      final nb =
          b is DepositEventKind_AwaitingConfs ? b.field0.needed : BigInt.zero;
      return nb.compareTo(na);
    });
    return pending;
  }

  @override
  Widget build(BuildContext context) {
    // Zero when nothing is announced, so the header lays out exactly as before.
    final bannerExtent =
        _isShuttingDown ? federationExpiryBannerExtent(context) : 0.0;
    // The nav bar floats over the body, so scrollable content reserves room
    // to clear it.
    final bottomInset = GlassNavBar.bodyInset(context);
    return Scaffold(
      extendBody: true,
      floatingActionButton:
          recovering
              ? null
              : SpeedDial(
                icon: Icons.add,
                activeIcon: Icons.close,
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                onClose: () async {
                  if (_pendingAction != null) {
                    await Future.delayed(const Duration(milliseconds: 200));
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _pendingAction!();
                      _pendingAction = null;
                    });
                  }
                },
                children:
                    _statecoinTab
                        ? _statecoinMenu()
                        : [
                          SpeedDialChild(
                            child: const Icon(Icons.download),
                            label: context.l10n.receive,
                            // Greyed rather than hidden: the tap explains why.
                            backgroundColor:
                                _receiveDisabled ? Colors.grey : Colors.green,
                            onTap: () => _scheduleAction(_onReceivePressed),
                          ),
                          if (balanceMsats != null &&
                              balanceMsats! > BigInt.zero) ...[
                            SpeedDialChild(
                              child: const Icon(Icons.upload),
                              label: context.l10n.send,
                              backgroundColor: Colors.blue,
                              onTap: () => _scheduleAction(_onSendPressed),
                            ),
                          ],
                        ],
              ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child:
            recovering
                ? Column(
                  children: [
                    const Spacer(),
                    DashboardBalance(
                      balanceMsats: balanceMsats,
                      isLoading: isLoadingBalance,
                      recovering: recovering,
                      btcPrices: _btcPrices,
                      isLoadingPrices: _isLoadingPrices,
                      pricesFailed: _pricesFailed,
                    ),
                    if (_isShuttingDown)
                      FederationExpiryBanner(
                        expiryTimestamp: _expiryTimestamp,
                        onTap: _openShutdownDetails,
                      ),
                    const SizedBox(height: 24),
                    RecoveryStatus(
                      key: ValueKey(_selectedPaymentType),
                      paymentType: _selectedPaymentType,
                      fed: widget.fed,
                      initialProgress:
                          _recoveryProgress[_selectedPaymentType] ?? 0.0,
                    ),
                    const Spacer(),
                    SizedBox(height: bottomInset),
                  ],
                )
                : RefreshIndicator(
                  onRefresh: _refresh,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final viewportHeight = constraints.maxHeight;
                      final collapseRange = _collapseRange(viewportHeight);
                      return NotificationListener<ScrollNotification>(
                        onNotification: _handleScrollNotification,
                        child: CustomScrollView(
                          controller: _scrollController,
                          // Lets the pull-to-refresh work when the list is too
                          // short to scroll.
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            SliverPersistentHeader(
                              pinned: true,
                              delegate: _DashboardBalanceHeader(
                                minExtent: _headerMinExtent + bannerExtent,
                                maxExtent:
                                    _expandedExtent(viewportHeight) +
                                    bannerExtent,
                                expiryTimestamp: _expiryTimestamp,
                                successorInvite: _successorInvite,
                                bannerExtent: bannerExtent,
                                onShutdownTap: _openShutdownDetails,
                                // Statecoins are not ecash: their tab shows
                                // what the wallet holds in them instead.
                                balanceMsats:
                                    _statecoinTab
                                        ? _statecoins.spendableMsats
                                        : balanceMsats,
                                isLoading:
                                    _statecoinTab
                                        ? _statecoins.coins == null
                                        : isLoadingBalance,
                                recovering: recovering,
                                btcPrices: _btcPrices,
                                isLoadingPrices: _isLoadingPrices,
                                pricesFailed: _pricesFailed,
                                lnAddressConfig: _lnAddressConfig,
                                onLnAddressTap:
                                    _lnAddressConfig != null
                                        ? () => showLightningAddressDialog(
                                          context,
                                          _lnAddressConfig!.username,
                                          _lnAddressConfig!.domain,
                                          _lnAddressConfig!.lnurl,
                                        )
                                        : null,
                                onWalletTap: _openMyWallet,
                                backgroundColor:
                                    Theme.of(context).scaffoldBackgroundColor,
                              ),
                            ),
                            if (widget.fed.network != null &&
                                widget.fed.network!.toLowerCase() != 'bitcoin')
                              SliverToBoxAdapter(
                                child: AnimatedBuilder(
                                  animation: _scrollController,
                                  builder: (context, child) {
                                    final offset =
                                        _scrollController.hasClients
                                            ? _scrollController.offset
                                            : 0.0;
                                    final t = (offset / collapseRange).clamp(
                                      0.0,
                                      1.0,
                                    );
                                    final opacity = (1.0 - t * 2.0).clamp(
                                      0.0,
                                      1.0,
                                    );
                                    return ClipRect(
                                      child: Align(
                                        alignment: Alignment.topCenter,
                                        heightFactor: 1.0 - t,
                                        child: Opacity(
                                          opacity: opacity,
                                          child: child,
                                        ),
                                      ),
                                    );
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 4.0),
                                    child: Text(
                                      context.l10n.testNetworkMessage,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall?.copyWith(
                                        color:
                                            Theme.of(
                                              context,
                                            ).colorScheme.secondary,
                                        fontStyle: FontStyle.italic,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              ),
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Row(
                                  children: [
                                    Text(
                                      _statecoinTab
                                          ? context.l10n.statecoins
                                          : context.l10n.recentActivity,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(color: Colors.grey),
                                    ),
                                    const Spacer(),
                                    // Keeps the row as tall as the button.
                                    if (_statecoinTab)
                                      const SizedBox(height: 48)
                                    else
                                      TextButton(
                                        onPressed: _openAllTransactions,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              context.l10n.viewAll,
                                              style: TextStyle(
                                                color:
                                                    Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                                fontSize: 13,
                                              ),
                                            ),
                                            const SizedBox(width: 2),
                                            Icon(
                                              Icons.chevron_right,
                                              size: 18,
                                              color:
                                                  Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 8),
                            ),
                            if (_statecoinTab)
                              ..._statecoinSlivers(bottomInset)
                            else if (_isLoadingTransactions &&
                                _pendingDeposits.isEmpty)
                              const SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(vertical: 32),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                              )
                            else if (_recentTransactions.isEmpty &&
                                _pendingDeposits.isEmpty)
                              SliverPadding(
                                padding: EdgeInsets.only(bottom: bottomInset),
                                sliver: SliverToBoxAdapter(
                                  child: EmptyTransactionsState(
                                    paymentType: _selectedPaymentType,
                                    onReceivePressed: _onReceivePressed,
                                  ),
                                ),
                              )
                            else
                              SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    if (index < _pendingDeposits.length) {
                                      return PendingDepositItem(
                                        event: _pendingDeposits[index],
                                        fed: widget.fed,
                                      );
                                    }
                                    final tx =
                                        _recentTransactions[index -
                                            _pendingDeposits.length];
                                    return TransactionItem(
                                      tx: tx,
                                      fed: widget.fed,
                                    );
                                  },
                                  childCount:
                                      _pendingDeposits.length +
                                      _recentTransactions.length,
                                ),
                              ),
                            // Pads short lists so the header can still collapse
                            // fully and the snap logic has room to work.
                            SliverLayoutBuilder(
                              builder:
                                  (context, constraints) => SliverToBoxAdapter(
                                    child: SizedBox(
                                      height: max(
                                        bottomInset + 8,
                                        viewportHeight +
                                            collapseRange -
                                            constraints.precedingScrollExtent,
                                      ),
                                    ),
                                  ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
      ),
      bottomNavigationBar: GlassNavBar(
        currentIndex:
            _statecoinTab
                ? PaymentType.values.length
                : _selectedPaymentType.index,
        onTap: (index) async {
          if (index == PaymentType.values.length) {
            setState(() => _statecoinTab = true);
            _statecoins.start();
            return;
          }
          _statecoins.stop();
          await _loadProgress(PaymentType.values[index]);
          setState(() {
            _statecoinTab = false;
            _selectedPaymentType = PaymentType.values[index];
            _recentTransactions = [];
            _isLoadingTransactions = true;
          });
          _loadRecentTransactions();
        },
        items: [
          GlassNavBarItem(icon: Icons.flash_on, label: context.l10n.lightning),
          GlassNavBarItem(icon: Icons.link, label: context.l10n.onchain),
          GlassNavBarItem(
            icon: Icons.currency_bitcoin,
            label: context.l10n.ecash,
          ),
          // Hidden while recovering: the recovery view only covers the
          // payment types.
          if (_statechainSupported && !recovering)
            GlassNavBarItem(icon: Icons.toll, label: context.l10n.statecoin),
        ],
      ),
    );
  }
}

class _DashboardBalanceHeader extends SliverPersistentHeaderDelegate {
  @override
  final double minExtent;
  @override
  final double maxExtent;
  final BigInt? balanceMsats;
  final bool isLoading;
  final bool recovering;
  final Map<FiatCurrency, int> btcPrices;
  final bool isLoadingPrices;
  final bool pricesFailed;
  final LightningAddressConfig? lnAddressConfig;
  final VoidCallback? onLnAddressTap;
  final VoidCallback? onWalletTap;
  final Color backgroundColor;

  /// Guardian-announced shutdown. The banner shows when either is set.
  final BigInt? expiryTimestamp;
  final String? successorInvite;

  /// Vertical space reserved under the balance for the banner; both extents
  /// already include it, so the collapse range is unchanged. Zero without an
  /// announcement.
  final double bannerExtent;
  final VoidCallback onShutdownTap;

  _DashboardBalanceHeader({
    required this.minExtent,
    required this.maxExtent,
    required this.expiryTimestamp,
    required this.successorInvite,
    required this.bannerExtent,
    required this.onShutdownTap,
    required this.balanceMsats,
    required this.isLoading,
    required this.recovering,
    required this.btcPrices,
    required this.isLoadingPrices,
    required this.pricesFailed,
    required this.lnAddressConfig,
    required this.onLnAddressTap,
    required this.onWalletTap,
    required this.backgroundColor,
  });

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final range = maxExtent - minExtent;
    final t = (shrinkOffset / range).clamp(0.0, 1.0);
    final showBanner = expiryTimestamp != null || successorInvite != null;
    return ClipRect(
      child: SizedBox.expand(
        child: ColoredBox(
          color: backgroundColor,
          child: Stack(
            children: [
              // The balance keeps the space it had before; the banner is
              // anchored below it so it stays fully visible while the balance
              // collapses.
              Positioned.fill(
                bottom: bannerExtent,
                child: Padding(
                  padding: EdgeInsets.only(top: lerpDouble(48.0, 8.0, t)!),
                  child: DashboardBalance(
                    balanceMsats: balanceMsats,
                    isLoading: isLoading,
                    recovering: recovering,
                    btcPrices: btcPrices,
                    isLoadingPrices: isLoadingPrices,
                    pricesFailed: pricesFailed,
                    lnAddressConfig: lnAddressConfig,
                    onLnAddressTap: onLnAddressTap,
                    onWalletTap: onWalletTap,
                    collapseProgress: t,
                  ),
                ),
              ),
              if (showBanner)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: FederationExpiryBanner(
                    expiryTimestamp: expiryTimestamp,
                    onTap: onShutdownTap,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DashboardBalanceHeader oldDelegate) {
    return balanceMsats != oldDelegate.balanceMsats ||
        isLoading != oldDelegate.isLoading ||
        recovering != oldDelegate.recovering ||
        btcPrices != oldDelegate.btcPrices ||
        isLoadingPrices != oldDelegate.isLoadingPrices ||
        pricesFailed != oldDelegate.pricesFailed ||
        lnAddressConfig != oldDelegate.lnAddressConfig ||
        expiryTimestamp != oldDelegate.expiryTimestamp ||
        successorInvite != oldDelegate.successorInvite ||
        bannerExtent != oldDelegate.bannerExtent ||
        minExtent != oldDelegate.minExtent ||
        maxExtent != oldDelegate.maxExtent;
  }
}
