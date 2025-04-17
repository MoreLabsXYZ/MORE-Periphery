import { ethers } from "hardhat";

async function main() {
    const emissionManager = "";

    if (!emissionManager) {
        console.error("Please set the emissionManager address.");
        return;
    }

    const RewardsController = await ethers.getContractFactory("RewardsController");
    const rewardsController = await RewardsController.deploy(emissionManager);

    await rewardsController.deployed();

    console.log(
        `RewardsController Implementation deployed to ${rewardsController.address}`
    );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
