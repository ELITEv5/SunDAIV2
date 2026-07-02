// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║              pSunDAIVault ASA v8 — Single-Collateral Hardening       ║
 * ║                                                                      ║
 * ║   Carries forward all v7 logic unchanged (dual-price liquidation,    ║
 * ║   surplus buffer, bad debt handling, Dutch auction, emergency        ║
 * ║   exits, vault enumeration). v8 adds three hardening mechanisms:     ║
 * ║                                                                      ║
 * ║   DYNAMIC EFFECTIVE CEILING                                          ║
 * ║   DEBT_CEILING stays as an immutable outer sanity bound, but the     ║
 * ║   ceiling actually enforced day to day is                            ║
 * ║   min(DEBT_CEILING, oracle.maxSafeDebt()) — it moves automatically   ║
 * ║   as real oracle pool liquidity changes, instead of trusting a       ║
 * ║   number picked once at deploy time that can never be revisited.     ║
 * ║                                                                      ║
 * ║   PER-VAULT CAP                                                      ║
 * ║   No single vault's debt may exceed oracle.maxSafeDebt() / 10.       ║
 * ║   Directly prevents a single large position from concentrating a     ║
 * ║   meaningful share of system debt in one vault — which is what       ║
 * ║   makes the oracle-depth mismatch and liquidation-throughput         ║
 * ║   problems dangerous in the first place.                             ║
 * ║                                                                      ║
 * ║   LIQUIDATION PACING WITHOUT A CONCENTRATION BOTTLENECK               ║
 * ║   The flat per-vault LIQUIDATION_COOLDOWN is removed. Any number of  ║
 * ║   liquidation calls can land on the same vault back-to-back — each   ║
 * ║   is still bounded by MIN_LIQUIDATION_BPS (>=20% of remaining debt   ║
 * ║   per call), so a single position can be cleared by multiple         ║
 * ║   liquidators in parallel instead of being serialized behind a       ║
 * ║   10-minute clock regardless of size.                                ║
 * ║                                                                      ║
 * ║   FLASH-MINT-FREE LIQUIDATION (liquidateWithFlashMint)                ║
 * ║   New, additive function alongside the unchanged liquidate(). Caller ║
 * ║   must be a contract implementing IFlashLiquidationReceiver. Sends   ║
 * ║   the liquidator their WPLS reward collateral up front, then calls   ║
 * ║   back into msg.sender's own onFlashLiquidation() — not an arbitrary ║
 * ║   target — so any swap the receiver performs is correctly attributed║
 * ║   to its own address/approvals, not the vault's. Requires repayment  ║
 * ║   (+ a small fee routed into surplusBuffer) by the end of the same   ║
 * ║   transaction or the whole call reverts. Removes the capital         ║
 * ║   requirement that previously limited large-position liquidation to  ║
 * ║   whoever already held a lot of pSunDAI. No token minting is         ║
 * ║   involved anywhere in this path — the WPLS sent out is real,        ║
 * ║   pre-existing vault collateral, and if repayment fails the entire   ║
 * ║   transaction (including the collateral transfer) reverts.           ║
 * ║                                                                      ║
 * ║   ── WHAT DIDN'T CHANGE ────────────────────────────────────────     ║
 * ║   - All economic parameters (150%/110%, 0.5% APY, 2-5% bonus)        ║
 * ║   - No admin keys, no upgradeability                                 ║
 * ║   - Vault-driven oracle advancement (no keepers)                     ║
 * ║   - Dutch auction bonus curve                                        ║
 * ║   - Emergency exits (30-day unlock, oracle-death)                    ║
 * ║   - On-chain vault enumeration, self-liquidation prevention          ║
 * ║   - Existing liquidate(address,uint256) signature and behavior,      ║
 * ║     unchanged, so the current frontend keeps working unmodified.     ║
 * ║                                                                      ║
 * ║   Dev: ELITE TEAM6 | https://www.sundaitoken.com                     ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./pSunDAI_ASA_Token_v7.sol";
import "./pSunDAI_Oracle_Hybrid_v8.sol";

interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/// @notice Implemented by the liquidator's own contract to receive the collateral
///         and settle liquidateWithFlashMint() in the same transaction. The vault
///         calls back into msg.sender (the caller of liquidateWithFlashMint) — not
///         into an arbitrary target — specifically so that any swap the receiver
///         performs is correctly attributed to the receiver's own address (its own
///         approvals, its own balance), not to the vault.
interface IFlashLiquidationReceiver {
    function onFlashLiquidation(
        address user,
        uint256 collateralReceived,
        uint256 amountOwed,
        bytes calldata data
    ) external;
}

