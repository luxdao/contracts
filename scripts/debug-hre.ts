import hre from 'hardhat';

async function main() {
  console.log('HRE keys:', Object.keys(hre));
  console.log('HRE network:', hre.network);

  // Hardhat 3 exposes ethers on a network connection, not on the HRE.
  const connection = await hre.network.connect();
  console.log('Connection ethers?:', typeof connection.ethers);
  console.log('Ethers keys:', Object.keys(connection.ethers));
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
