// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IAzoriusFreezeVotingV1} from "../../interfaces/decent/deployables/IAzoriusFreezeVotingV1.sol";
import {IBaseFreezeVotingV1} from "../../interfaces/decent/deployables/IBaseFreezeVotingV1.sol";
import {IBaseVotingAdapterV1} from "../../interfaces/decent/deployables/IBaseVotingAdapterV1.sol";
import {IAzoriusV1} from "../../interfaces/decent/deployables/IAzoriusV1.sol";
import {IStrategyV1} from "../../interfaces/decent/deployables/IStrategyV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {IVoterResolverV1} from "../../interfaces/decent/deployables/IVoterResolverV1.sol";
import {VoterResolverV1} from "../account-abstraction/VoterResolverV1.sol";
import {BaseFreezeVotingV1} from "./BaseFreezeVotingV1.sol";
import {Version} from "../Version.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract AzoriusFreezeVotingV1 is
    IAzoriusFreezeVotingV1,
    BaseFreezeVotingV1,
    VoterResolverV1,
    Version,
    ERC165
{
    uint16 public constant VERSION = 1;

    IAzoriusV1 internal _parentAzorius;
    address internal _freezeProposalStrategy;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        uint256 freezeVotesThreshold_,
        uint32 freezeProposalPeriod_,
        uint32 freezePeriod_,
        address parentAzorius_,
        address lightAccountFactory_
    ) external virtual override initializer {
        __BaseFreezeVotingV1_init(
            owner_,
            freezeProposalPeriod_,
            freezePeriod_,
            freezeVotesThreshold_
        );
        __VoterResolverV1_init(lightAccountFactory_);
        _parentAzorius = IAzoriusV1(parentAzorius_);
    }

    function parentAzorius() external view virtual override returns (address) {
        return address(_parentAzorius);
    }

    function freezeProposalStrategy()
        external
        view
        virtual
        override
        returns (address)
    {
        return _freezeProposalStrategy;
    }

    function castFreezeVote(
        VotingAdapterVoteData[] calldata _votingAdaptersToUse
    ) external virtual override {
        address resolvedVoter = voter(msg.sender);

        if (block.timestamp > _freezeProposalCreated + _freezeProposalPeriod) {
            initializeFreezeVote();
            _freezeProposalStrategy = _parentAzorius.strategy();
            emit FreezeProposalCreated(resolvedVoter, _freezeProposalStrategy);
        }

        recordFreezeVote(
            resolvedVoter,
            _getVotes(resolvedVoter, _votingAdaptersToUse)
        );
    }

    function _getVotes(
        address voter,
        VotingAdapterVoteData[] calldata votingAdaptersToUse
    ) internal virtual returns (uint256 userVotes) {
        for (uint256 i = 0; i < votingAdaptersToUse.length; ) {
            address adapterAddress = votingAdaptersToUse[i].votingAdapter;

            if (
                !IStrategyV1(_freezeProposalStrategy).isVotingAdapter(
                    adapterAddress
                )
            ) {
                revert InvalidVotingAdapter();
            }

            userVotes += IBaseVotingAdapterV1(adapterAddress).recordFreezeVote(
                voter,
                _freezeProposalCreated,
                votingAdaptersToUse[i].adapterVoteData
            );

            unchecked {
                ++i;
            }
        }
    }

    function unfreeze() public virtual override onlyOwner {
        _freezeProposalStrategy = address(0);
        super.unfreeze();
    }

    function version() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IAzoriusFreezeVotingV1).interfaceId ||
            interfaceId == type(IBaseFreezeVotingV1).interfaceId ||
            interfaceId == type(IVoterResolverV1).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