contract pSunDAIVault_ASA_v8 is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ── Immutables ───────────────────────────────────────────────────────────
    IERC20 public immutable wpls;
    pSunDAI_ASA public immutable psundai;
    pSunDAIoraclePLSXHybrid_v8 public immutable oracle;
    uint256 public immutable DEBT_CEILING;

    string public constant VERSION = "pSunDAIVault_ASA_v8";

    // ── Protocol parameters ──────────────────────────────────────────────────
    uint256 public constant COLLATERAL_RATIO     = 150;
    uint256 public constant AUTO_MINT_RATIO      = 155;
    uint256 public constant LIQUIDATION_RATIO    = 110;
    uint256 public constant MIN_ACTION_AMOUNT    = 1e14;
    uint256 public constant WITHDRAW_COOLDOWN    = 300;
    uint256 public constant MIN_LIQUIDATION_BPS  = 2000;   // 20% min partial liquidation
    uint256 public constant MIN_BONUS_BPS        = 200;    // 2% starting bonus
    uint256 public constant MAX_BONUS_BPS        = 500;    // 5% max after 3h
    uint256 public constant AUCTION_TIME         = 3 hours;
    uint256 public constant MIN_SYSTEM_HEALTH    = 130;
    uint256 public constant STABILITY_FEE_BPS    = 50;     // 0.5% APY
    uint256 public constant SECONDS_PER_YEAR     = 31_536_000;
    uint256 public constant MAX_VOLATILITY_BPS   = 1000;   // 10% vault-level TWAP clamp
    uint256 public constant ORACLE_DEAD_THRESHOLD = 7 days;

    // ── v8 dynamic-capacity parameters ────────────────────────────────────────
    // A single vault may hold at most oracle.maxSafeDebt() / MAX_VAULTS_AT_CAP —
    // forces natural diversification instead of allowing one position to
    // concentrate a large share of system debt in a single liquidation target.
    uint256 public constant MAX_VAULTS_AT_CAP = 10;
    // Premium on liquidateWithFlashMint, routed into surplusBuffer.
    uint256 public constant FLASH_FEE_BPS = 20; // 0.2%

    // ── Vault struct ─────────────────────────────────────────────────────────
    struct Vault {
        uint256 collateral;
        uint256 debt;
        uint256 lastDepositTime;
        uint256 lastWithdrawTime;
        uint256 lastDebtAccrual;
        uint256 undercollateralizedSince;
    }

    // ── System state ─────────────────────────────────────────────────────────
    mapping(address => Vault) public vaults;
    uint256 public totalCollateral;
    uint256 public totalDebt;
    uint256 public lastOraclePrice;
    uint256 public lastOracleUpdateTime;

    // ── Surplus buffer and bad debt ───────────────────────────────────────────
    // surplusBuffer: accumulated stability fees (and, in v8, flash-liquidation
    //   fees) not yet consumed by bad debt. Represents the system's equity
    //   margin — fees increase debt faster than supply, so repayment burns more
    //   pSunDAI than was minted. This excess deflationary pressure is the first
    //   line of defense against bad debt.
    // badDebtAccumulated: uncovered debt from underwater liquidations that
    //   exceeded the surplus buffer. Represents unbacked pSunDAI in circulation.
    //   Decreases via: (a) auto-reconciliation from future fee accrual,
    //   (b) settleDebt() — anyone burning pSunDAI to directly cancel bad debt.
    uint256 public surplusBuffer;
    uint256 public badDebtAccumulated;

    // ── Vault enumeration ─────────────────────────────────────────────────────
    address[] public vaultOwners;
    mapping(address => bool) public hasVault;

    // ── Events ───────────────────────────────────────────────────────────────
    event Deposit(address indexed user, uint256 amount, uint256 ratio);
    event Withdraw(address indexed user, uint256 amount, uint256 ratio);
    event Mint(address indexed user, uint256 amount, uint256 ratio);
    event Repay(address indexed user, uint256 amount, uint256 ratio);
    event Liquidation(address indexed user, uint256 repayAmount, address indexed liquidator, uint256 reward, uint256 ratio, bool spotPrice);
    event BadDebtCleared(address indexed user, uint256 collateralReturned, uint256 debtWrittenOff, address indexed caller);
    event BadDebtAccruedEvent(address indexed user, uint256 amount);
    event DebtSettled(uint256 amount, address indexed settler);
    event SurplusReconciled(uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event EmergencyRepay(address indexed user, uint256 amount);
    event EmergencyWithdrawOracleDead(address indexed user, uint256 amount);
    event VaultRegistered(address indexed user);
    event VaultMarkedUndercollateralized(address indexed user, uint256 timestamp);
    event OracleFallbackUsed(uint256 price);
    event DebtCeilingReached(uint256 totalDebt, uint256 ceiling);

    // ── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _wpls,
        address _psundai,
        address _oracle,
        uint256 _debtCeiling
    ) {
        require(_wpls != address(0) && _psundai != address(0) && _oracle != address(0), "Zero address");
        require(_debtCeiling > 0, "Invalid ceiling");

        wpls         = IERC20(_wpls);
        psundai      = pSunDAI_ASA(_psundai);
        oracle       = pSunDAIoraclePLSXHybrid_v8(_oracle);
        DEBT_CEILING = _debtCeiling;

        (uint256 initialPrice,) = pSunDAIoraclePLSXHybrid_v8(_oracle).peekPriceView();
        require(initialPrice > 0, "Oracle not ready");
        lastOraclePrice      = initialPrice;
        lastOracleUpdateTime = block.timestamp;
    }

    // ── ETH sender ───────────────────────────────────────────────────────────
    function _sendETH(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    // ── Vault registration ────────────────────────────────────────────────────
    function _registerVault(address user) internal {
        if (!hasVault[user]) {
            hasVault[user] = true;
            vaultOwners.push(user);
            emit VaultRegistered(user);
        }
    }

    // ── Dynamic capacity (v8) ─────────────────────────────────────────────────

    /// @notice Effective debt ceiling actually enforced: the lesser of the
    ///         immutable outer bound and the oracle's real-time, liquidity-derived
    ///         safe capacity. Moves automatically as pool depth changes.
    function _effectiveDebtCeiling() internal view returns (uint256) {
        uint256 dynamicCap = oracle.maxSafeDebt();
        return dynamicCap < DEBT_CEILING ? dynamicCap : DEBT_CEILING;
    }

    function effectiveDebtCeiling() external view returns (uint256) {
        return _effectiveDebtCeiling();
    }

    /// @notice Maximum debt a single vault may hold, derived from the same
    ///         liquidity signal as the effective ceiling.
    function _vaultCap() internal view returns (uint256) {
        return oracle.maxSafeDebt() / MAX_VAULTS_AT_CAP;
    }

    function vaultCap() external view returns (uint256) {
        return _vaultCap();
    }

    // ── Price helpers ─────────────────────────────────────────────────────────

    /// @notice Get conservative TWAP price, advance oracle state.
    ///         Used for: minting, withdrawal safety checks, interest accrual.
    ///         H-7: lastOracleUpdateTime only advances when oracle state progressed.
    function _safeMintPrice() internal returns (uint256 p) {
        uint256 ts;
        bool oracleAdvanced;

        try oracle.getPriceWithTimestamp() returns (uint256 _p, uint256 _ts) {
            p  = _p;
            ts = _ts;
            oracleAdvanced = true;
        } catch {
            (p, ts) = oracle.peekPriceView();
            emit OracleFallbackUsed(p > 0 ? p : lastOraclePrice);
        }

        if (p == 0) {
            emit OracleFallbackUsed(lastOraclePrice);
            return lastOraclePrice > 0 ? lastOraclePrice : 1e18;
        }

        if (lastOraclePrice > 0) {
            uint256 diff = p > lastOraclePrice ? p - lastOraclePrice : lastOraclePrice - p;
            uint256 volatilityBps = (diff * 10_000) / lastOraclePrice;

            if (volatilityBps > MAX_VOLATILITY_BPS) {
                (,,,bool inConfirmation,,,,) = oracle.getPriceStatus();

                if (inConfirmation) {
                    lastOraclePrice = p;
                    if (oracleAdvanced) lastOracleUpdateTime = ts;
                } else {
                    uint256 cooldown   = p < lastOraclePrice ? 4 hours : 1 hours;
                    uint256 lowerBound = (lastOraclePrice * 9000) / 10000;
                    uint256 upperBound = (lastOraclePrice * 11000) / 10000;

                    if (p >= lowerBound && p <= upperBound) {
                        lastOraclePrice = p;
                        if (oracleAdvanced) lastOracleUpdateTime = ts;
                    } else if (block.timestamp - lastOracleUpdateTime >= cooldown) {
                        lastOraclePrice = p;
                        if (oracleAdvanced) lastOracleUpdateTime = ts;
                    } else {
                        emit OracleFallbackUsed(lastOraclePrice);
                        p = lastOraclePrice;
                    }
                }
            } else {
                lastOraclePrice = p;
                if (oracleAdvanced) lastOracleUpdateTime = ts;
            }
        } else {
            lastOraclePrice = p;
            if (oracleAdvanced) lastOracleUpdateTime = ts;
        }

        return p;
    }

    /// @notice Get the price to use for liquidation eligibility and reward calculation.
    ///         When the oracle's spot warning has confirmed a sustained crash (30+ min),
    ///         use the real spot median. Otherwise use the conservative TWAP.
    ///         This also advances oracle state on the TWAP path (not on spot path).
    function _liquidationPrice() internal returns (uint256 price, bool isSpot) {
        if (oracle.isSpotLiquidationEnabled()) {
            uint256 spotPrice = oracle.getSpotPrice();
            if (spotPrice > 0) return (spotPrice, true);
        }
        return (_safeMintPrice(), false);
    }

    /// @notice View version of liquidation price for read-only checks.
    function _liquidationPriceView() internal view returns (uint256 price, bool isSpot) {
        if (oracle.isSpotLiquidationEnabled()) {
            uint256 spotPrice = oracle.getSpotPrice();
            if (spotPrice > 0) return (spotPrice, true);
        }
        (uint256 p,) = oracle.peekPriceView();
        return (p > 0 ? p : lastOraclePrice, false);
    }

    // ── Interest accrual with surplus buffer ──────────────────────────────────

    function _touch(address user) internal {
        Vault storage v = vaults[user];
        if (v.debt > 0) _accrueInterest(v);
    }

    function _accrueInterest(Vault storage v) internal {
        if (v.debt == 0) { v.lastDebtAccrual = block.timestamp; return; }
        uint256 elapsed = block.timestamp - v.lastDebtAccrual;
        if (elapsed == 0) return;

        uint256 fee = (v.debt * STABILITY_FEE_BPS * elapsed) / (SECONDS_PER_YEAR * 10_000);
        if (fee == 0 && elapsed > 0) fee = 1;

        v.debt    += fee;
        totalDebt += fee;
        // Surplus buffer grows with every fee accrual. Each fee increments both
        // the user's debt obligation AND the system's equity margin, because the
        // user will eventually burn more pSunDAI than was minted for them.
        surplusBuffer += fee;

        v.lastDebtAccrual = block.timestamp;

        // Dust clearing: remove micro-debts to prevent permanent tiny-debt state.
        // Adjust surplus buffer down since we're forgiving a small amount of debt.
        if (v.debt <= 1e12) {
            if (surplusBuffer >= v.debt) surplusBuffer -= v.debt; else surplusBuffer = 0;
            totalDebt -= v.debt;
            v.debt = 0;
        }

        // Auto-reconciliation: if surplus and bad debt coexist, cancel them.
        // This happens silently on every vault interaction — no keeper needed.
        _reconcile();
    }

    /// @notice Apply accumulated surplus against outstanding bad debt.
    ///         Called automatically on interest accrual. Also callable publicly.
    function _reconcile() internal {
        if (surplusBuffer > 0 && badDebtAccumulated > 0) {
            uint256 applied = surplusBuffer < badDebtAccumulated
                ? surplusBuffer
                : badDebtAccumulated;
            surplusBuffer      -= applied;
            badDebtAccumulated -= applied;
            emit SurplusReconciled(applied);
        }
    }

    // ── System state views ────────────────────────────────────────────────────

    function isUXSafe() public view returns (bool) {
        (uint256 p, uint256 ts) = oracle.peekPriceView();
        return p > 0 && block.timestamp - ts <= 1 hours && systemHealth() >= MIN_SYSTEM_HEALTH;
    }

    function isOracleDead() public view returns (bool) {
        return oracle.isStale(ORACLE_DEAD_THRESHOLD);
    }

    function systemHealth() public view returns (uint256) {
        if (totalDebt == 0) return type(uint256).max;
        (uint256 p,) = oracle.peekPriceView();
        uint256 price = p > 0 ? p : lastOraclePrice;
        return (totalCollateral * price * 100) / (totalDebt * 1e18);
    }

    /// @notice Net system solvency: positive = surplus equity, negative = bad debt outstanding.
    ///         surplusBuffer - badDebtAccumulated gives the system's equity cushion.
    function systemEquity() external view returns (int256) {
        return int256(surplusBuffer) - int256(badDebtAccumulated);
    }

    function _collateralRatio(address user) internal view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return type(uint256).max;
        (uint256 p,) = oracle.peekPriceView();
        uint256 price = p > 0 ? p : lastOraclePrice;
        return (v.collateral * price * 100) / (v.debt * 1e18);
    }

    function _checkSafe(uint256 col, uint256 debt, uint256 price) internal pure returns (bool) {
        if (debt == 0) return true;
        return col * price * 100 >= debt * COLLATERAL_RATIO * 1e18;
    }

    // ── Deposit ───────────────────────────────────────────────────────────────
    function depositPLS() external payable nonReentrant {
        require(msg.value >= MIN_ACTION_AMOUNT, "Too small");
        _touch(msg.sender);
        IWPLS(address(wpls)).deposit{value: msg.value}();
        _addCollateral(msg.sender, msg.value);
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount >= MIN_ACTION_AMOUNT, "Too small");
        _touch(msg.sender);
        wpls.safeTransferFrom(msg.sender, address(this), amount);
        _addCollateral(msg.sender, amount);
    }

    function _addCollateral(address user, uint256 amount) internal {
        _registerVault(user);
        Vault storage v = vaults[user];
        v.collateral     += amount;
        v.lastDepositTime = block.timestamp;
        totalCollateral  += amount;
        emit Deposit(user, amount, _collateralRatio(user));
    }

    // ── One-click deposit + mint ──────────────────────────────────────────────

    /// @notice Deposit PLS and auto-mint pSunDAI at 155% collateral ratio.
    /// @dev Debt ceiling and per-vault cap enforced (v8: dynamic, oracle-derived).
    ///      No MIN_SYSTEM_HEALTH gate — mathematically verified: depositing at
    ///      155% always raises system health toward 155% regardless of starting
    ///      health. mint() correctly gates manual minting at 130%.
    function depositAndAutoMintPLS() external payable nonReentrant {
        require(msg.value >= MIN_ACTION_AMOUNT, "Too small");
        _touch(msg.sender);
        IWPLS(address(wpls)).deposit{value: msg.value}();
        _addCollateral(msg.sender, msg.value);

        uint256 price      = _safeMintPrice();
        uint256 valueUSD   = (msg.value * price) / 1e18;
        uint256 mintAmount = (valueUSD * 100) / AUTO_MINT_RATIO;

        uint256 ceiling = _effectiveDebtCeiling();
        Vault storage v = vaults[msg.sender];
        uint256 cap     = _vaultCap();

        if (mintAmount > 0 && totalDebt + mintAmount <= ceiling && v.debt + mintAmount <= cap) {
            if (v.debt == 0) v.lastDebtAccrual = block.timestamp;
            v.debt      += mintAmount;
            totalDebt   += mintAmount;
            psundai.mint(msg.sender, mintAmount);
            emit Mint(msg.sender, mintAmount, _collateralRatio(msg.sender));
        } else if (mintAmount > 0) {
            emit DebtCeilingReached(totalDebt, ceiling);
        }
    }

    // ── Mint ──────────────────────────────────────────────────────────────────
    function mint(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero mint");
        require(isUXSafe(), "System not safe for minting");
        require(totalDebt + amount <= _effectiveDebtCeiling(), "Debt ceiling reached");

        _touch(msg.sender);
        _registerVault(msg.sender);

        require(systemHealth() >= MIN_SYSTEM_HEALTH, "System undercollateralized");
        require(vaults[msg.sender].debt + amount <= _vaultCap(), "Vault cap reached");

        uint256 price = _safeMintPrice();
        require(_checkSafe(vaults[msg.sender].collateral, vaults[msg.sender].debt + amount, price), "Not enough collateral");

        Vault storage v = vaults[msg.sender];
        if (v.debt == 0) v.lastDebtAccrual = block.timestamp;
        v.debt    += amount;
        totalDebt += amount;
        psundai.mint(msg.sender, amount);
        emit Mint(msg.sender, amount, _collateralRatio(msg.sender));
    }

    // ── Repay ─────────────────────────────────────────────────────────────────
    function repay(uint256 amount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        _touch(msg.sender);
        require(amount > 0 && v.debt >= amount, "Invalid repay");

        psundai.burn(msg.sender, amount);
        v.debt    -= amount;
        totalDebt -= amount;

        if (v.debt <= 1e12) {
            if (surplusBuffer >= v.debt) surplusBuffer -= v.debt; else surplusBuffer = 0;
            totalDebt -= v.debt;
            v.debt = 0;
        }

        emit Repay(msg.sender, amount, _collateralRatio(msg.sender));
    }

    // ── Withdraw ──────────────────────────────────────────────────────────────
    function withdrawPLS(uint256 amount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.collateral >= amount, "Invalid withdraw");
        require(block.timestamp > v.lastDepositTime + WITHDRAW_COOLDOWN, "Cooldown");
        _touch(msg.sender);

        uint256 price = v.debt > 0 ? _safeMintPrice() : 0;
        v.collateral    -= amount;
        totalCollateral -= amount;

        if (v.debt > 0) require(_checkSafe(v.collateral, v.debt, price), "Unsafe");

        v.lastWithdrawTime = block.timestamp;
        IWPLS(address(wpls)).withdraw(amount);
        _sendETH(msg.sender, amount);
        emit Withdraw(msg.sender, amount, _collateralRatio(msg.sender));
    }

    function withdrawWPLS(uint256 amount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.collateral >= amount, "Invalid withdraw");
        require(block.timestamp > v.lastDepositTime + WITHDRAW_COOLDOWN, "Cooldown");
        _touch(msg.sender);

        uint256 price = v.debt > 0 ? _safeMintPrice() : 0;
        v.collateral    -= amount;
        totalCollateral -= amount;

        if (v.debt > 0) require(_checkSafe(v.collateral, v.debt, price), "Unsafe");

        v.lastWithdrawTime = block.timestamp;
        wpls.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount, _collateralRatio(msg.sender));
    }

    // ── Repay + auto-withdraw ─────────────────────────────────────────────────
    function repayAndAutoWithdraw(uint256 repayAmount) external nonReentrant {
        Vault storage v = vaults[msg.sender];
        _touch(msg.sender);
        require(repayAmount > 0 && v.debt >= repayAmount, "Invalid repay");

        psundai.burn(msg.sender, repayAmount);
        v.debt    -= repayAmount;
        totalDebt -= repayAmount;

        if (v.debt <= 1e12) {
            if (surplusBuffer >= v.debt) surplusBuffer -= v.debt; else surplusBuffer = 0;
            totalDebt -= v.debt;
            v.debt = 0;
        }

        uint256 price = _safeMintPrice();

        if (v.debt == 0) {
            uint256 amt     = v.collateral;
            totalCollateral -= amt;
            delete vaults[msg.sender];
            IWPLS(address(wpls)).withdraw(amt);
            _sendETH(msg.sender, amt);
            emit Withdraw(msg.sender, amt, 0);
            emit Repay(msg.sender, repayAmount, 0);
            return;
        }

        uint256 required = (v.debt * COLLATERAL_RATIO * 1e18) / (price * 100);
        if (v.collateral > required) {
            uint256 withdrawable = v.collateral - required;
            v.collateral        = required;
            totalCollateral    -= withdrawable;
            IWPLS(address(wpls)).withdraw(withdrawable);
            _sendETH(msg.sender, withdrawable);
            emit Withdraw(msg.sender, withdrawable, _collateralRatio(msg.sender));
        }

        emit Repay(msg.sender, repayAmount, _collateralRatio(msg.sender));
    }

    function autoRepayToHealth() external nonReentrant {
        Vault storage v = vaults[msg.sender];
        _touch(msg.sender);
        if (v.debt == 0) return;
        uint256 price        = _safeMintPrice();
        uint256 requiredDebt = (v.collateral * price * 100) / (COLLATERAL_RATIO * 1e18);
        if (v.debt > requiredDebt) {
            uint256 repayAmt = v.debt - requiredDebt;
            psundai.burn(msg.sender, repayAmt);
            v.debt    -= repayAmt;
            totalDebt -= repayAmt;
            emit Repay(msg.sender, repayAmt, _collateralRatio(msg.sender));
        }
    }

    // ── Dutch auction clock ───────────────────────────────────────────────────

    /// @notice Mark a vault as undercollateralized to start the bonus graduation clock.
    ///         Uses liquidation price (spot if enabled, TWAP otherwise).
    ///         Liquidation bots should call this the moment a vault goes unsafe.
    function markUndercollateralized(address user) external {
        Vault storage v = vaults[user];
        require(v.debt > 0, "No debt");
        if (v.undercollateralizedSince != 0) return;

        (uint256 price,) = _liquidationPriceView();
        uint256 ratio = (v.collateral * price * 100) / (v.debt * 1e18);
        require(ratio < LIQUIDATION_RATIO, "Vault is safe");

        v.undercollateralizedSince = block.timestamp;
        emit VaultMarkedUndercollateralized(user, block.timestamp);
    }

    // ── Liquidation ───────────────────────────────────────────────────────────

    /// @notice Shared liquidation math for both liquidate() and
    ///         liquidateWithFlashMint(): validates the vault is actually
    ///         liquidatable, starts the Dutch-auction clock if needed, and
    ///         returns the collateral reward for repaying `repayAmount` at
    ///         `price`. Does not move any tokens or collateral itself.
    function _liquidationReward(Vault storage v, uint256 repayAmount, uint256 price) internal returns (uint256 reward) {
        uint256 currentRatio = (v.collateral * price * 100) / (v.debt * 1e18);
        require(currentRatio < LIQUIDATION_RATIO, "Vault is safe");

        if (v.undercollateralizedSince == 0) {
            v.undercollateralizedSince = block.timestamp;
        }

        uint256 base = Math.mulDiv(repayAmount, 1e18, price);
        uint256 elapsed = block.timestamp - v.undercollateralizedSince;
        if (elapsed > AUCTION_TIME) elapsed = AUCTION_TIME;
        uint256 bonusBps = MIN_BONUS_BPS + ((MAX_BONUS_BPS - MIN_BONUS_BPS) * elapsed / AUCTION_TIME);
        reward = base + (base * bonusBps) / 10000;
        if (reward > v.collateral) reward = v.collateral;
    }

    /// @notice Post-liquidation bookkeeping shared by both liquidation paths:
    ///         clears the undercollateralized clock if the vault is fully repaid
    ///         or has recovered above the liquidation ratio.
    function _finalizeLiquidation(Vault storage v, uint256 price) internal {
        if (v.debt == 0) {
            v.undercollateralizedSince = 0;
        } else {
            uint256 newRatio = (v.collateral * price * 100) / (v.debt * 1e18);
            if (newRatio >= LIQUIDATION_RATIO) v.undercollateralizedSince = 0;
        }
    }

    /// @notice Liquidate an undercollateralized vault.
    ///         Price used: spot median if oracle spot warning confirmed (30+ min),
    ///         otherwise conservative TWAP. This closes the bad-debt window that
    ///         exists while the TWAP is stepping down toward a confirmed crash.
    ///         v8: no per-vault cooldown — any number of calls can land on the
    ///         same vault back-to-back, each still bounded by MIN_LIQUIDATION_BPS,
    ///         so a large position can be cleared by multiple liquidators in
    ///         parallel instead of being serialized behind a fixed clock.
    function liquidate(address user, uint256 repayAmount) external nonReentrant {
        require(user != msg.sender, "Cannot self-liquidate");

        Vault storage v = vaults[user];
        _touch(user);

        require(v.debt > 0, "No debt");
        require(repayAmount > 0 && repayAmount <= v.debt, "Invalid amount");
        require(repayAmount * 10000 >= v.debt * MIN_LIQUIDATION_BPS, "Too small");

        (uint256 price, bool isSpot) = _liquidationPrice();
        uint256 reward = _liquidationReward(v, repayAmount, price);

        psundai.burn(msg.sender, repayAmount);
        v.debt           -= repayAmount;
        totalDebt        -= repayAmount;
        v.collateral     -= reward;
        totalCollateral  -= reward;

        _finalizeLiquidation(v, price);

        IWPLS(address(wpls)).withdraw(reward);
        _sendETH(msg.sender, reward);
        emit Liquidation(user, repayAmount, msg.sender, reward, _collateralRatio(user), isSpot);
    }

    /// @notice Liquidate without pre-holding pSunDAI (v8, additive — does not
    ///         replace liquidate()). Caller must be a contract implementing
    ///         IFlashLiquidationReceiver. The liquidator's WPLS reward collateral
    ///         is sent first, then the vault calls back into msg.sender's own
    ///         onFlashLiquidation() — deliberately msg.sender, not an arbitrary
    ///         target, so that any swap the receiver performs (e.g. against a DEX
    ///         router) is correctly attributed to the receiver's own address and
    ///         its own approvals, not the vault's. The vault never trusts or
    ///         interprets what the callback does; it only checks msg.sender's
    ///         resulting pSunDAI balance afterward. If repayment (repayAmount +
    ///         fee) isn't satisfied, the whole transaction reverts, including the
    ///         collateral transfer — no token minting occurs anywhere in this
    ///         path, so no unbacked supply can ever persist even transiently.
    function liquidateWithFlashMint(
        address user,
        uint256 repayAmount,
        bytes calldata data
    ) external nonReentrant {
        require(user != msg.sender, "Cannot self-liquidate");

        Vault storage v = vaults[user];
        _touch(user);

        require(v.debt > 0, "No debt");
        require(repayAmount > 0 && repayAmount <= v.debt, "Invalid amount");
        require(repayAmount * 10000 >= v.debt * MIN_LIQUIDATION_BPS, "Too small");

        (uint256 price, bool isSpot) = _liquidationPrice();
        uint256 reward = _liquidationReward(v, repayAmount, price);

        // Send the collateral reward first — this is what makes it "flash": no
        // pre-held pSunDAI required. If the liquidator fails to repay below,
        // this entire transaction (including this transfer) reverts.
        v.collateral    -= reward;
        totalCollateral -= reward;
        wpls.safeTransfer(msg.sender, reward);

        uint256 feeAmount = (repayAmount * FLASH_FEE_BPS) / 10_000;
        uint256 amountOwed = repayAmount + feeAmount;

        IFlashLiquidationReceiver(msg.sender).onFlashLiquidation(user, reward, amountOwed, data);

        require(psundai.balanceOf(msg.sender) >= amountOwed, "Insufficient repay");
        psundai.burn(msg.sender, amountOwed);
        surplusBuffer += feeAmount;

        v.debt    -= repayAmount;
        totalDebt -= repayAmount;
        _finalizeLiquidation(v, price);

        emit Liquidation(user, repayAmount, msg.sender, reward, _collateralRatio(user), isSpot);
    }

    // ── Bad debt clearing ─────────────────────────────────────────────────────

    /// @notice Clear a vault that is fully underwater (collateral < 100% of debt).
    ///         Callable when even a 0-bonus liquidation would lose money — regular
    ///         liquidate() cannot profitably work here.
    ///
    ///         Caller receives ALL remaining collateral at no cost (incentive to
    ///         clean up the system). The uncovered debt is written off against the
    ///         surplus buffer; any excess beyond the buffer is recorded as bad debt.
    ///
    ///         The bad debt represents pSunDAI in circulation without collateral
    ///         backing. It is cancelled over time via auto-reconciliation (future
    ///         stability fees) or explicitly via settleDebt().
    function clearBadDebt(address user) external nonReentrant {
        Vault storage v = vaults[user];
        _touch(user);
        require(v.debt > 0 && v.collateral > 0, "Nothing to clear");

        (uint256 price,) = _liquidationPriceView();
        uint256 collateralValue = (v.collateral * price) / 1e18;

        // Only callable when collateral is worth less than 100% of debt.
        // If collateral covers the debt, liquidate() should be used (liquidators profit).
        require(collateralValue < v.debt, "Not fully underwater - use liquidate()");

        uint256 col  = v.collateral;
        uint256 debt = v.debt;
        totalCollateral -= col;
        totalDebt       -= debt;
        delete vaults[user];

        // Write off the full debt against the surplus buffer.
        // The surplus buffer absorbs the loss without any on-chain token operation —
        // it's the system's accumulated equity from stability fees.
        if (surplusBuffer >= debt) {
            surplusBuffer -= debt;
        } else {
            uint256 covered   = surplusBuffer;
            surplusBuffer     = 0;
            uint256 uncovered = debt - covered;
            badDebtAccumulated += uncovered;
            emit BadDebtAccruedEvent(user, uncovered);
        }

        // Caller gets the remaining collateral — no payment required.
        // This creates a strong incentive to clean up underwater vaults promptly.
        IWPLS(address(wpls)).withdraw(col);
        _sendETH(msg.sender, col);

        emit BadDebtCleared(user, col, debt, msg.sender);
    }

    /// @notice Burn pSunDAI to directly cancel bad debt.
    ///         Anyone can call this: protocol team, community, anyone who wants to
    ///         restore full backing to the pSunDAI supply.
    function settleDebt(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(badDebtAccumulated >= amount, "Exceeds outstanding bad debt");
        psundai.burn(msg.sender, amount);
        badDebtAccumulated -= amount;
        emit DebtSettled(amount, msg.sender);
    }

    /// @notice Manually trigger surplus-to-bad-debt reconciliation.
    ///         Normally happens automatically on every _accrueInterest call.
    ///         Provided as an explicit entry point for bots and dashboards.
    function reconcile() external {
        _reconcile();
    }

    // ── Emergency unlock (30-day, zero debt) ──────────────────────────────────
    function emergencyUnlock() external nonReentrant {
        Vault storage v = vaults[msg.sender];
        require(v.debt == 0, "Repay first");
        require(v.collateral > 0, "No collateral");
        require(block.timestamp > v.lastDepositTime + 30 days, "Active");

        uint256 amt     = v.collateral;
        v.collateral    = 0;
        totalCollateral -= amt;
        IWPLS(address(wpls)).withdraw(amt);
        _sendETH(msg.sender, amt);
        emit EmergencyWithdraw(msg.sender, amt);
    }

    // ── Oracle-death emergency exits ──────────────────────────────────────────
    function emergencyRepay(uint256 amount) external nonReentrant {
        require(isOracleDead(), "Oracle alive - use repay()");
        Vault storage v = vaults[msg.sender];
        _touch(msg.sender);
        require(amount > 0 && v.debt >= amount, "Invalid repay");

        psundai.burn(msg.sender, amount);
        v.debt    -= amount;
        totalDebt -= amount;

        if (v.debt <= 1e12) {
            if (surplusBuffer >= v.debt) surplusBuffer -= v.debt; else surplusBuffer = 0;
            totalDebt -= v.debt;
            v.debt = 0;
        }

        emit EmergencyRepay(msg.sender, amount);
        emit Repay(msg.sender, amount, 0);
    }

    function emergencyWithdrawPLS(uint256 amount) external nonReentrant {
        require(isOracleDead(), "Oracle alive - use withdrawPLS()");
        Vault storage v = vaults[msg.sender];
        require(amount > 0 && v.collateral >= amount, "Invalid withdraw");
        require(v.debt == 0, "Repay debt first via emergencyRepay()");
        require(block.timestamp > v.lastDepositTime + WITHDRAW_COOLDOWN, "Cooldown");

        v.collateral    -= amount;
        totalCollateral -= amount;
        v.lastWithdrawTime = block.timestamp;

        IWPLS(address(wpls)).withdraw(amount);
        _sendETH(msg.sender, amount);
        emit EmergencyWithdrawOracleDead(msg.sender, amount);
    }

    // ── View functions ────────────────────────────────────────────────────────

    function vaultInfo(address user) external view returns (
        uint256 collateral,
        uint256 debt,
        uint256 collateralUSD,
        uint256 ratio,
        uint256 mintable,
        bool    oracleHealthy,
        uint256 price,
        uint256 systemRatio,
        bool    spotLiquidationActive
    ) {
        Vault storage v = vaults[user];
        collateral = v.collateral;
        debt       = v.debt;

        (uint256 p, uint256 ts) = oracle.peekPriceView();
        price         = (block.timestamp - ts > 300 || p == 0) ? lastOraclePrice : p;
        oracleHealthy = (p > 0 && block.timestamp - ts <= 600);
        collateralUSD = (collateral * price) / 1e18;
        ratio         = debt == 0 ? type(uint256).max : (collateral * price * 100) / (debt * 1e18);
        uint256 safeLimit = (collateralUSD * 100) / COLLATERAL_RATIO;
        uint256 ceiling   = _effectiveDebtCeiling();
        uint256 vCap      = _vaultCap();
        uint256 userMax   = safeLimit > debt ? safeLimit - debt : 0;
        userMax           = Math.min(userMax, debt < vCap ? vCap - debt : 0);
        mintable          = totalDebt < ceiling ? Math.min(userMax, ceiling - totalDebt) : 0;
        systemRatio          = systemHealth();
        spotLiquidationActive = oracle.isSpotLiquidationEnabled();
    }

    function maxMint(address user) external view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.collateral == 0) return 0;
        (uint256 p, uint256 ts) = oracle.peekPriceView();
        uint256 price    = (block.timestamp - ts > 300 || p == 0) ? lastOraclePrice : p;
        uint256 valueUSD = (v.collateral * price) / 1e18;
        uint256 limit    = (valueUSD * 100) / COLLATERAL_RATIO;
        uint256 userMax  = limit > v.debt ? limit - v.debt : 0;
        uint256 vCap     = _vaultCap();
        userMax          = Math.min(userMax, v.debt < vCap ? vCap - v.debt : 0);
        uint256 ceiling  = _effectiveDebtCeiling();
        uint256 room     = totalDebt < ceiling ? ceiling - totalDebt : 0;
        return Math.min(userMax, room);
    }

    function repayToHealth(address user) external view returns (uint256) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return 0;
        (uint256 p, uint256 ts) = oracle.peekPriceView();
        uint256 price   = (block.timestamp - ts > 300 || p == 0) ? lastOraclePrice : p;
        uint256 maxDebt = (v.collateral * price * 100) / (COLLATERAL_RATIO * 1e18);
        return v.debt > maxDebt ? v.debt - maxDebt : 0;
    }

    function isLiquidatable(address user) external view returns (bool canLiquidate, uint256 currentRatio, bool atSpotPrice) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return (false, type(uint256).max, false);
        (uint256 price, bool isSpot) = _liquidationPriceView();
        currentRatio = (v.collateral * price * 100) / (v.debt * 1e18);
        canLiquidate = currentRatio < LIQUIDATION_RATIO;
        atSpotPrice  = isSpot;
    }

    function liquidationInfo(address user) external view returns (
        uint256 debt,
        uint256 minRepay,
        uint256 bonusBps,
        uint256 auctionElapsed,
        bool    isUnderwater
    ) {
        Vault storage v = vaults[user];
        if (v.debt == 0) return (0, 0, 0, 0, false);
        debt     = v.debt;
        minRepay = (v.debt * MIN_LIQUIDATION_BPS) / 10000;
        auctionElapsed = v.undercollateralizedSince == 0
            ? 0
            : block.timestamp - v.undercollateralizedSince;
        uint256 elapsed = auctionElapsed > AUCTION_TIME ? AUCTION_TIME : auctionElapsed;
        bonusBps = MIN_BONUS_BPS + ((MAX_BONUS_BPS - MIN_BONUS_BPS) * elapsed / AUCTION_TIME);

        (uint256 price,) = _liquidationPriceView();
        uint256 collateralValue = (v.collateral * price) / 1e18;
        isUnderwater = collateralValue < v.debt;
    }

    // ── Vault enumeration ──────────────────────────────────────────────────────
    function getVaultCount() external view returns (uint256) {
        return vaultOwners.length;
    }

    function getVaultOwners(uint256 start, uint256 count) external view returns (address[] memory) {
        require(start < vaultOwners.length, "Out of bounds");
        uint256 end = start + count;
        if (end > vaultOwners.length) end = vaultOwners.length;
        address[] memory result = new address[](end - start);
        for (uint256 i = 0; i < end - start; i++) {
            result[i] = vaultOwners[start + i];
        }
        return result;
    }

    receive() external payable {}
    fallback() external payable {}
}
