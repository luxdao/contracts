// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.28;

import {Version} from "../Version.sol";
import {FactoryFriendly} from "@gnosis-guild/zodiac/contracts/factory/FactoryFriendly.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/**
 * An implementation of the OpenZeppelin `IVotes` voting token standard.
 */
contract VotesERC20V1 is
    Version,
    ERC20VotesUpgradeable,
    ERC20PermitUpgradeable,
    FactoryFriendly
{
    uint16 private constant VERSION = 1;

    constructor() {
        _disableInitializers();
    }

    /**
     * Initialize function, will be triggered when a new instance is deployed.
     *
     * @param initializeParams encoded initialization parameters: `string memory _name`,
     * `string memory _symbol`, `address[] memory _allocationAddresses`,
     * `uint256[] memory _allocationAmounts`
     */
    function setUp(
        bytes memory initializeParams
    ) public virtual override initializer {
        (
            string memory _name, // token name
            string memory _symbol, // token symbol
            address[] memory _allocationAddresses, // addresses of initial allocations
            uint256[] memory _allocationAmounts // amounts of initial allocations
        ) = abi.decode(
                initializeParams,
                (string, string, address[], uint256[])
            );

        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __ERC20Votes_init();

        uint256 holderCount = _allocationAddresses.length;
        for (uint256 i; i < holderCount; ) {
            _mint(_allocationAddresses[i], _allocationAmounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._update(from, to, value);
    }

    function nonces(
        address owner
    )
        public
        view
        virtual
        override(ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /// @inheritdoc Version
    function getVersion() public view virtual override returns (uint16) {
        return VERSION;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IERC20Permit).interfaceId ||
            interfaceId == type(IVotes).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
