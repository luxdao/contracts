// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title IEscrowV1
 * @notice Minimal, conservation-safe value vault for a single controller contract
 * @dev EscrowV1 is pure mechanism: it holds native coin and ERC-20 funds in named
 * deposits and releases or refunds them ONLY on instruction from its configured
 * controller. It encodes no business policy — WHO is allowed to fund, claim, accept,
 * or dispute is entirely the controller's concern (e.g. BountyV1). This keeps the
 * value-custody concern orthogonal to the work-market lifecycle (Rich Hickey:
 * decomplect custody from policy).
 *
 * Invariants the escrow itself guarantees, independent of any controller bug:
 * - Conservation: for every token (and native), the sum of live deposit balances
 *   never exceeds the escrow's actual on-chain balance; nothing is minted or burned
 *   by the escrow. Every wei released or refunded was first deposited.
 * - Single-spend: a deposit's remaining balance is debited before any external
 *   transfer (checks-effects-interactions) and is reentrancy-guarded, so a deposit
 *   can never pay out more than it holds.
 * - Authorization: only the controller can move funds; deposits record their funder
 *   so refunds are routable without the controller having to custody that fact.
 *
 * `token == address(0)` denotes the chain's native coin throughout (one convention,
 * matching the rest of the stack). Native deposits require msg.value == amount;
 * ERC-20 deposits pull via transferFrom and credit the exact received amount.
 *
 * Payouts ride to an arbitrary address (EOA, Safe, or any contract), so a
 * post-quantum-signed Safe can be funder or payee without the escrow caring.
 */
interface IEscrowV1 {
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

    /** @notice Thrown when ERC-20 value is sent alongside a deposit (must be 0) */
    error UnexpectedNativeValue();

    /** @notice Thrown when depositing or releasing a zero amount */
    error ZeroAmount();

    /** @notice Thrown when releasing/refunding more than a deposit's remaining balance */
    error InsufficientDeposit(bytes32 depositId, uint256 remaining, uint256 requested);

    /** @notice Thrown when a recipient address is zero */
    error InvalidRecipient();

    /** @notice Thrown when a native coin transfer fails */
    error NativeTransferFailed();

    // --- Structs ---

    /**
     * @notice A single escrowed deposit
     * @param token The deposited asset; address(0) for native coin
     * @param funder The address credited as the source (refunds route here by default)
     * @param amount The original deposited amount
     * @param remaining The amount not yet released or refunded
     */
    struct Deposit {
        address token;
        address funder;
        uint256 amount;
        uint256 remaining;
    }

    // --- Events ---

    /**
     * @notice Emitted when funds are deposited into the escrow
     * @param depositId The controller-chosen identifier for this deposit
     * @param token The deposited asset; address(0) for native
     * @param funder The source of the funds
     * @param amount The deposited amount
     */
    event Deposited(bytes32 indexed depositId, address indexed token, address indexed funder, uint256 amount);

    /**
     * @notice Emitted when funds are released from a deposit to a recipient
     * @param depositId The deposit being drawn from
     * @param to The recipient of the released funds
     * @param amount The released amount
     */
    event Released(bytes32 indexed depositId, address indexed to, uint256 amount);

    /**
     * @notice Emitted when funds are refunded from a deposit
     * @param depositId The deposit being drawn from
     * @param to The recipient of the refund
     * @param amount The refunded amount
     */
    event Refunded(bytes32 indexed depositId, address indexed to, uint256 amount);

    // --- View Functions ---

    /**
     * @notice The only address permitted to move funds (the policy contract)
     * @return controller The controller address
     */
    function controller() external view returns (address controller);

    /**
     * @notice Returns the full record of a deposit
     * @param depositId The deposit identifier
     * @return token The deposited asset (address(0) for native)
     * @return funder The funding source
     * @return amount The original amount
     * @return remaining The unspent balance
     */
    function deposits(
        bytes32 depositId
    ) external view returns (address token, address funder, uint256 amount, uint256 remaining);

    /**
     * @notice Returns the unspent balance of a deposit
     * @param depositId The deposit identifier
     * @return remaining The unspent balance
     */
    function remainingOf(bytes32 depositId) external view returns (uint256 remaining);

    // --- State-Changing Functions ---

    /**
     * @notice Creates a new deposit, custodying funds in the escrow
     * @dev Controller-only. For native coin (token == address(0)), msg.value must
     * equal amount. For ERC-20, msg.value must be 0 and the escrow pulls `amount`
     * from `funder` via transferFrom (funder must have approved the escrow). The
     * credited amount is the exact balance delta observed, so fee-on-transfer tokens
     * cannot inflate the deposit.
     * @param depositId Unique identifier chosen by the controller
     * @param token The asset to deposit; address(0) for native
     * @param funder The address funds originate from (refund target)
     * @param amount The amount to deposit
     */
    function deposit(bytes32 depositId, address token, address funder, uint256 amount) external payable;

    /**
     * @notice Releases part or all of a deposit to a recipient (payout path)
     * @dev Controller-only. Debits `remaining` before transferring.
     * @param depositId The deposit to draw from
     * @param to The payout recipient
     * @param amount The amount to release
     */
    function release(bytes32 depositId, address to, uint256 amount) external;

    /**
     * @notice Refunds part or all of a deposit (cancel/expiry/dispute path)
     * @dev Controller-only. Debits `remaining` before transferring. `to` is explicit
     * so the controller can route a refund to the original funder or to a treasury
     * per its own policy.
     * @param depositId The deposit to draw from
     * @param to The refund recipient
     * @param amount The amount to refund
     */
    function refund(bytes32 depositId, address to, uint256 amount) external;
}
