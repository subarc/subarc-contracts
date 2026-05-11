// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "./IERC20Minimal.sol";
import {SubArcSubscriptionV1} from "./SubArcSubscription.sol";

library CloneFactory {
    error CloneFailed();

    function clone(address implementation) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert CloneFailed();
    }
}

library SafeERC20Factory {
    error SafeTransferFailed();

    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        if (!success || (returnData.length != 0 && !abi.decode(returnData, (bool)))) {
            revert SafeTransferFailed();
        }
    }
}

contract SubArcFactoryV1 {
    using CloneFactory for address;
    using SafeERC20Factory for address;

    struct Merchant {
        bool registered;
        string metadataURI;
    }

    uint16 public constant MAX_FEE_BPS = 1_000;
    string public constant VERSION = "1.0.0";

    address public owner;
    address public feeRecipient;
    uint16 public platformFeeBps;
    address public subscriptionImplementation;
    bool public paused;

    mapping(address => Merchant) public merchants;
    mapping(address => address[]) private _merchantContracts;
    mapping(address => bool) public isService;
    address[] public allServices;

    event MerchantRegistered(address indexed merchant, string metadataURI);
    event MerchantMetadataUpdated(address indexed merchant, string metadataURI);
    event ServiceCreated(
        address indexed service,
        address indexed owner,
        address indexed token,
        uint256 price,
        uint64 interval
    );
    event SubscriptionContractCreated(
        address indexed merchant,
        address indexed service,
        address indexed paymentToken,
        string metadataURI
    );
    event PlatformFeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event TierPurchased(address indexed merchant, address indexed service, uint256 tierId);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    error NotOwner();
    error PausedError();
    error FeeRecipientZero();
    error FeeTooHigh();
    error MerchantZero();
    error TokenZero();
    error PriceZero();
    error IntervalZero();
    error ServiceUnknown();
    error NewOwnerZero();
    error ToZero();
    error AmountZero();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    constructor(address feeRecipient_, uint16 platformFeeBps_) {
        if (feeRecipient_ == address(0)) revert FeeRecipientZero();
        if (platformFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();

        owner = msg.sender;
        feeRecipient = feeRecipient_;
        platformFeeBps = platformFeeBps_;
        subscriptionImplementation = address(new SubArcSubscriptionV1());

        emit OwnershipTransferred(address(0), msg.sender);
    }

    function registerMerchant(address merchant, string memory metadataURI) public {
        if (merchant == address(0)) revert MerchantZero();
        if (merchant != msg.sender && msg.sender != owner) revert NotOwner();

        bool wasRegistered = merchants[merchant].registered;
        merchants[merchant] = Merchant({registered: true, metadataURI: metadataURI});

        if (wasRegistered) {
            emit MerchantMetadataUpdated(merchant, metadataURI);
        } else {
            emit MerchantRegistered(merchant, metadataURI);
        }
    }

    function registerMerchant(string calldata metadataURI) external {
        registerMerchant(msg.sender, metadataURI);
    }

    function createSubscriptionContract(
        address paymentToken,
        string memory metadataURI
    ) public whenNotPaused returns (address service) {
        service = _createService(paymentToken, 0, 0, metadataURI);
    }

    function createService(
        address paymentToken,
        uint256 price,
        uint64 interval
    ) external whenNotPaused returns (address service) {
        if (price == 0) revert PriceZero();
        if (interval == 0) revert IntervalZero();
        service = _createService(paymentToken, price, interval, "");
        emit ServiceCreated(service, msg.sender, paymentToken, price, interval);
    }

    function getMerchantContracts(address merchant) external view returns (address[] memory) {
        return _merchantContracts[merchant];
    }

    function getServicesByOwner(address merchant) external view returns (address[] memory) {
        return _merchantContracts[merchant];
    }

    function getCurrentFeeBps(address service) external view returns (uint16) {
        if (!isService[service]) revert ServiceUnknown();
        return platformFeeBps;
    }

    function platformWalletAddress() external view returns (address) {
        return feeRecipient;
    }

    function purchaseTier(address service, uint256 tierId) external whenNotPaused {
        if (!isService[service]) revert ServiceUnknown();
        emit TierPurchased(msg.sender, service, tierId);
    }

    function setPlatformFeeBps(uint16 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        platformFeeBps = feeBps;
        emit PlatformFeeUpdated(feeBps);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert FeeRecipientZero();
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NewOwnerZero();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ToZero();
        if (amount == 0) revert AmountZero();
        token.safeTransfer(to, amount);
        emit TokensRecovered(token, to, amount);
    }

    function _createService(
        address paymentToken,
        uint256 price,
        uint64 interval,
        string memory metadataURI
    ) internal returns (address service) {
        if (paymentToken == address(0)) revert TokenZero();
        _ensureMerchant(msg.sender);

        service = subscriptionImplementation.clone();
        SubArcSubscriptionV1(service).initialize({
            factory_: address(this),
            merchant_: msg.sender,
            paymentToken_: paymentToken,
            feeRecipient_: feeRecipient,
            feeBps_: platformFeeBps,
            defaultPrice: price,
            defaultInterval: interval,
            defaultPlanMetadataURI: metadataURI
        });

        _merchantContracts[msg.sender].push(service);
        isService[service] = true;
        allServices.push(service);

        emit SubscriptionContractCreated(msg.sender, service, paymentToken, metadataURI);
    }

    function _ensureMerchant(address merchant) internal {
        if (!merchants[merchant].registered) {
            merchants[merchant] = Merchant({registered: true, metadataURI: ""});
            emit MerchantRegistered(merchant, "");
        }
    }
}

contract SubArcFactory is SubArcFactoryV1 {
    constructor(address feeRecipient_, uint16 platformFeeBps_) SubArcFactoryV1(feeRecipient_, platformFeeBps_) {}
}
