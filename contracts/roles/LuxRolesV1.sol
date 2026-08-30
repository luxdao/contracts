// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import { ILuxRoles } from "./ILuxRoles.sol";
import { IHats } from "../interfaces/hats/IHats.sol";
import { LuxRolesIdUtilities } from "./LuxRolesIdUtilities.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * @title LuxRolesV1
 * @author Lux Industries Inc
 * @notice luxfi-native, IHats-compatible roles protocol. A drop-in for the external Hats
 *         Protocol: deploy at the address the Lux DAO app points to as `rolesProtocol` and
 *         the app + `UtilityRolesManagementV1` wrapper work unchanged (zero app logic changes).
 *
 * @dev Original luxfi implementation — no import of the external (AGPL) Hats codebase. It
 *      re-implements the observable behaviour of the Hats ERC-1155 hats-tree faithfully:
 *
 *      - Hats are soulbound ERC-1155 tokens (balance 0/1 per wearer per hat). Standard
 *        ERC-1155 transfers/approvals are disabled; role movement happens only through the
 *        admin-gated `transferHat` / `transferRole`.
 *      - A hat's *dynamic* balance is 1 only while the hat is active (toggle) AND the wearer
 *        is eligible + in good standing (eligibility). Modules are queried by staticcall with
 *        a fail-safe fallback to stored state, exactly as Hats does — so an EOA/plain-contract
 *        eligibility/toggle (used by the wrapper for untermed roles) yields active+eligible.
 *      - Authority is the hat tree: to create or mint a child hat, the caller must wear one of
 *        its admin hats (any ancestor up to the top hat). This is the ONLY authority path;
 *        there is no owner, no global admin, no backdoor.
 *
 *      Tree linking (grafting one top hat under another tree) is implemented with the
 *      canonical mutual-consent protocol (offer by the top-hat wearer + accept by the target
 *      admin), so it cannot be used for unilateral privilege escalation.
 *
 *      ERC-6551 composition: sub-wallets are created by the canonical ERC-6551 registry with
 *      `tokenContract == address(this)` and `tokenId == hatId`; the bound account
 *      (`LuxRolesAccount1ofNV1`) treats any current wearer of the hat as a valid 1-of-N signer.
 *
 * @custom:security-contact security@lux.network
 */
