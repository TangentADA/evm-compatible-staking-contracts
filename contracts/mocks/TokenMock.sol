// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenMock is ERC20 {

constructor() ERC20("TokenMock", "TMock") {
    _mint(
        msg.sender, 33000000000 * 10 ** decimals());
}

}