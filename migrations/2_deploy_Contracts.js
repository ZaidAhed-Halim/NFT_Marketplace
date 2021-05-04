const Nft_Marketplace = artifacts.require("Nft_Marketplace");

module.exports = function (deployer) {
  deployer.deploy(Nft_Marketplace);
};
