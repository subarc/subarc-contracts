// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISubArcLogic {
    function initialize(
        address _owner,
        address _token,
        uint256 _price,
        uint256 _interval,
        address _factory
    ) external;
}

/**
 * @title SubArcFactoryV1
 * @notice
 *  - SubArc Logic klonlarını (service) üretir
 *  - Her service için lisans (Free / Pro / Enterprise) yönetir
 *  - Self-service Pro / Enterprise upgrade
 *  - Custom fee (VIP anlaşma) desteği
 *  - Pausable (acil durum freni)
 *  - Yanlış gönderilen tokenlar için rescue fonksiyonu
 *
 *  Tier sistemi:
 *    - Free       → price = 0,    fee = 5%   (500 bps)
 *    - Pro        → price = 50$,  fee = 1%   (100 bps)
 *    - Enterprise → price = 500$, fee = 0.1% (10 bps)
 *
 *  Not:
 *    - Fee hesaplaması için Logic kontratlar:
 *        factory.getCurrentFeeBps(address(this)) çağırmalı.
 */
contract SubArcFactoryV1 is Ownable, Pausable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Core config
    // -------------------------------------------------------------------------

    // Logic implementation adresi (clone alınacak)
    address public implementation;

    // Tier ödemeleri için kullanılan token (ör: USDC)
    IERC20 public paymentToken;

    // Tier ücretleri buraya akar
    address public platformWallet;

    // Fee için hard cap (bps cinsinden) → Örn: 5000 = %50 max
    uint256 public constant MAX_FEE_BPS = 5000;

    // Örn: USDC için 6 decimals
    uint8 public constant PAYMENT_TOKEN_DECIMALS = 6;

    // -------------------------------------------------------------------------
    // Tier config
    // -------------------------------------------------------------------------

    uint256 public constant TIER_FREE       = 0;
    uint256 public constant TIER_PRO        = 1;
    uint256 public constant TIER_ENTERPRISE = 2;

    struct TierInfo {
        uint256 price;     // paymentToken cinsinden (ör: 50 * 10^6)
        uint256 feeBps;    // 100 = %1, 500 = %5
        uint256 duration;  // Lisans süresi (ör: 30 days)
        bool isActive;     // Satışta mı?
    }

    mapping(uint256 => TierInfo) public tiers;

    // -------------------------------------------------------------------------
    // Service & license state
    // -------------------------------------------------------------------------

    // Factory ile oluşturulmuş SubArc service'leri
    mapping(address => bool) public isService;

    struct License {
        uint256 tierId;
        uint256 expiresAt;
    }

    // serviceAddress => license
    mapping(address => License) public serviceLicenses;

    // Owner cüzdanına göre servis listesi
    mapping(address => address[]) public servicesByOwner;

    // Custom deals (VIP anlaşma) → tier fee'yi override eder
    mapping(address => uint256) public customFees;   // service => feeBps
    mapping(address => bool) public hasCustomFee;    // service => aktif mi?

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param _implementation  SubArcLogic implementation adresi
     * @param _paymentToken    USDC benzeri payment token adresi
     * @param _wallet          Platform fee'lerinin gideceği cüzdan
     */
    constructor(
        address _implementation,
        address _paymentToken,
        address _wallet
    ) Ownable() {
        require(_implementation != address(0), "Invalid implementation");
        require(_paymentToken != address(0), "Invalid payment token");
        require(_wallet != address(0), "Invalid platform wallet");

        implementation = _implementation;
        paymentToken = IERC20(_paymentToken);
        platformWallet = _wallet;

        // Default tier'lar:

        // Free:
        // - price: 0
        // - fee: 5% (500 bps)
        // - duration: 0 (lisans takibi yok, fallback)
        tiers[TIER_FREE] = TierInfo({
            price: 0,
            feeBps: 500,
            duration: 0,
            isActive: true
        });

        // Pro:
        // - price: 50 USDC
        // - fee: 1% (100 bps)
        // - duration: 30 gün
        tiers[TIER_PRO] = TierInfo({
            price: 50 * (10 ** PAYMENT_TOKEN_DECIMALS),
            feeBps: 100,
            duration: 30 days,
            isActive: true
        });

        // Enterprise:
        // - price: 500 USDC
        // - fee: 0.1% (10 bps)
        // - duration: 30 gün
        tiers[TIER_ENTERPRISE] = TierInfo({
            price: 500 * (10 ** PAYMENT_TOKEN_DECIMALS),
            feeBps: 10,
            duration: 30 days,
            isActive: true
        });
    }

    // -------------------------------------------------------------------------
    // Service creation
    // -------------------------------------------------------------------------

    /**
     * @notice Yeni bir SubArc service (logic clone) oluşturur.
     * @param _token    Bu servisin kendi subscription'ları için kullanacağı token
     * @param _price    Service-level subscription fiyatı
     * @param _interval Subscription interval'i (service-level)
     *
     * Not:
     *  - Factory Paused ise yeni service oluşturulamaz.
     */
    function createService(
        address _token,
        uint256 _price,
        uint256 _interval
    ) external whenNotPaused returns (address) {
        address clone = Clones.clone(implementation);

        ISubArcLogic(clone).initialize(
            msg.sender,    // service owner
            _token,
            _price,
            _interval,
            address(this)  // factory
        );

        isService[clone] = true;
        servicesByOwner[msg.sender].push(clone);

        emit ServiceCreated(clone, msg.sender);
        return clone;
    }

    // -------------------------------------------------------------------------
    // Tier purchase / upgrade
    // -------------------------------------------------------------------------

    /**
     * @notice Bir service için Pro / Enterprise lisansı satın alır veya uzatır.
     * @dev
     *  - Free tier satılmaz (price = 0, bu fonk'tan geçmez)
     *  - Herkes başka bir service'e lisans satın alabilir (sponsor modeli)
     *  - Factory Paused ise satın alma yapılamaz.
     */
    function purchaseTier(address _serviceAddress, uint256 _tierId)
        external
        whenNotPaused
    {
        require(isService[_serviceAddress], "Unknown service");

        TierInfo memory tier = tiers[_tierId];
        require(tier.isActive, "Tier not active");
        require(tier.price > 0, "Free tier not purchasable");

        // Ödemeyi al (USDC → platformWallet)
        paymentToken.safeTransferFrom(msg.sender, platformWallet, tier.price);

        // Lisansı güncelle
        License storage license = serviceLicenses[_serviceAddress];

        if (license.tierId == _tierId && license.expiresAt > block.timestamp) {
            // Aynı tier ve lisans hala aktif → süreyi ekle
            license.expiresAt += tier.duration;
        } else {
            // Farklı tier veya süresi bitmişse → resetle
            license.tierId = _tierId;
            license.expiresAt = block.timestamp + tier.duration;
        }

        emit SubscriptionPurchased(_serviceAddress, _tierId, license.expiresAt);
    }

    // -------------------------------------------------------------------------
    // Fee resolution logic
    // -------------------------------------------------------------------------

    /**
     * @notice SubArcLogic kontratları tarafından çağrılır:
     *         "Şu an benim için geçerli fee bps nedir?"
     */
    function getCurrentFeeBps(address _service) external view returns (uint256) {
        require(isService[_service], "Unknown service");

        // 1) Custom fee varsa → onu kullan
        if (hasCustomFee[_service]) {
            return customFees[_service];
        }

        // 2) Lisans var mı, süresi dolmamış mı?
        License memory license = serviceLicenses[_service];

        // Lisans yoksa veya süresi bittiyse → Free tier fee
        if (license.expiresAt < block.timestamp || license.expiresAt == 0) {
            return tiers[TIER_FREE].feeBps;
        }

        // 3) Geçerli lisans → o tier'ın fee'ini kullan
        return tiers[license.tierId].feeBps;
    }

    /**
     * @notice UI / panel için: bir service'in lisans + efektif fee bilgisini döner.
     */
    function getLicenseInfo(address _service)
        external
        view
        returns (
            uint256 tierId,
            uint256 expiresAt,
            uint256 effectiveFeeBps,
            bool customActive
        )
    {
        require(isService[_service], "Unknown service");

        License memory license = serviceLicenses[_service];
        uint256 feeBps;

        if (hasCustomFee[_service]) {
            feeBps = customFees[_service];
            customActive = true;
        } else if (license.expiresAt < block.timestamp || license.expiresAt == 0) {
            feeBps = tiers[TIER_FREE].feeBps;
        } else {
            feeBps = tiers[license.tierId].feeBps;
        }

        return (license.tierId, license.expiresAt, feeBps, customActive);
    }

    /**
     * @notice Tier detaylarını döner.
     */
    function getTier(uint256 _tierId) external view returns (TierInfo memory) {
        return tiers[_tierId];
    }

    // -------------------------------------------------------------------------
    // Admin controls (owner only)
    // -------------------------------------------------------------------------

    /**
     * @notice Belirli bir service için özel fee tanımla (VIP / enterprise deal).
     * @dev
     *  - _feeBps: bps cinsinden fee (0 = komisyon yok)
     *  - _active: false ise custom fee devre dışı kalır, tier lisansı geçerli olur.
     */
    function setCustomFee(address _service, uint256 _feeBps, bool _active) external onlyOwner {
        require(isService[_service], "Unknown service");
        require(_feeBps <= MAX_FEE_BPS, "Fee too high");

        customFees[_service] = _feeBps;
        hasCustomFee[_service] = _active;

        emit CustomFeeSet(_service, _feeBps, _active);
    }

    /**
     * @notice Tier konfigürasyonunu güncelle (fiyat, fee, süre, aktiflik).
     * @dev Fee için MAX_FEE_BPS hard cap uygulanır.
     */
    function updateTier(
        uint256 _tierId,
        uint256 _price,
        uint256 _feeBps,
        uint256 _duration,
        bool _active
    ) external onlyOwner {
        require(_feeBps <= MAX_FEE_BPS, "Fee too high");

        tiers[_tierId] = TierInfo({
            price: _price,
            feeBps: _feeBps,
            duration: _duration,
            isActive: _active
        });

        emit TierUpdated(_tierId, _price, _feeBps, _duration, _active);
    }

    /**
     * @notice Platform kasasını güncelle.
     */
    function setPlatformWallet(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "Invalid wallet");
        emit PlatformWalletUpdated(platformWallet, _newWallet);
        platformWallet = _newWallet;
    }

    // -------------------------------------------------------------------------
    // Pause / Unpause (Circuit Breaker)
    // -------------------------------------------------------------------------

    /**
     * @notice Acil durumda sistemi durdur (service yaratma & tier satışı durur).
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Sistemi yeniden aç.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Rescue (yanlış gönderilen tokenlar)
    // -------------------------------------------------------------------------

    /**
     * @notice Bu factory kontratına yanlışlıkla gönderilen ERC20 tokenları kurtar.
     * @dev
     *  - Sadece owner çağırabilir.
     *  - Genellikle paymentToken burada birikmeyeceği için, tüm tokenlar kurtarılabilir.
     */
    function recoverERC20(address _token, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Invalid recipient");
        IERC20 token = IERC20(_token);
        token.safeTransfer(_to, _amount);
        emit TokensRecovered(_token, _to, _amount);
    }

    // -------------------------------------------------------------------------
    // Convenience
    // -------------------------------------------------------------------------

    function platformWalletAddress() external view returns (address) {
        return platformWallet;
    }

    /**
     * @notice Belirli bir cüzdanın oluşturduğu tüm servislerin adreslerini döndürür.
     */
    function getServicesByOwner(address _owner) external view returns (address[] memory) {
        return servicesByOwner[_owner];
    }
}
