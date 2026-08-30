// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import { IHatsIdUtilities } from "../interfaces/hats/IHatsIdUtilities.sol";

/**
 * @title LuxRolesIdUtilities
 * @author Lux Industries Inc
 * @notice luxfi-native, IHats-compatible hat-id arithmetic. Original implementation of the
 *         `IHatsIdUtilities` surface — no import of the external Hats codebase.
 *
 * @dev Hat ids are 256-bit values with a fixed positional layout that the Lux DAO app
 *      (`useCreateRoles.ts` / `rolesStoreUtils.predictHatId`) and the on-chain wrapper
 *      (`UtilityRolesManagementV1`) both assume:
 *
 *        bits [224..255]  (32 bits)  -> top-hat domain (a.k.a. tree id)      == level 0
 *        bits [208..223]  (16 bits)  -> level 1 child slot
 *        bits [192..207]  (16 bits)  -> level 2 child slot
 *        ...
 *        bits [  0.. 15]  (16 bits)  -> level 14 child slot
 *
 *      A top hat is `uint256(domain) << 224`. A child of admin `A` at the next free 16-bit
 *      slot is `A | (uint16(childIndex) << (16 * (14 - localLevel)))`.
 *
 *      The `linkedTreeAdmins` mapping supports grafting one tree's top hat under another
 *      tree's admin hat. LuxRolesV1 populates it only via the canonical mutual-consent
 *      protocol (the top-hat wearer requests, the destination admin approves), so this
 *      base's linkage-aware read paths (levels/admins/tippy-domain) resolve correctly across
 *      linked trees while no party can graft a tree unilaterally.
 *
 * @custom:security-contact security@lux.network
 */
