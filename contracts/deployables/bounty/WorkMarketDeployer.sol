// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Escrow} from "./Escrow.sol";
import {Reputation} from "./Reputation.sol";
import {Bounty} from "./Bounty.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Karma} from "@luxfi/standard/governance/Karma.sol";
import {KarmaController} from "@luxfi/standard/governance/KarmaController.sol";

/**
 * @title WorkMarketDeployer
 * @author Lux Industries Inc
 * @notice Atomic, self-wiring, on-chain-verified deployer for a complete work market:
 * a fresh Escrow / Reputation / Bounty trio AND its global Karma stack (Karma +
 * KarmaController), fully role-wired and handed to the org Safe — in ONE constructor.
 *
 * @dev Everything nonce-sensitive or authority-sensitive is done atomically and
 * VERIFIED on-chain, so a mis-wired or partially-owned market can never be produced:
 *
 *  - The escrow<->reputation<->bounty cycle is broken by predicting the Bounty proxy
 *    address (CREATE is deterministic in deployer + nonce) and pointing escrow/reputation at
 *    it. The prediction is over `address(this)` (a fresh contract whose nonce
 *    starts at 1), so it is independent of the outer EOA nonce; an on-chain require is the
 *    backstop.
 *  - Karma + KarmaController are deployed with THIS contract as their transient AccessControl
 *    admin, so this constructor can wire the roles. It then grants the OPERATIONAL roles at
 *    least privilege (KarmaController is the only Karma ATTESTOR; Reputation is the only
 *    KarmaController KARMA_SOURCE), hands GOVERNANCE (admin + slash) to the org Safe, and
 *    RENOUNCES every role it held — so after construction the deployer has no power and the
 *    org Safe governs everything. No EOA is ever an admin.
 *
 *  The three market IMPLEMENTATIONS (Escrow / Reputation / Bounty logic) are deployed by the
 *  caller and passed in — NOT embedded here. That keeps this deployer's own initcode far under the
 *  EIP-3860 limit (embedding all three impls' creation code left it ~30 bytes from the ceiling —
 *  a brittle, near-brick constraint), and lets a multi-market org reuse one impl set. The impls are
 *  stateless logic with no admin, so injecting them introduces no trust concern.
 *
 *  CREATE nonce map (all from address(this)):
 *    1: Karma            3: Escrow proxy       5: Bounty proxy   <-- predicted
 *    2: KarmaController  4: Reputation proxy
 *
 * The five live addresses are exposed as immutables. Brand-neutral (LP-040): no brand string,
 * no hardcoded address, nothing read from block.chainid; owner/treasury/karmaPerCompletion/impls
 * are constructor arguments.
 *
 * @custom:security-contact security@lux.network
 */
