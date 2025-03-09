// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {IBaseQuorumPercentV1} from "../../interfaces/decent/deployables/IBaseQuorumPercentV1.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * An Azorius extension contract that enables percent based quorums.
 * Intended to be implemented by [BaseStrategy](./BaseStrategy.md) implementations.
 */
abstract contract BaseQuorumPercentV1 is
    IBaseQuorumPercentV1,
    IVersion,
    OwnableUpgradeable,
    ERC165
{
    /** The numerator to use when calculating quorum (adjustable). */
    uint256 public quorumNumerator;

    /** The denominator to use when calculating quorum (1,000,000). */
    uint256 public constant QUORUM_DENOMINATOR = 1_000_000;

    /**
     * Updates the quorum required for future Proposals.
     *
     * @param _quorumNumerator numerator to use when calculating quorum (over 1,000,000)
     */
    function updateQuorumNumerator(
        uint256 _quorumNumerator
    ) public virtual onlyOwner {
        _updateQuorumNumerator(_quorumNumerator);
    }

    /** Internal implementation of `updateQuorumNumerator`. */
    function _updateQuorumNumerator(uint256 _quorumNumerator) internal virtual {
        if (_quorumNumerator > QUORUM_DENOMINATOR)
            revert InvalidQuorumNumerator();

        quorumNumerator = _quorumNumerator;

        emit QuorumNumeratorUpdated(_quorumNumerator);
    }

    /**
     * Calculates whether a vote meets quorum. This is calculated based on yes votes + abstain
     * votes.
     *
     * @param _totalSupply the total supply of tokens
     * @param _yesVotes number of votes in favor
     * @param _abstainVotes number of votes abstaining
     * @return bool whether the total number of yes votes + abstain meets the quorum
     */
    function meetsQuorum(
        uint256 _totalSupply,
        uint256 _yesVotes,
        uint256 _abstainVotes
    ) public view returns (bool) {
        return
            _yesVotes + _abstainVotes >=
            (_totalSupply * quorumNumerator) / QUORUM_DENOMINATOR;
    }

    /**
     * Calculates the total number of votes required for a proposal to meet quorum.
     *
     * @param _proposalId The ID of the proposal to get quorum votes for
     * @return uint256 The quantity of votes required to meet quorum
     */
    function quorumVotes(
        uint32 _proposalId
    ) public view virtual returns (uint256);

    /// @inheritdoc IVersion
    function getVersion() external pure virtual returns (uint16);

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IBaseQuorumPercentV1).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
