import { writeFileSync } from "node:fs";
import hre from "hardhat";

async function main() {
  console.log("🚀 Minimal contract deployment for testing...");

  const { ethers } = await hre.network.connect();
  const [deployer] = await ethers.getSigners();
  console.log("📍 Deploying with account:", deployer.address);

  try {
    // Deploy a simple test contract
    console.log("\n📦 Deploying KeyValuePairs...");
    const KeyValuePairs = await ethers.getContractFactory("KeyValuePairs");
    const keyValuePairs = await KeyValuePairs.deploy();
    await keyValuePairs.waitForDeployment();
    const kvAddress = await keyValuePairs.getAddress();
    console.log("   ✅ KeyValuePairs deployed to:", kvAddress);

    // Save minimal deployment info
    const deploymentInfo = {
      KeyValuePairs: { address: kvAddress },
      network: "localhost",
      timestamp: new Date().toISOString()
    };
    
    writeFileSync(
      "./deployments/localhost.json",
      JSON.stringify(deploymentInfo, null, 2)
    );
    
    console.log("\n✅ Minimal deployment complete!");
    console.log("📄 Deployment info saved to deployments/localhost.json");
    
  } catch (error) {
    console.error("❌ Deployment error:", error);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });