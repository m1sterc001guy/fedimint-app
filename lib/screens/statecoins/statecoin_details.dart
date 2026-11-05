import 'dart:async';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/error_helper.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/screens/statecoins/statecoin_deposit.dart';
import 'package:ecashapp/screens/statecoins/statecoin_widgets.dart';
import 'package:ecashapp/statechain.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

enum _View { overview, fund, send, pegOut, exit }

/// A coin's signed backup transactions, or null if they cannot be loaded.
Future<StatecoinBackups?> loadStatecoinBackups(
  FederationSelector fed,
  String coinId,
) async {
  try {
    return await statechainBackups(
      federationId: fed.federationId,
      coinId: coinId,
    );
  } catch (e) {
    AppLogger.instance.warn('Could not load statecoin backups: $e');
    return null;
  }
}

/// What the dashboard's menu can open a statecoin's details with.
enum StatecoinAction { send, pegOut, exit }

/// A statecoin and what its owner can do with it.
class StatecoinDetails extends StatefulWidget {
  final FederationSelector fed;
  final Statecoin coin;

  /// Starts on this action instead of the overview.
  final StatecoinAction? action;

  const StatecoinDetails({
    super.key,
    required this.fed,
    required this.coin,
    this.action,
  });

  @override
  State<StatecoinDetails> createState() => _StatecoinDetailsState();
}

class _StatecoinDetailsState extends State<StatecoinDetails> {
  /// The peg-out transaction's on-chain fee, taken from the coin. Enough for
  /// its one input and one output at a few sats per vbyte.
  static const _defaultPegOutFeeSats = 1000;

  final _sendAddress = TextEditingController();
  final _pegOutAddress = TextEditingController();
  final _pegOutFee = TextEditingController(
    text: _defaultPegOutFeeSats.toString(),
  );

  late _View _view = switch (widget.action) {
    StatecoinAction.send => _View.send,
    StatecoinAction.pegOut => _View.pegOut,
    StatecoinAction.exit || null => _View.overview,
  };
  bool _busy = false;

  /// Our signed but unbroadcast backups, while the coin is ours and still
  /// held with the guardians. Completes with null if they cannot be loaded.
  Future<StatecoinBackups?>? _backups;

  Statecoin get _coin => widget.coin;

