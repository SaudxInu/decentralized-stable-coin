// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {DSCEngine, AggregatorV3Interface} from "../../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../../src/DecentralizedStableCoin.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";

contract StopOnRevertHandler is Test {
    DSCEngine public dscEngine;
    DecentralizedStableCoin public dsc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public weth;
    ERC20Mock public wbtc;

    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    modifier onlyOnAnvil() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();

        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public onlyOnAnvil {
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        address owner = msg.sender;

        vm.startPrank(owner);

        collateral.mint(owner, amountCollateral);

        collateral.approve(address(dscEngine), amountCollateral);

        dscEngine.depositCollateral(address(collateral), amountCollateral);

        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed) public onlyOnAnvil {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        uint256 amountCollateral = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));

        if (amountCollateral == 0) {
            return;
        }

        vm.prank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnDsc(uint256 amountDsc) public onlyOnAnvil {
        amountDsc = dscEngine.getUserDscMinted(msg.sender);

        if (amountDsc == 0) {
            return;
        }

        vm.prank(msg.sender);
        dsc.approve(address(dscEngine), amountDsc);

        vm.prank(msg.sender);
        dscEngine.burnDsc(amountDsc);
    }

    function liquidate(uint256 collateralSeed, address userToBeLiquidated) public onlyOnAnvil {
        uint256 minHealthFactor = dscEngine.getMinHealthFactor();

        uint256 userHealthFactor = dscEngine.getHealthFactor(userToBeLiquidated);

        if (userHealthFactor >= minHealthFactor) {
            return;
        }

        uint256 debtToCover = dsc.balanceOf(userToBeLiquidated);

        debtToCover = bound(debtToCover, 1, uint256(MAX_DEPOSIT_SIZE));

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        uint256 amountCollateral = dscEngine.getTokenAmountFromUsd(address(collateral), debtToCover);

        collateral.mint(msg.sender, amountCollateral);

        collateral.approve(address(dscEngine), amountCollateral);

        dscEngine.depositCollateralAndMintDsc(address(collateral), amountCollateral, debtToCover);

        dscEngine.liquidate(address(collateral), userToBeLiquidated, debtToCover);
    }

    function transferDsc(uint256 amountDsc, address to) public onlyOnAnvil {
        if (to == address(0)) {
            to = address(1);
        }

        amountDsc = bound(amountDsc, 0, dsc.balanceOf(msg.sender));

        if (amountDsc == 0) {
            return;
        }

        vm.prank(msg.sender);
        dsc.transfer(to, amountDsc);
    }

    // function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
    //     int256 intNewPrice = int256(uint256(newPrice));

    //     ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

    //     MockV3Aggregator priceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(collateral)));

    //     priceFeed.updateAnswer(intNewPrice);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
