// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract ArcSubscriptionV2_Safe is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ----------------------------------------------------------
    // 1) V1 İLE AYNI ALANLAR (SIRAYA DOKUNMA) 🧱
    // ----------------------------------------------------------

    // Constant storage kullanmaz, layout'u bozmaz
    address public constant USDC_ADDRESS =
        0x3600000000000000000000000000000000000000;

    uint256 public subscriptionPrice; // V1 slot 0
    uint256 public interval;          // V1 slot 1

    struct Subscriber {
        uint256 nextPaymentTime;
        bool isActive;
    }

    mapping(address => Subscriber) public subscribers; // V1 slot 2

    // ----------------------------------------------------------
    // 2) V2 İÇİN YENİ ALANLAR (EN ALTA EKLENDİ) ✅
    // ----------------------------------------------------------

    IERC20Upgradeable public usdc;      // slot 3
    uint256 public gracePeriod;         // slot 4
    bool public isSystemPaused;         // slot 5

    // Reentrancy koruması için basit lock
    bool private _reentrancyLock;       // slot 6

    // ----------------------------------------------------------
    // EVENTS
    // ----------------------------------------------------------
    event Subscribed(address indexed user, uint256 nextPaymentTime);
    event FundsWithdrawn(address indexed to, uint256 amount);
    event Paused(address account);
    event Unpaused(address account);
    event GracePeriodUpdated(uint256 oldGrace, uint256 newGrace);
    event USDCUpdated(address indexed oldToken, address indexed newToken);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ----------------------------------------------------------
    // 3) V2 İNIT (SADECE YENİ DEĞİŞKENLER) 🔁
    // ----------------------------------------------------------
    // V1'de initialize ZATEN ÇAĞRILDI. Bunu sadece upgrade sonrası 1 kere çağıracağız.
    function initializeV2() public reinitializer(2) onlyOwner {
        // İkinci kez elle kurcalamayı engellemek istersen:
        // require(address(usdc) == address(0), "Already initialized V2");

        usdc = IERC20Upgradeable(USDC_ADDRESS);
        gracePeriod = 0;
        isSystemPaused = false;
        _reentrancyLock = false;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    // ----------------------------------------------------------
    // 4) MODIFIER'LAR (MANUEL PAUSE + NON-REENTRANT) 🔒
    // ----------------------------------------------------------

    modifier whenNotPaused() {
        require(!isSystemPaused, "Sistem su an bakimda (paused)");
        _;
    }

    modifier nonReentrant() {
        require(!_reentrancyLock, "Reentrancy blocked");
        _reentrancyLock = true;
        _;
        _reentrancyLock = false;
    }

    // ----------------------------------------------------------
    // 5) KULLANICI FONKSIYONLARI 👥
    // ----------------------------------------------------------

    // V2 subscribe:
    // - Reentrancy korumali
    // - Pause durumuna bakiyor
    // - Aktif abonelik varsa ustune ekliyor (stacking)
    function subscribe() external nonReentrant whenNotPaused {
        require(subscriptionPrice > 0, "Price not set");
        require(interval > 0, "Interval not set");

        uint256 startTime = block.timestamp;
        Subscriber memory s = subscribers[msg.sender];

        // Eğer kullanıcının aktif bir süresi varsa, onu uzat
        if (s.isActive && s.nextPaymentTime > block.timestamp) {
            startTime = s.nextPaymentTime;
        }

        // USDC tokeni (initializeV2 ile set edeceğiz)
        IERC20Upgradeable token = address(usdc) == address(0)
            ? IERC20Upgradeable(USDC_ADDRESS)
            : usdc;

        token.safeTransferFrom(msg.sender, address(this), subscriptionPrice);

        subscribers[msg.sender] = Subscriber({
            nextPaymentTime: startTime + interval,
            isActive: true
        });

        emit Subscribed(msg.sender, startTime + interval);
    }

    // Grace period dahil abonelik kontrolü
    function checkSubscription(address _user) external view returns (bool) {
        Subscriber memory s = subscribers[_user];
        if (!s.isActive) return false;
        return block.timestamp < (s.nextPaymentTime + gracePeriod);
    }

    // ----------------------------------------------------------
    // 6) OWNER FONKSIYONLARI (YÖNETİM) 🛠
    // ----------------------------------------------------------

    // V1'deki fiyat / interval fonksiyonlarını kullanmaya devam edebilirsin
    // istersen buraya da yeniden ekleyebiliriz:
    function setSubscriptionPrice(uint256 _newPrice) external onlyOwner {
        require(_newPrice > 0, "Invalid price");
        subscriptionPrice = _newPrice;
    }

    function setInterval(uint256 _newInterval) external onlyOwner {
        require(_newInterval > 0, "Invalid interval");
        interval = _newInterval;
    }

    function setGracePeriod(uint256 _newGrace) external onlyOwner {
        emit GracePeriodUpdated(gracePeriod, _newGrace);
        gracePeriod = _newGrace;
    }

    function setUSDC(address _newUSDC) external onlyOwner {
        require(_newUSDC != address(0), "Zero address");
        emit USDCUpdated(address(usdc), _newUSDC);
        usdc = IERC20Upgradeable(_newUSDC);
    }

    function pause() external onlyOwner {
        isSystemPaused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        isSystemPaused = false;
        emit Unpaused(msg.sender);
    }

    function withdrawFunds() external onlyOwner nonReentrant {
        IERC20Upgradeable token = address(usdc) == address(0)
            ? IERC20Upgradeable(USDC_ADDRESS)
            : usdc;

        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "Bakiye yok");

        token.safeTransfer(msg.sender, balance);
        emit FundsWithdrawn(msg.sender, balance);
    }

    function getVersion() external pure returns (string memory) {
        return "Version 2.0 - Safe & Secure";
    }
}
