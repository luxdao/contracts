// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IEscrow
 * @notice Conservation-safe multi-asset value vault for a single controller contract
 * @dev Escrow is the single canonical value-custody half of the work-market. It custodies
 * native coin and ERC-20 funds with conservation / single-spend / controller-authorization
 * guarantees, and it ALSO custodies ERC-721 and ERC-1155 rewards. EIP-7201 namespaced and
 * deployed as a UUPS proxy.
 *
 * One deposit holds exactly one asset, tagged by {AssetKind}:
 *  - Native   : token == address(0), tokenId == 0, `amount` is the wei value.
 *  - ERC20    : token is the ERC-20, tokenId == 0, `amount` is the token amount.
 *  - ERC721   : token is the ERC-721, `tokenId` is the token, `amount` == 1 (a single,
 *               indivisible NFT).
 *  - ERC1155  : token is the ERC-1155, `tokenId` is the id, `amount` is the quantity.
 *
 * Invariants the escrow guarantees independent of any controller bug:
 * - Conservation: every unit released or refunded was first deposited; the escrow never
 *   mints or burns. A deposit's `remaining` is debited BEFORE any outbound transfer
 *   (checks-effects-interactions) and every mover is reentrancy-guarded, so a deposit
 *   can never pay out more than it holds — this covers the ERC-721/1155 `safeTransfer`
 *   callback into the recipient, which cannot re-enter to double-release.
 * - Exact custody: an NFT enters the ledger ONLY through a controller-driven deposit()
 *   pull; unsolicited direct ERC-721/1155 transfers are REJECTED (UnsolicitedTransfer),
 *   so the escrow holds exactly the NFTs its ledger tracks (no stranded/orphan tokens).
 * - ERC-721 indivisibility: an ERC-721 deposit's amount is fixed at 1 and it can only be
 *   released/refunded WHOLE — a fractional NFT payout is impossible.
 * - Fee-on-transfer / deflationary ERC-20s are rejected at deposit (received != nominal),
 *   preserving exact nominal accounting. Rebasing tokens are NOT caught (their balance drifts
 *   after a conformant deposit) and are unsupported.
 */
interface IEscrow {
    // --- Enums ---

    /**
     * @notice The asset class a deposit holds
     * @dev Native and ERC20 are the fungible classes; ERC721 and ERC1155 are the NFT classes.
     */
    enum AssetKind {
        Native, //   0: chain native coin (token == address(0))
        ERC20, //    1: fungible ERC-20
        ERC721, //   2: single indivisible NFT (amount == 1)
        ERC1155 //   3: semi-fungible token (amount == quantity)
    }

    // --- Errors ---

    /** @notice Thrown when a non-controller address attempts to move funds */
    error OnlyController();

    /** @notice Thrown when initializing with a zero controller address */
    error InvalidController();

    /** @notice Thrown when a deposit id is reused */
    error DepositExists(bytes32 depositId);

    /** @notice Thrown when referencing a deposit that was never created */
    error UnknownDeposit(bytes32 depositId);

    /** @notice Thrown when a native deposit's msg.value does not equal the amount */
    error NativeValueMismatch(uint256 expected, uint256 provided);

    /** @notice Thrown when native value is sent alongside a non-native deposit (must be 0) */
    error UnexpectedNativeValue();

    /** @notice Thrown when depositing or moving a zero amount */
    error ZeroAmount();

    /** @notice Thrown when releasing/refunding more than a deposit's remaining balance */
    error InsufficientDeposit(bytes32 depositId, uint256 remaining, uint256 requested);

    /**
     * @notice Thrown when the ERC-20 balance actually received != the nominal amount
     * @dev Rejects fee-on-transfer / deflationary tokens at deposit so the controller's nominal
     * accounting can never strand funds (rebasing tokens are not caught and are unsupported).
     */
    error DepositAmountMismatch(uint256 expected, uint256 received);

    /** @notice Thrown when a recipient address is zero */
    error InvalidRecipient();

    /** @notice Thrown when withdrawing / reassigning a credit that does not exist */
    error NoCredit();

    /** @notice Thrown when reassigning more credit than the source holds (bounds recovery to the reward) */
    error InsufficientCredit(uint256 available, uint256 requested);

    /** @notice Thrown when a credit withdrawal's retried transfer still fails (credit is kept) */
    error WithdrawFailed();

    /** @notice Thrown when an ERC-721 deposit is created with amount != 1 (an NFT is one unit) */
    error BadERC721Amount(uint256 amount);

