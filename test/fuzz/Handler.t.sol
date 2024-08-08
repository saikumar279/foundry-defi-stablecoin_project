//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    MockV3Aggregator ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    address[] public usersWithCollateralDeposited;
    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        console.log(address(weth));
        wbtc = ERC20Mock(collateralTokens[1]);
        console.log(address(wbtc));

        ethUsdPriceFeed = MockV3Aggregator(dsce.getPriceFeed(address(weth)));
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        address sender = usersWithCollateralDeposited[
            addressSeed % usersWithCollateralDeposited.length
        ];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInformation(sender);

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) -
            int256(totalDscMinted);

        if (maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint));

        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);

        dsce.mintDsc(amount);
        vm.stopPrank();
    }

    function depositCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getTotalCollateralDeposited(
            msg.sender,
            address(collateral)
        );
        console.log(maxCollateralToRedeem);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        console.log(amountCollateral);
        if (amountCollateral == 0) {
            return;
        }

        vm.prank(msg.sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);

        // console.log(
        //     dsce.getTotalCollateralDeposited(msg.sender, address(collateral))
        // );

        // console.log(
        //     dsce.getTotalCollateralDeposited(msg.sender, address(collateral))
        // );
    }

    // function updateCollateralPrice(uint96 newprice) public {
    //     int256 newPriceInt = int256(uint256(newprice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // Helper Functions

    function _getCollateralFromSeed(
        uint256 collateralSeed
    ) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 1) {
            return weth;
        }
        return wbtc;
    }
}
