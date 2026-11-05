use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{bail, ensure, Context};
use fedimint_core::config::FederationId;
use fedimint_core::db::mem_impl::MemDatabase;
use fedimint_core::db::Database;
use fedimint_core::rustls::install_crypto_provider;
use fedimint_statechain_common::{CoinStatus, StatechainAddress};

use super::{
    timelock_state, with_chain_exit, StatecoinExitState, StatecoinHolding, StatecoinStatus,
};
use crate::multimint::{Multimint, MultimintCreation};

#[test]
fn an_exit_becomes_ready_one_block_before_its_timelock_expires() {
    // The node transaction confirmed at height 100 with a 50 block timelock:
    // the exit transaction is valid in block 150, so the mempool takes it once
    // the tip is 149.
    assert_eq!(
        timelock_state(100, 100, 50),
        StatecoinExitState::Timelocked {
            blocks_remaining: 49
        }
    );
    assert_eq!(
        timelock_state(100, 148, 50),
        StatecoinExitState::Timelocked {
            blocks_remaining: 1
        }
    );
    assert_eq!(timelock_state(100, 149, 50), StatecoinExitState::Ready);
    assert_eq!(timelock_state(100, 500, 50), StatecoinExitState::Ready);
}

#[test]
fn coin_statuses_map_to_what_the_wallet_shows() {
    assert_eq!(
        StatecoinStatus::from(&CoinStatus::Active),
        StatecoinStatus::Active
    );
    assert_eq!(
        StatecoinStatus::from(&CoinStatus::Closed {
            txid: bitcoin::Txid::from_raw_hash(bitcoin::hashes::Hash::all_zeros())
        }),
        StatecoinStatus::Closed
    );
}

#[test]
fn the_chain_shows_an_exit_whatever_the_federation_reports() {
    // Nothing on chain: the federation's status, possibly the last one it
    // reported before going offline.
    assert_eq!(
        with_chain_exit(StatecoinStatus::Active, None),
        StatecoinStatus::Active
    );

    // A broadcast node transaction makes the coin unspendable, so it leaves
    // the balance even while the federation still reports it active.
    for state in [
        StatecoinExitState::AwaitingNodeConfirmation,
        StatecoinExitState::Timelocked {
            blocks_remaining: 10,
        },
        StatecoinExitState::Ready,
        StatecoinExitState::ExitBroadcast,
    ] {
        assert_eq!(
            with_chain_exit(StatecoinStatus::Active, Some(&state)),
            StatecoinStatus::Exiting
        );
    }

    assert_eq!(
        with_chain_exit(
            StatecoinStatus::Active,
            Some(&StatecoinExitState::Completed)
        ),
        StatecoinStatus::Closed
    );

    // A coin the federation saw spent stays closed.
    assert_eq!(
        with_chain_exit(StatecoinStatus::Closed, Some(&StatecoinExitState::Ready)),
        StatecoinStatus::Closed
    );
}

