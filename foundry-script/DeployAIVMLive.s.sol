// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {AIComputeRegistry} from "../contracts/deployables/thinking/AIComputeRegistry.sol";

/// A stand-in miner: a contract authorized to claim computations (claimers must be contracts).
contract MinerStub {
    AIComputeRegistry public reg;

    constructor(AIComputeRegistry r) {
        reg = r;
    }

    function mine(bytes32 model, bytes32 prompt, bytes32 output) external {
        reg.claim(reg.computationKey(model, prompt, output));
    }
}

/// Deploys the unified AIVM compute-claim ledger live and reconciles one AI computation through it.
contract DeployAIVMLive is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVKEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);
        AIComputeRegistry reg = new AIComputeRegistry(me); // the global ledger
        MinerStub miner = new MinerStub(reg);
        reg.setMiner(address(miner), true);
        miner.mine("zen-coder-flash", "what is 2+2", "4"); // the live AI-work claim
        vm.stopBroadcast();

        bytes32 key = reg.computationKey("zen-coder-flash", "what is 2+2", "4");
        console.log("AIComputeRegistry:", address(reg));
        console.log("MinerStub:", address(miner));
        console.log("claimed:", reg.isClaimed(key));
        console.log("claimedBy:", reg.claimedBy(key));
    }
}
