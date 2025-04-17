import { ethers } from "hardhat";

async function main() {
    const incentivesController = "";
    const rewardsAdmin = "0xF6Bf91CB6219f20EaA420255Da1468f157c81517";
    const rewardsVault = "0xF6Bf91CB6219f20EaA420255Da1468f157c81517";

    if (!incentivesController || !rewardsAdmin || !rewardsVault) {
        console.error("Please set the incentivesController, rewardsAdmin, and rewardsVault addresses.");
        return;
    }

    const PullRewardsTransferStrategy = await ethers.getContractFactory("PullRewardsTransferStrategy");
    const pullRewardsTransferStrategy = await PullRewardsTransferStrategy.deploy(
        incentivesController,
        rewardsAdmin,
        rewardsVault
    );

    await pullRewardsTransferStrategy.deployed();

    console.log(
        `PullRewardsTransferStrategy deployed to ${pullRewardsTransferStrategy.address}`
    );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
