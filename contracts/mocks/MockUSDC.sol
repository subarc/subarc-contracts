// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    /**
     * @param name   Token adı (Örn: "Mock USDC")
     * @param symbol Token sembolü (Örn: "mUSDC")
     */
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /**
     * @notice Testlerde istediğimiz adrese para basmak için.
     */
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    /**
     * @notice USDC 6 decimal kullanır.
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}