# pSunDAI V8

**Autonomous · Ownerless · Immutable · Censorship-Resistant · PulseChain**

pSunDAI is a WPLS-collateralized autonomous stable asset on PulseChain. Users lock PLS (or WPLS) as collateral and mint pSunDAI — a USD-pegged token backed by over-collateralization, a stability fee, and a 5-pool PulseX liquidity-weighted oracle. There are no admin keys, no upgradeability, and no governance. Once deployed, the protocol runs forever.

V8 hardens V7's already-correct logic against gaps that only matter once real value is at stake: a debt ceiling that's actually tied to real oracle liquidity instead of a static number nobody re-checks, a per-vault cap so no single position can concentrate system risk, and a liquidation path that doesn't serialize behind an artificial cooldown.

> *"The bank is immutable Solidity. The monetary policy is enforced by mathematics."*

---

## Table of Contents

1. [Running this off your own computer](#running-this-off-your-own-computer)
2. [What is pSunDAI?](#what-is-psundai)
3. [V8 Improvements over V7](#v8-improvements-over-v7)
4. [The Oracle (5-Pool Liquidity-Weighted TWAP)](#the-oracle-5-pool-liquidity-weighted-twap)
5. [How to Use](#how-to-use)
6. [Vault Health Zones](#vault-health-zones)
7. [Liquidations](#liquidations)
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

## Running this off your own computer

This app is intentionally self-contained — no build step, no CDN dependency, no server-side component. That's not an accident: censorship resistance is a design goal for every protocol in this system, and a frontend that only works when a specific company's server is up isn't actually censorship-resistant, no matter how immutable the contracts underneath it are.

**Three ways to run it, in order of how little you need to trust:**

1. **Double-click `index.html`.** Every asset reference in this folder (`ethers.umd.min.js`, `sundailogo.png`, `favicon.svg`) is a relative path, `ethers.js` is bundled locally rather than pulled from a CDN, and there are no `fetch()` calls to anywhere — the contract ABIs are inlined directly in the HTML. Opening the file directly via `file://` works. The one thing that won't work over `file://` is the service worker (browsers require a secure context for those) — the page degrades gracefully, it just won't get the offline-caching layer.
2. **Run a trivial local server**, if your browser is stricter about `file://` wallet extensions (some are): `python3 -m http.server 8080` from inside this folder, then open `http://localhost:8080/index.html`.
3. **Pull it from IPFS** once pinned (see below) — content-addressed, no single host, no company that can take it down.

None of these require trusting GitHub, a hosting provider, or anyone's server. Your wallet talks directly to PulseChain; this folder is just the interface.

---

## What is pSunDAI?

pSunDAI is a CDP (Collateralized Debt Position) protocol on PulseChain. Users lock WPLS (or native PLS) as collateral and borrow pSunDAI against it. Each pSunDAI targets **$1 USD** — the peg is enforced by:

1. **Over-collateralization** — minimum 150% CR to mint
2. **Stability fee** — 0.5% APY applied to debt, creating sell pressure when supply is high
3. **Liquidations** — vaults below 110% CR are liquidated by external parties, preventing bad debt

The protocol does not require any human intervention to maintain the peg. There is no governance, no admin, no pausing.

> **Note:** pSunDAI does not include a redemption mechanism. Peg maintenance relies on the stability fee and liquidation mechanisms.

---

## V8 Improvements over V7

### Dynamic, Liquidity-Derived Debt Ceiling
The real minting limit is `effectiveDebtCeiling() = min(DEBT_CEILING, oracle.maxSafeDebt())`. `DEBT_CEILING` (100,000,000 pSunDAI) is an immutable outer sanity bound — the number that actually gates minting day to day is `maxSafeDebt()`, which the oracle computes from real pool depth: 20× the **rolling 24-hour minimum** of combined valid-pool reserves, not the instantaneous value. That's deliberately asymmetric — a genuine liquidity drop is reflected immediately (today's depth is always a floor candidate), but a liquidity spike only counts once it's been sustained for the full 24 hours. This closes a flash-liquidity attack: without the rolling minimum, someone could temporarily add liquidity to the oracle's pools, mint against the momentarily-inflated cap, then withdraw the liquidity — leaving debt behind that real liquidity never justified.

### Per-Vault Cap
No single vault may hold more than `oracle.maxSafeDebt() / 10`. Prevents one large position from concentrating a meaningful share of system debt — the scenario where a single vault's liquidation becomes systemically significant on its own.

### Liquidity-Weighted Median
The 5-pool price median now weights each pool's vote by its stable-side reserve depth, so a thin pool can't sway the reported price as much as a deep one. V7 gave every valid pool equal weight regardless of size.

### Staircase-Drift Protection
A rolling 30-minute window tracks cumulative price drift, not just the most recent step. V7's asymmetric confirmation logic (instant moves ≤1% down / ≤5% up, longer confirmation beyond that) could in principle be walked past via many small sub-threshold updates chained together. V8 checks cumulative movement across the window, not just the latest step, before allowing an instant update.

### No Liquidation Cooldown
V7 serialized liquidation calls on a single vault behind a 10-minute clock — fine for many small vaults, a real bottleneck for one large one. V8 removes it entirely; any number of liquidators can clear a large position back-to-back in the same block, each call still bounded by the existing 20%-of-remaining-debt minimum.

### Flash-Mint Liquidation
`liquidateWithFlashMint(user, repayAmount, data)` — additive, doesn't touch `liquidate()`. Lets a liquidator's own contract clear a position without pre-holding pSunDAI: the vault sends the WPLS collateral reward first, then calls back into the caller's `onFlashLiquidation()` so it can swap for pSunDAI and repay within the same transaction. Requires the caller to be a contract implementing `IFlashLiquidationReceiver` — not usable from a plain wallet click, see the Vault Dashboard's Advanced panel for details.

---

## The Oracle (5-Pool Liquidity-Weighted TWAP)

Same dual-track design as V7 (conservative TWAP for minting/withdrawal safety, real-time spot warning for liquidation eligibility during confirmed crashes), plus the V8 additions above.

**Price sources:**
- 2 × WPLS/DAI pools (v1, v2)
- 2 × WPLS/USDC pools (v1, v2)
- 1 × WPLS/USDT pool

**TWAP constants:**
| Parameter | Value | Description |
|-----------|-------|-------------|
| `CONFIRM_TIME_DOWN` | 4 hours | Confirm before accepting >1% downward move |
| `CONFIRM_TIME_UP` | 30 min | Confirm before accepting >5% upward move |
| `STEP_SIZE_DOWN_BPS` | 300 (3%) | Max step per update going down |
| `STEP_SIZE_UP_BPS` | 1000 (10%) | Max step per update going up |
| `INSTANT_UPDATE_DOWN_BPS` | 100 (1%) | ≤1% down: instant, subject to cumulative check |
| `INSTANT_UPDATE_UP_BPS` | 500 (5%) | ≤5% up: instant, subject to cumulative check |
| `STAIRCASE_WINDOW` | 30 min | Rolling window for cumulative drift check |

**Dynamic capacity constants:**
| Parameter | Value | Description |
|-----------|-------|-------------|
| `SAFE_CAPACITY_MULTIPLIER` | 20 | `maxSafeDebt()` = 20× rolling-min combined pool depth |
| `LIQUIDITY_WINDOW` | 24 hours | Rolling window for the liquidity-depth minimum |
| `MAX_VAULTS_AT_CAP` | 10 | Per-vault cap = `maxSafeDebt() / 10` |

**Spot warning constants:**
| Parameter | Value | Description |
|-----------|-------|-------------|
| `SPOT_WARNING_BPS` | 500 (5%) | Threshold below TWAP to trigger warning clock |
| `SPOT_CONFIRM_TIME` | 30 min | Sustained time before liquidations switch to spot |

**Oracle states (`getPriceStatus` returns):**
| Field | Description |
|-------|-------------|
| `currentPrice` | TWAP committed price — used for vault safety checks |
| `marketPrice` | Current 5-pool liquidity-weighted spot median |
| `divergenceBps` | Divergence between TWAP and spot in basis points |
| `inConfirmation` | A price update is pending confirmation |
| `confirmTimeRemaining` | Time until confirmation completes |
| `targetPrice` | Target being confirmed |
| `spotWarningActive` | Spot is 5%+ below TWAP |
| `spotLiquidationEnabled` | Warning active for 30+ min — liquidations use spot |

**Poke:** Anyone can advance the oracle state machine by calling `poke()`. Rate-limited to once per 30 minutes. Also refreshes the rolling liquidity-depth sample feeding `maxSafeDebt()`, subject to its own 3-hour spacing.

**Dead oracle override:** If the oracle is dead for 7+ days, emergency repay and withdraw are enabled regardless of price data.

---

## How to Use

### Auto Mode (Recommended)
1. Connect a wallet on PulseChain (chain ID 369)
2. Enter a PLS amount in the Auto tab
3. Click **1-Click Auto Borrow** — deposits PLS and mints pSunDAI at 155% CR in one transaction

**Note:** the deposit always succeeds even if the mint doesn't. If the dynamic debt ceiling or your vault's cap is reached at the moment you transact, the contract silently skips the mint while the deposit still lands — the UI checks the transaction receipt and tells you which actually happened, rather than assuming success.

### Manual Flow
**Deposit PLS** → lock native PLS as collateral (auto-wrapped to WPLS internally). Or deposit WPLS directly after approval.

**Mint pSunDAI** → borrow USD-equivalent against your PLS. Minimum 150% CR after mint, and bounded by your vault's cap.
```
CR = (WPLS Collateral × PLS Price) ÷ pSunDAI Debt × 100%
```

**Repay** → burn pSunDAI to reduce debt. No approval needed — the vault has direct privileged burn rights.

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

When a vault's CR falls below 110%, it becomes liquidatable — via the [Vault Dashboard](liquidations.html).

**Process:**
1. Open Vault Dashboard → Liquidate tab
2. Scan all vaults — finds those below 110% CR
3. Click Liquidate, enter pSunDAI to repay (minimum 20% of vault debt)
4. Confirm — vault burns your pSunDAI, sends you proportional PLS + bonus

**Bonus:** starts at **2%** when the auction clock begins, grows to **5%** at the 3-hour mark. Call `markUndercollateralized(addr)` to start the clock without liquidating.

**No cooldown (V8 change):** any number of liquidation calls can land on the same vault back-to-back — multiple liquidators can clear a large position in parallel instead of waiting on a per-vault clock.

**Zombie vaults:** if collateral value < 100% of debt, `clearBadDebt(address)` seizes all collateral free. Caller keeps it. Remaining debt written off against the surplus buffer.

---

## Stability Fee and Surplus Buffer

**0.5% annual stability fee** accrues continuously to vault debt. Collected fees accumulate as `surplusBuffer` — protocol equity, the first line of defense against bad debt. Flash-mint liquidation fees (0.2% of repaid amount) also flow into this buffer.

```
Stability fee / flash-mint fee → surplusBuffer
Bad liquidation                → badDebtAccumulated
reconcile()                    → nets them automatically on every fee accrual
systemEquity = surplusBuffer - badDebtAccumulated
```

---

## Debt Ceiling

`DEBT_CEILING` is an immutable outer bound picked at deploy time (100,000,000 pSunDAI on this deployment). The number that actually constrains minting day to day is `effectiveDebtCeiling() = min(DEBT_CEILING, oracle.maxSafeDebt())` — see [V8 Improvements](#v8-improvements-over-v7) above. Neither side can be changed after deployment.

---

## Emergency Functions

| Function | When Available | What it Does |
|----------|---------------|-------------|
| `emergencyUnlock()` | Zero debt + last deposit >30 days | Recover PLS regardless of oracle |
| `emergencyRepay(amount)` | Oracle dead >7 days | Repay debt without oracle price |
| `emergencyWithdrawPLS(amount)` | Oracle dead >7 days + zero debt | Withdraw PLS without oracle |

These exist so users can always exit their own position, even if the oracle permanently fails.

---

## Protocol Tools

Public functions callable by any wallet. No economic cost beyond gas, except the flash-mint path which requires a contract caller.

| Function | What it Does |
|----------|-------------|
| `reconcile()` | Net surplus buffer against bad debt |
| `oracle.poke()` | Advance oracle TWAP + liquidity-sample state machine (30 min cooldown) |
| `markUndercollateralized(addr)` | Start the 3-hour liquidation bonus clock without liquidating |
| `clearBadDebt(addr)` | Seize zombie vault collateral. Caller keeps PLS free. |
| `settleDebt(amount)` | Burn your own pSunDAI to cancel accumulated bad debt |
| `liquidate(user, repayAmount)` | Standard liquidation — caller must already hold the pSunDAI being repaid |
| `liquidateWithFlashMint(user, repayAmount, data)` | Liquidation without pre-holding pSunDAI — caller must be a contract implementing `IFlashLiquidationReceiver` |

---

## System Invariants

```
I1  — Min CR:              150% required to mint or maintain position
I2  — Liquidation:         Vaults below 110% CR can be liquidated
I3  — No redemption:       pSunDAI does not include a redemption mechanism
I4  — Oracle resilience:   Stale oracle blocks minting, never blocks deposit/repay
I5  — Immutability:        No admin, no pause, no upgrade after setVault()
I6  — Liveness:            7-day oracle failure enables emergency exit paths
I7  — Surplus accounting:  Stability fees and flash-mint fees accumulate as
                            surplus — never lost
I8  — Privileged burn:     Vault burns from msg.sender directly via onlyVault
                            token.burn(); no approve needed
I9  — Dual-track:          Flash crashes never trigger spot liquidation; real
                            crashes do
I10 — Bad debt visible:    All bad debt tracked on-chain, never silently absorbed
I11 — Effective ceiling:   Total supply bounded by min(immutable DEBT_CEILING,
                            oracle.maxSafeDebt()) — the dynamic side moves with
                            real pool liquidity, the static side never can (V8:
                            changed from V7's single immutable DEBT_CEILING)
I12 — Bonus growing:       Liquidation bonus starts at min (2%), grows to
                            max (5%) over 3 hours
I13 — Per-vault cap:       No single vault's debt may exceed
                            oracle.maxSafeDebt() / MAX_VAULTS_AT_CAP (V8, new)
I14 — Liquidity floor is
      monotonic-safe:      maxSafeDebt() can never be inflated by a liquidity
                            spike sustained less than the 24h rolling window; a
                            genuine liquidity drop is reflected immediately,
                            not after a delay (V8, new)
I15 — No liquidation
      cooldown:             Any number of liquidation calls may land on the same
                            vault in the same block, each still bounded by the
                            20%-minimum-per-call floor (V8: removed V7's
                            10-minute per-vault cooldown)
I16 — Flash-mint atomicity: liquidateWithFlashMint mints no tokens at any point;
                            if repayment fails, the entire transaction — including
                            the collateral transfer — reverts, so no unbacked
                            supply can persist even transiently (V8, new)
```

---

## Deployed Contracts

**PulseChain (Chain ID: 369)** — verified on Sourcify (exact match, creation + runtime bytecode)

| Contract | Address |
|----------|---------|
| **pSunDAI Token** | `0xcf18F50135C0882420788b4477bFe84d263218d6` |
| **Vault V8** | `0x618f73d7aEc2853EdF89d6f69c9bB84519f398db` |
| **Oracle V8** | `0x5328F18b5850eb964ffbBb21B5286E98be9C3153` |

**Required external addresses (PulseChain mainnet):**

| Token | Address |
|-------|---------|
| WPLS | `0xA1077a294dDE1B09bB078844df40758a5D0f9a27` |
| DAI | `0xefD766cCb38EaF1dfd701853BFCe31359239F305` |
| USDC | `0x15D38573d2feeb82e7ad5187aB8c1D52810B1f07` |
| USDT | `0x0Cb6F5a34ad42ec934882A05265A7d5F59b51A2f` |

---

## Compiling

**Compiler:** solc `0.8.20`, `evmVersion: shanghai`. **OpenZeppelin:** v5.0.2 (plain `@openzeppelin/contracts/...` imports). `pSunDAIVault_ASA_v8.sol` requires `via_ir = true` to compile — this is a Foundry codegen setting to resolve a stack-too-deep error in `liquidateWithFlashMint`, it does not change the target EVM version or on-chain behavior.

Source is in `contracts/` in this folder — the exact code deployed at the addresses above, matching what's verified on Sourcify.

**Foundry:**
```
forge init && forge install OpenZeppelin/openzeppelin-contracts@v5.0.2
# copy contracts/ into your src/, set solc_version=0.8.20, evm_version="shanghai", via_ir=true
forge build
```

---

## Deploy Order

```
1. Deploy pSunDAI_ASA (token)
   → Records deployer address

2. Deploy pSunDAIoraclePLSXHybrid_v8
   args: pairDAIv1, pairDAIv2, pairUSDCv1, pairUSDCv2, pairUSDT,
         wpls, dai, usdc, usdt
   → bootstraps lastPrice from spot median at deploy; seeds the first
     rolling liquidity sample from current pool state — deploy when
     pools reflect real conditions, since that first sample sits in the
     24h rolling window regardless of direction

3. Deploy pSunDAIVault_ASA_v8
   args: wpls, psundai_address, oracle_address, debtCeiling
   → sets lastOraclePrice from oracle.peekPriceView() at deploy

4. oracle.setVault(vault_address)
   → permanent latch, one-time call, enables getPriceWithTimestamp()

5. token.setVault(vault_address)
   → permanent latch, one-time call, no admin after this

── system is now fully autonomous ──
```

Contract addresses are live on PulseChain — already set in both HTML files.

---

## Security Model

**No admin keys.** `setVault()` is the only privileged function on both token and oracle — becomes permanently inaccessible after being called once.

**No upgradeability.** No proxies, no beacons.

**Direct privileged burn.** The pSunDAI token exposes `burn(address from, uint256 amount)` gated by `onlyVault`. No ERC20 `approve()` is required before repaying or liquidating.

**Oracle manipulation resistance.** 5-pool liquidity-weighted median, confirmation periods for large moves, a rolling cumulative-drift check against chained small moves, and a rolling-minimum liquidity floor against flash-liquidity cap inflation.

**What the contracts cannot do:**
- Mint pSunDAI to arbitrary addresses
- Pause or freeze any function
- Change CR requirements, liquidation ratios, or fee structures
- Access or redirect user collateral outside of vault operations
- Raise `DEBT_CEILING` past its deploy-time value, regardless of how much oracle liquidity grows

---

## Frontend Files

| File | Purpose |
|------|---------|
| `index.html` | Main vault UI — deposit, mint, repay, withdraw, oracle status, system state |
| `liquidations.html` | Dashboard — scan all vaults, liquidate, inspect, flash-mint liquidation reference |
| `ethers.umd.min.js` | ethers.js v6 bundled — no CDN dependency |
| `manifest.json` | PWA manifest |
| `sw.js` | Service worker — cache-first, offline-friendly on IPFS |
| `sundailogo.png`, `favicon.svg` | Protocol branding |
| `contracts/pSunDAI_ASA_Token_v7.sol` | Token source (unchanged from V7) |
| `contracts/pSunDAIVault_ASA_v8.sol` | Vault source |
| `contracts/pSunDAI_Oracle_Hybrid_v8.sol` | Oracle source |

Both HTML files have contract ABIs inlined directly — no external fetch, no build step. All contract addresses are already set.

**Mirrors:**
- GitHub Pages: https://elitev5.github.io/SunDAIV2/pSunDAIV8/index.html
- IPFS: current CID tracked in `latest-cid.txt` at [github.com/elitev5/SunDAIV2](https://github.com/elitev5/SunDAIV2) (`pSunDAIV8/latest-cid.txt`). That file lives only in the GitHub source, not inside the pinned content itself — a file can't reference the hash of the folder it's part of, so this README doesn't hardcode a specific CID, and every re-pin (including one triggered by editing this file) produces a new one.
  - **This line only resolves if you're reading it on GitHub.** If you're viewing this README from inside an IPFS-pinned copy, `latest-cid.txt` isn't sitting next to it for the same self-reference reason — use the GitHub link above to find the current CID instead. Once you have any CID, any public gateway works: `https://ipfs.io/ipfs/<cid>/index.html`, or a local IPFS node.

---

*pSunDAI V8 is experimental software. No professional third-party audit has been performed. It passed an internal Foundry test suite and two independent AI review passes, which is not a substitute for professional review. Use at your own risk.*

**License: MIT**
