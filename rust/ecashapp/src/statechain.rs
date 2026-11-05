//! Statecoins: bitcoin UTXOs whose ownership moves off chain, held jointly with
//! a federation through its statechain module.
//!
//! The statechain client module does the protocol work; this layer adapts it
//! to the app and adds what the module leaves to the wallet: broadcasting the
//! funding transaction and a unilateral exit through esplora, and finishing an
//! exit once its timelock has passed.

use std::str::FromStr;
use std::time::Duration;

use anyhow::{anyhow, Context};
use bitcoin::address::NetworkUnchecked;
use bitcoin::consensus::encode::{deserialize_hex, serialize_hex};
use bitcoin::{Address, Network, Transaction, Txid};
use fedimint_client::{ClientHandleArc, ClientModuleInstance};
use fedimint_core::config::FederationId;
use fedimint_core::runtime;
use fedimint_core::task::sleep;
use fedimint_statechain_client::db::LocalCoinState;
use fedimint_statechain_client::{CoinInfo, ExitTransactions, StatechainClientModule};
use fedimint_statechain_common::{CoinId, CoinRecord, CoinStatus, StatechainAddress};
use serde::Deserialize;

use crate::app_error::{EcashAppError, EcashAppResult};
use crate::multimint::{LogLevel, Multimint, MultimintEvent};
use crate::net::http_client;
use crate::wallet::mempool_api_url;
use crate::{error_to_flutter, get_event_bus, info_to_flutter};

/// How often a unilateral exit checks on its node transaction to tell when the
/// exit transaction may be broadcast
const EXIT_POLL_INTERVAL: Duration = Duration::from_secs(5);

/// How long listing the coins waits for esplora to tell whether a coin is
/// exiting before showing it without
const CHAIN_CHECK_TIMEOUT: Duration = Duration::from_secs(5);

/// A freshly created statecoin and the address to fund it at.
#[derive(Debug, Clone)]
pub struct StatecoinDeposit {
    pub coin_id: String,
    /// Build a funding transaction to this address but do not broadcast it:
    /// hand it to [`Multimint::statechain_fund`], which co-signs the coin's
    /// backup transactions before broadcasting it.
    pub address: String,
}

/// The federation's view of a statecoin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StatecoinStatus {
    /// The guardians are generating the coin's key
    KeyGen,
    /// Waiting for the funding transaction
    AwaitingFunding,
    /// Funded, waiting for the deposit to confirm
    Unconfirmed,
    /// Can be sent or pegged out
    Active,
    /// Being sent
    Sending,
    /// Sent, waiting for the receiver to claim it
    AwaitingClaim,
    /// Being pegged out cooperatively
    PeggingOut,
    /// A unilateral exit has started on chain
    Exiting,
    /// Spent on chain, normally by a peg-out
    Closed,
    /// The funding transaction did not match its registration
    Invalid,
    /// The federation does not know the coin
    Unknown,
}

/// What this wallet holds of a statecoin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StatecoinHolding {
    /// We own the coin
    Owned,
    /// We sent the coin away
    Sent,
    /// We pegged the coin out
    PeggedOut,
}

#[derive(Debug, Clone)]
pub struct Statecoin {
    pub coin_id: String,
    pub amount_sats: Option<u64>,
    pub status: StatecoinStatus,
    pub holding: Option<StatecoinHolding>,
    /// The coin's on-chain address, which its funding transaction pays to
    pub deposit_address: Option<String>,
    /// The transaction that funded the coin
    pub funding_txid: Option<String>,
    /// Where our exit transaction pays to
    pub exit_address: Option<String>,
    /// Blocks our exit transaction waits after the node transaction confirms
    pub exit_timelock: Option<u32>,
    /// How often the coin changed hands before it reached us; each transfer
    /// shortens the exit timelock
    pub transfers: Option<u32>,
    /// The federation could not be reached, so the status is the last one it
    /// reported, corrected by what the chain shows
    pub federation_stale: bool,
}

#[derive(Debug, Clone)]
pub struct StatecoinClaim {
    pub claimed: Vec<String>,
    /// Coins sent to us that could not be claimed, as `<coin id>: <reason>`
    pub failed: Vec<String>,
}

