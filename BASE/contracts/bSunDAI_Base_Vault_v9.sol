// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║          bSunDAI Vault v9 — Base Chain CDP Stablecoin Vault          ║
 * ║                                                                      ║
 * ║   License:  MIT | One-Time Setup | Then Immutable Forever            ║
 * ║                                                                      ║
 * ║   Renamed v7 → v9 to stay version-aligned with pSunDAI V9            ║
 * ║   (PulseChain). This is the Base-chain sibling of that hardening     ║
 * ║   pass — same fixes, same Stability Pool design, ported here.        ║
 * ║                                                                      ║
 * ║   v9 CHANGES FROM v7:                                                ║
 * ║                                                                      ║
 * ║   STABILITY POOL (new)                                               ║
 * ║   Liquity-style Product-Sum accounting. Depositors lock bSunDAI,      ║
 * ║   which absorbs liquidations atomically via liquidateFromStability-   ║
 * ║   Pool() — no keeper needs to pre-hold bSunDAI or resell collateral   ║
 * ║   into a DEX. Depositors earn the liquidation bonus (WETH) plus       ║
 * ║   stability-fee yield (freshly minted bSunDAI, see _distributeFee).   ║
 * ║   The v7 draft had zero backstop beyond an ordinary keeper calling    ║
 * ║   liquidate() with pre-held bSunDAI — this was the single biggest     ║
 * ║   gap versus pSunDAI V9.                                              ║
 * ║                                                                      ║
 * ║   FIXED clearBadDebt (was a critical bug in the v7 draft)             ║
 * ║   New signature: clearBadDebt(address user, uint256 repayAmount).     ║
 * ║   The v7 draft gave 100% of a zombie vault's collateral away for      ║
 * ║   FREE to whoever called it first — same exploit class as a           ║
 * ║   confirmed real bug found in pSunDAI V8. Fixed identically: caller   ║
 * ║   must now actually burn repayAmount bSunDAI (up to v.debt) and       ║
 * ║   receives collateral strictly pro-rata (collateral * repayAmount /   ║
 * ║   debt), no bonus. Since the vault is underwater by definition, a     ║
 * ║   caller can never receive collateral worth more than they paid —    ║
 * ║   this is a voluntary loss-taking cleanup action, never a profit      ║
 * ║   opportunity. No longer feeds badDebtAccumulated (see docstring).    ║
 * ║                                                                      ║
 * ║   CLAMPED LIQUIDATION PRICE                                           ║
 * ║   Liquidation eligibility/reward now reads oracle.getLiquidationPrice ║
 * ║   (), which hard-clamps the live-Chainlink liquidation track to       ║
 * ║   within 15% of committedPrice once it activates. The v7 draft used   ║
 * ║   raw, unclamped live Chainlink — Chainlink is far harder to          ║
 * ║   manipulate in one transaction than an AMM spot price, but an        ║
 * ║   unclamped live-price path is still a real amplifier for extreme     ║
 * ║   volatility, a feed glitch, or a compromised oracle wrapper. Same    ║
 * ║   defense-in-depth pattern pSunDAI V9 added after finding an          ║
 * ║   unbounded-liquidation-profit exploit in pSunDAI V8.                 ║
 * ║                                                                      ║
 * ║   MIN_LIQUIDATION_BPS (new, 20%)                                      ║
 * ║   Partial liquidations must repay at least 20% of a vault's debt      ║
 * ║   per call — prevents dust-liquidation griefing (many tiny partial    ║
 * ║   liquidations harassing a vault owner or gaming the Dutch-auction    ║
 * ║   clock). Ported from pSunDAI V9; the v7 draft had no such floor.     ║
 * ║                                                                      ║
 * ║   NO LIQUIDATION COOLDOWN (removed)                                   ║
 * ║   v7's 10-minute per-vault LIQUIDATION_COOLDOWN is gone — it would    ║
 * ║   block the Stability Pool from immediately mopping up a follow-on    ║
 * ║   partial liquidation. Matches pSunDAI V9, which has no cooldown for  ║
 * ║   the same reason.                                                    ║
 * ║                                                                      ║
 * ║   depositAndAutoMintETH ceiling behavior                              ║
 * ║   v7 reverted the ENTIRE deposit if the debt ceiling was hit during   ║
 * ║   auto-mint. v9 just skips the mint and keeps the deposit — matches   ║
 * ║   pSunDAI V9's UX (a user's ETH should never get bounced because the  ║
 * ║   protocol-wide mint ceiling happened to be full).                    ║
 * ║                                                                      ║
 * ║   DYNAMIC DEBT CAPACITY (added after the oracle was already deployed) ║
 * ║   effectiveDebtCeiling() = min(DEBT_CEILING, maxSafeDebt()), matching  ║
 * ║   pSunDAI V9's design exactly. maxSafeDebt() = real DEX depth (raw     ║
 * ║   WETH + quote-token ERC20 balances across the oracle's 3 pools, in   ║
 * ║   USD) * SAFE_CAPACITY_MULTIPLIER (5x). Grows automatically as Base   ║
 * ║   liquidity deepens — no redeploy ever needed to raise it. Reads the  ║
 * ║   pool addresses/quote-decimals already public on the (immutable,     ║
 * ║   already-deployed) oracle — no oracle changes required. Uses raw     ║
 * ║   pool token balances rather than Uniswap V3's in-range liquidity()   ║
 * ║   value, since converting concentrated liquidity into a real token    ║
 * ║   amount needs full tick/price-range math; a raw balance read is      ║
 * ║   simple, robust, and errs toward counting more committed capital     ║
 * ║   (including out-of-range positions) rather than a narrower,          ║
 * ║   easier-to-game instantaneous slice of it. DEBT_CEILING remains as   ║
 * ║   an immutable outer backstop only, in case of an oracle/pool         ║
 * ║   malfunction. vaultCap() = maxSafeDebt() / MAX_VAULTS_AT_CAP (10)     ║
 * ║   forces diversification — no single vault can claim the whole        ║
 * ║   ceiling.                                                            ║
 * ║                                                                      ║
 * ║   PRESERVED FROM v7 (bSunDAI-specific, already correct, not part of   ║
 * ║   the pSunDAI parity work):                                           ║
 * ║   ✓ Redemption mechanism — hard $1 peg floor (pSunDAI has none)       ║
 * ║   ✓ Permit-based single-tx operations (repay/liquidate/redeem)        ║
 * ║   ✓ Inverted Dutch auction: 10% → 2% over 3h (high bonus first)       ║
 * ║   ✓ Zombie vault views (isZombieVault, vaultBadDebt, systemBadDebt)   ║
 * ║   ✓ emergencyRepay / emergencyWithdrawETH / emergencyUnlock           ║
 * ║                                                                      ║
 * ║   NOT ADDED (considered, deliberately skipped):                       ║
 * ║   ✗ liquidateWithFlashMint — the Stability Pool already covers the    ║
 * ║     "liquidator doesn't need to pre-hold bSunDAI" use case with less  ║
 * ║     attack surface than an external-callback flash-liquidation path.  ║
 * ║                                                                      ║
 * ║   Deploy args: weth, bsundai, oracle, debtCeiling                     ║
 * ║   Dev: Elite Team6 | https://www.sundaitoken.com                      ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

