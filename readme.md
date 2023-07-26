# My Own "Awesome Solidity", what I've learned so far :)

Here is a collection of fun ideas/contract templates I've put together throughout my time learning solidity.

1. token/ERC1155OtherchainERC20QRNGMint - A silly overkill NFT that mints ERC1155 of 2 tiers based on an url(Airnode QRNG)[https://docs.api3.org/reference/qrng/] and allows for communication with an ERC20 on another Hyperlane-compatible chain.

---

## Notes on Building

For (1):

Had to download v1 branch of hyperlane to add in compatability. to add this, download the zip file here https://github.com/hyperlane-xyz/hyperlane-monorepo/tree/v1 and extract into a file called "lib-local" in the project root
