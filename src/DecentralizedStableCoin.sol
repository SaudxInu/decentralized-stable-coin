// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 * @title DecentralizedStableCoin
 * @author Saud Iqbal
 * @notice This is the contract meant to be owned by DSCEngine. It is a ERC20 token that can be minted and burned by the DSCEngine smart contract.
 * @dev This is an Anchored, Decentralized, Exogenous Crypto Collateralized stable coin with the following properties.
 * - Relative Stability (Value): Anchored (Pegged to USD)
 * - Stability Mechanism (Minting and Burning): Decentralized (Algorithmic)
 * - Collateral: Exogenous. Crypto. (wETH and wBTC)
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountMustBeMoreThanZero();

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }
        _;
    }

    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner moreThanZero(_amount) {
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner moreThanZero(_amount) returns (bool) {
        _mint(_to, _amount);

        return true;
    }
}
