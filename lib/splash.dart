import 'dart:io';

import 'package:ecashapp/app.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/pin_gated_app.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'create_wallet.dart';

class Splash extends StatefulWidget {
  final Directory dir;
  const Splash({super.key, required this.dir});

  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> {
  @override
  void initState() {
    super.initState();
    _checkWalletStatus();
  }

  Future<void> _checkWalletStatus() async {
    final walletDir = Directory('${widget.dir.path}/client.db');
    final exists = await walletDir.exists();
    AppLogger.instance.info("Wallet exists: $exists");

    if (!mounted) return;
    final Widget screen;
    if (exists) {
      try {
        AppLogger.instance.info("Calling loadMultimint...");
        await loadMultimint(
          path: widget.dir.path,
          isDesktop: Platform.isLinux | Platform.isMacOS,
        );
        AppLogger.instance.info("loadMultimint completed successfully");
        final initialFeds = await federations();
        AppLogger.instance.info("federations() returned ${initialFeds.length} federations");
        final pinRequired = await hasPinCode();
        AppLogger.instance.info("hasPinCode() returned $pinRequired");
        screen = PinGatedApp(
          pinRequired: pinRequired,
          child: MyApp(
            initialFederations: initialFeds,
            recoverFederationInviteCodes: false,
          ),
        );
      } catch (e, stackTrace) {
        AppLogger.instance.error("Splash crash: $e\n$stackTrace");
        rethrow;
      }
    } else {
      screen = CreateWallet(dir: widget.dir);
    }

    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Image(
          image: AssetImage('assets/images/ecash-app.png'),
          width: 200,
        ),
      ),
    );
  }
}
