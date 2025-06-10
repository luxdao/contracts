// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IVersion} from "../../interfaces/decent/deployables/IVersion.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract Countersign is IVersion, Ownable2StepUpgradeable, ERC165 {
    struct Transaction {
        address target;
        uint256 value;
        bytes data;
    }

    struct Signer {
        bool isSigner;
        bool required;
        bool signed;
        uint256 weight;
        Transaction[] transactions;
    }

    error InvalidSignerData();
    error InvalidSigner();
    error AlreadySigned();

    event Signed(address indexed signer);

    uint256 public minWeight;
    uint256 public maxWeight;
    address[] public signerAddresses;
    mapping(address signer => Signer signerData) public signers;

    constructor(
        uint256 minWeight_,
        uint256 maxWeight_,
        address[] memory signerAddresses_,
        bool[] memory signerRequired_,
        uint256[] memory signerWeights_,
        Transaction[][] memory signerTransactions_
    ) {
        if (
            signerAddresses_.length != signerRequired_.length ||
            signerAddresses_.length != signerWeights_.length ||
            signerAddresses_.length != signerTransactions_.length
        ) {
            revert InvalidSignerData();
        }

        __Ownable2Step_init(msg.sender);

        minWeight = minWeight_;
        maxWeight = maxWeight_;

        signerAddresses = signerAddresses_;

        for (uint256 i = 0; i < signerAddresses_.length; ) {
            signers[signerAddresses_[i]] = Signer({
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

    function sign() public {
        Signer storage signer = signers[msg.sender];

        if (!signer.isSigner) revert InvalidSigner();

        if (signer.signed) revert AlreadySigned();

        signer.signed = true;

        emit Signed(msg.sender);
    }

    function _execute(Transaction memory transaction_) internal returns (bool) {
        (bool success, ) = transaction_.target.call{value: transaction_.value}(
            transaction_.data
        );

        // if (!success) revert ExecutionFailed();

        return success;
    }

    function version() public pure virtual override returns (uint16) {
        return 1;
    }

    function supportsInterface(
        bytes4 interfaceId_
    ) public view virtual override returns (bool) {
        return
            interfaceId_ == type(IVersion).interfaceId ||
            super.supportsInterface(interfaceId_);
    }
}
