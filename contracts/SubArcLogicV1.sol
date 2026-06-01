// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface ISubArcFactory {
    function getCurrentFeeBps(address service) external view returns (uint256);
    function platformWalletAddress() external view returns (address);
    function paused() external view returns (bool);
}

/**
 * @title SubArcLogicV1
 * @notice Merchant service clone that owns plans, subscriptions, and renewals.
 */
contract SubArcLogicV1 is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    error InvalidAddress();
    error InvalidPrice();
    error InvalidInterval();
    error InvalidDefaultPlan();
    error InvalidPlan();
    error InactivePlan();
    error FactoryPaused();
    error PriceMismatch();
    error IntervalMismatch();
    error FeeExceedsMax();
    error ActiveSubscriptionLocked();
    error SubscriptionNotDue();
    error RenewalWindowExpired();
    error NoActiveSubscription();
    error NoFunds();
    error NoBalance();
    error InvalidToken();
    error RenounceDisabled();

    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant RENEWAL_GRACE_PERIOD = 7 days;

    struct Plan {
        uint256 price;
        uint256 interval;
        bool isActive;
    }

    struct Subscriber {
        uint256 planId;
        uint256 expiresAt;
        bool canceled;
        uint256 agreedPrice;
        uint256 agreedInterval;
        uint256 maxFeeBps;
    }

    IERC20Upgradeable public paymentToken;
    address public factory;
    uint256 public defaultPlanId;
    uint256 public planCount;

    mapping(uint256 => Plan) public plans;
    mapping(address => Subscriber) public subscribers;

    event PlanCreated(uint256 indexed planId, uint256 price, uint256 interval, bool isDefault);
    event PlanUpdated(uint256 indexed planId, uint256 price, uint256 interval, bool isActive);
    event Subscribed(
        address indexed user,
        uint256 indexed planId,
        uint256 expiresAt,
        uint256 agreedPrice,
        uint256 agreedInterval,
        uint256 feePaid,
        uint256 netAmount
    );
    event Renewed(
        address indexed user,
        uint256 indexed planId,
        address indexed triggeredBy,
        uint256 expiresAt,
        uint256 agreedPrice,
        uint256 agreedInterval,
        uint256 feePaid,
        uint256 netAmount
    );
    event SubscriptionCancelled(address indexed user, uint256 indexed planId);
    event FundsWithdrawn(address indexed owner, address indexed token, uint256 amount);
    event ConfigUpdated(uint256 indexed planId, uint256 newPrice, uint256 newInterval);
    event Recovered(address indexed token, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address token_,
        uint256 defaultPrice_,
        uint256 defaultInterval_,
        address factory_
    ) external initializer {
        if (
            owner_ == address(0) ||
            token_ == address(0) ||
            factory_ == address(0) ||
            token_.code.length == 0 ||
            factory_.code.length == 0
        ) {
            revert InvalidAddress();
        }
        if (
            (defaultPrice_ == 0 && defaultInterval_ != 0) ||
            (defaultPrice_ != 0 && defaultInterval_ == 0)
        ) {
            revert InvalidDefaultPlan();
        }

        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _transferOwnership(owner_);

        paymentToken = IERC20Upgradeable(token_);
        factory = factory_;

        if (defaultPrice_ > 0) {
            defaultPlanId = _createPlan(defaultPrice_, defaultInterval_, true);
        }
    }

    function subscribe(
        uint256 planId,
        uint256 expectedPrice,
        uint256 expectedInterval,
        uint256 maxFeeBps
    ) external nonReentrant whenNotPaused {
        _subscribe(msg.sender, planId, expectedPrice, expectedInterval, maxFeeBps);
    }

    /**
     * @notice Called by the relayer or any external automation. Funds are still
     *         pulled by this contract from the subscriber allowance.
     */
    function renew(address user) external nonReentrant whenNotPaused {
        uint256 currentFeeBps = _requireFactoryActiveAndGetFeeBps();
        Subscriber storage subscription = subscribers[user];

        if (subscription.planId == 0 || subscription.canceled) {
            revert NoActiveSubscription();
        }
        if (subscription.expiresAt > block.timestamp) {
            revert SubscriptionNotDue();
        }
        if (block.timestamp > subscription.expiresAt + RENEWAL_GRACE_PERIOD) {
            revert RenewalWindowExpired();
        }
        if (currentFeeBps > subscription.maxFeeBps) {
            revert FeeExceedsMax();
        }

        _collectAndRecordRenewal(user, currentFeeBps, msg.sender);
    }

    /**
     * @notice Cancellation must remain available even if the service or factory is paused.
     */
    function cancelSubscription() external {
        Subscriber storage subscription = subscribers[msg.sender];
        if (subscription.planId == 0 || subscription.canceled) {
            revert NoActiveSubscription();
        }

        subscription.canceled = true;
        emit SubscriptionCancelled(msg.sender, subscription.planId);
    }

    function _subscribe(
        address user,
        uint256 planId,
        uint256 expectedPrice,
        uint256 expectedInterval,
        uint256 maxFeeBps
    ) internal {
        Plan memory plan = plans[planId];
        if (planId == 0 || plan.interval == 0) {
            revert InvalidPlan();
        }
        if (!plan.isActive) {
            revert InactivePlan();
        }
        if (plan.price != expectedPrice) {
            revert PriceMismatch();
        }
        if (plan.interval != expectedInterval) {
            revert IntervalMismatch();
        }
        if (maxFeeBps > MAX_FEE_BPS) {
            revert FeeExceedsMax();
        }

        uint256 currentFeeBps = _requireFactoryActiveAndGetFeeBps();
        if (currentFeeBps > maxFeeBps) {
            revert FeeExceedsMax();
        }

        Subscriber storage existing = subscribers[user];
        if (
            existing.planId != 0 &&
            !existing.canceled &&
            existing.expiresAt > block.timestamp &&
            existing.planId != planId
        ) {
            revert ActiveSubscriptionLocked();
        }

        _collectAndRecordInitial(user, planId, expectedPrice, expectedInterval, maxFeeBps, currentFeeBps);
    }

    function _collectAndRecordInitial(
        address user,
        uint256 planId,
        uint256 agreedPrice,
        uint256 agreedInterval,
        uint256 maxFeeBps,
        uint256 currentFeeBps
    ) internal {
        uint256 feeAmount = (agreedPrice * currentFeeBps) / 10000;
        uint256 merchantAmount = agreedPrice - feeAmount;
        address platformWallet = ISubArcFactory(factory).platformWalletAddress();

        if (feeAmount > 0 && platformWallet != address(0)) {
            paymentToken.safeTransferFrom(user, platformWallet, feeAmount);
        }
        if (merchantAmount > 0) {
            paymentToken.safeTransferFrom(user, address(this), merchantAmount);
        }

        uint256 expiry = _recordInitialSubscription(user, planId, agreedPrice, agreedInterval, maxFeeBps);

        emit Subscribed(
            user,
            planId,
            expiry,
            agreedPrice,
            agreedInterval,
            feeAmount,
            merchantAmount
        );
    }

    function _collectAndRecordRenewal(address user, uint256 currentFeeBps, address triggeredBy) internal {
        Subscriber storage subscription = subscribers[user];
        uint256 feeAmount = (subscription.agreedPrice * currentFeeBps) / 10000;
        uint256 merchantAmount = subscription.agreedPrice - feeAmount;
        address platformWallet = ISubArcFactory(factory).platformWalletAddress();

        if (feeAmount > 0 && platformWallet != address(0)) {
            paymentToken.safeTransferFrom(user, platformWallet, feeAmount);
        }
        if (merchantAmount > 0) {
            paymentToken.safeTransferFrom(user, address(this), merchantAmount);
        }

        subscription.expiresAt = block.timestamp + subscription.agreedInterval;
        subscription.canceled = false;

        emit Renewed(
            user,
            subscription.planId,
            triggeredBy,
            subscription.expiresAt,
            subscription.agreedPrice,
            subscription.agreedInterval,
            feeAmount,
            merchantAmount
        );
    }

    function _recordInitialSubscription(
        address user,
        uint256 planId,
        uint256 agreedPrice,
        uint256 agreedInterval,
        uint256 maxFeeBps
    ) internal returns (uint256) {
        Subscriber storage subscription = subscribers[user];
        uint256 currentExpiry = subscription.expiresAt;
        uint256 newExpiry;

        // Same-plan active re-subscribe is intentional MVP behavior: paying again prepays
        // one more interval instead of silently switching the subscriber to another plan.
        if (
            subscription.planId == planId &&
            !subscription.canceled &&
            currentExpiry > block.timestamp
        ) {
            newExpiry = currentExpiry + agreedInterval;
        } else {
            newExpiry = block.timestamp + agreedInterval;
        }

        subscription.planId = planId;
        subscription.expiresAt = newExpiry;
        subscription.canceled = false;
        subscription.agreedPrice = agreedPrice;
        subscription.agreedInterval = agreedInterval;
        subscription.maxFeeBps = maxFeeBps;

        return newExpiry;
    }

    function _requireFactoryActiveAndGetFeeBps() internal view returns (uint256 currentFeeBps) {
        if (ISubArcFactory(factory).paused()) {
            revert FactoryPaused();
        }

        currentFeeBps = ISubArcFactory(factory).getCurrentFeeBps(address(this));
        if (currentFeeBps > MAX_FEE_BPS) {
            currentFeeBps = MAX_FEE_BPS;
        }
    }

    function isSubscribed(address user) external view returns (bool) {
        Subscriber memory subscription = subscribers[user];
        return !subscription.canceled && subscription.expiresAt > block.timestamp;
    }

    function getSubscriptionDetails(address user)
        external
        view
        returns (
            uint256 planId,
            uint256 expiry,
            bool isActive,
            bool canceled,
            uint256 agreedPrice,
            uint256 agreedInterval,
            uint256 maxFeeBps
        )
    {
        Subscriber memory subscription = subscribers[user];
        planId = subscription.planId;
        expiry = subscription.expiresAt;
        canceled = subscription.canceled;
        isActive = !canceled && expiry > block.timestamp;
        agreedPrice = subscription.agreedPrice;
        agreedInterval = subscription.agreedInterval;
        maxFeeBps = subscription.maxFeeBps;
    }

    function getRemainingTime(address user) external view returns (uint256) {
        Subscriber memory subscription = subscribers[user];
        if (subscription.canceled || subscription.expiresAt <= block.timestamp) {
            return 0;
        }
        return subscription.expiresAt - block.timestamp;
    }

    function getPlan(uint256 planId) external view returns (Plan memory) {
        return plans[planId];
    }

    function createPlan(uint256 price, uint256 interval) external onlyOwner returns (uint256) {
        return _createPlan(price, interval, false);
    }

    function updatePlan(uint256 planId, uint256 price, uint256 interval, bool isActive) public onlyOwner {
        if (planId == 0 || plans[planId].interval == 0) {
            revert InvalidPlan();
        }
        if (price == 0) {
            revert InvalidPrice();
        }
        if (interval == 0) {
            revert InvalidInterval();
        }

        plans[planId] = Plan({price: price, interval: interval, isActive: isActive});
        emit PlanUpdated(planId, price, interval, isActive);
    }

    function _createPlan(uint256 price, uint256 interval, bool markDefault) internal returns (uint256 planId) {
        if (price == 0) {
            revert InvalidPrice();
        }
        if (interval == 0) {
            revert InvalidInterval();
        }

        planId = ++planCount;
        plans[planId] = Plan({price: price, interval: interval, isActive: true});

        if (markDefault && defaultPlanId == 0) {
            defaultPlanId = planId;
        }

        emit PlanCreated(planId, price, interval, markDefault);
    }

    function withdrawFunds() external nonReentrant onlyOwner {
        uint256 balance = paymentToken.balanceOf(address(this));
        if (balance == 0) {
            revert NoFunds();
        }

        paymentToken.safeTransfer(msg.sender, balance);
        emit FundsWithdrawn(msg.sender, address(paymentToken), balance);
    }

    function recoverERC20(address token) external nonReentrant onlyOwner {
        if (token == address(paymentToken)) {
            revert InvalidToken();
        }

        uint256 balance = IERC20Upgradeable(token).balanceOf(address(this));
        if (balance == 0) {
            revert NoBalance();
        }

        IERC20Upgradeable(token).safeTransfer(msg.sender, balance);
        emit Recovered(token, balance);
    }

    function updateConfig(uint256 newPrice, uint256 newInterval) external onlyOwner {
        if (defaultPlanId == 0) {
            defaultPlanId = _createPlan(newPrice, newInterval, true);
        } else {
            updatePlan(defaultPlanId, newPrice, newInterval, true);
        }

        emit ConfigUpdated(defaultPlanId, newPrice, newInterval);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
