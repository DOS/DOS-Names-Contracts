import {
  Address,
  BigInt,
  Bytes,
  DataSourceContext,
  ethereum,
} from "@graphprotocol/graph-ts";
import {
  afterEach,
  assert,
  clearStore,
  dataSourceMock,
  newMockEvent,
  test,
} from "matchstick-as/assembly/index";

import {
  handleLabelRegistered,
  handleLabelUnregistered,
  handleResolverUpdated,
  handleSubregistryUpdated,
  handleTokenRegenerated,
  handleTransferSingle,
} from "../src/registry";
import {
  handleUserRegistryLabelRegistered,
  handleUserRegistryLabelUnregistered,
  handleUserRegistryExpiryUpdated,
  handleUserRegistryResolverUpdated,
  handleUserRegistryTokenRegenerated,
  handleUserRegistrySubregistryUpdated,
  handleUserRegistryTransferSingle,
} from "../src/userRegistry";
import {
  LabelRegistered,
  LabelUnregistered,
  ResolverUpdated,
  SubregistryUpdated,
  TokenRegenerated,
  TransferSingle,
} from "../src/types/DOSTLDRegistry/PermissionedRegistry";
import { LabelRegistered as UserRegistryLabelRegistered } from "../src/types/templates/UserRegistryTemplate/PermissionedRegistry";
import { LabelUnregistered as UserRegistryLabelUnregistered } from "../src/types/templates/UserRegistryTemplate/PermissionedRegistry";
import { TransferSingle as UserRegistryTransferSingle } from "../src/types/templates/UserRegistryTemplate/PermissionedRegistry";
import { ResolverUpdated as UserRegistryResolverUpdated } from "../src/types/templates/UserRegistryTemplate/PermissionedRegistry";
import { ExpiryUpdated as UserRegistryExpiryUpdated } from "../src/types/templates/UserRegistryTemplate/PermissionedRegistry";
import { TokenRegenerated as UserRegistryTokenRegenerated } from "../src/types/templates/UserRegistryTemplate/PermissionedRegistry";
import { SubregistryUpdated as UserRegistrySubregistryUpdated } from "../src/types/templates/UserRegistryTemplate/PermissionedRegistry";
import { Domain } from "../src/types/schema";

const OWNER = "0x89205a3a3b2a69de6dbf7f01ed13b2108b2c43e7";
const NEW_OWNER = "0x4976fb03c32e5b8cfe2b6ccb31c09ba78ebaba41";
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const USER_REGISTRY = "0x1111111111111111111111111111111111111111";
const RESOLVER = "0x2222222222222222222222222222222222222222";
const NESTED_REGISTRY = "0x3333333333333333333333333333333333333333";
const LABEL_HASH =
  "0x9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501";
const ALICE_DOS =
  "0x424d8e54ceea7400cbef56f721accb0a42bf370777b1439bfaee1d4eb678040f";
const SUB_LABEL_HASH =
  "0xfa1ea47215815692a5f1391cff19abbaf694c82fb2151a4c351b6c0eeaaf317b";
const SUB_ALICE_DOS =
  "0x1c1ff2cdbb0b7cc0b67c4b92a0ba7633d2cf2d2e756ea950fbe437050296f930";

function registration(tokenId: i32): LabelRegistered {
  let mock = newMockEvent();
  let event = new LabelRegistered(
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

function regeneration(oldTokenId: i32, newTokenId: i32): TokenRegenerated {
  let mock = newMockEvent();
  mock.logIndex = BigInt.fromI32(1);
  let event = new TokenRegenerated(
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
      "oldTokenId",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(oldTokenId))
    ),
    new ethereum.EventParam(
      "newTokenId",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(newTokenId))
    ),
  ];
  return event;
}

function subregistryUpdated(tokenId: i32): SubregistryUpdated {
  let mock = newMockEvent();
  mock.logIndex = BigInt.fromI32(1);
  let event = new SubregistryUpdated(
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
      "subregistry",
      ethereum.Value.fromAddress(Address.fromString(USER_REGISTRY))
    ),
    new ethereum.EventParam(
      "sender",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
  ];
  return event;
}

