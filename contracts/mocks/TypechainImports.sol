// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ERC1967Proxy as OZERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable as OZUUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC165 as OZERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IAccessControl as IOZAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20 as IOZERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit as IOZERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IVotes as IOZVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IPaymaster as IAAPaymaster} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";

/**
 * Thin re-exports of OpenZeppelin and account-abstraction dependency contracts
 * that the test suite drives through TypeChain factories. Hardhat only emits
 * artifacts (and therefore TypeChain factories) for contracts declared under
 * `contracts/`, so these declarations give the dependency factories a home in
 * `typechain-types`.
 *
 * - `ERC1967Proxy` is deployed directly to host an implementation behind a proxy.
 * - `UUPSUpgradeable__factory` is used only as an ABI lens via `.connect(addr)`
 *   to call `upgradeToAndCall` on the real contract under test, so the no-op
 *   authorization here is never exercised on this contract itself.
 * - The remaining interface re-exports are used to compute ERC165 interface IDs
 *   in `supportsInterface` test suites; the extension carries the parent ABI.
 */
contract ERC1967Proxy is OZERC1967Proxy {
    constructor(
        address implementation,
        bytes memory data
    ) payable OZERC1967Proxy(implementation, data) {}
}

contract UUPSUpgradeable is OZUUPSUpgradeable {
    function _authorizeUpgrade(address newImplementation) internal override {}
}

// solhint-disable-next-line no-empty-blocks
contract ERC165 is OZERC165 {}

// solhint-disable-next-line no-empty-blocks
interface IAccessControl is IOZAccessControl {}

// solhint-disable-next-line no-empty-blocks
interface IERC20 is IOZERC20 {}

// solhint-disable-next-line no-empty-blocks
interface IERC20Permit is IOZERC20Permit {}

// solhint-disable-next-line no-empty-blocks
interface IVotes is IOZVotes {}

// solhint-disable-next-line no-empty-blocks
interface IPaymaster is IAAPaymaster {}
