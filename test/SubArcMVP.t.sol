// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SubArcFactory, SubArcFactoryV1} from "../src/SubArcFactory.sol";
import {SubArcSubscription, SubArcSubscriptionV1} from "../src/SubArcSubscription.sol";

interface Vm {
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function warp(uint256 timestamp) external;
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
}

contract MiniTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool value, string memory message) internal pure {
        require(value, message);
    }

    function assertFalse(bool value, string memory message) internal pure {
        require(!value, message);
    }

    function assertEq(uint256 a, uint256 b, string memory message) internal pure {
        require(a == b, message);
    }

    function assertEq(address a, address b, string memory message) internal pure {
        require(a == b, message);
    }

    function assertEq(bool a, bool b, string memory message) internal pure {
        require(a == b, message);
    }
}

contract MockUSDC {
    string public constant name = "Mock USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BALANCE_LOW");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        require(balanceOf[from] >= amount, "BALANCE_LOW");
        require(allowance[from][msg.sender] >= amount, "ALLOWANCE_LOW");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ReentrantUSDC is MockUSDC {
    SubArcSubscription internal target;
    bytes32 internal planId;
    bool internal attack;

    function arm(SubArcSubscription target_, bytes32 planId_) external {
        target = target_;
        planId = planId_;
        attack = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (attack) {
            attack = false;
            target.renew(planId, 10_000000, 30 days, 500);
        }
        return super.transferFrom(from, to, amount);
    }
}

contract FeeOnTransferUSDC is MockUSDC {
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(balanceOf[from] >= amount, "BALANCE_LOW");
        require(allowance[from][msg.sender] >= amount, "ALLOWANCE_LOW");
        require(amount > 0, "AMOUNT_ZERO");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - 1;
        return true;
    }
}

