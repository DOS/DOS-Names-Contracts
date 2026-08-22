// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {DosDomainPolicy} from "~src/registrar/DosDomainPolicy.sol";
import {DOSPolicyRegistrar} from "~src/registrar/DOSPolicyRegistrar.sol";
import {IDosDomainPolicy} from "~src/registrar/interfaces/IDosDomainPolicy.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {MigrationControllerFixture} from "~test/fixtures/MigrationControllerFixture.sol";
import {StandardRentPriceOracleFixture} from "~test/fixtures/StandardRentPriceOracleFixture.sol";
import {StandardRegistrar} from "~test/StandardRegistrar.sol";

contract DosDomainPolicyTest is MigrationControllerFixture, StandardRentPriceOracleFixture {
    uint64 constant CLAIM_DURATION = 365 days;
    uint64 constant GRACE_PERIOD = 28 days;
    uint256 constant VOUCHER_SIGNER_KEY = 0xA11CE;

    DosDomainPolicy policy;
    DOSPolicyRegistrar registrar;

    address voucherSigner = vm.addr(VOUCHER_SIGNER_KEY);
    address wallet = makeAddr("dosWallet");

    function setUp() external {
        deployMigrationControllerFixture();
        deployStandardRentPriceOracleFixture();

        policy = new DosDomainPolicy(ethRegistry, address(this), voucherSigner, 20, address(0));
        registrar = new DOSPolicyRegistrar(
            address(this),
            ethRegistry,
            beneficiary,
            rentPriceOracle,
            GRACE_PERIOD,
            StandardRegistrar.MIN_COMMITMENT_AGE,
            StandardRegistrar.MAX_COMMITMENT_AGE,
            StandardRegistrar.MIN_REGISTER_DURATION,
            address(policy)
        );
        uint256 registrarRoles = RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW;
        ethRegistry.grantRootRoles(registrarRoles, address(registrar));
        ethRegistry.revokeRootRoles(registrarRoles, address(this));
        policy.setRegistrar(registrar);

        tokenUSDC.mint(address(policy), type(uint128).max);
        vm.warp(GRACE_PERIOD + 1);
    }

    function test_claimUsesPolicySubsidyAndSetsPaidExpiry() external {
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher("alice", wallet, 1);
        bytes32 secret = keccak256("commitment secret");
        bytes memory signature = _sign(voucher);

        vm.prank(wallet);
        policy.commitClaim("alice", voucher, signature, secret);
        vm.warp(block.timestamp + registrar.MIN_COMMITMENT_AGE() + 1);

        vm.prank(wallet);
        policy.claim("alice", voucher, signature, secret);

        bytes32 labelhash = keccak256(bytes("alice"));
        assertTrue(policy.labelEverClaimed(labelhash));
        assertTrue(policy.walletEverClaimed(wallet));
        assertTrue(policy.accountEverClaimed(voucher.accountId));
        assertEq(policy.paidExpiry(labelhash), uint64(block.timestamp) + CLAIM_DURATION);
        assertTrue(policy.isDosMeEntitled("alice", wallet));
    }

    function test_claimRejectsReplay() external {
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher("alice", wallet, 1);
        bytes32 secret = keccak256("commitment secret");
        bytes memory signature = _sign(voucher);

        vm.prank(wallet);
        policy.commitClaim("alice", voucher, signature, secret);
        vm.warp(block.timestamp + registrar.MIN_COMMITMENT_AGE() + 1);
        vm.prank(wallet);
        policy.claim("alice", voucher, signature, secret);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(IDosDomainPolicy.NonceAlreadyUsed.selector, voucher.nonce)
        );
        policy.claim("alice", voucher, signature, secret);
    }

    function test_claimRejectsExternalWalletCaller() external {
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher("alice", wallet, 1);
        bytes memory signature = _sign(voucher);
        address externalWallet = makeAddr("externalWallet");

        vm.prank(externalWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IDosDomainPolicy.WrongWallet.selector, externalWallet, wallet)
        );
        policy.commitClaim("alice", voucher, signature, keccak256("commitment secret"));
    }

    function test_claimRejectsUnderscoredLabel() external {
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher("alice_id", wallet, 1);
        bytes memory signature = _sign(voucher);

        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(IDosDomainPolicy.InvalidLabel.selector, "alice_id"));
        policy.commitClaim("alice_id", voucher, signature, keccak256("commitment secret"));
    }

    function test_claimRejectsInvalidVoucherSignature() external {
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher("alice", wallet, 1);
        bytes32 digest = policy.hashVoucher(voucher);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.prank(wallet);
        vm.expectRevert(IDosDomainPolicy.InvalidVoucher.selector);
        policy.commitClaim("alice", voucher, invalidSignature, keccak256("commitment secret"));
    }

    function test_claimReusesAFrontRunCommitmentWithoutBypass() external {
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher("alice", wallet, 1);
        bytes32 secret = keccak256("commitment secret");
        bytes memory signature = _sign(voucher);
        bytes32 commitment =
            registrar.makeCommitment(
                "alice",
                wallet,
                secret,
                IRegistry(address(0)),
                address(0),
                CLAIM_DURATION,
                bytes32(0)
            );

        vm.prank(makeAddr("frontRunner"));
        registrar.commit(commitment);

        vm.prank(wallet);
        policy.commitClaim("alice", voucher, signature, secret);
        vm.warp(block.timestamp + registrar.MIN_COMMITMENT_AGE() + 1);
        vm.prank(wallet);
        policy.claim("alice", voucher, signature, secret);

        assertTrue(policy.isDosMeEntitled("alice", wallet));
    }

    function test_claimRejectsSecondFreeClaimForWallet() external {
        _claim("alice", wallet, 1);
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher("bravo", wallet, 2);
        bytes memory signature = _sign(voucher);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(IDosDomainPolicy.FirstClaimAlreadyUsed.selector, wallet)
        );
        policy.commitClaim("bravo", voucher, signature, keccak256("another secret"));
    }

    function test_claimRejectsSecondFreeClaimForLabel() external {
        _claim("alice", wallet, 1);
        address otherWallet = makeAddr("otherDosWallet");
        IDosDomainPolicy.Voucher memory voucher =
            IDosDomainPolicy.Voucher({operation: IDosDomainPolicy.Operation.CLAIM, wallet: otherWallet, accountId: _accountId(
                otherWallet
            ), labelhash: keccak256(bytes("alice")), duration: CLAIM_DURATION, paymentToken: tokenUSDC, maxPrice: 0, nonce: 2, deadline: uint64(
                block.timestamp + 1 days
            )});
        bytes memory signature = _sign(voucher);

        vm.prank(otherWallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDosDomainPolicy.LabelAlreadyClaimed.selector,
                keccak256(bytes("alice"))
            )
        );
        policy.commitClaim("alice", voucher, signature, keccak256("another secret"));
    }

    function test_claimRejectsSecondFreeClaimForAccountAfterWalletChange() external {
        _claim("alice", wallet, 1);
        address replacementWallet = makeAddr("replacementDosWallet");
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher("bravo", replacementWallet, 2);
        voucher.accountId = _accountId(wallet);
        bytes memory signature = _sign(voucher);

        vm.prank(replacementWallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDosDomainPolicy.AccountAlreadyClaimed.selector,
                voucher.accountId
            )
        );
        policy.commitClaim("bravo", voucher, signature, keccak256("replacement wallet secret"));
    }

    function test_claimRespectsVoucherPriceCap() external {
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher("alice", wallet, 1);
        voucher.maxPrice = 0;
        bytes32 secret = keccak256("commitment secret");
        bytes memory signature = _sign(voucher);

        vm.prank(wallet);
        policy.commitClaim("alice", voucher, signature, secret);
        vm.warp(block.timestamp + registrar.MIN_COMMITMENT_AGE() + 1);
        (, , uint256 actualPrice) =
            policy.quote(IDosDomainPolicy.Operation.CLAIM, "alice", CLAIM_DURATION, tokenUSDC);
        vm.expectRevert(
            abi.encodeWithSelector(IDosDomainPolicy.PriceExceedsVoucher.selector, actualPrice, 0)
        );
        vm.prank(wallet);
        policy.claim("alice", voucher, signature, secret);
    }

    function test_pauseBlocksClaimButNotEntitlementRead() external {
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher("alice", wallet, 1);
        bytes memory signature = _sign(voucher);
        policy.pause();

        assertFalse(policy.isDosMeEntitled("alice", wallet));
        vm.prank(wallet);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        policy.commitClaim("alice", voucher, signature, keccak256("commitment secret"));
    }

    function test_renewWorksDuringGracePeriod() external {
        _claim("alice", wallet, 1);
        bytes32 labelhash = keccak256(bytes("alice"));
        uint64 previousPaidExpiry = policy.paidExpiry(labelhash);
        vm.warp(previousPaidExpiry + 1);

        IDosDomainPolicy.Voucher memory voucher =
            _voucher(IDosDomainPolicy.Operation.RENEW, "alice", wallet, 2, CLAIM_DURATION);
        bytes memory signature = _sign(voucher);
        _fundAndApprove(wallet, voucher.maxPrice);

        vm.prank(wallet);
        policy.renew("alice", voucher, signature);

        assertEq(policy.paidExpiry(labelhash), previousPaidExpiry + CLAIM_DURATION);
        assertTrue(policy.isDosMeEntitled("alice", wallet));
    }

    function test_renewRejectsPreviousOwnerAfterTransfer() external {
        _claim("alice", wallet, 1);
        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id("alice"));
        address buyer = makeAddr("buyer");
        vm.prank(wallet);
        ethRegistry.safeTransferFrom(wallet, buyer, state.tokenId, 1, "");

        IDosDomainPolicy.Voucher memory voucher =
            _voucher(IDosDomainPolicy.Operation.RENEW, "alice", wallet, 2, CLAIM_DURATION);
        bytes memory signature = _sign(voucher);
        _fundAndApprove(wallet, voucher.maxPrice);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(IDosDomainPolicy.NotCurrentOwner.selector, wallet, buyer)
        );
        policy.renew("alice", voucher, signature);
    }

    function test_transferredOwnerCanRenewWithAValidVoucher() external {
        _claim("alice", wallet, 1);
        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id("alice"));
        address buyer = makeAddr("buyerDosWallet");
        vm.prank(wallet);
        ethRegistry.safeTransferFrom(wallet, buyer, state.tokenId, 1, "");

        IDosDomainPolicy.Voucher memory voucher =
            _voucher(IDosDomainPolicy.Operation.RENEW, "alice", buyer, 2, CLAIM_DURATION);
        bytes memory signature = _sign(voucher);
        _fundAndApprove(buyer, voucher.maxPrice);

        assertTrue(policy.isRenewalEligible("alice", buyer));
        vm.prank(buyer);
        policy.renew("alice", voucher, signature);

        assertEq(policy.paidExpiry(keccak256(bytes("alice"))), state.expiry + CLAIM_DURATION);
    }

    function test_entitlementRevokesForTransferAndAfterGrace() external {
        _claim("alice", wallet, 1);
        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id("alice"));
        address buyer = makeAddr("buyer");
        vm.prank(wallet);
        ethRegistry.safeTransferFrom(wallet, buyer, state.tokenId, 1, "");

        assertFalse(policy.isDosMeEntitled("alice", wallet));
        assertTrue(policy.isDosMeEntitled("alice", buyer));

        vm.warp(policy.paidExpiry(keccak256(bytes("alice"))) + GRACE_PERIOD);
        assertFalse(policy.isDosMeEntitled("alice", buyer));
    }

    function test_entitlementRemainsDuringGracePeriod() external {
        _claim("alice", wallet, 1);
        uint64 expiry = policy.paidExpiry(keccak256(bytes("alice")));

        vm.warp(uint256(expiry) + 1);

        assertTrue(policy.isDosMeEntitled("alice", wallet));
    }

    function test_legacyNameCannotClaimFreeAndCanBeReclaimedAfterGrace() external {
        address legacyWallet = makeAddr("legacyDosWallet");
        uint64 expiry = uint64(block.timestamp + 1 days);
        _registerLegacy("legacy", legacyWallet, expiry);
        vm.warp(uint256(expiry) + GRACE_PERIOD);

        bytes32 labelhash = keccak256(bytes("legacy"));
        assertTrue(policy.hasHistoricalClaim(labelhash));
        assertTrue(policy.isReclaimEligible("legacy"));

        address newWallet = makeAddr("newDosWallet");
        IDosDomainPolicy.Voucher memory freeVoucher = _claimVoucher("legacy", newWallet, 1);
        bytes memory freeSignature = _sign(freeVoucher);
        vm.prank(newWallet);
        vm.expectRevert(
            abi.encodeWithSelector(IDosDomainPolicy.LabelAlreadyClaimed.selector, labelhash)
        );
        policy.commitClaim("legacy", freeVoucher, freeSignature, keccak256("legacy free claim"));

        IDosDomainPolicy.Voucher memory reclaimVoucher =
            _voucher(IDosDomainPolicy.Operation.RECLAIM, "legacy", newWallet, 2, CLAIM_DURATION);
        bytes memory reclaimSignature = _sign(reclaimVoucher);
        bytes32 secret = keccak256("legacy reclaim");
        _fundAndApprove(newWallet, reclaimVoucher.maxPrice);

        vm.prank(newWallet);
        policy.commitReclaim("legacy", reclaimVoucher, reclaimSignature, secret);
        vm.warp(block.timestamp + registrar.MIN_COMMITMENT_AGE() + 1);
        vm.prank(newWallet);
        policy.reclaim("legacy", reclaimVoucher, reclaimSignature, secret);

        assertTrue(policy.isDosMeEntitled("legacy", newWallet));
    }

    function test_legacyOwnerRenewsDuringGraceAndInitializesPolicyExpiry() external {
        address legacyWallet = makeAddr("legacyDosWallet");
        uint64 expiry = uint64(block.timestamp + 1 days);
        _registerLegacy("legacy", legacyWallet, expiry);
        vm.warp(uint256(expiry) + 1);

        IDosDomainPolicy.Voucher memory voucher =
            _voucher(IDosDomainPolicy.Operation.RENEW, "legacy", legacyWallet, 1, CLAIM_DURATION);
        bytes memory signature = _sign(voucher);
        _fundAndApprove(legacyWallet, voucher.maxPrice);

        vm.prank(legacyWallet);
        policy.renew("legacy", voucher, signature);

        assertEq(policy.paidExpiry(keccak256(bytes("legacy"))), expiry + CLAIM_DURATION);
        assertTrue(policy.accountEverClaimed(voucher.accountId));
        assertTrue(policy.isDosMeEntitled("legacy", legacyWallet));
    }

    function test_reclaimAfterGraceRequiresPaidVoucher() external {
        _claim("alice", wallet, 1);
        vm.warp(policy.paidExpiry(keccak256(bytes("alice"))) + GRACE_PERIOD);

        address newWallet = makeAddr("newDosWallet");
        IDosDomainPolicy.Voucher memory voucher =
            _voucher(IDosDomainPolicy.Operation.RECLAIM, "alice", newWallet, 2, CLAIM_DURATION);
        bytes32 secret = keccak256("reclaim secret");
        bytes memory signature = _sign(voucher);
        _fundAndApprove(newWallet, voucher.maxPrice);

        vm.prank(newWallet);
        policy.commitReclaim("alice", voucher, signature, secret);
        vm.warp(block.timestamp + registrar.MIN_COMMITMENT_AGE() + 1);
        vm.prank(newWallet);
        policy.reclaim("alice", voucher, signature, secret);

        assertTrue(policy.isDosMeEntitled("alice", newWallet));
    }

    function test_registrarRejectsDirectRegistration() external {
        bytes32 secret = keccak256("bypass secret");
        bytes32 commitment =
            registrar.makeCommitment(
                "alice",
                wallet,
                secret,
                IRegistry(address(0)),
                address(0),
                CLAIM_DURATION,
                bytes32(0)
            );
        vm.prank(wallet);
        registrar.commit(commitment);
        vm.warp(block.timestamp + registrar.MIN_COMMITMENT_AGE() + 1);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                DOSPolicyRegistrar.UnauthorizedRegistrationController.selector,
                wallet,
                address(policy)
            )
        );
        registrar.register(
            "alice",
            wallet,
            secret,
            IRegistry(address(0)),
            address(0),
            CLAIM_DURATION,
            tokenUSDC,
            bytes32(0)
        );
    }

    function test_registrarRejectsDirectRenewal() external {
        _claim("alice", wallet, 1);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(
                DOSPolicyRegistrar.UnauthorizedRegistrationController.selector,
                wallet,
                address(policy)
            )
        );
        registrar.renew("alice", CLAIM_DURATION, tokenUSDC, bytes32(0));
    }

    function test_registryRejectsRegistrationOutsidePolicyRegistrar() external {
        vm.expectRevert();
        ethRegistry.register(
            "bypass",
            wallet,
            IRegistry(address(0)),
            address(0),
            0,
            uint64(block.timestamp + CLAIM_DURATION)
        );
    }

    function test_registryRejectsRenewalOutsidePolicyRegistrar() external {
        _claim("alice", wallet, 1);
        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id("alice"));

        vm.expectRevert();
        ethRegistry.renew(state.tokenId, state.expiry + CLAIM_DURATION);
    }

    function _claim(string memory label, address owner, uint256 nonce) internal {
        IDosDomainPolicy.Voucher memory voucher = _claimVoucher(label, owner, nonce);
        bytes32 secret = keccak256(abi.encodePacked(label, owner, nonce));
        bytes memory signature = _sign(voucher);

        vm.prank(owner);
        policy.commitClaim(label, voucher, signature, secret);
        vm.warp(block.timestamp + registrar.MIN_COMMITMENT_AGE() + 1);
        vm.prank(owner);
        policy.claim(label, voucher, signature, secret);
    }

    function _voucher(
        IDosDomainPolicy.Operation operation,
        string memory label,
        address owner,
        uint256 nonce,
        uint64 duration
    )
        internal
        view
        returns (IDosDomainPolicy.Voucher memory voucher)
    {
        (, , uint256 total) = policy.quote(operation, label, duration, tokenUSDC);
        return
            IDosDomainPolicy.Voucher({operation: operation, wallet: owner, accountId: _accountId(
                owner
            ), labelhash: keccak256(bytes(label)), duration: duration, paymentToken: tokenUSDC, maxPrice: total, nonce: nonce, deadline: uint64(
                block.timestamp + 1 days
            )});
    }

    function _fundAndApprove(address owner, uint256 amount) internal {
        tokenUSDC.mint(owner, amount);
        vm.prank(owner);
        tokenUSDC.approve(address(policy), amount);
    }

    function _claimVoucher(string memory label, address owner, uint256 nonce)
        internal
        view
        returns (IDosDomainPolicy.Voucher memory voucher)
    {
        return _voucher(IDosDomainPolicy.Operation.CLAIM, label, owner, nonce, CLAIM_DURATION);
    }

    function _registerLegacy(string memory label, address owner, uint64 expiry) internal {
        uint256 roles = RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW;
        ethRegistry.grantRootRoles(roles, address(this));
        ethRegistry.register(label, owner, IRegistry(address(0)), address(0), 0, expiry);
        ethRegistry.revokeRootRoles(roles, address(this));
    }

    function _accountId(address owner) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("dos-me-account", owner));
    }

    function _sign(IDosDomainPolicy.Voucher memory voucher)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 digest = policy.hashVoucher(voucher);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(VOUCHER_SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }
}
