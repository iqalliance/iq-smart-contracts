// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./token/ERC721Enumerable.sol";
import "./interfaces/IBorrowTokenStorage.sol";
import "./interfaces/IEnterprise.sol";
import "./EnterpriseOwnable.sol";

abstract contract BorrowTokenStorage is EnterpriseOwnable, ERC721Enumerable, IBorrowTokenStorage {
    uint256 internal _tokenIdTracker;

    function initialize(
        string memory name,
        string memory symbol,
        IEnterprise enterprise
    ) external override {
        EnterpriseOwnable.initialize(enterprise);
        ERC721.initialize(name, symbol);
    }
}
