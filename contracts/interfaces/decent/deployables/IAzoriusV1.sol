// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

interface IAzoriusV1 {
    event ProposalCreated(
        address strategy,
        uint256 proposalId,
        address proposer,
        Transaction[] transactions,
        string metadata
    );
    event ProposalExecuted(uint32 proposalId, bytes32[] txHashes);
    event TimelockPeriodUpdated(uint32 timelockPeriod);
    event ExecutionPeriodUpdated(uint32 executionPeriod);
    event StrategyUpdated(address strategy);

    error InvalidStrategy();
    error InvalidProposal();
    error InvalidProposer();
    error ProposalNotExecutable();
    error InvalidTxHash();
    error TxFailed();
    error InvalidTxs();
    error InvalidArrayLengths();

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        Enum.Operation operation;
    }

    struct Proposal {
        uint32 executionCounter;
        uint32 timelockPeriod;
        uint32 executionPeriod;
        address strategy;
        bytes32[] txHashes;
    }

    enum ProposalState {
        ACTIVE,
        TIMELOCKED,
        EXECUTABLE,
        EXECUTED,
        EXPIRED,
        FAILED
    }

    function initialize(
        address owner,
        address avatar,
        address target,
        address strategy,
        uint32 timelockPeriod,
        uint32 executionPeriod
    ) external;

    function totalProposalCount() external view returns (uint32);

    function timelockPeriod() external view returns (uint32);

    function executionPeriod() external view returns (uint32);

    function proposals(
        uint32 _proposalId
    ) external view returns (Proposal memory);

    function strategy() external view returns (address);

    function updateTimelockPeriod(uint32 _timelockPeriod) external;

    function updateExecutionPeriod(uint32 _executionPeriod) external;

    function updateStrategy(address _strategy) external;

    function submitProposal(
        Transaction[] calldata _transactions,
        string calldata _metadata,
        bytes memory _proposerData,
        bytes memory _proposalData
    ) external;

    function executeProposal(
        uint32 _proposalId,
        address[] memory _targets,
        uint256[] memory _values,
        bytes[] memory _data,
        Enum.Operation[] memory _operations
    ) external;

    function proposalState(
        uint32 _proposalId
    ) external view returns (ProposalState);

    function generateTxHashData(
        address _to,
        uint256 _value,
        bytes memory _data,
        Enum.Operation _operation,
        uint256 _nonce
    ) external view returns (bytes memory);

    function getTxHash(
        address _to,
        uint256 _value,
        bytes memory _data,
        Enum.Operation _operation
    ) external view returns (bytes32);

    function getProposalTxHash(
        uint32 _proposalId,
        uint32 _txIndex
    ) external view returns (bytes32);

    function getProposalTxHashes(
        uint32 _proposalId
    ) external view returns (bytes32[] memory);

    function getProposal(
        uint32 _proposalId
    )
        external
        view
        returns (
            address _strategy,
            bytes32[] memory _txHashes,
            uint32 _timelockPeriod,
            uint32 _executionPeriod,
            uint32 _executionCounter
        );
}
