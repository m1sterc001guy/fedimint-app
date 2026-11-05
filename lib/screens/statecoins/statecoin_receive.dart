import 'package:ecashapp/error_helper.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/screens/statecoins/statecoin_widgets.dart';
import 'package:flutter/material.dart';

/// Creates a statechain address that others can send a statecoin to.
class StatecoinReceiveSheet extends StatefulWidget {
  final FederationSelector fed;

  const StatecoinReceiveSheet({super.key, required this.fed});

  @override
  State<StatecoinReceiveSheet> createState() => _StatecoinReceiveSheetState();
}

class _StatecoinReceiveSheetState extends State<StatecoinReceiveSheet> {
  final _exitAddress = TextEditingController(text: lastStatecoinExitAddress);
  String? _address;
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
      final address = await statechainReceiveAddress(
        federationId: widget.fed.federationId,
        exitAddress: exitAddress,
      );
      lastStatecoinExitAddress = exitAddress;
      if (!mounted) return;
      setState(() => _address = address);
    } catch (e) {
      if (mounted) showErrorToast(context, e);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final address = _address;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatecoinSheetTitle(context.l10n.receive),
          if (address != null) ...[
            Text(
              context.l10n.statecoinReceiveInstructions,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            StatecoinQr(data: address),
          ] else ...[
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
                    label: context.l10n.statecoinCreateAddress,
                    busy: _creating,
                    onPressed: value.text.trim().isEmpty ? null : _create,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}
