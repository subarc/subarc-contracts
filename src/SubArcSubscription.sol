// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "./IERC20Minimal.sol";

library SafeERC20Minimal {
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

interface ISubArcFactoryFees {
    function getCurrentFeeBps(address service) external view returns (uint16);
    function platformWalletAddress() external view returns (address);
}

contract SubArcSubscriptionV1 {
    using SafeERC20Minimal for address;

    struct Plan {
        uint256 price;
        uint64 interval;
        bool active;
        string metadataURI;
    }

    struct Subscription {
        uint64 expiresAt;
        bool cancelled;
    }

    bytes32 public constant DEFAULT_PLAN_ID = keccak256("default");
    uint16 public constant MAX_FEE_BPS = 1_000;
    string public constant VERSION = "1.0.0";

    address public factory;
    address public merchant;
    address public paymentToken;
    address public feeRecipient;
    uint16 public feeBps;
    bool public initialized;
    bool public paused;

    bytes32[] private _planIds;
    mapping(bytes32 => Plan) public plans;
    mapping(address => mapping(bytes32 => Subscription)) private _subscriptions;

    bool private _locked;

    event Initialized(
        address indexed factory, address indexed merchant, address indexed paymentToken
    );
    event PlanCreated(bytes32 indexed planId, uint256 price, uint64 interval, string metadataURI);
    event PlanUpdated(
        bytes32 indexed planId, uint256 price, uint64 interval, bool active, string metadataURI
    );
    event Subscribed(
        address indexed user,
        bytes32 indexed planId,
        uint64 expiresAt,
        uint256 amount,
        uint256 feePaid,
        uint256 netAmount
    );
    event Renewed(
        address indexed user,
        bytes32 indexed planId,
        uint64 expiresAt,
        uint256 amount,
        uint256 feePaid,
        uint256 netAmount
    );
    event Cancelled(address indexed user, bytes32 indexed planId, uint64 expiresAt);
    event MerchantWithdrawn(
        address indexed merchant, address indexed to, address indexed paymentToken, uint256 amount
    );
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Recovered(address indexed token, address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotInitialized();
    error NotMerchant();
    error Reentrancy();
    error PausedError();
    error FactoryZero();
    error MerchantZero();
    error TokenZero();
    error FeeRecipientZero();
    error FeeTooHigh();
    error PlanMissing();
    error PlanExists();
    error PlanInactive();
    error PriceZero();
    error IntervalZero();
    error AlreadySubscribed();
    error NotSubscribed();
    error SubscriptionCancelled();
    error ToZero();
    error AmountZero();
    error InsufficientBalance();
    error InvalidToken();
    error PaymentTokenRescueBlocked();
    error ContractExpected(address account);
    error ExpiryOverflow();

    constructor() {
        initialized = true;
    }

    modifier onlyInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    modifier onlyMerchant() {
        if (msg.sender != merchant) revert NotMerchant();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    function initialize(
        address factory_,
        address merchant_,
        address paymentToken_,
        address feeRecipient_,
        uint16 feeBps_,
        uint256 defaultPrice,
        uint64 defaultInterval,
        string calldata defaultPlanMetadataURI
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (factory_ == address(0)) revert FactoryZero();
        if (merchant_ == address(0)) revert MerchantZero();
        if (paymentToken_ == address(0)) revert TokenZero();
        if (feeRecipient_ == address(0)) revert FeeRecipientZero();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (factory_.code.length == 0) revert ContractExpected(factory_);
        if (paymentToken_.code.length == 0) revert ContractExpected(paymentToken_);

        initialized = true;
        factory = factory_;
        merchant = merchant_;
        paymentToken = paymentToken_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;

        emit Initialized(factory_, merchant_, paymentToken_);

        if (defaultPrice != 0 || defaultInterval != 0) {
            _createPlan(DEFAULT_PLAN_ID, defaultPrice, defaultInterval, defaultPlanMetadataURI);
        }
    }

    function createPlan(
        bytes32 planId,
        uint256 price,
        uint64 intervalSeconds,
        string calldata metadataURI
    ) external onlyInitialized onlyMerchant {
        _createPlan(planId, price, intervalSeconds, metadataURI);
    }

    function setPlan(
        bytes32 planId,
        uint256 price,
        uint64 intervalSeconds,
        bool active,
        string calldata metadataURI
    ) external onlyInitialized onlyMerchant {
        Plan storage plan = plans[planId];
        if (plan.interval == 0) revert PlanMissing();
        if (price == 0) revert PriceZero();
        if (intervalSeconds == 0) revert IntervalZero();

        plan.price = price;
        plan.interval = intervalSeconds;
        plan.active = active;
        plan.metadataURI = metadataURI;

        emit PlanUpdated(planId, price, intervalSeconds, active, metadataURI);
    }

    function subscribe() external {
        subscribe(DEFAULT_PLAN_ID);
    }

    function subscribe(bytes32 planId) public onlyInitialized nonReentrant whenNotPaused {
        Plan memory plan = _activePlan(planId);
        Subscription storage sub = _subscriptions[msg.sender][planId];
        if (isSubscribed(msg.sender, planId)) revert AlreadySubscribed();

        uint64 start = _toUint64(block.timestamp);
        if (plan.interval > type(uint64).max - start) revert ExpiryOverflow();
        uint64 expiresAt = start + plan.interval;
        sub.expiresAt = expiresAt;
        sub.cancelled = false;

        (uint256 feePaid, uint256 netAmount) = _collectPayment(plan.price);
        emit Subscribed(msg.sender, planId, expiresAt, plan.price, feePaid, netAmount);
    }

    function renew() external {
        renew(DEFAULT_PLAN_ID);
    }

    function renew(bytes32 planId) public onlyInitialized nonReentrant whenNotPaused {
        Plan memory plan = _activePlan(planId);
        Subscription storage sub = _subscriptions[msg.sender][planId];
        if (sub.expiresAt == 0) revert NotSubscribed();
        if (sub.cancelled) revert SubscriptionCancelled();

        uint64 currentTime = _toUint64(block.timestamp);
        uint64 start = sub.expiresAt > currentTime ? sub.expiresAt : currentTime;
        if (plan.interval > type(uint64).max - start) revert ExpiryOverflow();
        uint64 expiresAt = start + plan.interval;
        sub.expiresAt = expiresAt;

        (uint256 feePaid, uint256 netAmount) = _collectPayment(plan.price);
        emit Renewed(msg.sender, planId, expiresAt, plan.price, feePaid, netAmount);
    }

    function cancel() external {
        cancel(DEFAULT_PLAN_ID);
    }

    function cancel(bytes32 planId) public onlyInitialized {
        Subscription storage sub = _subscriptions[msg.sender][planId];
        if (sub.expiresAt == 0) revert NotSubscribed();
        if (sub.cancelled) revert SubscriptionCancelled();
        sub.cancelled = true;
        emit Cancelled(msg.sender, planId, sub.expiresAt);
    }

    function isSubscribed(address user) public view returns (bool) {
        return isSubscribed(user, DEFAULT_PLAN_ID);
    }

    function isSubscribed(address user, bytes32 planId) public view returns (bool) {
        Subscription memory sub = _subscriptions[user][planId];
        // forge-lint: disable-next-line(block-timestamp)
        return sub.expiresAt > block.timestamp && !sub.cancelled;
    }

    function subscriptions(address user) external view returns (uint64 expiresAt, bool cancelled) {
        Subscription memory sub = _subscriptions[user][DEFAULT_PLAN_ID];
        return (sub.expiresAt, sub.cancelled);
    }

    function subscriptions(address user, bytes32 planId)
        external
        view
        returns (uint64 expiresAt, bool cancelled)
    {
        Subscription memory sub = _subscriptions[user][planId];
        return (sub.expiresAt, sub.cancelled);
    }

    function subscriptionPrice() external view returns (uint256) {
        return plans[DEFAULT_PLAN_ID].price;
    }

    function interval() external view returns (uint64) {
        return plans[DEFAULT_PLAN_ID].interval;
    }

    function withdrawFunds(address to, uint256 amount)
        external
        onlyInitialized
        onlyMerchant
        nonReentrant
    {
        if (to == address(0)) revert ToZero();
        if (amount == 0) revert AmountZero();
        if (IERC20Minimal(paymentToken).balanceOf(address(this)) < amount) {
            revert InsufficientBalance();
        }

        paymentToken.safeTransfer(to, amount);
        emit MerchantWithdrawn(msg.sender, to, paymentToken, amount);
    }

    function pause() external onlyInitialized onlyMerchant {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyInitialized onlyMerchant {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function recoverERC20(address token, address to, uint256 amount)
        external
        onlyInitialized
        onlyMerchant
        nonReentrant
    {
        if (token == paymentToken) revert PaymentTokenRescueBlocked();
        if (token == address(0)) revert TokenZero();
        if (to == address(0)) revert ToZero();
        if (amount == 0) revert AmountZero();

        token.safeTransfer(to, amount);
        emit Recovered(token, to, amount);
    }

    function getPlanIds() external view returns (bytes32[] memory) {
        return _planIds;
    }

    function currentFeeConfig()
        public
        view
        returns (address currentFeeRecipient, uint16 currentFeeBps)
    {
        currentFeeRecipient = ISubArcFactoryFees(factory).platformWalletAddress();
        currentFeeBps = ISubArcFactoryFees(factory).getCurrentFeeBps(address(this));
        if (currentFeeRecipient == address(0)) revert FeeRecipientZero();
        if (currentFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
    }

    function _createPlan(
        bytes32 planId,
        uint256 price,
        uint64 intervalSeconds,
        string memory metadataURI
    ) internal {
        if (planId == bytes32(0)) revert PlanMissing();
        if (plans[planId].interval != 0) revert PlanExists();
        if (price == 0) revert PriceZero();
        if (intervalSeconds == 0) revert IntervalZero();

        plans[planId] =
            Plan({price: price, interval: intervalSeconds, active: true, metadataURI: metadataURI});
        _planIds.push(planId);

        emit PlanCreated(planId, price, intervalSeconds, metadataURI);
    }

    function _activePlan(bytes32 planId) internal view returns (Plan memory plan) {
        plan = plans[planId];
        if (plan.interval == 0) revert PlanMissing();
        if (!plan.active) revert PlanInactive();
    }

    function _collectPayment(uint256 amount) internal returns (uint256 feePaid, uint256 netAmount) {
        (address currentFeeRecipient, uint16 currentFeeBps) = currentFeeConfig();
        feeRecipient = currentFeeRecipient;
        feeBps = currentFeeBps;

        feePaid = (amount * currentFeeBps) / 10_000;
        netAmount = amount - feePaid;

        if (feePaid > 0) {
            paymentToken.safeTransferFrom(msg.sender, currentFeeRecipient, feePaid);
        }
        paymentToken.safeTransferFrom(msg.sender, address(this), netAmount);
    }

    function _toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert ExpiryOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value);
    }
}

contract SubArcSubscription is SubArcSubscriptionV1 {}
