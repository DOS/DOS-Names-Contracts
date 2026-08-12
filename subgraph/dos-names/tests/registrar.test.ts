import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  afterEach,
  assert,
  clearStore,
  newMockEvent,
  test,
} from "matchstick-as/assembly/index";

import {
  handleNameRegisteredByRegistrar,
  handleNameRenewedByRegistrar,
} from "../src/registrar";
import { handleLabelRegistered } from "../src/registry";
import { NameRegistered as RegistrarNameRegistered } from "../src/types/DOSRegistrar/DOSRegistrar";
import { NameRenewed as RegistrarNameRenewed } from "../src/types/DOSRegistrar/DOSRegistrar";
import { LabelRegistered as RegistryLabelRegistered } from "../src/types/DOSTLDRegistry/PermissionedRegistry";

const OWNER = "0x89205a3a3b2a69de6dbf7f01ed13b2108b2c43e7";
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ZERO_BYTES32 =
  "0x0000000000000000000000000000000000000000000000000000000000000000";
const LABEL_HASH =
  "0x9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501";
const ALICE_DOS =
  "0x424d8e54ceea7400cbef56f721accb0a42bf370777b1439bfaee1d4eb678040f";

function registryRegistration(tokenId: i32): RegistryLabelRegistered {
  let mock = newMockEvent();
  let event = new RegistryLabelRegistered(
    mock.address,
    mock.logIndex,
    mock.transactionLogIndex,
    mock.logType,
    mock.block,
    mock.transaction,
    mock.parameters,
    mock.receipt
  );
  event.parameters = [
    new ethereum.EventParam(
      "tokenId",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(tokenId))
    ),
    new ethereum.EventParam(
      "labelHash",
      ethereum.Value.fromFixedBytes(Bytes.fromHexString(LABEL_HASH))
    ),
    new ethereum.EventParam("label", ethereum.Value.fromString("alice")),
    new ethereum.EventParam(
      "owner",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
    new ethereum.EventParam(
      "expiry",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(2_000_000_000))
    ),
    new ethereum.EventParam(
      "sender",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
  ];
  return event;
}

function registrarRegistration(tokenId: i32): RegistrarNameRegistered {
  let mock = newMockEvent();
  mock.logIndex = BigInt.fromI32(1);
  let event = new RegistrarNameRegistered(
    mock.address,
    mock.logIndex,
    mock.transactionLogIndex,
    mock.logType,
    mock.block,
    mock.transaction,
    mock.parameters,
    mock.receipt
  );
  event.parameters = [
    new ethereum.EventParam(
      "tokenId",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(tokenId))
    ),
    new ethereum.EventParam("label", ethereum.Value.fromString("alice")),
    new ethereum.EventParam(
      "owner",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
    new ethereum.EventParam(
      "subregistry",
      ethereum.Value.fromAddress(Address.fromString(ZERO_ADDRESS))
    ),
    new ethereum.EventParam(
      "resolver",
      ethereum.Value.fromAddress(Address.fromString(ZERO_ADDRESS))
    ),
    new ethereum.EventParam(
      "duration",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(31_536_000))
    ),
    new ethereum.EventParam(
      "paymentToken",
      ethereum.Value.fromAddress(Address.fromString(ZERO_ADDRESS))
    ),
    new ethereum.EventParam(
      "referrer",
      ethereum.Value.fromFixedBytes(Bytes.fromHexString(ZERO_BYTES32))
    ),
    new ethereum.EventParam(
      "base",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(10))
    ),
    new ethereum.EventParam(
      "premium",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(2))
    ),
  ];
  return event;
}

function registrarRenewal(tokenId: i32): RegistrarNameRenewed {
  let mock = newMockEvent();
  mock.logIndex = BigInt.fromI32(2);
  let event = new RegistrarNameRenewed(
    mock.address,
    mock.logIndex,
    mock.transactionLogIndex,
    mock.logType,
    mock.block,
    mock.transaction,
    mock.parameters,
    mock.receipt
  );
  event.parameters = [
    new ethereum.EventParam(
      "tokenId",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(tokenId))
    ),
    new ethereum.EventParam("label", ethereum.Value.fromString("alice")),
    new ethereum.EventParam(
      "duration",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(31_536_000))
    ),
    new ethereum.EventParam(
      "newExpiry",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(2_100_000_000))
    ),
    new ethereum.EventParam(
      "paymentToken",
      ethereum.Value.fromAddress(Address.fromString(ZERO_ADDRESS))
    ),
    new ethereum.EventParam(
      "referrer",
      ethereum.Value.fromFixedBytes(Bytes.fromHexString(ZERO_BYTES32))
    ),
    new ethereum.EventParam(
      "amount",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(7))
    ),
  ];
  return event;
}

afterEach(() => {
  clearStore();
});

test("registrar enriches the domain mapped from an ENSv2 token ID", () => {
  handleLabelRegistered(registryRegistration(123));
  handleNameRegisteredByRegistrar(registrarRegistration(123));

  assert.fieldEquals("Domain", ALICE_DOS, "name", "alice.dos");
  assert.fieldEquals("Registration", LABEL_HASH, "cost", "12");
  assert.entityCount("NameRegistered", 1);
});

test("registrar renewal stores the ENSv2 amount and new expiry", () => {
  handleLabelRegistered(registryRegistration(123));
  handleNameRenewedByRegistrar(registrarRenewal(123));

  assert.fieldEquals("Domain", ALICE_DOS, "expiryDate", "2100000000");
  assert.fieldEquals("Registration", LABEL_HASH, "cost", "7");
  assert.fieldEquals("Registration", LABEL_HASH, "expiryDate", "2100000000");
  assert.entityCount("NameRenewed", 1);
});