function resolverUpdated(tokenId: i32, resolver: string, logIndex: i32): ResolverUpdated {
  let mock = newMockEvent();
  mock.logIndex = BigInt.fromI32(logIndex);
  let event = new ResolverUpdated(
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
      "resolver",
      ethereum.Value.fromAddress(Address.fromString(resolver))
    ),
    new ethereum.EventParam(
      "sender",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
  ];
  return event;
}

function labelUnregistered(tokenId: i32): LabelUnregistered {
  let mock = newMockEvent();
  mock.logIndex = BigInt.fromI32(1);
  mock.block.timestamp = BigInt.fromI32(2_000_000_100);
  let event = new LabelUnregistered(
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
      "sender",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
  ];
  return event;
}

function transfer(tokenId: i32): TransferSingle {
  let mock = newMockEvent();
  mock.logIndex = BigInt.fromI32(2);
  let event = new TransferSingle(
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
      "operator",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
    new ethereum.EventParam(
      "from",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
    new ethereum.EventParam(
      "to",
      ethereum.Value.fromAddress(Address.fromString(NEW_OWNER))
    ),
    new ethereum.EventParam(
      "id",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(tokenId))
    ),
    new ethereum.EventParam(
      "value",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(1))
    ),
  ];
  return event;
}

function userRegistryRegistration(tokenId: i32): UserRegistryLabelRegistered {
  let mock = newMockEvent();
  mock.address = Address.fromString(USER_REGISTRY);
  let event = new UserRegistryLabelRegistered(
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
      ethereum.Value.fromFixedBytes(Bytes.fromHexString(SUB_LABEL_HASH))
    ),
    new ethereum.EventParam("label", ethereum.Value.fromString("sub")),
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

function userRegistryLabelUnregistered(tokenId: i32): UserRegistryLabelUnregistered {
  let mock = newMockEvent();
  mock.address = Address.fromString(USER_REGISTRY);
  mock.logIndex = BigInt.fromI32(2);
  mock.block.timestamp = BigInt.fromI32(2_000_000_200);
  let event = new UserRegistryLabelUnregistered(
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
      "sender",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
  ];
  return event;
}

function userRegistryTransfer(tokenId: i32): UserRegistryTransferSingle {
  let mock = newMockEvent();
  mock.address = Address.fromString(USER_REGISTRY);
  mock.logIndex = BigInt.fromI32(1);
  let event = new UserRegistryTransferSingle(
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
      "operator",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
    new ethereum.EventParam(
      "from",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
    new ethereum.EventParam(
      "to",
      ethereum.Value.fromAddress(Address.fromString(NEW_OWNER))
    ),
    new ethereum.EventParam(
      "id",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(tokenId))
    ),
    new ethereum.EventParam(
      "value",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(1))
    ),
  ];
  return event;
}

function userRegistryResolverUpdated(tokenId: i32): UserRegistryResolverUpdated {
  let mock = newMockEvent();
  mock.address = Address.fromString(USER_REGISTRY);
  mock.logIndex = BigInt.fromI32(1);
  let event = new UserRegistryResolverUpdated(
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
      "resolver",
      ethereum.Value.fromAddress(Address.fromString(RESOLVER))
    ),
    new ethereum.EventParam(
      "sender",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
  ];
  return event;
}

function userRegistryExpiryUpdated(tokenId: i32): UserRegistryExpiryUpdated {
  let mock = newMockEvent();
  mock.address = Address.fromString(USER_REGISTRY);
  mock.logIndex = BigInt.fromI32(1);
  let event = new UserRegistryExpiryUpdated(
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
      "newExpiry",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(2_100_000_000))
    ),
    new ethereum.EventParam(
      "sender",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
  ];
  return event;
}

function userRegistryTokenRegenerated(
  oldTokenId: i32,
  newTokenId: i32
): UserRegistryTokenRegenerated {
  let mock = newMockEvent();
  mock.address = Address.fromString(USER_REGISTRY);
  mock.logIndex = BigInt.fromI32(1);
  let event = new UserRegistryTokenRegenerated(
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
      "oldTokenId",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(oldTokenId))
    ),
    new ethereum.EventParam(
      "newTokenId",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(newTokenId))
    ),
  ];
  return event;
}

