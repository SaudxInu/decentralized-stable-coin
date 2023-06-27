// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockV3Aggregator} from "./MockV3Aggregator.sol";

/*
 * @title DecentralizedStableCoin
 * @author Patrick Collins
 * Collateral: Exogenous
 * Minting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral Type: Crypto
 *
 * This is the contract meant to be owned by DSCEngine. It is a ERC20 token that can be minted and burned by the DSCEngine smart contract.
 */
contract MockMoreDebtDSC is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountMustBeMoreThanZero();

    address mockAggregator;

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }
        _;
    }

    constructor(address _mockAggregator) ERC20("DecentralizedStableCoin", "DSC") {
        mockAggregator = _mockAggregator;
    }

    function burn(uint256 _amount) public override onlyOwner moreThanZero(_amount) {
        // We crash the price
        MockV3Aggregator(mockAggregator).updateAnswer(0);

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner moreThanZero(_amount) returns (bool) {
        _mint(_to, _amount);

        return true;
    }
}
