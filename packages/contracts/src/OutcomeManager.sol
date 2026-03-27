// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CallRegistry} from "./CallRegistry.sol";

contract OutcomeManager is EIP712, Ownable {
    using ECDSA for bytes32;

    CallRegistry public registry;

    bytes32 public constant OUTCOME_TYPEHASH =
        keccak256("Outcome(uint256 callId,bool outcome,uint256 finalPrice,uint256 timestamp)");
    
    // Mapping of authorized oracles
    mapping(address => bool) public authorizedOracle;
    
    // Total count of authorized oracles (for quorum calculation)
    uint256 public totalOracles;
    
    // Mapping to track which oracles have signed for each call
    // callId => oracle => bool (has signed)
    mapping(uint256 => mapping(address => bool)) public hasSigned;
    
    // Mapping to track signature count for each call
    mapping(uint256 => uint256) public signatureCount;
    
    // Mapping to track settled calls
    mapping(uint256 => bool) public settled;
    
    // Mapping to store final outcome once quorum is reached
    mapping(uint256 => bool) public finalOutcome;
    mapping(uint256 => uint256) public finalPrice;
    
    // Quorum threshold - number of signatures required (e.g., 2 for 2/3)
    uint256 public constant QUORUM_THRESHOLD = 2;

    event OutcomeSubmitted(uint256 indexed callId, bool outcome, uint256 finalPrice, address oracle);
    event OutcomeSettled(uint256 indexed callId, bool outcome, uint256 finalPrice, uint256 signatureCount);
    event PayoutWithdrawn(uint256 indexed callId, address indexed recipient, uint256 amount);
    event OracleAuthorizationChanged(address indexed oracle, bool status);

    constructor(address _registry) EIP712("OnChainSageOutcome", "1") Ownable(msg.sender) {
        registry = CallRegistry(_registry);
    }

    function setOracle(address _oracle, bool _status) external onlyOwner {
        // Update total oracles count when adding/removing
        if (_status && !authorizedOracle[_oracle]) {
            totalOracles++;
        } else if (!_status && authorizedOracle[_oracle]) {
            require(totalOracles > 0, "No oracles to remove");
            totalOracles--;
        }
        
        authorizedOracle[_oracle] = _status;
        emit OracleAuthorizationChanged(_oracle, _status);
    }

    function submitOutcome(
        uint256 callId,
        bool outcome,
        uint256 finalPriceArg,
        uint256 _timestamp,
        bytes calldata signature
    ) external {
        require(!settled[callId], "Already settled");

        // Verify call exists and ended
        (,,,,, uint256 endTs,,,, bool isSettled,,) = registry.calls(callId);
        require(endTs > 0, "Call not found");
        require(block.timestamp >= endTs, "Call not ended");
        require(!isSettled, "Registry says settled");

        bytes32 structHash;
        bytes32 typeHash = OUTCOME_TYPEHASH;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), callId)
            mstore(add(ptr, 0x40), outcome)
            mstore(add(ptr, 0x60), finalPriceArg)
            mstore(add(ptr, 0x80), _timestamp)
            structHash := keccak256(ptr, 0xa0)
        }
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);

        require(authorizedOracle[signer], "Invalid oracle");
        
        // Prevent double-signing by the same oracle
        require(!hasSigned[callId][signer], "Oracle already signed for this call");

        // Record the signature
        hasSigned[callId][signer] = true;
        signatureCount[callId]++;
        
        // Store the outcome data (all oracles must agree on outcome)
        finalOutcome[callId] = outcome;
        finalPrice[callId] = finalPriceArg;

        emit OutcomeSubmitted(callId, outcome, finalPriceArg, signer);

        // Check if quorum threshold is reached
        if (signatureCount[callId] >= QUORUM_THRESHOLD) {
            settled[callId] = true;
            // In a real implementation, we would call back to Registry to update state
            // For this MVP, we track settlement here and allow withdrawals based on this state
            
            emit OutcomeSettled(callId, finalOutcome[callId], finalPrice[callId], signatureCount[callId]);
        }
    }

    /**
     * @notice Get the number of signatures collected for a call
     * @param callId The ID of the call
     * @return The number of unique oracle signatures received
     */
    function getSignatureCount(uint256 callId) external view returns (uint256) {
        return signatureCount[callId];
    }

    /**
     * @notice Check if a specific oracle has signed for a call
     * @param callId The ID of the call
     * @param oracle The oracle address to check
     * @return Whether the oracle has signed
     */
    function getHasSigned(uint256 callId, address oracle) external view returns (bool) {
        return hasSigned[callId][oracle];
    }

    /**
     * @notice Get the quorum threshold
     * @return The number of signatures required for settlement
     */
    function getQuorumThreshold() external pure returns (uint256) {
        return QUORUM_THRESHOLD;
    }

    // Placeholder for withdrawal logic
    // In a full implementation, this would calculate shares and transfer tokens
    function withdrawPayout(uint256 callId) external view {
        require(settled[callId], "Not settled");
        // Implementation details omitted for brevity
    }
}