function userRegistrySubregistryUpdated(tokenId: i32): UserRegistrySubregistryUpdated {
  let mock = newMockEvent();
  mock.address = Address.fromString(USER_REGISTRY);
  mock.logIndex = BigInt.fromI32(1);
  let event = new UserRegistrySubregistryUpdated(
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
      "subregistry",
      ethereum.Value.fromAddress(Address.fromString(NESTED_REGISTRY))
    ),
    new ethereum.EventParam(
      "sender",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
  ];
  return event;
}

afterEach(() => {
  clearStore();
});

test("token regeneration preserves the canonical domain mapping", () => {
  handleLabelRegistered(registration(123));
  handleTokenRegenerated(regeneration(123, 456));
  handleTransferSingle(transfer(456));

  assert.fieldEquals("Domain", ALICE_DOS, "owner", NEW_OWNER);
  assert.fieldEquals("Domain", ALICE_DOS, "tokenId", "456");
  assert.fieldEquals(
    "TokenToDomain",
    "0x00000000000000000000000000000000000000000000000000000000000001c8",
    "domain",
    ALICE_DOS
  );
  assert.notInStore(
    "TokenToDomain",
    "0x000000000000000000000000000000000000000000000000000000000000007b"
  );
});

test("a discovered user registry indexes a subname under its parent path", () => {
  handleLabelRegistered(registration(123));

  let context = new DataSourceContext();
  context.setBytes("parentNode", Bytes.fromHexString(ALICE_DOS));
  dataSourceMock.setContext(context);

  handleUserRegistryLabelRegistered(userRegistryRegistration(456));

  assert.fieldEquals("Domain", SUB_ALICE_DOS, "name", "sub.alice.dos");
  assert.fieldEquals("Domain", SUB_ALICE_DOS, "parent", ALICE_DOS);
  assert.fieldEquals("Domain", ALICE_DOS, "subdomainCount", "1");
});

test("a user-registry token transfer updates the subname owner", () => {
  handleLabelRegistered(registration(123));
  let context = new DataSourceContext();
  context.setBytes("parentNode", Bytes.fromHexString(ALICE_DOS));
  dataSourceMock.setContext(context);
  handleUserRegistryLabelRegistered(userRegistryRegistration(456));

  handleUserRegistryTransferSingle(userRegistryTransfer(456));

  assert.fieldEquals("Domain", SUB_ALICE_DOS, "owner", NEW_OWNER);
  assert.fieldEquals("WrappedDomain", SUB_ALICE_DOS, "owner", NEW_OWNER);
  assert.fieldEquals("Registration", SUB_ALICE_DOS, "registrant", NEW_OWNER);
});

test("a user-registry unregistration retires the scoped token mapping", () => {
  handleLabelRegistered(registration(123));
  let context = new DataSourceContext();
  context.setBytes("parentNode", Bytes.fromHexString(ALICE_DOS));
  dataSourceMock.setContext(context);
  handleUserRegistryLabelRegistered(userRegistryRegistration(456));

  handleUserRegistryLabelUnregistered(userRegistryLabelUnregistered(456));

  assert.fieldEquals("Domain", SUB_ALICE_DOS, "owner", ZERO_ADDRESS);
  assert.fieldEquals("Domain", SUB_ALICE_DOS, "expiryDate", "2000000200");
  assert.fieldEquals("WrappedDomain", SUB_ALICE_DOS, "owner", ZERO_ADDRESS);
  assert.fieldEquals("Registration", SUB_ALICE_DOS, "registrant", ZERO_ADDRESS);
  assert.notInStore(
    "TokenToDomain",
    USER_REGISTRY.concat("-0x00000000000000000000000000000000000000000000000000000000000001c8")
  );
});

test("a user-registry resolver is attached to the subname and dynamically indexed", () => {
  handleLabelRegistered(registration(123));
  let context = new DataSourceContext();
  context.setBytes("parentNode", Bytes.fromHexString(ALICE_DOS));
  dataSourceMock.setContext(context);
  handleUserRegistryLabelRegistered(userRegistryRegistration(456));

  handleUserRegistryResolverUpdated(userRegistryResolverUpdated(456));

  assert.fieldEquals("ResolverSource", RESOLVER, "address", RESOLVER);
  assert.fieldEquals(
    "Domain",
    SUB_ALICE_DOS,
    "resolver",
    RESOLVER.concat("-").concat(SUB_ALICE_DOS)
  );
});

