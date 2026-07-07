# bSunDAI V9

**Autonomous · Ownerless · Immutable · Base Chain**

bSunDAI is an ETH-collateralized autonomous stable asset on Base Chain. Users lock ETH as collateral and mint bSunDAI — a USD-pegged token backed by over-collateralization, a Stability Pool, a redemption mechanism, and a stability fee. There are no admin keys, no upgradeability, and no governance. Once deployed, the protocol runs forever.

> *"The bank is immutable Solidity. The monetary policy is enforced by mathematics."*

---

## Table of Contents

1. [What is bSunDAI?](#what-is-bsundai)
2. [V9 Improvements](#v9-improvements)
3. [The Oracle (Dual-Price System)](#the-oracle-dual-price-system)
4. [How to Use](#how-to-use)
5. [Vault Health Zones](#vault-health-zones)
6. [Liquidations](#liquidations)
7. [Stability Pool](#stability-pool)
8. [Redemptions](#redemptions)
9. [Stability Fee and Surplus Buffer](#stability-fee-and-surplus-buffer)
10. [Debt Ceiling](#debt-ceiling)
11. [Emergency Functions](#emergency-functions)
12. [Protocol Tools](#protocol-tools)
13. [System Invariants](#system-invariants)
14. [Deployed Contracts](#deployed-contracts)
15. [Compiling](#compiling)
16. [Deploy Order](#deploy-order)
17. [Security Model](#security-model)
18. [Frontend Files](#frontend-files)

---

## What is bSunDAI?

bSunDAI is a CDP (Collateralized Debt Position) protocol. Users lock ETH as collateral and borrow bSunDAI against it. Each bSunDAI targets **$1 USD** — the peg is enforced by:

1. **Over-collateralization** — minimum 150% CR to mint
2. **Stability fee** — 0.5% APY applied to debt, creating sell pressure when supply is high
3. **Redemption** — any holder can redeem bSunDAI for $1 of ETH from any vault, creating a hard peg floor
4. **Liquidations** — vaults below 110% CR are liquidated by external parties, preventing bad debt

The protocol does not require any human intervention to maintain the peg. There is no governance, no admin, no pausing.

---

## V9 Improvements

V9 closes a critical gap found in the V7 draft (never deployed with this bug live) and brings bSunDAI up to parity with the pSunDAI V9 hardening pass on PulseChain.

### Stability Pool (new)
Standard Liquity-style Product-Sum accounting. Depositors lock bSunDAI in the pool via `provideToStabilityPool(amount)`; anyone can then call `liquidateFromStabilityPool(user)` permissionlessly to absorb an eligible vault's debt atomically — no pre-held bSunDAI or DEX resale needed. The caller gets a small flat tip (0.5% of the repaid value) as gas compensation; the rest of the liquidation bonus (real ETH) plus stability-fee yield (freshly minted bSunDAI) goes to Stability Pool depositors pro-rata. Withdraw anytime via `withdrawFromStabilityPool(amount)`; claim pending ETH gains without withdrawing via `claimCollateralGain()`.

### Fixed `clearBadDebt` (critical fix)
The V7 draft gave away **100% of a zombie vault's collateral for free** to whoever called `clearBadDebt(user)` first, once collateral value dipped under 100% of debt — the same exploit class as a confirmed real bug found in pSunDAI V8. V9 fixes this at the root: `clearBadDebt(user, repayAmount)` now requires the caller to actually burn `repayAmount` bSunDAI (up to the vault's debt) and pays out collateral **strictly pro-rata** — `collateralOut = collateral × repayAmount / debt`, no bonus. Since the vault is underwater by definition, a caller can never receive collateral worth more than they paid: this is a voluntary, loss-taking cleanup action, never a profit opportunity.

### Clamped Liquidation Price
Liquidation eligibility/reward reads `oracle.getLiquidationPrice()`, which hard-clamps the live-Chainlink liquidation track to within **15%** of the conservative committed price once it activates. Chainlink is far harder to manipulate in a single transaction than an on-chain AMM spot price, but an unclamped live-price path is still a real amplifier for extreme volatility, a feed glitch, or a compromised oracle wrapper — this closes that gap the same way pSunDAI V9 did after finding an unbounded-liquidation-profit exploit in pSunDAI V8.

### Dynamic Debt Capacity (new)
`effectiveDebtCeiling() = min(DEBT_CEILING, maxSafeDebt())`. `maxSafeDebt()` reads real, live DEX depth — raw WETH + quote-token ERC20 balances held across the oracle's 3 Uniswap V3 pools, in USD — times a `SAFE_CAPACITY_MULTIPLIER` of 5. It grows automatically as Base liquidity deepens, with no redeploy ever needed to raise it; the immutable `DEBT_CEILING` exists only as a distant outer backstop in case of an oracle/pool malfunction. `vaultCap() = maxSafeDebt() / MAX_VAULTS_AT_CAP` (10) additionally forces diversification — no single vault can claim the whole ceiling.

### MIN_LIQUIDATION_BPS (new, 20%)
Partial liquidations must repay at least 20% of a vault's debt per call — prevents dust-liquidation griefing (many tiny partial liquidations harassing a vault owner or gaming the Dutch-auction clock).

### No Liquidation Cooldown (removed)
The old 10-minute per-vault cooldown between liquidations is gone — it would have blocked the Stability Pool from immediately mopping up a follow-on partial liquidation.

### `depositAndAutoMintETH` Ceiling Behavior
If the debt ceiling is full, the deposit still succeeds — only the auto-mint is skipped. A user's ETH should never bounce because the protocol-wide mint ceiling happened to be full at that moment.

### Carried Forward Unchanged (already correct)
- **Dual-Price Liquidation** — Committed Price (conservative stepping, ≤2% down / ≤5% up instant, 4h/30min confirmation for larger moves) plus the Chainlink Warning Track (3%+ divergence sustained 30 min → live-Chainlink liquidation track, now clamped as above).
- **Surplus Buffer + Bad Debt Accounting** — `surplusBuffer`, `badDebtAccumulated`, `systemEquity()`, `reconcile()`. Note: `clearBadDebt` no longer feeds `badDebtAccumulated` — any shortfall is now absorbed by the caller directly, not the protocol, since repayment is always proportional and voluntary.
- **Inverted Dutch Auction** — bonus starts at 10%, decays to 2% over 3 hours. First mover wins the highest bonus.
- **Redemption mechanism, permit-based single-tx operations, zombie vault views, emergency functions** — all unchanged from prior versions.

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

**Bonus:** Starts at 10% immediately when vault becomes undercollateralized. Decays to 2% over 3 hours. First mover wins. Partial liquidations must repay at least 20% of the vault's debt (`MIN_LIQUIDATION_BPS`) — prevents dust-liquidation griefing.

**Dual-price effect:** During a confirmed crash (Chainlink warning active 30+ min), liquidation eligibility uses live Chainlink price — clamped to within 15% of committed price — instead of committed. Vaults that appear healthy at committed price may be liquidatable at the (clamped) Chainlink price during a real crash.

**Stability Pool absorption:** Anyone can call `liquidateFromStabilityPool(user)` permissionlessly on an eligible vault — no bSunDAI required from the caller, who receives a small flat tip as gas compensation. See [Stability Pool](#stability-pool) below.

**Zombie vaults:** If collateral value < debt (ETH crashed severely), `clearBadDebt(user, repayAmount)` lets anyone voluntarily unwind the vault — repay `repayAmount` bSunDAI (up to the vault's debt) and receive collateral **strictly pro-rata**, no bonus. Since the vault is underwater by definition, this can never be a profit opportunity — it's a loss-taking cleanup action.

---

## Stability Pool

Depositors lock bSunDAI in the Stability Pool, which backstops the system by absorbing liquidations atomically — no keeper needs to pre-hold bSunDAI or resell seized collateral into a DEX.

**Depositing and withdrawing:**
- `provideToStabilityPool(amount)` — deposit bSunDAI (requires ERC20 approval first). Harvests any pending ETH gain automatically.
- `withdrawFromStabilityPool(amount)` — withdraw up to your compounded balance. Harvests any pending gain first.
- `claimCollateralGain()` — claim pending ETH gains without depositing or withdrawing.

**Earning yield:** Depositors earn two things, both auto-compounding:
1. **Liquidation bonus (ETH)** — when `liquidateFromStabilityPool(user)` fires, the pool's bSunDAI burns to cover the vault's debt, and depositors receive the seized collateral (principal + Dutch-auction bonus) pro-rata to their share of the pool.
2. **Stability fee yield (bSunDAI)** — the 0.5% APY stability fee, instead of just accumulating in `surplusBuffer`, mints directly into the pool as yield whenever the pool has deposits — real yield funded by the same borrower debt growth.

**How compounding works:** Standard Liquity-style Product-Sum accounting (`P`, `S`, `currentScale`, `currentEpoch`). Your compounded deposit shrinks proportionally every time the pool absorbs a loss, and grows proportionally every time it earns fee yield — no manual restaking needed. If the pool is ever fully wiped out (100% loss in one event), your principal compounds to zero but you still keep whatever ETH gain accrued from that final event; a fresh epoch starts for anyone depositing afterward.

**Views:** `getCompoundedStabilityDeposit(depositor)`, `getDepositorCollateralGain(depositor)`, `getStabilityPoolStats()` (totals, `P`, scale, epoch).

**Partial coverage:** If the pool can't fully cover a vault's debt, `liquidateFromStabilityPool` offsets `min(vaultDebt, totalStabilityDeposits)` and the vault stays open — still liquidatable via the ordinary `liquidate()` keeper path or `clearBadDebt()` for the remainder.

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

`effectiveDebtCeiling() = min(DEBT_CEILING, maxSafeDebt())`. Mint and auto-mint revert (or, for auto-mint, just skip the mint and keep the deposit) if `totalDebt + amount` would exceed it.

- `DEBT_CEILING` — immutable, set at deploy time. A distant outer backstop only, in case of an oracle/pool malfunction — cannot be changed without deploying a new vault.
- `maxSafeDebt()` — real-time, liquidity-derived: live WETH + quote-token balances across the oracle's 3 pools (USD) × `SAFE_CAPACITY_MULTIPLIER` (5). Grows automatically as Base liquidity deepens — no redeploy ever needed to raise it.
- `vaultCap()` — `maxSafeDebt() / MAX_VAULTS_AT_CAP` (10). Maximum debt a single vault may hold, forcing natural diversification.

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
| `clearBadDebt(addr, repayAmount)` | Voluntarily unwind a zombie vault — repay pro-rata, receive collateral pro-rata, no bonus |
| `liquidateFromStabilityPool(addr)` | Permissionlessly liquidate an eligible vault using pooled bSunDAI — no capital required, caller gets a small tip |
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
I10 — Dual-price:        Flash crashes never trigger liquidation; real crashes do, clamped to 15% of committed
I11 — Bad debt visible:  All bad debt tracked on-chain, never silently absorbed
I12 — Debt ceiling:      Total supply bounded by min(immutable DEBT_CEILING, live maxSafeDebt())
I13 — No free extraction: clearBadDebt() always pays strictly pro-rata — never a profit opportunity
I14 — Stability Pool solvency: Product-Sum accounting never lets P underflow to zero
```

---

## Deployed Contracts

**Base Mainnet (Chain ID: 8453)** — live.

| Contract | Address |
|----------|---------|
| **bSunDAI Token** | `0x0594A2B4916dc2299e8e322973dC344C8c92BF4c` |
| **Vault v9** | `0x974cb2F1f02c520B796d0F0ECc9b8F58d69E0913` |
| **Oracle v9** | `0xdDbfBF4F6FCf11E9E8Ea1b2E2054e8ffeBC2dF9e` |
| **WETH (Base)** | `0x4200000000000000000000000000000000000006` |
| **Aave Oracle** | `0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156` |
| **WETH/USDC V3 0.05%** | `0xd0b53D9277642d899DF5C87A3966A349A798F224` |
| **WETH/USDC V3 0.30%** | `0x6c561B446416E1A00E8E93E221854d6eA4171372` |
| **USDbC/WETH V3 0.05%** | `0x4C36388bE6F416A29C8d8Eee81C771cE6bE14B18` |

**Vault parameters:**
- Min collateral ratio: **150%** · Liquidation threshold: **110%**
- Stability fee: **0.5% APY** · Min action: 0.0001 ETH
- Max bonus: **10%** (decays to 2% over 3h) · Min partial liquidation: **20%** of debt · Redemption fee: **0.5%** to vault owner
- Withdrawal cooldown: **5 minutes** · Emergency unlock: **30 days** with zero debt
- Oracle staleness limit: **5 minutes** · Oracle dead override: **7 days**
- Debt ceiling: **500,000,000 bSunDAI** (immutable outer backstop) · Dynamic capacity multiplier: **5×** real DEX depth

---

## Compiling

**Compiler: `0.8.20`, EVM target: `shanghai`.** Base fully supports Shanghai; Cancun opcodes like `mcopy` are avoided for consistency with the tested build.

The vault is large enough to approach the 24KB (EIP-170) contract size limit. If you hit "Contract code size exceeds 24576 bytes" in Remix, enable **revert-string stripping** (`debug.revertStrings: "strip"` in a custom compiler config, or via IR if your Remix build exposes it) — this drops the vault comfortably under the limit with zero logic changes. Only cost: failed transactions won't carry a human-readable reason string on-chain, just a bare revert.

The vault imports token and oracle directly — compile all three together in Remix or use a flattened version.

**Remix:**
1. Import all three `.sol` files
2. Compiler: `0.8.20`, EVM: `shanghai`, optimizer on/200 runs, revert strings stripped (see above)
3. Pin OpenZeppelin imports to the exact tested version: `@openzeppelin/contracts@5.0.2/...` (Remix's bare `@openzeppelin/contracts/...` resolves to whatever the latest release is, which may require a newer Solidity version)
4. Deploy via Injected Provider (MetaMask on Base)

---

## Deploy Order

```
1. Deploy bSunDAI_ASA_Token_v9
   → Records deployer address

2. Deploy bSunDAI_Oracle_BASE_v9
   args: aaveOracle, weth, usdc, pool0, 6, pool1, 6, pool2, 6
   → bootstraps committedPrice from live Chainlink at deploy

3. Deploy bSunDAI_Base_Vault_v9
   args: weth, bsundai_address, oracle_address, debtCeiling
   → sets lastOraclePrice from oracle.peekPrice() at deploy
   → debtCeiling is just the outer backstop (see Debt Ceiling) — the real
     day-to-day cap is the dynamic maxSafeDebt(), so this can be set
     generously (deployed with 500,000,000e18)

4. token.setVault(vault_address)
   → permanent latch, one-time call, no admin after this

── system is now fully autonomous ──
```

`VAULT_ADDR`, `TOKEN_ADDR`, `ORACLE_ADDR` in both HTML files are already set to the live addresses above.

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
| `sundai-vault-v9-abi.json` | Vault ABI (v9 — Stability Pool, dynamic debt capacity, fixed clearBadDebt) |
| `sundai-token-v9-abi.json` | Token ABI (ERC20 + ERC20Permit) |
| `sundai-oracle-v9-abi.json` | Oracle ABI (dual-price, warning track, clamped liquidation price, source status) |
| `ethers.umd.min.js` | ethers.js v6 bundled — no CDN dependency |
| `sundailogo.png` | Protocol logo |
| `contracts/bSunDAI_ASA_Token_v9.sol` | Token source |
| `contracts/bSunDAI_Base_Vault_v9.sol` | Vault source |
| `contracts/bSunDAI_Oracle_BASE_v9.sol` | Oracle source |

**GitHub Pages:** Push this folder to a GitHub repo, enable Pages on root branch.

---

*bSunDAI is experimental software. No audits have been performed. Use at your own risk.*

**License: MIT**
