import hre from 'hardhat';

async function main() {
  console.log("Connecting to network...");
  const connection = await hre.network.connect();
  console.log("Connection keys:", Object.keys(connection));
  console.log("Provider?:", typeof connection.provider);
  
  if (connection.provider) {
    const accounts = await connection.provider.request({
      method: 'eth_accounts',
      params: []
    });
    console.log("Accounts:", accounts);
  }
}

main().catch(console.error);
