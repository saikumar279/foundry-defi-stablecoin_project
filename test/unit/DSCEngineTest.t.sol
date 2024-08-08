//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
contract DSCEngineTest is Test {
    DeployDSC public deployer;
    DecentralizedStableCoin public dsc;
    DSCEngine public dsce;
    HelperConfig public config;

    address public wethUsdPriceFeed;
    address public wbtcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;
    address public intialOwnerOfDSC;
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 3 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant collateralToCover = 100 ether;

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );
    function setUp() external {
        deployer = new DeployDSC();

        (dsc, dsce, config) = deployer.run();

        (
            wethUsdPriceFeed,
            wbtcUsdPriceFeed,
            weth,
            wbtc,
            deployerKey,
            intialOwnerOfDSC
        ) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////////////
    /// Modifiers For  Test     ///
    ///////////////////////////////

    modifier DepositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // uint256 tokensLength = dsce.getAccountCollateralValue(USER);
        // console.log(tokensLength);
        vm.stopPrank();
        _;
    }

    modifier MintDsc() {
        uint256 amountMint = AMOUNT_TO_MINT;

        uint256 amountToMint = dsce.getUsdValue(weth, amountMint);
        // console.log(amountToMint);

        vm.startPrank(USER);

        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        _;
    }

    ////////////////////////
    /// Constructor Test ///
    ////////////////////////

    function testRevertsIfTokenAddressesLengthNotEqual() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);
        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMustBeSame
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////
    /// Price Test ///
    //////////////////

    function testGetTokenAmountFromUsd() public view {
        uint256 actualValue = dsce.getTokenAmountFromUsd(weth, 1000e18);

        uint256 expectedValue = 0.5 ether;

        assert(actualValue == expectedValue);
    }

    function testGetUsdValue() public view {
        /// 10e18 * 2000e18 / 1e18 = 20000e18

        uint256 ethAmount = 10e18;
        uint256 expectedUsdamount = 20000e18;
        uint256 actualUsdAmount = dsce.getUsdValue(weth, ethAmount);
        // console.log(ethAmount);
        // console.log(actualUsdAmount);

        assert(expectedUsdamount == actualUsdAmount);
    }

    ///////////////////////////////
    /// Deposit Collateral Test ///
    ///////////////////////////////

    function testCanDepositCollateralWithoutMinting()
        public
        DepositedCollateral
    {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(
            DSCEngine.DSCEngine__AmountShouldBeMoreThanZero.selector
        );
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfTokenNotAllowed() public {
        ERC20Mock newToken = new ERC20Mock();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__CollateralTypeNotValid.selector);
        dsce.depositCollateral(address(newToken), 1 ether);
        vm.stopPrank();
    }

    function testIfEventIsEmittedAfterDepositing() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, false, true);
        emit CollateralDeposited(USER, weth, 1 ether);

        dsce.depositCollateral(weth, 1 ether);

        vm.stopPrank();
    }

    ///////////////////////////////
    /// Redeem Collateral Test  ///
    ///////////////////////////////

    function testRevertsRedeemIfAmountIsZero() public DepositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(
            DSCEngine.DSCEngine__AmountShouldBeMoreThanZero.selector
        );
        dsce.redeemCollateral(weth, 0);
    }

    function testEmitsEventWhenRedeemingCollateral()
        public
        DepositedCollateral
    {
        vm.startPrank(USER);

        vm.expectEmit(true, true, true, false);
        emit CollateralRedeemed(USER, USER, weth, 1 ether);
        dsce.redeemCollateral(weth, 1 ether);
        vm.stopPrank();
    }

    function testRevertsRedeemCollateralIfHealthFactorIsBroken()
        public
        DepositedCollateral
        MintDsc
    {
        uint256 totalDscMinted = dsce.getUsdValue(weth, AMOUNT_TO_MINT);
        console.log(totalDscMinted);
        uint256 actualCollateralValueAfterRedeeming = dsce.getUsdValue(
            weth,
            5 ether
        );
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            totalDscMinted,
            actualCollateralValueAfterRedeeming
        );
        console.log(expectedHealthFactor);
        vm.startPrank(USER);

        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        dsce.redeemCollateral(weth, 5 ether);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public DepositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////
    /// Mint Dsc Test           ///
    ///////////////////////////////

    function testCanMintWithDepositedCollateral()
        public
        DepositedCollateral
        MintDsc
    {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, dsce.getUsdValue(weth, AMOUNT_TO_MINT));
    }
    function testRevertsMintIfAmountisGreaterThanZero()
        public
        DepositedCollateral
    {
        vm.startPrank(USER);
        vm.expectRevert(
            DSCEngine.DSCEngine__AmountShouldBeMoreThanZero.selector
        );
        dsce.mintDsc(0);
    }

    function testRevertsMintIfHealthFactorIsBroken()
        public
        DepositedCollateral
    {
        uint256 amountMint = 9 ether;
        console.log(amountMint);
        uint256 amountToMint = dsce.getUsdValue(weth, amountMint);
        console.log(amountToMint);
        // (, int256 price, , , ) = MockV3Aggregator(wethUsdPriceFeed)
        //     .latestRoundData();
        // uint256 amountToMint = (amountMint * (uint256(price) * 1e10)) / 1e18;
        // uint256 accountInfo = dsce.getAccountCollateralValue(USER);
        // console.log(accountInfo);

        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            amountToMint,
            dsce.getAccountCollateralValue(USER)
        );
        console.log(expectedHealthFactor);
        vm.startPrank(USER);

        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    ///////////////////////////////
    /// Burn Dsc Test           ///
    ///////////////////////////////

    function testBurnDscRevertsIfAmountIsZero()
        public
        DepositedCollateral
        MintDsc
    {
        vm.startPrank(USER);
        vm.expectRevert(
            DSCEngine.DSCEngine__AmountShouldBeMoreThanZero.selector
        );
        dsce.burnDsc(0);

        vm.stopPrank();
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor()
        public
        DepositedCollateral
        MintDsc
    {
        // uint256 totalDscMinted = dsce.getUsdValue(weth, AMOUNT_TO_MINT);
        // console.log(totalDscMinted);
        uint256 expectedHealthFactor = 1666666666666666666;
        // uint256 expectedHealthFactor = dsce.calculateHealthFactor(
        //     totalDscMinted,
        //     dsce.getAccountCollateralValue(USER)
        // );

        uint256 healthFactor = dsce.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    ////////////////////////
    // Liquidation Tests  //
    ////////////////////////

    function testRevertsIfDebtToCoverIsZeroInLquidation()
        public
        DepositedCollateral
        MintDsc
    {
        vm.expectRevert(
            DSCEngine.DSCEngine__AmountShouldBeMoreThanZero.selector
        );
        dsce.liquidate(weth, USER, 0);
    }

    function testRevertsIfHealthFactorIsGreaterThanMinInLiquidation()
        public
        DepositedCollateral
        MintDsc
    {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__UserHealthFactorIsNotOk.selector);
        dsce.liquidate(weth, USER, 5 ether);
    }

    function testIfTokenFromUsdIsCorrect() public view {
        uint256 expectedUsdValue = 0.05e18;

        uint256 actualValue = dsce.getTokenAmountFromUsd(weth, 100e18);

        assert(expectedUsdValue == actualValue);
    }

    function testLiquidateWorksCorrect() public DepositedCollateral MintDsc {
        int256 ethUsdUpdatedPrice = 1000e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        console.log(userHealthFactor);
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        uint256 amountToMint = 6000e18;
        console.log(amountToMint);
        console.log(ERC20Mock(weth).balanceOf(LIQUIDATOR));

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);

        dsc.approve(address(dsce), amountToMint);
        dsce.liquidate(weth, USER, amountToMint); // We are covering their whole debt
        vm.stopPrank();

        console.log(dsce.getDscMinted(LIQUIDATOR));
        assert(dsce.getDscMinted(LIQUIDATOR) == 0);
    }

    ////////////////////////
    // Precision Tests    //
    ////////////////////////
    function testGetDsc() public view {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    function testGetCollateralBalanceOfUser() public DepositedCollateral {
        uint256 collateralBalance = dsce.getTotalCollateralDeposited(
            USER,
            weth
        );
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public DepositedCollateral {
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = dsce.getUsdValue(
            weth,
            AMOUNT_COLLATERAL
        );
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetAccountCollateralValueFromInformation()
        public
        DepositedCollateral
    {
        (, uint256 collateralValue) = dsce.getAccountInformation(USER);
        uint256 expectedCollateralValue = dsce.getUsdValue(
            weth,
            AMOUNT_COLLATERAL
        );
        assertEq(collateralValue, expectedCollateralValue);
    }
}
