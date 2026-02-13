#!/usr/bin/env node
/**
 * Generate ABIs from compiled artifacts
 */

import * as fs from 'fs';
import * as path from 'path';

const ARTIFACTS_DIR = path.join(__dirname, '..', 'artifacts', 'contracts');
const OUTPUT_FILE = path.join(__dirname, '..', 'publish', 'abis.ts');

// Contracts to export
const CONTRACTS = [
  // Modules
  'deployables/modules/ModuleGovernorV1.sol/ModuleGovernorV1',
  'deployables/modules/ModuleFractalV1.sol/ModuleFractalV1',

  // Strategies
  'deployables/strategies/StrategyV1.sol/StrategyV1',
  'deployables/strategies/voting-weight/VotingWeightERC20V1.sol/VotingWeightERC20V1',
  'deployables/strategies/voting-weight/VotingWeightERC721V1.sol/VotingWeightERC721V1',
  'deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol/VoteTrackerERC20V1',
  'deployables/strategies/vote-trackers/VoteTrackerERC721V1.sol/VoteTrackerERC721V1',
  'deployables/strategies/proposer-adapters/ProposerAdapterERC20V1.sol/ProposerAdapterERC20V1',
  'deployables/strategies/proposer-adapters/ProposerAdapterHatsV1.sol/ProposerAdapterHatsV1',
  'deployables/strategies/proposer-adapters/ProposerAdapterERC721V1.sol/ProposerAdapterERC721V1',

  // Freeze Guard
  'deployables/freeze-guard/FreezeGuardGovernorV1.sol/FreezeGuardGovernorV1',
  'deployables/freeze-guard/FreezeGuardMultisigV1.sol/FreezeGuardMultisigV1',

  // Freeze Voting
  'deployables/freeze-voting/FreezeVotingGovernorV1.sol/FreezeVotingGovernorV1',
  'deployables/freeze-voting/FreezeVotingMultisigV1.sol/FreezeVotingMultisigV1',
  'deployables/freeze-voting/FreezeVotingStandaloneV1.sol/FreezeVotingStandaloneV1',

  // ERC20 Tokens
  'deployables/erc20/VotesERC20V1.sol/VotesERC20V1',
  'deployables/erc20/VotesERC20StakedV1.sol/VotesERC20StakedV1',

  // Account Abstraction
  'deployables/account-abstraction/PaymasterV1.sol/PaymasterV1',

  // Other
  'deployables/autonomous-admin/AutonomousAdminV1.sol/AutonomousAdminV1',
  'deployables/countersign/CountersignV1.sol/CountersignV1',
  'deployables/public-sale/PublicSaleV1.sol/PublicSaleV1',
];

function generateAbis() {
  const abis: Record<string, unknown[]> = {};

  for (const contractPath of CONTRACTS) {
    const fullPath = path.join(ARTIFACTS_DIR, contractPath + '.json');
    const contractName = path.basename(contractPath);

    try {
      const artifact = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
      abis[contractName] = artifact.abi;
      console.log(`  ${contractName}`);
    } catch (e) {
      console.error(`  [SKIP] ${contractName}: ${(e as Error).message}`);
    }
  }

  const output = `// Auto-generated from compiled contracts
// Do not edit manually

export default ${JSON.stringify(abis, null, 2)} as const;
`;

  fs.writeFileSync(OUTPUT_FILE, output);
  console.log(`\nGenerated ${OUTPUT_FILE}`);
}

generateAbis();
