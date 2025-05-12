// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {LinearERC721VotingV1} from "./LinearERC721VotingV1.sol";
import {HatsProposalCreationWhitelistV1} from "./HatsProposalCreationWhitelistV1.sol";

/**
 * An [Azorius](./Azorius.md) [BaseStrategy](./BaseStrategy.md) implementation that
 * enables linear (i.e. 1 to 1) ERC721 based token voting, with proposal creation
 * restricted to users wearing whitelisted Hats.
 */
contract LinearERC721VotingWithHatsProposalCreationV1 is
    HatsProposalCreationWhitelistV1,
    LinearERC721VotingV1
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
     * @param _owner The owner of the contract
     * @param _tokens Array of ERC-721 token addresses that can vote
     * @param _weights Array of voting weights for each token
     * @param _azoriusModule The Azorius module address
     * @param _votingPeriod The voting time period (in blocks)
     * @param _quorumThreshold Total voting weight required to achieve quorum
     * @param _basisNumerator The numerator for basis calculation
     * @param _hatsContract Address of the Hats contract
     * @param _initialWhitelistedHats Array of initial whitelisted Hat IDs
     */
    function initialize(
        address _owner,
        address[] memory _tokens,
        uint256[] memory _weights,
        address _azoriusModule,
        uint32 _votingPeriod,
        uint256 _quorumThreshold,
        uint256 _basisNumerator,
        address _hatsContract,
        uint256[] memory _initialWhitelistedHats
    ) public initializer {
        // Initialize LinearERC721VotingV1
        LinearERC721VotingV1.initialize(
            _owner,
            _tokens,
            _weights,
            _azoriusModule,
            _votingPeriod,
            _quorumThreshold,
            0, // _proposerThreshold is zero because we only care about the hat check
            _basisNumerator
        );

        // Initialize HatsProposalCreationWhitelistV1
        HatsProposalCreationWhitelistV1.initialize(
            _owner,
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
        override(HatsProposalCreationWhitelistV1, LinearERC721VotingV1)
        onlyOwner
    {}

    function isProposer(
        address _address
    ) public view virtual override returns (bool) {
        return isWearingWhitelistedHat(_address);
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
        override(HatsProposalCreationWhitelistV1, LinearERC721VotingV1)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