contract WorkMarketDeployer {
    /** @notice The Bounty proxy: sole controller of the escrow and writer of reputation. */
    address public immutable bounty;
    /** @notice The Escrow proxy: multi-asset value custody for this market. */
    address public immutable escrow;
    /** @notice The Reputation proxy: worker completion history + Karma bridge. */
    address public immutable reputation;
    /** @notice The Karma token: global, cross-DAO soul-bound reputation. */
    address public immutable karma;
    /** @notice The KarmaController: the role-gated earn path Reputation mints through. */
    address public immutable karmaController;

    /** @notice Thrown if the Bounty proxy did not land at its predicted address. */
    error BountyPredictionFailed(address predicted, address actual);

    /** @notice Thrown if the escrow's controller is not the bounty proxy after wiring. */
    error EscrowMiswired(address controller, address expectedBounty);

    /** @notice Thrown if the reputation's writer is not the bounty proxy after wiring. */
    error ReputationMiswired(address writer, address expectedBounty);

    /** @notice Thrown if the reputation's Karma controller is not the deployed controller. */
    error KarmaControllerMiswired(address wired, address expected);

    /** @notice Thrown if a required operational Karma role was not granted. */
    error KarmaRoleMiswired();

    /** @notice Thrown if the org Safe did not end up as governance admin, or the deployer retained power. */
    error OwnershipHandoffFailed();

    /**
     * @param owner_ The UUPS upgrade authority for the three market proxies AND the Karma
     *        governance admin (a treasury Safe in production; the deployer only on test/local).
     * @param treasury_ Where slashed stakes route (address(0) => to the bounty's funder).
     * @param karmaPerCompletion_ The flat Karma award minted per accepted completion.
     * @param escrowImpl_ Pre-deployed Escrow implementation (logic; ownerless).
     * @param reputationImpl_ Pre-deployed Reputation implementation (logic; ownerless).
     * @param bountyImpl_ Pre-deployed Bounty implementation (logic; ownerless).
     */
    constructor(
        address owner_,
        address treasury_,
        uint256 karmaPerCompletion_,
        address escrowImpl_,
        address reputationImpl_,
        address bountyImpl_
    ) {
        // The Bounty proxy is the 5th CREATE from this contract (see class doc).
        address predictedBounty = _computeCreateAddress(5);

        // --- Karma stack: this contract is the transient AccessControl admin. -----------
        Karma karmaToken = new Karma(address(this)); //                          nonce 1
        KarmaController controller = new KarmaController( //                     nonce 2
            address(karmaToken),
            address(0), // no SoulID: earnKarma stays a pure mint + activity record
            address(this),
            address(this)
        );

        // --- Market proxies over the injected impls (escrow/reputation point at predicted bounty).
        address escrowProxy = address( //                                        nonce 3
            new ERC1967Proxy(escrowImpl_, abi.encodeCall(Escrow.initialize, (owner_, predictedBounty)))
        );
        address reputationProxy = address( //                                    nonce 4
            new ERC1967Proxy(
                reputationImpl_,
                abi.encodeCall(
                    Reputation.initialize,
                    (owner_, predictedBounty, address(controller), karmaPerCompletion_)
                )
            )
        );
        address bountyProxy = address( //                                        nonce 5
            new ERC1967Proxy(
                bountyImpl_,
                abi.encodeCall(Bounty.initialize, (owner_, escrowProxy, reputationProxy, treasury_))
            )
        );

        // --- Operational role grants (least privilege). ---------------------------------
        // KarmaController is the ONLY Karma minter; Reputation is the ONLY earn source.
        karmaToken.grantRole(karmaToken.ATTESTOR_ROLE(), address(controller));
        controller.grantRole(controller.KARMA_SOURCE_ROLE(), reputationProxy);

        // --- Governance handoff to the org Safe. ----------------------------------------
        bytes32 adminRole = 0x00; // AccessControl.DEFAULT_ADMIN_ROLE
        karmaToken.grantRole(adminRole, owner_);
        karmaToken.grantRole(karmaToken.SLASHER_ROLE(), owner_);
        controller.grantRole(adminRole, owner_);
        controller.grantRole(controller.GOVERNOR_ROLE(), owner_);
        controller.grantRole(controller.SLASHER_ROLE(), owner_);

        // --- On-chain wiring guards (revert the whole deployment if anything is off). ----
        if (bountyProxy != predictedBounty) revert BountyPredictionFailed(predictedBounty, bountyProxy);
        address wiredController = Escrow(payable(escrowProxy)).controller();
        if (wiredController != bountyProxy) revert EscrowMiswired(wiredController, bountyProxy);
        address wiredWriter = Reputation(reputationProxy).writer();
        if (wiredWriter != bountyProxy) revert ReputationMiswired(wiredWriter, bountyProxy);
        address wiredKarma = Reputation(reputationProxy).karmaController();
        if (wiredKarma != address(controller)) revert KarmaControllerMiswired(wiredKarma, address(controller));
        if (!karmaToken.hasRole(karmaToken.ATTESTOR_ROLE(), address(controller))) revert KarmaRoleMiswired();
        if (!controller.hasRole(controller.KARMA_SOURCE_ROLE(), reputationProxy)) revert KarmaRoleMiswired();
        if (!karmaToken.hasRole(adminRole, owner_)) revert OwnershipHandoffFailed();
        if (!controller.hasRole(adminRole, owner_)) revert OwnershipHandoffFailed();

        // --- Renounce ALL power the deployer transiently held. --------------------------
        karmaToken.renounceRole(karmaToken.ATTESTOR_ROLE(), address(this));
        karmaToken.renounceRole(karmaToken.SLASHER_ROLE(), address(this));
        controller.renounceRole(controller.KARMA_SOURCE_ROLE(), address(this));
        controller.renounceRole(controller.GOVERNOR_ROLE(), address(this));
        controller.renounceRole(controller.SLASHER_ROLE(), address(this));
        // Renounce admin LAST — after this the deployer can grant/renounce nothing more.
        karmaToken.renounceRole(adminRole, address(this));
        controller.renounceRole(adminRole, address(this));

        // The deployer must retain NO authority anywhere.
        if (karmaToken.hasRole(adminRole, address(this))) revert OwnershipHandoffFailed();
        if (controller.hasRole(adminRole, address(this))) revert OwnershipHandoffFailed();

        bounty = bountyProxy;
        escrow = escrowProxy;
        reputation = reputationProxy;
        karma = address(karmaToken);
        karmaController = address(controller);
    }

    /**
     * @dev Computes the CREATE address of `address(this)` at a small nonce (1..127). For a
     * contract-sender with nonce < 0x80 the RLP is a 22-byte list (0xd6 = 0xc0 + 0x16):
     * 0x94 (0x80 + 20-byte address) ++ address ++ the single-byte nonce.
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
