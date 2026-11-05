import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/screens/statecoins/statecoin_widgets.dart';
import 'package:ecashapp/statechain.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

/// A statecoin row, styled like the dashboard's transaction rows.
class StatecoinItem extends StatelessWidget {
  final Statecoin coin;
  final VoidCallback onTap;

  const StatecoinItem({super.key, required this.coin, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final color = coin.isHeld ? theme.colorScheme.primary : Colors.redAccent;
    final holding = coin.holding;

    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: theme.colorScheme.surface,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.1),
          child: Icon(Icons.toll, color: color),
        ),
        title: Text(
          holding != null && !coin.isOwned
              ? holding.label(context)
              : coin.status.label(context),
          style: theme.textTheme.bodyMedium,
        ),
        subtitle: Text(
          getAbbreviatedText(coin.coinId),
          style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
        ),
        trailing: Text(
          coin.formatAmount(context, bitcoinDisplay),
          style: TextStyle(fontWeight: FontWeight.bold, color: color),
        ),
      ),
    );
  }
}

/// Shown while the federation is unreachable. The coins stay ours and can exit
/// without it; only their statuses may be out of date.
class StatecoinFederationUnreachable extends StatelessWidget {
  const StatecoinFederationUnreachable({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: Colors.grey[500]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.statecoinFederationUnreachable,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown on the Statecoin tab before the wallet has any statecoins.
class StatecoinEmptyState extends StatelessWidget {
  const StatecoinEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Animate(
      effects: [FadeEffect(duration: 200.ms, curve: Curves.easeIn)],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.toll, size: 48, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            context.l10n.statecoinsEmpty,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Lets the user choose one of [coins], skipping the question when there is
/// only one. Null if they dismiss the sheet.
Future<Statecoin?> pickStatecoin(
  BuildContext context,
  List<Statecoin> coins,
) async {
  if (coins.length == 1) return coins.single;

  return showAppModalBottomSheet<Statecoin>(
    context: context,
    fitContent: true,
    childBuilder:
        () async => Builder(
          builder:
              (sheetContext) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StatecoinSheetTitle(sheetContext.l10n.statecoinPickCoin),
                    for (final coin in coins)
                      StatecoinItem(
                        coin: coin,
                        onTap: () => Navigator.of(sheetContext).pop(coin),
                      ),
                  ],
                ),
              ),
        ),
  );
}
