//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
/*
 * @title: DSCEngine
 * @author: Saikumar
 *
 *
 * This system is designed to be as minimal as possible and have tokens maintain 1 token == 1$
 *
 * This Stable coin has properties:
 * - Relative Stability: Pegged
 * - Stability Mechanism: Algorithmic
 * - Colletaral: Exogenous (WETH and WBTC)
 *
 *
 * Our System should always be "overcolloteralised" that means at no point value of all collataral should not be less than or equal to the value of all the DSC
 *
 *
 *
 * @notice This contract is core of the DSC system where it handles all things like mining and redemming DSC tokens and depositing and withdrawing colleteral
 * @notice This contract is very loosely based on MakerDao DSS(DAI) System.
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////////////
    /// Error Delarations ///
    /////////////////////////

    error DSCEngine__AmountShouldBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMustBeSame();
    error DSCEngine__CollateralTypeNotValid();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__UserHealthFactorIsNotOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////////
    /// Type Delarations  ///
    /////////////////////////

    using OracleLib for AggregatorV3Interface;

    /////////////////////////
    /// State Variables /////
    /////////////////////////

    uint256 private constant ADDITIONAL_PRICE_FEED = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address pricefeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /////////////////////////
    /// Event Declarations //
    /////////////////////////

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
    /////////////////
    /// Modifiers ///
    /////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__AmountShouldBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__CollateralTypeNotValid();
        }
        _;
    }

    /////////////////
    /// Functions ///
    /////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMustBeSame();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////
    /// External Functions ////
    ///////////////////////////

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /// @notice This function is for the users to deposit collateral
    /// @param tokenCollateralAddress The token address of the collateral transfferred
    /// @param amountCollateral The amount of collateral to deposit

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /// @notice This function burns the dsc from the user and also redeems their collateral checking the health factor
    /// @param tokenCollateralAddress This is the token collateral address from which user wants to burn
    /// @param amountCollateral The amount of collateral which the user wants to withdraw
    /// @param amountDscToBurn The amount of Dsc which the user wants to Burn

    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /// @notice Inorder to redeem colleteral their healthfactor should be more than 1 after collateral pulled
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        // 100 -1000 than it would revert
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /// @notice This function is for the users to mint DSC tokens
    /// @param amountDscToMint The amount of DSC to Mint
    /// @notice They should have more collateral than the minimum threshold amount
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I think this is not needed so please take a look into it while auditing
    }

    // If the contract starts to go undercollateralisation than we need to someone to liquidate positions
    // 100$ ETH -> 50$ of DSC But if ETH goes down to 20 $ ETH -> 50 $ DSC you would see that value of DSC cannot be mainted as 1$

    /*
     * @param collateralAddress The collateral to liquidate
     * @param user The user from which we need to liquidate(Only if their health factor _healthFactor() is less than minimum health factor MIN_HEALTH_FACTOR)
     * @param debtToCover Amount of DSC does the user want to send inorder to liquidate which increases the healthfactor of the user
     * @notice You can partially liquidate user
     * @notice You would get liquidation bonus for liquidating a user
     * @notice This function working assumes that the protocol is roughly always 200% overcollateralised
     * @notice If the protocol is 100% or less collaterlised than we wouldn't be able to incentivise the users
     * Like if the price of collateral drops before anyone liquidates particular user
     *
     */
    function liquidate(
        address collateralAddress,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        // First we need to check the healthfactor of the user

        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__UserHealthFactorIsNotOk();
        }

        uint256 tokenAmountFromDebitCovered = getTokenAmountFromUsd(
            collateralAddress,
            debtToCover
        );

        //Also ADD 10% Bonus

        uint256 bonusCollateral = (tokenAmountFromDebitCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebitCovered +
            bonusCollateral;

        _redeemCollateral(
            collateralAddress,
            totalCollateralToRedeem,
            user,
            msg.sender
        );

        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ////////////////////////////////////////////
    /// Private and Internal View Functions ////
    ////////////////////////////////////////////

    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        s_DSCMinted[dscFrom] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] =
            s_collateralDeposited[from][tokenCollateralAddress] -
            amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * It tells how close the user to a liquidation
     * If the user goes below 1 than they can get liquidated
     *
     */
    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 totalCollateralValueInUsd
        ) = _getAccountInformation(user);

        uint256 healthFactor = _calculateHealthFactor(
            totalDscMinted,
            totalCollateralValueInUsd
        );
        return healthFactor;

        // if (totalDscMinted == 0) {
        //     return type(uint256).max;
        // }
        // uint256 collateralValueAdjustedToThreshold = (totalCollateralValueInUsd *
        //         LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // //Example For 1000$ 100 DSC are minted  1000$ eth * 50 /100 = 500$ 500/
        // return
        //     (collateralValueAdjustedToThreshold * PRECISION) / totalDscMinted;
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 totalCollateralValueInUsd
    ) private pure returns (uint256) {
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralValueAdjustedToThreshold = (totalCollateralValueInUsd *
                LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        //Example For 1000$ 100 DSC are minted  1000$ eth * 50 /100 = 500$ 500/
        return
            (collateralValueAdjustedToThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(healthFactor);
        }
    }

    ////////////////////////////////////////////
    /// Public and External View Functions /////
    ////////////////////////////////////////////

    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 totalCollateralValueInUsd
    ) public pure returns (uint256) {
        uint256 healthFactor = _calculateHealthFactor(
            totalDscMinted,
            totalCollateralValueInUsd
        );
        return healthFactor;
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();

        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_PRICE_FEED);
    }
    function getAccountCollateralValue(
        address user
    ) public view returns (uint256) {
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            // uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(
                s_collateralTokens[i],
                s_collateralDeposited[user][token]
            );
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();

        return ((uint256(price) * ADDITIONAL_PRICE_FEED) * amount) / PRECISION;
    }

    ////////////////////////////////////////////
    /// Getter View Functions              /////
    ////////////////////////////////////////////

    function getTokensLength() public view returns (uint256) {
        return s_collateralTokens.length;
    }

    function getTotalCollateralDeposited(
        address user,
        address token
    ) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getHealthFactor(address user) public view returns (uint256) {
        return _healthFactor(user);
    }

    function getDscMinted(address user) public view returns (uint256) {
        return s_DSCMinted[user];
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }
    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }
    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }
    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
