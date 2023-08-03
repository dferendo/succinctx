// SPDX-License-Identifier: MIT

pragma solidity ^0.8.16;

import {IFunctionGateway, FunctionRequest} from "./interfaces/IFunctionGateway.sol";
import {IFunctionVerifier} from "./interfaces/IFunctionVerifier.sol";
import {FunctionRegistry} from "./FunctionRegistry.sol";
import {IFeeVault} from "@telepathy-v2/payment/interfaces/IFeeVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FunctionGateway is IFunctionGateway, FunctionRegistry, Ownable {
    /// @dev The proof id for an aggregate proof.
    bytes32 public constant AGGREGATION_FUNCTION_ID = keccak256("AGGREGATION_FUNCTION_ID");

    /// @dev The default gas limit for requests.
    uint256 public DEFAULT_GAS_LIMIT = 1000000;

    /// @dev Keeps track of the nonce for generating request ids.
    uint256 public nonce;

    /// @dev Maps request ids to their corresponding requests.
    mapping(bytes32 => FunctionRequest) public requests;

    /// @notice The dynamic scalar for requests.
    uint256 public scalar;

    /// @notice A reference to the contract where fees are sent.
    /// @dev During the request functions, this is used to add msg.value to the sender's balance.
    address public immutable feeVault;

    constructor(uint256 _scalar, address _feeVault, address _owner) Ownable() {
        scalar = _scalar;
        feeVault = _feeVault;
        _transferOwnership(_owner);
    }

    function request(bytes32 _functionId, bytes memory _input, bytes4 _callbackSelector, bytes memory _context)
        external
        payable
        returns (bytes32)
    {
        return request(_functionId, _input, _callbackSelector, _context, DEFAULT_GAS_LIMIT, tx.origin);
    }

    /// @dev Requests for a proof to be generated by the marketplace.
    /// @param _functionId The id of the proof to be generated.
    /// @param _input The input to the proof.
    /// @param _context The context of the runtime.
    /// @param _callbackSelector The selector of the callback function.
    function request(
        bytes32 _functionId,
        bytes memory _input,
        bytes4 _callbackSelector,
        bytes memory _context,
        uint256 _gasLimit,
        address _refundAccount
    ) public payable returns (bytes32) {
        bytes32 inputHash = keccak256(_input);
        bytes32 contextHash = keccak256(_context);
        FunctionRequest memory r = FunctionRequest({
            functionId: _functionId,
            inputHash: inputHash,
            outputHash: bytes32(0),
            contextHash: contextHash,
            callbackAddress: msg.sender,
            callbackSelector: _callbackSelector,
            proofFulfilled: false,
            callbackFulfilled: false
        });

        uint256 feeAmount = _handlePayment(_gasLimit, _refundAccount, msg.sender, msg.value);

        bytes32 requestId = keccak256(abi.encode(nonce, r));
        requests[requestId] = r;

        emit ProofRequested(nonce, requestId, _input, _context, _gasLimit, feeAmount);
        nonce++;
        return requestId;
    }

    /// @dev The entrypoint for fulfilling proofs which are not in batches.
    /// @param _requestId The id of the request to be fulfilled.
    /// @param _outputHash The output hash of the proof.
    /// @param _proof The proof.
    function fulfill(bytes32 _requestId, bytes32 _outputHash, bytes memory _proof) external {
        // Do some sanity checks.
        FunctionRequest storage r = requests[_requestId];
        if (r.callbackAddress == address(0)) {
            revert RequestNotFound(_requestId);
        } else if (r.proofFulfilled) {
            revert ProofAlreadyFulfilled(_requestId);
        }

        // Update the request.
        r.proofFulfilled = true;
        r.outputHash = _outputHash;

        // Verify the proof.
        IFunctionVerifier verifier = verifiers[r.functionId];
        if (!verifier.verify(r.inputHash, _outputHash, _proof)) {
            revert InvalidProof(address(verifier), r.inputHash, _outputHash, _proof);
        }

        emit ProofFulfilled(_requestId, _outputHash, _proof);
    }

    /// @dev The entrypoint for fulfilling proofs which are in batches.
    /// @param _requestIds The ids of the requests to be fulfilled.
    /// @param _aggregateProof The aggregate proof.
    /// @param _inputsRoot The root of the inputs.
    /// @param _outputHashes The output hashes of the proofs.
    /// @param _outputsRoot The root of the outputs.
    /// @param _verificationKeyRoot The root of the verification keys.
    function fulfillBatch(
        bytes32[] memory _requestIds,
        bytes memory _aggregateProof,
        bytes32 _inputsRoot,
        bytes32[] memory _outputHashes,
        bytes32 _outputsRoot,
        bytes32 _verificationKeyRoot
    ) external {
        // Collect the input hashes and verification key hashes.
        bytes32[] memory inputHashes = new bytes32[](_requestIds.length);
        bytes32[] memory verificationKeyHashes = new bytes32[](_requestIds.length);
        for (uint256 i = 0; i < _requestIds.length; i++) {
            bytes32 requestId = _requestIds[i];
            FunctionRequest storage r = requests[requestId];
            if (r.callbackAddress == address(0)) {
                revert RequestNotFound(requestId);
            } else if (r.proofFulfilled) {
                revert ProofAlreadyFulfilled(requestId);
            }
            inputHashes[i] = r.inputHash;
            verificationKeyHashes[i] = verifiers[r.functionId].verificationKeyHash();
        }

        // Do some sanity checks.
        if (_requestIds.length != _outputHashes.length) {
            revert LengthMismatch(_requestIds.length, _outputHashes.length);
        } else if (_inputsRoot != keccak256(abi.encode(inputHashes))) {
            revert InputsRootMismatch(_inputsRoot, inputHashes);
        } else if (_outputsRoot != keccak256(abi.encode(_outputHashes))) {
            revert OutputsRootMismatch(_outputsRoot, _outputHashes);
        } else if (_verificationKeyRoot != keccak256(abi.encode(verificationKeyHashes))) {
            revert VerificationKeysRootMismatch(_verificationKeyRoot, verificationKeyHashes);
        }

        // Update the requests.
        for (uint256 i = 0; i < _requestIds.length; i++) {
            bytes32 requestId = _requestIds[i];
            requests[requestId].proofFulfilled = true;
            requests[requestId].outputHash = _outputHashes[i];
        }

        // Verify the aggregate proof.
        IFunctionVerifier verifier = verifiers[AGGREGATION_FUNCTION_ID];
        if (!verifier.verify(_inputsRoot, _outputsRoot, _aggregateProof)) {
            revert InvalidProof(address(verifier), _inputsRoot, _outputsRoot, _aggregateProof);
        }

        emit ProofBatchFulfilled(
            _requestIds, _aggregateProof, _inputsRoot, _outputHashes, _outputsRoot, _verificationKeyRoot
        );
    }

    /// @dev Fulfills the callback for a request.
    /// @param _requestId The id of the request to be fulfilled.
    /// @param _output The output of the proof.
    /// @param _context The context of the runtime.
    function callback(bytes32 _requestId, bytes memory _output, bytes memory _context) external {
        // Do some sanity checks.
        FunctionRequest storage r = requests[_requestId];
        if (r.callbackFulfilled) {
            revert CallbackAlreadyFulfilled(_requestId);
        } else if (r.callbackAddress == address(0)) {
            revert RequestNotFound(_requestId);
        } else if (r.contextHash != keccak256(_context)) {
            revert ContextMismatch(_requestId, _context);
        } else if (r.outputHash != keccak256(_output)) {
            revert OutputMismatch(_requestId, _output);
        } else if (!r.proofFulfilled) {
            revert ProofNotFulfilled(_requestId);
        }

        // Update the request.
        r.callbackFulfilled = true;

        // Call the callback.
        (bool status,) = r.callbackAddress.call(abi.encodeWithSelector(r.callbackSelector, _output, _context));
        if (!status) {
            revert CallbackFailed(r.callbackAddress, r.callbackSelector);
        }

        emit CallbackFulfilled(_requestId, _output, _context);
    }

    /// @notice Update the scalar.
    function updateScalar(uint256 _scalar) external onlyOwner {
        scalar = _scalar;

        emit ScalarUpdated(_scalar);
    }

    /// @notice Calculates the feeAmount for the default gasLimit.
    function calculateFeeAmount() external view returns (uint256 feeAmount) {
        return calculateFeeAmount(DEFAULT_GAS_LIMIT);
    }

    /// @notice Calculates the feeAmount for a given gasLimit.
    function calculateFeeAmount(uint256 _gasLimit) public view returns (uint256 feeAmount) {
        if (scalar == 0) {
            feeAmount = tx.gasprice * _gasLimit;
        } else {
            feeAmount = tx.gasprice * _gasLimit * scalar;
        }
    }

    /// @dev Calculates the feeAmount for the request, sends the feeAmount to the FeeVault, and
    ///      sends the excess amount as a refund to the refundAccount.
    function _handlePayment(uint256 _gasLimit, address _refundAccount, address _senderAccount, uint256 _value)
        private
        returns (uint256 feeAmount)
    {
        feeAmount = calculateFeeAmount(_gasLimit);
        if (_value < feeAmount) {
            revert InsufficientFeeAmount(feeAmount, _value);
        }

        // Send the feeAmount amount to the fee vault.
        if (feeAmount > 0 && feeVault != address(0)) {
            IFeeVault(feeVault).depositNative{value: feeAmount}(_senderAccount);
        }

        // Send the excess amount to the refund account.
        uint256 refundAmount = _value - feeAmount;
        if (refundAmount > 0) {
            (bool success,) = _refundAccount.call{value: refundAmount}("");
            if (!success) {
                revert RefundFailed(_refundAccount, refundAmount);
            }
        }
    }
}
