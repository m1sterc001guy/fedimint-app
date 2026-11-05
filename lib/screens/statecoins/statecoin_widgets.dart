import 'package:ecashapp/db.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/statechain.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

extension StatecoinStatusLabel on StatecoinStatus {
  String label(BuildContext context) => switch (this) {
    StatecoinStatus.keyGen => context.l10n.statecoinStatusKeyGen,
    StatecoinStatus.awaitingFunding =>
      context.l10n.statecoinStatusAwaitingFunding,
    StatecoinStatus.unconfirmed => context.l10n.statecoinStatusUnconfirmed,
    StatecoinStatus.active => context.l10n.statecoinStatusActive,
    StatecoinStatus.sending => context.l10n.statecoinStatusSending,
    StatecoinStatus.awaitingClaim => context.l10n.statecoinStatusAwaitingClaim,
    StatecoinStatus.peggingOut => context.l10n.statecoinStatusPeggingOut,
    StatecoinStatus.exiting => context.l10n.statecoinStatusExiting,
    StatecoinStatus.closed => context.l10n.statecoinStatusClosed,
    StatecoinStatus.invalid => context.l10n.statecoinStatusInvalid,
    StatecoinStatus.unknown => context.l10n.statecoinStatusUnknown,
  };
}

extension StatecoinHoldingLabel on StatecoinHolding {
  String label(BuildContext context) => switch (this) {
    StatecoinHolding.owned => context.l10n.statecoinHoldingOwned,
    StatecoinHolding.sent => context.l10n.statecoinHoldingSent,
    StatecoinHolding.peggedOut => context.l10n.statecoinHoldingPeggedOut,
  };
}

extension StatecoinDisplay on Statecoin {
  bool get isOwned => holding == StatecoinHolding.owned;

  /// Still in this wallet: ours and not spent on chain.
  bool get isHeld =>
      isOwned &&
      status != StatecoinStatus.closed &&
      status != StatecoinStatus.invalid;

  String formatAmount(BuildContext context, BitcoinDisplay bitcoinDisplay) {
    final sats = amountSats;
    if (sats == null) return context.l10n.statecoinAmountPending;
    return formatBalance(sats * BigInt.from(1000), false, bitcoinDisplay);
  }

  /// The status, prefixed with the holding once the coin is no longer ours.
  String describe(BuildContext context) {
    final holding = this.holding;
    return [
      if (holding != null && !isOwned) holding.label(context),
      status.label(context),
    ].join(' · ');
  }
}

class StatecoinSheetTitle extends StatelessWidget {
  final String title;

  const StatecoinSheetTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// A QR code of [data] above its text, which copies it when tapped.
class StatecoinQr extends StatelessWidget {
  final String data;

  const StatecoinQr({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: AspectRatio(
              aspectRatio: 1,
              child: QrImageView(
                data: data,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: data));
            ToastService().show(
              message: context.l10n.addressCopiedToClipboard,
              duration: const Duration(seconds: 3),
              onTap: () {},
              icon: const Icon(Icons.check),
            );
          },
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    data,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.copy, size: 20, color: theme.colorScheme.primary),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A signed transaction: its txid and its raw hex, both copyable.
class StatecoinSignedTx extends StatelessWidget {
  final String label;
  final String txid;
  final String hex;

  const StatecoinSignedTx({
    super.key,
    required this.label,
    required this.txid,
    required this.hex,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          CopyableDetailRow(
            label: context.l10n.txDetailTxid,
            value: txid,
            abbreviate: true,
          ),
          _HexBox(hex: hex),
        ],
      ),
    );
  }
}

class _HexBox extends StatefulWidget {
  final String hex;

  const _HexBox({required this.hex});

  @override
  State<_HexBox> createState() => _HexBoxState();
}

class _HexBoxState extends State<_HexBox> {
  bool _copied = false;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.hex));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              widget.hex,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
          IconButton(
            onPressed: _copy,
            icon: Icon(
              _copied ? Icons.check : Icons.copy,
              size: 20,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// A monospace text field for addresses and transactions, with a paste
/// button since their contents come from elsewhere.
class StatecoinTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? helper;
  final bool enabled;
  final int maxLines;
  final TextInputType? keyboardType;

  const StatecoinTextField({
    super.key,
    required this.controller,
    required this.label,
    this.helper,
    this.enabled = true,
    this.maxLines = 1,
    this.keyboardType,
  });

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text != null && text.isNotEmpty) controller.text = text;
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      minLines: 1,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: const TextStyle(fontFamily: 'monospace'),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: const Icon(Icons.content_paste),
          tooltip: context.l10n.paste,
          onPressed: enabled ? _paste : null,
        ),
      ),
    );
  }
}

/// A full width button that shows a spinner while its action runs.
class StatecoinActionButton extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final bool outlined;

  const StatecoinActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    final child =
        busy
            ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
            : Text(label);
    final onPressed = busy ? null : this.onPressed;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child:
            outlined
                ? OutlinedButton(onPressed: onPressed, child: child)
                : FilledButton(onPressed: onPressed, child: child),
      ),
    );
  }
}
