import 'package:ecashapp/error_helper.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/screens/statecoins/statecoin_widgets.dart';
import 'package:ecashapp/statechain.dart';
import 'package:ecashapp/toast.dart';
import 'package:flutter/material.dart';

/// Creates a statecoin, then funds it.
class StatecoinDepositSheet extends StatefulWidget {
  final FederationSelector fed;

  const StatecoinDepositSheet({super.key, required this.fed});

  @override
  State<StatecoinDepositSheet> createState() => _StatecoinDepositSheetState();
}

class _StatecoinDepositSheetState extends State<StatecoinDepositSheet> {
  final _exitAddress = TextEditingController();
  StatecoinDeposit? _deposit;
  bool _creating = false;

  @override
  void dispose() {
    _exitAddress.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final exitAddress = _exitAddress.text.trim();
    setState(() => _creating = true);

    try {
      final deposit = await statechainDeposit(
        federationId: widget.fed.federationId,
        exitAddress: exitAddress,
      );
      if (!mounted) return;
      setState(() => _deposit = deposit);
    } catch (e) {
      if (mounted) showErrorToast(context, e);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deposit = _deposit;
    if (deposit != null) {
      return StatecoinFundForm(
        fed: widget.fed,
        coinId: deposit.coinId,
        address: deposit.address,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatecoinSheetTitle(context.l10n.statecoinDeposit),
          StatecoinTextField(
            controller: _exitAddress,
            label: context.l10n.statecoinExitAddress,
            helper: context.l10n.statecoinExitAddressHint,
            enabled: !_creating,
          ),
          ValueListenableBuilder(
            valueListenable: _exitAddress,
            builder:
                (context, value, _) => StatecoinActionButton(
                  label: context.l10n.statecoinCreateCoin,
                  busy: _creating,
                  onPressed: value.text.trim().isEmpty ? null : _create,
                ),
          ),
        ],
      ),
    );
  }
}

/// Funds a statecoin: the federation co-signs the coin's backup transactions
/// for the pasted funding transaction before the app broadcasts it.
class StatecoinFundForm extends StatefulWidget {
  final FederationSelector fed;
  final String coinId;
  final String address;

  const StatecoinFundForm({
    super.key,
    required this.fed,
    required this.coinId,
    required this.address,
  });

  @override
  State<StatecoinFundForm> createState() => _StatecoinFundFormState();
}

class _StatecoinFundFormState extends State<StatecoinFundForm> {
  final _fundingTx = TextEditingController();
  bool _funding = false;

  @override
  void dispose() {
    _fundingTx.dispose();
    super.dispose();
  }

  Future<void> _fund() async {
    setState(() => _funding = true);

    try {
      await statechainFund(
        federationId: widget.fed.federationId,
        coinId: widget.coinId,
        fundingTxHex: _fundingTx.text.trim(),
      );
      if (!mounted) return;
      ToastService().show(
        message: context.l10n.statecoinFunded,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.check),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showErrorToast(context, e);
    } finally {
      if (mounted) setState(() => _funding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatecoinSheetTitle(context.l10n.statecoinFund),
          Text(
            context.l10n.statecoinFundInstructions,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          StatecoinQr(data: widget.address),
          const SizedBox(height: 16),
          StatecoinTextField(
            controller: _fundingTx,
            label: context.l10n.statecoinFundingTx,
            enabled: !_funding,
            maxLines: 4,
          ),
          ValueListenableBuilder(
            valueListenable: _fundingTx,
            builder:
                (context, value, _) => StatecoinActionButton(
                  label: context.l10n.statecoinSignAndBroadcast,
                  busy: _funding,
                  onPressed: value.text.trim().isEmpty ? null : _fund,
                ),
          ),
        ],
      ),
    );
  }
}