test("a user-registry renewal updates every BENS expiry view", () => {
  handleLabelRegistered(registration(123));
  let context = new DataSourceContext();
  context.setBytes("parentNode", Bytes.fromHexString(ALICE_DOS));
  dataSourceMock.setContext(context);
  handleUserRegistryLabelRegistered(userRegistryRegistration(456));

  handleUserRegistryExpiryUpdated(userRegistryExpiryUpdated(456));

  assert.fieldEquals("Domain", SUB_ALICE_DOS, "expiryDate", "2100000000");
  assert.fieldEquals(
    "WrappedDomain",
    SUB_ALICE_DOS,
    "expiryDate",
    "2100000000"
  );
  assert.fieldEquals(
    "Registration",
    SUB_ALICE_DOS,
    "expiryDate",
    "2100000000"
  );
});

test("user-registry token regeneration keeps later transfers attached to the subname", () => {
  handleLabelRegistered(registration(123));
  let context = new DataSourceContext();
  context.setBytes("parentNode", Bytes.fromHexString(ALICE_DOS));
  dataSourceMock.setContext(context);
  handleUserRegistryLabelRegistered(userRegistryRegistration(456));

  handleUserRegistryTokenRegenerated(userRegistryTokenRegenerated(456, 789));
  handleUserRegistryTransferSingle(userRegistryTransfer(789));

  assert.fieldEquals("Domain", SUB_ALICE_DOS, "tokenId", "789");
  assert.fieldEquals("Domain", SUB_ALICE_DOS, "owner", NEW_OWNER);
  assert.fieldEquals(
    "TokenToDomain",
    USER_REGISTRY.concat("-0x0000000000000000000000000000000000000000000000000000000000000315"),
    "domain",
    SUB_ALICE_DOS
  );
  assert.notInStore(
    "TokenToDomain",
    USER_REGISTRY.concat("-0x00000000000000000000000000000000000000000000000000000000000001c8")
  );
});

test("a nested user registry preserves the complete parent path", () => {
  handleLabelRegistered(registration(123));
  let context = new DataSourceContext();
  context.setBytes("parentNode", Bytes.fromHexString(ALICE_DOS));
  dataSourceMock.setContext(context);
  handleUserRegistryLabelRegistered(userRegistryRegistration(456));

  handleUserRegistrySubregistryUpdated(userRegistrySubregistryUpdated(456));

  assert.fieldEquals(
    "RegistryPath",
    NESTED_REGISTRY.concat("-").concat(SUB_ALICE_DOS),
    "parentDomain",
    SUB_ALICE_DOS
  );
});

test("subregistry discovery stores the parent path for dynamic indexing", () => {
  handleLabelRegistered(registration(123));
  handleSubregistryUpdated(subregistryUpdated(123));

  assert.fieldEquals(
    "RegistryPath",
    USER_REGISTRY.concat("-").concat(ALICE_DOS),
    "registry",
    USER_REGISTRY
  );
  assert.fieldEquals(
    "RegistryPath",
    USER_REGISTRY.concat("-").concat(ALICE_DOS),
    "parentDomain",
    ALICE_DOS
  );
});

test("resolver discovery creates a dynamic source and zero address clears it", () => {
  handleLabelRegistered(registration(123));
  handleResolverUpdated(resolverUpdated(123, RESOLVER, 1));

  assert.fieldEquals("ResolverSource", RESOLVER, "address", RESOLVER);
  assert.fieldEquals(
    "Domain",
    ALICE_DOS,
    "resolver",
    RESOLVER.concat("-").concat(ALICE_DOS)
  );

  handleResolverUpdated(resolverUpdated(123, ZERO_ADDRESS, 2));
  let domain = Domain.load(ALICE_DOS)!;
  assert.assertNull(domain.resolver);
});

test("unregistration retires the token mapping without losing domain history", () => {
  handleLabelRegistered(registration(123));
  handleLabelUnregistered(labelUnregistered(123));

  assert.fieldEquals("Domain", ALICE_DOS, "owner", ZERO_ADDRESS);
  assert.fieldEquals("Domain", ALICE_DOS, "expiryDate", "2000000100");
  assert.notInStore(
    "TokenToDomain",
    "0x000000000000000000000000000000000000000000000000000000000000007b"
  );
});