  @override
  void initState() {
    super.initState();
    if (_coin.isOwned &&
        (_coin.status == StatecoinStatus.unconfirmed ||
            _coin.status == StatecoinStatus.active)) {
      _backups = loadStatecoinBackups(widget.fed, _coin.coinId);
    }
    if (widget.action == StatecoinAction.exit) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _confirmExit());
    }
  }

  @override
  void dispose() {
    _sendAddress.dispose();
    _pegOutAddress.dispose();
    _pegOutFee.dispose();
    super.dispose();
  }

  /// Runs [action] with the buttons disabled, closing the sheet with
  /// [successMessage] once it succeeds.
  Future<void> _run(
    Future<void> Function() action,
    String successMessage,
  ) async {
    setState(() => _busy = true);

    try {
      await action();
      if (!mounted) return;
      ToastService().show(
        message: successMessage,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.check),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showErrorToast(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(
    () => statechainSend(
      federationId: widget.fed.federationId,
      coinId: _coin.coinId,
      address: _sendAddress.text.trim(),
    ),
    context.l10n.statecoinSent,
  );

  Future<void> _pegOut() => _run(
    () => statechainPegOut(
      federationId: widget.fed.federationId,
      coinId: _coin.coinId,
      address: _pegOutAddress.text.trim(),
      feeSats: BigInt.parse(_pegOutFee.text.trim()),
    ),
    context.l10n.statecoinPeggedOut,
  );

  Future<void> _confirmExit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(context.l10n.statecoinExit),
            content: Text(context.l10n.statecoinExitConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(context.l10n.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(context.l10n.confirm),
              ),
            ],
          ),
    );

    if (confirmed == true) await _exit();
  }

  /// Broadcasts the node transaction and has the app broadcast the exit
  /// transaction once its timelock expires. Both broadcasts tolerate the
  /// transaction being known already, so this also resumes an exit.
  Future<void> _exit() async {
    setState(() => _busy = true);

    try {
      await statechainExit(
        federationId: widget.fed.federationId,
        coinId: _coin.coinId,
      );
      if (!mounted) return;
      setState(() => _view = _View.exit);
    } catch (e) {
      if (mounted) showErrorToast(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final depositAddress = _coin.depositAddress;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: switch (_view) {
        _View.overview => _buildOverview(context),
        _View.fund when depositAddress != null => StatecoinFundForm(
          fed: widget.fed,
          coinId: _coin.coinId,
          address: depositAddress,
        ),
        _View.fund => _buildOverview(context),
        _View.send => _buildSend(context),
        _View.pegOut => _buildPegOut(context),
        _View.exit => StatecoinExitProgress(
          fed: widget.fed,
          coinId: _coin.coinId,
          timelock: _coin.exitTimelock,
        ),
      },
    );
  }

  Widget _buildOverview(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final fundingTxid = _coin.fundingTxid;
    final exitAddress = _coin.exitAddress;
    final exitTimelock = _coin.exitTimelock;
    final transfers = _coin.transfers;
    final backups = _backups;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _coin.formatAmount(context, bitcoinDisplay),
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _coin.describe(context),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 16),
        CopyableDetailRow(
          label: context.l10n.statecoinCoinId,
          value: _coin.coinId,
          abbreviate: true,
        ),
        if (fundingTxid != null)
          CopyableDetailRow(
            label: context.l10n.statecoinDepositTx,
            value: fundingTxid,
            abbreviate: true,
          ),
        if (exitAddress != null)
          CopyableDetailRow(
            label: context.l10n.statecoinExitAddress,
            value: exitAddress,
            abbreviate: true,
          ),
        if (exitTimelock != null)
          CopyableDetailRow(
            label: context.l10n.statecoinExitTimelock,
            value: context.l10n.statecoinBlocks(exitTimelock),
            showCopyButton: false,
          ),
        if (transfers != null && _coin.isOwned)
          CopyableDetailRow(
            label: context.l10n.statecoinTransfers,
            value: transfers.toString(),
            showCopyButton: false,
          ),
        const SizedBox(height: 4),
        ..._actions(context),
        if (backups != null) _buildBackups(context, backups),
      ],
    );
  }

  Widget _buildBackups(
    BuildContext context,
    Future<StatecoinBackups?> backups,
  ) {
    return FutureBuilder<StatecoinBackups?>(
      future: backups,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            title: Text(context.l10n.statecoinBackups),
            subtitle: Text(context.l10n.statecoinBackupsHint),
            children: [
              StatecoinSignedTx(
                label: context.l10n.statecoinNodeTx,
                txid: data.nodeTxid,
                hex: data.nodeTxHex,
              ),
              StatecoinSignedTx(
                label: context.l10n.statecoinExitTx,
                txid: data.exitTxid,
                hex: data.exitTxHex,
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _actions(BuildContext context) {
    if (!_coin.isOwned) return [];

    return switch (_coin.status) {
      StatecoinStatus.awaitingFunding when _coin.depositAddress != null => [
        StatecoinActionButton(
          label: context.l10n.statecoinFund,
          onPressed: () => setState(() => _view = _View.fund),
        ),
      ],
      StatecoinStatus.active => [
        StatecoinActionButton(
          label: context.l10n.send,
          onPressed: _busy ? null : () => setState(() => _view = _View.send),
        ),
        StatecoinActionButton(
          label: context.l10n.statecoinPegOut,
          onPressed: _busy ? null : () => setState(() => _view = _View.pegOut),
        ),
        StatecoinActionButton(
          label: context.l10n.statecoinExit,
          busy: _busy,
          outlined: true,
          onPressed: _confirmExit,
        ),
      ],
      StatecoinStatus.exiting || StatecoinStatus.closed => [
        StatecoinActionButton(
          label: context.l10n.statecoinExitProgress,
          busy: _busy,
          onPressed: _exit,
        ),
      ],
      _ => [],
    };
  }

  Widget _buildSend(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatecoinSheetTitle(context.l10n.send),
        StatecoinTextField(
          controller: _sendAddress,
          label: context.l10n.statecoinSendTo,
          enabled: !_busy,
          maxLines: 3,
        ),
        ValueListenableBuilder(
          valueListenable: _sendAddress,
          builder:
              (context, value, _) => StatecoinActionButton(
                label: context.l10n.send,
                busy: _busy,
                onPressed: value.text.trim().isEmpty ? null : _send,
              ),
        ),
      ],
    );
  }

  Widget _buildPegOut(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatecoinSheetTitle(context.l10n.statecoinPegOut),
        StatecoinTextField(
          controller: _pegOutAddress,
          label: context.l10n.statecoinPegOutAddress,
          enabled: !_busy,
        ),
        const SizedBox(height: 16),
        StatecoinTextField(
          controller: _pegOutFee,
          label: context.l10n.statecoinPegOutFee,
          enabled: !_busy,
          keyboardType: TextInputType.number,
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_pegOutAddress, _pegOutFee]),
          builder: (context, _) {
            final valid =
                _pegOutAddress.text.trim().isNotEmpty &&
                BigInt.tryParse(_pegOutFee.text.trim()) != null;

            return StatecoinActionButton(
              label: context.l10n.statecoinPegOut,
              busy: _busy,
              onPressed: valid ? _pegOut : null,
            );
          },
        ),
      ],
    );
  }
}