contract SubArcMVPTest is MiniTest {
    address internal merchant = address(0xA11CE);
    address internal subscriber = address(0xB0B);
    address internal feeRecipient = address(0xFEE);
    address internal newFeeRecipient = address(0xFEE2);

    MockUSDC internal usdc;
    SubArcFactory internal factory;
    SubArcSubscription internal subscription;

    bytes32 internal constant BASIC_PLAN = keccak256("basic");
    uint256 internal constant PRICE = 10_000000;
    uint64 internal constant INTERVAL = 30 days;
    uint16 internal constant PLATFORM_FEE_BPS = 500;
    uint16 internal constant PRO_FEE_BPS = 100;
    uint256 internal constant PRO_PRICE = 50 * 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        factory = new SubArcFactory(feeRecipient, PLATFORM_FEE_BPS);
        factory.setPaymentTokenAllowed(address(usdc), true);
        usdc.mint(subscriber, 1_000_000000);
        usdc.mint(merchant, 1_000_000000);

        vm.prank(merchant);
        address service = factory.createSubscriptionContract(address(usdc), "ipfs://service");
        subscription = SubArcSubscription(service);
    }

    function testMerchantRegistration() public {
        vm.prank(merchant);
        factory.registerMerchant("ipfs://merchant");

        (bool registered, string memory metadataURI) = factory.merchants(merchant);
        assertTrue(registered, "merchant not registered");
        assertTrue(
            keccak256(bytes(metadataURI)) == keccak256("ipfs://merchant"), "metadata mismatch"
        );
    }

    function testPlanCreation() public {
        vm.prank(merchant);
        subscription.createPlan(BASIC_PLAN, PRICE, INTERVAL, "ipfs://plan");

        (uint256 price, uint64 interval, bool active, string memory metadataURI) =
            subscription.plans(BASIC_PLAN);
        assertEq(price, PRICE, "price mismatch");
        assertEq(uint256(interval), uint256(INTERVAL), "interval mismatch");
        assertTrue(active, "plan inactive");
        assertTrue(keccak256(bytes(metadataURI)) == keccak256("ipfs://plan"), "metadata mismatch");
    }

    function testCreateServiceCreatesDefaultPlan() public {
        vm.prank(merchant);
        address service = factory.createService(address(usdc), PRICE, INTERVAL);
        SubArcSubscription created = SubArcSubscription(service);

        (uint256 price, uint64 interval, bool active,) = created.plans(created.DEFAULT_PLAN_ID());
        assertEq(price, PRICE, "default price mismatch");
        assertEq(uint256(interval), uint256(INTERVAL), "default interval mismatch");
        assertTrue(active, "default plan inactive");
        assertTrue(factory.isService(service), "service not registered");
    }

    function testSubscribeAndIsSubscribed() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);

        assertTrue(subscription.isSubscribed(subscriber, BASIC_PLAN), "subscriber should be active");
    }

    function testRenew() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
        (, uint256 firstExpiry) = _subscriptionState(subscriber, BASIC_PLAN);

        vm.warp(block.timestamp + 10 days);
        vm.prank(subscriber);
        subscription.renew(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
        (, uint256 secondExpiry) = _subscriptionState(subscriber, BASIC_PLAN);

        assertEq(secondExpiry, firstExpiry + INTERVAL, "renew should extend from prior expiry");
    }

    function testRenewExpiredStartsFromNow() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
        vm.warp(block.timestamp + INTERVAL + 1 days);

        uint256 renewalTime = block.timestamp;
        vm.prank(subscriber);
        subscription.renew(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
        (, uint256 secondExpiry) = _subscriptionState(subscriber, BASIC_PLAN);

        assertEq(secondExpiry, renewalTime + INTERVAL, "expired renew should start from now");
    }

    function testCancel() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
        vm.prank(subscriber);
        subscription.cancel(BASIC_PLAN);

        assertFalse(subscription.isSubscribed(subscriber, BASIC_PLAN), "cancel should deactivate");
    }

    function testMerchantWithdrawal() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);

        uint256 contractBalance = usdc.balanceOf(address(subscription));
        uint256 merchantBalanceBefore = usdc.balanceOf(merchant);
        vm.prank(merchant);
        subscription.withdrawFunds(merchant, contractBalance);

        assertEq(usdc.balanceOf(address(subscription)), 0, "contract balance should be empty");
        assertEq(
            usdc.balanceOf(merchant),
            merchantBalanceBefore + contractBalance,
            "merchant did not receive funds"
        );
    }

    function testFeeSplit() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);

        uint256 expectedFee = (PRICE * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedNet = PRICE - expectedFee;
        assertEq(usdc.balanceOf(feeRecipient), expectedFee, "fee recipient mismatch");
        assertEq(usdc.balanceOf(address(subscription)), expectedNet, "merchant escrow mismatch");
    }

    function testFactoryFeeChangeAffectsExistingService() public {
        _createPlan();
        _approveSubscriber();

        factory.setPlatformFeeBps(250);

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);

        uint256 expectedFee = (PRICE * 250) / 10_000;
        assertEq(usdc.balanceOf(feeRecipient), expectedFee, "updated fee not applied");
    }

    function testFactoryFeeRecipientChangeAffectsExistingService() public {
        _createPlan();
        _approveSubscriber();

        factory.setFeeRecipient(newFeeRecipient);

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);

        uint256 expectedFee = (PRICE * PLATFORM_FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(feeRecipient), 0, "old fee recipient should not receive fee");
        assertEq(usdc.balanceOf(newFeeRecipient), expectedFee, "new fee recipient mismatch");
    }

    function testSubscribeRevertsWhenPriceChanges() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(merchant);
        subscription.setPlan(BASIC_PLAN, PRICE * 2, INTERVAL, true, "ipfs://plan-v2");

        vm.expectRevert(SubArcSubscriptionV1.PriceChanged.selector);
        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
    }

    function testSubscribeRevertsWhenIntervalChanges() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(merchant);
        subscription.setPlan(BASIC_PLAN, PRICE, INTERVAL / 2, true, "ipfs://plan-v2");

        vm.expectRevert(SubArcSubscriptionV1.IntervalChanged.selector);
        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
    }

    function testSubscribeRevertsWhenFeeExceedsMax() public {
        _createPlan();
        _approveSubscriber();

        factory.setPlatformFeeBps(600);

        vm.expectRevert(SubArcSubscriptionV1.FeeChanged.selector);
        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
    }

    function testFactoryPauseBlocksExistingServiceSubscribe() public {
        _createPlan();
        _approveSubscriber();
        factory.pause();

        vm.expectRevert(SubArcSubscriptionV1.PausedError.selector);
        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
    }

    function testPurchaseTierCollectsPaymentAndDiscountsServiceFee() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(merchant);
        usdc.approve(address(factory), PRO_PRICE);
        vm.prank(merchant);
        factory.purchaseTier(address(subscription), 1);

        assertEq(usdc.balanceOf(feeRecipient), PRO_PRICE, "tier payment missing");
        assertEq(factory.getCurrentFeeBps(address(subscription)), PRO_FEE_BPS, "pro fee not active");

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);

        uint256 expectedSubscriptionFee = (PRICE * PRO_FEE_BPS) / 10_000;
        assertEq(
            usdc.balanceOf(feeRecipient), PRO_PRICE + expectedSubscriptionFee, "pro fee mismatch"
        );
    }

    function testTierFeeSnapshotSurvivesTierUpdate() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(merchant);
        usdc.approve(address(factory), PRO_PRICE);
        vm.prank(merchant);
        factory.purchaseTier(address(subscription), 1);

        factory.setTier(1, PRO_PRICE, 300, 30 days, true);
        assertEq(
            factory.getCurrentFeeBps(address(subscription)),
            PRO_FEE_BPS,
            "active license should use fee snapshot"
        );

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PRO_FEE_BPS);

        uint256 expectedSubscriptionFee = (PRICE * PRO_FEE_BPS) / 10_000;
        assertEq(
            usdc.balanceOf(feeRecipient),
            PRO_PRICE + expectedSubscriptionFee,
            "snapshot fee mismatch"
        );
    }

    function testTierExpiryFallsBackToPlatformFee() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(merchant);
        usdc.approve(address(factory), PRO_PRICE);
        vm.prank(merchant);
        factory.purchaseTier(address(subscription), 1);

        vm.warp(block.timestamp + 31 days);

        assertEq(
            factory.getCurrentFeeBps(address(subscription)),
            PLATFORM_FEE_BPS,
            "expired tier should fall back"
        );

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);

        uint256 expectedFee = (PRICE * PLATFORM_FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(feeRecipient), PRO_PRICE + expectedFee, "fallback fee mismatch");
    }

    function testTierExactExpiryFallsBackToPlatformFee() public {
        vm.prank(merchant);
        usdc.approve(address(factory), PRO_PRICE);
        vm.prank(merchant);
        factory.purchaseTier(address(subscription), 1);

        (, uint64 expiresAt,) = factory.serviceLicenses(address(subscription));
        vm.warp(expiresAt);

        assertEq(
            factory.getCurrentFeeBps(address(subscription)),
            PLATFORM_FEE_BPS,
            "exact tier expiry should fall back"
        );
    }

    function testTokenWhitelistBlocksUnknownToken() public {
        MockUSDC other = new MockUSDC();

        vm.expectRevert(SubArcFactoryV1.TokenNotAllowed.selector);
        vm.prank(merchant);
        factory.createSubscriptionContract(address(other), "ipfs://unknown-token");
    }

    function testFeeOnTransferPaymentTokenRejected() public {
        FeeOnTransferUSDC token = new FeeOnTransferUSDC();
        token.mint(subscriber, 1_000_000000);
        factory.setPaymentTokenAllowed(address(token), true);

        vm.prank(merchant);
        address service = factory.createSubscriptionContract(address(token), "ipfs://fee-token");
        SubArcSubscription feeTokenSubscription = SubArcSubscription(service);

        vm.prank(merchant);
        feeTokenSubscription.createPlan(BASIC_PLAN, PRICE, INTERVAL, "ipfs://plan");
        vm.prank(subscriber);
        token.approve(address(feeTokenSubscription), type(uint256).max);

        vm.expectRevert();
        vm.prank(subscriber);
        feeTokenSubscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
    }

    function testOnlyServiceOwnerCanPurchaseTier() public {
        vm.prank(subscriber);
        usdc.approve(address(factory), PRO_PRICE);

        vm.expectRevert(SubArcFactoryV1.NotServiceOwner.selector);
        vm.prank(subscriber);
        factory.purchaseTier(address(subscription), 1);
    }

    function testInactiveTierCannotBePurchased() public {
        factory.setTier(1, PRO_PRICE, PRO_FEE_BPS, 30 days, false);

        vm.prank(merchant);
        usdc.approve(address(factory), PRO_PRICE);

        vm.expectRevert(SubArcFactoryV1.TierInactive.selector);
        vm.prank(merchant);
        factory.purchaseTier(address(subscription), 1);
    }

    function testPauseBlocksFactoryServiceCreation() public {
        factory.pause();

        vm.expectRevert(SubArcFactoryV1.PausedError.selector);
        vm.prank(merchant);
        factory.createSubscriptionContract(address(usdc), "ipfs://paused");
    }

    function testPauseBlocksSubscribeAndRenew() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(merchant);
        subscription.pause();

        vm.expectRevert(SubArcSubscriptionV1.PausedError.selector);
        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);

        vm.prank(merchant);
        subscription.unpause();
        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);

        vm.prank(merchant);
        subscription.pause();
        vm.expectRevert(SubArcSubscriptionV1.PausedError.selector);
        vm.prank(subscriber);
        subscription.renew(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
    }

    function testPaymentTokenCannotBeRescued() public {
        vm.expectRevert(SubArcSubscriptionV1.PaymentTokenRescueBlocked.selector);
        vm.prank(merchant);
        subscription.recoverERC20(address(usdc), merchant, 1);
    }

    function testPaymentTokenMustBeContract() public {
        vm.expectRevert(SubArcFactoryV1.TokenNotContract.selector);
        vm.prank(merchant);
        factory.createSubscriptionContract(address(0x1234), "ipfs://service");
    }

    function testImplementationCannotBeInitialized() public {
        SubArcSubscriptionV1 implementation = new SubArcSubscriptionV1();

        vm.expectRevert(SubArcSubscriptionV1.AlreadyInitialized.selector);
        implementation.initialize(
            address(factory),
            merchant,
            address(usdc),
            feeRecipient,
            PLATFORM_FEE_BPS,
            PRICE,
            INTERVAL,
            "ipfs://plan"
        );
    }

    function testNonPaymentTokenCanBeRescued() public {
        MockUSDC other = new MockUSDC();
        other.mint(address(subscription), 100);

        vm.prank(merchant);
        subscription.recoverERC20(address(other), merchant, 100);

        assertEq(other.balanceOf(merchant), 100, "rescue failed");
    }

    function testZeroInputRejects() public {
        vm.expectRevert(SubArcFactoryV1.TokenZero.selector);
        vm.prank(merchant);
        factory.createSubscriptionContract(address(0), "ipfs://service");

        vm.expectRevert(SubArcFactoryV1.PriceZero.selector);
        vm.prank(merchant);
        factory.createService(address(usdc), 0, INTERVAL);

        vm.expectRevert(SubArcFactoryV1.IntervalZero.selector);
        vm.prank(merchant);
        factory.createService(address(usdc), PRICE, 0);

        vm.expectRevert(SubArcSubscriptionV1.PriceZero.selector);
        vm.prank(merchant);
        subscription.createPlan(BASIC_PLAN, 0, INTERVAL, "ipfs://plan");

        vm.expectRevert(SubArcSubscriptionV1.IntervalZero.selector);
        vm.prank(merchant);
        subscription.createPlan(BASIC_PLAN, PRICE, 0, "ipfs://plan");

        vm.expectRevert(SubArcSubscriptionV1.ToZero.selector);
        vm.prank(merchant);
        subscription.withdrawFunds(address(0), 1);
    }

    function testExactExpiryIsInactive() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
        (, uint256 expiry) = _subscriptionState(subscriber, BASIC_PLAN);

        vm.warp(expiry);
        assertFalse(
            subscription.isSubscribed(subscriber, BASIC_PLAN), "exact expiry should be inactive"
        );
    }

    function testCancelTwiceReverts() public {
        _createPlan();
        _approveSubscriber();

        vm.prank(subscriber);
        subscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
        vm.prank(subscriber);
        subscription.cancel(BASIC_PLAN);

        vm.expectRevert(SubArcSubscriptionV1.SubscriptionCancelled.selector);
        vm.prank(subscriber);
        subscription.cancel(BASIC_PLAN);
    }

    function testOnlyMerchantCanManageServiceFundsAndPlans() public {
        vm.expectRevert(SubArcSubscriptionV1.NotMerchant.selector);
        vm.prank(subscriber);
        subscription.createPlan(BASIC_PLAN, PRICE, INTERVAL, "ipfs://plan");

        vm.expectRevert(SubArcSubscriptionV1.NotMerchant.selector);
        vm.prank(subscriber);
        subscription.withdrawFunds(subscriber, 1);

        vm.expectRevert(SubArcSubscriptionV1.NotMerchant.selector);
        vm.prank(subscriber);
        subscription.pause();
    }

    function testReentrantTokenIsBlocked() public {
        ReentrantUSDC token = new ReentrantUSDC();
        token.mint(subscriber, 1_000_000000);
        factory.setPaymentTokenAllowed(address(token), true);

        vm.prank(merchant);
        address service = factory.createSubscriptionContract(address(token), "ipfs://reentrant");
        SubArcSubscription reentrantSubscription = SubArcSubscription(service);

        vm.prank(merchant);
        reentrantSubscription.createPlan(BASIC_PLAN, PRICE, INTERVAL, "ipfs://plan");
        token.arm(reentrantSubscription, BASIC_PLAN);

        vm.prank(subscriber);
        token.approve(address(reentrantSubscription), type(uint256).max);

        vm.expectRevert();
        vm.prank(subscriber);
        reentrantSubscription.subscribe(BASIC_PLAN, PRICE, INTERVAL, PLATFORM_FEE_BPS);
        assertFalse(
            reentrantSubscription.isSubscribed(subscriber, BASIC_PLAN),
            "reentrant subscribe should fail"
        );
    }

    function _createPlan() internal {
        vm.prank(merchant);
        subscription.createPlan(BASIC_PLAN, PRICE, INTERVAL, "ipfs://plan");
    }

    function _approveSubscriber() internal {
        vm.prank(subscriber);
        usdc.approve(address(subscription), type(uint256).max);
    }

    function _subscriptionState(address user, bytes32 planId)
        internal
        view
        returns (bool cancelled, uint256 expiresAt)
    {
        (uint64 expiry, bool isCancelled) = subscription.subscriptions(user, planId);
        return (isCancelled, uint256(expiry));
    }
}
