pragma solidity ^0.5.11;

// Sablier protocol
import "@sablier/protocol/contracts/Sablier.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";

import { SwapTypes } from "./Types.sol";

contract StreamedSwap is Ownable, CarefulMath, ReentrancyGuard {
    /**
     * @notice Counter for new stream ids.
     */
    uint256 public nextSwapId;

    /**
     * @notice The swap objects identifiable by their unsigned integer ids.
     */
    mapping(uint256 => SwapTypes.AtomicSwap) private streamedSwaps;

    Sablier public sablier;

    constructor(address _sablierContractAddress) public {
        require(_sablierContractAddress != address(0x00), "Sablier contract address is zero address.");
        sablier = Sablier(_sablierContractAddress);
    }

    /**
     * @dev Throws if the provided id does not point to a valid swap.
     */
    modifier swapExists(uint256 swapId) {
        require(streamedSwaps[swapId].isEntity, "swap does not exist");
        _;
    }

    /**
     * @dev Throws if the caller is not a recipient of the swap's streams.
     */
    modifier onlySenderOrRecipient(uint256 swapId) {
        (, address recipient1, , , , , , ) = sablier.getStream(streamedSwaps[swapId].streamId1);
        (, address recipient2, , , , , , ) = sablier.getStream(streamedSwaps[swapId].streamId2);

        require(msg.sender == recipient1 || msg.sender == recipient2, "caller is not the sender or recipient");
        _;
    }

    event SwapCreation(
        uint256 indexed swapId,
        address indexed sender,
        address indexed recipient,
        uint256 deposit1,
        uint256 deposit2,
        address tokenAddress1,
        address tokenAddress2,
        uint256 startTime,
        uint256 stopTime
    );

    /**
     * @notice Emits when a party of the swap withdraws a portion or all their pro rata share of the swap.
     */
    event WithdrawFromSwap(uint256 indexed swapId, address indexed recipient, uint256 amount);

    /**
     * @notice Emits when a stream is successfully cancelled and tokens are transferred back on a pro rata basis.
     */
    event CancelSwap(
        uint256 indexed swapId,
        address indexed sender,
        address indexed recipient,
        uint256 senderBalance1,
        uint256 senderBalance2,
        uint256 recipientBalance1,
        uint256 recipientBalance2
    );

    /*********************************
     * @notice - Streamed Atomic Swap
     *********************************/

    // TODO: Add verification that recipient consents to swap
    function createSwap(
        address recipient,
        uint256 deposit1,
        uint256 deposit2,
        address tokenAddress1,
        address tokenAddress2,
        uint256 startTime,
        uint256 stopTime
    ) public returns (uint256) {
        /***
         * @notice - Integrate createStreamedSwap()
         ***/

        require(tokenAddress1 != tokenAddress2, "Can't swap token for itself.");
        require(recipient != address(this), "stream to the contract itself");

        // Pull in deposits from users
        require(IERC20(tokenAddress1).transferFrom(msg.sender, address(this), deposit1), "token transfer failure");
        require(IERC20(tokenAddress2).transferFrom(recipient, address(this), deposit2), "token transfer failure");

        /* Approve the Sablier contract to spend from our tokens. */
        require(IERC20(tokenAddress1).approve(address(sablier), deposit1), "token approval failure");
        require(IERC20(tokenAddress2).approve(address(sablier), deposit2), "token approval failure");

        // Create both streams on sablier contract
        // These are now both owned by this contract so can only be cancelled atomically.
        uint256 streamId1 = sablier.createStream(recipient, deposit1, tokenAddress1, startTime, stopTime);
        uint256 streamId2 = sablier.createStream(msg.sender, deposit2, tokenAddress2, startTime, stopTime);

        /* Create and store the swap stream object. */
        uint256 swapId = nextSwapId;
        streamedSwaps[swapId] = SwapTypes.AtomicSwap({
            sender: msg.sender,
            recipient: recipient,
            tokenAddress1: tokenAddress1,
            tokenAddress2: tokenAddress2,
            streamId1: streamId1,
            streamId2: streamId2,
            isEntity: true
        });

        emit SwapCreation(
            swapId,
            msg.sender,
            recipient,
            deposit1,
            deposit2,
            tokenAddress1,
            tokenAddress2,
            startTime,
            stopTime
        );

        /* Increment the next swap id. */
        MathError mathErr;
        (mathErr, nextSwapId) = addUInt(swapId, uint256(1));

        require(mathErr == MathError.NO_ERROR, "next stream id calculation error");

        return swapId;
    }

    /**
     * @notice Withdraws from the contract to the recipient's account.
     * @dev Throws if the id does not point to a valid swap.
     *  Throws if the caller is not a party involved in the swap.
     *  Throws if the amount exceeds the available balance.
     *  Throws if there is a token transfer failure.
     * @param swapId The id of the swap to withdraw tokens from.
     * @param amount The amount of tokens to withdraw.
     * @return bool true=success, otherwise false.
     */
    function withdrawFromSwap(uint256 swapId, uint256 amount)
        external
        nonReentrant
        swapExists(swapId)
        onlySenderOrRecipient(swapId)
        returns (bool)
    {
        SwapTypes.AtomicSwap memory swap = streamedSwaps[swapId];

        // Withdraw from correct stream for caller to this contract.
        if (msg.sender == swap.sender) {
            sablier.withdrawFromStream(swap.streamId2, amount);
        } else if (msg.sender == swap.recipient) {
            sablier.withdrawFromStream(swap.streamId1, amount);
        }

        // TODO: Add check to see if both streams are exhausted. If so delete the swap
        // if (!sablier.streamExists(swap.streamId1) && !sablier.streamExists(swap.streamId2) ) {
        // delete streamedSwaps[swapId];
        // }

        emit WithdrawFromSwap(swapId, msg.sender, amount);
        return true;
    }

    /**
     * @notice Cancels the stream and transfers the tokens back on a pro rata basis.
     * @dev Throws if the id does not point to a valid stream.
     *  Throws if there is a token transfer failure.
     * @param streamId The id of the stream to cancel.
     * @param tokenAddress The address of the stream's token.
     * @param sender The address to send the unstreamed tokens to.
     * @return bool true=success, otherwise false.
     */
    function _cancelStream(uint256 streamId, address tokenAddress, address sender) internal returns (bool) {
        // Get balanceof AtomicSwap.sol on this stream
        // This is the amount which needs to be returned to the user
        uint256 senderBalance = sablier.balanceOf(streamId, address(this));

        // Recipient's balance is automatically sent to them by Sablier.sol so don't need to worry
        sablier.cancelStream(streamId);

        // Return unswapped balance to sender
        if (senderBalance > 0)
            require(IERC20(tokenAddress).transfer(sender, senderBalance), "recipient token transfer failure");
        return true;
    }

    /**
     * @notice Cancels the swap and transfers the tokens back on a pro rata basis.
     * @dev Throws if the id does not point to a valid swap.
     *  Throws if the caller is not the sender or the recipient of the stream.
     *  Throws if there is a token transfer failure.
     * @param swapId The id of the swap to cancel.
     * @return bool true=success, otherwise false.
     */
    function cancelSwap(uint256 swapId)
        external
        nonReentrant
        swapExists(swapId)
        onlySenderOrRecipient(swapId)
        returns (bool)
    {
        SwapTypes.AtomicSwap memory swap = streamedSwaps[swapId];

        (uint256 senderBalance1, uint256 senderBalance2) = balanceOf(swapId, swap.sender);
        (uint256 recipientBalance1, uint256 recipientBalance2) = balanceOf(swapId, swap.recipient);

        _cancelStream(swap.streamId1, swap.tokenAddress1, swap.sender);
        _cancelStream(swap.streamId2, swap.tokenAddress2, swap.recipient);

        delete streamedSwaps[swapId];

        emit CancelSwap(
            swapId,
            swap.sender,
            swap.recipient,
            senderBalance1,
            senderBalance2,
            recipientBalance1,
            recipientBalance2
        );
        return true;
    }

    /*** View Functions ***/

    /**
     * @notice Returns the compounding stream with all its properties.
     * @dev Throws if the id does not point to a valid streamedSwap.
     * @param swapId The id of the stream to query.
     * @return The swap object.
     */
    function getSwap(uint256 swapId)
        external
        view
        swapExists(swapId)
        returns (
            address sender,
            address recipient,
            uint256 deposit1,
            uint256 deposit2,
            address tokenAddress1,
            address tokenAddress2,
            uint256 startTime,
            uint256 stopTime,
            uint256 remainingBalance1,
            uint256 remainingBalance2
        )
    {
        (, recipient, deposit1, tokenAddress1, startTime, stopTime, remainingBalance1, ) = sablier.getStream(
            streamedSwaps[swapId].streamId1
        );

        // startTime and stopTime already set above so omitted.
        (, sender, deposit2, tokenAddress2, , , remainingBalance2, ) = sablier.getStream(
            streamedSwaps[swapId].streamId2
        );
    }

    /**
     * @notice Returns the available funds for the given stream id and address.
     * @dev Throws if the id does not point to a valid stream.
     * @param swapId The id of the stream for which to query the balance.
     * @param who The address for which to query the balance.
     * @return The total funds allocated to `who` as uint256.
     */
    function balanceOf(uint256 swapId, address who)
        public
        view
        swapExists(swapId)
        returns (uint256 balance1, uint256 balance2)
    {
        SwapTypes.AtomicSwap memory swap = streamedSwaps[swapId];
        balance1 = sablier.balanceOf(swap.streamId1, who);
        balance2 = sablier.balanceOf(swap.streamId2, who);
    }
}
