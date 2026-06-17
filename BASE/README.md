# bSunDAI V7

**Autonomous · Ownerless · Immutable · Base Chain**

bSunDAI is an ETH-collateralized autonomous stable asset on Base Chain. Users lock ETH as collateral and mint bSunDAI — a USD-pegged token backed by over-collateralization, a redemption mechanism, and a stability fee. There are no admin keys, no upgradeability, and no governance. Once deployed, the protocol runs forever.

> *"The bank is immutable Solidity. The monetary policy is enforced by mathematics."*

---

## Table of Contents

1. [What is bSunDAI?](#what-is-bsundai)
2. [V7 Improvements](#v7-improvements)
3. [The Oracle (Dual-Price System)](#the-oracle-dual-price-system)
4. [How to Use](#how-to-use)
5. [Vault Health Zones](#vault-health-zones)
6. [Liquidations](#liquidations)
7. [Redemptions](#redemptions)
8. [Stability Fee and Surplus Buffer](#stability-fee-and-surplus-buffer)
9. [Debt Ceiling](#debt-ceiling)
10. [Emergency Functions](#emergency-functions)
11. [Protocol Tools](#protocol-tools)
12. [System Invariants](#system-invariants)
13. [Deployed Contracts](#deployed-contracts)
14. [Compiling](#compiling)
15. [Deploy Order](#deploy-order)
16. [Security Model](#security-model)
17. [Frontend Files](#frontend-files)

---

## What is bSunDAI?

bSunDAI is a CDP (Collateralized Debt Position) protocol. Users lock ETH as collateral and borrow bSunDAI against it. Each bSunDAI targets **$1 USD** — the peg is enforced by:

1. **Over-collateralization** — minimum 150% CR to mint
2. **Stability fee** — 0.5% APY applied to debt, creating sell pressure when supply is high
3. **Redemption** — any holder can redeem bSunDAI for $1 of ETH from any vault, creating a hard peg floor
4. **Liquidations** — vaults below 110% CR are liquidated by external parties, preventing bad debt

The protocol does not require any human intervention to maintain the peg. There is no governance, no admin, no pausing.

---

## V7 Improvements

### Dual-Price Liquidation
V7 introduces a Chainlink **Warning Track** alongside the committed stepping price:

- **Committed Price** — Used for minting and withdrawal safety. Accepts small moves instantly (≤2% down, ≤5% up). Requires confirmation periods for larger moves (4h down, 30min up), stepping gradually toward the target. This prevents liquidation cascades during flash crashes.

- **Chainlink Warning Track** — Monitors whether live Chainlink is 3%+ below committed price. If this persists for 30 continuous minutes, `isChainlinkLiquidationEnabled()` returns true. The vault then uses live Chainlink for liquidation eligibility — closing the bad-debt window that conservative committed stepping creates during a real crash.

**Flash crash:** Chainlink drops briefly, recovers in minutes. Warning never reaches 30 minutes. Committed price is protected.

**Real crash:** Chainlink drops 3%+ and stays there. After 30 minutes, liquidations proceed at live price. Bad debt is minimized.

### Surplus Buffer + Bad Debt Accounting
V6 silently absorbed uncovered liquidation losses. V7 makes the math explicit:

- `surplusBuffer` — accumulated stability fees. Protocol equity.
- `badDebtAccumulated` — unrecovered loss from zombie vaults.
- `systemEquity()` — surplusBuffer minus badDebtAccumulated. Positive = solvent.
- `reconcile()` — nets the two. Called automatically on every fee accrual. Public.

### Inverted Dutch Auction
V6 bonus grew from 2% to 10% over 3 hours — bots waited, leaving vaults underwater. V7 reverses this: bonus starts at **10%** and decays to **2%** over 3 hours. First mover wins the highest bonus. Bad debt window collapses from hours to minutes.

### Debt Ceiling
Immutable limit on total bSunDAI supply. Set at deploy time. Mint reverts if ceiling would be exceeded. Limits protocol-level risk.

### Bug Fixes vs V6.5
- **M-8:** `repayAndAutoWithdraw` full exit now emits `Withdraw` (not `EmergencyWithdraw` — wrong event on normal full repay)
- **L-4:** `_doRepay` clears debt dust ≤ 1e12 after repayment — prevents zombie micro-debt

---

## The Oracle (Dual-Price System)

The oracle is a public utility — no vault-only gating. Anyone can call `refreshPrice()` to advance the state machine.

**Price sources:**
- **Primary:** Chainlink via Aave Oracle (ETH/USD, 8-decimal, scaled to 1e18)
- **Backup:** Uniswap V3 TWAP median across 3 WETH/USDC pools (30-minute window)
- **Safety:** USDC depeg guard — if USDC < $0.97 on Chainlink, TWAP is disabled and Chainlink is used directly
- **Cross-divergence:** If Chainlink and TWAP diverge by >30%, TWAP wins (Chainlink manipulation protection)

**Oracle states (getPriceStatus returns):**
| Field | Description |
|-------|-------------|
| `currentPrice` | Committed price — used by vault for safety checks |
| `rawPrice` | Live unstepped price from primary/backup source |
| `targetPrice` | Target being confirmed or stepped toward |
| `_inConfirmation` | Waiting for confirmation period to complete |
| `_confirmStart` | Timestamp when current confirmation period started |
| `_isStepping` | Stepping toward target after confirmation completes |
| `chainlinkWarningActive` | Chainlink is 3%+ below committed price |
| `chainlinkLiquidationEnabled` | Warning active for 30+ min — liquidations use live Chainlink |

**Dead oracle override:** If oracle is dead for 7+ days, `isOracleCatastrophicallyFailed()` returns true — enabling emergency repay and withdraw.

---

## How to Use

### Auto Mode (Recommended)
1. Connect MetaMask on Base (chain ID 8453)
2. Enter ETH amount in the Auto tab
3. Click **1-Click Auto Borrow** — deposits ETH and mints bSunDAI at 155% CR in one transaction

### Manual Flow
**Deposit ETH** → lock ETH as collateral. 5-minute withdrawal cooldown begins.

**Mint bSunDAI** → borrow USD-equivalent against your ETH. Minimum 150% CR after mint.
```
CR = (ETH Collateral × ETH Price) ÷ bSunDAI Debt × 100%
```

**Repay** → burn bSunDAI to reduce debt. Requires vault approval first.

**Withdraw** → pull ETH back. CR must stay ≥ 150% after withdrawal.

**Full Exit** → Repay All & Withdraw — single transaction, requires wallet balance = current total debt.

---

## Vault Health Zones

| CR | Status | Description |
|----|--------|-------------|
| Above 150% | Safe | Can mint more, can withdraw. Immune to liquidation. Redeemable. |
| 110–150% | At risk | Cannot mint more. Add collateral or repay. Still redeemable. |
| Below 110% | Liquidatable | Liquidators repay debt and claim ETH + bonus. Also redeemable. |

> **No redemption CR filter:** Unlike MakerDAO-style protocols, bSunDAI has no minimum CR requirement to redeem against a vault. Any vault with `debt ≥ redeemAmount` can be redeemed against, regardless of collateral ratio. The `_doRedeem()` function has no CR check. All vaults are always redeemable.

**Recommended target:** 175%+ CR to absorb ETH price swings without entering the redeemable zone.

---

## Liquidations

When a vault's CR falls below 110%, it becomes liquidatable.

**Process:**
1. Open Vault Dashboard → Liquidate tab
2. Scan all vaults — finds those below 110% CR
3. Click Liquidate, enter bSunDAI to repay (any amount ≤ vault debt)
4. Confirm — vault burns your bSunDAI, sends you proportional ETH + bonus

**Bonus:** Starts at 10% immediately when vault becomes undercollateralized. Decays to 2% over 3 hours. First mover wins.

**V7 dual-price effect:** During a confirmed crash (Chainlink warning active 30+ min), liquidation eligibility uses live Chainlink price — not committed. Vaults that appear healthy at committed price may be liquidatable at Chainlink price during a real crash.

**Zombie vaults:** If collateral value < debt (ETH crashed severely), `clearBadDebt(address)` seizes all collateral free. Caller keeps it. Remaining debt written off against surplus.

---

## Redemptions

Redemptions enforce the $1 peg from below.

**How it works:**
1. Choose any vault with enough debt to cover your amount
2. Enter bSunDAI amount to burn (minimum 100 bSunDAI)
3. You receive: `amount × $1 / ETH_price` ETH, minus 0.5% fee
4. Vault's debt decreases by the bSunDAI burned
5. Vault's collateral decreases by the ETH paid out

**Redemptions always execute at the oracle price.** 1 bSunDAI = $1 worth of ETH. No slippage on the redemption itself.

**Why this creates the peg:** If bSunDAI ever trades below $1 on market, arbitrageurs buy cheap and redeem at full $1 value, pocketing the spread. This loop closes automatically.

---

## Stability Fee and Surplus Buffer

**0.5% annual stability fee** accrues continuously to vault debt. 1,000 bSunDAI debt grows by ~5 bSunDAI/year. Collected fees accumulate as `surplusBuffer` — protocol equity in bSunDAI units.

**Surplus flow:**
```
Stability fee → surplusBuffer
Bad liquidation → badDebtAccumulated
reconcile()   → nets them: surplusBuffer absorbs badDebt first
systemEquity = surplusBuffer - badDebtAccumulated
```

Positive equity means the protocol can absorb bad debt from future liquidations before it propagates. Protocol has no treasury receiver — fees stay in the contract as a reserve.

---

## Debt Ceiling

Immutable limit set at deploy time. Mint and auto-mint revert if `totalDebt + amount > DEBT_CEILING`. Displayed in the System State panel with a utilization bar. Cannot be increased without deploying a new vault.

---

## Emergency Functions

| Function | When Available | What it Does |
|----------|---------------|-------------|
| `emergencyUnlock()` | Zero debt + last deposit >30 days | Recover collateral regardless of oracle |
| `emergencyRepay(amount)` | Oracle dead >7 days | Repay debt without oracle price |
| `emergencyWithdrawETH(amount)` | Oracle dead >7 days + zero debt | Withdraw collateral without oracle |

These exist to ensure users can always exit, even if the oracle permanently fails.

---

## Protocol Tools

Public functions callable by any wallet. No economic cost beyond gas.

| Function | What it Does |
|----------|-------------|
| `reconcile()` | Net surplus buffer against bad debt |
| `oracle.refreshPrice()` | Advance oracle state machine |
| `clearBadDebt(addr)` | Seize zombie vault collateral. Caller keeps ETH free. |
| `settleDebt(amount)` | Burn your own bSunDAI to cancel accumulated bad debt |

---

## System Invariants

```
I1  — Min CR:            150% required to mint or maintain position
I2  — Liquidation:       Vaults below 110% CR can be liquidated
I3  — Redemption:        Any vault with debt can be redeemed against at oracle price
I4  — Peg floor:         1 bSunDAI always redeemable for $1 USD worth of ETH
I5  — Oracle resilience: Stale oracle blocks minting, never blocks deposit/repay
I6  — Immutability:      No admin, no pause, no upgrade after setVault()
I7  — Liveness:          7-day oracle failure enables emergency exit paths
I8  — Surplus accounting: Stability fees accumulate as surplus — never lost
I9  — Trust-minimized burn: Vault burns only tokens it holds in its own balance
I10 — Dual-price:        Flash crashes never trigger liquidation; real crashes do
I11 — Bad debt visible:  All bad debt tracked on-chain, never silently absorbed
I12 — Debt ceiling:      Total supply bounded by immutable DEBT_CEILING
```

---

## Deployed Contracts

**Base Mainnet (Chain ID: 8453)** — contracts not yet deployed. Update addresses after deployment.

| Contract | Address |
|----------|---------|
| **bSunDAI Token** | TBD |
| **Vault v7** | TBD |
| **Oracle v7** | TBD |
| **WETH (Base)** | `0x4200000000000000000000000000000000000006` |
| **Aave Oracle** | `0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156` |
| **WETH/USDC V3 0.05%** | `0xd0b53D9277642d899DF5C87A3966A349A798F224` |
| **WETH/USDC V3 0.30%** | `0x6c561B446416E1A00E8E93E221854d6eA4171372` |
| **USDbC/WETH V3 0.05%** | `0x4C36388bE6F416A29C8d8Eee81C771cE6bE14B18` |

**Vault parameters:**
- Min collateral ratio: **150%** · Liquidation threshold: **110%**
- Stability fee: **0.5% APY** · Min action: 0.0001 ETH
- Max bonus: **10%** (decays to 2% over 3h) · Redemption fee: **0.5%** to vault owner
- Withdrawal cooldown: **5 minutes** · Emergency unlock: **30 days** with zero debt
- Oracle staleness limit: **5 minutes** · Oracle dead override: **7 days**

---

## Compiling

**EVM target: `paris`** (Base uses paris/Shanghai EVM — Cancun opcodes like `mcopy` are NOT available on Base mainnet at the time of this deployment).

> If `mcopy` errors appear: add `--evm-version paris` in Remix, or set `evmVersion: "paris"` in Hardhat/Foundry config.

The vault imports token and oracle directly — compile all three together in Remix or use a flattened version.

**Remix:**
1. Import all three `.sol` files
2. Compiler: `0.8.25`, EVM: `paris`
3. Deploy via Injected Provider (MetaMask on Base)

---

## Deploy Order

```
1. Deploy bSunDAI_ASA_Token_v7
   → Records deployer address

2. Deploy bSunDAI_Oracle_BASE_v7
   args: aaveOracle, weth, usdc, pool0, 6, pool1, 6, pool2, 6
   → bootstraps committedPrice from live Chainlink at deploy

3. Deploy bSunDAI_Base_Vault_v7
   args: weth, bsundai_address, oracle_address, debtCeiling
   → sets lastOraclePrice from oracle.peekPrice() at deploy

4. token.setVault(vault_address)
   → permanent latch, one-time call, no admin after this

── system is now fully autonomous ──
```

Update `VAULT_ADDR`, `TOKEN_ADDR`, `ORACLE_ADDR` in both HTML files after deploy.

---

## Security Model

**No admin keys.** `setVault()` is the only privileged function — becomes permanently inaccessible after being called once.

**No upgradeability.** No proxies, no beacons.

**Trust-minimized token.** Vault calls `transferFrom(user → vault)` then burns from its own balance. The vault cannot drain wallets.

**Oracle manipulation resistance.** Committed stepping rejects flash manipulation. 30% Chainlink/TWAP divergence threshold detects oracle-specific attacks.

**Dual-price protects both sides:**
- Conservative stepping: flash crashes don't cascade liquidations
- Chainlink warning track: real crashes don't create perpetual bad debt

**What the contracts cannot do:**
- Mint bSunDAI to arbitrary addresses
- Pause or freeze any function
- Change CR requirements, liquidation ratios, or fee structures
- Access or redirect user collateral outside of vault operations

---

## Frontend Files

| File | Purpose |
|------|---------|
| `index.html` | Main vault UI — deposit, mint, repay, withdraw, oracle status |
| `liquidations.html` | Dashboard — scan all vaults, liquidate, redeem, inspect |
| `sundai-vault-v7-abi.json` | Vault ABI (v7 — 8-return vaultInfo, surplus buffer, debt ceiling) |
| `sundai-token-v7-abi.json` | Token ABI (ERC20 + ERC20Permit) |
| `sundai-oracle-v7-abi.json` | Oracle ABI (dual-price, warning track, source status) |
| `ethers.umd.min.js` | ethers.js v6 bundled — no CDN dependency |
| `sundailogo.png` | Protocol logo |
| `contracts/bSunDAI_ASA_Token_v7.sol` | Token source |
| `contracts/bSunDAI_Base_Vault_v7.sol` | Vault source |
| `contracts/bSunDAI_Oracle_BASE_v7.sol` | Oracle source |

**GitHub Pages:** Push this folder to a GitHub repo, enable Pages on root branch.

---

*bSunDAI is experimental software. No audits have been performed. Use at your own risk.*

**License: MIT**
