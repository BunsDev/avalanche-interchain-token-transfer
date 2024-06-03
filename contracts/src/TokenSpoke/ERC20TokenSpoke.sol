// (c) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// SPDX-License-Identifier: Ecosystem

pragma solidity 0.8.18;

import {TokenSpoke} from "./TokenSpoke.sol";
import {TokenSpokeSettings} from "./interfaces/ITokenSpoke.sol";
import {IERC20TokenBridge} from "../interfaces/IERC20TokenBridge.sol";
import {IERC20SendAndCallReceiver} from "../interfaces/IERC20SendAndCallReceiver.sol";
import {
    SendTokensInput, SendAndCallInput, SingleHopCallMessage
} from "../interfaces/ITokenBridge.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts@4.8.1/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@4.8.1/token/ERC20/utils/SafeERC20.sol";
import {CallUtils} from "../utils/CallUtils.sol";

/**
 * THIS IS AN EXAMPLE CONTRACT THAT USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 */

/**
 * @title ERC20TokenSpoke
 * @notice This contract is an {IERC20TokenBridge} that receives tokens from its specifed {TokenHub} instance,
 * and represents the received tokens with an ERC20 token on this chain.
 * @custom:security-contact https://github.com/ava-labs/teleporter-token-bridge/blob/main/SECURITY.md
 */
contract ERC20TokenSpoke is IERC20TokenBridge, ERC20, TokenSpoke {
    using SafeERC20 for IERC20;

    uint8 private immutable _decimals;

    /**
     * @notice Initializes this token spoke instance to receive tokens from the specified hub instance,
     * and represents the received tokens with an ERC20 token on this chain.
     * @param settings Constructor settings for this token spoke instance.
     * @param tokenName The name of the ERC20 token.
     * @param tokenSymbol The symbol of the ERC20 token.
     * @param tokenDecimals_ The number of decimals for the ERC20 token.
     */
    constructor(
        TokenSpokeSettings memory settings,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 tokenDecimals_
    ) TokenSpoke(settings, 0, tokenDecimals_) ERC20(tokenName, tokenSymbol) {
        _decimals = tokenDecimals;
    }

    /**
     * @dev See {IERC20TokenBridge-send}
     *
     * Note: For transfers to an {input.destinationBlockchainID} that is not the {tokenHubBlockchainID},
     * a multi-hop transfer is performed, where the tokens are sent back to the token hub instance
     * first to check for bridge balance, and then routed to the final destination spoke instance.
     */
    function send(SendTokensInput calldata input, uint256 amount) external {
        _send(input, amount);
    }

    /**
     * @dev See {IERC20TokenBridge-sendAndCall}
     */
    function sendAndCall(SendAndCallInput calldata input, uint256 amount) external {
        _sendAndCall(input, amount);
    }

    /**
     * @dev See {ERC20-decimals}
     */
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev See {TokenSpoke-_deposit}
     *
     * Note: The amount returned must be the amount credited as a result of the transfer.
     * For a standard ERC20 implementation such as this contract, that is equal to the full amount given.
     * Child contracts with different {_transfer} implementations may need to override this
     * implemenation to ensure the amount returned is correct.
     */
    function _deposit(uint256 amount) internal virtual override returns (uint256) {
        return _transferSenderAllowance(amount);
    }

    /**
     * @dev See {TokenSpoke-_withdraw}
     */
    function _withdraw(address recipient, uint256 amount) internal virtual override {
        emit TokensWithdrawn(recipient, amount);
        _mint(recipient, amount);
    }

    /**
     * @dev See {TokenSpoke-_burn}
     *
     * Calls {ERC20-_burn} to burn tokens from this contract.
     */
    function _burn(uint256 amount) internal virtual override {
        _burn(address(this), amount);
    }

    /**
     * @dev See {TokenSpoke-_handleSendAndCall}
     *
     * Mints the tokens to this contract, approves the recipient contract to spend them,
     * and calls {IERC20SendAndCallReceiver-receiveTokens} on the recipient contract.
     * If the call fails or doesn't spend all of the tokens, the remaining amount is
     * sent to the fallback recipient.
     */
    function _handleSendAndCall(
        SingleHopCallMessage memory message,
        uint256 amount
    ) internal virtual override {
        // Mint the tokens to this contract address.
        _mint(address(this), amount);

        // Approve the recipient contract to spend the amount.
        _approve(address(this), message.recipientContract, amount);

        // Encode the call to {IERC20SendAndCallReceiver-receiveTokens}
        bytes memory payload = abi.encodeCall(
            IERC20SendAndCallReceiver.receiveTokens,
            (
                message.sourceBlockchainID,
                message.originBridgeAddress,
                message.originSenderAddress,
                address(this),
                amount,
                message.recipientPayload
            )
        );

        // Call the recipient contract with the given payload and gas amount.
        bool success = CallUtils._callWithExactGas(
            message.recipientGasLimit, message.recipientContract, payload
        );

        // Check what the remaining allowance is to transfer to the fallback recipient.
        uint256 remainingAllowance = allowance(address(this), message.recipientContract);

        // Reset the recipient contract allowance to 0.
        _approve(address(this), message.recipientContract, 0);

        if (success) {
            emit CallSucceeded(message.recipientContract, amount);
        } else {
            emit CallFailed(message.recipientContract, amount);
        }

        // Transfer any remaining allowance to the fallback recipient. This will be the
        // full amount if the call failed.
        if (remainingAllowance > 0) {
            _transfer(address(this), message.fallbackRecipient, remainingAllowance);
        }
    }

    function _transferSenderAllowance(uint256 amount) internal virtual override returns (uint256) {
        _spendAllowance(_msgSender(), address(this), amount);
        _transfer(_msgSender(), address(this), amount);
        return amount;
    }
}
