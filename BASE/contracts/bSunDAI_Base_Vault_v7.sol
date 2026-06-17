// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║          bSunDAI Vault v7 — Base Chain CDP Stablecoin Vault          ║
 * ║                                                                      ║
 * ║   License:  MIT | One-Time Setup | Then Immutable Forever             ║
 * ║                                                                      ║
 * ║   v7 ADDITIONS FROM v6.5:                                             ║
 * ║                                                                      ║
 * ║   DUAL-PRICE LIQUIDATION                                              ║
 * ║   Committed price governs minting and withdrawal safety (unchanged).  ║
 * ║   When oracle's Chainlink warning track has been active for 30+ min,  ║
 * ║   liquidation eligibility switches to live Chainlink price.           ║
 * ║   Flash crashes: warning clears quickly, committed price never used.  ║
 * ║   Real crashes: Chainlink stays down, liquidations proceed at market.  ║
 * ║   Closes the bad-debt window inherent in conservative price stepping.  ║
 * ║                                                                      ║
 * ║   SURPLUS BUFFER + BAD DEBT ACCOUNTING                                ║
 * ║   Stability fees accumulate as `surplusBuffer` (in bSunDAI units).    ║
 * ║   This equity absorbs uncovered liquidation losses automatically.     ║
 * ║   `clearBadDebt(user)` — anyone seizes a zombie vault's collateral    ║
 * ║     free. Remaining debt written off against surplus or badDebt.      ║
 * ║   `settleDebt(amount)` — anyone burns bSunDAI to cancel bad debt.     ║
 * ║   `reconcile()` — public; also called after every fee accrual.        ║
 * ║   `systemEquity()` — surplusBuffer minus badDebtAccumulated.           ║
 * ║                                                                      ║
 * ║   DEBT CEILING                                                        ║
 * ║   Immutable. Set at deploy time. mint() and depositAndAutoMintETH()   ║
 * ║   revert if minting would exceed it. Limits protocol-level risk.       ║
 * ║                                                                      ║
 * ║   PRESERVED FROM v6.5 (unchanged):                                    ║
 * ║   ✓ Redemption mechanism — hard $1 peg floor                          ║
 * ║     redeemWithPermit support                                           ║
 * ║   ✓ Permit-based single-tx operations (repay, liquidate, redeem)      ║
 * ║   ✓ Inverted Dutch auction: 10% → 2% over 3h (high bonus first)       ║
 * ║   ✓ Zombie vault views (isZombieVault, vaultBadDebt, systemBadDebt)   ║
 * ║   ✓ emergencyRepay / emergencyWithdrawETH / emergencyUnlock           ║
 * ║   ✓ isUXSafe, systemHealth, vaultInfo, redemptionPreview              ║
 * ║                                                                      ║
 * ║   FIXES vs v6.5:                                                      ║
 * ║   ✓ M-8: repayAndAutoWithdraw full exit emits Withdraw (was           ║
 * ║          EmergencyWithdraw on normal full repay — wrong event)         ║
 * ║   ✓ L-4: _doRepay clears debt dust ≤ 1e12 after repayment            ║
 * ║                                                                      ║
 * ║   NOT ADDED:                                                           ║
 * ║   ✗ markUndercollateralized() — inverted Dutch auction pays maximum    ║
 * ║     bonus immediately; bots need no incentive to wait.                 ║
 * ║                                                                      ║
 * ║   Deploy args: weth, bsundai, oracle, debtCeiling                     ║
 * ║   Dev: Elite Team6 | https://www.sundaitoken.com                      ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./bSunDAI_ASA_Token_v7.sol";
import "./bSunDAI_Oracle_BASE_v7.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

