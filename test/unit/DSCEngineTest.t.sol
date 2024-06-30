// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";



contract DSCEngineTest is Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount);
    // if the redeemedFrom != redeemedTo, then the collateral was liquidated
   
    DecentralizedStableCoin public dsc;
    DSCEngine public dsce;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    // address public wbtc;
    // uint256 public deployerKey;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = address(1);

    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;
    
    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, , weth, , ) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(user, STARTING_ERC20_BALANCE);
    }

    //////////////////////////
    //  Constructor Tests   //
    //////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }



    ////////////////////
    // Price Tests    //
    ////////////////////

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // Assuming the price of WETH is 2000 USD
        // uint256 expectedWeth = 0.05 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);

    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18; // 15 ether -> 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUsd = 30_000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd); 
    }


    //////////////////////////////
    // depositCollateral Tests //
    //////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();

    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", user, 100e18);  // Remove this magic number for amountCollateral
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector));
        dsce.depositCollateral(address(ranToken), amountCollateral);
        vm.stopPrank();
        
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositAmount, amountCollateral);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    //////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);

        uint256 expectedHealthFactor = dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintDscWithDepositedCollateral () public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    //////////////////////////
    //    mintDsc Tests    ///
    //////////////////////////

    function testRevertsIfMintAmountIsEqualToZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }
    // This test is might not be needed as it is already covered in the depositCollateralAndMintDsc test
    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }
    //////////////////////////
    //    burnDsc Tests     //  
    //////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testBurnCantExceedMoreThanUserHas() public {
        vm.prank(user);
        // Expect revert in next transaction, if not, this should fail
        vm.expectRevert();
        // Attempts to burn 1 DSC token when user has 0
        dsce.burnDsc(1);
    }

    function testUserCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);

        // Check and print user balance before burning
        uint256 userBalanceBefore = dsc.balanceOf(user);
        console.log("User balance before burning: ", userBalanceBefore);
        require(userBalanceBefore >= amountToMint, "User does not have enough DSC to burn");

        // Approve and burn if passes
        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalanceAfter = dsc.balanceOf(user);
        console.log("User balance after burning: ", userBalanceAfter);
        assertEq(userBalanceAfter, 0);
    }
    ///////////////////////////////////
    //    redeemCollateral Tests     //  
    //////////////////////////////////

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testUserCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        dsce.redeemCollateral(weth, amountCollateral);
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalance, amountCollateral);
        vm.stopPrank();

    }

    function testEmitsCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralRedeemed(user, user, weth, amountCollateral);
        vm.startPrank(user);
        dsce.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }
    
    /////////////////////////////////////////
    //    redeemCollateralForDsc Tests     //  
    /////////////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();

    }

    function testUserCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testHealthFactorIsReportedProperly() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 actualHealthFactor = dsce.getHealthFactor(user);

        assertEq(expectedHealthFactor, actualHealthFactor);

    }

    ////////////////////////
    // Liquidation Tests  //
    ////////////////////////

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);

        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }
    // This modifier sets up a specific scenario where a users debt is liquidated:
    modifier liquidated() {
        // 1: Simulate User Actions
        // Prank the user
        vm.startPrank(user);
        //  Approves contract to spend 'amountCollateral' of WETH on behalf of the user
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        // User deposits WETH collateral and mints DSC
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        // End prank on user
        vm.stopPrank(); 

        // 2: Manipulate Price Feed
        // Sets the new price of ETH to $18
        int256 ethUsdUpdatedPrice = 18e8;
        // Update the price feed to new ETH price
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice); 
        // Retreives the new health factor of the user after the price change
        uint256 userHealthFactor = dsce.getHealthFactor(user);
        
        // 3: Simulate Liquidator Actions   
        // Mint WETH for liquidator to cover collateral
        ERC20Mock(weth).mint(liquidator, collateralToCover);
        // Prank the liquidator
        vm.startPrank(liquidator);
        // Approve DSCEngine contract to spend 'collateralToCover' of WETH on behalf of the liquidator
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        // Liquidator deposits WETH collateral and mints DSC
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        // Approves DSCEngine contract to spend 'amountToMint' of DSC on behalf of the liquidator
        dsc.approve(address(dsce), amountToMint);
        // Liquidate the entire balance of debt for user using DSC 
        dsce.liquidate(weth, user, amountToMint); 
        // End prank on liquidator
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsAccurate() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        // Converts the amount of DSC (in USD) to WETH equivalent amount
        // Sums that WETH equivalent amount of 'amountToMint' with the liquidation bonus
        // Will result in total amount of WETH that the liquidator will receive in payout
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) / dsce.getLiquidationBonus());
        // Hardcoded expected WETH amount --> 6.111111111111111110 weth in wei
        // Dynamic calculation 'expectedWeth' should equal hardcoded value
        uint256 hardCodedExpectedWeth = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpectedWeth);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasEthAfterLiquidation() public liquidated {
        // Retreive amount of WETH the user lost
        // Uses the amount of DSC (in USD) to calculate WETH equivalent 
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) / dsce.getLiquidationBonus());
        // Amount of WETH the user lost
        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
        // Amount of WETH the user has left after liquidation
        uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);
        // Retreive the user's collateral value in USD
        (, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        // Harcode expected value of user's collateral value in USD
        uint256 hardCodedExpectedUserCollateralValue = 70_000_000_000_000_000_020; // 70.000000000000000020 WETH in wei
        // Assert that the user's collateral value in USD is equal to the expected value
        assertEq(collateralValueInUsd, expectedUserCollateralValueInUsd);
        // Assert that the user's collateral value in USD is equal to the hardcoded expected value
        assertEq(collateralValueInUsd, hardCodedExpectedUserCollateralValue);

    }

    function testLiquidatorInheritsUserDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dsce.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);

    }

    function testUserHasNoRemainingDebt() public liquidated {
        (uint256 userDscMinted,) = dsce.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }

    ////////////////////////////////
    // View & Pure Function Test //
    ////////////////////////////////

    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }
    
    function testGetCollateralTokens() public {
        // Get the collateralTokens address 
        address[] memory collateralTokens = dsce.getCollateralTokens();
        // Assert that the first element of the collateralTokens array is equal to the address of WETH
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralAmountFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dsce.getAccountInformation(user);
        uint256 expectedCollateral = dsce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateral);
    }

    function testGetCollateralBalanceOfUserIsAccurate() public {
        // Prank the user, approve collateral, and ensure collateral is deposited
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        // Test collateral value from 'getCollaterlBalanceOfUser' is accurate
        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        uint256 collateralValue = dsce.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(expectedLiquidationPrecision, actualLiquidationPrecision);
    }
}