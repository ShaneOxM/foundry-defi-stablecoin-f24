
// SPDX-License-Identifier: MIT
// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol"; 
import {OracleLib} from "./libraries/OracleLib.sol";
import {console} from "lib/forge-std/src/console.sol";


/**
 * @title DSCEngine
 * @author Shane Monastero
 * 
 * This system is designed to be as minimal as possible, and intended to have the tokens maintain a 1 token == $1 peg.
 * This stablcoin has the properties:
 * - Exogenous Collateral 
 * - Dollar pegged
 * - Algorithmically Stable
 * 
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC.
 * 
 * Our DSC system should always be overcollateralized, and the collateral should be held in a decentralized manner.
 * 
 * At no point should the system be able to mint more DSC than the value of the $ backed collateral backing the DSC.
 * 
 * @notice This contract is the core of the DSC system. It is the engine that handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system. It is a stripped down version that is meant to be as simple as possible.
 * 
 */
contract DSCEngine is ReentrancyGuard {
    
   ////////////////////
   // Errors         //
   ////////////////////
   error DSCEngine__NeedsMoreThanZero();
   error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
   error DSCEngine__TokenNotAllowed();
   error DSCEngine__TransferFailed();
   error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
   error DSCEngine__MintFailed();
   error DSCEngine__HealthFactorOk();
   error DSCEngine__HealthFactorNotImproved();

   ///////////////////////////
   // Type Declarations     //
   ///////////////////////////
    using OracleLib for AggregatorV3Interface;


   //////////////////////////
   // State Variables     //
   /////////////////////////
   uint256 private constant LIQUIDATION_THRESHOLD = 50; // 150% collateralization ratio
   uint256 private constant LIQUIDATOR_BONUS = 10; // 10% bonus for liquidators
   uint256 private constant LIQUIDATION_PRECISION = 100; 
   uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 1 is the minimum health factor, if it goes below 1, then the account can be liquidated
   uint256 private constant PRECISION = 1e18;
   uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
   uint256 private constant FEED_PRECISION = 1e8;

   mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
   mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
   mapping(address user => uint256 amount) private s_DSCMinted; 
   address[] private s_collateralTokens;


   DecentralizedStableCoin private immutable i_dsc;

   /////////////////
   // Events      //
   /////////////////
   event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
   event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

   ////////////////////
   // Modifiers      //
   ////////////////////
   modifier moreThanZero(uint256 amount) {
        if(amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

   modifier isAllowedToken(address token) {
    // Check if token is allowed --> We need to make token allow list
        if(s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

   ////////////////////
   // Functions    //
   ////////////////////
   constructor (
    address[] memory tokenAddresses,
    address[] memory priceFeedAddresses,
    address dscAddress
    
    ) {
       // USD Price Feeds
       if (tokenAddresses.length != priceFeedAddresses.length) {
           revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
       }
       // If they have price feeds they are allowed, if not, they are not allowed
       for (uint256 i = 0; i < tokenAddresses.length; i++) {
       s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
       s_collateralTokens.push(tokenAddresses[i]);
       }
       i_dsc = DecentralizedStableCoin(dscAddress);
    }

   //////////////////////////
   // External Functions  //
   /////////////////////////

   /*
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice This function will deposit your collateral and mind DSC in one transaction
    */

   function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }


    /*
     * 
     * @param tokenCollateralAddress The address of the token to redeem as collateral
     * @param amountCollateral The amount collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * This function burns DSC and redeems collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress)
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) external 
    moreThanZero(amountCollateral) nonReentrant isAllowedToken(tokenCollateralAddress)
    {
        // Redeem collateral of user (msg.sender) to themselves (msg.sender)
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc(uint256 amount) external moreThanZero(amount) {
        _burnDsc(amount,msg.sender, msg.sender); // Burn DSC from user to themselves --> See internal function for outside calls to burn DSC
        _revertIfHealthFactorIsBroken(msg.sender); // Check health factor after burning DSC
    }

    /*
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user to who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC to you want to burn to improve the users health factor
     * @notice This function will liquidate the user by burning DSC to cover their debt
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation reward for liquidating a user
     * @notice This function will revert if the user is not undercollateralizedm or if the user does not have enough DSC to cover the debt
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then the liquidation would not work and we would not be able to incentivize liquidators
     * 
     * Follows CEI pattern (Check-Effect-Interact)
     */
    function liquidate(address collateral, address user, uint256 debtToCover) 
        external 
        moreThanZero(debtToCover) 
        nonReentrant 
    {
        // Check health factor to see if user is undercollateralized
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn DSC to cover the "debt"
        // And we want to redeem collateral to cover the debt
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // Calculate bonus for liquidator
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATOR_BONUS) / LIQUIDATION_PRECISION;
        // Redeem collateral using _redeemCollateral functionality
        // Redeem from user to liquidator (msg.sender)
        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        // Burn DSC from user to themselves
        // User is the one who is being liquidated
        // msg.sender is the liquidator
        _burnDsc(debtToCover, user, msg.sender);
        // Check health factor of user being liquidated, after liquidation
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        // Revert if user health factor is impacted by acting as liquidator
        _revertIfHealthFactorIsBroken(user);
    }

    //////////////////////
    // Public Functions //
    //////////////////////

    // Check if the collateral value > DSC Amount
    /*
     * @notice follows CEI pattern (Check-Effect-Interact) 
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice They must have more collateral value than the minimum threshold to mint DSC
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted) {
            revert DSCEngine__MintFailed();
        }
            
    }
    
    /*
    * @notice follows CEI pattern (Check-Effect-Interact)
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public 
        moreThanZero(amountCollateral) 
        isAllowedToken(tokenCollateralAddress) 
        nonReentrant
    {

        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
    

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    ////////////////////////
   // Private Functions  //
   ////////////////////////
    
    /**
     * Returns how close to liquidation the user is
     * If a user goes below 1, then they can be liquidated
     * to  Is the liquidator
     * from Is the user that is being liquidated
     */
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private 
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*  
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factors being broken
     */

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        // Underflow check
        uint256 currentMinted = s_DSCMinted[onBehalfOf];
        require (currentMinted >= amountDscToBurn, "DSCEngine: Burn amount exceeds minted amount");
        
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This condition is hypothetically unreachable 
        // If transferFrom fails, will throw an error
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }






    ///////////////////////////////////////////////
    // Private & Internal View & Pure Functions //
    ///////////////////////////////////////////////

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) 
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor (address user) private view returns (uint256) 
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // The returned value from CL is going to be 1e8
        // So we need to multiply it by 1e10, multiply this by the amount of tokens, then divide by 1e8 to get the USD value
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns (uint256) 
    {
        // Check if totalDscMinted is 0, if it is, return max uint256
        // Logical because if no debt is minted, then the health factor is 1
        // This logic indicats Maximum Safert and Avoides Division by Zero Error
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////////////
    // External & Public View & Pure Functions  ///
    ///////////////////////////////////////////////

    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user) external view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) 
    {
      return _getAccountInformation(user);
    }

    function getUsdValue(address token, uint256 amount) external view returns(uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns(uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        // Loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd (address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();        
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION); // Should now be 1e18
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
        return LIQUIDATOR_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
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

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
















