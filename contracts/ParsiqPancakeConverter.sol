// SPDX-License-Identifier: MIT

// IQ Protocol. Risk-free collateral-less utility renting
// https://iq.space/docs/iq-yellow-paper.pdf
// (C) Blockvis & PARSIQ
// 🖖 Stake strong!

pragma solidity 0.8.4;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IConverter.sol";
import "./libs/Errors.sol";
import "./libs/IUniswapV2Router02.sol";
import "./libs/IUniswapV2Pair.sol";
import "./libs/IUniswapV2Factory.sol";

/**
 * Pancakeswap converter for estimating token prices.
 */
contract ParsiqPancakeConverter is IConverter {
    IUniswapV2Pair public immutable swapPair;
    IUniswapV2Router02 private _uniswapRouter;

    /**
     * @notice Constructor for `ParsiqPancakeConverter`
     * @param uniswapRouter - UniswapV2 router implementation. On BSC that would be Pancakeswap.
     * @param allowedSourceCoin - The ERC20 token that's used for expressing the price of a service
     * @param allowedTargetCoin - The ERC20 token that's used for paying for the service
     * @dev The token pair must be pre-deployed and registered on the router!
     * @dev Instantiate a uniswap router pointer
     * @dev Find the existing token pair
     */
    constructor(
        IUniswapV2Router02 uniswapRouter,
        IERC20 allowedSourceCoin, // <- STABLECOIN (BUSD)
        IERC20 allowedTargetCoin // <- PRQ
    ) {
        _uniswapRouter = uniswapRouter;
        IUniswapV2Factory uniswapFactory = IUniswapV2Factory(_uniswapRouter.factory());
        swapPair = IUniswapV2Pair(uniswapFactory.getPair(address(allowedSourceCoin), address(allowedTargetCoin)));
    }

    /**
     * @notice Perform estimation of how many `target` tokens are necessary to cover required amount of `source` tokens.
     * @param source - the source token address
     * @param target - the target token address
     * @param amount - the amount of source token price
     * @dev Source and target token addresses must be the exact ones as specified in the constructor of this contract.
     */
    function estimateConvert(
        IERC20 source,
        uint256 amount,
        IERC20 target
    ) external view override returns (uint256) {
        require(address(source) == swapPair.token0(), Errors.DC_UNSUPPORTED_PAIR);
        require(address(target) == swapPair.token1(), Errors.DC_UNSUPPORTED_PAIR);

        // the price of token1 denominated in token0
        return swapPair.price1CumulativeLast() * amount;
    }

    /**
     * @notice Noop converter. Reverts if `source` and `target` tokens differ.
     */
    function convert(
        IERC20 source,
        uint256 amount,
        IERC20 target
    ) external pure override returns (uint256) {
        require(address(source) == address(target), Errors.DC_UNSUPPORTED_PAIR);
        return amount;
    }
}
