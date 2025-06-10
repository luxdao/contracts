// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {ICountersign} from "../../interfaces/decent/deployables/ICountersign.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract Countersign is ICountersign, IVersion, ERC165 {
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
        _preExecutionTransactions = preExecutionTransactions_;

        for (uint256 i = 0; i < signerAddresses_.length; ) {
            _signerData[signerAddresses_[i]] = Signer({
                isSigner: true,
                required: signerRequired_[i],
                signed: false,
                weight: signerWeights_[i],
                transactions: signerTransactions_[i]
            });

            unchecked {
                ++i;
            }
        }
    }

    // ======================================================================
    // ICountersign
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
        public
        view
        virtual
        override
        returns (
            bool isSigner,
            bool required,
            bool signed,
            uint256 weight,
            Transaction[] memory transactions
        )
    {
        return (
            _signerData[signer].isSigner,
            _signerData[signer].required,
            _signerData[signer].signed,
            _signerData[signer].weight,
            _signerData[signer].transactions
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
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
