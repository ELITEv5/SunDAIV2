# pSunDAI V7

**Autonomous · Ownerless · Immutable · PulseChain**

pSunDAI is a WPLS-collateralized autonomous stable asset on PulseChain. Users lock PLS (or WPLS) as collateral and mint pSunDAI — a USD-pegged token backed by over-collateralization, a stability fee, and a 5-pool PulseX oracle. There are no admin keys, no upgradeability, and no governance. Once deployed, the protocol runs forever.

> *"The bank is immutable Solidity. The monetary policy is enforced by mathematics."*

---

## Table of Contents

1. [What is pSunDAI?](#what-is-psundai)
2. [V7 Improvements](#v7-improvements)
3. [The Oracle (Dual-Track PulseX TWAP)](#the-oracle-dual-track-pulsex-twap)
4. [How to Use](#how-to-use)
5. [Vault Health Zones](#vault-health-zones)
6. [Liquidations](#liquidations)
7. [Stability Fee and Surplus Buffer](#stability-fee-and-surplus-buffer)
8. [Debt Ceiling](#debt-ceiling)
9. [Emergency Functions](#emergency-functions)
10. [Protocol Tools](#protocol-tools)
11. [System Invariants](#system-invariants)
12. [Deployed Contracts](#deployed-contracts)
13. [Compiling](#compiling)
14. [Deploy Order](#deploy-order)
15. [Security Model](#security-model)
16. [Frontend Files](#frontend-files)

---

## What is pSunDAI?

pSunDAI is a CDP (Collateralized Debt Position) protocol on PulseChain. Users lock WPLS (or native PLS) as collateral and borrow pSunDAI against it. Each pSunDAI targets **$1 USD** — the peg is enforced by:

1. **Over-collateralization** — minimum 150% CR to mint
2. **Stability fee** — 0.5% APY applied to debt, creating sell pressure when supply is high
3. **Liquidations** — vaults below 110% CR are liquidated by external parties, preventing bad debt

The protocol does not require any human intervention to maintain the peg. There is no governance, no admin, no pausing.

> **Note:** pSunDAI V7 does not include a redemption mechanism. Peg maintenance relies on the stability fee and liquidation mechanisms.

---

## V7 Improvements

### Dual-Track Oracle (TWAP + Spot Warning)
V7 introduces a real-time **Spot Warning Track** alongside the conservative TWAP:

- **TWAP (Conservative)** — Used for minting and withdrawal safety. Slow to fall (4h confirmation for >1% moves down), fast to rise (30min for <5%). Prevents liquidation cascades during flash crashes.

- **Spot Warning Track** — Monitors whether the 5-pool PulseX spot median is 5%+ below the TWAP. If this persists for 30 continuous minutes, `isSpotLiquidationEnabled()` returns true. The vault then uses real spot price for liquidation eligibility — closing the bad-debt window that conservative TWAP stepping creates during a real crash.

**Flash crash:** Spot drops briefly, recovers in minutes. Warning never reaches 30 minutes. TWAP price is protected.

**Real crash:** Spot drops 5%+ and stays there. After 30 minutes, liquidations proceed at live spot price. Bad debt is minimized.

### Surplus Buffer + Bad Debt Accounting
V6 silently absorbed uncovered liquidation losses. V7 makes the math explicit:

- `surplusBuffer` — accumulated stability fees. Protocol equity.
- `badDebtAccumulated` — unrecovered loss from zombie vaults.
- `systemEquity()` — surplusBuffer minus badDebtAccumulated. Positive = solvent.
- `reconcile()` — nets the two. Called automatically on every fee accrual. Public.

### Inverted Dutch Auction
Bonus starts at **5%** immediately when a vault is marked undercollateralized, and decays to **2%** over 3 hours. First mover wins the highest bonus. This eliminates the bad-debt window created by bots waiting for the maximum bonus.

### Debt Ceiling
Immutable limit on total pSunDAI supply. Set at deploy time. Mint reverts if ceiling would be exceeded. Limits protocol-level risk.

### Bug Fixes vs V6.5
- **M-8:** `repayAndAutoWithdraw` full exit now emits `Withdraw` (not `EmergencyWithdraw`)
- **L-4:** Dust clearing ≤ 1e12 after repayment prevents zombie micro-debt

---

## The Oracle (Dual-Track PulseX TWAP)

The oracle uses **five PulseX liquidity pools** to compute a TWAP median price for PLS in USD.

**Price sources:**
- 2 × WPLS/DAI pools (v1, v2)
- 2 × WPLS/USDC pools (v1, v2)
- 1 × WPLS/USDT pool

Prices are normalized to 18 decimals. A minimum reserve threshold (1000 USD) filters low-liquidity pools. The median of valid readings is taken, rejecting outliers.

**TWAP constants:**
| Parameter | Value | Description |
|-----------|-------|-------------|
| `CONFIRM_TIME_DOWN` | 4 hours | Confirm before accepting >1% downward move |
| `CONFIRM_TIME_UP` | 30 min | Confirm before accepting >5% upward move |
| `STEP_SIZE_DOWN_BPS` | 300 (3%) | Max step per update going down |
| `STEP_SIZE_UP_BPS` | 1000 (10%) | Max step per update going up |
| `INSTANT_UPDATE_DOWN_BPS` | 100 (1%) | ≤1% down: instant, no confirmation |
| `INSTANT_UPDATE_UP_BPS` | 500 (5%) | ≤5% up: instant, no confirmation |

**Spot warning constants:**
| Parameter | Value | Description |
|-----------|-------|-------------|
| `SPOT_WARNING_BPS` | 500 (5%) | Threshold below TWAP to trigger warning clock |
| `SPOT_CONFIRM_TIME` | 30 min | Sustained time before liquidations switch to spot |

**Oracle states (`getPriceStatus` returns):**
| Field | Description |
|-------|-------------|
| `currentPrice` | TWAP committed price — used for vault safety checks |
| `marketPrice` | Current 5-pool spot median |
| `divergenceBps` | Divergence between TWAP and spot in basis points |
| `inConfirmation` | A price update is pending confirmation |
| `confirmTimeRemaining` | Time until confirmation completes |
| `targetPrice` | Target being confirmed |
| `spotWarningActive` | Spot is 5%+ below TWAP |
| `spotLiquidationEnabled` | Warning active for 30+ min — liquidations use spot |

**Poke:** Anyone can advance the oracle state machine by calling `poke()`. Rate-limited to once per 30 minutes. Used by keepers and bots to keep TWAP current without requiring user vault interactions.

**Dead oracle override:** If oracle is dead for 7+ days, emergency repay and withdraw are enabled.

---

## How to Use

### Auto Mode (Recommended)
1. Connect MetaMask on PulseChain (chain ID 369)
2. Enter PLS amount in the Auto tab
3. Click **1-Click Auto Borrow** — deposits PLS and mints pSunDAI at 155% CR in one transaction

### Manual Flow
**Deposit PLS** → lock native PLS as collateral (auto-wrapped to WPLS internally). Or deposit WPLS directly after approval.

**Mint pSunDAI** → borrow USD-equivalent against your PLS. Minimum 150% CR after mint.
```
CR = (WPLS Collateral × PLS Price) ÷ pSunDAI Debt × 100%
```

**Repay** → burn pSunDAI to reduce debt. Requires wallet approval first.

**Withdraw** → pull PLS back (as native PLS via `withdrawPLS()` or as WPLS via `withdrawWPLS()`). CR must stay ≥ 150% after withdrawal. 5-minute cooldown after deposit.

**Full Exit** → Repay All & Withdraw — single transaction, closes position entirely.

---

## Vault Health Zones

| CR | Status | Description |
|----|--------|-------------|
| Above 150% | Safe | Can mint more, can withdraw. Immune to liquidation. |
| 110–150% | At risk | Cannot mint more. Add collateral. |
| Below 110% | Liquidatable | Liquidators repay debt and claim WPLS + bonus. |

**Recommended target:** 175%+ CR to absorb PLS price swings comfortably.

---

## Liquidations

When a vault's CR falls below 110%, it becomes liquidatable.

**Process:**
1. Open Vault Dashboard → Liquidate tab
2. Scan all vaults — finds those below 110% CR
3. Click Liquidate, enter pSunDAI to repay (minimum 20% of vault debt)
4. Confirm — vault burns your pSunDAI, sends you proportional PLS + bonus

**Bonus:** Starts at **5%** immediately when vault becomes undercollateralized. Decays to **2%** over 3 hours. First mover wins.

**V7 dual-price effect:** During confirmed spot liquidation (spot warning active 30+ min), liquidation eligibility uses real-time spot price. Vaults safe at TWAP may be liquidatable at spot during a real crash.

**Zombie vaults:** If collateral value < 100% of debt, `clearBadDebt(address)` seizes all collateral free. Caller keeps it. Remaining debt written off against surplus.

---

## Stability Fee and Surplus Buffer

**0.5% annual stability fee** accrues continuously to vault debt. 1,000 pSunDAI debt grows by ~5 pSunDAI/year. Collected fees accumulate as `surplusBuffer` — protocol equity.

**Surplus flow:**
```
Stability fee → surplusBuffer
Bad liquidation → badDebtAccumulated
reconcile()   → nets them: surplusBuffer absorbs badDebt first
systemEquity = surplusBuffer - badDebtAccumulated
```

Positive equity means the protocol can absorb future bad debt before it propagates. Fees stay in the contract as a reserve — no treasury receiver.

---

## Debt Ceiling

Immutable limit set at deploy time. Mint and auto-mint revert if `totalDebt + amount > DEBT_CEILING`. Displayed in the System State panel with a utilization bar. Cannot be increased without deploying a new vault.

---

## Emergency Functions

| Function | When Available | What it Does |
|----------|---------------|-------------|
| `emergencyUnlock()` | Zero debt + last deposit >30 days | Recover PLS regardless of oracle |
| `emergencyRepay(amount)` | Oracle dead >7 days | Repay debt without oracle price |
| `emergencyWithdrawPLS(amount)` | Oracle dead >7 days + zero debt | Withdraw PLS without oracle |

These exist to ensure users can always exit, even if the oracle permanently fails.

---

## Protocol Tools

Public functions callable by any wallet. No economic cost beyond gas.

| Function | What it Does |
|----------|-------------|
| `reconcile()` | Net surplus buffer against bad debt |
| `oracle.poke()` | Advance oracle TWAP state machine (30 min cooldown) |
| `clearBadDebt(addr)` | Seize zombie vault collateral. Caller keeps PLS free. |
| `settleDebt(amount)` | Burn your own pSunDAI to cancel accumulated bad debt |

---

## System Invariants

```
I1  — Min CR:            150% required to mint or maintain position
I2  — Liquidation:       Vaults below 110% CR can be liquidated
I3  — No redemption:     pSunDAI V7 does not include a redemption mechanism
I4  — Oracle resilience: Stale oracle blocks minting, never blocks deposit/repay
I5  — Immutability:      No admin, no pause, no upgrade after setVault()
I6  — Liveness:          7-day oracle failure enables emergency exit paths
I7  — Surplus accounting: Stability fees accumulate as surplus — never lost
I8  — Trust-minimized burn: Vault burns only tokens it holds in its own balance
I9  — Dual-track:        Flash crashes never trigger spot liquidation; real crashes do
I10 — Bad debt visible:  All bad debt tracked on-chain, never silently absorbed
I11 — Debt ceiling:      Total supply bounded by immutable DEBT_CEILING
I12 — Bonus inverted:    Liquidation bonus starts at max (5%), decays to min (2%)
```

---

## Deployed Contracts

**PulseChain (Chain ID: 369)** — contracts not yet deployed. Update addresses after deployment.

| Contract | Address |
|----------|---------|
| **pSunDAI Token** | TBD |
| **Vault v7** | TBD |
| **Oracle v7** | TBD |

**Required external addresses (PulseChain mainnet):**

Oracle constructor takes 5 PulseX pool addresses + WPLS, DAI, USDC, USDT:
| Token | Address |
|-------|---------|
| WPLS | `0xA1077a294dDE1B09bB078844df40758a5D0f9a27` |
| DAI | `0xefD766cCb38EaF1dfd701853BFCe31359239F305` |
| USDC | `0x15D38573d2feeb82e7ad5187aB8c1D52810B1f07` |
| USDT | `0x0Cb6F5a34ad42ec934882A05265A7d5F59b51A2f` |

Confirm pool addresses on PulseX before deployment.

**Vault parameters:**
- Min collateral ratio: **150%** · Liquidation threshold: **110%**
- Stability fee: **0.5% APY** · Min action: 0.0001 PLS
- Max bonus: **5%** (decays to 2% over 3h) · Min liquidation: 20% of vault debt
- Withdrawal cooldown: **5 minutes** · Emergency unlock: **30 days** with zero debt
- Oracle staleness limit: **5 minutes** · Oracle dead override: **7 days**

---

## Compiling

**EVM target: `paris`** — PulseChain uses a Paris-compatible EVM.

> Use `--evm-version paris` in Remix or set `evmVersion: "paris"` in Hardhat/Foundry config.

The vault imports token and oracle directly. Compile all three together in Remix or use a flattened version.

**Remix:**
1. Import all three `.sol` files
2. Compiler: `0.8.20`, EVM: `paris`
3. Deploy via Injected Provider (MetaMask on PulseChain)

**Note on OZ imports:** The contracts use `@openzeppelin/contracts` GitHub-path imports. If using Remix, the remappings resolve automatically. For Hardhat/Foundry, install `@openzeppelin/contracts@4.x` (v4.9.6 works; avoid v5 which uses `mcopy` incompatible with Paris EVM).

---

## Deploy Order

```
1. Deploy pSunDAI_ASA_Token_v7
   → Records deployer address

2. Deploy pSunDAI_Oracle_Hybrid_v7
   args: pairDAIv1, pairDAIv2, pairUSDCv1, pairUSDCv2, pairUSDT,
         wpls, dai, usdc, usdt
   → bootstraps lastPrice from spot median at deploy

3. Deploy pSunDAIVault_ASA_v7
   args: wpls, psundai_address, oracle_address, debtCeiling
   → sets lastOraclePrice from oracle.peekPriceView() at deploy

4. oracle.setVault(vault_address)
   → permanent latch, one-time call, enables getPriceWithTimestamp()

5. token.setVault(vault_address)
   → permanent latch, one-time call, no admin after this

── system is now fully autonomous ──
```

Update `VAULT_ADDR`, `TOKEN_ADDR`, `ORACLE_ADDR` in both HTML files after deploy.

---

## Security Model

**No admin keys.** `setVault()` is the only privileged function on both token and oracle — becomes permanently inaccessible after being called once.

**No upgradeability.** No proxies, no beacons.

**Trust-minimized token.** Vault calls `approve` flow then burns from its own balance. The vault cannot drain wallets.

**Oracle manipulation resistance.** 5-pool TWAP median is extremely expensive to manipulate on-chain. Confirmation periods reject flash manipulation. Spot warning requires 30 continuous minutes to activate — not achievable by a single block attack.

**Dual-track protects both sides:**
- Conservative TWAP: flash crashes don't cascade liquidations
- Spot warning track: real crashes don't create perpetual bad debt

**What the contracts cannot do:**
- Mint pSunDAI to arbitrary addresses
- Pause or freeze any function
- Change CR requirements, liquidation ratios, or fee structures
- Access or redirect user collateral outside of vault operations

---

## Frontend Files

| File | Purpose |
|------|---------|
| `index.html` | Main vault UI — deposit, mint, repay, withdraw, oracle status |
| `liquidations.html` | Dashboard — scan all vaults, liquidate, inspect |
| `psundai-vault-v7-abi.json` | Vault ABI (9-return vaultInfo, surplus buffer, debt ceiling) |
| `psundai-token-v7-abi.json` | Token ABI (ERC20, no Permit) |
| `psundai-oracle-v7-abi.json` | Oracle ABI (dual-track, spot warning, poke) |
| `ethers.umd.min.js` | ethers.js v6 bundled — no CDN dependency |
| `sundailogo.png` | Protocol logo |
| `contracts/pSunDAI_ASA_Token_v7.sol` | Token source |
| `contracts/pSunDAIVault_ASA_v7.sol` | Vault source |
| `contracts/pSunDAI_Oracle_Hybrid_v7.sol` | Oracle source |

**GitHub Pages:** Push this folder to a GitHub repo, enable Pages on root branch.

---

*pSunDAI is experimental software. No audits have been performed. Use at your own risk.*

**License: MIT**
