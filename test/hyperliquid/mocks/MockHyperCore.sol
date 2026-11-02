// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// A stand-in for HyperCore: the read precompiles and the CoreWriter, both controllable.
///
/// ## Why not hyper-evm-lib's simulator
///
/// The library ships a far more complete `HyperCore` simulation, and it was the first
/// choice. It requires solc ^0.8.28. Every contract in `src/` pins `pragma solidity
/// 0.8.24` and `foundry.toml` pins the compiler and `evm_version = "paris"`, both for
/// documented reasons — Paris bytecode deploys unchanged across every EVM chain worth
/// targeting. A single Solidity compilation unit cannot span the two, so using the
/// simulator would mean moving the production contracts onto a newer compiler to suit a
/// test dependency. Ahead of an audit that is the wrong way round.
///
/// There is a second reason, and on reflection it is the better one. The simulator models
/// CoreWriter actions as *succeeding* after `nextBlock()`. The single most important fact
/// about CoreWriter is that it is **fire-and-forget**: an action can be silently dropped
/// and the EVM side cannot tell. That path is where this vault's whole reservation and
/// reconcile design lives, and a simulator which always eventually succeeds cannot
/// express it. `dropNextAction` below can.
///
/// What this mock does *not* do is model matching, fees, or margin — so it proves the
/// vault's logic, not Hyperliquid's. The testnet probe in `script/probes/` is what
/// covers the rest, and the gap between the two is stated in ADR-0002 rather than
/// papered over.

/// Records what the vault sent, and can refuse to.
contract MockCoreWriter {
    bytes[] public actions;

    /// When set, the next `sendRawAction` is accepted at the EVM level and discarded.
    /// That is precisely what HyperCore does to an order with a bad tick size: the
    /// transaction succeeds and the order never exists.
    bool public dropNextAction;

    function sendRawAction(bytes calldata data) external {
        if (dropNextAction) {
            dropNextAction = false;
            return;
        }
        actions.push(data);
    }

    function setDropNextAction(bool drop) external {
        dropNextAction = drop;
    }

    function actionCount() external view returns (uint256) {
        return actions.length;
    }

    function lastAction() external view returns (bytes memory) {
        return actions[actions.length - 1];
    }

    /// The action id, read back out of the encoding: one version byte then a uint24.
    function actionIdAt(uint256 i) external view returns (uint24 id) {
        bytes memory a = actions[i];
        return (uint24(uint8(a[1])) << 16) | (uint24(uint8(a[2])) << 8) | uint24(uint8(a[3]));
    }
}

/// The margin-summary precompile at 0x…080F. Returns whatever the test set.
contract MockMarginSummary {
    struct AccountMarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    mapping(address => int64) public accountValueOf;

    function set(address user, int64 accountValue) external {
        accountValueOf[user] = accountValue;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        (, address user) = abi.decode(input, (uint32, address));
        return abi.encode(
            AccountMarginSummary({
                accountValue: accountValueOf[user], marginUsed: 0, ntlPos: 0, rawUsd: 0
            })
        );
    }
}

/// The position precompile at 0x…0800.
contract MockPosition {
    struct Position {
        int64 szi;
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }

    mapping(address => mapping(uint32 => int64)) public sziOf;

    function set(address user, uint32 perp, int64 szi) external {
        sziOf[user][perp] = szi;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        (address user, uint32 perp) = abi.decode(input, (address, uint32));
        return abi.encode(
            Position({
                szi: sziOf[user][perp],
                entryNtl: 0,
                isolatedRawUsd: 0,
                leverage: 1,
                isIsolated: false
            })
        );
    }
}

/// The mark-price precompile at 0x…0806.
contract MockMarkPx {
    mapping(uint32 => uint64) public pxOf;

    function set(uint32 perp, uint64 px) external {
        pxOf[perp] = px;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        uint32 perp = abi.decode(input, (uint32));
        return abi.encode(pxOf[perp]);
    }
}

/// The token-info precompile at 0x…080C.
///
/// `CoreWriterLib`'s bridge helpers read it to convert an EVM amount to Core wei. Set up
/// 1:1 here (`weiDecimals` equal to the EVM token's, no extra) so the tests exercise the
/// vault's arithmetic rather than the library's decimal handling, which has its own tests
/// upstream.
contract MockTokenInfo {
    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    address public evmContract;
    uint8 public weiDecimals = 6;

    function set(address evmContract_, uint8 weiDecimals_) external {
        evmContract = evmContract_;
        weiDecimals = weiDecimals_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        uint64[] memory spots = new uint64[](0);
        return abi.encode(
            TokenInfo({
                name: "USDC",
                spots: spots,
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: evmContract,
                szDecimals: 2,
                weiDecimals: weiDecimals,
                evmExtraWeiDecimals: 0
            })
        );
    }
}

/// The Core deposit wallet at 0x6B9E…0A24 (mainnet) / 0x0B80…C206 (testnet).
///
/// USDC does not reach Core by a transfer to a system address the way other tokens do —
/// it goes through this wallet, which the vault approves and then calls. Worth knowing
/// operationally: it is a real contract on the target chain, and a deployment to a chain
/// without it would have a deposit path that reverts.
interface IMintableERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MockCoreDepositWallet {
    uint256 public lastAmount;
    uint32 public lastDex;
    address public lastRecipient;
    address public token;

    function setToken(address token_) external {
        token = token_;
    }

    /// Pulls the approved tokens, as the real wallet does. This matters for more than
    /// realism: if the mock left them behind, the vault would hold its whole deposit on
    /// the EVM side and every test of the fee sweep or the withdrawal payout would be
    /// reading money that should have gone to Core.
    function deposit(uint256 amount, uint32 dex) external {
        lastAmount = amount;
        lastDex = dex;
        if (token != address(0)) {
            IMintableERC20(token).transferFrom(msg.sender, address(this), amount);
        }
    }

    function depositFor(address recipient, uint256 amount, uint32 dex) external {
        lastRecipient = recipient;
        lastAmount = amount;
        lastDex = dex;
    }
}