    /**
     * @notice Thrown when an ERC-721 release/refund does not move the whole token
     * @dev An ERC-721 is indivisible: the moved amount must equal the deposit's remaining (1).
     */
    error PartialERC721Move(bytes32 depositId, uint256 requested);

    /**
     * @notice Thrown when the escrow receives an ERC-721/1155 outside a deposit() pull
     * @dev The escrow only accepts NFTs it is actively pulling in via deposit(); a direct,
     * unsolicited transfer is rejected so the escrow holds exactly its ledgered NFTs.
     */
    error UnsolicitedTransfer();

    // --- Structs ---

    /**
     * @notice A single escrowed deposit of one asset
     * @param kind The asset class (native/erc20/erc721/erc1155)
     * @param token The asset contract; address(0) for native
     * @param funder The address credited as the source (refunds route here by default)
     * @param tokenId The ERC-721/1155 token id; 0 for native/erc20
     * @param amount The original deposited amount (erc721: 1; erc1155: quantity; else value)
     * @param remaining The amount not yet released or refunded
     */
    struct Deposit {
        AssetKind kind;
        address token;
        address funder;
        uint256 tokenId;
        uint256 amount;
        uint256 remaining;
    }

    // --- Events ---

    /**
     * @notice Emitted when an asset is deposited into the escrow
     * @param depositId The controller-chosen identifier for this deposit
     * @param kind The asset class
     * @param token The asset contract; address(0) for native
     * @param funder The source of the funds
     * @param tokenId The ERC-721/1155 id (0 for native/erc20)
     * @param amount The deposited amount
     */
    event Deposited(
        bytes32 indexed depositId,
        AssetKind kind,
        address indexed token,
        address indexed funder,
        uint256 tokenId,
        uint256 amount
    );

    /**
     * @notice Emitted when part or all of a deposit is released to a recipient (payout)
     * @param depositId The deposit being drawn from
     * @param to The recipient of the released asset
     * @param amount The released amount
     */
    event Released(bytes32 indexed depositId, address indexed to, uint256 amount);

    /**
     * @notice Emitted when part or all of a deposit is refunded
     * @param depositId The deposit being drawn from
     * @param to The recipient of the refund
     * @param amount The refunded amount
     */
    event Refunded(bytes32 indexed depositId, address indexed to, uint256 amount);

    /**
     * @notice Emitted when an outward transfer failed and the amount was credited instead (H1)
     * @param depositId The deposit being drawn from
     * @param to The recipient owed the credit
     * @param kind The asset class
     * @param token The asset contract (address(0) for native)
     * @param tokenId The ERC-721/1155 id
     * @param amount The credited amount (claimable via withdraw)
     */
    event PayoutCredited(
        bytes32 indexed depositId,
        address indexed to,
        AssetKind kind,
        address indexed token,
        uint256 tokenId,
        uint256 amount
    );

    /**
     * @notice Emitted when a recipient withdraws a previously-credited (failed) payout
     * @param to The recipient
     * @param kind The asset class
     * @param token The asset contract
     * @param tokenId The ERC-721/1155 id
     * @param amount The withdrawn amount
     */
    event CreditWithdrawn(address indexed to, AssetKind kind, address indexed token, uint256 tokenId, uint256 amount);

    /**
     * @notice Emitted when the controller reassigns a credit between recipients (funder-recovery)
     * @param from The prior owner of the credit
     * @param to The new owner of the credit
     * @param kind The asset class
     * @param token The asset contract
     * @param tokenId The ERC-721/1155 id
     * @param amount The reassigned amount
     */
    event CreditReassigned(
        address indexed from,
        address indexed to,
        AssetKind kind,
        address indexed token,
        uint256 tokenId,
        uint256 amount
    );

    // --- View Functions ---

    /**
     * @notice The only address permitted to move funds (the policy contract)
     * @return controller The controller address
     */
    function controller() external view returns (address controller);

    /**
     * @notice Returns the full record of a deposit
     * @param depositId The deposit identifier
     * @return kind The asset class
     * @return token The asset contract (address(0) for native)
     * @return funder The funding source
     * @return tokenId The ERC-721/1155 id (0 for native/erc20)
     * @return amount The original amount
     * @return remaining The unspent balance
     */
    function deposits(
        bytes32 depositId
    )
        external
        view
        returns (AssetKind kind, address token, address funder, uint256 tokenId, uint256 amount, uint256 remaining);

