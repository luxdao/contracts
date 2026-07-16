// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {EscrowV1} from "./EscrowV1.sol";
import {ReputationV1} from "./ReputationV1.sol";
import {BountyV1} from "./BountyV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title WorkMarketDeployer
 * @author Lux Industries Inc
 * @notice Atomic, self-wiring deployer for one EscrowV1 / ReputationV1 / BountyV1 work
 * market. Its CONSTRUCTOR deploys the three implementations and their ERC1967 proxies,
 * wires escrow.controller == reputation.writer == the BountyV1 proxy, and VERIFIES that
 * wiring on-chain — reverting the entire deployment if anything is mis-wired. The three
 * live proxy addresses are exposed as immutables.
 *
 * @dev Why a contract and not a script guard: under `forge script --broadcast` the
 * require()s in a Script run only in the off-chain simulation, never on-chain. If the
 * broadcasting EOA's nonce skews between simulation and broadcast (a concurrent tx,
 * `--resume`, a re-broadcast), the real BountyV1 proxy can land at a different address
 * than the one baked into escrow/reputation init data — a SILENT mis-wire that bricks
 * the market with no on-chain guard.
 *
 * Doing the whole deploy inside ONE constructor makes it atomic and EOA-nonce-independent:
 * the six CREATEs originate from THIS contract, so their relative nonces are fully
 * deterministic regardless of the outer EOA's nonce. The BountyV1 proxy address is
 * predicted over `address(this)` — a freshly created contract whose nonce starts at 1 and
 * increments once per CREATE — and the on-chain require is the backstop: if the prediction
 * is ever wrong the constructor reverts, so a mis-wired market can never be deployed.
 *
 *   nonce 1: escrow impl        nonce 4: escrow proxy
 *   nonce 2: reputation impl    nonce 5: reputation proxy
 *   nonce 3: bounty impl        nonce 6: BountyV1 proxy   <-- predicted, wired into 4 & 5
 *
 * LP-040 (bytecode neutrality): brand-neutral — no brand string, no hardcoded address;
 * owner and treasury are constructor arguments, nothing is read from block.chainid here.
 *
 * @custom:security-contact security@lux.network
 */
contract WorkMarketDeployer {
    /** @notice The BountyV1 proxy: sole controller of the escrow and writer of reputation. */
    address public immutable bounty;
    /** @notice The EscrowV1 proxy: value custody for this market. */
    address public immutable escrow;
    /** @notice The ReputationV1 proxy: worker completion history for this market. */
    address public immutable reputation;

    /** @notice Thrown if the BountyV1 proxy did not land at its predicted address. */
    error BountyPredictionFailed(address predicted, address actual);

    /** @notice Thrown if the escrow's controller is not the bounty proxy after wiring. */
    error EscrowMiswired(address controller, address expectedBounty);

    /** @notice Thrown if the reputation's writer is not the bounty proxy after wiring. */
    error ReputationMiswired(address writer, address expectedBounty);

    /**
     * @param owner_ The UUPS upgrade authority for all three proxies (a treasury Safe in
     *        production; the deployer only on testnet/local).
     * @param treasury_ Where slashed stakes route (address(0) => to the bounty's funder).
     */
    constructor(address owner_, address treasury_) {
        // The BountyV1 proxy is the 6th CREATE from this contract (see class doc).
        address predictedBounty = _computeCreateAddress(6);

        EscrowV1 escrowImpl = new EscrowV1(); //          nonce 1
        ReputationV1 repImpl = new ReputationV1(); //     nonce 2
        BountyV1 bountyImpl = new BountyV1(); //          nonce 3

        address escrowProxy = address( //                nonce 4
            new ERC1967Proxy(address(escrowImpl), abi.encodeCall(EscrowV1.initialize, (owner_, predictedBounty)))
        );
        address reputationProxy = address( //            nonce 5
            new ERC1967Proxy(address(repImpl), abi.encodeCall(ReputationV1.initialize, (owner_, predictedBounty)))
        );
        address bountyProxy = address( //                nonce 6
            new ERC1967Proxy(
                address(bountyImpl),
                abi.encodeCall(BountyV1.initialize, (owner_, escrowProxy, reputationProxy, treasury_))
            )
        );

        // On-chain wiring guards: revert the whole deployment (atomic) if anything is off,
        // so a market whose escrow/reputation point at the wrong controller/writer — or a
        // BountyV1 proxy at an unexpected address — can never be produced.
        if (bountyProxy != predictedBounty) revert BountyPredictionFailed(predictedBounty, bountyProxy);
        address wiredController = EscrowV1(payable(escrowProxy)).controller();
        if (wiredController != bountyProxy) revert EscrowMiswired(wiredController, bountyProxy);
        address wiredWriter = ReputationV1(reputationProxy).writer();
        if (wiredWriter != bountyProxy) revert ReputationMiswired(wiredWriter, bountyProxy);

        bounty = bountyProxy;
        escrow = escrowProxy;
        reputation = reputationProxy;
    }

    /**
     * @dev Computes the CREATE address of `address(this)` at a small nonce (1..127) — the
     * only range this constructor uses. For a contract-sender with nonce < 0x80, the RLP is
     * a 22-byte list (0xd6 = 0xc0 + 0x16): 0x94 (0x80 + 20-byte address) ++ address ++ the
     * single-byte nonce. The last 20 bytes of its keccak are the address.
     */
    function _computeCreateAddress(uint8 nonce_) private view returns (address) {
        return
            address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), bytes1(nonce_))))
                )
            );
    }
}
