// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {ICountersignV1} from "../../interfaces/decent/deployables/ICountersignV1.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract CountersignV1 is ICountersignV1, IVersion, ERC165 {
    // ======================================================================
    // STATE VARIABLES
    // ======================================================================

    string internal _agreementUri;
    address internal immutable _verificationContract;
    uint256 internal immutable _minWeight;
    address[] internal _signerAddresses;
    mapping(address signer => Signer signerData) internal _signerData;
    Transaction[] internal _preExecutionTransactions;

    // ======================================================================
    // CONSTRUCTOR & INITIALIZERS
    // ======================================================================

    constructor(
        string memory agreementUri_,
        address verificationContract_,
        uint256 minWeight_,
        SignerInitialization[] memory signerInitializations_,
        Transaction[] memory preExecutionTransactions_
    ) {
        _agreementUri = agreementUri_;
        _verificationContract = verificationContract_;
        _minWeight = minWeight_;

        for (uint256 i = 0; i < signerInitializations_.length; ) {
            SignerInitialization memory signerInit = signerInitializations_[i];

            _signerAddresses.push(signerInit.account);

            _signerData[signerInit.account].isSigner = true;
            _signerData[signerInit.account].required = signerInit.required;
            _signerData[signerInit.account].signed = false;
            _signerData[signerInit.account].weight = signerInit.weight;

            Transaction[] storage transactions = _signerData[signerInit.account]
                .transactions;
            for (uint256 j = 0; j < signerInit.transactions.length; ) {
                transactions.push(signerInit.transactions[j]);
                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }

        for (uint256 i = 0; i < preExecutionTransactions_.length; ) {
            _preExecutionTransactions.push(preExecutionTransactions_[i]);
            unchecked {
                ++i;
            }
        }
    }

    // ======================================================================
    // ICountersignV1
    // ======================================================================

    // --- View Functions ---

    function agreementUri()
        public
        view
        virtual
        override
        returns (string memory)
    {
        return _agreementUri;
    }

    function verificationContract()
        public
        view
        virtual
        override
        returns (address)
    {
        return _verificationContract;
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
        address signer
    )
        external
        view
        override
        returns (bool, bool, bool, uint256, Transaction[] memory)
    {
        Signer storage signerData_ = _signerData[signer];

        Transaction[] storage signerTransactions = signerData_.transactions;
        uint256 transactionCount = signerTransactions.length;

        Transaction[] memory returnedSignerTransactions = new Transaction[](
            transactionCount
        );

        for (uint256 i = 0; i < transactionCount; ) {
            returnedSignerTransactions[i] = signerTransactions[i];
            unchecked {
                ++i;
            }
        }

        return (
            true,
            signerData_.required,
            signerData_.signed,
            signerData_.weight,
            returnedSignerTransactions
        );
    }

    function preExecutionTransactions()
        public
        view
        virtual
        override
        returns (Transaction[] memory)
    {
        return _preExecutionTransactions;
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
            super.supportsInterface(interfaceId_);
    }
}
