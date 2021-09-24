// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./interfaces/IInterestToken.sol";
import "./interfaces/IBorrowToken.sol";
import "./interfaces/IConverter.sol";
import "./interfaces/IPowerToken.sol";
import "./EnterpriseStorage.sol";

contract Enterprise is EnterpriseStorage {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    enum LiquidityChangeType {
        WithdrawInterest,
        Add,
        Remove,
        Increase,
        Decrease
    }

    event LiquidityChanged(
        uint256 indexed interestTokenId,
        address indexed liquidityProvider,
        LiquidityChangeType indexed changeType,
        uint256 amount,
        uint256 totalShares,
        uint256 reserve,
        uint256 usedReserve
    );

    event ServiceRegistered(address indexed powerToken);

    event Borrowed(
        uint256 indexed borrowTokenId,
        address indexed borrower,
        address indexed powerToken,
        address paymentToken,
        uint112 amount,
        uint112 interest,
        uint112 serviceFee,
        uint112 gcFee,
        uint32 borrowingTime,
        uint32 maturityTime,
        uint32 borrowerReturnGraceTime,
        uint32 enterpriseCollectGraceTime,
        uint256 reserve,
        uint256 usedReserve
    );

    event LoanExtended(
        uint256 indexed borrowTokenId,
        address indexed borrower,
        address paymentToken,
        uint112 interest,
        uint112 serviceFee,
        uint32 maturityTime,
        uint32 borrowerReturnGraceTime,
        uint32 enterpriseCollectGraceTime
    );

    event LoanReturned(
        uint256 indexed borrowTokenId,
        address indexed returner,
        address indexed powerToken,
        uint112 amount,
        uint112 gcFee,
        address gcFeeToken,
        uint256 reserve,
        uint256 usedReserve
    );

    function registerService(
        string memory serviceName,
        string memory symbol,
        uint32 gapHalvingPeriod,
        uint112 baseRate,
        IERC20Metadata baseToken,
        uint16 serviceFeePercent,
        uint32 minLoanDuration,
        uint32 maxLoanDuration,
        uint96 minGCFee,
        bool allowsPerpetualTokensForever
    ) external onlyOwner notShutdown {
        require(address(baseToken) != address(0), Errors.E_INVALID_BASE_TOKEN_ADDRESS);
        require(_powerTokens.length < type(uint16).max, Errors.E_SERVICE_LIMIT_REACHED);

        PowerToken powerToken = _factory.deployService(getProxyAdmin());
        {
            string memory tokenSymbol = _liquidityToken.symbol();
            string memory powerTokenSymbol = string(abi.encodePacked(tokenSymbol, " ", symbol));
            powerToken.initialize(serviceName, powerTokenSymbol, _liquidityToken.decimals());
        }
        powerToken.initialize(
            this,
            baseRate,
            minGCFee,
            gapHalvingPeriod,
            uint16(_powerTokens.length),
            baseToken,
            minLoanDuration,
            maxLoanDuration,
            serviceFeePercent,
            allowsPerpetualTokensForever
        );
        _powerTokens.push(powerToken);
        _registeredPowerTokens[powerToken] = true;

        emit ServiceRegistered(address(powerToken));
    }

    function borrow(
        PowerToken powerToken,
        IERC20 paymentToken,
        uint112 amount,
        uint32 duration,
        uint256 maxPayment
    ) external notShutdown {
        require(_registeredPowerTokens[powerToken], Errors.UNREGISTERED_POWER_TOKEN);
        require(isSupportedPaymentToken(paymentToken), Errors.E_UNSUPPORTED_INTEREST_PAYMENT_TOKEN);
        require(powerToken.isAllowedLoanDuration(duration), Errors.E_LOAN_DURATION_OUT_OF_RANGE);
        require(amount > 0, Errors.E_INVALID_LOAN_AMOUNT);
        require(amount <= getAvailableReserve(), Errors.E_INSUFFICIENT_LIQUIDITY);

        uint112 interest;
        uint112 serviceFee;
        uint112 gcFee;
        {
            // scope to avoid stack too deep errors
            (uint112 interestAmount, uint112 serviceFeeAmount, uint112 gcFeeAmount) = powerToken.estimateLoanDetailed(
                paymentToken,
                amount,
                duration
            );
            interest = interestAmount;
            serviceFee = serviceFeeAmount;
            gcFee = gcFeeAmount;

            uint256 loanCost = interest + serviceFee;
            require(loanCost + gcFee <= maxPayment, Errors.E_LOAN_COST_SLIPPAGE);

            paymentToken.safeTransferFrom(msg.sender, address(this), loanCost);

            uint256 convertedLiquidityTokens = loanCost;

            if (address(paymentToken) != address(_liquidityToken)) {
                paymentToken.approve(address(_converter), loanCost);
                convertedLiquidityTokens = _converter.convert(paymentToken, loanCost, _liquidityToken);
            }

            uint256 serviceLiquidity = (serviceFee * convertedLiquidityTokens) / loanCost;
            _liquidityToken.safeTransfer(_enterpriseVault, serviceLiquidity);

            _usedReserve += amount;

            uint112 poolInterest = uint112(convertedLiquidityTokens - serviceLiquidity);
            _increaseStreamingReserveTarget(poolInterest);
        }
        paymentToken.safeTransferFrom(msg.sender, address(_borrowToken), gcFee);
        uint32 borrowingTime = uint32(block.timestamp);
        uint32 maturityTime = borrowingTime + duration;
        uint32 borrowerReturnGraceTime = maturityTime + _borrowerLoanReturnGracePeriod;
        uint32 enterpriseCollectGraceTime = maturityTime + _enterpriseLoanCollectGracePeriod;
        uint256 borrowTokenId = _borrowToken.getNextTokenId();

        _loanInfo[borrowTokenId] = LoanInfo(
            amount,
            powerToken.getIndex(),
            borrowingTime,
            maturityTime,
            borrowerReturnGraceTime,
            enterpriseCollectGraceTime,
            gcFee,
            uint16(paymentTokenIndex(paymentToken))
        );

        assert(_borrowToken.mint(msg.sender) == borrowTokenId); // also mints PowerTokens

        powerToken.notifyNewLoan(borrowTokenId);

        emit Borrowed(
            borrowTokenId,
            msg.sender,
            address(powerToken),
            address(paymentToken),
            amount,
            interest,
            serviceFee,
            gcFee,
            borrowingTime,
            maturityTime,
            borrowerReturnGraceTime,
            enterpriseCollectGraceTime,
            getReserve(),
            _usedReserve
        );
    }

    function reborrow(
        uint256 borrowTokenId,
        IERC20 paymentToken,
        uint32 duration,
        uint256 maxPayment
    ) external notShutdown {
        require(isSupportedPaymentToken(paymentToken), Errors.E_UNSUPPORTED_INTEREST_PAYMENT_TOKEN);
        LoanInfo storage loan = _loanInfo[borrowTokenId];
        require(loan.amount > 0, Errors.E_INVALID_LOAN_TOKEN_ID);
        PowerToken powerToken = _powerTokens[loan.powerTokenIndex];
        require(powerToken.isAllowedLoanDuration(duration), Errors.E_LOAN_DURATION_OUT_OF_RANGE);
        require(loan.maturityTime + duration >= block.timestamp, Errors.E_INVALID_LOAN_DURATION);

        // emulating here loan return
        _usedReserve -= loan.amount;

        (uint112 interest, uint112 serviceFee, ) = powerToken.estimateLoanDetailed(paymentToken, loan.amount, duration);

        // emulating here borrow
        unchecked {
            _usedReserve += loan.amount; // safe, because previously we successfully decreased it
        }
        uint256 loanCost = interest + serviceFee;

        require(loanCost <= maxPayment, Errors.E_LOAN_COST_SLIPPAGE);

        paymentToken.safeTransferFrom(msg.sender, address(this), loanCost);
        {
            uint256 convertedLiquidityTokens = loanCost;
            if (address(paymentToken) != address(_liquidityToken)) {
                paymentToken.approve(address(_converter), loanCost);
                convertedLiquidityTokens = _converter.convert(paymentToken, loanCost, _liquidityToken);
            }

            uint256 serviceLiquidity = (serviceFee * convertedLiquidityTokens) / loanCost;
            _liquidityToken.safeTransfer(_enterpriseVault, serviceLiquidity);

            uint112 poolInterest = uint112(convertedLiquidityTokens - serviceLiquidity);
            _increaseStreamingReserveTarget(poolInterest);
        }

        uint32 newMaturityTime = loan.maturityTime + duration;
        uint32 newBorrowerReturnGraceTime = newMaturityTime + _borrowerLoanReturnGracePeriod;
        uint32 newEnterpriseCollectGraceTime = newMaturityTime + _enterpriseLoanCollectGracePeriod;

        loan.maturityTime = newMaturityTime;
        loan.borrowerReturnGraceTime = newBorrowerReturnGraceTime;
        loan.enterpriseCollectGraceTime = newEnterpriseCollectGraceTime;

        powerToken.notifyNewLoan(borrowTokenId);

        emit LoanExtended(
            borrowTokenId,
            msg.sender,
            address(paymentToken),
            interest,
            serviceFee,
            newMaturityTime,
            newBorrowerReturnGraceTime,
            newEnterpriseCollectGraceTime
        );
    }

    function returnLoan(uint256 borrowTokenId) external {
        LoanInfo memory loan = _loanInfo[borrowTokenId];
        require(loan.amount > 0, Errors.E_INVALID_LOAN_TOKEN_ID);
        address borrower = _borrowToken.ownerOf(borrowTokenId);
        uint32 timestamp = uint32(block.timestamp);

        require(
            loan.borrowerReturnGraceTime < timestamp || msg.sender == borrower,
            Errors.E_INVALID_CALLER_WITHIN_BORROWER_GRACE_PERIOD
        );
        require(
            loan.enterpriseCollectGraceTime < timestamp || msg.sender == borrower || msg.sender == _enterpriseCollector,
            Errors.E_INVALID_CALLER_WITHIN_ENTERPRISE_GRACE_PERIOD
        );

        if (!_enterpriseShutdown) {
            // Enterprise shutdown sets usedReserve to zero
            _usedReserve -= loan.amount;
        }

        _borrowToken.burn(borrowTokenId, msg.sender); // burns PowerTokens, returns gc fee

        emit LoanReturned(
            borrowTokenId,
            msg.sender,
            address(_powerTokens[loan.powerTokenIndex]),
            loan.amount,
            loan.gcFee,
            _paymentTokens[loan.gcFeeTokenIndex],
            getReserve(),
            _usedReserve
        );

        delete _loanInfo[borrowTokenId];
    }

    /**
     * One must approve sufficient amount of liquidity tokens to
     * Enterprise address before calling this function
     */
    function addLiquidity(uint256 liquidityAmount) external notShutdown {
        _liquidityToken.safeTransferFrom(msg.sender, address(this), liquidityAmount);

        uint256 newShares = (_totalShares == 0 ? liquidityAmount : _liquidityToShares(liquidityAmount));

        _increaseReserve(liquidityAmount);

        uint256 interestTokenId = _interestToken.mint(msg.sender);

        _liquidityInfo[interestTokenId] = LiquidityInfo(liquidityAmount, newShares, block.number);

        _increaseShares(newShares);

        emit LiquidityChanged(
            interestTokenId,
            msg.sender,
            LiquidityChangeType.Add,
            liquidityAmount,
            _totalShares,
            getReserve(),
            _usedReserve
        );
    }

    function withdrawInterest(uint256 interestTokenId) external onlyInterestTokenOwner(interestTokenId) {
        LiquidityInfo storage liquidityInfo = _liquidityInfo[interestTokenId];
        uint256 shares = liquidityInfo.shares;

        uint256 interest = getAccruedInterest(interestTokenId);
        require(interest <= getAvailableReserve(), Errors.E_INSUFFICIENT_LIQUIDITY);

        _liquidityToken.safeTransfer(msg.sender, interest);

        uint256 newShares = _liquidityToShares(liquidityInfo.amount);
        liquidityInfo.shares = newShares;

        _decreaseShares(shares - newShares);
        _decreaseReserve(interest);

        emit LiquidityChanged(
            interestTokenId,
            msg.sender,
            LiquidityChangeType.WithdrawInterest,
            interest,
            _totalShares,
            getReserve(),
            _usedReserve
        );
    }

    function removeLiquidity(uint256 interestTokenId) external onlyInterestTokenOwner(interestTokenId) {
        LiquidityInfo storage liquidityInfo = _liquidityInfo[interestTokenId];
        require(liquidityInfo.block < block.number, Errors.E_FLASH_LIQUIDITY_REMOVAL);
        uint256 shares = liquidityInfo.shares;

        uint256 liquidityWithInterest = _sharesToLiquidity(shares);
        require(liquidityWithInterest <= getAvailableReserve(), Errors.E_INSUFFICIENT_LIQUIDITY);

        _interestToken.burn(interestTokenId);
        _liquidityToken.safeTransfer(msg.sender, liquidityWithInterest);

        _decreaseShares(shares);
        _decreaseReserve(liquidityWithInterest);
        delete _liquidityInfo[interestTokenId];

        emit LiquidityChanged(
            interestTokenId,
            msg.sender,
            LiquidityChangeType.Remove,
            liquidityWithInterest,
            _totalShares,
            getReserve(),
            _usedReserve
        );
    }

    function decreaseLiquidity(uint256 interestTokenId, uint256 amount)
        external
        onlyInterestTokenOwner(interestTokenId)
    {
        LiquidityInfo storage liquidityInfo = _liquidityInfo[interestTokenId];
        require(liquidityInfo.block < block.number, Errors.E_FLASH_LIQUIDITY_REMOVAL);
        require(liquidityInfo.amount >= amount, Errors.E_INSUFFICIENT_LIQUIDITY);
        require(amount <= getAvailableReserve(), Errors.E_INSUFFICIENT_LIQUIDITY);
        _liquidityToken.safeTransfer(msg.sender, amount);

        uint256 shares = _liquidityToShares(amount);
        if (shares > liquidityInfo.shares) {
            shares = liquidityInfo.shares;
        }
        unchecked {
            liquidityInfo.shares -= shares;
            liquidityInfo.amount -= amount;
        }
        _decreaseShares(shares);
        _decreaseReserve(amount);

        emit LiquidityChanged(
            interestTokenId,
            msg.sender,
            LiquidityChangeType.Decrease,
            amount,
            _totalShares,
            getReserve(),
            _usedReserve
        );
    }

    function increaseLiquidity(uint256 interestTokenId, uint256 amount)
        external
        notShutdown
        onlyInterestTokenOwner(interestTokenId)
    {
        _liquidityToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 newShares = (_totalShares == 0 ? amount : _liquidityToShares(amount));

        _increaseReserve(amount);
        LiquidityInfo storage liquidityInfo = _liquidityInfo[interestTokenId];
        liquidityInfo.amount += amount;
        liquidityInfo.shares += newShares;
        liquidityInfo.block = block.number;
        _increaseShares(newShares);

        emit LiquidityChanged(
            interestTokenId,
            msg.sender,
            LiquidityChangeType.Increase,
            amount,
            _totalShares,
            getReserve(),
            _usedReserve
        );
    }

    function estimateLoan(
        PowerToken powerToken,
        IERC20 paymentToken,
        uint112 amount,
        uint32 duration
    ) external view notShutdown returns (uint256) {
        require(_registeredPowerTokens[powerToken], Errors.UNREGISTERED_POWER_TOKEN);

        return powerToken.estimateLoan(paymentToken, amount, duration);
    }

    function _increaseReserve(uint256 delta) internal {
        _fixedReserve += delta;
        emit FixedReserveChanged(_fixedReserve);
    }

    function _decreaseReserve(uint256 delta) internal {
        if (_fixedReserve >= delta) {
            unchecked {
                _fixedReserve -= delta;
            }
        } else {
            uint256 streamingReserve = _flushStreamingReserve();

            _fixedReserve = _fixedReserve + streamingReserve - delta;
        }
        emit FixedReserveChanged(_fixedReserve);
    }

    function _increaseShares(uint256 delta) internal {
        _totalShares += delta;
        emit TotalSharesChanged(_totalShares);
    }

    function _decreaseShares(uint256 delta) internal {
        _totalShares -= delta;
        emit TotalSharesChanged(_totalShares);
    }

    function _liquidityToShares(uint256 amount) internal view returns (uint256) {
        return (_totalShares * amount) / getReserve();
    }

    function _sharesToLiquidity(uint256 shares) internal view returns (uint256) {
        return (getReserve() * shares) / _totalShares;
    }

    function loanTransfer(
        address from,
        address to,
        uint256 borrowTokenId
    ) external onlyBorrowToken {
        uint112 amount = _loanInfo[borrowTokenId].amount;
        require(amount > 0, Errors.E_INVALID_LOAN_TOKEN_ID);

        bool isExpiredBorrow = (block.timestamp > _loanInfo[borrowTokenId].maturityTime);
        bool isMinting = (from == address(0));
        bool isBurning = (to == address(0));
        PowerToken powerToken = _powerTokens[_loanInfo[borrowTokenId].powerTokenIndex];

        if (isBurning) {
            powerToken.burnFrom(from, amount);
        } else if (isMinting) {
            powerToken.mint(to, amount);
        } else if (!isExpiredBorrow) {
            powerToken.forceTransfer(from, to, amount);
        } else {
            revert(Errors.E_LOAN_TRANSFER_NOT_ALLOWED);
        }
    }

    function getAccruedInterest(uint256 interestTokenId) public view returns (uint256) {
        LiquidityInfo storage liquidityInfo = _liquidityInfo[interestTokenId];

        uint256 liquidity = _sharesToLiquidity(liquidityInfo.shares);
        // Due to rounding errors calculated liquidity could be insignificantly
        // less than provided liquidity
        return liquidity <= liquidityInfo.amount ? 0 : liquidity - liquidityInfo.amount;
    }

    /**
     * @dev Shuts down Enterprise.
     *  * Unlocks all reserves, LPs can withdraw their tokens
     *  * Disables adding liquidity
     *  * Disables borrowing
     *  * Disables wrapping
     *
     * !!! Cannot be undone !!!
     */
    function shutdownEnterpriseForever() external notShutdown onlyOwner {
        _enterpriseShutdown = true;
        _usedReserve = 0;
        _streamingReserve = _streamingReserveTarget;

        emit EnterpriseShutdown();
    }
}
