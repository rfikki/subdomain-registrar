pragma solidity ^0.4.17;

import "./ENS.sol";
import "./Resolver.sol";
import "./RegistrarInterface.sol";
import "./HashRegistrarSimplified.sol";

/**
 * @dev Implements an ENS registrar that sells subdomains on behalf of their owners.
 *
 * Users may register a subdomain by calling `register` with the name of the domain
 * they wish to register under, and the label hash of the subdomain they want to
 * register. They must also specify the new owner of the domain, and the referrer,
 * who is paid an optional finder's fee. The registrar then configures a simple
 * default resolver, which resolves `addr` lookups to the new owner, and sets
 * the `owner` account as the owner of the subdomain in ENS.
 *
 * New domains may be added by calling `configureDomain`, then transferring
 * ownership in the ENS registry to this contract. Ownership in the contract
 * may be transferred using `transfer`, and a domain may be unlisted for sale
 * using `unlistDomain`. There is (deliberately) no way to recover ownership
 * in ENS once the name is transferred to this registrar.
 *
 * Critically, this contract does not check one key property of a listed domain:
 *
 * - Is the name UTS46 normalised?
 *
 * User applications MUST check these two elements for each domain before
 * offering them to users for registration.
 *
 * Applications should additionally check that the domains they are offering to
 * register are controlled by this registrar, since calls to `register` will
 * fail if this is not the case.
 */