/// A coin's signed backup transactions, which take it on chain without the
/// guardians: the node transaction spends the funding output and our exit
/// transaction spends the node transaction.
#[derive(Debug, Clone)]
pub struct StatecoinBackups {
    pub node_txid: String,
    /// The signed node transaction, consensus-encoded as hex
    pub node_tx_hex: String,
    pub exit_txid: String,
    /// The signed exit transaction, consensus-encoded as hex
    pub exit_tx_hex: String,
    /// Confirmations the node transaction needs before the exit transaction
    /// is valid
    pub timelock: u32,
}

impl From<&ExitTransactions> for StatecoinBackups {
    fn from(exit: &ExitTransactions) -> Self {
        Self {
            node_txid: exit.node_tx.compute_txid().to_string(),
            node_tx_hex: serialize_hex(&exit.node_tx),
            exit_txid: exit.exit_tx.compute_txid().to_string(),
            exit_tx_hex: serialize_hex(&exit.exit_tx),
            timelock: u32::from(exit.timelock),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StatecoinExitState {
    /// The node transaction is not confirmed yet
    AwaitingNodeConfirmation,
    /// The exit transaction can be broadcast after this many more blocks
    Timelocked { blocks_remaining: u32 },
    /// The exit transaction can be broadcast now
    Ready,
    /// The exit transaction is in the mempool
    ExitBroadcast,
    /// The exit transaction confirmed: the bitcoin is at the exit address
    Completed,
}

impl From<&CoinStatus> for StatecoinStatus {
    fn from(status: &CoinStatus) -> Self {
        match status {
            CoinStatus::KeyGen => Self::KeyGen,
            CoinStatus::AwaitingFunding => Self::AwaitingFunding,
            CoinStatus::Unconfirmed => Self::Unconfirmed,
            CoinStatus::Active => Self::Active,
            CoinStatus::SendPending { .. } => Self::Sending,
            CoinStatus::AwaitingClaim { .. } => Self::AwaitingClaim,
            CoinStatus::PegOutPending { .. } | CoinStatus::PegOutBroadcast { .. } => {
                Self::PeggingOut
            }
            CoinStatus::Exiting => Self::Exiting,
            CoinStatus::Closed { .. } => Self::Closed,
            CoinStatus::Invalid => Self::Invalid,
        }
    }
}

impl From<&LocalCoinState> for StatecoinHolding {
    fn from(state: &LocalCoinState) -> Self {
        match state {
            LocalCoinState::Owned => Self::Owned,
            LocalCoinState::Sent { .. } => Self::Sent,
            LocalCoinState::PeggedOut { .. } => Self::PeggedOut,
        }
    }
}

fn statecoin(
    info: CoinInfo,
    network: Network,
    exit_timelock: impl Fn(u16) -> Option<u16>,
) -> Statecoin {
    let funding = info
        .federation
        .as_ref()
        .and_then(|record| record.funding)
        .or_else(|| info.local.as_ref().and_then(|local| local.funding));

    Statecoin {
        coin_id: info.coin.to_string(),
        amount_sats: funding.map(|funding| funding.amount.to_sat()),
        status: info
            .federation
            .as_ref()
            .map_or(StatecoinStatus::Unknown, |record| (&record.status).into()),
        holding: info.local.as_ref().map(|local| (&local.state).into()),
        deposit_address: info
            .federation
            .as_ref()
            .and_then(CoinRecord::coin_script)
            .and_then(|script| Address::from_script(&script, network).ok())
            .map(|address| address.to_string()),
        funding_txid: funding.map(|funding| funding.outpoint.txid.to_string()),
        exit_address: info.local.as_ref().and_then(|local| {
            Address::from_script(&local.exit_script, network)
                .ok()
                .map(|address| address.to_string())
        }),
        exit_timelock: info
            .local
            .as_ref()
            .and_then(|local| exit_timelock(local.level))
            .map(u32::from),
        transfers: info.local.as_ref().map(|local| u32::from(local.level)),
        federation_stale: info.stale,
    }
}

/// The status to show for a coin given what the chain shows of its exit. The
/// chain shows an exit before the federation does, and also while the
/// federation is unreachable.
fn with_chain_exit(status: StatecoinStatus, chain: Option<&StatecoinExitState>) -> StatecoinStatus {
    match chain {
        Some(StatecoinExitState::Completed) => StatecoinStatus::Closed,
        Some(_) if status != StatecoinStatus::Closed => StatecoinStatus::Exiting,
        _ => status,
    }
}

/// The exit of a coin we own as the chain shows it, once its node transaction
/// has been broadcast. Anyone holding the coin's backups can start an exit, and
/// none of this needs the guardians.
async fn chain_exit_state(
    module: &StatechainClientModule,
    esplora: &Esplora,
    info: &CoinInfo,
) -> Option<StatecoinExitState> {
    if !matches!(info.local.as_ref()?.state, LocalCoinState::Owned) {
        return None;
    }

    // A coin has no backups until it is funded.
    let exit = module.exit_transactions(info.coin).await.ok()?;

    let state = runtime::timeout(CHAIN_CHECK_TIMEOUT, async {
        if esplora
            .tx_status(exit.node_tx.compute_txid())
            .await?
            .is_none()
        {
            return anyhow::Ok(None);
        }

        Ok(Some(esplora.exit_state(&exit).await?))
    })
    .await
    .map_err(anyhow::Error::from)
    .and_then(|state| state);

    match state {
        Ok(state) => state,
        Err(err) => {
            get_event_bus()
                .publish(MultimintEvent::Log(
                    LogLevel::Debug,
                    format!("Could not check statecoin {} on chain: {err:#}", info.coin),
                ))
                .await;
            None
        }
    }
}

/// The state of an exit given the confirmation height of its node transaction
/// and the chain tip.
///
/// BIP-68 makes the exit transaction valid in the block at
/// `node_height + timelock`, so a node accepts it into its mempool once the tip
/// is one block below that.
fn timelock_state(node_height: u64, tip_height: u64, timelock: u32) -> StatecoinExitState {
    let broadcastable_at = (node_height + u64::from(timelock)).saturating_sub(1);

    match broadcastable_at.checked_sub(tip_height) {
        Some(0) | None => StatecoinExitState::Ready,
        Some(blocks_remaining) => StatecoinExitState::Timelocked {
            blocks_remaining: u32::try_from(blocks_remaining).unwrap_or(u32::MAX),
        },
    }
}

#[derive(Debug, Deserialize)]
struct TxStatus {
    confirmed: bool,
    block_height: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct EsploraTx {
    status: TxStatus,
}

/// The few esplora calls statecoins need
struct Esplora {
    http: reqwest::Client,
    url: String,
}

impl Esplora {
    fn new(network: Network) -> Self {
        Self {
            http: http_client(),
            url: mempool_api_url(network),
        }
    }

    /// Broadcasts a transaction. A transaction esplora already knows counts as
    /// broadcast, so retrying is safe.
    async fn broadcast(&self, tx: &Transaction) -> anyhow::Result<Txid> {
        let txid = tx.compute_txid();

        let response = self
            .http
            .post(format!("{}/tx", self.url))
            .body(serialize_hex(tx))
            .send()
            .await?;

        if response.status().is_success() || self.tx_status(txid).await?.is_some() {
            return Ok(txid);
        }

        let reason = response.text().await.unwrap_or_default();

        Err(anyhow!("Broadcasting {txid} failed: {reason}"))
    }

    /// The transaction's status, or `None` if esplora has never seen it.
    ///
    /// Reads the whole transaction rather than `/tx/:txid/status`, which
    /// reports a transaction esplora has never seen as unconfirmed instead of
    /// unknown.
    async fn tx_status(&self, txid: Txid) -> anyhow::Result<Option<TxStatus>> {
        let response = self
            .http
            .get(format!("{}/tx/{txid}", self.url))
            .send()
            .await?;

        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }

        Ok(Some(
            response
                .error_for_status()?
                .json::<EsploraTx>()
                .await?
                .status,
        ))
    }

    async fn tip_height(&self) -> anyhow::Result<u64> {
        let height = self
            .http
            .get(format!("{}/blocks/tip/height", self.url))
            .send()
            .await?
            .error_for_status()?
            .text()
            .await?;

        height
            .trim()
            .parse()
            .with_context(|| format!("Unexpected tip height {height}"))
    }

    async fn exit_state(&self, exit: &ExitTransactions) -> anyhow::Result<StatecoinExitState> {
        if let Some(status) = self.tx_status(exit.exit_tx.compute_txid()).await? {
            return Ok(if status.confirmed {
                StatecoinExitState::Completed
            } else {
                StatecoinExitState::ExitBroadcast
            });
        }

        let node_height = self
            .tx_status(exit.node_tx.compute_txid())
            .await?
            .filter(|status| status.confirmed)
            .and_then(|status| status.block_height);

        let Some(node_height) = node_height else {
            return Ok(StatecoinExitState::AwaitingNodeConfirmation);
        };

        Ok(timelock_state(
            node_height,
            self.tip_height().await?,
            u32::from(exit.timelock),
        ))
    }
}

/// Watches an exit and broadcasts the exit transaction as soon as its timelock
/// allows, until it confirms.
async fn complete_exit(esplora: Esplora, coin: CoinId, exit: ExitTransactions) {
    loop {
        match esplora.exit_state(&exit).await {
            Ok(StatecoinExitState::Completed) => {
                info_to_flutter(format!("Statecoin {coin} exited to bitcoin")).await;
                return;
            }
            Ok(StatecoinExitState::Ready) => {
                if let Err(err) = esplora.broadcast(&exit.exit_tx).await {
                    error_to_flutter(format!(
                        "Could not broadcast the exit transaction of statecoin {coin}: {err:#}"
                    ))
                    .await;
                }
            }
            Ok(
                StatecoinExitState::AwaitingNodeConfirmation
                | StatecoinExitState::Timelocked { .. }
                | StatecoinExitState::ExitBroadcast,
            ) => {}
            Err(err) => {
                error_to_flutter(format!(
                    "Could not check the exit of statecoin {coin}: {err:#}"
                ))
                .await;
            }
        }

        sleep(EXIT_POLL_INTERVAL).await;
    }
}

fn parse_coin_id(coin_id: &str) -> EcashAppResult<CoinId> {
    CoinId::from_str(coin_id).map_err(|err| EcashAppError::other(err.to_string()))
}

fn parse_address(address: &str) -> EcashAppResult<Address<NetworkUnchecked>> {
    Address::from_str(address).map_err(|err| EcashAppError::InvalidBitcoinAddress(err.to_string()))
}

fn statechain_module(
    client: &ClientHandleArc,
) -> EcashAppResult<ClientModuleInstance<'_, StatechainClientModule>> {
    client
        .get_first_module::<StatechainClientModule>()
        .map_err(|_| EcashAppError::other("This federation does not support statecoins"))
}

impl Multimint {
    pub(crate) async fn statechain_supported(&self, federation_id: &FederationId) -> bool {
        match self.get_client(federation_id).await {
            Ok(client) => statechain_module(&client).is_ok(),
            Err(_) => false,
        }
    }

    /// Creates a statecoin; its exit address is chosen when funding it.
    pub(crate) async fn statechain_deposit(
        &self,
        federation_id: &FederationId,
    ) -> EcashAppResult<StatecoinDeposit> {
        let client = self.get_client(federation_id).await?;
        let module = statechain_module(&client)?;

        let deposit = module.deposit().await?;

        Ok(StatecoinDeposit {
            coin_id: deposit.coin.to_string(),
            address: deposit.address.assume_checked().to_string(),
        })
    }

    /// Co-signs a coin's backup transactions for a signed but not yet broadcast
    /// funding transaction, the exit transaction paying to `exit_address`,
    /// then broadcasts the funding transaction. Returns its txid.
    pub(crate) async fn statechain_fund(
        &self,
        federation_id: &FederationId,
        coin_id: String,
        funding_tx_hex: String,
        exit_address: String,
    ) -> EcashAppResult<String> {
        let client = self.get_client(federation_id).await?;
        let module = statechain_module(&client)?;

        let funding_tx: Transaction = deserialize_hex(funding_tx_hex.trim())
            .map_err(|err| EcashAppError::other(format!("Invalid funding transaction: {err}")))?;

        module
            .fund(
                parse_coin_id(&coin_id)?,
                &funding_tx,
                parse_address(&exit_address)?,
            )
            .await?;

        // Only now that the backups are signed may the funds leave the wallet.
        let txid = Esplora::new(module.params().network)
            .broadcast(&funding_tx)
            .await?;

        Ok(txid.to_string())
    }

    /// Creates a statechain address to receive coins whose exit transactions
    /// pay to `exit_address`.
    pub(crate) async fn statechain_receive_address(
        &self,
        federation_id: &FederationId,
        exit_address: String,
    ) -> EcashAppResult<String> {
        let client = self.get_client(federation_id).await?;
        let module = statechain_module(&client)?;

        Ok(module
            .receive_address(parse_address(&exit_address)?)
            .await?
            .to_string())
    }

    pub(crate) async fn statechain_send(
        &self,
        federation_id: &FederationId,
        coin_id: String,
        address: String,
    ) -> EcashAppResult<()> {
        let client = self.get_client(federation_id).await?;
        let module = statechain_module(&client)?;

        let address = StatechainAddress::from_str(address.trim())
            .map_err(|err| EcashAppError::other(err.to_string()))?;

        module.send(parse_coin_id(&coin_id)?, address).await?;

        Ok(())
    }

    /// Claims every coin sent to one of our statechain addresses.
    pub(crate) async fn statechain_claim(
        &self,
        federation_id: &FederationId,
    ) -> EcashAppResult<StatecoinClaim> {
        let client = self.get_client(federation_id).await?;
        let module = statechain_module(&client)?;

        let result = module.claim().await?;

        Ok(StatecoinClaim {
            claimed: result.claimed.iter().map(ToString::to_string).collect(),
            failed: result
                .failed
                .iter()
                .map(|(coin, reason)| format!("{coin}: {reason}"))
                .collect(),
        })
    }

    pub(crate) async fn statechain_list(
        &self,
        federation_id: &FederationId,
    ) -> EcashAppResult<Vec<Statecoin>> {
        let client = self.get_client(federation_id).await?;
        let module = statechain_module(&client)?;
        let params = &module.params().clone();
        let esplora = &Esplora::new(params.network);
        let module = &*module;

        let coins = module
            .list_coins()
            .await
            .into_iter()
            .map(move |info| async move {
                let chain = chain_exit_state(module, esplora, &info).await;
                let mut coin = statecoin(info, params.network, |level| params.exit_timelock(level));

                coin.status = with_chain_exit(coin.status, chain.as_ref());

                coin
            });

        Ok(futures_util::future::join_all(coins).await)
    }

    /// Cooperatively pegs a coin out; the guardians broadcast the transaction.
    /// Returns its txid.
    pub(crate) async fn statechain_peg_out(
        &self,
        federation_id: &FederationId,
        coin_id: String,
        address: String,
        fee_sats: u64,
    ) -> EcashAppResult<String> {
        let client = self.get_client(federation_id).await?;
        let module = statechain_module(&client)?;

        let tx = module
            .peg_out(
                parse_coin_id(&coin_id)?,
                parse_address(&address)?,
                bitcoin::Amount::from_sat(fee_sats),
            )
            .await?;

        Ok(tx.compute_txid().to_string())
    }

    /// Starts a unilateral exit: broadcasts the node transaction and keeps
    /// watching the chain to broadcast the exit transaction once its timelock
    /// has passed. Needs no guardian. Calling it again resumes the watch, for
    /// example after a restart.
    pub(crate) async fn statechain_exit(
        &self,
        federation_id: &FederationId,
        coin_id: String,
    ) -> EcashAppResult<StatecoinBackups> {
        let federation = self.get_federation(federation_id).await?;
        let module = statechain_module(&federation.client)?;
        let coin = parse_coin_id(&coin_id)?;

        let exit = module.exit_transactions(coin).await?;
        let esplora = Esplora::new(module.params().network);

        esplora.broadcast(&exit.node_tx).await?;

        let backups = StatecoinBackups::from(&exit);

        federation
            .tasks
            .spawn_cancellable("statecoin exit", complete_exit(esplora, coin, exit));

        Ok(backups)
    }

    /// The signed backup transactions of a coin we own, without broadcasting
    /// them.
    pub(crate) async fn statechain_backups(
        &self,
        federation_id: &FederationId,
        coin_id: String,
    ) -> EcashAppResult<StatecoinBackups> {
        let client = self.get_client(federation_id).await?;
        let module = statechain_module(&client)?;

        let exit = module.exit_transactions(parse_coin_id(&coin_id)?).await?;

        Ok(StatecoinBackups::from(&exit))
    }

    pub(crate) async fn statechain_exit_state(
        &self,
        federation_id: &FederationId,
        coin_id: String,
    ) -> EcashAppResult<StatecoinExitState> {
        let client = self.get_client(federation_id).await?;
        let module = statechain_module(&client)?;

        let exit = module.exit_transactions(parse_coin_id(&coin_id)?).await?;

        Ok(Esplora::new(module.params().network)
            .exit_state(&exit)
            .await?)
    }
}

#[cfg(test)]
mod tests;
