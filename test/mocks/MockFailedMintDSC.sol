// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockFailedMintDSC is ERC20Burnable, Ownable {
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

    function mint(address, /*_to*/ uint256 /*_amount*/ )
        external
        view
        onlyOwner /*moreThanZero(_amount)*/
        returns (bool)
    {
        return false;
    }
}
