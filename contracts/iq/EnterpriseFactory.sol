// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.7.6;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IEnterprise.sol";

contract EnterpriseFactory {
    using Clones for address;

    event EnterpriseDeployed(address indexed liquidityToken, string name, string baseUrl, address deployed);

    address public immutable powerTokenImpl;
    address public immutable interestTokenImpl;
    address public immutable enterpriseImpl;

    constructor(
        address _powerTokenImpl,
        address _interestTokenImpl,
        address _enterpriseImpl
    ) {
        require(_powerTokenImpl != address(0), "Invalid PowerToken address");
        require(_interestTokenImpl != address(0), "Invalid InterestToken address");
        require(_enterpriseImpl != address(0), "Invalid Enterprise address");
        powerTokenImpl = _powerTokenImpl;
        interestTokenImpl = _interestTokenImpl;
        enterpriseImpl = _enterpriseImpl;
    }

    function deploy(
        string calldata name,
        address liquidityToken,
        string calldata baseUrl
    ) external {
        IEnterprise enterprise = IEnterprise(enterpriseImpl.clone());
        enterprise.initialize(name, liquidityToken, baseUrl, interestTokenImpl, powerTokenImpl);

        emit EnterpriseDeployed(liquidityToken, name, baseUrl, address(enterprise));
    }
}
