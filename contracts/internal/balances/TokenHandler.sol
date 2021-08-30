// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../math/SafeInt256.sol";
import "../../global/Types.sol";
import "../../global/Constants.sol";
import "interfaces/compound/CErc20Interface.sol";
import "interfaces/compound/CEtherInterface.sol";
import "interfaces/IEIP20NonStandard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Handles all external token transfers and events
library TokenHandler {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    function _getSlot(uint256 currencyId, bool underlying) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    currencyId,
                    keccak256(abi.encode(underlying, Constants.TOKEN_STORAGE_OFFSET))
                )
            );
    }

    function setMaxCollateralBalance(uint256 currencyId, uint72 maxCollateralBalance) internal {
        bytes32 slot = _getSlot(currencyId, false);
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        // Clear the top 72 bits for the max collateral balance
        data = data & 0x000000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        data = data | bytes32(uint256(maxCollateralBalance) << 184);

        assembly {
            sstore(slot, data)
        }
    } 

    /// @notice Gets token data for a particular currency id, if underlying is set to true then returns
    /// the underlying token. (These may not always exist)
    function getToken(uint256 currencyId, bool underlying) internal view returns (Token memory) {
        bytes32 slot = _getSlot(currencyId, underlying);
        bytes32 data;

        assembly {
            data := sload(slot)
        }
        address tokenAddress = address(bytes20(data << 96));
        bool tokenHasTransferFee = bytes1(data << 88) != Constants.BOOL_FALSE;
        uint8 tokenDecimalPlaces = uint8(bytes1(data << 80));
        TokenType tokenType = TokenType(uint8(bytes1(data << 72)));
        uint256 maxCollateralBalance = uint256(data >> 184);

        return
            Token({
                tokenAddress: tokenAddress,
                hasTransferFee: tokenHasTransferFee,
                decimals: int256(10**tokenDecimalPlaces),
                tokenType: tokenType,
                maxCollateralBalance: maxCollateralBalance
            });
    }

    /// @notice Sets a token for a currency id.
    function setToken(
        uint256 currencyId,
        bool underlying,
        TokenStorage memory tokenStorage
    ) internal {
        bytes32 slot = _getSlot(currencyId, underlying);

        if (tokenStorage.tokenType == TokenType.Ether && currencyId == Constants.ETH_CURRENCY_ID) {
            // Specific storage for Ether token type
            bytes32 etherData =
                ((bytes32(bytes20(address(0))) >> 96) |
                    (bytes32(bytes1(Constants.BOOL_FALSE)) >> 88) |
                    bytes32(uint256(18) << 168) |
                    bytes32(uint256(TokenType.Ether) << 176));

            assembly {
                sstore(slot, etherData)
            }

            return;
        }
        require(tokenStorage.tokenType != TokenType.Ether); // dev: ether can only be set once
        require(tokenStorage.tokenAddress != address(0), "TH: address is zero");
        if (underlying) {
            // Underlying tokens cannot have max collateral balances, the contract only has a balance temporarily
            // during mint and redeem actions.
            require(tokenStorage.maxCollateralBalance == 0); // dev: underlying cannot have max collateral balance
            require(tokenStorage.tokenType == TokenType.UnderlyingToken); // dev: underlying token inconsistent
        } else {
            require(tokenStorage.tokenType != TokenType.UnderlyingToken); // dev: underlying token inconsistent
        }

        uint8 decimalPlaces = ERC20(tokenStorage.tokenAddress).decimals();
        require(decimalPlaces != 0, "TH: decimals is zero");

        // Once a token is set we cannot override it. In the case that we do need to do change a token address
        // then we should explicitly upgrade this method to allow for a token to be changed.
        Token memory token = getToken(currencyId, underlying);
        require(
            token.tokenAddress == tokenStorage.tokenAddress || token.tokenAddress == address(0),
            "TH: token cannot be reset"
        );

        if (tokenStorage.tokenType == TokenType.cToken) {
            // Set the approval for the underlying so that we can mint cTokens
            Token memory underlyingToken = getToken(currencyId, true);
            ERC20(underlyingToken.tokenAddress).approve(
                tokenStorage.tokenAddress,
                type(uint256).max
            );
        }

        bytes1 transferFee =
            tokenStorage.hasTransferFee ? Constants.BOOL_TRUE : Constants.BOOL_FALSE;

        bytes32 data =
            ((bytes32(bytes20(tokenStorage.tokenAddress)) >> 96) |
                (bytes32(bytes1(transferFee)) >> 88) |
                bytes32(uint256(decimalPlaces) << 168) |
                bytes32(uint256(tokenStorage.tokenType) << 176) |
                bytes32(uint256(tokenStorage.maxCollateralBalance) << 184)
            );

        assembly {
            sstore(slot, data)
        }
    }

    /// @notice This method only works with cTokens, it's unclear how we can make this more generic
    function mint(Token memory token, uint256 underlyingAmountExternal) internal returns (int256) {
        uint256 startingBalance = IERC20(token.tokenAddress).balanceOf(address(this));

        uint256 success;
        if (token.tokenType == TokenType.cToken) {
            success = CErc20Interface(token.tokenAddress).mint(underlyingAmountExternal);
        } else if (token.tokenType == TokenType.cETH) {
            // Reverts on error
            CEtherInterface(token.tokenAddress).mint{value: msg.value}();
        } else {
            revert(); // dev: non mintable token
        }

        require(success == 0, "Mint");
        uint256 endingBalance = IERC20(token.tokenAddress).balanceOf(address(this));

        // This is the starting and ending balance in external precision
        return int256(endingBalance.sub(startingBalance));
    }

    function redeem(
        Token memory assetToken,
        Token memory underlyingToken,
        uint256 assetAmountExternal
    ) internal returns (int256) {
        uint256 startingBalance;
        if (assetToken.tokenType == TokenType.cETH) {
            startingBalance = address(this).balance;
        } else if (assetToken.tokenType == TokenType.cToken) {
            startingBalance = IERC20(underlyingToken.tokenAddress).balanceOf(address(this));
        } else {
            revert(); // dev: non redeemable failure
        }

        uint256 success = CErc20Interface(assetToken.tokenAddress).redeem(assetAmountExternal);
        require(success == 0, "Redeem");

        uint256 endingBalance;
        if (assetToken.tokenType == TokenType.cETH) {
            endingBalance = address(this).balance;
        } else {
            endingBalance = IERC20(underlyingToken.tokenAddress).balanceOf(address(this));
        }

        // Underlying token external precision
        return int256(endingBalance.sub(startingBalance));
    }

    /// @notice Handles transfers into and out of the system denominated in the external token decimal
    /// precision.
    function transfer(
        Token memory token,
        address account,
        int256 netTransferExternal
    ) internal returns (int256) {
        if (netTransferExternal > 0) {
            // Deposits must account for transfer fees.
            netTransferExternal = _deposit(token, account, uint256(netTransferExternal));
        } else if (token.tokenType == TokenType.Ether) {
            require(netTransferExternal < 0); // dev: cannot transfer ether
            address payable accountPayable = payable(account);
            // This does not work with contracts, but is reentrancy safe. If contracts want to withdraw underlying
            // ETH they will have to withdraw the cETH token and then redeem it manually.
            accountPayable.transfer(uint256(netTransferExternal.neg()));
        } else {
            safeTransferOut(
                token.tokenAddress,
                account,
                uint256(netTransferExternal.neg())
            );
        }

        return netTransferExternal;
    }

    /// @notice Handles token deposits into Notional. If there is a transfer fee then we must
    /// calculate the net balance after transfer. Amounts are denominated in the destination token's
    /// precision.
    function _deposit(
        Token memory token,
        address account,
        uint256 amount
    ) private returns (int256) {
        uint256 startingBalance;
        uint256 endingBalance;
        uint256 finalAmountAdjustment;

        if (token.hasTransferFee) {
            startingBalance = IERC20(token.tokenAddress).balanceOf(address(this));
        }

        safeTransferIn(token.tokenAddress, account, amount);

        if (token.hasTransferFee || token.maxCollateralBalance > 0) {
            endingBalance = IERC20(token.tokenAddress).balanceOf(address(this));
        }

        if (token.maxCollateralBalance > 0) {
            int256 internalPrecisionBalance = convertToInternal(token, int256(endingBalance));
            require(internalPrecisionBalance <= int256(token.maxCollateralBalance)); // dev: over max collateral balance
        }

        if (token.decimals < Constants.INTERNAL_TOKEN_PRECISION) {
            // If decimals is less than internal token precision, we change how much the the user is credited
            // during this deposit so that the protocol accrues the dust (not the user's cash balance)
            finalAmountAdjustment = 1;
        }

        if (token.hasTransferFee) {
            return int256(endingBalance.sub(startingBalance).sub(finalAmountAdjustment));
        } else {
            return int256(amount.sub(finalAmountAdjustment));
        }
    }

    function convertToInternal(Token memory token, int256 amount) internal pure returns (int256) {
        // If token decimals is greater than INTERNAL_TOKEN_PRECISION then this will truncate
        // down to the internal precision. If token decimals is less than INTERNAL_TOKEN_PRECISION
        // then this will add zeros to the end of amount and will not result in dust.
        if (token.decimals == Constants.INTERNAL_TOKEN_PRECISION) return amount;
        return amount.mul(Constants.INTERNAL_TOKEN_PRECISION).div(token.decimals);
    }

    function convertToExternal(Token memory token, int256 amount) internal pure returns (int256) {
        if (token.decimals == Constants.INTERNAL_TOKEN_PRECISION) return amount;
        // If token decimals is greater than INTERNAL_TOKEN_PRECISION then this will increase amount
        // by adding a number of zeros to the end. If token decimals is less than INTERNAL_TOKEN_PRECISION
        // then we will end up truncating off the lower portion of the amount. This can result in the
        // internal cash balances being different from the actual cash balances. This can result in dust
        // amounts accruing in the protocol.
        // For this case, when withdrawing out of the protocol we want to round down such that the
        // protocol will retain more balance than the user. This already happens in the conversion below. When
        // depositing, we want to decrease the amount of cash balance we credit to the user by a dust amount
        // so that the protocol accrues the dust (rather than the user's balance). This is implemented in _deposit
        // above.
        return amount.mul(token.decimals).div(Constants.INTERNAL_TOKEN_PRECISION);
    }

    function transferIncentive(address account, uint256 tokensToTransfer) internal {
        safeTransferOut(Constants.NOTE_TOKEN_ADDRESS, account, tokensToTransfer);
    }

    function safeTransferOut(
        address token,
        address account,
        uint256 amount
    ) private {
        IEIP20NonStandard(token).transfer(account, amount);
        checkReturnCode();
    }

    function safeTransferIn(
        address token,
        address account,
        uint256 amount
    ) private {
        IEIP20NonStandard(token).transferFrom(account, address(this), amount);
        checkReturnCode();
    }

    function checkReturnCode() private pure {
        bool success;
        assembly {
            switch returndatasize()
                case 0 {
                    // This is a non-standard ERC-20
                    success := not(0) // set success to true
                }
                case 32 {
                    // This is a compliant ERC-20
                    returndatacopy(0, 0, 32)
                    success := mload(0) // Set `success = returndata` of external call
                }
                default {
                    // This is an excessively non-compliant ERC-20, revert.
                    revert(0, 0)
                }
        }

        require(success, "ERC20");
    }
}
