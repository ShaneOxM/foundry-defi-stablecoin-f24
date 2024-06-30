// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Decentralized Stable Coin
 * @author Shane Monastero
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * This is the contract meant to be governed by DSCEngine. This contract is just the ERC20 implementation of our stablecoin system.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor(
        address initialOwner
    ) ERC20("Decentralized Stable Coin", "DSC") {
        // Pass any additional arguments to the ERC20 constructor if needed
    }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount); //Directs to superclass after code is run, to use the function "burn" from ERC20Burnable
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            /** Sanitization of Inputs */
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        // Prevents user from minting to zero address
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
            // Prevents user from minting negative amount
        }
        _mint(_to, _amount); // Directs to superclass after code is run, to use the function "_mint" from ERC20
        return true; // Returns true if minting is successful and meets parameters
    }
}