/// Follows a unilateral exit until the bitcoin is at the exit address. The
/// app broadcasts the exit transaction in the background, so this only shows
/// where the exit is.
class StatecoinExitProgress extends StatefulWidget {
  final FederationSelector fed;
  final String coinId;
  final int? timelock;

  const StatecoinExitProgress({
    super.key,
    required this.fed,
    required this.coinId,
    this.timelock,
  });

  @override
  State<StatecoinExitProgress> createState() => _StatecoinExitProgressState();
}

class _StatecoinExitProgressState extends State<StatecoinExitProgress> {
  static const _pollInterval = Duration(seconds: 3);

  StatecoinExitState? _state;
  Timer? _timer;
  bool _polling = false;

  /// For the txids, so the exit can be looked up on chain.
  late final Future<StatecoinBackups?> _backups = loadStatecoinBackups(
    widget.fed,
    widget.coinId,
  );

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;

    try {
      final state = await statechainExitState(
        federationId: widget.fed.federationId,
        coinId: widget.coinId,
      );
      if (!mounted) return;
      setState(() => _state = state);
      if (state is StatecoinExitState_Completed) _timer?.cancel();
    } catch (e) {
      AppLogger.instance.warn('Could not check statecoin exit: $e');
    } finally {
      _polling = false;
    }
  }

  String _describe(BuildContext context, StatecoinExitState? state) {
    switch (state) {
      case null:
        return '';
      case StatecoinExitState_AwaitingNodeConfirmation():
        return context.l10n.statecoinExitAwaitingNode;
      case StatecoinExitState_Timelocked(:final blocksRemaining):
        return context.l10n.statecoinExitTimelocked(blocksRemaining);
      case StatecoinExitState_Ready():
        return context.l10n.statecoinExitReady;
      case StatecoinExitState_ExitBroadcast():
        return context.l10n.statecoinExitBroadcast;
      case StatecoinExitState_Completed():
        return context.l10n.statecoinExitCompleted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _state;
    final timelock = widget.timelock;

    final Widget indicator = switch (state) {
      StatecoinExitState_Completed() => const Icon(
        Icons.check_circle,
        color: Colors.green,
        size: 64,
      ),
      StatecoinExitState_Timelocked(:final blocksRemaining)
          when timelock != null && timelock > 0 =>
        LinearProgressIndicator(
          value: (1 - blocksRemaining / timelock).clamp(0.0, 1.0),
          minHeight: 8,
          borderRadius: BorderRadius.circular(4),
        ),
      _ => const CircularProgressIndicator(),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatecoinSheetTitle(context.l10n.statecoinExitProgress),
        const SizedBox(height: 8),
        SizedBox(height: 64, child: Center(child: indicator)),
        const SizedBox(height: 16),
        Text(
          _describe(context, state),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 16),
        FutureBuilder<StatecoinBackups?>(
          future: _backups,
          builder: (context, snapshot) {
            final backups = snapshot.data;
            if (backups == null) return const SizedBox.shrink();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CopyableDetailRow(
                  label: context.l10n.statecoinNodeTx,
                  value: backups.nodeTxid,
                  abbreviate: true,
                ),
                CopyableDetailRow(
                  label: context.l10n.statecoinExitTx,
                  value: backups.exitTxid,
                  abbreviate: true,
                ),
              ],
            );
          },
        ),
        StatecoinActionButton(
          label: context.l10n.close,
          outlined: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
