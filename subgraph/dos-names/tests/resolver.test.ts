import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  afterEach,
  assert,
  clearStore,
  newMockEvent,
  test,
} from "matchstick-as/assembly/index";

import {
  handleAddrChanged,
  handleNameChanged,
  handleTextChanged,
} from "../src/resolver";
import {
  AddrChanged,
  NameChanged,
  TextChanged,
} from "../src/types/Resolver/PermissionedResolver";

const RESOLVER = "0x2222222222222222222222222222222222222222";
const OWNER = "0x89205a3a3b2a69de6dbf7f01ed13b2108b2c43e7";
const NODE =
  "0x424d8e54ceea7400cbef56f721accb0a42bf370777b1439bfaee1d4eb678040f";

function addrChanged(): AddrChanged {
  let mock = newMockEvent();
  mock.address = Address.fromString(RESOLVER);
  let event = new AddrChanged(
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
      "node",
      ethereum.Value.fromFixedBytes(Bytes.fromHexString(NODE))
    ),
    new ethereum.EventParam(
      "a",
      ethereum.Value.fromAddress(Address.fromString(OWNER))
    ),
  ];
  return event;
}

function textChanged(): TextChanged {
  let mock = newMockEvent();
  mock.address = Address.fromString(RESOLVER);
  mock.logIndex = BigInt.fromI32(1);
  let event = new TextChanged(
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
      "node",
      ethereum.Value.fromFixedBytes(Bytes.fromHexString(NODE))
    ),
    new ethereum.EventParam("indexedKey", ethereum.Value.fromString("url")),
    new ethereum.EventParam("key", ethereum.Value.fromString("url")),
    new ethereum.EventParam(
      "value",
      ethereum.Value.fromString("https://doschain.com")
    ),
  ];
  return event;
}

function nameChanged(): NameChanged {
  let mock = newMockEvent();
  mock.address = Address.fromString(RESOLVER);
  mock.logIndex = BigInt.fromI32(2);
  let event = new NameChanged(
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
      "node",
      ethereum.Value.fromFixedBytes(Bytes.fromHexString(NODE))
    ),
    new ethereum.EventParam("name", ethereum.Value.fromString("alice.dos")),
  ];
  return event;
}

afterEach(() => {
  clearStore();
});

test("address and text records retain resolver state", () => {
  handleAddrChanged(addrChanged());
  handleTextChanged(textChanged());

  let resolverId = RESOLVER.concat("-").concat(NODE);
  assert.fieldEquals("Resolver", resolverId, "addr", OWNER);
  assert.fieldEquals("Resolver", resolverId, "texts", "[url]");
  assert.fieldEquals("TextChanged", "1-1", "value", "https://doschain.com");
});

test("name records create their resolver relation when indexed standalone", () => {
  handleNameChanged(nameChanged());

  let resolverId = RESOLVER.concat("-").concat(NODE);
  assert.fieldEquals("Resolver", resolverId, "address", RESOLVER);
  assert.fieldEquals("NameChanged", "1-2", "resolver", resolverId);
  assert.fieldEquals("NameChanged", "1-2", "name", "alice.dos");
});
