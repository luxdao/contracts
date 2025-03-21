// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {Version} from "../Version.sol";
import {LinearERC20VotingV1} from "./LinearERC20VotingV1.sol";
import {HatsProposalCreationWhitelistV1} from "./HatsProposalCreationWhitelistV1.sol";
import {BaseStrategyV1} from "./BaseStrategyV1.sol";

/**
 * An [Azorius](./Azorius.md) [BaseStrategy](./BaseStrategy.md) implementation that
 * enables linear (i.e. 1 to 1) ERC20 based token voting, with proposal creation
 * restricted to users wearing whitelisted Hats.
 */
contract LinearERC20VotingWithHatsProposalCreationV1 is
    HatsProposalCreationWhitelistV1,
    LinearERC20VotingV1
{
    uint16 private constant VERSION = 1;

    /**
     * @dev Constructor that disables initializers
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * Initializes the contract with its initial parameters.
     *
     * @param _owner Address that will own the contract
     * @param _governanceToken The token used for voting
     * @param _azoriusModule Address of the Azorius module contract
     * @param _votingPeriod Time period for voting
     * @param _quorumNumerator Numerator for quorum calculation
     * @param _basisNumerator Numerator for basis calculation
     * @param _hatsContract Address of the Hats contract
     * @param _initialWhitelistedHats Array of initial whitelisted Hat IDs
     */
    function initialize(
        address _owner,
        address _governanceToken,
        address _azoriusModule,
        uint32 _votingPeriod,
        uint256 _quorumNumerator,
        uint256 _basisNumerator,
        address _hatsContract,
        uint256[] memory _initialWhitelistedHats
    ) public initializer {
        // Initialize LinearERC20VotingV1
        LinearERC20VotingV1.initialize(
            _owner,
            _governanceToken,
            _azoriusModule,
            _votingPeriod,
            0, // requiredProposerWeight is zero because we only care about the hat check
            _quorumNumerator,
            _basisNumerator
        );

        // Initialize HatsProposalCreationWhitelistV1
        HatsProposalCreationWhitelistV1.initialize(
            _hatsContract,
            _initialWhitelistedHats
        );
    }

    /**
     * @dev Function that authorizes an upgrade to a new implementation.
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    )
        internal
        virtual
        override(HatsProposalCreationWhitelistV1, LinearERC20VotingV1)
        onlyOwner
    {}

    /** @inheritdoc HatsProposalCreationWhitelistV1*/
    function isProposer(
        address _address
    )
        public
        view
        virtual
        override(HatsProposalCreationWhitelistV1, LinearERC20VotingV1)
        returns (bool)
    {
        return HatsProposalCreationWhitelistV1.isProposer(_address);
    }

    /**
     * Implementation of version
     */
    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(HatsProposalCreationWhitelistV1, LinearERC20VotingV1)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
