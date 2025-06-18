// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IKYCVerifierV1} from "../../interfaces/decent/deployables/IKYCVerifierV1.sol";
import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {ICountersignV1} from "../../interfaces/decent/deployables/ICountersignV1.sol";
import {IDeploymentBlockV1} from "../../interfaces/decent/IDeploymentBlockV1.sol";
import {IMultisend} from "../../interfaces/safe/IMultiSend.sol";
import {DeploymentBlockV1} from "../../DeploymentBlockV1.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract CountersignV1 is
    ICountersignV1,
    IVersion,
    DeploymentBlockV1,
    ERC165,
    Ownable2StepUpgradeable
{
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    bool internal _initialExecutionComplete;
    string internal _agreementUri;
    address internal _kycVerifier;
    uint48 internal _signingDeadline;
    uint48 internal _executionDeadline;
    address internal _multisend;
    uint256 internal _minWeight;
    address[] internal _signerAddresses;
    mapping(address signer => Signer signerData) internal _signerData;
    bytes internal _preExecutionTransactions;

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        string memory agreementUri_,
        address kycVerifier_,
        uint48 signingDeadline_,
        uint48 executionDeadline_,
        address multisend_,
        uint256 minWeight_,
        bytes memory preExecutionTransactions_,
        SignerInitialization[] memory signerInitializations_
    ) public virtual override initializer {
        __Ownable_init(owner_);
        __DeploymentBlockV1_init();
        _agreementUri = agreementUri_;
        _kycVerifier = kycVerifier_;
        _signingDeadline = signingDeadline_;
        _executionDeadline = executionDeadline_;
        _multisend = multisend_;
        _minWeight = minWeight_;
        _preExecutionTransactions = preExecutionTransactions_;

        for (uint256 i = 0; i < signerInitializations_.length; ) {
            SignerInitialization memory signerInit = signerInitializations_[i];

            _signerAddresses.push(signerInit.account);

            _signerData[signerInit.account].isSigner = true;
            _signerData[signerInit.account].required = signerInit.required;
            _signerData[signerInit.account].weight = signerInit.weight;
            _signerData[signerInit.account].transactions = signerInit
                .transactions;

            unchecked {
                ++i;
            }
        }
    }

    // ======================================================================
    // ICountersignV1
    // ======================================================================

    // --- View Functions ---

    function initialExecutionComplete()
        public
        view
        virtual
        override
        returns (bool)
    {
        return _initialExecutionComplete;
    }

    function agreementUri()
        public
        view
        virtual
        override
        returns (string memory)
    {
        return _agreementUri;
    }

    function kycVerifier() public view virtual override returns (address) {
        return _kycVerifier;
    }

    function signingDeadline() public view virtual override returns (uint48) {
        return _signingDeadline;
    }

    function executionDeadline() public view virtual override returns (uint48) {
        return _executionDeadline;
    }

    function multisend() public view virtual override returns (address) {
        return _multisend;
    }

    function minWeight() public view virtual override returns (uint256) {
        return _minWeight;
    }

    function signerAddresses()
        public
        view
        virtual
        override
        returns (address[] memory)
    {
        return _signerAddresses;
    }

    function signerData(
        address signer_
    )
        external
        view
        override
        returns (bool, bool, bool, bool, uint48, uint256, bytes memory)
    {
        Signer storage signer = _signerData[signer_];

        return (
            true,
            signer.required,
            signer.signed,
            signer.executed,
            signer.signedTimestamp,
            signer.weight,
            signer.transactions
        );
    }

    function preExecutionTransactions()
        public
        view
        virtual
        override
        returns (bytes memory)
    {
        return _preExecutionTransactions;
    }

    // --- State-Changing Functions ---

    function sign() public virtual override {
        if (block.timestamp > _signingDeadline) {
            revert SigningDeadlineElapsed();
        }

        Signer storage signer = _signerData[msg.sender];

        if (!signer.isSigner) {
            revert InvalidSigner();
        }

        if (signer.signed) {
            revert SignerAlreadySigned();
        }

        if (!IKYCVerifierV1(_kycVerifier).verify(msg.sender)) {
            revert InvalidKYCSignature();
        }

        signer.signed = true;
        signer.signedTimestamp = uint48(block.timestamp);

        emit Signed(msg.sender);
    }

    function execute() public virtual override onlyOwner {
        if (block.timestamp < _signingDeadline) {
            revert SigningDeadlineNotElapsed();
        }

        if (block.timestamp > _executionDeadline) {
            revert ExecutionDeadlineElapsed();
        }

        if (!_initialExecutionComplete) {
            _initialExecution();
        } else {
            _followUpExecutions();
        }
    }

    function _initialExecution() internal {
        if (_preExecutionTransactions.length > 0) {
            (bool success, ) = _multisend.delegatecall(
                abi.encodeCall(IMultisend.multiSend, _preExecutionTransactions)
            );

            if (!success) {
                revert PreExecutionTxFailed();
            }
        }

        uint256 executedWeight;

        for (uint256 i = 0; i < _signerAddresses.length; ) {
            address signerAddress = _signerAddresses[i];
            Signer storage signer = _signerData[signerAddress];

            if (!signer.signed) {
                if (signer.required)
                    revert RequiredSignerNotSigned(signerAddress);

                unchecked {
                    ++i;
                }
                continue;
            }

            if (signer.transactions.length > 0) {
                (bool success, ) = _multisend.delegatecall(
                    abi.encodeCall(IMultisend.multiSend, signer.transactions)
                );

                if (success) {
                    signer.executed = true;
                    executedWeight += signer.weight;
                    emit SignerTxExecuted(signerAddress);
                } else {
                    if (signer.required) {
                        revert RequiredSignerTxFailed(signerAddress);
                    } else {
                        emit SignerTxFailed(signerAddress);
                    }
                }
            }

            unchecked {
                ++i;
            }
        }

        if (executedWeight < _minWeight) {
            revert MinimumWeightNotMet();
        }

        _initialExecutionComplete = true;
    }

    function _followUpExecutions() internal {
        for (uint256 i = 0; i < _signerAddresses.length; ) {
            address signerAddress = _signerAddresses[i];
            Signer storage signer = _signerData[signerAddress];

            if (
                !signer.signed ||
                signer.executed ||
                signer.transactions.length == 0
            ) {
                unchecked {
                    ++i;
                }
                continue;
            }

            (bool success, ) = _multisend.delegatecall(
                abi.encodeCall(IMultisend.multiSend, signer.transactions)
            );

            if (success) {
                signer.executed = true;
                emit SignerTxExecuted(signerAddress);
            } else {
                emit SignerTxFailed(signerAddress);
            }

            unchecked {
                ++i;
            }
        }
    }

    // ======================================================================
    // IVersion
    // ======================================================================

    // --- Pure Functions ---

    function version() public pure virtual override returns (uint16) {
        return 1;
    }

    // ======================================================================
    // ERC165
    // ======================================================================

    // --- View Functions ---

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(ICountersignV1).interfaceId ||
            interfaceId_ == type(IVersion).interfaceId ||
            interfaceId_ == type(IDeploymentBlockV1).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