abstract contract LuxRolesIdUtilities is IHatsIdUtilities {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of bits reserved for the top-hat domain (level 0).
    uint256 internal constant TOPHAT_ADDRESS_SPACE = 32;

    /// @notice Number of bits reserved for each sub-level (levels 1..14).
    uint256 internal constant LOWER_LEVEL_ADDRESS_SPACE = 16;

    /// @notice Maximum number of hat levels below the top hat (14 * 16 = 224 bits).
    uint256 internal constant MAX_LEVELS = 14;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps a top-hat domain to the admin hat it is linked under (0 if unlinked).
    /// @dev Keyed by the full top-hat id (`uint256(domain) << 224`) to match canonical
    ///      Hats getter selector `linkedTreeAdmins(uint256)`.
    mapping(uint256 => uint256) public linkedTreeAdmins;

    /// @notice Pending top-hat -> new-admin link requests awaiting approval.
    mapping(uint256 => uint256) public linkedTreeRequests;

    /*//////////////////////////////////////////////////////////////
                              PURE ARITHMETIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHatsIdUtilities
    function buildHatId(uint256 _admin, uint16 _newHat) public pure returns (uint256 id) {
        uint256 mask;
        for (uint256 i = 0; i < MAX_LEVELS;) {
            // mask keeps every bit strictly below the (32 + 16*i) most-significant bits.
            mask = type(uint256).max >> (TOPHAT_ADDRESS_SPACE + (LOWER_LEVEL_ADDRESS_SPACE * i));
            if (_admin & mask == 0) {
                // first empty region found: place `_newHat` in the highest free 16-bit slot.
                id = _admin | (uint256(_newHat) << (LOWER_LEVEL_ADDRESS_SPACE * (MAX_LEVELS - 1 - i)));
                return id;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IHatsIdUtilities
    function getLocalHatLevel(uint256 _hatId) public pure returns (uint32 level) {
        // if there are no bits below the domain, it is a (local) top hat at level 0.
        if (_hatId & type(uint224).max == 0) return 0;

        // scan sub-levels top-down; the level is the last contiguous non-empty slot.
        for (level = 1; level < MAX_LEVELS;) {
            if (_hatId & (uint256(type(uint16).max) << (LOWER_LEVEL_ADDRESS_SPACE * (MAX_LEVELS - level))) == 0) {
                return level - 1;
            }
            unchecked {
                ++level;
            }
        }
        // all 14 sub-levels populated.
        return uint32(MAX_LEVELS);
    }

    /// @inheritdoc IHatsIdUtilities
    function isLocalTopHat(uint256 _hatId) public pure returns (bool _localTopHat) {
        _localTopHat = _hatId > 0 && uint224(_hatId) == 0;
    }

    /// @inheritdoc IHatsIdUtilities
    function getAdminAtLocalLevel(uint256 _hatId, uint32 _level) public pure returns (uint256 admin) {
        uint256 mask = type(uint256).max << (LOWER_LEVEL_ADDRESS_SPACE * (MAX_LEVELS - _level));
        admin = _hatId & mask;
    }

    /// @inheritdoc IHatsIdUtilities
    function getTopHatDomain(uint256 _hatId) public pure returns (uint32 domain) {
        domain = uint32(_hatId >> (LOWER_LEVEL_ADDRESS_SPACE * MAX_LEVELS));
    }

    /*//////////////////////////////////////////////////////////////
                        LINKAGE-AWARE READ PATHS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHatsIdUtilities
    function getHatLevel(uint256 _hatId) public view returns (uint32 level) {
        uint32 local = getLocalHatLevel(_hatId);

        uint256 linkedAdmin = linkedTreeAdmins[uint256(getTopHatDomain(_hatId)) << 224];
        if (linkedAdmin == 0) return local;

        // full level = local level + 1 (for the link edge) + the linked admin's full level.
        return 1 + local + getHatLevel(linkedAdmin);
    }

    /// @inheritdoc IHatsIdUtilities
    function isTopHat(uint256 _hatId) public view returns (bool _topHat) {
        _topHat = isLocalTopHat(_hatId) && linkedTreeAdmins[uint256(getTopHatDomain(_hatId)) << 224] == 0;
    }

    /// @inheritdoc IHatsIdUtilities
    /// @dev Structural validity depends only on the id layout, so this is `pure` (a stricter
    ///      override of the `view`-declared interface function is permitted).
    function isValidHatId(uint256 _hatId) public pure returns (bool validHatId) {
        // a valid (linked or unlinked) top hat is always valid.
        if (isLocalTopHat(_hatId)) return getTopHatDomain(_hatId) != 0;

        // otherwise: domain must be set AND there must be no empty gap between populated
        // levels — equivalent to the id equalling its own admin at its measured local level.
        if (getTopHatDomain(_hatId) == 0) return false;
        validHatId = _hatId == getAdminAtLocalLevel(_hatId, getLocalHatLevel(_hatId));
    }

    /// @inheritdoc IHatsIdUtilities
    function getAdminAtLevel(uint256 _hatId, uint32 _level) public view returns (uint256 admin) {
        uint256 linkedAdmin = linkedTreeAdmins[uint256(getTopHatDomain(_hatId)) << 224];
        if (linkedAdmin == 0) return getAdminAtLocalLevel(_hatId, _level);

        // full level of this tree's local top hat within the linked super-tree.
        uint32 localTopHatLevel = getHatLevel(getAdminAtLocalLevel(_hatId, 0));

        if (localTopHatLevel <= _level) {
            return getAdminAtLocalLevel(_hatId, _level - localTopHatLevel);
        }
        return getAdminAtLevel(linkedAdmin, _level);
    }

    /// @inheritdoc IHatsIdUtilities
    function getTippyTopHatDomain(uint32 _topHatDomain) public view returns (uint32 domain) {
        uint256 linkedAdmin = linkedTreeAdmins[uint256(_topHatDomain) << 224];
        if (linkedAdmin == 0) return _topHatDomain;
        return getTippyTopHatDomain(getTopHatDomain(linkedAdmin));
    }

    /// @inheritdoc IHatsIdUtilities
    function noCircularLinkage(uint32 _topHatDomain, uint256 _linkedAdmin) public view returns (bool notCircular) {
        if (_linkedAdmin == 0) return true;
        uint32 adminDomain = getTopHatDomain(_linkedAdmin);
        if (_topHatDomain == adminDomain) return false;
        uint256 parentAdmin = linkedTreeAdmins[uint256(adminDomain) << 224];
        return noCircularLinkage(_topHatDomain, parentAdmin);
    }

    /// @inheritdoc IHatsIdUtilities
    function sameTippyTopHatDomain(uint32 _topHatDomain, uint256 _newAdminHat) public view returns (bool sameDomain) {
        uint32 currentTippy = getTippyTopHatDomain(_topHatDomain);
        uint32 newAdminTippy = getTippyTopHatDomain(getTopHatDomain(_newAdminHat));
        sameDomain = currentTippy == newAdminTippy;
    }
}
