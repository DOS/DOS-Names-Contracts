// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IHCAFactoryBasic} from "~src/hca/interfaces/IHCAFactoryBasic.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IRegistryMetadata} from "~src/registry/interfaces/IRegistryMetadata.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";

import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";
import {SimpleRegistryMetadata} from "~src/registry/SimpleRegistryMetadata.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";

import {StandardRentPriceOracle, DiscountPoint, PaymentRatio} from "~src/registrar/StandardRentPriceOracle.sol";
import {DOSRegistrar} from "~src/registrar/DOSRegistrar.sol";
import {IDOSRegistrar} from "~src/registrar/interfaces/IDOSRegistrar.sol";
import {IRentPriceOracle} from "~src/registrar/interfaces/IRentPriceOracle.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

/// @dev Simple mock WDOS token for testing (real WDOS is a WARP precompile at 0x1111...1111).
contract MockWDOS is ERC20 {
    constructor() ERC20("Wrapped DOS", "WDOS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Integration tests for the DOS Name Service stack.
contract DOSNameServiceTest is Test {
    // ---- ERC1155 Receiver (required because deployer = this contract) ----
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x4e2312e0;
    }

    // ---- Contracts ----
    MockHCAFactoryBasic hcaFactory;
    SimpleRegistryMetadata metadata;
    PermissionedRegistry root;
    PermissionedRegistry dosTLD;
    PermissionedRegistry reverseReg;
    StandardRentPriceOracle priceOracle;
    DOSRegistrar registrar;
    MockWDOS wdos;

    // ---- Actors ----
    address deployer;
    address user;
    bytes32 constant SECRET = keccak256("my-secret");
    uint64 constant DURATION = 365 days; // 1 year
    uint64 constant MAX_EXPIRY = type(uint64).max;

    // ---- Deploy params (mirror DeployDOS.s.sol) ----
    uint64 constant MIN_COMMITMENT_AGE = 60;
    uint64 constant MAX_COMMITMENT_AGE = 86400;
    uint64 constant MIN_REGISTER_DURATION = 2419200; // 28 days

    function setUp() public {
        // Warp to a reasonable timestamp so commitment checks work
        // (default block.timestamp=1 causes 0 + MAX_COMMITMENT_AGE > 1 to be true for any empty slot)
        vm.warp(100_000);

        deployer = address(this);
        user = makeAddr("user");

        // 1. MockWDOS
        wdos = new MockWDOS();

        // 2. HCAFactory
        hcaFactory = new MockHCAFactoryBasic();

        // 3. SimpleRegistryMetadata
        metadata = new SimpleRegistryMetadata(IHCAFactoryBasic(address(hcaFactory)));

        // 4. RootRegistry
        root = new PermissionedRegistry(
            IHCAFactoryBasic(address(hcaFactory)),
            IRegistryMetadata(address(metadata)),
            deployer,
            EACBaseRolesLib.ALL_ROLES
        );

        // 5. DOSTLDRegistry
        dosTLD = new PermissionedRegistry(
            IHCAFactoryBasic(address(hcaFactory)),
            IRegistryMetadata(address(metadata)),
            deployer,
            EACBaseRolesLib.ALL_ROLES
        );

        // Register "dos" TLD in root
        root.register("dos", deployer, IRegistry(address(dosTLD)), address(0), 0, MAX_EXPIRY);

        // 6. ReverseRegistry
        reverseReg = new PermissionedRegistry(
            IHCAFactoryBasic(address(hcaFactory)),
            IRegistryMetadata(address(metadata)),
            deployer,
            EACBaseRolesLib.ALL_ROLES
        );
        root.register("reverse", deployer, IRegistry(address(reverseReg)), address(0), 0, MAX_EXPIRY);

        // 7. StandardRentPriceOracle
        uint256[] memory baseRatePerCp = new uint256[](3);
        baseRatePerCp[0] = 3_170_979_198; // 1-char: ~100 DOS/year
        baseRatePerCp[1] = 1_585_489_599; // 2-char: ~50 DOS/year
        baseRatePerCp[2] = 317_097_919;   // 3+ char: ~10 DOS/year

        DiscountPoint[] memory discountPoints = new DiscountPoint[](0);

        PaymentRatio[] memory paymentRatios = new PaymentRatio[](1);
        paymentRatios[0] = PaymentRatio({token: IERC20(address(wdos)), numer: 1, denom: 1});

        priceOracle = new StandardRentPriceOracle(
            deployer,
            IPermissionedRegistry(address(dosTLD)),
            baseRatePerCp,
            discountPoints,
            0,  // premiumPriceInitial
            0,  // premiumHalvingPeriod
            0,  // premiumPeriod
            paymentRatios
        );

        // 8. DOSRegistrar
        registrar = new DOSRegistrar(
            IPermissionedRegistry(address(dosTLD)),
            IHCAFactoryBasic(address(hcaFactory)),
            deployer,       // beneficiary
            MIN_COMMITMENT_AGE,
            MAX_COMMITMENT_AGE,
            MIN_REGISTER_DURATION,
            IRentPriceOracle(address(priceOracle))
        );

        // Grant ROLE_REGISTRAR | ROLE_RENEW to DOSRegistrar on dosTLD
        dosTLD.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(registrar)
        );

        // Fund user with WDOS
        wdos.mint(user, 10_000 ether);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @dev Full commit-reveal registration helper.
    function _registerName(string memory label, address owner_, bytes32 secret_, uint64 duration_) internal returns (uint256 tokenId) {
        bytes32 commitment = registrar.makeCommitment(
            label, owner_, secret_, IRegistry(address(0)), address(0), duration_, bytes32(0)
        );

        vm.prank(owner_);
        registrar.commit(commitment);

        vm.warp(block.timestamp + MIN_COMMITMENT_AGE + 1);

        // Approve registrar to spend WDOS
        vm.prank(owner_);
        wdos.approve(address(registrar), type(uint256).max);

        vm.prank(owner_);
        tokenId = registrar.register(
            label, owner_, secret_, IRegistry(address(0)), address(0), duration_, IERC20(address(wdos)), bytes32(0)
        );
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// @notice Verify all contracts deployed correctly, root has "dos" TLD registered.
    function test_deploymentSetup() public view {
        // HCAFactory exists
        assertTrue(address(hcaFactory) != address(0), "hcaFactory not deployed");

        // Root, dosTLD, reverseReg exist
        assertTrue(address(root) != address(0), "root not deployed");
        assertTrue(address(dosTLD) != address(0), "dosTLD not deployed");
        assertTrue(address(reverseReg) != address(0), "reverseReg not deployed");

        // "dos" TLD is registered in root (not AVAILABLE)
        IPermissionedRegistry.Status dosStatus = root.getStatus(LibLabel.id("dos"));
        assertTrue(dosStatus != IPermissionedRegistry.Status.AVAILABLE, "dos TLD not registered");

        // "reverse" is registered in root
        IPermissionedRegistry.Status reverseStatus = root.getStatus(LibLabel.id("reverse"));
        assertTrue(reverseStatus != IPermissionedRegistry.Status.AVAILABLE, "reverse not registered");

        // Registrar points to dosTLD
        assertEq(address(registrar.REGISTRY()), address(dosTLD), "registrar registry mismatch");

        // PriceOracle is set
        assertEq(address(registrar.rentPriceOracle()), address(priceOracle), "oracle mismatch");

        // Commitment age params
        assertEq(registrar.MIN_COMMITMENT_AGE(), MIN_COMMITMENT_AGE, "minCommitmentAge mismatch");
        assertEq(registrar.MAX_COMMITMENT_AGE(), MAX_COMMITMENT_AGE, "maxCommitmentAge mismatch");
        assertEq(registrar.MIN_REGISTER_DURATION(), MIN_REGISTER_DURATION, "minRegisterDuration mismatch");

        // WDOS is a valid payment token
        assertTrue(priceOracle.isPaymentToken(IERC20(address(wdos))), "WDOS not payment token");
    }

    /// @notice Full commit-reveal flow: commit -> wait -> register a ".dos" name.
    function test_registerDosName() public {
        string memory label = "testname";
        uint256 tokenId = _registerName(label, user, SECRET, DURATION);

        // Verify name is registered (not available)
        assertFalse(registrar.isAvailable(label), "name should not be available after registration");

        // Verify state in dosTLD registry
        IPermissionedRegistry.State memory state = dosTLD.getState(LibLabel.id(label));
        assertTrue(state.status == IPermissionedRegistry.Status.REGISTERED, "status should be REGISTERED");
        assertEq(state.latestOwner, user, "owner should be user");
        assertTrue(state.tokenId > 0, "tokenId should be nonzero");
        assertEq(state.tokenId, tokenId, "tokenId mismatch");
    }

    /// @notice Verify price oracle returns correct prices for 3/4/5 char names.
    function test_pricingByLength() public view {
        // baseRatePerCp: [0]=1-char, [1]=2-char, [2]=3+ char
        // For 3+ char names, rate = 317_097_919 per second
        // For 1 char, rate = 3_170_979_198
        // For 2 char, rate = 1_585_489_599

        // 1-char name "a" => uses baseRatePerCp[0]
        uint256 rate1 = priceOracle.baseRate("a");
        assertEq(rate1, 3_170_979_198, "1-char rate incorrect");

        // 2-char name "ab" => uses baseRatePerCp[1]
        uint256 rate2 = priceOracle.baseRate("ab");
        assertEq(rate2, 1_585_489_599, "2-char rate incorrect");

        // 3-char name "abc" => uses baseRatePerCp[2]
        uint256 rate3 = priceOracle.baseRate("abc");
        assertEq(rate3, 317_097_919, "3-char rate incorrect");

        // 4-char name "abcd" => also uses baseRatePerCp[2] (last entry)
        uint256 rate4 = priceOracle.baseRate("abcd");
        assertEq(rate4, 317_097_919, "4-char rate incorrect");

        // 5-char name "abcde" => also uses baseRatePerCp[2]
        uint256 rate5 = priceOracle.baseRate("abcde");
        assertEq(rate5, 317_097_919, "5-char rate incorrect");

        // Verify actual rent prices differ by name length (1 year duration)
        (uint256 base3, ) = priceOracle.rentPrice("abc", address(0), DURATION, IERC20(address(wdos)));
        (uint256 base1, ) = priceOracle.rentPrice("a", address(0), DURATION, IERC20(address(wdos)));
        assertTrue(base1 > base3, "1-char should cost more than 3-char");
    }

    /// @notice Register then renew a name.
    function test_renewDosName() public {
        string memory label = "renewable";
        _registerName(label, user, SECRET, DURATION);

        // Get state before renewal
        IPermissionedRegistry.State memory stateBefore = dosTLD.getState(LibLabel.id(label));
        uint64 expiryBefore = stateBefore.expiry;

        // Compute renewal price
        uint64 renewDuration = 365 days;
        (uint256 renewBase, ) = priceOracle.rentPrice(label, user, renewDuration, IERC20(address(wdos)));
        assertTrue(renewBase > 0, "renewal price should be > 0");

        // Approve and renew
        vm.prank(user);
        wdos.approve(address(registrar), type(uint256).max);

        vm.prank(user);
        registrar.renew(label, renewDuration, IERC20(address(wdos)), bytes32(0));

        // Verify expiry extended
        IPermissionedRegistry.State memory stateAfter = dosTLD.getState(LibLabel.id(label));
        assertEq(stateAfter.expiry, expiryBefore + renewDuration, "expiry should be extended by renewDuration");
    }

    /// @notice Cannot register the same name twice.
    function test_revertOnDuplicateRegistration() public {
        string memory label = "unique";
        _registerName(label, user, SECRET, DURATION);

        // Try to register the same name again with a new commitment
        bytes32 secret2 = keccak256("another-secret");
        bytes32 commitment = registrar.makeCommitment(
            label, user, secret2, IRegistry(address(0)), address(0), DURATION, bytes32(0)
        );

        vm.prank(user);
        registrar.commit(commitment);

        vm.warp(block.timestamp + MIN_COMMITMENT_AGE + 1);

        vm.prank(user);
        wdos.approve(address(registrar), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IDOSRegistrar.NameNotAvailable.selector, label));
        registrar.register(
            label, user, secret2, IRegistry(address(0)), address(0), DURATION, IERC20(address(wdos)), bytes32(0)
        );
    }

    /// @notice Commitment expires after maxCommitmentAge.
    function test_revertOnExpiredCommitment() public {
        string memory label = "expired";
        bytes32 commitment = registrar.makeCommitment(
            label, user, SECRET, IRegistry(address(0)), address(0), DURATION, bytes32(0)
        );

        vm.prank(user);
        registrar.commit(commitment);

        // Warp past maxCommitmentAge
        vm.warp(block.timestamp + MAX_COMMITMENT_AGE + 1);

        vm.prank(user);
        wdos.approve(address(registrar), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(); // CommitmentTooOld
        registrar.register(
            label, user, SECRET, IRegistry(address(0)), address(0), DURATION, IERC20(address(wdos)), bytes32(0)
        );
    }

    /// @notice Cannot register before minCommitmentAge.
    function test_revertOnEarlyRegistration() public {
        string memory label = "tooearly";
        bytes32 commitment = registrar.makeCommitment(
            label, user, SECRET, IRegistry(address(0)), address(0), DURATION, bytes32(0)
        );

        vm.prank(user);
        registrar.commit(commitment);

        // Only warp 30 seconds (less than minCommitmentAge=60)
        vm.warp(block.timestamp + 30);

        vm.prank(user);
        wdos.approve(address(registrar), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(); // CommitmentTooNew
        registrar.register(
            label, user, SECRET, IRegistry(address(0)), address(0), DURATION, IERC20(address(wdos)), bytes32(0)
        );
    }
}