/// Runs bitcoin-cli against devimint's bitcoind wallet.
fn bitcoin_cli(args: &[&str]) -> anyhow::Result<String> {
    let client = std::env::var("FM_BTC_CLIENT").context("FM_BTC_CLIENT is not set")?;
    let mut parts = client.split_whitespace();
    let program = parts.next().context("FM_BTC_CLIENT is empty")?;

    let output = Command::new(program)
        .args(parts)
        .arg("-rpcwallet=default")
        .args(args)
        .output()?;

    ensure!(
        output.status.success(),
        "bitcoin-cli {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    Ok(String::from_utf8(output.stdout)?.trim().to_string())
}

fn mine(blocks: u32) -> anyhow::Result<()> {
    bitcoin_cli(&["-generate", &blocks.to_string()]).map(|_| ())
}

/// Polls `condition` until it returns `Some`, failing after two minutes.
async fn await_until<T, F, Fut>(what: &str, condition: F) -> anyhow::Result<T>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = anyhow::Result<Option<T>>>,
{
    let start = Instant::now();

    loop {
        if let Some(value) = condition().await? {
            return Ok(value);
        }

        if start.elapsed() > Duration::from_secs(120) {
            bail!("Timed out waiting for {what}");
        }

        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

async fn coin_status(
    wallet: &Multimint,
    federation_id: &FederationId,
    coin_id: &str,
) -> anyhow::Result<Option<(StatecoinStatus, Option<StatecoinHolding>)>> {
    Ok(wallet
        .statechain_list(federation_id)
        .await?
        .into_iter()
        .find(|coin| coin.coin_id == coin_id)
        .map(|coin| (coin.status, coin.holding)))
}

async fn new_wallet(invite: &str) -> anyhow::Result<(Multimint, FederationId)> {
    let db: Database = MemDatabase::new().into();
    let mut wallet = Multimint::new(db.clone(), MultimintCreation::New).await?;

    // Joining touches the app's global Nostr client. The first wallet's
    // database backs it; later calls leave it as it is.
    crate::create_nostr_client(db, true).await;

    let federation_id = wallet
        .join_federation(invite.to_string(), false)
        .await?
        .federation_id;

    Ok((wallet, federation_id))
}

/// Peg-in, transfer and unilateral exit through the app's statecoin API.
///
/// Run inside a devimint federation that has the statechain module enabled:
///
/// ```text
/// FM_ENABLE_MODULE_STATECHAIN=1 just devimint-env   # in the fedimint repo
/// ECASH_APP_REGTEST_ESPLORA_URL=http://127.0.0.1:$FM_PORT_ESPLORA \
///   cargo test statecoin_round_trip -- --ignored
/// ```
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs a devimint federation with the statechain module"]
async fn statecoin_round_trip_against_devimint() -> anyhow::Result<()> {
    let invite = std::env::var("FM_INVITE_CODE").context("FM_INVITE_CODE is not set")?;

    install_crypto_provider().await;
    crate::create_event_bus().await;

    let (alice, federation_id) = new_wallet(&invite).await?;
    let (bob, _) = new_wallet(&invite).await?;

    assert!(alice.statechain_supported(&federation_id).await);

    // Peg-in: the backups are signed before the app broadcasts the funding
    // transaction.
    let deposit = alice.statechain_deposit(&federation_id).await?;
    let coin_id = deposit.coin_id.clone();

    let funding = bitcoin_cli(&[
        "-named",
        "send",
        &format!("outputs={{\"{}\": 0.001}}", deposit.address),
        "fee_rate=2",
        "options={\"add_to_wallet\": false}",
    ])?;
    let funding_hex = serde_json::from_str::<serde_json::Value>(&funding)?["hex"]
        .as_str()
        .context("bitcoin-cli send returned no hex")?
        .to_string();

    alice
        .statechain_fund(
            &federation_id,
            coin_id.clone(),
            funding_hex,
            bitcoin_cli(&["getnewaddress"])?,
        )
        .await?;

    mine(10)?;

    await_until("the deposit to confirm", || async {
        Ok(coin_status(&alice, &federation_id, &coin_id)
            .await?
            .filter(|(status, _)| *status == StatecoinStatus::Active))
    })
    .await?;

    // Transfer to Bob.
    let bob_exit_address = bitcoin_cli(&["getnewaddress"])?;
    let address = bob
        .statechain_receive_address(&federation_id, bob_exit_address.clone())
        .await?;

    // The address round-trips through its string form.
    address
        .parse::<StatechainAddress>()
        .map_err(|err| anyhow::anyhow!("{err}"))?;

    alice
        .statechain_send(&federation_id, coin_id.clone(), address)
        .await?;

    let claim = bob.statechain_claim(&federation_id).await?;
    assert_eq!(claim.claimed, vec![coin_id.clone()]);
    assert!(claim.failed.is_empty());

    assert_eq!(
        coin_status(&bob, &federation_id, &coin_id).await?,
        Some((StatecoinStatus::Active, Some(StatecoinHolding::Owned)))
    );
    assert_eq!(
        coin_status(&alice, &federation_id, &coin_id)
            .await?
            .and_then(|(_, holding)| holding),
        Some(StatecoinHolding::Sent)
    );

    // Bob exits without the guardians; the app broadcasts both transactions.
    let exit = bob.statechain_exit(&federation_id, coin_id.clone()).await?;

    mine(1)?;

    await_until("the node transaction to confirm", || async {
        Ok(
            match bob
                .statechain_exit_state(&federation_id, coin_id.clone())
                .await?
            {
                StatecoinExitState::Timelocked { blocks_remaining } => Some(blocks_remaining),
                _ => None,
            },
        )
    })
    .await?;

    mine(exit.timelock - 1)?;

    await_until("the app to broadcast the exit transaction", || async {
        let state = bob
            .statechain_exit_state(&federation_id, coin_id.clone())
            .await?;

        Ok((state == StatecoinExitState::ExitBroadcast).then_some(()))
    })
    .await?;

    mine(1)?;

    await_until("the exit transaction to confirm", || async {
        let state = bob
            .statechain_exit_state(&federation_id, coin_id.clone())
            .await?;

        Ok((state == StatecoinExitState::Completed).then_some(()))
    })
    .await?;

    // The deposit minus the two pre-signed transaction fees.
    assert_eq!(
        bitcoin_cli(&["getreceivedbyaddress", &bob_exit_address])?,
        "0.00098000"
    );

    Ok(())
}
