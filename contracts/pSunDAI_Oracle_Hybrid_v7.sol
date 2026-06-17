// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║          pSunDAIoraclePLSXHybrid — ELITE TEAM6 (v7)                 ║
 * ║                                                                      ║
 * ║   Self-Healing Dual-Track Oracle for Autonomous Stable Assets        ║
 * ║                                                                      ║
 * ║   TWO PRICE TRACKS:                                                  ║
 * ║                                                                      ║
 * ║   MINT PRICE (conservative TWAP):                                    ║
 * ║   Used for: minting limits, withdrawal checks, health display.       ║
 * ║   Asymmetric confirmation — 1% down / 5% up instant thresholds,      ║
 * ║   4h confirmation for crashes, 30min for pumps, 3%/10% steps.        ║
 * ║   This track is deliberately slow on crashes to prevent flash-crash  ║
 * ║   liquidation cascades.                                              ║
 * ║                                                                      ║
 * ║   SPOT WARNING TRACK (5-pool median, real-time):                     ║
 * ║   Used for: liquidation eligibility when TWAP is lagging a real      ║
 * ║   crash. If the 5-pool spot median has been SPOT_WARNING_BPS (5%)    ║
 * ║   below the TWAP for SPOT_CONFIRM_TIME (30 min) continuously,        ║
 * ║   isSpotLiquidationEnabled() returns true.                           ║
 * ║                                                                      ║
 * ║   WHY THIS MATTERS:                                                  ║
 * ║   A flash crash lasts minutes — spot recovers before 30 min,         ║
 * ║   spotWarning clears, no liquidations triggered. A real crash stays  ║
 * ║   down — spot confirms after 30 min, liquidations can proceed at     ║
 * ║   actual market price before the TWAP has finished stepping down.    ║
 * ║   This closes the bad-debt accumulation window that the 4h TWAP      ║
 * ║   confirmation inherently creates.                                   ║
 * ║                                                                      ║
 * ║   Carries forward all v6 fixes:                                      ║
 * ║   ✓ H-1: oracleTimestampLast (aligned TWAP window)                  ║
 * ║   ✓ H-4: no spot fallback for sub-interval TWAP windows             ║
 * ║   ✓ M-5: stableDecimals cached at init                              ║
 * ║                                                                      ║
 * ║   Dev: ELITE TEAM6 | https://www.sundaitoken.com                     ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

import "@openzeppelin/contracts/utils/math/Math.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

