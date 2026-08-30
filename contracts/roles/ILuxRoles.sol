// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import { IHatsExtended } from "../interfaces/hats/IHatsExtended.sol";

/**
 * @title ILuxRoles
 * @author Lux Industries Inc
 * @notice The exact on-chain surface a luxfi-native roles protocol must expose to be a
 *         drop-in for the Lux DAO app + `UtilityRolesManagementV1` wrapper.
 *
 * @dev Extends `IHatsExtended` (which is `IHats` + `lastTopHatId()`) with the two extra
 *      selectors the frontend `HatsAbi.ts` encodes against `rolesProtocol` that are NOT in
 *      the vendored `IHats` interface:
 *
 *        - `transferRole(uint256,address,address)` — the app's alias for `transferHat`.
 *          Param-name renames do not change a selector, but the NAME change does:
 *          `transferRole` != `transferHat` at the 4-byte level, so a native protocol must
 *          expose BOTH (identical semantics) to remain zero-app-change.
 *        - `isActive(uint256) -> bool` — canonical Hats view (toggle status), read by the app.
 *
 *      These two are present in the real Hats implementation; they were simply omitted from
 *      the vendored `IHats.sol`. Declaring them here keeps the Solidity type honest.
 */
interface ILuxRoles is IHatsExtended {
    /// @notice Alias of `transferHat` with identical semantics; matches the frontend selector.
    function transferRole(uint256 _roleId, address _from, address _to) external;

    /// @notice Returns the current active status of a hat (queries its toggle module).
    function isActive(uint256 _hatId) external view returns (bool active);
}
