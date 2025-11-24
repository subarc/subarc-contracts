// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract ArcSubscriptionV1 is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    address public constant USDC_ADDRESS = 0x3600000000000000000000000000000000000000;
    
    uint256 public subscriptionPrice;
    uint256 public interval;
    
    struct Subscriber {
        uint256 nextPaymentTime;
        bool isActive;
    }
    mapping(address => Subscriber) public subscribers;

    event Subscribed(address indexed user, uint256 nextPaymentTime);
    event PaymentCollected(address indexed user, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        
        subscriptionPrice = 2 * 10**6;
        interval = 60 seconds;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function subscribe() external {
        require(!subscribers[msg.sender].isActive, "Already subscribed");
        
        IERC20Upgradeable usdc = IERC20Upgradeable(USDC_ADDRESS);
        
        bool success = usdc.transferFrom(msg.sender, address(this), subscriptionPrice);
        require(success, "Payment failed. Please approve USDC first.");

        subscribers[msg.sender] = Subscriber({
            nextPaymentTime: block.timestamp + interval,
            isActive: true
        });

        emit Subscribed(msg.sender, block.timestamp + interval);
    }

    function checkSubscription(address _user) external view returns (bool) {
        return subscribers[_user].isActive;
    }
    
    function getVersion() public pure returns (string memory) {
        return "Version 1.0";
    }
}