contract bSunDAIVault_ASA_v7 is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IERC20                  public immutable weth;
    bSunDAI                 public immutable bsundai;
    bSunDAIoracleBASE_v7    public immutable oracle;

    /// @notice Immutable protocol-level debt ceiling (in bSunDAI, 1e18 units).
    uint256                 public immutable DEBT_CEILING;

    string public constant VERSION = "bSunDAIVault_ASA_v7.0";

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
    uint256 public constant LIQUIDATION_COOLDOWN = 600;

    uint256 public constant MIN_SYSTEM_HEALTH    = 130;
    uint256 public constant MAX_ORACLE_STALENESS = 300;
    uint256 public constant ORACLE_FAILURE_OVERRIDE = 7 days;

    uint256 public constant REDEMPTION_FEE_BPS   = 50;
    uint256 public constant MIN_REDEMPTION       = 100e18;

    /*//////////////////////////////////////////////////////////////
                              VAULT STRUCT
    //////////////////////////////////////////////////////////////*/

    struct Vault {
        uint256 collateral;
        uint256 debt;
        uint256 lastDepositTime;
        uint256 lastWithdrawTime;
        uint256 lastLiquidationTime;
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
    // surplusBuffer: accumulated stability fees in bSunDAI units.
    //   Represents protocol equity — used to absorb uncovered losses.
    // badDebtAccumulated: unrecovered debt from cleared zombie vaults.
    //   Reduced by surplusBuffer reconciliation and settleDebt().
    uint256 public surplusBuffer;
    uint256 public badDebtAccumulated;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed user, uint256 amount, uint256 ratio);
    event Withdraw(address indexed user, uint256 amount, uint256 ratio);
    event Mint(address indexed user, uint256 amount, uint256 ratio);
    event Repay(address indexed user, uint256 amount, uint256 ratio);
    event Liquidation(address indexed user, uint256 repayAmount, address indexed liquidator, uint256 reward, uint256 ratio);
    event PartialLiquidation(address indexed user, uint256 repayAmount, uint256 debtRemaining, address indexed liquidator);
    event Redemption(address indexed vaultOwner, address indexed redeemer, uint256 bSunDAIBurned, uint256 wethReceived, uint256 feeBps);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event OracleFallbackUsed(uint256 price, uint256 timestamp);
    event EmergencyRepay(address indexed user, uint256 amount, string reason);
    event EmergencyWithdrawETH(address indexed user, uint256 amount, string reason);
    event VaultRegistered(address indexed user);

    // v7 events
    event BadDebtCleared(
        address indexed vaultOwner,
        uint256 debtWrittenOff,
        uint256 collateralSeized,
        address indexed caller,
        uint256 coveredBySurplus,
        uint256 uncovered
    );
    event BadDebtSettled(address indexed settler, uint256 amount);
    event SurplusReconciled(uint256 amount);

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
        oracle       = bSunDAIoracleBASE_v7(_oracle);
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
                     SURPLUS BUFFER & BAD DEBT
    //////////////////////////////////////////////////////////////*/

    /// @dev Apply surplus buffer against accumulated bad debt.
    ///      Called automatically on every fee accrual, and available publicly.
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
    ///         Positive = surplus covers bad debt with room to spare.
    ///         Negative = bad debt exceeds accumulated surplus.
    function systemEquity() external view returns (int256) {
        return int256(surplusBuffer) - int256(badDebtAccumulated);
    }

    /// @notice Clear a zombie vault (collateral value < debt).
    ///         Caller seizes all collateral for free as an incentive to clear the vault.
    ///         Debt written off against surplus buffer; remainder becomes bad debt.
    function clearBadDebt(address user) external nonReentrant {
        Vault storage v = vaults[user];
        require(v.debt > 0, "No debt");

        (uint256 price, ) = _getLiquidationContext();
        uint256 collateralValue = (v.collateral * price) / 1e18;
        require(collateralValue < v.debt, "Vault is not a zombie");

        uint256 collateral = v.collateral;
        uint256 debt       = v.debt;

        totalCollateral -= collateral;
        totalDebt       -= debt;
        delete vaults[user];

        uint256 covered   = surplusBuffer < debt ? surplusBuffer : debt;
        surplusBuffer    -= covered;
        uint256 uncovered = debt - covered;
        if (uncovered > 0) badDebtAccumulated += uncovered;

        IWETH(address(weth)).withdraw(collateral);
        _sendETH(msg.sender, collateral);

        emit BadDebtCleared(user, debt, collateral, msg.sender, covered, uncovered);
    }

    /// @notice Burn bSunDAI to cancel an equal amount of accumulated bad debt.
    ///         Anyone can call — debt holders, protocol supporters, etc.
    function settleDebt(uint256 amount) external nonReentrant {
        require(amount > 0 && badDebtAccumulated >= amount, "Invalid settle amount");
        _collectAndBurn(msg.sender, amount);
        badDebtAccumulated -= amount;
        emit BadDebtSettled(msg.sender, amount);
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

    /// @dev Advance oracle state, then return the appropriate liquidation price.
    ///      Uses Chainlink live price when the warning track has confirmed a real crash.
    ///      Falls back to committed price (conservative) otherwise.
    function _getLiquidationContext() internal returns (uint256 price, bool isChainlink) {
        price = _safePrice();
        if (oracle.isChainlinkLiquidationEnabled()) {
            uint256 clPrice = oracle.getChainlinkPrice();
            if (clPrice > 0) return (clPrice, true);
        }
        return (price, false);
    }

    /// @dev View version of _getLiquidationContext for off-chain reads.
    function _liquidationPriceView() internal view returns (uint256 price, bool isChainlink) {
        (uint256 p,) = oracle.peekPrice();
        price = p > 0 ? p : lastOraclePrice;
        if (oracle.isChainlinkLiquidationEnabled()) {
            uint256 clPrice = oracle.getChainlinkPrice();
            if (clPrice > 0) return (clPrice, true);
        }
        return (price, false);
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
        surplusBuffer += fee;
        v.lastDebtAccrual = block.timestamp;
        _clearDebtDust(v);
        _reconcile();
    }

    /// @dev Forgive sub-dust residual debt and keep surplusBuffer in sync.
    ///      Called from every path that can leave v.debt > 0 but tiny.
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

        require(totalDebt + mintAmount <= DEBT_CEILING, "Debt ceiling reached");

        Vault storage v = vaults[msg.sender];
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
        Vault storage v = vaults[msg.sender];
        _registerVault(msg.sender);
        _accrueInterest(v);
        if (v.debt == 0) v.lastDebtAccrual = block.timestamp;
        require(systemHealth() >= MIN_SYSTEM_HEALTH, "Mint paused: system undercollateralized");
        require(totalDebt + amount <= DEBT_CEILING, "Debt ceiling reached");
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
            // M-8 fix: full exit is a normal withdrawal, not an emergency
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
                           LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function _doLiquidate(address user, uint256 repayAmount) internal {
        require(user != msg.sender, "Cannot self-liquidate");
        require(repayAmount > 0, "Invalid amount");

        Vault storage v = vaults[user];
        _accrueInterest(v);
        require(v.debt > 0, "No debt");
        require(repayAmount <= v.debt, "Exceeds debt");
        require(block.timestamp > v.lastLiquidationTime + LIQUIDATION_COOLDOWN, "Liquidation cooldown");

        // v7: use real market price (Chainlink) when warning is confirmed, else committed price
        (uint256 price, ) = _getLiquidationContext();

        uint256 currentRatio = (v.collateral * price * 100) / (v.debt * 1e18);
        require(currentRatio < LIQUIDATION_RATIO, "Vault is safe");

        if (v.undercollateralizedSince == 0) v.undercollateralizedSince = block.timestamp;

        uint256 baseCollateral = (repayAmount * 1e18) / price;
        uint256 t = block.timestamp - v.undercollateralizedSince;
        if (t > AUCTION_TIME) t = AUCTION_TIME;

        uint256 bonusBps        = MAX_BONUS_BPS - ((MAX_BONUS_BPS - MIN_BONUS_BPS) * t) / AUCTION_TIME;
        uint256 bonusCollateral = (baseCollateral * bonusBps) / 10000;
        uint256 totalReward     = baseCollateral + bonusCollateral;

        if (totalReward > v.collateral) {
            totalReward  = v.collateral;
            uint256 impliedRepay = (totalReward * price) / 1e18;
            if (impliedRepay > v.debt) impliedRepay = v.debt;
            repayAmount    = impliedRepay;
            baseCollateral = (repayAmount * 1e18) / price;
            bonusCollateral = (baseCollateral * bonusBps) / 10000;
            totalReward = baseCollateral + bonusCollateral;
            if (totalReward > v.collateral) totalReward = v.collateral;
        }

        v.debt                -= repayAmount;
        v.collateral          -= totalReward;
        v.lastLiquidationTime  = block.timestamp;
        totalDebt             -= repayAmount;
        totalCollateral       -= totalReward;

        _collectAndBurn(msg.sender, repayAmount);
        IWETH(address(weth)).withdraw(totalReward);
        _sendETH(msg.sender, totalReward);

        if (v.debt == 0) {
            v.undercollateralizedSince = 0;
        } else {
            uint256 newRatio = (v.collateral * price * 100) / (v.debt * 1e18);
            if (newRatio >= LIQUIDATION_RATIO) v.undercollateralizedSince = 0;
        }

        if (v.debt > 0) emit PartialLiquidation(user, repayAmount, v.debt, msg.sender);
        emit Liquidation(user, repayAmount, msg.sender, totalReward, _collateralRatio(user));
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
