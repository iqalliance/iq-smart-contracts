// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./IEnterprise.sol";

interface IPowerTokenStorage {
    function initialize(
        IEnterprise enterprise,
        uint112 baseRate,
        uint96 minGCFee,
        uint32 energyGapHalvingPeriod,
        uint16 index,
        IERC20Metadata baseToken
    ) external;

    function initialize2(
        uint32 minRentalPeriod,
        uint32 maxRentalPeriod,
        uint16 serviceFeePercent,
        bool swappingEnabled
    ) external;

    function isAllowedRentalPeriod(uint32 period) external view returns (bool);

    function getIndex() external view returns (uint16);

    function isSwappingEnabled() external view returns (bool);

    function isTransferEnabled() external view returns (bool);
}
