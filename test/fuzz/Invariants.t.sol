//SPDX-License-Identifier: MIT

// What are our invarients?

//1. Total supply should always be greater than the amount of collateral

//2. Our getter view functions should never revert in any case

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";
contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    HelperConfig config;
    DecentralizedStableCoin dsc;
    Handler handler;

    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        handler = new Handler(dsce, dsc);
        (, , weth, wbtc, , ) = config.activeNetworkConfig();
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreCollateralThanSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 totalWethDepositedInUsd = dsce.getUsdValue(
            weth,
            totalWethDeposited
        );
        uint256 totalWbtcDepositedInUsd = dsce.getUsdValue(
            wbtc,
            totalWbtcDeposited
        );
        console.log("Weth value in Usd:", totalWethDepositedInUsd);
        console.log("Wbtc value in Usd:", totalWbtcDepositedInUsd);
        console.log("Total Supply:", totalSupply);
        assert(
            totalWethDepositedInUsd + totalWbtcDepositedInUsd >= totalSupply
        );
    }

    function invariant_gettersShouldNotRevert() public view {
        dsce.getAccountCollateralValue(msg.sender);
        dsce.getAccountInformation(msg.sender);
        dsce.getCollateralTokens();
        dsce.getDsc();
        dsce.getDscMinted(msg.sender);
        dsce.getHealthFactor(msg.sender);
        dsce.getLiquidationBonus();
        dsce.getLiquidationPrecision();
        dsce.getLiquidationThreshold();
        dsce.getMinHealthFactor();
        dsce.getTokensLength();
    }
}
