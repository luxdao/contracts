// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

/**
 * @title L3Registry
 * @author Hanzo AI Inc / Zoo Labs Foundation
 * @notice The canonical on-chain directory of model-zoo L3s, deployed on the
 * \emph{Zoo L2} EVM (the hub). Each community that launches a Thinking-Chain L3
 * (Beluga and its peers) registers it here, so the Zoo meta-DAO and \texttt{zoo.vote}
 * can discover, display, and endorse every L3 from one place. The hub records
 * and endorses; the L3 chain itself is created via the P-Chain
 * (\texttt{lux chain create --type=l3}) and runs its own sovereign
 * thinking-governance stack (ThinkingGovernor, ProofOfThoughtRegistry,
 * ThinkingChainObservatory, ThinkingReputation) on its own ledger.
 *
 * @dev Orthogonal by design: this is a pure directory. It holds no L3 state and
 * never reaches into an L3's governance; it stores the pointer (chainId + that
 * L3's governor/observatory addresses + metadata) that makes the L3 findable and,
 * if the Zoo DAO chooses, endorsed. Registration is permissionless (anyone may
 * list an L3); endorsement is gated to the Zoo DAO (the registry owner), so the
 * directory is open but the "official" set is curated.
 */
contract L3Registry {
    struct L3 {
        string name; //          e.g. "Beluga"
        uint256 chainId; //      the L3's EVM chain id
        address governor; //     the L3's ThinkingGovernor
        address observatory; //  the L3's ThinkingChainObservatory
        address registrar; //    who registered it
        string metadataURI; //   off-chain metadata (logo, description, rpc, token)
        uint64 registeredAt; //  block timestamp
        bool endorsed; //        recognized by the Zoo DAO
    }

    address public zooDAO; // endorsement authority (the Zoo meta-DAO / owner)

    mapping(bytes32 => L3) private _l3; //        id => record
    mapping(uint256 => bytes32) public byChainId; // chainId => id (one L3 per chain)
    bytes32[] private _ids; //                    enumeration

    event L3Registered(bytes32 indexed id, string name, uint256 indexed chainId, address governor, address registrar);
    event L3Endorsed(bytes32 indexed id, bool endorsed);
    event ZooDAOTransferred(address indexed from, address indexed to);

    error AlreadyRegistered(uint256 chainId);
    error UnknownL3(bytes32 id);
    error NotZooDAO();
    error ZeroChainId();

    constructor(address zooDAO_) {
        zooDAO = zooDAO_ == address(0) ? msg.sender : zooDAO_;
    }

    /// @notice The deterministic id for an L3 (keyed by chainId, the one thing
    /// that is globally unique and permanent for a chain).
    function idOf(uint256 chainId) public pure returns (bytes32) {
        return keccak256(abi.encode("zoo/l3", chainId));
    }

    /// @notice Register a model-zoo L3 in the hub directory. Permissionless;
    /// one record per chainId (re-registration of the same chain reverts).
    function register(
        string calldata name,
        uint256 chainId,
        address governor,
        address observatory,
        string calldata metadataURI
    ) external returns (bytes32 id) {
        if (chainId == 0) revert ZeroChainId();
        id = idOf(chainId);
        if (byChainId[chainId] != bytes32(0)) revert AlreadyRegistered(chainId);
        _l3[id] = L3({
            name: name,
            chainId: chainId,
            governor: governor,
            observatory: observatory,
            registrar: msg.sender,
            metadataURI: metadataURI,
            registeredAt: uint64(block.timestamp),
            endorsed: false
        });
        byChainId[chainId] = id;
        _ids.push(id);
        emit L3Registered(id, name, chainId, governor, msg.sender);
    }

    /// @notice Endorse (or un-endorse) an L3 as part of the official Zoo set.
    function endorse(bytes32 id, bool endorsed) external {
        if (msg.sender != zooDAO) revert NotZooDAO();
        if (_l3[id].chainId == 0) revert UnknownL3(id);
        _l3[id].endorsed = endorsed;
        emit L3Endorsed(id, endorsed);
    }

    /// @notice Hand the endorsement authority to the Zoo DAO contract.
    function transferZooDAO(address to) external {
        if (msg.sender != zooDAO) revert NotZooDAO();
        emit ZooDAOTransferred(zooDAO, to);
        zooDAO = to;
    }

    // ---- views: the directory zoo.vote reads -------------------------------
    function get(bytes32 id) external view returns (L3 memory) {
        if (_l3[id].chainId == 0) revert UnknownL3(id);
        return _l3[id];
    }

    function getByChainId(uint256 chainId) external view returns (L3 memory) {
        return _l3[idOf(chainId)];
    }

    function count() external view returns (uint256) {
        return _ids.length;
    }

    function at(uint256 index) external view returns (bytes32) {
        return _ids[index];
    }
}
