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
            mstore(
                add(ptr, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert CloneFailed();
    }
}

library SafeERC20Factory {
    error SafeTransferFailed();
    error TokenNotContract(address token);

    function safeTransfer(address token, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
    }

    function _call(address token, bytes memory data) private {
        if (token.code.length == 0) revert TokenNotContract(token);

        (bool success, bytes memory returnData) = token.call(data);
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

    struct TierInfo {
        uint256 price;
        uint16 feeBps;
        uint64 duration;
        bool active;
    }

    struct ServiceLicense {
        uint256 tierId;
        uint64 expiresAt;
    }

    uint256 public constant TIER_FREE = 0;
    uint256 public constant TIER_PRO = 1;
    uint256 public constant TIER_ENTERPRISE = 2;
    uint16 public constant MAX_FEE_BPS = 1_000;
    string public constant VERSION = "1.0.0";

    address public owner;
    address public feeRecipient;
    uint16 public platformFeeBps;
    address public immutable subscriptionImplementation;
    bool public paused;

    mapping(address => Merchant) public merchants;
    mapping(address => address[]) private _merchantContracts;
    mapping(address => bool) public isService;
    mapping(address => address) public serviceOwner;
    mapping(address => address) public servicePaymentToken;
    mapping(address => ServiceLicense) public serviceLicenses;
    mapping(uint256 => TierInfo) public tiers;
    address[] public allServices;
    bool private _locked;

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
    event TierUpdated(
        uint256 indexed tierId, uint256 price, uint16 feeBps, uint64 duration, bool active
    );
    event TierPurchased(
        address indexed merchant,
        address indexed service,
        uint256 indexed tierId,
        uint256 price,
        uint64 expiresAt
    );
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
    error NotServiceOwner();
    error TierInactive();
    error TierFree();
    error NewOwnerZero();
    error ToZero();
    error AmountZero();
    error TokenNotContract();
    error ExpiryOverflow();
    error Reentrancy();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address feeRecipient_, uint16 platformFeeBps_) {
        if (feeRecipient_ == address(0)) revert FeeRecipientZero();
        if (platformFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();

        owner = msg.sender;
        feeRecipient = feeRecipient_;
        platformFeeBps = platformFeeBps_;
        subscriptionImplementation = address(new SubArcSubscriptionV1());

        tiers[TIER_FREE] = TierInfo({price: 0, feeBps: platformFeeBps_, duration: 0, active: true});
        tiers[TIER_PRO] = TierInfo({price: 50 * 1e6, feeBps: 100, duration: 30 days, active: true});
        tiers[TIER_ENTERPRISE] =
            TierInfo({price: 500 * 1e6, feeBps: 10, duration: 30 days, active: true});

        emit OwnershipTransferred(address(0), msg.sender);
        emit TierUpdated(TIER_FREE, 0, platformFeeBps_, 0, true);
        emit TierUpdated(TIER_PRO, 50 * 1e6, 100, 30 days, true);
        emit TierUpdated(TIER_ENTERPRISE, 500 * 1e6, 10, 30 days, true);
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

    function createSubscriptionContract(address paymentToken, string memory metadataURI)
        public
        whenNotPaused
        nonReentrant
        returns (address service)
    {
        service = _createService(paymentToken, 0, 0, metadataURI);
    }

    function createService(address paymentToken, uint256 price, uint64 interval)
        external
        whenNotPaused
        nonReentrant
        returns (address service)
    {
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
        ServiceLicense memory license = serviceLicenses[service];
        TierInfo memory tier = tiers[license.tierId];
        // forge-lint: disable-next-line(block-timestamp)
        if (license.tierId != TIER_FREE && tier.active && license.expiresAt > block.timestamp) {
            return tier.feeBps;
        }
        return platformFeeBps;
    }

    function platformWalletAddress() external view returns (address) {
        return feeRecipient;
    }

    function purchaseTier(address service, uint256 tierId) external whenNotPaused nonReentrant {
        if (!isService[service]) revert ServiceUnknown();
        if (serviceOwner[service] != msg.sender) revert NotServiceOwner();
        if (tierId == TIER_FREE) revert TierFree();

        TierInfo memory tier = tiers[tierId];
        if (!tier.active || tier.duration == 0 || tier.feeBps > MAX_FEE_BPS) revert TierInactive();

        uint64 currentTime = _toUint64(block.timestamp);
        uint64 startsAt = serviceLicenses[service].expiresAt > currentTime
            ? serviceLicenses[service].expiresAt
            : currentTime;
        if (tier.duration > type(uint64).max - startsAt) revert ExpiryOverflow();

        uint64 expiresAt = startsAt + tier.duration;
        serviceLicenses[service] = ServiceLicense({tierId: tierId, expiresAt: expiresAt});

        address paymentToken = servicePaymentToken[service];
        paymentToken.safeTransferFrom(msg.sender, feeRecipient, tier.price);

        emit TierPurchased(msg.sender, service, tierId, tier.price, expiresAt);
    }

    function setPlatformFeeBps(uint16 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        platformFeeBps = feeBps;
        tiers[TIER_FREE].feeBps = feeBps;
        emit PlatformFeeUpdated(feeBps);
        emit TierUpdated(
            TIER_FREE,
            tiers[TIER_FREE].price,
            feeBps,
            tiers[TIER_FREE].duration,
            tiers[TIER_FREE].active
        );
    }

    function setTier(uint256 tierId, uint256 price, uint16 feeBps, uint64 duration, bool active)
        external
        onlyOwner
    {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (tierId != TIER_FREE && duration == 0) revert IntervalZero();

        tiers[tierId] = TierInfo({price: price, feeBps: feeBps, duration: duration, active: active});
        emit TierUpdated(tierId, price, feeBps, duration, active);
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

    function recoverERC20(address token, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
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
        if (paymentToken.code.length == 0) revert TokenNotContract();
        _ensureMerchant(msg.sender);

        service = subscriptionImplementation.clone();
        SubArcSubscriptionV1(service)
            .initialize({
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
        serviceOwner[service] = msg.sender;
        servicePaymentToken[service] = paymentToken;
        serviceLicenses[service] = ServiceLicense({tierId: TIER_FREE, expiresAt: 0});
        allServices.push(service);

        emit SubscriptionContractCreated(msg.sender, service, paymentToken, metadataURI);
    }

    function _ensureMerchant(address merchant) internal {
        if (!merchants[merchant].registered) {
            merchants[merchant] = Merchant({registered: true, metadataURI: ""});
            emit MerchantRegistered(merchant, "");
        }
    }

    function _toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert ExpiryOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value);
    }
}

contract SubArcFactory is SubArcFactoryV1 {
    constructor(address feeRecipient_, uint16 platformFeeBps_)
        SubArcFactoryV1(feeRecipient_, platformFeeBps_)
    {}
}
