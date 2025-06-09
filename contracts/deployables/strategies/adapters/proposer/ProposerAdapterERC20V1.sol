// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IProposerAdapterERC20V1} from "../../../../interfaces/decent/deployables/IProposerAdapterERC20V1.sol";
import {IProposerAdapterBaseV1} from "../../../../interfaces/decent/deployables/IProposerAdapterBaseV1.sol";
import {IVersion} from "../../../../interfaces/decent/deployables/IVersion.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract ProposerAdapterERC20V1 is
    IProposerAdapterERC20V1,
    IVersion,
    Initializable,
    ERC165
{
    IVotes internal _token;
    uint256 internal _proposerThreshold;

    uint16 public constant VERSION = 1;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address token_,
        uint256 proposerThreshold_
    ) external virtual override initializer {
        _token = IVotes(token_);
        _proposerThreshold = proposerThreshold_;
    }

    function token() external view virtual override returns (address) {
        return address(_token);
    }

    function proposerThreshold()
        external
        view
        virtual
        override
        returns (uint256)
    {
        return _proposerThreshold;
    }

    function isProposer(
        address proposer_,
        bytes calldata
    ) external view virtual override returns (bool) {
        return _token.getVotes(proposer_) >= _proposerThreshold;
    }

    function version() external pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IProposerAdapterERC20V1).interfaceId ||
            interfaceId_ == type(IProposerAdapterBaseV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
