// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {WarrantBase} from "../../../deployables/warrant/WarrantBase.sol";
import {
    IWarrantBase
} from "../../../interfaces/decent/deployables/IWarrantBase.sol";
import {IVersion} from "../../../interfaces/decent/deployables/IVersion.sol";
import {
    IDeploymentBlock
} from "../../../interfaces/decent/IDeploymentBlock.sol";
import {
    DeploymentBlockInitializable
} from "../../../DeploymentBlockInitializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * @title ConcreteWarrantBase
 * @notice Concrete implementation of WarrantBase for testing
 * @dev Provides a simple implementation of _executeWarrant for testing base functionality
 */
contract ConcreteWarrantBase is
    WarrantBase,
    IVersion,
    DeploymentBlockInitializable,
    ERC165
{
    /** @notice Emitted when mock execution occurs */
    event MockWarrantExecuted(address recipient);

    /** @notice Track if mock execution was called */
    bool public mockExecutionCalled;

    /** @notice Track the recipient from mock execution */
    address public mockExecutionRecipient;

    constructor() WarrantBase() {}

    /**
     * @notice Initialize the mock warrant
     * @param relativeTime_ Whether to use relative time based on token unlock
     * @param owner_ Owner address who can clawback after expiration
     * @param warrantHolder_ Address authorized to execute the warrant
     * @param token_ Token to be vested
     * @param feeToken_ Token used for fee payment
     * @param tokenAmount_ Amount of tokens to vest
     * @param tokenPrice_ Price per token in fee token units (18 decimals)
     * @param feeReceiver_ Address that receives fee payments
     * @param expiration_ Expiration timestamp or duration
     */
    function initialize(
        bool relativeTime_,
        address owner_,
        address warrantHolder_,
        address token_,
        address feeToken_,
        uint256 tokenAmount_,
        uint256 tokenPrice_,
        address feeReceiver_,
        uint256 expiration_
    ) public initializer {
        __WarrantBase_init(
            relativeTime_,
            owner_,
            warrantHolder_,
            token_,
            feeToken_,
            tokenAmount_,
            tokenPrice_,
            feeReceiver_,
            expiration_
        );
        __DeploymentBlockInitializable_init();
    }

    /**
     * @notice Mock implementation of warrant execution
     * @dev Simply tracks that execution was called
     * @param recipient_ Address that will receive the vested tokens
     */
    function _executeWarrant(address recipient_) internal override {
        mockExecutionCalled = true;
        mockExecutionRecipient = recipient_;
        emit MockWarrantExecuted(recipient_);
    }

    /**
     * @inheritdoc IVersion
     */
    function version() public pure virtual override returns (uint16) {
        return 1;
    }

    /**
     * @notice Check if contract supports a given interface
     * @dev Supports IWarrantBase, IVersion, IDeploymentBlockV1, and IERC165
     */
    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IWarrantBase).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlock).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
