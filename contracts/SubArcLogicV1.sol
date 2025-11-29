// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface ISubArcFactory {
    function getCurrentFeeBps(address _service) external view returns (uint256);
    function platformWalletAddress() external view returns (address);
}

/**
 * @title SubArcLogicV1
 * @notice
 * - Abonelik ödemelerini alan ve süreyi yöneten kontrat.
 * - Factory tarafından "Clone" olarak çoğaltılır.
 * - Dinamik fee, Reentrancy koruması ve Pausable özelliği içerir.
 *
 * Frontend notu:
 *  - "Sadece bu ay için onayla"  -> approve(subscriptionPrice)
 *  - "Otomatik yenilemeyi aç"    -> approve(subscriptionPrice * N) veya MaxUint
 *    tamamen dApp tarafında, kontrat değişmeden yapılabilir.
 */
contract SubArcLogicV1 is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // -------------------------------------------------------------------------
    // Custom Errors (Gas-optimal revert nedenleri)
    // -------------------------------------------------------------------------

    error InvalidAddress();      // owner / token / factory 0x0 ise
    error InvalidInterval();     // interval 0 ise
    error PriceNotSet();         // subscriptionPrice 0 ise
    error NoFunds();             // çekilecek paymentToken yoksa
    error NoBalance();           // recover edilecek token yoksa
    error InvalidToken();        // recoverERC20 için paymentToken kullanılmışsa

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    IERC20Upgradeable public paymentToken;   // Kullanıcıdan alınan token (örn: USDC)
    address public factory;                 // Bağlı olduğu Factory adresi

    uint256 public subscriptionPrice;       // Tek plan abonelik ücreti
    uint256 public interval;               // Abonelik süresi (saniye cinsinden)

    // Güvenlik: Factory yanlış davranırsa bile fee %50'yi geçemez
    uint256 private constant MAX_FEE_BPS = 5000; // 5000 = %50

    struct Subscriber {
        uint256 expiresAt; // Abonelik bitiş zamanı (timestamp)
    }
    mapping(address => Subscriber) public subscribers;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Subscribed(
        address indexed user,
        uint256 expiresAt,
        uint256 feePaid,
        uint256 netAmount
    );
    event FundsWithdrawn(address indexed owner, address indexed token, uint256 amount);
    event ConfigUpdated(uint256 newPrice, uint256 newInterval);
    event Recovered(address indexed token, uint256 amount);

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Implementation kontratının doğrudan initialize edilmesini engeller.
        _disableInitializers();
    }

    /**
     * @notice Factory tarafından clone oluşturulurken çağrılır.
     * @dev Proxy pattern'deki constructor yerine geçer.
     */
    function initialize(
        address _owner,
        address _token,
        uint256 _price,
        uint256 _interval,
        address _factory
    ) external initializer {
        // 1. Input Validation (Custom Errors ile)
        if (_owner == address(0) || _token == address(0) || _factory == address(0)) {
            revert InvalidAddress();
        }
        if (_interval == 0) {
            revert InvalidInterval();
        }

        // 2. Modülleri başlat
        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _transferOwnership(_owner);

        // 3. Değer Atamaları
        paymentToken = IERC20Upgradeable(_token);
        subscriptionPrice = _price;
        interval = _interval;
        factory = _factory;
    }

    // -------------------------------------------------------------------------
    // Core Logic
    // -------------------------------------------------------------------------

    /**
     * @notice Kullanıcı abone olur veya süresini uzatır.
     * @dev Reentrancy ve Pause korumalıdır.
     */
    function subscribe() external nonReentrant whenNotPaused {
        if (subscriptionPrice == 0) {
            revert PriceNotSet();
        }

        // A. Factory'den dinamik fee bps bilgisini al
        uint256 feeBps = ISubArcFactory(factory).getCurrentFeeBps(address(this));
        address platformWallet = ISubArcFactory(factory).platformWalletAddress();

        // B. Factory bozulsa bile üst limit
        if (feeBps > MAX_FEE_BPS) {
            feeBps = MAX_FEE_BPS;
        }

        // C. Hesaplamalar (10000 baz puan üzerinden)
        uint256 feeAmount = (subscriptionPrice * feeBps) / 10000;
        uint256 merchantAmount = subscriptionPrice - feeAmount;

        // D. Transferler
        // 1) Platform payı
        if (feeAmount > 0 && platformWallet != address(0)) {
            paymentToken.safeTransferFrom(msg.sender, platformWallet, feeAmount);
        }

        // 2) Service payı (bu kontratta birikir, owner withdrawFunds ile çeker)
        if (merchantAmount > 0) {
            paymentToken.safeTransferFrom(msg.sender, address(this), merchantAmount);
        }

        // E. Abonelik süresini güncelle
        _handleSubscription(msg.sender);

        emit Subscribed(
            msg.sender,
            subscribers[msg.sender].expiresAt,
            feeAmount,
            merchantAmount
        );
    }

    function _handleSubscription(address user) internal {
        uint256 currentExpiry = subscribers[user].expiresAt;
        uint256 newExpiry;

        if (currentExpiry > block.timestamp) {
            // Zaten aktifse, süreyi uzat
            newExpiry = currentExpiry + interval;
        } else {
            // Yeni abonelik veya süresi dolmuş aboneliği yeniden başlat
            newExpiry = block.timestamp + interval;
        }

        subscribers[user].expiresAt = newExpiry;
    }

    // -------------------------------------------------------------------------
    // View Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Kullanıcının şu anda aktif aboneliği var mı?
     */
    function isSubscribed(address _user) external view returns (bool) {
        return subscribers[_user].expiresAt > block.timestamp;
    }

    /**
     * @notice Kullanıcının abonelik bitiş zamanını ve aktiflik durumunu döner.
     */
    function getSubscriptionDetails(address _user)
        external
        view
        returns (uint256 expiry, bool isActive)
    {
        expiry = subscribers[_user].expiresAt;
        isActive = expiry > block.timestamp;
    }

    /**
     * @notice Kullanıcının aboneliğinde kaç saniye kaldığını döner.
     * @dev UI tarafında bu değer gün cinsine çevrilip gösterilebilir.
     */
    function getRemainingTime(address _user) external view returns (uint256) {
        uint256 expiry = subscribers[_user].expiresAt;
        if (expiry <= block.timestamp) {
            return 0;
        }
        return expiry - block.timestamp;
    }

    // -------------------------------------------------------------------------
    // Admin Functions (Service Owner)
    // -------------------------------------------------------------------------

    /**
     * @notice Service sahibinin biriken hasılatı çekmesi için.
     */
    function withdrawFunds() external nonReentrant onlyOwner {
        uint256 balance = paymentToken.balanceOf(address(this));
        if (balance == 0) {
            revert NoFunds();
        }

        paymentToken.safeTransfer(msg.sender, balance);
        emit FundsWithdrawn(msg.sender, address(paymentToken), balance);
    }

    /**
     * @notice Yanlışlıkla bu kontrata gönderilen diğer tokenları kurtarır.
     * @dev paymentToken için kullanılamaz, onun için withdrawFunds kullanılmalı.
     */
    function recoverERC20(address _token) external nonReentrant onlyOwner {
        if (_token == address(paymentToken)) {
            revert InvalidToken();
        }

        uint256 balance = IERC20Upgradeable(_token).balanceOf(address(this));
        if (balance == 0) {
            revert NoBalance();
        }

        IERC20Upgradeable(_token).safeTransfer(msg.sender, balance);
        emit Recovered(_token, balance);
    }

    /**
     * @notice Service sahibinin abonelik fiyatı ve süresini güncellemesi için.
     */
    function updateConfig(uint256 _newPrice, uint256 _newInterval) external onlyOwner {
        if (_newInterval == 0) {
            revert InvalidInterval();
        }
        subscriptionPrice = _newPrice;
        interval = _newInterval;
        emit ConfigUpdated(_newPrice, _newInterval);
    }

    // -------------------------------------------------------------------------
    // Pause Controls (Service Owner)
    // -------------------------------------------------------------------------

    /**
     * @notice Acil durumlarda abonelik alımlarını durdurur.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Durdurulan abonelik alımlarını yeniden açar.
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
