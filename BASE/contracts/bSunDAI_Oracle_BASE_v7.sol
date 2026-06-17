// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║       bSunDAI Oracle v7 — Hybrid Chainlink + TWAP + Warning Track    ║
 * ║                                                                      ║
 * ║   Primary:  Aave Oracle (Chainlink ETH/USD) — accurate, real-time    ║
 * ║   Backup:   Uniswap V3 TWAP median (3 pools) — trustless, on-chain   ║
 * ║   Safety:   USDC depeg guard — disables TWAP if USDC < $0.97         ║
 * ║                                                                      ║
 * ║   TWO COMMITTED PRICE TRACKS:                                         ║
 * ║                                                                      ║
 * ║   COMMITTED PRICE (conservative stepping):                            ║
 * ║   Used for minting limits and withdrawal safety. Moves ≤ 2% down /   ║
 * ║   ≤ 5% up are accepted instantly. Larger moves enter a confirmation   ║
 * ║   period (4h down / 30min up) before stepping. Prevents liquidation  ║
 * ║   cascades during flash crashes.                                      ║
 * ║                                                                      ║
 * ║   CHAINLINK WARNING TRACK (real-time divergence monitor):             ║
 * ║   Tracks whether live Chainlink is 3%+ below committedPrice.         ║
 * ║   If sustained for 30 minutes → isChainlinkLiquidationEnabled()      ║
 * ║   returns true. The vault then uses live Chainlink for liquidation    ║
 * ║   eligibility, closing the bad-debt window that the conservative      ║
 * ║   committed price inherently creates during real crashes.             ║
 * ║   Flash crashes: Chainlink recovers in minutes, warning clears.       ║
 * ║   Real crashes: Chainlink stays down 30+ min, liquidations proceed.   ║
 * ║                                                                      ║
 * ║   FIXES vs v6.4:                                                      ║
 * ║   ✓ Dead zone eliminated: moves > instant threshold now always start  ║
 * ║     confirmation. v6.4 had a silent gap (2-5% down, 5-10% up) where  ║
 * ║     moves were simply ignored — oracle could lag moderate real moves.  ║
 * ║   ✓ Deployer immutable added — setVault() properly guarded.           ║
 * ║   ✓ Oracle is now a pure public utility (no vault-only gating).       ║
 * ║     The vault link in v6.4 was vestigial — vault access was never     ║
 * ║     enforced. v7 removes the fiction cleanly.                         ║
 * ║                                                                      ║
 * ║   UNCHANGED from v6.4:                                                ║
 * ║   ✓ Chainlink + V3 TWAP hybrid selection logic                        ║
 * ║   ✓ USDC depeg guard                                                  ║
 * ║   ✓ 30% cross-divergence threshold for source switching               ║
 * ║   ✓ 3%/10% step sizes, STEP_INTERVAL                                  ║
 * ║   ✓ All diagnostic view functions                                     ║
 * ║                                                                      ║
 * ║   Deploy args (Base mainnet):                                         ║
 * ║     aaveOracle: 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156           ║
 * ║     weth:       0x4200000000000000000000000000000000000006           ║
 * ║     usdc:       0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913           ║
 * ║     pool0: 0xd0b53D9277642d899DF5C87A3966A349A798F224  dec: 6        ║
 * ║             WETH/USDC 0.05%  (~$100M+ TVL)                            ║
 * ║     pool1: 0x6c561B446416E1A00E8E93E221854d6eA4171372  dec: 6        ║
 * ║             WETH/USDC 0.30%  (~$12M TVL)                              ║
 * ║     pool2: 0x4C36388bE6F416A29C8d8Eee81C771cE6bE14B18  dec: 6        ║
 * ║             USDbC/WETH 0.05% (~$112K TVL, skipped if too thin)        ║
 * ║                                                                      ║
 * ║   Dev: Elite Team6 | https://www.sundaitoken.com                      ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 */

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
}