    /**
     * @notice Returns the unspent balance of a deposit
     * @param depositId The deposit identifier
     * @return remaining The unspent balance
     */
    function remainingOf(bytes32 depositId) external view returns (uint256 remaining);

    /**
     * @notice Returns a recipient's claimable credit for a given asset (from a failed payout)
     * @param recipient The address owed the credit
     * @param kind The asset class
     * @param token The asset contract (address(0) for native)
     * @param tokenId The ERC-721/1155 id (0 for native/erc20)
     * @return amount The claimable amount
     */
    function creditOf(
        address recipient,
        AssetKind kind,
        address token,
        uint256 tokenId
    ) external view returns (uint256 amount);

    // --- State-Changing Functions ---

    /**
     * @notice Creates a new deposit, custodying one asset in the escrow
     * @dev Controller-only. Native: msg.value must equal amount. ERC-20/721/1155: msg.value
     * must be 0 and the asset is pulled from `funder` (who must have approved the escrow).
     * ERC-20 requires the exact nominal amount to arrive (fee-on-transfer rejected). ERC-721
     * requires amount == 1. The NFT is accepted only because this pull sets the escrow's
     * receive guard; a direct transfer would revert.
     * @param depositId Unique identifier chosen by the controller
     * @param kind The asset class
     * @param token The asset contract; address(0) for native
     * @param funder The address the asset originates from (refund target)
     * @param tokenId The ERC-721/1155 id (ignored for native/erc20)
     * @param amount The amount to deposit (erc721: must be 1; erc1155: quantity)
     */
    function deposit(
        bytes32 depositId,
        AssetKind kind,
        address token,
        address funder,
        uint256 tokenId,
        uint256 amount
    ) external payable;

    /**
     * @notice Releases part or all of a deposit to a recipient (payout path)
     * @dev Controller-only. Debits `remaining` before transferring. For ERC-721 the amount must
     * equal the remaining (1) — an NFT moves whole. The outward transfer NEVER bubbles: if it
     * fails the amount is credited to `to` (claimable via withdraw) and `delivered` is false, so a
     * bad recipient cannot brick the caller's settlement.
     * @param depositId The deposit to draw from
     * @param to The payout recipient
     * @param amount The amount to release
     * @return delivered True if transferred out; false if credited on failure
     */
    function release(bytes32 depositId, address to, uint256 amount) external returns (bool delivered);

    /**
     * @notice Refunds part or all of a deposit (cancel/expiry/dispute path)
     * @dev Controller-only. Same credit-on-failure semantics as release.
     * @param depositId The deposit to draw from
     * @param to The refund recipient
     * @param amount The amount to refund
     * @return delivered True if transferred out; false if credited on failure
     */
    function refund(bytes32 depositId, address to, uint256 amount) external returns (bool delivered);

    /**
     * @notice Withdraws a previously-credited (failed) payout to the caller
     * @dev Permissionless for the credited recipient (msg.sender). Retries the transfer; reverts
     * (keeping the credit) if it still fails. Not a settlement path, so reverting here is safe.
     * @param kind The asset class of the credit
     * @param token The asset contract (address(0) for native)
     * @param tokenId The ERC-721/1155 id (0 for native/erc20)
     * @return amount The amount withdrawn
     */
    function withdraw(AssetKind kind, address token, uint256 tokenId) external returns (uint256 amount);

    /**
     * @notice Reassigns an EXACT amount of a credit from one recipient to another (moves the claim,
     * transfers nothing)
     * @dev Controller-only. The policy layer uses this for post-grace funder-recovery of a reward a
     * worker provably cannot receive, passing EXACTLY the bounty's credited reward — never the whole
     * balance. A fungible credit key can hold a worker's reward AND stake (native reward + native
     * stake collide) or two funders' rewards in the same asset; bounding to `amount` is what keeps
     * the stake floor and one funder's reward safe from another's recovery. Reverts if the source
     * holds less than `amount`.
     * @param from The current owner of the credit
     * @param to The new owner of the credit
     * @param kind The asset class
     * @param token The asset contract (address(0) for native)
     * @param tokenId The ERC-721/1155 id (0 for native/erc20)
     * @param amount The exact amount to reassign
     * @return moved The amount reassigned (== amount)
     */
    function reassignCredit(
        address from,
        address to,
        AssetKind kind,
        address token,
        uint256 tokenId,
        uint256 amount
    ) external returns (uint256 moved);
}
