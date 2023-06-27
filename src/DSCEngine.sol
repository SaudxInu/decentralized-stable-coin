// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

/*
 * @title DSCEngine
 * @author Saud Iqbal
 * @notice This contract handles all the logic for minting and redeeming DecentralizedStableCoin (DSC), as well as depositing and withdrawing collateral.
 * This contract is the core of the DSC system. This contract is based on the MakerDAO DSS system.
 * @dev The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 */
contract DSCEngine is ReentrancyGuard {
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsDontMatch();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactorValue);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    DecentralizedStableCoin private immutable i_dsc;

    /// @notice This means you need to be 200% over-collateralized.
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    /// @notice This means you get assets at a 10% discount when liquidating.
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    /// @notice Mapping of token address to price feed address
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    /// @notice Amount of collateral deposited by user
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    /// @notice Amount of DSC minted by user
    mapping(address user => uint256 amount) private s_DSCMinted;
    /// @dev If we know exactly how many collateral tokens we have, we could make this immutable.
    address[] private s_collateralTokens;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /// @dev if from != to, then it was liquidated
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed collateralTokenAddress,
        uint256 collateralTokenAmount
    );

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsDontMatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];

            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    )
        external
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        moreThanZero(amountDscToMint)
        nonReentrant
    {
        _depositCollateral(tokenCollateralAddress, amountCollateral);

        _mintDsc(amountDscToMint);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _depositCollateral(tokenCollateralAddress, amountCollateral);
    }

    /*
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice You can only mint DSC if you hav enough collateral
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        _mintDsc(amountDscToMint);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @param amountDscToBurn: The amount of DSC you want to burn
     * @notice This function will withdraw your collateral and burn DSC in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        moreThanZero(amountDscToBurn)
        nonReentrant
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);

        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @notice careful! You'll burn your DSC here! Make sure you want to do this...
     * @dev you might want to use this if you're nervous you might get liquidated and want to just burn
     * you DSC but keep your collateral in.
     */
    function burnDsc(uint256 amount) external moreThanZero(amount) nonReentrant {
        _burnDsc(amount, msg.sender, msg.sender);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @notice This function will redeem your collateral.
     * @notice If you have DSC minted, you might have to burn some or all of your DSC depending on amountCollateral
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     *  This is collateral that you're going to take from the user who is insolvent.
     *  In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice: This function working assumes that the protocol will be roughly 110% overcollateralized in order for this to work.
     * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        isAllowedToken(collateral)
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);

        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // If covering 100 DSC, we need to $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _burnDsc(debtToCover, user, msg.sender);

        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) private {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;

        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _mintDsc(uint256 amountDscToMint) private {
        s_DSCMinted[msg.sender] += amountDscToMint;

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);

        // Redundant check.
        if (minted != true) {
            revert DSCEngine__MintFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    // Why external? remove?
    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getUserDscMinted(address user) external view returns (uint256) {
        return s_DSCMinted[user];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    // Why public? change to internal or private
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);

        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    // Why public? change to internal or private
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];

            uint256 amount = s_collateralDeposited[user][token];

            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);

        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    // Using private as well external, make it public
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];

        collateralValueInUsd = getAccountCollateralValue(user);
    }

    // Using private as well external, make it public
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _getUsdValue(
        address token,
        uint256 amount // in WEI
    ) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);

        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    // internal plus external, make it public
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
}
