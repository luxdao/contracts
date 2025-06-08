// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IFunctionValidator} from "../../../interfaces/decent/deployables/IFunctionValidator.sol";
import {IStrategyV1} from "../../../interfaces/decent/deployables/IStrategyV1.sol";
import {IVersion} from "../../../interfaces/decent/deployables/IVersion.sol";
import {Version} from "../../Version.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract StrategyV1ValidatorV1 is IFunctionValidator, ERC165, Version {
    uint16 public constant VERSION = 1;

    function validateOperation(
        address,
        address lightAccountOwner_,
        address strategy_,
        bytes calldata callData_
    ) external view virtual override returns (bool) {
        // confirm here that the calldata selector is correct: `vote(uint32,uint8,(tuple(address,bytes))[])`
        if (bytes4(callData_) != IStrategyV1.vote.selector) {
            return false;
        }

        // Decode vote parameters from callData
        // vote(uint32 proposalId_, uint8 voteType_, (tuple(address,bytes))[] votingAdaptersData_)
        (
            uint32 proposalId,
            uint8 voteType,
            IStrategyV1.VotingAdapterVoteData[] memory votingAdaptersData
        ) = abi.decode(
                callData_[4:], // skip selector
                (uint32, uint8, IStrategyV1.VotingAdapterVoteData[])
            );

        return
            IStrategyV1(strategy_).validStrategyVote(
                lightAccountOwner_,
                proposalId,
                voteType,
                votingAdaptersData
            );
    }

    function version() public pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IFunctionValidator).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
