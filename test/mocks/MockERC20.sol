// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MockERC20
/// @notice A plain ERC-20 for tests: fixed decimals, a supply minted to the deployer, and `mint`
/// so a test can top an account up without routing tokens through a transfer.
/// @dev Deliberately ordinary. A hook under test should meet a token that behaves the way the
/// standard says — no fee on transfer, no rebasing, no transfer hooks — so that a failure in a pool
/// test is a failure of the hook and not of the token underneath it. Tokens that misbehave are
/// worth testing against, but they belong in their own mock, next to the test that wants them.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /// @param _name The token name.
    /// @param _symbol The token symbol.
    /// @param initialSupply Minted to the deployer at construction; pass 0 to start empty.
    constructor(string memory _name, string memory _symbol, uint256 initialSupply) {
        name = _name;
        symbol = _symbol;
        if (initialSupply > 0) mint(msg.sender, initialSupply);
    }

    /// @notice Mints `amount` to `to`. Unpermissioned: this is a test token.
    function mint(address to, uint256 amount) public {
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burns `amount` from `from`. Unpermissioned, for the same reason as `mint`.
    function burn(address from, uint256 amount) public {
        balanceOf[from] -= amount;
        unchecked {
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @dev An allowance of `type(uint256).max` is treated as infinite and is not decremented,
    /// which is what the routers in `lib/v4-core/src/test` expect after a max approval.
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
