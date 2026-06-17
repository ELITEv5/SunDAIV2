// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * ╔════════════════════════════════════════════════════════════╗
 * ║            bSunDAI Autonomous Stable Asset — v7            ║
 * ║                 Base Chain Edition                         ║
 * ║                                                            ║
 * ║   Trust-minimized vault-linked ERC20 with EIP-2612 permit  ║
 * ║                                                            ║
 * ║   UNCHANGED from v1.0.1 — token logic was correct:         ║
 * ║   ✓ Vault burns from its OWN balance (not from users)      ║
 * ║   ✓ burnFrom() uses ERC20 allowance for permit flows       ║
 * ║   ✓ ERC20Permit for single-tx agent operations             ║
 * ║   ✓ One-time deployer-controlled vault linkage             ║
 * ║   ✓ No admin keys after setVault()                         ║
 * ║                                                            ║
 * ║   INTEGRATION NOTE:                                        ║
 * ║   Vault must transferFrom user → vault, then call burn().  ║
 * ║   The vault cannot burn tokens it does not hold.           ║
 * ║                                                            ║
 * ║   Dev: Elite Team6 | https://www.sundaitoken.com           ║
 * ╚════════════════════════════════════════════════════════════╝
 */

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract bSunDAI is ERC20Permit, ReentrancyGuard {
    address public immutable deployer;
    address public vault;
    bool    public vaultSet;

    string public constant PROTOCOL_VERSION = "bSunDAI_v7";
    string public constant PROTOCOL_DEV     = "Elite Team6";

    modifier onlyVault() {
        require(msg.sender == vault && vault != address(0), "Not authorized");
        _;
    }

    event VaultLinked(address indexed vault, address indexed by);
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);

    constructor()
        ERC20("SunDAI Autonomous Stable Asset", "bSUNDAI")
        ERC20Permit("SunDAI Autonomous Stable Asset")
    {
        deployer = msg.sender;
    }

    /// @notice One-time vault link. Only deployer. Immutable after.
    function setVault(address _vault) external nonReentrant {
        require(!vaultSet,              "Vault already set");
        require(msg.sender == deployer, "Only deployer");
        require(_vault != address(0),   "Invalid vault");
        vault    = _vault;
        vaultSet = true;
        emit VaultLinked(_vault, msg.sender);
    }

    function mint(address to, uint256 amount) external onlyVault nonReentrant {
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /// @notice Burn tokens from vault's own balance.
    ///         Vault must have pulled tokens via transferFrom first.
    function burn(uint256 amount) external onlyVault nonReentrant {
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }

    /// @notice Allowance-based burn. User approves vault (or uses permit), vault burns.
    function burnFrom(address from, uint256 amount) external onlyVault nonReentrant {
        uint256 currentAllowance = allowance(from, msg.sender);
        require(currentAllowance >= amount, "Insufficient allowance");
        _approve(from, msg.sender, currentAllowance - amount);
        _burn(from, amount);
        emit Burned(from, amount);
    }

    function decimals() public pure override returns (uint8) { return 18; }

    function getVersion() external pure returns (string memory) {
        return "bSunDAI v7 | Base Autonomous Edition | Elite Team6";
    }
}