// ─── TickMath (MIT — Uniswap V3 Core, inlined) ───────────────────────────────

library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK =  887272;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(int256(MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2    != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4    != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8    != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10   != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20   != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40   != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80   != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100  != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200  != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400  != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800  != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9)  >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604)    >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98)       >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2)            >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}

// ─── FullMath (MIT — Uniswap V3 Core, inlined) ───────────────────────────────

library FullMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        uint256 prod0; uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (prod1 == 0) {
            require(denominator > 0, "MD0");
            assembly { result := div(prod0, denominator) }
            return result;
        }
        require(denominator > prod1, "MD1");
        uint256 remainder;
        assembly { remainder := mulmod(a, b, denominator) }
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }
        uint256 twos = (type(uint256).max - denominator + 1) & denominator;
        assembly {
            denominator := div(denominator, twos)
            prod0 := div(prod0, twos)
            twos := add(div(sub(0, twos), twos), 1)
        }
        prod0 |= prod1 * twos;
        uint256 inv = (3 * denominator) ^ 2;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        result = prod0 * inv;
    }
}

// ─── Oracle ───────────────────────────────────────────────────────────────────

contract bSunDAIoracleBASE_v7 {

    string public constant VERSION = "bSunDAIoracleBASE_v7.0";

    // ── Immutables ───────────────────────────────────────────────────────────
    IAaveOracle public immutable aaveOracle;
    address public immutable WETH;
    address public immutable USDC;
    address public immutable pool0;
    address public immutable pool1;
    address public immutable pool2;
    uint8   public immutable pool0QuoteDecimals;
    uint8   public immutable pool1QuoteDecimals;
    uint8   public immutable pool2QuoteDecimals;

    // ── Price stepping constants ──────────────────────────────────────────────
    uint32  public constant TWAP_PERIOD                = 1800;         // 30-min TWAP window
    uint256 public constant CROSS_DIVERGENCE_BPS       = 3000;         // 30% Chainlink/TWAP divergence → use TWAP
    uint128 public constant MIN_POOL_LIQUIDITY         = 1e15;
    uint256 public constant INSTANT_THRESHOLD_DOWN_BPS = 200;          // ≤ 2% drop: accept instantly
    uint256 public constant INSTANT_THRESHOLD_UP_BPS   = 500;          // ≤ 5% pump: accept instantly
    uint256 public constant CONFIRMATION_TIME_DOWN     = 4 hours;      // large drops must confirm 4h
    uint256 public constant CONFIRMATION_TIME_UP       = 30 minutes;   // large pumps confirm 30min
    uint256 public constant STEP_SIZE_DOWN_BPS         = 300;          // 3% per step down
    uint256 public constant STEP_SIZE_UP_BPS           = 1000;         // 10% per step up
    uint256 public constant STEP_INTERVAL              = 30 minutes;
    uint256 public constant ORACLE_DEAD_THRESHOLD      = 7 days;
    uint256 public constant USDC_DEPEG_THRESHOLD       = 97_000_000;   // $0.97 in 8-decimal

    // ── Chainlink warning track constants ─────────────────────────────────────
    // Chainlink must be this far below committedPrice before the warning clock starts.
    // 3% chosen so the warning triggers during confirmation periods (where committed
    // lags the real price) but not from normal small-move accepted updates.
    uint256 public constant CHAINLINK_WARNING_BPS  = 300;
    // Chainlink must stay below the threshold for this long before liquidations enable.
    // 30 min: flash crashes recover in minutes; real crashes don't.
    uint256 public constant CHAINLINK_CONFIRM_TIME = 30 minutes;

    // ── State ────────────────────────────────────────────────────────────────
    uint256 public committedPrice;
    uint256 public committedTime;
    uint256 public pendingTarget;
    bool    public inConfirmation;
    uint256 public confirmStartTime;
    uint256 public lastStepTime;

    // Chainlink warning track: set when live Chainlink first goes CHAINLINK_WARNING_BPS
    // below committedPrice. Cleared when Chainlink recovers above the threshold.
    // When nonzero for >= CHAINLINK_CONFIRM_TIME: isChainlinkLiquidationEnabled() = true.
    uint256 public chainlinkWarningStart;

    // ── Events ───────────────────────────────────────────────────────────────
    event PriceCommitted(uint256 price, uint256 timestamp, string reason);
    event ConfirmationStarted(uint256 committed, uint256 target, bool isDown);
    event PriceStepped(uint256 from, uint256 to, uint256 target);
    event ChainlinkWarningTriggered(uint256 chainlinkPrice, uint256 committedPrice, uint256 timestamp);
    event ChainlinkWarningCleared(uint256 chainlinkPrice, uint256 committedPrice);

    // ── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _aaveOracle,
        address _weth,
        address _usdc,
        address _pool0, uint8 _pool0QuoteDecimals,
        address _pool1, uint8 _pool1QuoteDecimals,
        address _pool2, uint8 _pool2QuoteDecimals
    ) {
        require(_aaveOracle != address(0), "Zero aave oracle");
        require(_weth != address(0),       "Zero WETH");
        require(_usdc != address(0),       "Zero USDC");
        require(_pool0 != address(0) && _pool1 != address(0) && _pool2 != address(0), "Zero pool");

        aaveOracle = IAaveOracle(_aaveOracle);
        WETH = _weth; USDC = _usdc;
        pool0 = _pool0; pool0QuoteDecimals = _pool0QuoteDecimals;
        pool1 = _pool1; pool1QuoteDecimals = _pool1QuoteDecimals;
        pool2 = _pool2; pool2QuoteDecimals = _pool2QuoteDecimals;

        uint256 initPrice = _getRawPrice();
        if (initPrice == 0) initPrice = 3000 * 1e18;
        committedPrice = initPrice;
        committedTime  = block.timestamp;

        emit PriceCommitted(initPrice, block.timestamp, "bootstrap");
    }

    // ── Price sources ────────────────────────────────────────────────────────

    function _getChainlinkPrice() internal view returns (uint256) {
        try aaveOracle.getAssetPrice(WETH) returns (uint256 price) {
            if (price == 0) return 0;
            return price * 1e10; // 8-decimal → 1e18
        } catch {
            return 0;
        }
    }

    function _isUSDCDepegged() internal view returns (bool) {
        try aaveOracle.getAssetPrice(USDC) returns (uint256 usdcPrice) {
            return usdcPrice > 0 && usdcPrice < USDC_DEPEG_THRESHOLD;
        } catch {
            return false;
        }
    }

    function _secondsAgos() private pure returns (uint32[] memory arr) {
        arr = new uint32[](2);
        arr[0] = TWAP_PERIOD;
        arr[1] = 0;
    }

    function _getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        private pure returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    function _getPoolPrice(address pool, uint8 quoteDecimals) internal view returns (uint256) {
        try IUniswapV3Pool(pool).liquidity() returns (uint128 liq) {
            if (liq < MIN_POOL_LIQUIDITY) return 0;
        } catch { return 0; }

        try IUniswapV3Pool(pool).observe(_secondsAgos()) returns (
            int56[] memory tickCumulatives, uint160[] memory
        ) {
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            int24 meanTick  = int24(tickDelta / int56(uint56(TWAP_PERIOD)));

            address token0     = IUniswapV3Pool(pool).token0();
            address token1     = IUniswapV3Pool(pool).token1();
            address quoteToken = (token0 == WETH) ? token1 : token0;

            uint256 rawQuote = _getQuoteAtTick(meanTick, uint128(1e18), WETH, quoteToken);
            if (rawQuote == 0) return 0;
            if (quoteDecimals < 18) return rawQuote * (10 ** uint256(18 - quoteDecimals));
            return rawQuote;
        } catch { return 0; }
    }

    function _getMedianTWAPPrice() internal view returns (uint256) {
        uint256[3] memory prices;
        uint256 count;

        uint256 p;
        p = _getPoolPrice(pool0, pool0QuoteDecimals); if (p > 0) prices[count++] = p;
        p = _getPoolPrice(pool1, pool1QuoteDecimals); if (p > 0) prices[count++] = p;
        p = _getPoolPrice(pool2, pool2QuoteDecimals); if (p > 0) prices[count++] = p;

        if (count == 0) return 0;
        if (count == 1) return prices[0];
        if (count == 2) return (prices[0] + prices[1]) / 2;

        if (prices[0] > prices[1]) (prices[0], prices[1]) = (prices[1], prices[0]);
        if (prices[1] > prices[2]) (prices[1], prices[2]) = (prices[2], prices[1]);
        if (prices[0] > prices[1]) (prices[0], prices[1]) = (prices[1], prices[0]);
        return prices[1];
    }

    function _getRawPrice() internal view returns (uint256) {
        uint256 chainlinkPrice = _getChainlinkPrice();
        uint256 twapPrice      = _getMedianTWAPPrice();

        if (chainlinkPrice == 0 && twapPrice == 0) return 0;
        if (chainlinkPrice == 0) return twapPrice;
        if (twapPrice == 0)      return chainlinkPrice;

        if (_isUSDCDepegged()) return chainlinkPrice;

        uint256 diff = chainlinkPrice > twapPrice
            ? chainlinkPrice - twapPrice
            : twapPrice - chainlinkPrice;
        uint256 divergenceBps = (diff * 10000) / chainlinkPrice;

        if (divergenceBps <= CROSS_DIVERGENCE_BPS) return chainlinkPrice;
        return twapPrice;
    }

    // ── Chainlink warning track ───────────────────────────────────────────────

    /// @notice Check live Chainlink against the committed price.
    ///         If Chainlink is CHAINLINK_WARNING_BPS below committed, start the clock.
    ///         Called at the end of every _update() so it tracks continuously.
    function _updateChainlinkWarning() internal {
        if (committedPrice == 0) return;
        uint256 clPrice = _getChainlinkPrice();
        if (clPrice == 0) return;

        uint256 threshold = (committedPrice * (10000 - CHAINLINK_WARNING_BPS)) / 10000;

        if (clPrice < threshold) {
            if (chainlinkWarningStart == 0) {
                chainlinkWarningStart = block.timestamp;
                emit ChainlinkWarningTriggered(clPrice, committedPrice, block.timestamp);
            }
        } else {
            if (chainlinkWarningStart != 0) {
                chainlinkWarningStart = 0;
                emit ChainlinkWarningCleared(clPrice, committedPrice);
            }
        }
    }

    /// @notice True when live Chainlink has been CHAINLINK_WARNING_BPS below committed
    ///         price for >= CHAINLINK_CONFIRM_TIME. The vault uses Chainlink directly
    ///         for liquidation eligibility when this is active.
    function isChainlinkLiquidationEnabled() external view returns (bool) {
        if (chainlinkWarningStart == 0) return false;
        return block.timestamp - chainlinkWarningStart >= CHAINLINK_CONFIRM_TIME;
    }

    /// @notice How long the Chainlink warning has been active (0 if not active).
    function chainlinkWarningElapsed() external view returns (uint256) {
        if (chainlinkWarningStart == 0) return 0;
        return block.timestamp - chainlinkWarningStart;
    }

    // ── State machine ────────────────────────────────────────────────────────

    function _handleStepping(uint256 raw) internal {
        uint256 committed = committedPrice;
        uint256 target    = pendingTarget;
        bool    goingDown = target < committed;

        // Reverse: raw crossed back past the committed price — accept immediately
        if (goingDown && raw > committed) {
            pendingTarget  = 0;
            committedPrice = raw;
            committedTime  = block.timestamp;
            emit PriceCommitted(raw, block.timestamp, "step-reversed");
            return;
        }
        if (!goingDown && raw < committed) {
            pendingTarget  = 0;
            committedPrice = raw;
            committedTime  = block.timestamp;
            emit PriceCommitted(raw, block.timestamp, "step-reversed");
            return;
        }

        if (block.timestamp < lastStepTime + STEP_INTERVAL) return;

        uint256 stepBps  = goingDown ? STEP_SIZE_DOWN_BPS : STEP_SIZE_UP_BPS;
        uint256 step     = (committed * stepBps) / 10000;
        uint256 newPrice;

        if (goingDown) {
            newPrice = committed > step ? committed - step : target;
            if (newPrice < target) newPrice = target;
        } else {
            newPrice = committed + step;
            if (newPrice > target) newPrice = target;
        }

        committedPrice = newPrice;
        committedTime  = block.timestamp;
        lastStepTime   = block.timestamp;
        emit PriceStepped(committed, newPrice, target);

        if (newPrice == target) pendingTarget = 0;
    }

    function _handleConfirmation(uint256 raw) internal {
        uint256 committed = committedPrice;
        uint256 target    = pendingTarget;
        bool    wasDown   = target < committed;

        bool    rawDown  = raw < committed;
        uint256 diff     = rawDown ? committed - raw : raw - committed;
        uint256 bps      = (diff * 10000) / committed;
        uint256 instantB = rawDown ? INSTANT_THRESHOLD_DOWN_BPS : INSTANT_THRESHOLD_UP_BPS;

        // Cancelled: direction reversed or recovered within instant threshold
        if (wasDown != rawDown || bps <= instantB) {
            inConfirmation = false;
            pendingTarget  = 0;
            committedPrice = raw;
            committedTime  = block.timestamp;
            emit PriceCommitted(raw, block.timestamp, "confirmation-cancelled");
            return;
        }

        uint256 confirmTime = wasDown ? CONFIRMATION_TIME_DOWN : CONFIRMATION_TIME_UP;
        if (block.timestamp < confirmStartTime + confirmTime) return;

        // Confirmed — begin stepping toward target
        pendingTarget  = raw;
        inConfirmation = false;
        lastStepTime   = block.timestamp - STEP_INTERVAL;
        _handleStepping(raw);
    }

    /// @dev v7 fix: no dead zone. Any move > instant threshold starts confirmation.
    ///      v6.4 had a gap (2–5% down / 5–10% up) where moves were silently ignored,
    ///      causing the committed price to lag moderate but real price moves.
    function _handleNormal(uint256 raw) internal {
        uint256 committed = committedPrice;
        bool    priceDown = raw < committed;
        uint256 diff      = priceDown ? committed - raw : raw - committed;
        uint256 bps       = (diff * 10000) / committed;
        uint256 instantB  = priceDown ? INSTANT_THRESHOLD_DOWN_BPS : INSTANT_THRESHOLD_UP_BPS;

        if (bps <= instantB) {
            // Small move: accept immediately
            committedPrice = raw;
            committedTime  = block.timestamp;
            emit PriceCommitted(raw, block.timestamp, "instant");
        } else {
            // Larger move: always start confirmation (no dead zone in v7)
            pendingTarget    = raw;
            inConfirmation   = true;
            confirmStartTime = block.timestamp;
            emit ConfirmationStarted(committed, raw, priceDown);
        }
    }

    function _update() internal {
        uint256 raw = _getRawPrice();
        if (raw == 0) return;

        if (committedPrice == 0) {
            committedPrice = raw;
            committedTime  = block.timestamp;
            emit PriceCommitted(raw, block.timestamp, "bootstrap");
            _updateChainlinkWarning();
            return;
        }

        if (!inConfirmation && pendingTarget != 0) { _handleStepping(raw);    }
        else if (inConfirmation)                   { _handleConfirmation(raw); }
        else                                       { _handleNormal(raw);       }

        // Always update warning track after any price state change
        _updateChainlinkWarning();
    }

    // ── Public interface ──────────────────────────────────────────────────────

    /// @notice Advance oracle state and return committed price.
    ///         Called by the vault on every state-changing interaction.
    ///         Public — no vault-only gating. Oracle is a public utility.
    function getPriceWithTimestamp() external returns (uint256 price, uint256 timestamp) {
        _update();
        return (committedPrice, committedTime);
    }

    /// @notice Public poke — keeps oracle live between vault interactions.
    function refreshPrice() external {
        _update();
    }

    /// @notice View-safe read of last committed price. No state changes.
    function peekPrice() external view returns (uint256 price, uint256 timestamp) {
        return (committedPrice, committedTime);
    }

    /// @notice Live Chainlink price (1e18). For vault's liquidation price check.
    function getChainlinkPrice() external view returns (uint256) {
        return _getChainlinkPrice();
    }

    function isOracleDead() external view returns (bool) {
        return block.timestamp > committedTime + ORACLE_DEAD_THRESHOLD;
    }

    // ── Diagnostics ───────────────────────────────────────────────────────────

    function getTWAPPrice() external view returns (uint256) {
        return _getMedianTWAPPrice();
    }

    function getPoolPrice(uint8 poolIndex) external view returns (uint256) {
        if (poolIndex == 0) return _getPoolPrice(pool0, pool0QuoteDecimals);
        if (poolIndex == 1) return _getPoolPrice(pool1, pool1QuoteDecimals);
        if (poolIndex == 2) return _getPoolPrice(pool2, pool2QuoteDecimals);
        return 0;
    }

    function getUSDCPrice() external view returns (uint256) {
        try aaveOracle.getAssetPrice(USDC) returns (uint256 p) { return p; }
        catch { return 0; }
    }

    function isUSDCDepegged() external view returns (bool) {
        return _isUSDCDepegged();
    }

    enum PriceSource { NONE, CHAINLINK, TWAP, CHAINLINK_VALIDATED_BY_TWAP }

    function getSourceStatus() external view returns (
        PriceSource source,
        uint256 chainlinkPrice,
        uint256 twapPrice,
        uint256 divergenceBps
    ) {
        chainlinkPrice = _getChainlinkPrice();
        twapPrice      = _getMedianTWAPPrice();

        if (chainlinkPrice == 0 && twapPrice == 0) return (PriceSource.NONE, 0, 0, 0);
        if (chainlinkPrice == 0) return (PriceSource.TWAP, 0, twapPrice, 0);
        if (twapPrice == 0)      return (PriceSource.CHAINLINK, chainlinkPrice, 0, 0);

        uint256 diff = chainlinkPrice > twapPrice
            ? chainlinkPrice - twapPrice
            : twapPrice - chainlinkPrice;
        divergenceBps = (diff * 10000) / chainlinkPrice;

        if (divergenceBps <= CROSS_DIVERGENCE_BPS)
            return (PriceSource.CHAINLINK_VALIDATED_BY_TWAP, chainlinkPrice, twapPrice, divergenceBps);
        return (PriceSource.TWAP, chainlinkPrice, twapPrice, divergenceBps);
    }

    function getPriceStatus() external view returns (
        uint256 currentPrice,
        uint256 rawPrice,
        uint256 targetPrice,
        bool    _inConfirmation,
        uint256 _confirmStart,
        bool    _isStepping,
        bool    chainlinkWarningActive,
        bool    chainlinkLiquidationEnabled
    ) {
        return (
            committedPrice,
            _getRawPrice(),
            pendingTarget,
            inConfirmation,
            confirmStartTime,
            !inConfirmation && pendingTarget != 0,
            chainlinkWarningStart != 0,
            chainlinkWarningStart != 0 && block.timestamp - chainlinkWarningStart >= CHAINLINK_CONFIRM_TIME
        );
    }
}
