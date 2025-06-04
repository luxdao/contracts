// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC20ProposerAdapterV1} from "../../../interfaces/decent/deployables/IERC20ProposerAdapterV1.sol";
import {IProposerAdapterV1} from "../../../interfaces/decent/deployables/IProposerAdapterV1.sol";
import {IProposerAdapterBaseV1} from "../../../interfaces/decent/deployables/IProposerAdapterBaseV1.sol";
import {IVersion} from "../../../interfaces/decent/deployables/IVersion.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Version} from "../../Version.sol";

contract ERC20ProposerAdapterV1 is
    IERC20ProposerAdapterV1,
    Initializable,
    ERC165,
    Version
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
        address _proposer,
        bytes memory
    ) external view virtual override returns (bool) {
        return _token.getVotes(_proposer) >= _proposerThreshold;
    }

    function version() public pure virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC20ProposerAdapterV1).interfaceId ||
            interfaceId == type(IProposerAdapterV1).interfaceId ||
            interfaceId == type(IProposerAdapterBaseV1).interfaceId ||
            interfaceId == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
