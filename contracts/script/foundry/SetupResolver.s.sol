// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {PermissionedResolverLib} from "~src/resolver/libraries/PermissionedResolverLib.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {COIN_TYPE_ETH} from "@ens/contracts/utils/ENSIP19.sol";

contract SetupResolver is Script {
    // Testnet 3939 addresses
    PermissionedRegistry constant DOS_TLD = PermissionedRegistry(0x62BE2a74E9f477A4e044ecA917c594fb11D01Bf4);
    PermissionedResolver constant RESOLVER_IMPL = PermissionedResolver(0xB132A5447077ad10Acd4244F96dFA92A1Cd5d6dE);

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        // 1. Deploy ERC1967 proxy for PermissionedResolver
        bytes memory initData = abi.encodeCall(
            PermissionedResolver.initialize,
            (deployer, EACBaseRolesLib.ALL_ROLES)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(RESOLVER_IMPL), initData);
        PermissionedResolver resolver = PermissionedResolver(address(proxy));
        console.log("Resolver proxy:", address(resolver));

        // 2. Set resolver on DOSTLDRegistry for "doschain"
        uint256 tokenId = LibLabel.id("doschain");
        DOS_TLD.setResolver(tokenId, address(resolver));
        console.log("Resolver set for doschain.dos");

        // 3. Set address record: addr(doschain.dos) = deployer
        //    node = namehash("doschain.dos")
        bytes32 node = NameCoder.namehash(
            abi.encodePacked(uint8(8), "doschain", uint8(3), "dos", uint8(0)),
            0
        );
        resolver.setAddr(node, deployer);
        console.log("addr(doschain.dos) =", deployer);

        vm.stopBroadcast();
    }
}
