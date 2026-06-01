// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISubArcLogic {
    function initialize(
        address owner_,
        address token_,
        uint256 defaultPrice_,
        uint256 defaultInterval_,
        address factory_
    ) external;
}

interface IOwnableService {
    function owner() external view returns (address);
}

/**
 * @title SubArcFactoryV1
 * @notice Service deployment and registry layer for recurring Arc-native USDC billing.
 */
contract SubArcFactoryV1 is Ownable, Pausable {
    using SafeERC20 for IERC20;

    error RenounceDisabled();

    event ServiceCreated(address indexed service, address indexed owner);
    event SubscriptionPurchased(address indexed service, uint256 tierId, uint256 expiresAt);
    event CustomFeeSet(address indexed service, uint256 feeBps, bool active);
    event TierUpdated(
        uint256 indexed tierId,
        uint256 price,
        uint256 feeBps,
        uint256 duration,
        bool isActive
    );
    event PlatformWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    address public implementation;
    IERC20 public paymentToken;
    address public platformWallet;

    uint256 public constant MAX_FEE_BPS = 1000;
    uint8 public constant PAYMENT_TOKEN_DECIMALS = 6;

    uint256 public constant TIER_FREE = 0;
    uint256 public constant TIER_PRO = 1;
    uint256 public constant TIER_ENTERPRISE = 2;

    struct TierInfo {
        uint256 price;
        uint256 feeBps;
        uint256 duration;
        bool isActive;
    }

    struct License {
        uint256 tierId;
        uint256 expiresAt;
    }

    mapping(uint256 => TierInfo) public tiers;
    mapping(address => bool) public isService;
    // Indexing helpers only. Authorization must always use the live service owner
    // via owner(). If service ownership changes, these helper mappings may become
    // stale, so dashboards should rely on live owner checks when accuracy matters.
    mapping(address => address) public serviceOwner;
    mapping(address => License) public serviceLicenses;
    mapping(address => address[]) public servicesByOwner;
    mapping(address => uint256) public customFees;
    mapping(address => bool) public hasCustomFee;

    constructor(address implementation_, address paymentToken_, address wallet_) Ownable() {
        require(implementation_ != address(0) && implementation_.code.length > 0, "Invalid implementation");
        require(paymentToken_ != address(0) && paymentToken_.code.length > 0, "Invalid payment token");
        require(wallet_ != address(0), "Invalid platform wallet");

        implementation = implementation_;
        paymentToken = IERC20(paymentToken_);
        platformWallet = wallet_;

        tiers[TIER_FREE] = TierInfo({price: 0, feeBps: 500, duration: 0, isActive: true});
        tiers[TIER_PRO] = TierInfo({
            price: 50 * (10 ** PAYMENT_TOKEN_DECIMALS),
            feeBps: 100,
            duration: 30 days,
            isActive: true
        });
        tiers[TIER_ENTERPRISE] = TierInfo({
            price: 500 * (10 ** PAYMENT_TOKEN_DECIMALS),
            feeBps: 10,
            duration: 30 days,
            isActive: true
        });
    }

    function createService(address token) external whenNotPaused returns (address) {
        return _createService(token, 0, 0);
    }

    function createService(
        address token,
        uint256 defaultPrice,
        uint256 defaultInterval
    ) external whenNotPaused returns (address) {
        return _createService(token, defaultPrice, defaultInterval);
    }

    function _createService(
        address token,
        uint256 defaultPrice,
        uint256 defaultInterval
    ) internal returns (address clone) {
        require(token != address(0) && token.code.length > 0, "Invalid service token");
        require(token == address(paymentToken), "Unsupported payment token");

        clone = Clones.clone(implementation);

        ISubArcLogic(clone).initialize(
            msg.sender,
            token,
            defaultPrice,
            defaultInterval,
            address(this)
        );

        isService[clone] = true;
        serviceOwner[clone] = msg.sender;
        servicesByOwner[msg.sender].push(clone);

        emit ServiceCreated(clone, msg.sender);
    }

    /**
     * @notice Optional business configuration only.
     *         Authorization uses the live owner on the service contract.
     */
    function purchaseTier(address serviceAddress, uint256 tierId) external whenNotPaused {
        require(isService[serviceAddress], "Unknown service");
        require(IOwnableService(serviceAddress).owner() == msg.sender, "Not service owner");

        TierInfo memory tier = tiers[tierId];
        require(tier.isActive, "Tier not active");
        require(tier.price > 0, "Free tier not purchasable");

        paymentToken.safeTransferFrom(msg.sender, platformWallet, tier.price);

        License storage license = serviceLicenses[serviceAddress];
        if (license.tierId == tierId && license.expiresAt > block.timestamp) {
            license.expiresAt += tier.duration;
        } else {
            license.tierId = tierId;
            license.expiresAt = block.timestamp + tier.duration;
        }

        emit SubscriptionPurchased(serviceAddress, tierId, license.expiresAt);
    }

    function getCurrentFeeBps(address service) external view returns (uint256) {
        require(isService[service], "Unknown service");

        if (hasCustomFee[service]) {
            return customFees[service];
        }

        License memory license = serviceLicenses[service];
        if (license.expiresAt <= block.timestamp) {
            return tiers[TIER_FREE].feeBps;
        }

        return tiers[license.tierId].feeBps;
    }

    function getLicenseInfo(address service)
        external
        view
        returns (uint256 tierId, uint256 expiresAt, uint256 effectiveFeeBps, bool customActive)
    {
        require(isService[service], "Unknown service");

        License memory license = serviceLicenses[service];
        uint256 feeBps;

        if (hasCustomFee[service]) {
            feeBps = customFees[service];
            customActive = true;
        } else if (license.expiresAt <= block.timestamp) {
            feeBps = tiers[TIER_FREE].feeBps;
        } else {
            feeBps = tiers[license.tierId].feeBps;
        }

        return (license.tierId, license.expiresAt, feeBps, customActive);
    }

    function getTier(uint256 tierId) external view returns (TierInfo memory) {
        return tiers[tierId];
    }

    function setCustomFee(address service, uint256 feeBps, bool active) external onlyOwner {
        require(isService[service], "Unknown service");
        require(feeBps <= MAX_FEE_BPS, "Fee too high");

        customFees[service] = feeBps;
        hasCustomFee[service] = active;

        emit CustomFeeSet(service, feeBps, active);
    }

    function updateTier(
        uint256 tierId,
        uint256 price,
        uint256 feeBps,
        uint256 duration,
        bool active
    ) external onlyOwner {
        require(feeBps <= MAX_FEE_BPS, "Fee too high");
        if (tierId == TIER_FREE) {
            require(price == 0, "Free tier price must be zero");
            require(duration == 0, "Free tier duration must be zero");
        } else if (active) {
            require(price > 0, "Paid tier price required");
            require(duration > 0, "Paid tier duration required");
        }

        tiers[tierId] = TierInfo({
            price: price,
            feeBps: feeBps,
            duration: duration,
            isActive: active
        });

        emit TierUpdated(tierId, price, feeBps, duration, active);
    }

    function setPlatformWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Invalid wallet");
        emit PlatformWalletUpdated(platformWallet, newWallet);
        platformWallet = newWallet;
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

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(to, amount);
        emit TokensRecovered(token, to, amount);
    }

    function platformWalletAddress() external view returns (address) {
        return platformWallet;
    }

    function getServicesByOwner(address owner_) external view returns (address[] memory) {
        return servicesByOwner[owner_];
    }
}