contract LuxRolesV1 is ILuxRoles, LuxRolesIdUtilities, ERC165 {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Hat {
        string details; // free-form metadata / ipfs pointer
        string imageURI; // image pointer (empty -> inherits from admin / baseImageURI)
        address eligibility; // module or account authoritative for wearer eligibility/standing
        address toggle; // module or account authoritative for active status
        uint32 maxSupply; // maximum concurrent wearers (0 => hat not created)
        uint32 supply; // current concurrent wearers
        uint16 lastHatId; // number of children created under this hat
        bool mutable_; // whether admin may still mutate this hat
        bool active; // stored active status (fallback when toggle is not a live module)
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Upper bound on `details`/`imageURI` byte-length; guards `uri()`/`viewHat()`
    ///         against an admin inflating strings until reads exceed the block gas limit.
    uint256 internal constant MAX_STRING_LENGTH = 7000;

    /// @notice ERC-165 interface id for ERC-1155.
    bytes4 internal constant INTERFACE_ID_ERC1155 = 0xd9b67a26;

    /// @notice ERC-165 interface id for ERC-1155 metadata URI extension.
    bytes4 internal constant INTERFACE_ID_ERC1155_METADATA = 0x0e89341c;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice hatId => Hat.
    mapping(uint256 => Hat) internal _hats;

    /// @notice hatId => wearer => static (minted) balance flag.
    mapping(uint256 => mapping(address => bool)) internal _staticBalanceOf;

    /// @notice hatId => wearer => BAD standing flag (true == in bad standing).
    mapping(uint256 => mapping(address => bool)) public badStandings;

    /// @notice The most recently created top-hat domain (0 before any exist).
    uint32 public lastTopHatId;

    /// @notice Fallback base image URI for hats without an explicit or inherited image.
    string public baseImageURI;

    /*//////////////////////////////////////////////////////////////
                            ERC-1155 EVENTS
    //////////////////////////////////////////////////////////////*/
    // Declared here because the vendored `HatsEvents` covers only hat-specific events; the
    // ERC-1155 token events belong to the ERC-1155 surface this protocol implements.

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TransferBatch(
        address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values
    );
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Hats are soulbound; standard ERC-1155 transfers/approvals are disabled.
    ///         Role movement happens only through admin-gated `transferHat` / `transferRole`.
    error Soulbound();

    /// @notice An admin hat already has the maximum 65,535 direct children (uint16 child index),
    ///         so no further child can be created under it. Fail-closed to prevent the child
    ///         index wrapping to 0 (which, since `buildHatId(_admin, 0) == _admin`, would collide
    ///         with — and overwrite — the admin hat's own struct).
    error MaxHatsInLevelReached();

    /*//////////////////////////////////////////////////////////////
                              TOP HAT / CREATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHats
    function mintTopHat(address _target, string memory _details, string memory _imageURI)
        public
        returns (uint256 topHatId)
    {
        // new domain in [1 .. type(uint32).max]; ids are `domain << 224`.
        topHatId = uint256(++lastTopHatId) << 224;

        _createHat(
            topHatId,
            _details,
            1, // maxSupply
            address(0), // eligibility: top hat wearer is always eligible
            address(0), // toggle: top hat is always active
            false, // top hats are immutable
            _imageURI
        );

        _mintHat(_target, topHatId);
    }

    /// @inheritdoc IHats
    function createHat(
        uint256 _admin,
        string calldata _details,
        uint32 _maxSupply,
        address _eligibility,
        address _toggle,
        bool _mutable,
        string calldata _imageURI
    ) public returns (uint256 newHatId) {
        newHatId = _createHatChecked(_admin, _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI);
    }

    /// @dev Shared create path used by both `createHat` and `batchCreateHats` (DRY, one
    ///      authorization + validation implementation).
    function _createHatChecked(
        uint256 _admin,
        string memory _details,
        uint32 _maxSupply,
        address _eligibility,
        address _toggle,
        bool _mutable,
        string memory _imageURI
    ) internal returns (uint256 newHatId) {
        // the lowest 16-bit slot of `_admin` being set means it is already at level 14.
        if (uint16(_admin) != 0) revert MaxLevelsReached();
        if (_eligibility == address(0)) revert ZeroAddress();
        if (_toggle == address(0)) revert ZeroAddress();
        _checkStringLength(_details);
        _checkStringLength(_imageURI);

        newHatId = getNextId(_admin);

        // authority: caller must wear one of the new hat's admin hats.
        _checkAdmin(newHatId);

        _createHat(newHatId, _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI);

        // safe: lastHatId is uint16 and buildHatId already refused to overflow the level.
        unchecked {
            ++_hats[_admin].lastHatId;
        }
    }

    /// @inheritdoc IHats
    function batchCreateHats(
        uint256[] calldata _admins,
        string[] calldata _details,
        uint32[] calldata _maxSupplies,
        address[] memory _eligibilityModules,
        address[] memory _toggleModules,
        bool[] calldata _mutables,
        string[] calldata _imageURIs
    ) public returns (bool success) {
        uint256 length = _admins.length;
        if (
            length != _details.length || length != _maxSupplies.length || length != _eligibilityModules.length
                || length != _toggleModules.length || length != _mutables.length || length != _imageURIs.length
        ) {
            revert BatchArrayLengthMismatch();
        }

        for (uint256 i = 0; i < length;) {
            _createHatChecked(
                _admins[i],
                _details[i],
                _maxSupplies[i],
                _eligibilityModules[i],
                _toggleModules[i],
                _mutables[i],
                _imageURIs[i]
            );
            unchecked {
                ++i;
            }
        }
        success = true;
    }

    /// @inheritdoc IHats
    function getNextId(uint256 _admin) public view returns (uint256 nextId) {
        uint16 lastId = _hats[_admin].lastHatId;
        // fail-closed at the uint16 ceiling: without this, `lastId + 1` wraps to 0 and
        // `buildHatId(_admin, 0) == _admin`, so the next `createHat` would overwrite the admin
        // hat's own struct instead of creating a distinct child. Guarding here covers every
        // write path (createHat / batchCreateHats route through this) and the module's
        // termed-role `getNextId` read (which must revert when the level is full).
        if (lastId == type(uint16).max) revert MaxHatsInLevelReached();
        nextId = buildHatId(_admin, lastId + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                  MINTING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHats
    function mintHat(uint256 _hatId, address _wearer) public returns (bool success) {
        Hat storage hat = _hats[_hatId];
        if (hat.maxSupply == 0) revert HatDoesNotExist(_hatId);
        if (hat.supply >= hat.maxSupply) revert AllHatsWorn(_hatId);
        if (!isEligible(_wearer, _hatId)) revert NotEligible();
        if (!_isActive(hat, _hatId)) revert HatNotActive();
        if (_staticBalanceOf[_hatId][_wearer]) revert AlreadyWearingHat(_wearer, _hatId);

        // authority: caller must wear one of the hat's admin hats.
        _checkAdmin(_hatId);

        _mintHat(_wearer, _hatId);
        success = true;
    }

    /// @inheritdoc IHats
    function batchMintHats(uint256[] calldata _hatIds, address[] calldata _wearers) public returns (bool success) {
        uint256 length = _hatIds.length;
        if (length != _wearers.length) revert BatchArrayLengthMismatch();

        for (uint256 i = 0; i < length;) {
            mintHat(_hatIds[i], _wearers[i]);
            unchecked {
                ++i;
            }
        }
        success = true;
    }

    /*//////////////////////////////////////////////////////////////
                          TRANSFER / RENOUNCE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHats
    function transferHat(uint256 _hatId, address _from, address _to) public {
        _transferHat(_hatId, _from, _to);
    }

    /// @inheritdoc ILuxRoles
    /// @dev Frontend alias of `transferHat` (identical semantics, different selector).
    function transferRole(uint256 _roleId, address _from, address _to) public {
        _transferHat(_roleId, _from, _to);
    }

    /// @inheritdoc IHats
    function renounceHat(uint256 _hatId) public {
        if (!_staticBalanceOf[_hatId][msg.sender]) revert NotHatWearer();
        _burnHat(msg.sender, _hatId);
    }

    /*//////////////////////////////////////////////////////////////
                            TOGGLE (ACTIVE)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHats
    function setHatStatus(uint256 _hatId, bool _newStatus) external returns (bool toggled) {
        if (msg.sender != _hats[_hatId].toggle) revert NotHatsToggle();
        toggled = _processHatStatus(_hatId, _newStatus);
    }

    /// @inheritdoc IHats
    function checkHatStatus(uint256 _hatId) external returns (bool toggled) {
        Hat storage hat = _hats[_hatId];
        (bool success, bytes memory returndata) =
            hat.toggle.staticcall(abi.encodeWithSignature("getHatStatus(uint256)", _hatId));

        // only a live toggle module can drive an on-chain status refresh.
        if (!success || returndata.length < 32) revert NotHatsToggle();

        toggled = _processHatStatus(_hatId, abi.decode(returndata, (bool)));
    }

    /// @inheritdoc ILuxRoles
    function isActive(uint256 _hatId) external view returns (bool active) {
        active = _isActive(_hats[_hatId], _hatId);
    }

    /*//////////////////////////////////////////////////////////////
                        ELIGIBILITY / STANDING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHats
    function setHatWearerStatus(uint256 _hatId, address _wearer, bool _eligible, bool _standing)
        external
        returns (bool updated)
    {
        if (msg.sender != _hats[_hatId].eligibility) revert NotHatsEligibility();
        updated = _processHatWearerStatus(_hatId, _wearer, _eligible, _standing);
    }

    /// @inheritdoc IHats
    function checkHatWearerStatus(uint256 _hatId, address _wearer) external returns (bool updated) {
        (bool success, bytes memory returndata) = _hats[_hatId].eligibility
            .staticcall(abi.encodeWithSignature("getWearerStatus(address,uint256)", _wearer, _hatId));

        // only a live eligibility module can drive an on-chain wearer-status refresh.
        if (!success || returndata.length < 64) revert NotHatsEligibility();

        (bool eligible, bool standing) = abi.decode(returndata, (bool, bool));
        updated = _processHatWearerStatus(_hatId, _wearer, eligible, standing);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN MUTATORS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHats
    function makeHatImmutable(uint256 _hatId) external {
        _checkAdmin(_hatId);
        Hat storage hat = _hats[_hatId];
        if (!hat.mutable_) revert Immutable();
        hat.mutable_ = false;
        emit HatMutabilityChanged(_hatId);
    }

    /// @inheritdoc IHats
    function changeHatDetails(uint256 _hatId, string memory _newDetails) external {
        _checkStringLength(_newDetails);
        _checkAdmin(_hatId);
        Hat storage hat = _hats[_hatId];
        // top hats may always relabel themselves; other hats must be mutable.
        if (!hat.mutable_ && !isTopHat(_hatId)) revert Immutable();
        hat.details = _newDetails;
        emit HatDetailsChanged(_hatId, _newDetails);
    }

    /// @inheritdoc IHats
    function changeHatEligibility(uint256 _hatId, address _newEligibility) external {
        if (_newEligibility == address(0)) revert ZeroAddress();
        _checkAdmin(_hatId);
        Hat storage hat = _hats[_hatId];
        if (!hat.mutable_) revert Immutable();
        hat.eligibility = _newEligibility;
        emit HatEligibilityChanged(_hatId, _newEligibility);
    }

    /// @inheritdoc IHats
    function changeHatToggle(uint256 _hatId, address _newToggle) external {
        if (_newToggle == address(0)) revert ZeroAddress();
        _checkAdmin(_hatId);
        Hat storage hat = _hats[_hatId];
        if (!hat.mutable_) revert Immutable();
        hat.toggle = _newToggle;
        emit HatToggleChanged(_hatId, _newToggle);
    }

    /// @inheritdoc IHats
    function changeHatImageURI(uint256 _hatId, string memory _newImageURI) external {
        _checkStringLength(_newImageURI);
        _checkAdmin(_hatId);
        Hat storage hat = _hats[_hatId];
        if (!hat.mutable_ && !isTopHat(_hatId)) revert Immutable();
        hat.imageURI = _newImageURI;
        emit HatImageURIChanged(_hatId, _newImageURI);
    }

    /// @inheritdoc IHats
    function changeHatMaxSupply(uint256 _hatId, uint32 _newMaxSupply) external {
        _checkAdmin(_hatId);
        Hat storage hat = _hats[_hatId];
        if (!hat.mutable_) revert Immutable();
        if (_newMaxSupply < hat.supply) revert NewMaxSupplyTooLow();
        hat.maxSupply = _newMaxSupply;
        emit HatMaxSupplyChanged(_hatId, _newMaxSupply);
    }

    /*//////////////////////////////////////////////////////////////
                             TREE LINKING
    //////////////////////////////////////////////////////////////*/
    //
    // Mutual-consent grafting of one top hat under another tree's admin hat. Safe by
    // construction: `request*` is gated to the top hat's own wearer (you may only OFFER your
    // own tree), and `approve*` is gated to an admin of the target admin hat AND a matching
    // outstanding request (the receiver must ACCEPT). No unilateral authority is transferable.

    /// @inheritdoc IHats
    function requestLinkTopHatToTree(uint32 _topHatId, uint256 _newAdminHat) external {
        uint256 fullTopHat = uint256(_topHatId) << 224;
        _checkAdmin(fullTopHat);
        linkedTreeRequests[fullTopHat] = _newAdminHat;
        emit TopHatLinkRequested(_topHatId, _newAdminHat);
    }

    /// @inheritdoc IHats
    function approveLinkTopHatToTree(
        uint32 _topHatId,
        uint256 _newAdminHat,
        address _eligibility,
        address _toggle,
        string calldata _details,
        string calldata _imageURI
    ) external {
        // the receiving side must be an admin of the destination admin hat.
        _checkAdmin(_newAdminHat);

        uint256 fullTopHat = uint256(_topHatId) << 224;

        // the offering side must have requested exactly this linkage.
        if (linkedTreeRequests[fullTopHat] != _newAdminHat) revert LinkageNotRequested();
        // must not create a cycle.
        if (!noCircularLinkage(_topHatId, _newAdminHat)) revert CircularLinkage();

        delete linkedTreeRequests[fullTopHat];
        linkedTreeAdmins[fullTopHat] = _newAdminHat;

        // the top hat is now a linked (non-top) hat: give it real modules/metadata.
        _updateLinkedHat(fullTopHat, _eligibility, _toggle, _details, _imageURI);

        emit TopHatLinked(_topHatId, _newAdminHat);
    }

    /// @inheritdoc IHats
    function unlinkTopHatFromTree(uint32 _topHatId, address _wearer) external {
        uint256 fullTopHat = uint256(_topHatId) << 224;
        _checkAdmin(fullTopHat);

        // never brick a tophat: it must have a live wearer to return to standalone status.
        if (!isWearerOfHat(_wearer, fullTopHat)) revert InvalidUnlink();

        delete linkedTreeAdmins[fullTopHat];
        delete linkedTreeRequests[fullTopHat];

        // restore standalone top-hat semantics (always active, wearer always eligible).
        Hat storage hat = _hats[fullTopHat];
        hat.eligibility = address(0);
        hat.toggle = address(0);
        hat.active = true;

        emit TopHatLinked(_topHatId, 0);
    }

    /// @inheritdoc IHats
    function relinkTopHatWithinTree(
        uint32 _topHatDomain,
        uint256 _newAdminHat,
        address _eligibility,
        address _toggle,
        string calldata _details,
        string calldata _imageURI
    ) external {
        uint256 fullTopHat = uint256(_topHatDomain) << 224;
        _checkAdmin(fullTopHat);

        // may only move within the same super-tree, and never into a cycle.
        if (linkedTreeAdmins[fullTopHat] == 0) revert LinkageNotRequested();
        if (!sameTippyTopHatDomain(_topHatDomain, _newAdminHat)) revert CrossTreeLinkage();
        if (!noCircularLinkage(_topHatDomain, _newAdminHat)) revert CircularLinkage();

        linkedTreeAdmins[fullTopHat] = _newAdminHat;
        _updateLinkedHat(fullTopHat, _eligibility, _toggle, _details, _imageURI);

        emit TopHatLinked(_topHatDomain, _newAdminHat);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHats
    function viewHat(uint256 _hatId)
        external
        view
        returns (
            string memory details,
            uint32 maxSupply,
            uint32 supply,
            address eligibility,
            address toggle,
            string memory imageURI,
            uint16 lastHatId,
            bool mutable_,
            bool active
        )
    {
        Hat storage hat = _hats[_hatId];
        details = hat.details;
        maxSupply = hat.maxSupply;
        supply = hat.supply;
        eligibility = hat.eligibility;
        toggle = hat.toggle;
        imageURI = getImageURIForHat(_hatId);
        lastHatId = hat.lastHatId;
        mutable_ = hat.mutable_;
        active = _isActive(hat, _hatId);
    }

    /// @inheritdoc IHats
    function isWearerOfHat(address _user, uint256 _hatId) public view returns (bool isWearer) {
        isWearer = balanceOf(_user, _hatId) > 0;
    }

    /// @inheritdoc IHats
    function isAdminOfHat(address _user, uint256 _hatId) public view returns (bool isAdmin) {
        uint256 hatId = _hatId;
        uint256 linkedTreeAdmin;
        uint32 adminLocalHatLevel;

        if (isLocalTopHat(hatId)) {
            linkedTreeAdmin = linkedTreeAdmins[uint256(getTopHatDomain(hatId)) << 224];
            if (linkedTreeAdmin == 0) {
                // an unlinked top hat is admin'd only by its own wearer.
                return isWearerOfHat(_user, hatId);
            }
            // a linked top hat is admin'd via its linked admin hat.
            adminLocalHatLevel = getLocalHatLevel(linkedTreeAdmin);
            hatId = linkedTreeAdmin;
        } else {
            adminLocalHatLevel = getLocalHatLevel(hatId);
        }

        // walk this local tree from the hat's parent up toward its local top hat.
        while (adminLocalHatLevel > 0) {
            if (isWearerOfHat(_user, getAdminAtLocalLevel(hatId, adminLocalHatLevel - 1))) {
                return true;
            }
            unchecked {
                --adminLocalHatLevel;
            }
        }

        // local top hat.
        isAdmin = isWearerOfHat(_user, getAdminAtLocalLevel(hatId, 0));
        if (isAdmin) return true;

        // recurse up the linked parent tree, if any.
        linkedTreeAdmin = linkedTreeAdmins[uint256(getTopHatDomain(hatId)) << 224];
        if (linkedTreeAdmin != 0) {
            isAdmin = isAdminOfHat(_user, linkedTreeAdmin);
        }
    }

    /// @inheritdoc IHats
    function isInGoodStanding(address _wearer, uint256 _hatId) public view returns (bool standing) {
        (bool success, bytes memory returndata) = _hats[_hatId].eligibility
            .staticcall(abi.encodeWithSignature("getWearerStatus(address,uint256)", _wearer, _hatId));
        if (success && returndata.length >= 64) {
            (, standing) = abi.decode(returndata, (bool, bool));
        } else {
            standing = !badStandings[_hatId][_wearer];
        }
    }

    /// @inheritdoc IHats
    function isEligible(address _wearer, uint256 _hatId) public view returns (bool eligible) {
        eligible = _isEligible(_hatId, _hats[_hatId], _wearer);
    }

    /// @inheritdoc IHats
    function getHatEligibilityModule(uint256 _hatId) external view returns (address eligibility) {
        eligibility = _hats[_hatId].eligibility;
    }

    /// @inheritdoc IHats
    function getHatToggleModule(uint256 _hatId) external view returns (address toggle) {
        toggle = _hats[_hatId].toggle;
    }

    /// @inheritdoc IHats
    function getHatMaxSupply(uint256 _hatId) external view returns (uint32 maxSupply) {
        maxSupply = _hats[_hatId].maxSupply;
    }

    /// @inheritdoc IHats
    function hatSupply(uint256 _hatId) external view returns (uint32 supply) {
        supply = _hats[_hatId].supply;
    }

    /// @inheritdoc IHats
    function getImageURIForHat(uint256 _hatId) public view returns (string memory _uri) {
        Hat storage hat = _hats[_hatId];
        if (bytes(hat.imageURI).length != 0) return hat.imageURI;

        // inherit the nearest ancestor's image, walking up admins.
        uint32 level = getHatLevel(_hatId);
        for (uint32 i = level; i > 0;) {
            uint256 adminId = getAdminAtLevel(_hatId, i - 1);
            string storage adminURI = _hats[adminId].imageURI;
            if (bytes(adminURI).length != 0) return adminURI;
            unchecked {
                --i;
            }
        }
        return baseImageURI;
    }

    /*//////////////////////////////////////////////////////////////
                         ERC-1155 (SOULBOUND)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHats
    function balanceOf(address _wearer, uint256 _hatId) public view returns (uint256 balance) {
        Hat storage hat = _hats[_hatId];
        if (_isActive(hat, _hatId) && _isEligible(_hatId, hat, _wearer) && _staticBalanceOf[_hatId][_wearer]) {
            balance = 1;
        }
    }

    /// @inheritdoc IHats
    function balanceOfBatch(address[] calldata _wearers, uint256[] calldata _hatIds)
        external
        view
        returns (uint256[] memory balances)
    {
        if (_wearers.length != _hatIds.length) revert BatchArrayLengthMismatch();
        balances = new uint256[](_wearers.length);
        for (uint256 i = 0; i < _wearers.length;) {
            balances[i] = balanceOf(_wearers[i], _hatIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IHats
    function uri(uint256 id) external view returns (string memory _uri) {
        // The Lux DAO app reads rich hat metadata off-chain (subgraph). On-chain we return the
        // resolved image URI, which is the only field consumed on-chain. Complete and correct
        // for its consumers; a full JSON metadata document is intentionally not assembled here.
        _uri = getImageURIForHat(id);
    }

    /// @notice Hats are soulbound: wearers cannot transfer or approve them. Reverts.
    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external pure {
        revert Soulbound();
    }

    /// @notice Hats are soulbound: wearers cannot transfer or approve them. Reverts.
    function safeBatchTransferFrom(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
    {
        revert Soulbound();
    }

    /// @notice Hats are soulbound: wearers cannot delegate approval. Reverts.
    function setApprovalForAll(address, bool) external pure {
        revert Soulbound();
    }

    /// @notice Soulbound tokens are never operator-approved.
    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == INTERFACE_ID_ERC1155 || interfaceId == INTERFACE_ID_ERC1155_METADATA
            || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function _createHat(
        uint256 _id,
        string memory _details,
        uint32 _maxSupply,
        address _eligibility,
        address _toggle,
        bool _mutable,
        string memory _imageURI
    ) internal {
        Hat storage hat = _hats[_id];
        hat.details = _details;
        hat.maxSupply = _maxSupply;
        hat.eligibility = _eligibility;
        hat.toggle = _toggle;
        hat.imageURI = _imageURI;
        hat.mutable_ = _mutable;
        hat.active = true;

        emit HatCreated(_id, _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI);
    }

    function _mintHat(address _wearer, uint256 _hatId) internal {
        unchecked {
            // mintHat enforces supply < maxSupply (both uint32) before calling.
            ++_hats[_hatId].supply;
        }
        _staticBalanceOf[_hatId][_wearer] = true;
        emit TransferSingle(msg.sender, address(0), _wearer, _hatId, 1);
    }

    function _burnHat(address _wearer, uint256 _hatId) internal {
        _staticBalanceOf[_hatId][_wearer] = false;
        unchecked {
            // only called when the wearer currently holds the hat, so supply > 0.
            --_hats[_hatId].supply;
        }
        emit TransferSingle(msg.sender, _wearer, address(0), _hatId, 1);
    }

    function _transferHat(uint256 _hatId, address _from, address _to) internal {
        _checkAdmin(_hatId);
        Hat storage hat = _hats[_hatId];

        // immutable non-top hats cannot be moved; top hats always can (DAO handoff).
        if (!isTopHat(_hatId) && !hat.mutable_) revert Immutable();
        // check stored balance (not dynamic) so admins can re-home revoked hats.
        if (!_staticBalanceOf[_hatId][_from]) revert NotHatWearer();
        if (_staticBalanceOf[_hatId][_to]) revert AlreadyWearingHat(_to, _hatId);
        if (!_isEligible(_hatId, hat, _to)) revert NotEligible();

        _staticBalanceOf[_hatId][_from] = false;
        _staticBalanceOf[_hatId][_to] = true;
        emit TransferSingle(msg.sender, _from, _to, _hatId, 1);
    }

    function _processHatStatus(uint256 _hatId, bool _newStatus) internal returns (bool updated) {
        Hat storage hat = _hats[_hatId];
        if (_newStatus != hat.active) {
            hat.active = _newStatus;
            emit HatStatusChanged(_hatId, _newStatus);
            updated = true;
        }
    }

    function _processHatWearerStatus(uint256 _hatId, address _wearer, bool _eligible, bool _standing)
        internal
        returns (bool updated)
    {
        // revoke (burn) the hat if the wearer is no longer eligible or lost standing.
        if ((!_eligible || !_standing) && _staticBalanceOf[_hatId][_wearer]) {
            _burnHat(_wearer, _hatId);
            updated = true;
        }
        // record a standing change (badStandings stores the inverse of good standing).
        if (_standing == badStandings[_hatId][_wearer]) {
            badStandings[_hatId][_wearer] = !_standing;
            emit WearerStandingChanged(_hatId, _wearer, _standing);
            updated = true;
        }
    }

    function _updateLinkedHat(
        uint256 _fullTopHat,
        address _eligibility,
        address _toggle,
        string calldata _details,
        string calldata _imageURI
    ) internal {
        Hat storage hat = _hats[_fullTopHat];
        if (_eligibility != address(0)) hat.eligibility = _eligibility;
        if (_toggle != address(0)) hat.toggle = _toggle;
        if (bytes(_details).length != 0) {
            _checkStringLength(_details);
            hat.details = _details;
        }
        if (bytes(_imageURI).length != 0) {
            _checkStringLength(_imageURI);
            hat.imageURI = _imageURI;
        }
    }

    function _checkAdmin(uint256 _hatId) internal view {
        if (!isAdminOfHat(msg.sender, _hatId)) revert NotAdmin(msg.sender, _hatId);
    }

    function _checkStringLength(string memory _str) internal pure {
        if (bytes(_str).length > MAX_STRING_LENGTH) revert StringTooLong();
    }

    /// @dev Active status: prefer a live toggle module's answer, else fall back to stored flag.
    ///      A call to an EOA / address(0) / contract without `getHatStatus` returns no 32-byte
    ///      word, so the stored `active` flag governs (top hats & EOA-toggled hats stay active).
    function _isActive(Hat storage _hat, uint256 _hatId) internal view returns (bool active) {
        (bool success, bytes memory returndata) =
            _hat.toggle.staticcall(abi.encodeWithSignature("getHatStatus(uint256)", _hatId));
        if (success && returndata.length >= 32) {
            active = abi.decode(returndata, (bool));
        } else {
            active = _hat.active;
        }
    }

    /// @dev Eligibility (including good standing): prefer a live eligibility module, else fall
    ///      back to stored standing. A wearer is eligible only if BOTH eligible AND in standing.
    function _isEligible(uint256 _hatId, Hat storage _hat, address _wearer) internal view returns (bool eligible) {
        (bool success, bytes memory returndata) =
            _hat.eligibility.staticcall(abi.encodeWithSignature("getWearerStatus(address,uint256)", _wearer, _hatId));
        if (success && returndata.length >= 64) {
            bool standing;
            (eligible, standing) = abi.decode(returndata, (bool, bool));
            // never eligible while in bad standing.
            eligible = eligible && standing;
        } else {
            eligible = !badStandings[_hatId][_wearer];
        }
    }
}
