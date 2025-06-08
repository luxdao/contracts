// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {IMultisigFreezeVotingV1} from "../../interfaces/decent/deployables/IMultisigFreezeVotingV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {ISafe} from "../../interfaces/safe/ISafe.sol";
import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {Version} from "../Version.sol";
import {VoterResolverV1} from "../account-abstraction/VoterResolverV1.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract MultisigFreezeVotingV1 is
    IMultisigFreezeVotingV1,
    BaseFreezeVotingV1,
    VoterResolverV1,
    Version,
    ERC165
{
    uint16 private constant VERSION = 1;

    ISafe internal _parentSafe;
    mapping(uint48 freezeProposalCreated => mapping(address voter => bool))
        internal _userHasFreezeVoted;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        uint256 freezeVotesThreshold_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_,
        address parentSafe_,
        address lightAccountFactory_
    ) public virtual override initializer {
        __BaseFreezeVotingV1_init(
            owner_,
            freezeProposalPeriod_,
            freezePeriod_,
            freezeVotesThreshold_
        );
        __VoterResolverV1_init(lightAccountFactory_);
        _parentSafe = ISafe(parentSafe_);
    }

    function parentSafe() external view virtual override returns (address) {
        return address(_parentSafe);
    }

    function userHasFreezeVoted(
        uint48 freezeProposalCreated,
        address voter
    ) external view virtual override returns (bool) {
        return _userHasFreezeVoted[freezeProposalCreated][voter];
    }

    function castFreezeVote() external virtual override {
        address resolvedVoter = voter(msg.sender);

        if (block.timestamp > _freezeProposalCreated + _freezeProposalPeriod) {
            initializeFreezeVote();
            emit FreezeProposalCreated(resolvedVoter);
        }

        recordFreezeVote(
            resolvedVoter,
            _getVotesAndUpdateHasVoted(resolvedVoter)
        );
    }

    function _getVotesAndUpdateHasVoted(
        address voter
    ) internal virtual returns (uint256 userVotes) {
        if (!_parentSafe.isOwner(voter)) {
            return 0;
        }

        if (_userHasFreezeVoted[_freezeProposalCreated][voter]) {
            return 0;
        }

        userVotes = 1;
        _userHasFreezeVoted[_freezeProposalCreated][voter] = true;
    }

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IMultisigFreezeVotingV1).interfaceId ||
            interfaceId == type(IBaseFreezeVotingV1).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