contract SubdomainRegistrar is RegistrarInterface {

    // namehash('eth')
    bytes32 constant public TLD_NODE = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;

    ENS public ens;
    HashRegistrarSimplified public hashRegistrar;

    struct Domain {
        string name;
        address owner;
        address transferAddress;
        uint price;
        uint referralFeePPM;
    }

    mapping (bytes32 => Domain) domains;

    modifier new_registrar() {
        require(ens.owner(TLD_NODE) != address(hashRegistrar));
        _;
    }

    modifier owner_only(bytes32 label) {
        require(owner(label) == msg.sender);
        _;
    }

    event TransferAddressSet(bytes32 indexed label, address addr);
    event DomainUpgraded(bytes32 indexed label, string name);

    function SubdomainRegistrar(ENS _ens) public {
        ens = _ens;
        hashRegistrar = HashRegistrarSimplified(ens.owner(TLD_NODE));
    }

    /**
     * @dev owner returns the address of the account that controls a domain.
     *      Initially this is a null address. If the name has been
     *      transferred to this contract, then the internal mapping is consulted
     *      to determine who controls it. If the owner is not set,
     *      the previous owner of the deed is returned.
     * @param label The label hash of the deed to check.
     * @return The address owning the deed.
     */
    function owner(bytes32 label) public view returns (address) {

        if (domains[label].owner != 0x0) {
            return domains[label].owner;
        }

        Deed domainDeed = deed(label);
        if (domainDeed.owner() != address(this)) {
            return 0x0;
        }

        return domainDeed.previousOwner();
    }

    /**
     * @dev Transfers internal control of a name to a new account. Does not update
     *      ENS.
     * @param name The name to transfer.
     * @param newOwner The address of the new owner.
     */
    function transfer(string name, address newOwner) public owner_only(keccak256(name)) {
        bytes32 label = keccak256(name);
        OwnerChanged(keccak256(name), domains[label].owner, newOwner);
        domains[label].owner = newOwner;
    }

    /**
     * @dev Sets the resolver record for a name in ENS.
     * @param name The name to set the resolver for.
     * @param resolver The address of the resolver
     */
    function setResolver(string name, address resolver) public owner_only(keccak256(name)) {
        bytes32 label = keccak256(name);
        bytes32 node = keccak256(TLD_NODE, label);
        ens.setResolver(node, resolver);
    }

    /**
     * @dev Configures a domain for sale.
     * @param name The name to configure.
     * @param price The price in wei to charge for subdomain registrations
     * @param referralFeePPM The referral fee to offer, in parts per million
     */
    function configureDomain(string name, uint price, uint referralFeePPM) public owner_only(keccak256(name)) {
        bytes32 label = keccak256(name);
        Domain domain = domains[label];

        if (domain.owner != msg.sender) {
            domain.owner = msg.sender;
        }

        if (keccak256(domain.name) != label) {
            // New listing
            domain.name = name;
        }

        domain.price = price;
        domain.referralFeePPM = referralFeePPM;
        DomainConfigured(label);
    }

    /**
     * @dev Sets the transfer address of a domain for after an ENS update.
     * @param name The name for which to set the transfer address.
     * @param transfer The address to transfer to.
     */
    function setTransferAddress(string name, address transfer) public owner_only(keccak256(name)) {
        bytes32 label = keccak256(name);
        Domain domain = domains[label];

        require(domain.transferAddress == 0x0);

        domain.transferAddress = transfer;
        TransferAddressSet(label, transfer);
    }

    /**
     * @dev Unlists a domain
     * May only be called by the owner.
     * @param name The name of the domain to unlist.
     */
    function unlistDomain(string name) public owner_only(keccak256(name)) {
        bytes32 label = keccak256(name);
        Domain domain = domains[label];
        DomainUnlisted(label);

        domain.name = '';
        domain.owner = owner(label);
        domain.price = 0;
        domain.referralFeePPM = 0;
    }

    /**
     * @dev Returns information about a subdomain.
     * @param label The label hash for the domain.
     * @param subdomain The label for the subdomain.
     * @return domain The name of the domain, or an empty string if the subdomain
     *                is unavailable.
     * @return price The price to register a subdomain, in wei.
     * @return rent The rent to retain a subdomain, in wei per second.
     * @return referralFeePPM The referral fee for the dapp, in ppm.
     */
    function query(bytes32 label, string subdomain) public view returns (string domain, uint price, uint rent, uint referralFeePPM) {
        bytes32 node = keccak256(TLD_NODE, label);
        bytes32 subnode = keccak256(node, keccak256(subdomain));

        if (ens.owner(subnode) != 0) {
            return ('', 0, 0, 0);
        }

        Domain data = domains[label];
        return (data.name, data.price, 0, data.referralFeePPM);
    }

    /**
     * @dev Registers a subdomain.
     * @param label The label hash of the domain to register a subdomain of.
     * @param subdomain The desired subdomain label.
     * @param subdomainOwner The account that should own the newly configured subdomain.
     * @param referrer The address of the account to receive the referral fee.
     */
    function register(bytes32 label, string subdomain, address subdomainOwner, address referrer, address resolver) public payable {
        bytes32 domainNode = keccak256(TLD_NODE, label);
        bytes32 subdomainLabel = keccak256(subdomain);

        // Subdomain must not be registered already.
        require(ens.owner(keccak256(domainNode, subdomainLabel)) == address(0));

        Domain domain = domains[label];

        // Domain must be available for registration
        require(keccak256(domain.name) == label);

        // User must have paid enough
        require(msg.value >= domain.price);

        // Send any extra back
        if (msg.value > domain.price) {
            msg.sender.transfer(msg.value - domain.price);
        }

        // Send any referral fee
        uint256 total = domain.price;
        if (domain.referralFeePPM * domain.price > 0 && referrer != 0 && referrer != domain.owner) {
            uint256 referralFee = (domain.price * domain.referralFeePPM) / 1000000;
            referrer.transfer(referralFee);
            total -= referralFee;
        }

        // Send the registration fee
        if (total > 0) {
            domain.owner.transfer(total);
        }

        // Register the domain
        if (subdomainOwner == 0) {
            subdomainOwner = msg.sender;
        }
        doRegistration(domainNode, subdomainLabel, subdomainOwner, Resolver(resolver));

        NewRegistration(label, subdomain, subdomainOwner, referrer, domain.price);
    }

    function doRegistration(bytes32 node, bytes32 label, address subdomainOwner, Resolver resolver) internal {
        // Get the subdomain so we can configure it
        ens.setSubnodeOwner(node, label, this);

        bytes32 subnode = keccak256(node, label);
        // Set the subdomain's resolver
        ens.setResolver(subnode, resolver);

        // Set the address record on the resolver
        resolver.setAddr(subnode, subdomainOwner);

        // Pass ownership of the new subdomain to the registrant
        ens.setOwner(subnode, subdomainOwner);
    }

    function supportsInterface(bytes4 interfaceID) public pure returns (bool) {
        return (
            (interfaceID == 0x01ffc9a7) // supportsInterface(bytes4)
            || (interfaceID == 0xc1b15f5a) // RegistrarInterface
        );
    }

    function rentDue(bytes32 label, string subdomain) public view returns (uint timestamp) {
        return 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    }

    /**
     * @dev Upgrades the domain to a new registrar.
     * @param name The name of the domain to transfer.
     */
    function upgrade(string name) public owner_only(keccak256(name)) new_registrar {
        bytes32 label = keccak256(name);
        address transfer = domains[label].transferAddress;

        require(transfer != 0x0);

        delete domains[label];

        hashRegistrar.transfer(label, transfer);
        DomainUpgraded(label, name);
    }

    function payRent(bytes32 label, string subdomain) public payable {
        revert();
    }

    function deed(bytes32 label) internal view returns (Deed) {
        var (,deedAddress,,,) = hashRegistrar.entries(label);
        return Deed(deedAddress);
    }
}
