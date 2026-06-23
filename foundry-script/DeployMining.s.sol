// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {AICoin} from "../contracts/deployables/thinking/AICoin.sol";
import {AIReceiptRoots} from "../contracts/deployables/thinking/AIReceiptRoots.sol";
import {AICoinMiner, IAICoinMintable, IAIReceiptRootsView, IComputeVerifierM} from "../contracts/deployables/thinking/AICoinMiner.sol";
import {AttestationRootRegistry} from "../contracts/deployables/thinking/AttestationRootRegistry.sol";
import {ComputeVerifier} from "../contracts/deployables/thinking/ComputeVerifier.sol";
import {OptimisticEvidence} from "../contracts/deployables/thinking/evidence/OptimisticEvidence.sol";
import {ComputeProof, ComputeProofLib} from "../contracts/deployables/thinking/ComputeProofLib.sol";

/// @notice Deploy the AI-mining stack — NOW WITH THE COMPUTE-PROOF GATE — to ANY EVM and PROVE
/// it live with a real on-chain mint. Same bytecode + same pure-Solidity attestation
/// verification + same compute-proof binding on every chain. The receipt is built exactly as the
/// A-Chain builds it (cross-module golden-tested), and the optimistic compute proof is bonded and
/// its window left open (a watcher could still slash it) — so this end-to-end run exercises the
/// FULL "no valid compute proof → no mint" path, not just merkle inclusion.
///
/// Run: DEPLOYER_PK=0x.. NET_LABEL=lux-test \
///      forge script foundry-script/DeployMining.s.sol:DeployMining --rpc-url $RPC --broadcast
contract DeployMining is Script {
    bytes constant DOMAIN = "lux/aivmbridge/receipt/v1";
    uint256 constant GENESIS = 1_781_000_000;
    uint256 constant REWARD = 1000 ether; // 1000 AI per verified receipt
    uint256 constant MIN_BOND = 1 ether;
    uint64 constant CHALLENGE_WINDOW = 1 hours;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address dep = vm.addr(pk);
        string memory label = vm.envString("NET_LABEL");

        vm.startBroadcast(pk);

        // 1. deploy the stack: coin, receipt roots, registry, verifier, optimistic backend, miner
        AICoin coin = new AICoin("AICoin", "AI", dep, address(0), GENESIS);
        AIReceiptRoots roots = new AIReceiptRoots(dep);
        AttestationRootRegistry registry = new AttestationRootRegistry(dep);
        ComputeVerifier verifier = new ComputeVerifier(address(registry), dep);
        OptimisticEvidence optimistic = new OptimisticEvidence(MIN_BOND, CHALLENGE_WINDOW, address(registry));
        AICoinMiner miner = new AICoinMiner(
            IAICoinMintable(address(coin)),
            IAIReceiptRootsView(address(roots)),
            dep,
            REWARD,
            IComputeVerifierM(address(verifier))
        );

        // 2. wire mint seam, relayer, backend slot, and the governed measurements
        coin.setMinter(address(miner), true);
        roots.setRelayer(dep, true);
        verifier.setBackend(3, address(optimistic)); // optimistic backend in slot 3
        bytes32 modelSpec = keccak256(abi.encodePacked("model-spec/", label));
        bytes32 promptHash = keccak256(abi.encodePacked("prompt/", label));
        bytes32 runtime = keccak256(abi.encodePacked("runtime-temp0/", label));
        registry.setModelSpec(modelSpec, true);
        registry.setRuntime(runtime, true);

        // 3. a wire-correct A-Chain receipt bound to this deployer (now carrying the model spec,
        //    prompt, and a real output the compute proof will bind to)
        bytes32 intentID = keccak256(abi.encodePacked("intent/", label));
        bytes32 outputHash = keccak256(abi.encodePacked("output/", label));
        bytes memory receipt = abi.encodePacked(
            uint16(1), // Version
            intentID, // IntentID
            bytes32(0), // TaskID
            bytes32(0), // CChainID
            bytes32(0), // AChainID
            dep, // Requester (beneficiary)
            modelSpec, // ModelSpecHash
            promptHash, // PromptHash
            outputHash, // CanonicalOutputHash
            uint8(2), // Status = Completed
            uint16(5), // N
            uint16(3), // Threshold
            bytes32(0), // WinnersRoot
            bytes32(0), // OperatorsRoot
            bytes32(0), // FeePaid
            uint64(12345) // SettledAtHeight
        );
        bytes32 leaf = keccak256(abi.encodePacked(keccak256(abi.encodePacked(DOMAIN, receipt))));
        bytes memory proof = abi.encodePacked(leaf, uint64(0), uint16(0)); // single-leaf

        // 4. build + bond the compute proof (taskId 0, openBlockHash 0 for this single receipt)
        bytes32 reportData = ComputeProofLib.expectedReportData(
            0, intentID, modelSpec, promptHash, bytes32(0), dep, outputHash, runtime
        );
        optimistic.submit{value: MIN_BOND}(reportData, keccak256("activation-trace"), modelSpec);
        ComputeProof memory cp = ComputeProof({proofType: 3, reportData: reportData, evidence: ""});

        // 5. anchor the root + MINE (verify attestation + compute proof on-chain -> mint AICoin)
        roots.anchorRoot(leaf, 12345);
        uint256 amount = miner.mine(receipt, proof, cp, bytes32(0), runtime);

        vm.stopBroadcast();

        // 6. report (the runner greps these)
        console.log("LABEL", label);
        console.log("AICoin", address(coin));
        console.log("AIReceiptRoots", address(roots));
        console.log("AttestationRootRegistry", address(registry));
        console.log("ComputeVerifier", address(verifier));
        console.log("OptimisticEvidence", address(optimistic));
        console.log("AICoinMiner", address(miner));
        console.log("minted", amount);
        console.log("totalSupply", coin.totalSupply());
        console.log("balanceRequester", coin.balanceOf(dep));
    }
}
