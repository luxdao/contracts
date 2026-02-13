import hre from 'hardhat';

async function main() {
  console.log("HRE keys:", Object.keys(hre));
  console.log("HRE network:", hre.network);
  console.log("HRE ethers?:", typeof hre.ethers);
  if (hre.ethers) {
    console.log("Ethers keys:", Object.keys(hre.ethers));
  }
}

main().catch(console.error);
