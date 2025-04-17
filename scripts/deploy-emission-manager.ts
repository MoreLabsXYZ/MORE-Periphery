import { ethers } from "hardhat";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with the account:", deployer.address);
    const EmissionManager = await ethers.getContractFactory("EmissionManager");
    const emissionManager = await EmissionManager.deploy(deployer.address);

    await emissionManager.deployed();

    console.log(
        `EmissionManager deployed to ${emissionManager.address}`
    );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
