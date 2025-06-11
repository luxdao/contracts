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
        address[] memory signerAddresses_,
        bool[] memory signerRequired_,
        uint256[] memory signerWeights_,
        Transaction[][] memory signerTransactions_,
        Transaction[] memory preExecutionTransactions_
    ) {
        if (
            signerAddresses_.length != signerRequired_.length ||
            signerAddresses_.length != signerWeights_.length ||
            signerAddresses_.length != signerTransactions_.length
        ) {
            revert InvalidArrayLengths();
        }

        _agreementUri = agreementUri_;
        _verificationContract = verificationContract_;
        _minWeight = minWeight_;
        _signerAddresses = signerAddresses_;

        for (uint256 i = 0; i < preExecutionTransactions_.length; ) {
            _preExecutionTransactions.push(preExecutionTransactions_[i]);
            unchecked {
                ++i;
            }
        }

        for (uint256 i = 0; i < signerAddresses_.length; ) {
            _signerData[signerAddresses_[i]].isSigner = true;
            _signerData[signerAddresses_[i]].required = signerRequired_[i];
            _signerData[signerAddresses_[i]].signed = false;
            _signerData[signerAddresses_[i]].weight = signerWeights_[i];

            Transaction[] storage transactions = _signerData[
                signerAddresses_[i]
            ].transactions;

            for (uint256 j = 0; j < signerTransactions_[i].length; ) {
                transactions.push(signerTransactions_[i][j]);
                unchecked {
                    ++j;
                }
            }

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