contract pSunDAIoraclePLSXHybrid_v7 {
    using Math for uint256;

    string public constant VERSION = "pSunDAIoraclePLSXHybrid_v7";

    // ── Pair data ────────────────────────────────────────────────────────────
    struct PairData {
        IUniswapV2Pair pair;
        uint256 priceCumulativeLast;
        uint40  oracleTimestampLast; // oracle's own last-sample time (H-1 fix)
        uint8   stableDecimals;      // cached at init (M-5 fix)
        bool    wplsIsToken0;
    }

    struct PendingPriceUpdate {
        uint256 targetPrice;
        uint256 firstSeenTime;
        bool    isActive;
    }

    PairData public pairDAIv1;
    PairData public pairDAIv2;
    PairData public pairUSDCv1;
    PairData public pairUSDCv2;
    PairData public pairUSDT;

    // ── Immutable addresses ──────────────────────────────────────────────────
    address public immutable wpls;
    address public immutable dai;
    address public immutable usdc;
    address public immutable usdt;
    address public immutable deployer;

    address public vault;
    bool    public immutableSet;

    // ── TWAP track state ─────────────────────────────────────────────────────
    uint256 public lastPrice;
    uint256 public lastUpdateTimestamp;
    uint256 public lastPokeTime;
    PendingPriceUpdate public pendingUpdate;

    // ── Spot warning track state ─────────────────────────────────────────────
    // Set when 5-pool spot median first drops SPOT_WARNING_BPS below lastPrice.
    // Cleared when spot recovers. isSpotLiquidationEnabled() returns true when
    // this has been nonzero for >= SPOT_CONFIRM_TIME.
    uint256 public spotWarningStart;

    // ── TWAP constants ───────────────────────────────────────────────────────
    uint256 public constant PRECISION              = 1e18;
    uint256 public constant MIN_RESERVE_USD        = 1_000 * 1e18;
    uint256 public constant MAX_PRICE_AGE          = 300;
    uint256 public constant MIN_TWAP_INTERVAL      = 60;
    uint256 public constant CONFIRM_TIME_DOWN      = 4 hours;
    uint256 public constant CONFIRM_TIME_UP        = 30 minutes;
    uint256 public constant STEP_SIZE_DOWN_BPS     = 300;
    uint256 public constant STEP_SIZE_UP_BPS       = 1000;
    uint256 public constant INSTANT_UPDATE_DOWN_BPS = 100;
    uint256 public constant INSTANT_UPDATE_UP_BPS   = 500;
    uint256 public constant RECOVERY_BPS           = 300;
    uint256 public constant TARGET_SHIFT_BPS       = 300;
    uint256 public constant MIN_POKE_INTERVAL      = 30 minutes;

    // ── Spot warning constants ────────────────────────────────────────────────
    // Spot must be this far below TWAP before the warning clock starts.
    // 5% chosen because small divergences are normal on thin-liquidity DEXes.
    uint256 public constant SPOT_WARNING_BPS   = 500;
    // Spot must stay below the threshold for this long before liquidations enable.
    // 30 min: long enough to survive flash crashes, short enough to catch real ones.
    uint256 public constant SPOT_CONFIRM_TIME  = 30 minutes;

    // ── Events ───────────────────────────────────────────────────────────────
    event PriceUpdated(uint256 price, uint256 timestamp, bool stepped);
    event ConfirmationStarted(uint256 targetPrice, uint256 confirmTime, bool isDown);
    event ConfirmationCancelled(uint256 reason);
    event SpotWarningTriggered(uint256 spotPrice, uint256 twapPrice, uint256 timestamp);
    event SpotWarningCleared(uint256 spotPrice, uint256 twapPrice);
    event VaultSet(address vault);

    modifier onlyVault() {
        require(msg.sender == vault && vault != address(0), "Not vault");
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _pairDAIv1,
        address _pairDAIv2,
        address _pairUSDCv1,
        address _pairUSDCv2,
        address _pairUSDT,
        address _wpls,
        address _dai,
        address _usdc,
        address _usdt
    ) {
        require(
            _pairDAIv1  != address(0) && _pairDAIv2  != address(0) &&
            _pairUSDCv1 != address(0) && _pairUSDCv2 != address(0) &&
            _pairUSDT   != address(0), "Invalid pair"
        );
        require(
            _wpls != address(0) && _dai  != address(0) &&
            _usdc != address(0) && _usdt != address(0), "Invalid token"
        );

        deployer = msg.sender;
        wpls = _wpls; dai = _dai; usdc = _usdc; usdt = _usdt;

        pairDAIv1  = _initPair(_pairDAIv1,  _wpls);
        pairDAIv2  = _initPair(_pairDAIv2,  _wpls);
        pairUSDCv1 = _initPair(_pairUSDCv1, _wpls);
        pairUSDCv2 = _initPair(_pairUSDCv2, _wpls);
        pairUSDT   = _initPair(_pairUSDT,   _wpls);

        (uint256 initialPrice,) = _spotMedian();
        lastPrice           = initialPrice > 0 ? initialPrice : 1e18;
        lastUpdateTimestamp = block.timestamp;
        lastPokeTime        = block.timestamp;

        emit PriceUpdated(lastPrice, block.timestamp, false);
    }

    // ── Pair initialization ──────────────────────────────────────────────────
    function _initPair(address pairAddr, address _wpls) internal view returns (PairData memory d) {
        IUniswapV2Pair p = IUniswapV2Pair(pairAddr);
        bool wplsIs0 = p.token0() == _wpls;
        require(wplsIs0 || p.token1() == _wpls, "Pair missing WPLS");
        address stableToken = wplsIs0 ? p.token1() : p.token0();
        d = PairData({
            pair:                p,
            priceCumulativeLast: wplsIs0 ? p.price0CumulativeLast() : p.price1CumulativeLast(),
            oracleTimestampLast: uint40(block.timestamp),
            stableDecimals:      _getDecimals(stableToken),
            wplsIsToken0:        wplsIs0
        });
    }

    // ── Vault link (one-time) ────────────────────────────────────────────────
    function setVault(address _vault) external {
        require(!immutableSet,          "Vault locked");
        require(msg.sender == deployer, "Only deployer");
        require(_vault != address(0),   "Invalid vault");
        vault        = _vault;
        immutableSet = true;
        emit VaultSet(_vault);
    }

    // ── External oracle interface ────────────────────────────────────────────

    /// @notice Advance TWAP state, update spot warning, return conservative price.
    ///         Called by vault on every user interaction.
    function getPriceWithTimestamp()
        external
        onlyVault
        returns (uint256 price, uint256 timestamp)
    {
        (price, timestamp) = _updateIfNeeded();
        _updateSpotWarning(lastPrice); // always refresh spot warning, even if TWAP didn't move
        require(price > 0, "Invalid price");
    }

    /// @notice Read conservative TWAP price without advancing state.
    function peekPriceView() external view returns (uint256 price, uint256 timestamp) {
        if (block.timestamp - lastUpdateTimestamp > 24 hours) {
            (price,) = _spotMedian();
            if (price == 0) return (lastPrice, lastUpdateTimestamp);
            return (price, block.timestamp);
        }
        return (lastPrice, lastUpdateTimestamp);
    }

    /// @notice Current 5-pool spot median. Used by vault when spot liquidation is enabled.
    function getSpotPrice() external view returns (uint256 price) {
        (price,) = _spotMedian();
    }

    /// @notice True when spot has been SPOT_WARNING_BPS below TWAP for SPOT_CONFIRM_TIME.
    ///         When true, the vault switches to spot price for liquidation eligibility.
    function isSpotLiquidationEnabled() external view returns (bool) {
        if (spotWarningStart == 0) return false;
        return block.timestamp - spotWarningStart >= SPOT_CONFIRM_TIME;
    }

    /// @notice How long the spot warning has been active (0 if not active).
    function spotWarningElapsed() external view returns (uint256) {
        if (spotWarningStart == 0) return 0;
        return block.timestamp - spotWarningStart;
    }

    function isStale(uint256 threshold) external view returns (bool) {
        return block.timestamp - lastUpdateTimestamp > threshold;
    }

    function isHealthy() external view returns (bool) {
        return (block.timestamp - lastUpdateTimestamp) < (MAX_PRICE_AGE * 2);
    }

    // ── Public poke (rate-limited, 30min) ────────────────────────────────────
    function poke() external {
        require(block.timestamp >= lastPokeTime + MIN_POKE_INTERVAL, "Poke cooldown");
        lastPokeTime = block.timestamp;
        _updateIfValid();
        _updateSpotWarning(lastPrice);
    }

    function canPoke() external view returns (bool) {
        return block.timestamp >= lastPokeTime + MIN_POKE_INTERVAL;
    }

    function timeUntilNextPoke() external view returns (uint256) {
        if (block.timestamp >= lastPokeTime + MIN_POKE_INTERVAL) return 0;
        return (lastPokeTime + MIN_POKE_INTERVAL) - block.timestamp;
    }

    // ── Spot warning track ───────────────────────────────────────────────────

    /// @notice Compares fresh 5-pool spot median against conservative TWAP.
    ///         If spot has been SPOT_WARNING_BPS below TWAP continuously for
    ///         SPOT_CONFIRM_TIME, the spot liquidation arm activates.
    ///         This runs on every vault interaction and every poke() — no keeper needed.
    function _updateSpotWarning(uint256 twapPrice) internal {
        if (twapPrice == 0) return;
        (uint256 spot,) = _spotMedian();
        if (spot == 0) return; // all pools empty — can't determine

        uint256 warningThreshold = (twapPrice * (10000 - SPOT_WARNING_BPS)) / 10000;

        if (spot < warningThreshold) {
            if (spotWarningStart == 0) {
                spotWarningStart = block.timestamp;
                emit SpotWarningTriggered(spot, twapPrice, block.timestamp);
            }
            // else: clock already running
        } else {
            if (spotWarningStart != 0) {
                spotWarningStart = 0;
                emit SpotWarningCleared(spot, twapPrice);
            }
        }
    }

    // ── Internal TWAP update logic ───────────────────────────────────────────

    function _updateIfNeeded() internal returns (uint256, uint256) {
        if (block.timestamp - lastUpdateTimestamp > MIN_TWAP_INTERVAL) {
            return _updateIfValid();
        }
        return (lastPrice, lastUpdateTimestamp);
    }

    function _updateIfValid() internal returns (uint256, uint256) {
        uint256 newPrice = _getMedianPrice();
        if (newPrice == 0) return (lastPrice, lastUpdateTimestamp);

        if (lastPrice == 1e18 || lastPrice == 0) {
            lastPrice           = newPrice;
            lastUpdateTimestamp = block.timestamp;
            emit PriceUpdated(newPrice, block.timestamp, false);
            return (newPrice, block.timestamp);
        }

        return _processPriceUpdate(newPrice);
    }

    function _getMedianPrice() internal returns (uint256) {
        uint256[5] memory px;
        bool[5]    memory valid;
        uint8[5]   memory decs;

        (px[0],, valid[0]) = _tryTWAP(pairDAIv1);  decs[0] = pairDAIv1.stableDecimals;
        (px[1],, valid[1]) = _tryTWAP(pairDAIv2);  decs[1] = pairDAIv2.stableDecimals;
        (px[2],, valid[2]) = _tryTWAP(pairUSDCv1); decs[2] = pairUSDCv1.stableDecimals;
        (px[3],, valid[3]) = _tryTWAP(pairUSDCv2); decs[3] = pairUSDCv2.stableDecimals;
        (px[4],, valid[4]) = _tryTWAP(pairUSDT);   decs[4] = pairUSDT.stableDecimals;

        uint256[5] memory prices;
        uint8 count;
        for (uint8 i; i < 5; i++) {
            if (!valid[i] || px[i] == 0) continue;
            prices[count++] = _normalizeTo1e18(px[i], decs[i]);
        }

        if (count == 0) return 0;
        return _median(prices, count);
    }

    // ── Asymmetric price update logic ─────────────────────────────────────────

    function _processPriceUpdate(uint256 newPrice) internal returns (uint256, uint256) {
        uint256 diff = newPrice > lastPrice ? newPrice - lastPrice : lastPrice - newPrice;
        uint256 divergenceBps = (diff * 10_000) / lastPrice;
        bool    isDown        = newPrice < lastPrice;

        uint256 instantThreshold = isDown ? INSTANT_UPDATE_DOWN_BPS : INSTANT_UPDATE_UP_BPS;

        if (divergenceBps <= instantThreshold) {
            if (pendingUpdate.isActive) {
                delete pendingUpdate;
                emit ConfirmationCancelled(0);
            }
            lastPrice           = newPrice;
            lastUpdateTimestamp = block.timestamp;
            emit PriceUpdated(newPrice, block.timestamp, false);
            return (newPrice, block.timestamp);
        }

        return _handleLargeMove(newPrice, divergenceBps);
    }

    function _handleLargeMove(uint256 newPrice, uint256 divergenceBps) internal returns (uint256, uint256) {
        bool isDownward = newPrice < lastPrice;
        if (!pendingUpdate.isActive) return _startConfirmation(newPrice, isDownward);
        return _processPendingUpdate(newPrice, divergenceBps, isDownward);
    }

    function _startConfirmation(uint256 newPrice, bool isDownward) internal returns (uint256, uint256) {
        uint256 confirmTime = isDownward ? CONFIRM_TIME_DOWN : CONFIRM_TIME_UP;
        pendingUpdate = PendingPriceUpdate({
            targetPrice:   newPrice,
            firstSeenTime: block.timestamp,
            isActive:      true
        });
        emit ConfirmationStarted(newPrice, confirmTime, isDownward);
        return (lastPrice, lastUpdateTimestamp);
    }

    function _processPendingUpdate(
        uint256 newPrice,
        uint256 divergenceBps,
        bool    isDownward
    ) internal returns (uint256, uint256) {
        uint256 pendingDiff = newPrice > pendingUpdate.targetPrice
            ? newPrice - pendingUpdate.targetPrice
            : pendingUpdate.targetPrice - newPrice;
        uint256 pendingDivergenceBps = (pendingDiff * 10_000) / pendingUpdate.targetPrice;

        if (pendingDivergenceBps > TARGET_SHIFT_BPS) {
            emit ConfirmationCancelled(1);
            return _startConfirmation(newPrice, isDownward);
        }

        if (divergenceBps <= RECOVERY_BPS) {
            delete pendingUpdate;
            emit ConfirmationCancelled(0);
            lastPrice           = newPrice;
            lastUpdateTimestamp = block.timestamp;
            emit PriceUpdated(newPrice, block.timestamp, false);
            return (newPrice, block.timestamp);
        }

        bool    targetIsDown = pendingUpdate.targetPrice < lastPrice;
        uint256 confirmTime  = targetIsDown ? CONFIRM_TIME_DOWN : CONFIRM_TIME_UP;
        if (block.timestamp - pendingUpdate.firstSeenTime < confirmTime) {
            return (lastPrice, lastUpdateTimestamp);
        }

        return _stepTowardTarget();
    }

    function _stepTowardTarget() internal returns (uint256, uint256) {
        bool    targetIsDown = pendingUpdate.targetPrice < lastPrice;
        uint256 stepSizeBps  = targetIsDown ? STEP_SIZE_DOWN_BPS : STEP_SIZE_UP_BPS;
        uint256 maxMove      = (lastPrice * stepSizeBps) / 10_000;

        uint256 remainingDiff = pendingUpdate.targetPrice > lastPrice
            ? pendingUpdate.targetPrice - lastPrice
            : lastPrice - pendingUpdate.targetPrice;

        uint256 updatedPrice;
        if (remainingDiff <= maxMove) {
            updatedPrice = pendingUpdate.targetPrice;
            delete pendingUpdate;
        } else {
            updatedPrice = targetIsDown ? lastPrice - maxMove : lastPrice + maxMove;
        }

        lastPrice           = updatedPrice;
        lastUpdateTimestamp = block.timestamp;
        emit PriceUpdated(updatedPrice, block.timestamp, true);
        return (updatedPrice, block.timestamp);
    }

    // ── TWAP calculation (v6 fixes carried forward) ──────────────────────────

    function _tryTWAP(PairData storage d)
        internal
        returns (uint256 price, uint256 timestamp, bool valid)
    {
        (uint112 r0, uint112 r1, uint32 tsPair) = d.pair.getReserves();
        if (r0 == 0 || r1 == 0) return (0, tsPair, false);
        if (block.timestamp <= d.oracleTimestampLast) return (0, tsPair, false);

        uint32 elapsed = uint32(block.timestamp - uint256(d.oracleTimestampLast));

        uint112 stableReserve = d.wplsIsToken0 ? r1 : r0;
        uint256 scaledReserve = uint256(stableReserve) * (10 ** (18 - d.stableDecimals));
        if (scaledReserve < MIN_RESERVE_USD) return (0, tsPair, false);

        // H-4: no spot fallback — sub-interval windows return invalid
        if (elapsed < MIN_TWAP_INTERVAL) return (0, tsPair, false);

        uint256 cumulative = d.wplsIsToken0
            ? d.pair.price0CumulativeLast()
            : d.pair.price1CumulativeLast();

        unchecked {
            uint32 delta = uint32(block.timestamp) - tsPair;
            if (delta > 0) {
                uint256 px = d.wplsIsToken0
                    ? (uint256(r1) << 112) / r0
                    : (uint256(r0) << 112) / r1;
                cumulative += px * delta;
            }
        }

        uint256 diff = cumulative - d.priceCumulativeLast;
        uint256 avg  = Math.mulDiv(diff, PRECISION, uint256(elapsed) << 112);

        d.priceCumulativeLast = cumulative;
        d.oracleTimestampLast  = uint40(block.timestamp);

        bool fresh = (block.timestamp - tsPair <= MAX_PRICE_AGE);
        return (avg, tsPair, fresh);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _normalizeTo1e18(uint256 price, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return price;
        if (dec < 18)  return price * 10 ** (18 - dec);
        return price / 10 ** (dec - 18);
    }

    function _getDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length == 0) return 18;
        uint8 d = abi.decode(data, (uint8));
        return (d < 6 || d > 18) ? 18 : d;
    }

    function _median(uint256[5] memory a, uint8 count) internal pure returns (uint256) {
        for (uint8 i = 1; i < count; i++) {
            uint256 key = a[i];
            uint8   j   = i;
            while (j > 0 && a[j - 1] > key) { a[j] = a[j - 1]; j--; }
            a[j] = key;
        }
        return a[count / 2];
    }

    function _spotMedian() internal view returns (uint256 price, uint256 ts) {
        uint256[5] memory px;
        uint8 count;
        PairData[5] memory arr = [pairDAIv1, pairDAIv2, pairUSDCv1, pairUSDCv2, pairUSDT];

        for (uint i = 0; i < 5; i++) {
            (uint112 r0, uint112 r1, uint32 t0) = arr[i].pair.getReserves();
            if (r0 == 0 || r1 == 0) continue;

            uint112 stableReserve = arr[i].wplsIsToken0 ? r1 : r0;
            uint256 scaledReserve = uint256(stableReserve) * (10 ** (18 - arr[i].stableDecimals));
            if (scaledReserve < MIN_RESERVE_USD) continue;

            uint256 p = arr[i].wplsIsToken0
                ? (uint256(r1) * PRECISION) / r0
                : (uint256(r0) * PRECISION) / r1;
            p = _normalizeTo1e18(p, arr[i].stableDecimals);
            px[count++] = p;
            ts = t0;
        }

        if (count == 0) return (0, block.timestamp);
        return (_median(px, count), ts);
    }

    // ── Monitoring views ─────────────────────────────────────────────────────

    function getPriceStatus() external view returns (
        uint256 currentPrice,
        uint256 marketPrice,
        uint256 divergenceBps,
        bool    inConfirmation,
        uint256 confirmTimeRemaining,
        uint256 targetPrice,
        bool    spotWarningActive,
        bool    spotLiquidationEnabled
    ) {
        currentPrice = lastPrice;
        (marketPrice,) = _spotMedian();

        if (marketPrice > 0 && currentPrice > 0) {
            uint256 diff = marketPrice > currentPrice
                ? marketPrice - currentPrice
                : currentPrice - marketPrice;
            divergenceBps = (diff * 10_000) / currentPrice;
        }

        inConfirmation = pendingUpdate.isActive;
        targetPrice    = pendingUpdate.targetPrice;

        if (inConfirmation) {
            bool    isDown      = targetPrice < currentPrice;
            uint256 confirmTime = isDown ? CONFIRM_TIME_DOWN : CONFIRM_TIME_UP;
            uint256 elapsed     = block.timestamp - pendingUpdate.firstSeenTime;
            confirmTimeRemaining = elapsed < confirmTime ? confirmTime - elapsed : 0;
        }

        spotWarningActive        = spotWarningStart != 0;
        spotLiquidationEnabled   = spotWarningStart != 0 &&
                                   block.timestamp - spotWarningStart >= SPOT_CONFIRM_TIME;
    }
}
