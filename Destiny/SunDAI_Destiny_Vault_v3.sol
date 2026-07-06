// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║           D E S T I N Y   V A U L T   B L A C K H O L E          ║
 * ║                     v2 — MEV-Safe Ignition                       ║
 * ╠══════════════════════════════════════════════════════════════════╣
 * ║  Ignition is split into two separate phases:                     ║
 * ║                                                                  ║
 * ║  Phase 1 — ignite()                                              ║
 * ║    Sets ignited=true. No swap. Cannot fail. Cannot brick.        ║
 * ║                                                                  ║
 * ║  Phase 2 — executeConversion(minPlsOut)                          ║
 * ║    Performs LP removal + SunDAI→PLS swap with slippage guard.    ║
 * ║    Retryable — a revert here bricks nothing. Submit via          ║
 * ║    private RPC for best execution. Call again with adjusted      ║
 * ║    minPlsOut if market conditions change.                        ║
 * ║                                                                  ║
 * ║  Sequence after Phase 2:                                         ║
 * ║    supernova() → rebirth() → claim()                             ║
 * ╚══════════════════════════════════════════════════════════════════╝
 *
 * @custom:changes-from-v2
 * - Fixed ORACLE_ADDR. v2 hardcoded 0xDA5591A1DE3934B28cB1DE3Ea828606be6473236,
 *   read from an empty, unused Destiny Vault deployment (0x6F0F93d2...) that
 *   was mistaken for the real one. The real, actually-staked-into deploy-1
 *   (0x6262b68fc709239ABEb6a6eD5e32bdf0BE8DB543) uses a DIFFERENT SunDial
 *   Oracle: 0x9a3442Ea79BE914d2bDACbc9550A30DD1f0747a4. Both addresses are
 *   real, functioning oracle contracts (both respond to getPrice()), which
 *   is why this didn't surface as a revert — they just return different
 *   prices. v2 (0xEfF88B68309870cCcC3B84Ae3A2659B5E5521C66) is immutable and
 *   was checking the $1 ignition threshold against the wrong price feed;
 *   it is abandoned in favor of this contract. Every other constant
 *   (sundai/wpls/router/pairV1) was independently re-verified fresh against
 *   the real deploy-1 before writing this file and is unchanged from v2.
 *
 * @custom:changes-from-deploy-1
 * - Reward path repointed at pSunDAI V9: the token that gets minted at rebirth
 *   and claimed by stakers is now pSunDAI V9, minted through the V9 vault.
 * - Constructor simplified to a single argument (the pSunDAI token address).
 *   The vault address is no longer a separate input — it is read on-chain via
 *   IPSunDAI(_psundai).vault(), so the token and the vault that mints it can
 *   never be passed in mismatched. sundai/wpls/router/pairV1/oracle are
 *   unchanged from the live deploy-1 values and are now hardcoded constants
 *   rather than constructor arguments, since none of them are pSunDAI-version
 *   dependent and hardcoding removes any deploy-time argument-order risk.
 * - No other logic changes. Staking, ignite/executeConversion, supernova,
 *   rebirth, claim, and emergency exit are byte-identical to deploy-1.
 * - Deployed with zero prior stakers (deploy-1 had totalWeight()==0, ignited
 *   ==false at time of redeploy) — this is a fresh instance, not a migration.
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

interface IPSunDAIVault {
    function depositPLS() external payable;
    function mint(uint256 amount) external;
    function maxMint(address user) external view returns (uint256);
}

interface IPSunDAI is IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function vault() external view returns (address);
}

interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface ISunDialOracle {
    function getPrice() external view returns (uint256 price);
}

