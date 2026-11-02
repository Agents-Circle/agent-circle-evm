// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { HLAgentVault } from "./HLAgentVault.sol";
import { Errors } from "../libraries/Errors.sol";

/// Deploys one `HLAgentVault` clone per `(trader, listing)` and vouches for its children.
///
/// ## Why this contract is the trust edge
///
/// `AgentRegistry` has to know whether the thing calling `notifyAumDelta` is a real
/// vault, because that call is what moves a builder's AUM figure and therefore what the
/// tier ceiling is enforced against. With a singleton that was one stored address. With
/// clones it cannot be, so the registry trusts this factory and this factory attests its
/// children.
///
/// That attestation has to be unforgeable, and the way it is made unforgeable is that
/// `isVault` reads a mapping **this contract writes and nothing else can**. It is not
/// derived from `extcodehash`, not from a `CREATE2` address prediction, and not from
/// asking the candidate anything about itself — every one of those can be satisfied by
/// an attacker who controls a contract. A forged address cannot appear in a mapping only
/// `deployVault` writes to.
///
/// ADR-0001 action items 2–4.
contract HLAgentVaultFactory {
    /// Deterministic salt per pair, so one trader cannot open two vaults against the
    /// same listing and split their exposure across them to sit under a cap twice.
    mapping(bytes32 => address) public vaultFor;

    /// The canonical answer the registry relies on.
    mapping(address => bool) public isVault;

    address public immutable implementation;

    event VaultDeployed(
        address indexed vault, address indexed trader, bytes32 indexed listingId
    );

    constructor(address implementation_) {
        if (implementation_ == address(0)) revert Errors.ZeroAddress();
        implementation = implementation_;
    }

    function vaultId(address trader, bytes32 listingId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(trader, listingId));
    }

    /// Open a vault for the caller against `listingId`.
    ///
    /// Anyone may call it for themselves and nobody may call it for someone else: the
    /// trader is `msg.sender`, not a parameter. A factory that let one address open a
    /// vault owned by another would be a way to bind a stranger's address to a listing,
    /// and on HyperEVM that address is also a HyperCore account.
    ///
    /// Pass zero for either limit to inherit the listing's; overrides may only be
    /// stricter, which `initialize` enforces.
    function deployVault(bytes32 listingId, uint16 positionCapBps, uint16 maxDrawdownBps)
        external
        returns (address vault)
    {
        bytes32 id = vaultId(msg.sender, listingId);
        if (vaultFor[id] != address(0)) revert Errors.VaultAlreadyExists();

        // Deployed and registered *before* initialising, because `initialize` reads the
        // registry and a future registry read could call back here. Writing provenance
        // first means a reentrant caller sees a consistent factory rather than a vault
        // that exists but is not yet vouched for.
        vault = Clones.cloneDeterministic(implementation, id);
        vaultFor[id] = vault;
        isVault[vault] = true;

        emit VaultDeployed(vault, msg.sender, listingId);

        HLAgentVault(vault).initialize(msg.sender, listingId, positionCapBps, maxDrawdownBps);
    }

    /// Where a vault for this pair would live, whether or not it exists yet.
    ///
    /// Useful operationally: the address is also the HyperCore account, so a trader can
    /// be shown it, and funds can be checked for, before the vault is deployed.
    function predictVault(address trader, bytes32 listingId) external view returns (address) {
        return Clones.predictDeterministicAddress(
            implementation, vaultId(trader, listingId), address(this)
        );
    }
}