import "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts@5.0.2/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts@5.0.2/utils/math/Math.sol";

import "./bSunDAI_ASA_Token_v9.sol";
import "./bSunDAI_Oracle_BASE_v9.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/// @dev Minimal read-only interface for the oracle's three Uniswap V3 pools
///      - only what's needed to identify which side is WETH vs quote token
///      for the dynamic debt-capacity calculation below.
interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract bSunDAIVault_ASA_v9 is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IERC20                  public immutable weth;
    bSunDAI                 public immutable bsundai;
    bSunDAIoracleBASE_v9    public immutable oracle;

    /// @notice Immutable protocol-level debt ceiling (in bSunDAI, 1e18 units).
    uint256                 public immutable DEBT_CEILING;

    string public constant VERSION = "bSunDAIVault_ASA_v9.0";

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant COLLATERAL_RATIO     = 150;
    uint256 public constant AUTO_MINT_RATIO      = 155;
    uint256 public constant LIQUIDATION_RATIO    = 110;
    uint256 public constant MIN_ACTION_AMOUNT    = 1e14;
    uint256 public constant WITHDRAW_COOLDOWN    = 300;
    uint256 public constant STABILITY_FEE_BPS    = 50;
    uint256 public constant SECONDS_PER_YEAR     = 31_536_000;

    /// @notice Liquidation Dutch auction: starts at 10%, decreases to 2% over 3h
    uint256 public constant MIN_BONUS_BPS        = 200;
    uint256 public constant MAX_BONUS_BPS        = 1000;
    uint256 public constant AUCTION_TIME         = 3 hours;

    /// @notice Minimum fraction of a vault's debt a single partial liquidation
    ///         must repay (20%) — prevents dust-liquidation griefing.
    uint256 public constant MIN_LIQUIDATION_BPS  = 2000;

    uint256 public constant MIN_SYSTEM_HEALTH    = 130;
    uint256 public constant MAX_ORACLE_STALENESS = 300;
    uint256 public constant ORACLE_FAILURE_OVERRIDE = 7 days;

    uint256 public constant REDEMPTION_FEE_BPS   = 50;
    uint256 public constant MIN_REDEMPTION       = 100e18;

    /// @notice Flat tip (fraction of the repaid debt's collateral value) paid to
    ///         whoever triggers liquidateFromStabilityPool(), as gas compensation
    ///         — the rest of the reward goes to Stability Pool depositors.
    uint256 public constant LIQUIDATION_CALLER_TIP_BPS = 50; // 0.5%
    uint256 public constant DECIMAL_PRECISION = 1e18;
    uint256 public constant SCALE_FACTOR      = 1e9;

    /// @notice Dynamic debt capacity multiplier: the real-time-derived safe
    ///         ceiling is real DEX depth (WETH + quote-token balances across
    ///         the oracle's 3 pools, in USD) times this multiplier. Matches
    ///         pSunDAI V9's tightened value (down from an earlier, looser 20x
    ///         that was found to authorize far more debt than real liquidity
    ///         could ever absorb during a large-scale unwind).
    uint256 public constant SAFE_CAPACITY_MULTIPLIER = 5;

    /// @notice A single vault may hold at most maxSafeDebt() / MAX_VAULTS_AT_CAP
    ///         - forces natural diversification instead of one position
    ///         concentrating a large share of system debt as a single
    ///         liquidation target.
    uint256 public constant MAX_VAULTS_AT_CAP = 10;

    /*//////////////////////////////////////////////////////////////
                              VAULT STRUCT
    //////////////////////////////////////////////////////////////*/

    struct Vault {
        uint256 collateral;
        uint256 debt;
        uint256 lastDepositTime;
        uint256 lastWithdrawTime;
        uint256 lastDebtAccrual;
        uint256 undercollateralizedSince;
    }

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    mapping(address => Vault) public vaults;
    uint256 public totalCollateral;
    uint256 public totalDebt;
    uint256 public lastOraclePrice;
    uint256 public lastOracleUpdateTime;

    address[] public vaultOwners;
    mapping(address => bool) public hasVault;

    // ── Surplus buffer + bad debt ────────────────────────────────
    // surplusBuffer: fallback destination for stability fees when the
    //   Stability Pool is empty (nobody to pay yield to yet). Whenever the
    //   Stability Pool is non-empty, fees are minted directly to it instead
    //   (see _distributeFee) — real yield for depositors.
    // badDebtAccumulated: uncovered debt from the interest-accrual dust-
    //   clearing path only. clearBadDebt no longer feeds this — a caller who
    //   unwinds a fully-underwater vault now pays pro-rata, so any shortfall
    //   is absorbed by that caller directly, not the protocol.
    uint256 public surplusBuffer;
    uint256 public badDebtAccumulated;

    // ── v9: Stability Pool state ─────────────────────────────────
    // Standard Liquity-style Product-Sum accounting. `P` starts at
    // DECIMAL_PRECISION and shrinks multiplicatively every time the pool
    // absorbs a loss; each depositor's compounded balance is their initial
    // deposit scaled by how much P has moved since their last snapshot. `S`
    // (per epoch/scale) accumulates the collateral-gain rate so each
    // depositor's claimable gain is computed from the S delta since their
    // snapshot. `currentEpoch` increments (P resets) on a full 100% pool
    // wipeout; `currentScale` increments whenever P would otherwise lose too
    // much precision to remain useful.
    struct StabilitySnapshot {
        uint256 P;
        uint256 S;
        uint128 scale;
        uint128 epoch;
    }

    uint256 public totalStabilityDeposits;
    uint256 public stabilityPoolCollateral; // WETH held by the pool, claimable pro-rata by depositors
    mapping(address => uint256) public stabilityDeposits;
    mapping(address => StabilitySnapshot) public depositSnapshots;

    uint256 public P = DECIMAL_PRECISION;
    uint128 public currentScale;
    uint128 public currentEpoch;
    mapping(uint128 => mapping(uint128 => uint256)) public epochToScaleToSum;

    uint256 internal lastCollateralError_Offset;
    uint256 internal lastDebtLossError_Offset;
    uint256 internal lastFeeGainError_Offset;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed user, uint256 amount, uint256 ratio);
    event Withdraw(address indexed user, uint256 amount, uint256 ratio);
    event Mint(address indexed user, uint256 amount, uint256 ratio);
    event Repay(address indexed user, uint256 amount, uint256 ratio);
    event Liquidation(address indexed user, uint256 repayAmount, address indexed liquidator, uint256 reward, uint256 ratio, bool isLivePrice);
    event PartialLiquidation(address indexed user, uint256 repayAmount, uint256 debtRemaining, address indexed liquidator);
    event Redemption(address indexed vaultOwner, address indexed redeemer, uint256 bSunDAIBurned, uint256 wethReceived, uint256 feeBps);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event OracleFallbackUsed(uint256 price, uint256 timestamp);
    event EmergencyRepay(address indexed user, uint256 amount, string reason);
    event EmergencyWithdrawETH(address indexed user, uint256 amount, string reason);
    event VaultRegistered(address indexed user);
    event DebtCeilingReached(uint256 totalDebt, uint256 ceiling);

    event BadDebtCleared(address indexed user, uint256 collateralReturned, uint256 debtRepaid, address indexed caller);
    event DebtSettled(uint256 amount, address indexed settler);
    event SurplusReconciled(uint256 amount);

    // v9: Stability Pool events
    event StabilityDeposit(address indexed depositor, uint256 amount);
    event StabilityWithdraw(address indexed depositor, uint256 amount);
    event CollateralGainWithdrawn(address indexed depositor, uint256 amount);
    event StabilityPoolOffset(uint256 debtOffset, uint256 collateralAdded);
    event StabilityPoolEmptied(uint128 newEpoch);
    event StabilityPoolFeeDistributed(uint256 feeAmount);
    event LiquidatedFromStabilityPool(address indexed user, uint256 debtOffset, uint256 collateralToPool, uint256 callerTip, address indexed caller);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _weth,
        address _bsundai,
        address _oracle,
        uint256 _debtCeiling
    ) {
        require(_weth != address(0) && _bsundai != address(0) && _oracle != address(0), "Zero address");
        require(_debtCeiling > 0, "Zero ceiling");
        weth         = IERC20(_weth);
        bsundai      = bSunDAI(_bsundai);
        oracle       = bSunDAIoracleBASE_v9(_oracle);
        DEBT_CEILING = _debtCeiling;

        (lastOraclePrice,) = oracle.peekPrice();
        if (lastOraclePrice == 0) lastOraclePrice = 3000 * 1e18;
        lastOracleUpdateTime = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _sendETH(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    function _collectAndBurn(address from, uint256 amount) internal {
        IERC20(address(bsundai)).safeTransferFrom(from, address(this), amount);
        bsundai.burn(amount);
    }

    function _registerVault(address user) internal {
        if (!hasVault[user]) {
            hasVault[user] = true;
            vaultOwners.push(user);
            emit VaultRegistered(user);
        }
    }

    function _requireOracleFresh() internal view {
        (uint256 p, uint256 ts) = oracle.peekPrice();
        require(p > 0 && block.timestamp - ts <= MAX_ORACLE_STALENESS, "Oracle not fresh");
    }

    /*//////////////////////////////////////////////////////////////
                       DYNAMIC DEBT CAPACITY
    //////////////////////////////////////////////////////////////*/

    /// @dev USD value (1e18) of one pool's real, currently-held token balances
    ///      - both the WETH side and the quote-token side (USDC/USDbC). Uses
    ///      raw ERC20 balances rather than Uniswap V3's in-range `liquidity()`
    ///      value: converting concentrated liquidity into an actual token
    ///      amount needs the current tick and price-range math, while a raw
    ///      balance read is simple, robust, and (if anything) a mildly
    ///      conservative-leaning proxy for "how much real capital backs this
    ///      market" - it counts out-of-range positions too, which wouldn't
    ///      trade at the current price, but errs toward a broader measure of
    ///      committed capital rather than an instantaneous, gameable slice of it.
    function _pairDepthUSD(address pool, uint8 quoteDecimals, uint256 price) internal view returns (uint256) {
        address wethAddr = address(weth);
        address token0 = IUniswapV3PoolMinimal(pool).token0();
        address quoteToken = (token0 == wethAddr) ? IUniswapV3PoolMinimal(pool).token1() : token0;

        uint256 wethBal  = IERC20(wethAddr).balanceOf(pool);
        uint256 quoteBal = IERC20(quoteToken).balanceOf(pool);

        uint256 wethUSD  = (wethBal * price) / 1e18;
        uint256 quoteUSD = quoteDecimals < 18 ? quoteBal * (10 ** uint256(18 - quoteDecimals)) : quoteBal;

        return wethUSD + quoteUSD;
    }

    /// @dev Total real DEX depth (USD, 1e18) across the oracle's 3 pools.
    ///      The oracle itself is immutable and doesn't expose this - all the
    ///      inputs (pool addresses, quote decimals, WETH address) are already
    ///      public immutables on the already-deployed oracle, so this needs
    ///      no oracle changes at all.
    function _dexLiquidityUSD() internal view returns (uint256 totalUSD) {
        (uint256 p,) = oracle.peekPrice();
        uint256 price = p > 0 ? p : lastOraclePrice;

        totalUSD += _pairDepthUSD(oracle.pool0(), oracle.pool0QuoteDecimals(), price);
        totalUSD += _pairDepthUSD(oracle.pool1(), oracle.pool1QuoteDecimals(), price);
        totalUSD += _pairDepthUSD(oracle.pool2(), oracle.pool2QuoteDecimals(), price);
    }

    /// @notice Real-time, liquidity-derived safe debt capacity: real DEX
    ///         depth times SAFE_CAPACITY_MULTIPLIER. Grows automatically as
    ///         Base liquidity deepens - no redeploy ever needed to raise it.
    function maxSafeDebt() public view returns (uint256) {
        return _dexLiquidityUSD() * SAFE_CAPACITY_MULTIPLIER;
    }

    /// @notice Effective debt ceiling actually enforced: the lesser of the
    ///         immutable outer bound (DEBT_CEILING) and the real-time,
    ///         liquidity-derived safe capacity (maxSafeDebt()). Moves
    ///         automatically as pool depth changes; DEBT_CEILING exists only
    ///         as an outer backstop in case of an oracle/pool malfunction.
    function _effectiveDebtCeiling() internal view returns (uint256) {
        uint256 dynamicCap = maxSafeDebt();
        return dynamicCap < DEBT_CEILING ? dynamicCap : DEBT_CEILING;
    }

    function effectiveDebtCeiling() external view returns (uint256) {
        return _effectiveDebtCeiling();
    }

    /// @dev Maximum debt a single vault may hold, derived from the same
    ///      liquidity signal as the effective ceiling - forces diversification.
    function _vaultCap() internal view returns (uint256) {
        return maxSafeDebt() / MAX_VAULTS_AT_CAP;
    }

    function vaultCap() external view returns (uint256) {
        return _vaultCap();
    }

    /*//////////////////////////////////////////////////////////////
                     SURPLUS BUFFER & BAD DEBT
    //////////////////////////////////////////////////////////////*/

    /// @dev Apply surplus buffer against accumulated bad debt.
    function _reconcile() internal {
        if (surplusBuffer > 0 && badDebtAccumulated > 0) {
            uint256 applied = surplusBuffer < badDebtAccumulated ? surplusBuffer : badDebtAccumulated;
            surplusBuffer        -= applied;
            badDebtAccumulated   -= applied;
            emit SurplusReconciled(applied);
        }
    }

    /// @notice Manually trigger reconciliation. Callable by anyone (bots, keepers).
    function reconcile() external nonReentrant {
        _reconcile();
    }

    /// @notice Net system equity in bSunDAI units.
    function systemEquity() external view returns (int256) {
        return int256(surplusBuffer) - int256(badDebtAccumulated);
    }

    /// @notice Burn bSunDAI to directly cancel bad debt accumulated via the
    ///         interest-accrual dust-clearing path.
    function settleDebt(uint256 amount) external nonReentrant {
        require(amount > 0 && badDebtAccumulated >= amount, "Invalid settle amount");
        _collectAndBurn(msg.sender, amount);
        badDebtAccumulated -= amount;
        emit DebtSettled(amount, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                           ORACLE PRICE
    //////////////////////////////////////////////////////////////*/

    function _safePrice() internal returns (uint256 p) {
        uint256 ts;
        (p, ts) = oracle.getPriceWithTimestamp();

        if (p == 0 || block.timestamp - ts > MAX_ORACLE_STALENESS) {
            emit OracleFallbackUsed(lastOraclePrice, block.timestamp);
            return lastOraclePrice > 0 ? lastOraclePrice : 3000 * 1e18;
        }

        lastOraclePrice      = p;
        lastOracleUpdateTime = ts;
        return p;
    }

    /// @dev v9: price to use for liquidation eligibility/reward. Reads the
    ///      oracle's clamped getLiquidationPrice() (live Chainlink, capped to
    ///      15% of committedPrice, once the warning track confirms), else
    ///      falls back to the ordinary committed price.
    function _liquidationPrice() internal returns (uint256 price, bool isLive) {
        (uint256 p, bool live) = oracle.getLiquidationPrice();
        if (live && p > 0) return (p, true);
        return (_safePrice(), false);
    }

    /// @dev View version for read-only checks.
    function _liquidationPriceView() internal view returns (uint256 price, bool isLive) {
        (uint256 p, bool live) = oracle.getLiquidationPrice();
        if (live && p > 0) return (p, true);
        (uint256 tp,) = oracle.peekPrice();
        return (tp > 0 ? tp : lastOraclePrice, false);
    }

    /*//////////////////////////////////////////////////////////////
                           SAFETY CHECKS
    //////////////////////////////////////////////////////////////*/

    function isUXSafe() public view returns (bool) {
        (uint256 p, uint256 ts) = oracle.peekPrice();
        return (p > 0 && block.timestamp - ts <= MAX_ORACLE_STALENESS) && systemHealth() >= MIN_SYSTEM_HEALTH;
    }

    function isOracleCatastrophicallyFailed() public view returns (bool) {
        (, uint256 ts) = oracle.peekPrice();
        return block.timestamp - ts > ORACLE_FAILURE_OVERRIDE;
    }

    /*//////////////////////////////////////////////////////////////
                           VAULT INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _accrueInterest(Vault storage v) internal {
        if (v.debt == 0) return;
        uint256 elapsed = block.timestamp - v.lastDebtAccrual;
        if (elapsed == 0) return;
        uint256 fee = (v.debt * STABILITY_FEE_BPS * elapsed) / (SECONDS_PER_YEAR * 10000);
        if (fee == 0 && elapsed > 0) fee = 1;
        v.debt        += fee;
        totalDebt     += fee;
        v.lastDebtAccrual = block.timestamp;
        _distributeFee(fee);
        _clearDebtDust(v);
        _reconcile();
    }

    /// @dev Forgive sub-dust residual debt, funded from surplusBuffer if available.
    function _clearDebtDust(Vault storage v) internal {
        if (v.debt > 0 && v.debt <= 1e12) {
            uint256 dust = v.debt;
            totalDebt -= dust;
            if (surplusBuffer >= dust) surplusBuffer -= dust;
            else surplusBuffer = 0;
            v.debt = 0;
        }
    }

    function _addCollateral(address user, uint256 amount) internal {
        Vault storage v = vaults[user];
        _registerVault(user);
        v.collateral      += amount;
        v.lastDepositTime  = block.timestamp;
        totalCollateral   += amount;
        emit Deposit(user, amount, _collateralRatio(user));
    }

    function _collateralRatio(address user) internal view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return type(uint256).max;
        (uint256 p,) = oracle.peekPrice();
        uint256 price = p > 0 ? p : lastOraclePrice;
        return (v.collateral * price * 100) / (v.debt * 1e18);
    }

    function systemHealth() public view returns (uint256) {
        if (totalDebt == 0) return type(uint256).max;
        (uint256 p,) = oracle.peekPrice();
        uint256 price = p > 0 ? p : lastOraclePrice;
        return (totalCollateral * price * 100) / (totalDebt * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                         VAULT ENUMERATION
    //////////////////////////////////////////////////////////////*/

    function getVaultCount() external view returns (uint256) {
        return vaultOwners.length;
    }

    function getVaultOwners(uint256 start, uint256 count) external view returns (address[] memory) {
        require(start < vaultOwners.length, "Out of bounds");
        uint256 end = start + count;
        if (end > vaultOwners.length) end = vaultOwners.length;
        uint256 n = end - start;
        address[] memory result = new address[](n);
        for (uint256 i = 0; i < n; i++) result[i] = vaultOwners[start + i];
        return result;
    }

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositETH() external payable nonReentrant {
        require(msg.value >= MIN_ACTION_AMOUNT, "Invalid amount");
        IWETH(address(weth)).deposit{value: msg.value}();
        _addCollateral(msg.sender, msg.value);
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount >= MIN_ACTION_AMOUNT, "Invalid amount");
        weth.safeTransferFrom(msg.sender, address(this), amount);
        _addCollateral(msg.sender, amount);
    }

    function depositAndAutoMintETH() external payable nonReentrant {
        require(msg.value >= MIN_ACTION_AMOUNT, "Invalid amount");
        _requireOracleFresh();

        IWETH(address(weth)).deposit{value: msg.value}();
        _addCollateral(msg.sender, msg.value);

        uint256 price      = _safePrice();
        uint256 mintAmount = (msg.value * price / 1e18 * 100) / AUTO_MINT_RATIO;
        if (mintAmount == 0) return;

        // v9: skip the mint (keep the deposit) rather than reverting the whole
        // tx if the ceiling is full — a user's ETH should never bounce because
        // the protocol-wide mint ceiling happened to be full at that moment.
        uint256 ceiling = _effectiveDebtCeiling();
        Vault storage v = vaults[msg.sender];
        uint256 cap = _vaultCap();
        if (totalDebt + mintAmount > ceiling || v.debt + mintAmount > cap) {
            emit DebtCeilingReached(totalDebt, ceiling);
            return;
        }

        if (v.debt == 0) v.lastDebtAccrual = block.timestamp;
        v.debt    += mintAmount;
        totalDebt += mintAmount;
        bsundai.mint(msg.sender, mintAmount);
        emit Mint(msg.sender, mintAmount, _collateralRatio(msg.sender));
    }

    /*//////////////////////////////////////////////////////////////
                    MINTING & REPAYMENT
    //////////////////////////////////////////////////////////////*/

    function mint(uint256 amount) external nonReentrant {
        require(amount > 0, "Invalid mint");
        require(isUXSafe(), "System not safe");
        require(totalDebt + amount <= _effectiveDebtCeiling(), "Debt ceiling reached");
        Vault storage v = vaults[msg.sender];
        _registerVault(msg.sender);
        _accrueInterest(v);
        if (v.debt == 0) v.lastDebtAccrual = block.timestamp;
        require(systemHealth() >= MIN_SYSTEM_HEALTH, "Mint paused: system undercollateralized");
        require(v.debt + amount <= _vaultCap(), "Vault cap reached");
        uint256 price = _safePrice();
        require(v.collateral * price * 100 >= (v.debt + amount) * COLLATERAL_RATIO * 1e18, "Not enough collateral");
        v.debt    += amount;
        totalDebt += amount;
        bsundai.mint(msg.sender, amount);
        emit Mint(msg.sender, amount, _collateralRatio(msg.sender));
    }

    function _doRepay(uint256 amount) internal {
        Vault storage v = vaults[msg.sender];
        require(amount > 0, "Invalid repay");
        _accrueInterest(v);
        require(v.debt >= amount, "Repay exceeds debt");
        _collectAndBurn(msg.sender, amount);
        v.debt    -= amount;
        totalDebt -= amount;
        _clearDebtDust(v);
        emit Repay(msg.sender, amount, _collateralRatio(msg.sender));
    }

    function repay(uint256 amount) external nonReentrant {
        _doRepay(amount);
    }

    function repayWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 pV, bytes32 pR, bytes32 pS
    ) external nonReentrant {
        bsundai.permit(msg.sender, address(this), amount, deadline, pV, pR, pS);
        _doRepay(amount);
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAWAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function withdrawETH(uint256 amount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.collateral >= amount, "Invalid withdraw");
        require(block.timestamp > v.lastDepositTime + WITHDRAW_COOLDOWN, "Cooldown");
        require(isUXSafe() || v.debt == 0, "Withdraw paused");

        uint256 price = v.debt > 0 ? _safePrice() : 0;
        v.collateral -= amount;
        totalCollateral -= amount;
        if (v.debt > 0) {
            require(v.collateral * price * 100 >= v.debt * COLLATERAL_RATIO * 1e18, "Unsafe");
        }
        v.lastWithdrawTime = block.timestamp;
        IWETH(address(weth)).withdraw(amount);
        _sendETH(msg.sender, amount);
        emit Withdraw(msg.sender, amount, _collateralRatio(msg.sender));
    }

    function repayAndAutoWithdraw(uint256 repayAmount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        _accrueInterest(v);
        require(repayAmount > 0 && v.debt >= repayAmount, "Invalid repay");

        _collectAndBurn(msg.sender, repayAmount);
        v.debt    -= repayAmount;
        totalDebt -= repayAmount;
        _clearDebtDust(v);

        uint256 price = _safePrice();

        if (v.debt == 0) {
            uint256 amt = v.collateral;
            totalCollateral -= amt;
            delete vaults[msg.sender];
            IWETH(address(weth)).withdraw(amt);
            _sendETH(msg.sender, amt);
            emit Withdraw(msg.sender, amt, type(uint256).max);
            return;
        }

        uint256 requiredCollateral = (v.debt * COLLATERAL_RATIO * 1e18) / (price * 100);
        if (v.collateral > requiredCollateral) {
            uint256 withdrawable = v.collateral - requiredCollateral;
            v.collateral    = requiredCollateral;
            totalCollateral -= withdrawable;
            IWETH(address(weth)).withdraw(withdrawable);
            _sendETH(msg.sender, withdrawable);
            emit Withdraw(msg.sender, withdrawable, _collateralRatio(msg.sender));
        }
        emit Repay(msg.sender, repayAmount, _collateralRatio(msg.sender));
    }

    /*//////////////////////////////////////////////////////////////
                    v9: STABILITY POOL
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit bSunDAI into the Stability Pool. Harvests any pending
    ///         collateral gain first. Requires prior ERC20 approval.
    function provideToStabilityPool(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        _harvestAndUpdateSnapshot(msg.sender);

        IERC20(address(bsundai)).safeTransferFrom(msg.sender, address(this), amount);

        stabilityDeposits[msg.sender] += amount;
        totalStabilityDeposits        += amount;

        emit StabilityDeposit(msg.sender, amount);
    }

    /// @notice Withdraw up to `amount` of your compounded Stability Pool deposit.
    function withdrawFromStabilityPool(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        _harvestAndUpdateSnapshot(msg.sender);

        uint256 currentDeposit = stabilityDeposits[msg.sender];
        require(currentDeposit > 0, "No deposit");
        uint256 withdrawAmount = amount > currentDeposit ? currentDeposit : amount;

        stabilityDeposits[msg.sender] = currentDeposit - withdrawAmount;
        totalStabilityDeposits        -= withdrawAmount;

        IERC20(address(bsundai)).safeTransfer(msg.sender, withdrawAmount);
        emit StabilityWithdraw(msg.sender, withdrawAmount);
    }

    /// @notice Claim any pending collateral gain without depositing/withdrawing.
    function claimCollateralGain() external nonReentrant {
        require(stabilityDeposits[msg.sender] > 0, "No deposit");
        _harvestAndUpdateSnapshot(msg.sender);
    }

    /// @dev Pays out the depositor's pending collateral gain and re-snapshots
    ///      their compounded deposit against current P/S/scale/epoch.
    function _harvestAndUpdateSnapshot(address depositor) internal {
        uint256 initialDeposit = stabilityDeposits[depositor];
        if (initialDeposit > 0) {
            uint256 collGain   = _getDepositorCollateralGain(depositor);
            uint256 compounded = _getCompoundedStabilityDeposit(depositor);

            stabilityDeposits[depositor] = compounded;

            if (collGain > 0) {
                stabilityPoolCollateral -= collGain;
                IWETH(address(weth)).withdraw(collGain);
                _sendETH(depositor, collGain);
                emit CollateralGainWithdrawn(depositor, collGain);
            }
        }

        depositSnapshots[depositor] = StabilitySnapshot({
            P:     P,
            S:     epochToScaleToSum[currentEpoch][currentScale],
            scale: currentScale,
            epoch: currentEpoch
        });
    }

    function _getCompoundedStabilityDeposit(address depositor) internal view returns (uint256) {
        uint256 initialDeposit = stabilityDeposits[depositor];
        if (initialDeposit == 0) return 0;
        StabilitySnapshot memory snap = depositSnapshots[depositor];
        if (snap.epoch < currentEpoch) return 0; // pool fully wiped since this snapshot

        uint128 scaleDiff = currentScale - snap.scale;
        uint256 compounded;
        if (scaleDiff == 0) {
            compounded = (initialDeposit * P) / snap.P;
        } else if (scaleDiff == 1) {
            compounded = (initialDeposit * P) / snap.P / SCALE_FACTOR;
        } else {
            compounded = 0;
        }
        if (compounded < 1e9) return 0; // negligible dust after heavy decay
        return compounded;
    }

    function _getDepositorCollateralGain(address depositor) internal view returns (uint256) {
        uint256 initialDeposit = stabilityDeposits[depositor];
        if (initialDeposit == 0) return 0;
        StabilitySnapshot memory snap = depositSnapshots[depositor];

        uint128 gainEpoch = snap.epoch < currentEpoch ? snap.epoch : currentEpoch;

        uint256 firstPortion  = epochToScaleToSum[gainEpoch][snap.scale] - snap.S;
        uint256 secondPortion = epochToScaleToSum[gainEpoch][snap.scale + 1] / SCALE_FACTOR;

        return (initialDeposit * (firstPortion + secondPortion)) / snap.P / DECIMAL_PRECISION;
    }

    function getCompoundedStabilityDeposit(address depositor) external view returns (uint256) {
        return _getCompoundedStabilityDeposit(depositor);
    }

    function getDepositorCollateralGain(address depositor) external view returns (uint256) {
        return _getDepositorCollateralGain(depositor);
    }

    function getStabilityPoolStats() external view returns (
        uint256 totalDeposits,
        uint256 totalCollateralHeld,
        uint256 currentP,
        uint128 scale,
        uint128 epoch
    ) {
        return (totalStabilityDeposits, stabilityPoolCollateral, P, currentScale, currentEpoch);
    }

    /// @dev Applies a liquidation to the Stability Pool: burns `debtToOffset`
    ///      bSunDAI from the pool's own held balance and credits `collToAdd`
    ///      WETH to depositors pro-rata via Product-Sum accounting.
    function _offset(uint256 debtToOffset, uint256 collToAdd) internal {
        if (totalStabilityDeposits == 0 || debtToOffset == 0) return;

        uint256 collNumerator        = collToAdd * DECIMAL_PRECISION + lastCollateralError_Offset;
        uint256 collGainPerUnitStaked = collNumerator / totalStabilityDeposits;
        lastCollateralError_Offset    = collNumerator - (collGainPerUnitStaked * totalStabilityDeposits);

        uint256 debtNumerator     = debtToOffset * DECIMAL_PRECISION + lastDebtLossError_Offset;
        uint256 lossPerUnitStaked = debtNumerator / totalStabilityDeposits;
        if (lossPerUnitStaked > DECIMAL_PRECISION) lossPerUnitStaked = DECIMAL_PRECISION;
        lastDebtLossError_Offset  = debtNumerator - (lossPerUnitStaked * totalStabilityDeposits);

        uint256 newProductFactor = DECIMAL_PRECISION - lossPerUnitStaked;

        uint128 epochCached = currentEpoch;
        uint128 scaleCached = currentScale;
        uint256 pCached      = P;

        // No division by DECIMAL_PRECISION here: collGainPerUnitStaked and P
        // are both already DECIMAL_PRECISION-scaled, and the read side divides
        // by both P_snapshot and DECIMAL_PRECISION when reading this sum back
        // out — matching the standard Liquity StabilityPool algorithm.
        uint256 marginalCollGain = collGainPerUnitStaked * pCached;
        epochToScaleToSum[epochCached][scaleCached] += marginalCollGain;

        uint256 newP;
        if (newProductFactor == 0) {
            currentEpoch = epochCached + 1;
            currentScale = 0;
            newP = DECIMAL_PRECISION;
            emit StabilityPoolEmptied(currentEpoch);
        } else if ((pCached * newProductFactor) / DECIMAL_PRECISION < SCALE_FACTOR) {
            // Single division (not /DECIMAL_PRECISION twice): rescales P *up*
            // by SCALE_FACTOR so it doesn't underflow to dust/zero on repeated
            // heavy losses. The read side divides back down by SCALE_FACTOR
            // once per scale step crossed.
            newP = (pCached * newProductFactor * SCALE_FACTOR) / DECIMAL_PRECISION;
            currentScale = scaleCached + 1;
        } else {
            newP = (pCached * newProductFactor) / DECIMAL_PRECISION;
        }
        require(newP > 0, "P underflow");
        P = newP;

        totalStabilityDeposits  -= debtToOffset;
        stabilityPoolCollateral += collToAdd;

        bsundai.burn(debtToOffset);

        emit StabilityPoolOffset(debtToOffset, collToAdd);
    }

    /// @dev Distributes stability-fee revenue to Stability Pool depositors as
    ///      auto-compounding yield, falling back to surplusBuffer when the
    ///      pool is empty. Mints `feeAmount` new bSunDAI directly into the
    ///      pool's custody and grows P by the same multiplicative mechanism
    ///      _offset uses for losses, just upward instead of downward.
    function _distributeFee(uint256 feeAmount) internal {
        if (feeAmount == 0) return;

        if (totalStabilityDeposits == 0) {
            surplusBuffer += feeAmount;
            return;
        }

        uint256 gainNumerator = feeAmount * DECIMAL_PRECISION + lastFeeGainError_Offset;
        uint256 feeGainPerUnitStaked = gainNumerator / totalStabilityDeposits;
        lastFeeGainError_Offset = gainNumerator - (feeGainPerUnitStaked * totalStabilityDeposits);

        uint256 newProductFactor = DECIMAL_PRECISION + feeGainPerUnitStaked;
        P = (P * newProductFactor) / DECIMAL_PRECISION;

        totalStabilityDeposits += feeAmount;
        bsundai.mint(address(this), feeAmount);

        emit StabilityPoolFeeDistributed(feeAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Shared liquidation math: validates the vault is liquidatable,
    ///      starts the Dutch-auction clock if needed, and returns the
    ///      collateral reward for repaying `repayAmount` at `price`. Inverted
    ///      curve: starts at MAX_BONUS_BPS (10%), decreases to MIN_BONUS_BPS
    ///      (2%) over AUCTION_TIME — bots need no incentive to wait.
    function _liquidationReward(Vault storage v, uint256 repayAmount, uint256 price) internal returns (uint256 reward) {
        uint256 currentRatio = (v.collateral * price * 100) / (v.debt * 1e18);
        require(currentRatio < LIQUIDATION_RATIO, "Vault is safe");

        if (v.undercollateralizedSince == 0) v.undercollateralizedSince = block.timestamp;

        uint256 base = (repayAmount * 1e18) / price;
        uint256 elapsed = block.timestamp - v.undercollateralizedSince;
        if (elapsed > AUCTION_TIME) elapsed = AUCTION_TIME;
        uint256 bonusBps = MAX_BONUS_BPS - ((MAX_BONUS_BPS - MIN_BONUS_BPS) * elapsed) / AUCTION_TIME;
        reward = base + (base * bonusBps) / 10000;
        if (reward > v.collateral) reward = v.collateral;
    }

    function _finalizeLiquidation(Vault storage v, uint256 price) internal {
        if (v.debt == 0) {
            v.undercollateralizedSince = 0;
        } else {
            uint256 newRatio = (v.collateral * price * 100) / (v.debt * 1e18);
            if (newRatio >= LIQUIDATION_RATIO) v.undercollateralizedSince = 0;
        }
    }

    /// @notice Liquidate an undercollateralized vault. Caller must already
    ///         hold the bSunDAI being repaid. For vaults the Stability Pool
    ///         can cover, liquidateFromStabilityPool() is more capital-
    ///         efficient for callers (no pre-held bSunDAI required).
    function _doLiquidate(address user, uint256 repayAmount) internal {
        require(user != msg.sender, "Cannot self-liquidate");
        require(repayAmount > 0, "Invalid amount");

        Vault storage v = vaults[user];
        _accrueInterest(v);
        require(v.debt > 0, "No debt");
        require(repayAmount <= v.debt, "Exceeds debt");
        require(repayAmount * 10000 >= v.debt * MIN_LIQUIDATION_BPS || repayAmount == v.debt, "Too small");

        (uint256 price, bool isLive) = _liquidationPrice();
        uint256 reward = _liquidationReward(v, repayAmount, price);

        _collectAndBurn(msg.sender, repayAmount);
        v.debt          -= repayAmount;
        totalDebt       -= repayAmount;
        v.collateral    -= reward;
        totalCollateral -= reward;

        _finalizeLiquidation(v, price);

        IWETH(address(weth)).withdraw(reward);
        _sendETH(msg.sender, reward);

        if (v.debt > 0) emit PartialLiquidation(user, repayAmount, v.debt, msg.sender);
        emit Liquidation(user, repayAmount, msg.sender, reward, _collateralRatio(user), isLive);
    }

    function liquidate(address user, uint256 repayAmount) external nonReentrant {
        _doLiquidate(user, repayAmount);
    }

    function liquidateWithPermit(
        address user,
        uint256 repayAmount,
        uint256 deadline,
        uint8 pV, bytes32 pR, bytes32 pS
    ) external nonReentrant {
        bsundai.permit(msg.sender, address(this), repayAmount, deadline, pV, pR, pS);
        _doLiquidate(user, repayAmount);
    }

    /// @notice v9: permissionless liquidation absorbed atomically by the
    ///         Stability Pool — no pre-held bSunDAI needed by the caller.
    ///         Offsets min(v.debt, totalStabilityDeposits) against the pool
    ///         at the same Dutch-auction reward curve as liquidate(). The
    ///         caller receives a small flat tip (gas compensation); the rest
    ///         goes to Stability Pool depositors, since it's their capital
    ///         doing the absorbing. If the pool can't cover the full debt,
    ///         the remainder stays on the vault for liquidate() or
    ///         clearBadDebt() to finish.
    function liquidateFromStabilityPool(address user) external nonReentrant {
        require(user != msg.sender, "Cannot self-liquidate");

        Vault storage v = vaults[user];
        _accrueInterest(v);
        require(v.debt > 0, "No debt");
        require(totalStabilityDeposits > 0, "SP empty - use liquidate()");

        (uint256 price, bool isLive) = _liquidationPrice();
        uint256 debtToOffset = v.debt < totalStabilityDeposits ? v.debt : totalStabilityDeposits;

        uint256 totalReward = _liquidationReward(v, debtToOffset, price);

        uint256 base = (debtToOffset * 1e18) / price;
        uint256 callerTip = (base * LIQUIDATION_CALLER_TIP_BPS) / 10000;
        if (callerTip > totalReward) callerTip = totalReward;
        uint256 poolReward = totalReward - callerTip;

        v.debt          -= debtToOffset;
        totalDebt       -= debtToOffset;
        v.collateral    -= totalReward;
        totalCollateral -= totalReward;

        _finalizeLiquidation(v, price);
        _offset(debtToOffset, poolReward);

        if (callerTip > 0) {
            IWETH(address(weth)).withdraw(callerTip);
            _sendETH(msg.sender, callerTip);
        }

        emit LiquidatedFromStabilityPool(user, debtToOffset, poolReward, callerTip, msg.sender);
        if (v.debt > 0) emit PartialLiquidation(user, debtToOffset, v.debt, msg.sender);
        emit Liquidation(user, debtToOffset, msg.sender, totalReward, _collateralRatio(user), isLive);
    }

    /*//////////////////////////////////////////////////////////////
                        REDEMPTION MECHANISM
    //////////////////////////////////////////////////////////////*/

    function _doRedeem(uint256 bSunDAIAmount, address vaultOwner) internal {
        require(bSunDAIAmount >= MIN_REDEMPTION, "Below minimum redemption");
        require(vaultOwner != msg.sender, "Cannot self-redeem");
        _requireOracleFresh();

        Vault storage v = vaults[vaultOwner];
        _accrueInterest(v);
        require(v.debt >= bSunDAIAmount, "Exceeds vault debt");

        uint256 price    = _safePrice();
        uint256 wethGross = (bSunDAIAmount * 1e18) / price;
        uint256 wethFee   = (wethGross * REDEMPTION_FEE_BPS) / 10000;
        uint256 wethNet   = wethGross - wethFee;

        require(v.collateral >= wethNet, "Vault has insufficient collateral");

        v.debt          -= bSunDAIAmount;
        v.collateral    -= wethNet;
        totalDebt       -= bSunDAIAmount;
        totalCollateral -= wethNet;

        if (v.debt == 0) {
            v.undercollateralizedSince = 0;
        } else {
            uint256 newRatio = (v.collateral * price * 100) / (v.debt * 1e18);
            if (newRatio >= LIQUIDATION_RATIO) v.undercollateralizedSince = 0;
        }

        _collectAndBurn(msg.sender, bSunDAIAmount);
        IWETH(address(weth)).withdraw(wethNet);
        _sendETH(msg.sender, wethNet);

        emit Redemption(vaultOwner, msg.sender, bSunDAIAmount, wethNet, REDEMPTION_FEE_BPS);
    }

    function redeem(uint256 bSunDAIAmount, address vaultOwner) external nonReentrant {
        _doRedeem(bSunDAIAmount, vaultOwner);
    }

    function redeemWithPermit(
        uint256 bSunDAIAmount,
        address vaultOwner,
        uint256 deadline,
        uint8 pV, bytes32 pR, bytes32 pS
    ) external nonReentrant {
        bsundai.permit(msg.sender, address(this), bSunDAIAmount, deadline, pV, pR, pS);
        _doRedeem(bSunDAIAmount, vaultOwner);
    }

    /*//////////////////////////////////////////////////////////////
                     BAD DEBT CLEARING (v9: fixed)
    //////////////////////////////////////////////////////////////*/

    /// @notice Voluntarily unwind a fully-underwater vault (collateral value <
    ///         100% of debt, unabsorbed by the Stability Pool or a keeper).
    ///         Caller repays `repayAmount` (up to v.debt) and receives
    ///         collateral strictly pro-rata: collateralOut = v.collateral *
    ///         repayAmount / v.debt, with NO bonus — the position is
    ///         insolvent, so a bonus would only deepen the loss. Because
    ///         payout is exactly proportional and the vault is underwater by
    ///         definition, a caller can never receive collateral worth more
    ///         than they paid: this is strictly a voluntary, loss-taking
    ///         cleanup action, never a profit opportunity.
    ///
    ///         v9 fix: the v7 draft gave 100% of a vault's collateral away
    ///         for FREE once collateral value dipped under 100% of debt — an
    ///         attacker could trigger this on an otherwise fine vault via a
    ///         manipulated liquidation-price read and walk away with its
    ///         collateral. Requiring real, proportional repayment removes the
    ///         exploit at the root; using the oracle's clamped
    ///         getLiquidationPrice() for the underwater check closes the
    ///         manipulation vector on the trigger itself.
    function clearBadDebt(address user, uint256 repayAmount) external nonReentrant {
        Vault storage v = vaults[user];
        _accrueInterest(v);
        require(v.debt > 0 && v.collateral > 0, "Nothing to clear");
        require(repayAmount > 0 && repayAmount <= v.debt, "Invalid amount");

        (uint256 price,) = _liquidationPriceView();
        uint256 collateralValue = (v.collateral * price) / 1e18;
        require(collateralValue < v.debt, "Not underwater - use liquidate()");

        uint256 collateralOut = (v.collateral * repayAmount) / v.debt;

        _collectAndBurn(msg.sender, repayAmount);

        v.debt          -= repayAmount;
        v.collateral    -= collateralOut;
        totalDebt       -= repayAmount;
        totalCollateral -= collateralOut;

        if (v.debt == 0) {
            if (v.collateral > 0) {
                totalCollateral -= v.collateral;
                v.collateral = 0;
            }
            delete vaults[user];
        }

        IWETH(address(weth)).withdraw(collateralOut);
        _sendETH(msg.sender, collateralOut);

        emit BadDebtCleared(user, collateralOut, repayAmount, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                         EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function emergencyRepay(uint256 amount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.debt >= amount, "Invalid repay");
        require(isOracleCatastrophicallyFailed(), "Oracle not failed (use normal repay)");
        _accrueInterest(v);
        _collectAndBurn(msg.sender, amount);
        v.debt    -= amount;
        totalDebt -= amount;
        emit EmergencyRepay(msg.sender, amount, "Oracle catastrophically failed");
        emit Repay(msg.sender, amount, _collateralRatio(msg.sender));
    }

    function emergencyWithdrawETH(uint256 amount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.collateral >= amount, "Invalid withdraw");
        require(isOracleCatastrophicallyFailed(), "Oracle not failed (use normal withdraw)");
        require(v.debt == 0, "Repay debt first via emergencyRepay()");
        require(block.timestamp > v.lastDepositTime + WITHDRAW_COOLDOWN, "Cooldown");
        v.collateral    -= amount;
        totalCollateral -= amount;
        v.lastWithdrawTime = block.timestamp;
        IWETH(address(weth)).withdraw(amount);
        _sendETH(msg.sender, amount);
        emit EmergencyWithdrawETH(msg.sender, amount, "Oracle catastrophically failed");
        emit Withdraw(msg.sender, amount, _collateralRatio(msg.sender));
    }

    function emergencyUnlock() external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(v.debt == 0, "Repay debt first");
        require(v.collateral > 0, "No collateral");
        require(block.timestamp > v.lastDepositTime + 30 days, "Vault recently active");
        uint256 amt = v.collateral;
        v.collateral    = 0;
        totalCollateral -= amt;
        IWETH(address(weth)).withdraw(amt);
        _sendETH(msg.sender, amt);
        emit EmergencyWithdraw(msg.sender, amt);
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function vaultInfo(address user)
        external view
        returns (
            uint256 collateral, uint256 debt, uint256 collateralUSD,
            uint256 ratio, uint256 mintable, bool oracleHealthy,
            uint256 price, uint256 systemRatio
        )
    {
        Vault storage v = vaults[user];
        collateral = v.collateral;
        debt = v.debt;
        (uint256 p, uint256 ts) = oracle.peekPrice();
        price        = (block.timestamp - ts > MAX_ORACLE_STALENESS || p == 0) ? lastOraclePrice : p;
        oracleHealthy = (block.timestamp - ts <= MAX_ORACLE_STALENESS && p > 0);
        collateralUSD = (collateral * price) / 1e18;
        ratio         = debt == 0 ? type(uint256).max : (collateral * price * 100) / (debt * 1e18);
        uint256 safeDebtLimit = (collateralUSD * 100) / COLLATERAL_RATIO;
        mintable      = safeDebtLimit > debt ? safeDebtLimit - debt : 0;
        systemRatio   = systemHealth();
    }

    function isLiquidatable(address user) external view returns (bool canLiquidate, uint256 currentRatio) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return (false, type(uint256).max);
        (uint256 price,) = _liquidationPriceView();
        currentRatio  = (v.collateral * price * 100) / (v.debt * 1e18);
        canLiquidate  = currentRatio < LIQUIDATION_RATIO;
    }

    function liquidationInfo(address user)
        external view
        returns (bool canLiquidate, uint256 maxRepay, uint256 bonusBps, uint256 auctionElapsed)
    {
        Vault storage v = vaults[user];
        if (v.debt == 0) return (false, 0, 0, 0);
        (uint256 price,) = _liquidationPriceView();
        uint256 ratio = (v.collateral * price * 100) / (v.debt * 1e18);
        canLiquidate  = ratio < LIQUIDATION_RATIO;
        if (!canLiquidate) return (false, 0, 0, 0);
        maxRepay      = v.debt;
        auctionElapsed = v.undercollateralizedSince > 0 ? block.timestamp - v.undercollateralizedSince : 0;
        uint256 t = auctionElapsed > AUCTION_TIME ? AUCTION_TIME : auctionElapsed;
        bonusBps  = MAX_BONUS_BPS - ((MAX_BONUS_BPS - MIN_BONUS_BPS) * t) / AUCTION_TIME;
    }

    function repayToHealth(address user) external view returns (uint256 repayNeeded) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return 0;
        (uint256 p,) = oracle.peekPrice();
        uint256 price = p > 0 ? p : lastOraclePrice;
        uint256 requiredDebt = (v.collateral * price * 100) / (COLLATERAL_RATIO * 1e18);
        repayNeeded = v.debt > requiredDebt ? v.debt - requiredDebt : 0;
    }

    function isZombieVault(address user) external view returns (bool) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return false;
        (uint256 p,) = oracle.peekPrice();
        uint256 price = p > 0 ? p : lastOraclePrice;
        return (v.collateral * price) < (v.debt * 1e18);
    }

    function vaultBadDebt(address user) external view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return 0;
        (uint256 p,) = oracle.peekPrice();
        uint256 price = p > 0 ? p : lastOraclePrice;
        uint256 collateralValue = (v.collateral * price) / 1e18;
        return collateralValue < v.debt ? v.debt - collateralValue : 0;
    }

    function systemBadDebtEstimate(uint256 start, uint256 count)
        external view returns (uint256 badDebt, uint256 zombieCount)
    {
        (uint256 p,) = oracle.peekPrice();
        uint256 price = p > 0 ? p : lastOraclePrice;

        uint256 end = start + count;
        if (end > vaultOwners.length) end = vaultOwners.length;

        for (uint256 i = start; i < end; i++) {
            Vault storage v = vaults[vaultOwners[i]];
            if (v.debt == 0) continue;
            uint256 collateralValue = (v.collateral * price) / 1e18;
            if (collateralValue < v.debt) {
                badDebt += v.debt - collateralValue;
                zombieCount++;
            }
        }
    }

    function redemptionPreview(address vaultOwner, uint256 bSunDAIAmount)
        external view
        returns (uint256 wethOut, uint256 feeBps, bool feasible)
    {
        Vault storage v = vaults[vaultOwner];
        if (v.debt < bSunDAIAmount || bSunDAIAmount < MIN_REDEMPTION) return (0, REDEMPTION_FEE_BPS, false);
        (uint256 p,) = oracle.peekPrice();
        uint256 price = p > 0 ? p : lastOraclePrice;
        uint256 wethGross = (bSunDAIAmount * 1e18) / price;
        uint256 wethFee   = (wethGross * REDEMPTION_FEE_BPS) / 10000;
        wethOut   = wethGross - wethFee;
        feasible  = v.collateral >= wethOut;
        feeBps    = REDEMPTION_FEE_BPS;
    }

    /*//////////////////////////////////////////////////////////////
                              FALLBACK
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
    fallback() external payable {}
}
