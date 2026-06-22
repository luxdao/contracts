// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title AICoin
 * @author Hanzo AI Inc / Zoo Labs Foundation
 * @notice The native coin (\textsc{ai}) of a Thinking-Chain L1/L2/L3, with
 * Bitcoin-shaped issuance: a capped, halving fair-launch subsidy mined entirely
 * by useful cognition, after which the network is funded by fees alone. This is
 * the on-chain encoding of the core paper's Tokenomics.
 *
 * @dev Issuance model (one and only one way to mint new supply):
 *
 *   - A hard cap {MAX_SUBSIDY} = 1,000,000,000 \textsc{ai} is the total that can
 *     ever be minted by subsidy. There is no pre-mine: supply starts at zero and
 *     every coin is minted to a cognitive node for an accepted answer.
 *   - The subsidy halves every {HALVING_PERIOD} (four years). Within an epoch the
 *     allowance vests linearly; the slope halves each epoch. The cumulative
 *     allowance at time t is
 *         allowed(t) = MAX*(1 - 2^{-k}) + f * MAX*2^{-(k+1)}
 *     where k = epoch and f in [0,1) is fractional progress through the epoch.
 *     allowed(GENESIS)=0, allowed is continuous and strictly increasing, and
 *     allowed(t) -> MAX as t -> infinity. The geometric sum of per-epoch
 *     emissions equals exactly MAX (sum_{k>=0} MAX*2^{-(k+1)} = MAX).
 *   - {mintSubsidy} (only the minter — the settlement contract) mints up to
 *     {emissionAllowance}() at the current time. Cumulative minted can never
 *     exceed allowed(t) <= MAX, so the cap is structurally enforced.
 *
 * Deflation: this contract is {ERC20Burnable}. The protocol burns a governed
 * fraction of every settled fee (EIP-1559-style). Net supply change per block is
 * subsidy(t) - burn(t); since subsidy -> 0 while fee burn persists under use, net
 * supply turns deflationary once the chain is in steady use (core paper, Thm.
 * "Fair-launch issuance: bounded, then deflationary").
 *
 * Orthogonal by design: AICoin is the pure value layer. It knows nothing about
 * tasks, receipts, or governance — it only enforces the issuance schedule and
 * exposes a single {minter} seam that the settlement path mints through.
 */
contract AICoin is ERC20, ERC20Burnable {
    /// @notice Total coin ever mintable by subsidy: one billion, fair-mined.
    uint256 public constant MAX_SUBSIDY = 1_000_000_000 ether; // 1e9 * 1e18

    /// @notice The halving period: the emission slope halves every four years.
    uint256 public constant HALVING_PERIOD = 4 * 365 days; // 1460 days

    /// @notice Deploy timestamp; the emission curve is measured from here.
    uint256 public immutable GENESIS;

    /// @notice Cumulative coin minted by subsidy so far (monotone, <= MAX_SUBSIDY).
    uint256 public mintedSubsidy;

    /// @notice The settlement contract permitted to mint the subsidy.
    address public minter;

    /// @notice The governance authority that may rotate the minter.
    address public admin;

    event SubsidyMinted(address indexed to, uint256 amount, uint256 epoch, uint256 mintedTotal);
    event MinterSet(address indexed from, address indexed to);
    event AdminTransferred(address indexed from, address indexed to);

    error NotMinter();
    error NotAdmin();
    error ZeroAddress();
    error ExceedsEmissionAllowance(uint256 requested, uint256 allowed);

    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        address minter_
    ) ERC20(name_, symbol_) {
        admin = admin_ == address(0) ? msg.sender : admin_;
        minter = minter_; // may be zero at deploy; set once the settlement is live
        GENESIS = block.timestamp;
    }

    // ---- issuance --------------------------------------------------------------

    /// @notice The current halving epoch (0 for the first four years).
    function epoch() public view returns (uint256) {
        return (block.timestamp - GENESIS) / HALVING_PERIOD;
    }

    /// @notice Total coin emittable during the current epoch (E_k = MAX / 2^{k+1}).
    function epochSubsidy() external view returns (uint256) {
        uint256 k = epoch();
        if (k >= 128) return 0;
        return MAX_SUBSIDY >> (k + 1);
    }

    /// @notice Cumulative subsidy the schedule has unlocked by now: allowed(t).
    function cumulativeAllowance() public view returns (uint256) {
        uint256 elapsed = block.timestamp - GENESIS;
        uint256 k = elapsed / HALVING_PERIOD;
        if (k >= 128) return MAX_SUBSIDY; // subsidy effectively complete
        uint256 vestedEpochs = MAX_SUBSIDY - (MAX_SUBSIDY >> k); // MAX*(1 - 2^{-k})
        uint256 epochEmission = MAX_SUBSIDY >> (k + 1); // E_k = MAX*2^{-(k+1)}
        uint256 inEpoch = elapsed % HALVING_PERIOD; // [0, HALVING_PERIOD)
        uint256 vestedThisEpoch = (epochEmission * inEpoch) / HALVING_PERIOD;
        return vestedEpochs + vestedThisEpoch;
    }

    /// @notice Subsidy claimable right now: allowed(t) - already minted.
    function emissionAllowance() public view returns (uint256) {
        uint256 allowed = cumulativeAllowance();
        return allowed > mintedSubsidy ? allowed - mintedSubsidy : 0;
    }

    /// @notice Coin still mintable by subsidy over all future time.
    function remainingSubsidy() external view returns (uint256) {
        return MAX_SUBSIDY - mintedSubsidy;
    }

    /// @notice Mint the fair-launch subsidy to a cognitive node for accepted work.
    /// Only the settlement (minter) may call; bounded by the halving schedule.
    function mintSubsidy(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        if (to == address(0)) revert ZeroAddress();
        uint256 allowance_ = emissionAllowance();
        if (amount > allowance_) revert ExceedsEmissionAllowance(amount, allowance_);
        mintedSubsidy += amount;
        _mint(to, amount);
        emit SubsidyMinted(to, amount, epoch(), mintedSubsidy);
    }

    // ---- admin (governance rotates the settlement seam) ------------------------

    function setMinter(address minter_) external {
        if (msg.sender != admin) revert NotAdmin();
        emit MinterSet(minter, minter_);
        minter = minter_;
    }

    function transferAdmin(address admin_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (admin_ == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, admin_);
        admin = admin_;
    }
}
