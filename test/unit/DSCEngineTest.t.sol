// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {Test, console} from "forge-std/Test.sol";

contract DSCEngineTest is Test {
    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    address public constant USER = address(1);
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;

    modifier onlyOnAnvil() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function setUp() external {
        DeployDSC deployer = new DeployDSC();

        (dsc, dsce, helperConfig) = deployer.run();

        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();

        if (block.chainid == 31337) {
            vm.deal(USER, STARTING_USER_BALANCE);

            ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);

            ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        }
    }

    ///////////////////////
    // constructor Tests //
    ///////////////////////

    address[] tokenAddresses;
    address[] feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed, btcUsdPriceFeed];

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsDontMatch.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    //////////////////
    // Price Tests ///
    //////////////////

    function testGetTokenAmountFromUsd() public onlyOnAnvil {
        uint256 usdAmount = 100 ether;

        uint256 expectedWeth = 0.05 ether;

        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(amountWeth, expectedWeth);
    }

    function testGetUsdValue() public onlyOnAnvil {
        uint256 ethAmount = 15e18;

        uint256 expectedUsd = 30000e18;

        uint256 usdValue = dsce.getUsdValue(weth, ethAmount);

        assertEq(usdValue, expectedUsd);
    }

    ///////////////////////////////////////
    // depositCollateral Tests ////////////
    ///////////////////////////////////////

    function testRevertsIfTransferFromFails() public {
        // Arrange
        address owner = msg.sender;

        vm.startPrank(owner);

        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();

        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.stopPrank();

        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];

        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            feedAddresses,
            address(dsc)
        );

        vm.prank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);

        // Act / Assert
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
    }

    function testRevertsIfCollateralZero() public onlyOnAnvil {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);

        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);

        randToken.approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randToken)));
        dsce.depositCollateral(address(randToken), AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public onlyOnAnvil depositedCollateral {
        uint256 USERBalance = dsc.balanceOf(USER);

        assertEq(USERBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public onlyOnAnvil depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, 0);

        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public onlyOnAnvil {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        uint256 amountDscToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountDscToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountDscToMint);

        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);

        vm.stopPrank();

        _;
    }

    function testCanMintWithDepositedCollateral() public onlyOnAnvil depositedCollateralAndMintedDsc {
        uint256 USERBalance = dsc.balanceOf(USER);

        assertEq(USERBalance, AMOUNT_TO_MINT);
    }

    ///////////////////////////////////
    // mintDsc Tests //////////////////
    ///////////////////////////////////

    function testRevertsIfMintFails() public onlyOnAnvil {
        // Arrange
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];

        address owner = msg.sender;

        vm.startPrank(owner);

        MockFailedMintDSC mockDsc = new MockFailedMintDSC();

        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockDsc)
        );

        mockDsc.transferOwnership(address(mockDsce));

        vm.stopPrank();

        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);

        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public onlyOnAnvil {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);

        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public onlyOnAnvil depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        uint256 amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
    }

    function testCanMintDsc() public onlyOnAnvil depositedCollateral {
        vm.prank(USER);

        dsce.mintDsc(AMOUNT_TO_MINT);

        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    ///////////////////////////////////
    // burnDsc Tests //////////////////
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public onlyOnAnvil depositedCollateralAndMintedDsc {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public onlyOnAnvil depositedCollateralAndMintedDsc {
        vm.startPrank(USER);

        dsc.approve(address(dsce), AMOUNT_TO_MINT);

        dsce.burnDsc(AMOUNT_TO_MINT);

        vm.stopPrank();

        uint256 USERBalance = dsc.balanceOf(USER);

        assertEq(USERBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests /////////
    ///////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;

        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();

        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];

        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockDsc)
        );

        vm.prank(owner);
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));

        vm.prank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);

        // Act / Assert
        vm.startPrank(USER);

        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public onlyOnAnvil depositedCollateral {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
    }

    function testCanRedeemCollateral() public onlyOnAnvil depositedCollateral {
        vm.startPrank(USER);

        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);

        assertEq(userBalance, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests ///
    ///////////////////////////////////

    function testMustRedeemMoreThanZero() public onlyOnAnvil depositedCollateralAndMintedDsc {
        vm.startPrank(USER);

        dsc.approve(address(dsce), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, AMOUNT_TO_MINT);

        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public onlyOnAnvil depositedCollateralAndMintedDsc {
        vm.startPrank(USER);

        dsc.approve(address(dsce), AMOUNT_TO_MINT);

        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);

        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public onlyOnAnvil depositedCollateralAndMintedDsc {
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor

        uint256 expectedHealthFactor = 100 ether;

        uint256 healthFactor = dsce.getHealthFactor(USER);

        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public onlyOnAnvil depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // 1 ETH = $18
        // Rememeber, we need more than equal to $100 at all times if we have $100 of debt
        // 180 * 0.5 = 90
        // 90 / 100 = 0.9 health factor

        uint256 userHealthFactor = dsce.getHealthFactor(USER);

        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    function testCantLiquidateGoodHealthFactor() public onlyOnAnvil depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);

        ERC20Mock(weth).approve(address(dsce), COLLATERAL_TO_COVER);

        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);

        dsc.approve(address(dsce), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_TO_MINT);

        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);

        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);

        ERC20Mock(weth).approve(address(dsce), COLLATERAL_TO_COVER);

        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);

        dsc.approve(address(dsce), AMOUNT_TO_MINT);

        dsce.liquidate(weth, USER, AMOUNT_TO_MINT); // We are covering their whole debt

        vm.stopPrank();

        _;
    }

    function testLiquidationPayoutIsCorrect() public onlyOnAnvil liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);

        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT)
            + (dsce.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) / dsce.getLiquidationBonus());

        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public onlyOnAnvil liquidated {
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT)
            + (dsce.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) / dsce.getLiquidationBonus());

        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);

        uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 UserCollateralValueInUsd) = dsce.getAccountInformation(USER);

        assertEq(UserCollateralValueInUsd, expectedUserCollateralValueInUsd);
    }

    function testUserHasNoMoreDebt() public onlyOnAnvil liquidated {
        (uint256 userDscMinted,) = dsce.getAccountInformation(USER);

        assertEq(userDscMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests /////
    ///////////////////////////////////

    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);

        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = dsce.getCollateralTokens();

        assertEq(collateralTokens[0], weth);
        assertEq(collateralTokens[1], wbtc);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = dsce.getMinHealthFactor();

        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();

        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public onlyOnAnvil depositedCollateral {
        (, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);

        assertEq(collateralValueInUsd, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUSER() public onlyOnAnvil depositedCollateral {
        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(USER, weth);

        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public onlyOnAnvil depositedCollateral {
        uint256 collateralValueInUsd = dsce.getAccountCollateralValue(USER);

        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);

        assertEq(collateralValueInUsd, expectedCollateralValue);
    }

    function testGetDsc() public {
        address dscAddress = dsce.getDsc();

        assertEq(dscAddress, address(dsc));
    }
}