contract DestinyVaultBlackHole_v3 is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Hardcoded, version-independent addresses (unchanged from deploy-1) ──

    address private constant SUNDAI_ADDR  = 0x41C6b24019Bd67CC58fe7bb059D532C12356712B;
    address private constant WPLS_ADDR    = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address private constant ROUTER_ADDR  = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address private constant PAIR_V1_ADDR = 0xc01e2eDAe9E65950bb5783A6B01DC429Cf3F0eE2;
    address private constant ORACLE_ADDR  = 0x9a3442Ea79BE914d2bDACbc9550A30DD1f0747a4;

    // ── Immutables ────────────────────────────────────────────────────────────

    IERC20              public immutable sundai;
    IPSunDAI            public immutable psundaiToken;
    IERC20              public immutable wpls;
    IPSunDAIVault       public immutable vault;
    IUniswapV2Router02  public immutable router;
    IUniswapV2Pair      public immutable pairV1;
    ISunDialOracle      public immutable oracle;

    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 public constant LP_MULTIPLIER_BPS = 15000; // 1.5× weight for LP stakers
    uint256 public constant SAFETY_BPS        = 9000;  // mint at 90% of maxMint

    // ── State ─────────────────────────────────────────────────────────────────

    bool    public ignited;             // Phase 1 complete — vault locked forever
    bool    public conversionComplete;  // Phase 2 complete — PLS in vault
    bool    public supernovaTriggered;
    bool    public rebirthTriggered;

    uint256 public totalWeight;
    uint256 public totalPayout;

    uint256 public threshold = 1e18;   // $1.00 in oracle units
    bool    public thresholdLocked;

    // ── Staking ───────────────────────────────────────────────────────────────

    struct Stake {
        uint256 sundaiAmt;
        uint256 plpAmt;
        uint256 weight;
        bool    claimed;
    }

    mapping(address => Stake) public stakes;

    // ── Events ────────────────────────────────────────────────────────────────

    event Staked(address indexed user, uint256 sundaiAmt, uint256 plpAmt, uint256 weight);
    event Withdrawn(address indexed user, uint256 sundaiAmt, uint256 plpAmt);
    event Ignited();                                      // Phase 1: vault locked, no swap
    event ConversionComplete(uint256 plsRecovered);       // Phase 2: all assets → PLS
    event Supernova(uint256 plsDeposited);
    event Rebirth(uint256 minted);
    event Claimed(address indexed user, uint256 amount);
    event ThresholdUpdated(uint256 newThreshold);
    event ThresholdLocked();

    // ── Emergency exit ────────────────────────────────────────────────────────

    bool    public emergencyExitTriggered;
    uint256 public snapshotPlsBal;

    event EmergencyExitEnabled(uint256 totalPlsAvailable);
    event EmergencyClaim(address indexed user, uint256 amountSundai, uint256 amountPlp, uint256 amountPls);

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param _psundai The pSunDAI token to mint and distribute (V9). The vault
    ///                 that mints it is read on-chain via _psundai.vault() —
    ///                 never passed in separately, so it cannot be mismatched.
    constructor(address _psundai) Ownable(msg.sender) {
        require(_psundai != address(0), "zero pSunDAI");
        psundaiToken = IPSunDAI(_psundai);

        address _vault = psundaiToken.vault();
        require(_vault != address(0), "vault not set on token");
        vault = IPSunDAIVault(_vault);

        sundai  = IERC20(SUNDAI_ADDR);
        wpls    = IERC20(WPLS_ADDR);
        router  = IUniswapV2Router02(ROUTER_ADDR);
        pairV1  = IUniswapV2Pair(PAIR_V1_ADDR);
        oracle  = ISunDialOracle(ORACLE_ADDR);
    }

    // ── Threshold control ─────────────────────────────────────────────────────

    function setThreshold(uint256 newThreshold) external onlyOwner {
        require(!thresholdLocked, "Threshold locked");
        threshold = newThreshold;
        emit ThresholdUpdated(newThreshold);
    }

    function lockThreshold() external onlyOwner {
        require(!thresholdLocked, "Already locked");
        thresholdLocked = true;
        emit ThresholdLocked();
    }

    function isLocked() external view returns (bool) {
        return (oracle.getPrice() >= threshold || ignited);
    }

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier vaultUnlocked() {
        require(oracle.getPrice() < threshold && !ignited, "Vault locked");
        _;
    }

    // ── Staking ───────────────────────────────────────────────────────────────

    function stake(uint256 sundaiAmt, uint256 plpAmt) external nonReentrant vaultUnlocked {
        require(sundaiAmt > 0 || plpAmt > 0, "Zero stake");

        Stake storage s = stakes[msg.sender];
        uint256 newWeight;

        if (sundaiAmt > 0) {
            sundai.safeTransferFrom(msg.sender, address(this), sundaiAmt);
            s.sundaiAmt += sundaiAmt;
            newWeight   += sundaiAmt;
        }

        if (plpAmt > 0) {
            IERC20(address(pairV1)).safeTransferFrom(msg.sender, address(this), plpAmt);
            s.plpAmt  += plpAmt;
            newWeight += (plpAmt * LP_MULTIPLIER_BPS) / 10000;
        }

        s.weight    += newWeight;
        totalWeight += newWeight;

        emit Staked(msg.sender, sundaiAmt, plpAmt, newWeight);
    }

    function withdraw(uint256 sundaiAmt, uint256 plpAmt) external nonReentrant vaultUnlocked {
        require(sundaiAmt > 0 || plpAmt > 0, "Nothing to withdraw");

        Stake storage s = stakes[msg.sender];
        require(s.weight > 0, "Nothing staked");
        require(s.sundaiAmt >= sundaiAmt, "Not enough SunDAI staked");
        require(s.plpAmt    >= plpAmt,    "Not enough LP staked");

        uint256 weightRemoved;

        if (sundaiAmt > 0) {
            s.sundaiAmt  -= sundaiAmt;
            weightRemoved += sundaiAmt;
            sundai.safeTransfer(msg.sender, sundaiAmt);
        }

        if (plpAmt > 0) {
            s.plpAmt     -= plpAmt;
            weightRemoved += (plpAmt * LP_MULTIPLIER_BPS) / 10000;
            IERC20(address(pairV1)).safeTransfer(msg.sender, plpAmt);
        }

        s.weight    -= weightRemoved;
        totalWeight -= weightRemoved;

        emit Withdrawn(msg.sender, sundaiAmt, plpAmt);
    }

    // ── Phase 1: Ignite ───────────────────────────────────────────────────────

    /**
     * @notice Lock the vault. Sets ignited=true. No swaps — cannot fail or brick.
     *         Call executeConversion() next to perform the actual asset conversion.
     */
    function ignite() external nonReentrant {
        require(!ignited, "Already ignited");
        require(oracle.getPrice() >= threshold, "Not at threshold yet");
        require(totalWeight > 0, "Nothing staked");

        ignited = true;
        emit Ignited();
    }

    // ── Phase 2: Execute conversion ───────────────────────────────────────────

    /**
     * @notice Convert all staked SunDAI and LP tokens into PLS.
     *         Callable by anyone after ignite(). Safe to retry — a revert here
     *         bricks nothing, just call again with an adjusted minPlsOut.
     *
     *         For best execution: submit via a private RPC to avoid MEV sandwiching.
     *
     * @param minPlsOut  Minimum PLS the vault must hold after conversion.
     *                   Compute off-chain: simulate the swap, then apply your
     *                   desired slippage tolerance (e.g. expectedPLS * 95 / 100).
     *                   If the bot-adjusted output is below this, the tx reverts
     *                   and nothing is bricked — retry at a better moment.
     */
    function executeConversion(uint256 minPlsOut) external nonReentrant {
        require(ignited,            "Not ignited");
        require(!conversionComplete,"Already converted");

        uint256 sundaiBal = sundai.balanceOf(address(this));
        uint256 plpBal    = IERC20(address(pairV1)).balanceOf(address(this));
        require(sundaiBal > 0 || plpBal > 0, "Empty vault");

        // Step 1: Remove LP → receive SunDAI + WPLS, unwrap WPLS → PLS
        if (plpBal > 0) {
            IERC20(address(pairV1)).approve(address(router), 0);
            IERC20(address(pairV1)).approve(address(router), plpBal);

            (uint256 amtSundai, uint256 amtWPLS) = router.removeLiquidity(
                address(sundai),
                address(wpls),
                plpBal,
                1,
                1,
                address(this),
                block.timestamp + 600
            );

            sundaiBal += amtSundai;

            if (amtWPLS > 0) {
                IWPLS(address(wpls)).withdraw(amtWPLS);
            }
        }

        // Step 2: Swap all SunDAI → WPLS → unwrap to PLS
        if (sundaiBal > 0) {
            sundai.approve(address(router), 0);
            sundai.approve(address(router), sundaiBal);

            address[] memory path = new address[](2);
            path[0] = address(sundai);
            path[1] = address(wpls);

            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                sundaiBal,
                1,
                path,
                address(this),
                block.timestamp + 600
            );

            uint256 wplsBal = wpls.balanceOf(address(this));
            if (wplsBal > 0) {
                IWPLS(address(wpls)).withdraw(wplsBal);
            }
        }

        // Step 3: Slippage guard — covers both LP removal and swap in aggregate.
        // A revert here is completely safe: ignited=true persists, retry with
        // a lower minPlsOut or wait for a calmer block.
        uint256 plsBal = address(this).balance;
        require(plsBal >= minPlsOut, "Slippage: insufficient PLS out");

        conversionComplete = true;
        emit ConversionComplete(plsBal);
    }

    // ── Supernova ─────────────────────────────────────────────────────────────

    /// @notice Deposit all PLS into the pSunDAI vault as collateral.
    function supernova() external nonReentrant {
        require(ignited && conversionComplete, "Conversion not complete");
        require(!supernovaTriggered, "Already triggered");

        uint256 plsBal = address(this).balance;
        require(plsBal > 0, "No PLS");

        vault.depositPLS{value: plsBal}();
        supernovaTriggered = true;

        emit Supernova(plsBal);
    }

    // ── Rebirth ───────────────────────────────────────────────────────────────

    /// @notice Mint pSunDAI at 90% of maxMint from the deposited collateral.
    function rebirth() external nonReentrant {
        require(ignited && supernovaTriggered, "Not ready");
        require(!rebirthTriggered, "Already rebirthed");

        uint256 maxMintable = vault.maxMint(address(this));
        require(maxMintable > 0, "Vault says 0 mintable");

        uint256 safeMint = (maxMintable * SAFETY_BPS) / 10000;
        require(safeMint > 0, "Zero mint");

        uint256 preBal = psundaiToken.balanceOf(address(this));
        vault.mint(safeMint);
        uint256 minted = psundaiToken.balanceOf(address(this)) - preBal;
        require(minted > 0, "No pSunDAI minted");

        totalPayout      = minted;
        rebirthTriggered = true;

        emit Rebirth(minted);
    }

    // ── Claim ─────────────────────────────────────────────────────────────────

    /// @notice Claim proportional pSunDAI share after rebirth.
    function claim() external nonReentrant {
        require(rebirthTriggered, "Not finished");
        require(totalWeight > 0,  "No total weight");

        Stake storage s = stakes[msg.sender];
        require(!s.claimed && s.weight > 0, "Already claimed or none");

        uint256 share = (totalPayout * s.weight) / totalWeight;
        require(share > 0, "Zero payout");

        s.claimed = true;
        IERC20(address(psundaiToken)).safeTransfer(msg.sender, share);

        emit Claimed(msg.sender, share);
    }

    // ── View helpers ──────────────────────────────────────────────────────────

    /**
     * @notice Simulate the conversion at current pool state.
     *         Call this off-chain before executeConversion() to determine
     *         a sensible minPlsOut. Apply your desired slippage tolerance:
     *         e.g. minPlsOut = simulateConversion() * 93 / 100  (7% buffer)
     *
     * @return expectedPls  Estimated PLS the vault would receive right now.
     *                      Not a guarantee — pool state may change between
     *                      blocks — but gives a reliable baseline for minPlsOut.
     */
    function simulateConversion() external view returns (uint256 expectedPls) {
        uint256 sundaiBal = sundai.balanceOf(address(this));
        uint256 plpBal    = IERC20(address(pairV1)).balanceOf(address(this));

        if (sundaiBal == 0 && plpBal == 0) return 0;

        // Estimate SunDAI + WPLS from LP removal
        uint256 totalSundai = sundaiBal;
        uint256 wplsFromLp  = 0;

        if (plpBal > 0) {
            uint256 totalSupply = pairV1.totalSupply();
            if (totalSupply > 0) {
                (uint112 r0, uint112 r1,) = pairV1.getReserves();
                address token0 = pairV1.token0();

                (uint256 reserveSundai, uint256 reserveWpls) = token0 == address(sundai)
                    ? (uint256(r0), uint256(r1))
                    : (uint256(r1), uint256(r0));

                totalSundai += (reserveSundai * plpBal) / totalSupply;
                wplsFromLp   = (reserveWpls   * plpBal) / totalSupply;
            }
        }

        // Estimate WPLS from swapping all SunDAI (constant-product AMM, 0.3% fee)
        if (totalSundai > 0) {
            (uint112 r0, uint112 r1,) = pairV1.getReserves();
            address token0 = pairV1.token0();

            (uint256 reserveSundai, uint256 reserveWpls) = token0 == address(sundai)
                ? (uint256(r0), uint256(r1))
                : (uint256(r1), uint256(r0));

            uint256 amtInWithFee = totalSundai * 997;
            uint256 wplsFromSwap = (amtInWithFee * reserveWpls)
                                 / (reserveSundai * 1000 + amtInWithFee);
            wplsFromLp += wplsFromSwap;
        }

        // WPLS → PLS is 1:1 on unwrap
        expectedPls = wplsFromLp + address(this).balance;
    }

    // ── Emergency exit ────────────────────────────────────────────────────────

    function enableEmergencyExit() external onlyOwner nonReentrant {
        require(!supernovaTriggered,     "Supernova already moved funds");
        require(!emergencyExitTriggered, "Already triggered");
        require(oracle.getPrice() >= threshold, "Vault not locked by threshold");

        if (conversionComplete) {
            snapshotPlsBal = address(this).balance;
            require(snapshotPlsBal > 0, "No PLS to recover");
        }

        emergencyExitTriggered = true;
        emit EmergencyExitEnabled(snapshotPlsBal);
    }

    function claimEmergency() external nonReentrant {
        require(emergencyExitTriggered, "Exit not enabled");

        Stake storage s = stakes[msg.sender];
        require(!s.claimed && s.weight > 0, "Already claimed or none");

        if (!conversionComplete) {
            // Pre-conversion: return original staked assets
            uint256 sundaiAmt = s.sundaiAmt;
            uint256 plpAmt    = s.plpAmt;

            s.claimed   = true;
            s.sundaiAmt = 0;
            s.plpAmt    = 0;

            if (sundaiAmt > 0) sundai.safeTransfer(msg.sender, sundaiAmt);
            if (plpAmt    > 0) IERC20(address(pairV1)).safeTransfer(msg.sender, plpAmt);

            emit EmergencyClaim(msg.sender, sundaiAmt, plpAmt, 0);
        } else {
            // Post-conversion, pre-supernova: return proportional PLS
            uint256 share = (snapshotPlsBal * s.weight) / totalWeight;
            require(share > 0, "Zero payout");

            s.claimed = true;
            (bool ok, ) = msg.sender.call{value: share}("");
            require(ok, "PLS transfer failed");

            emit EmergencyClaim(msg.sender, 0, 0, share);
        }
    }

    receive() external payable {}
}
