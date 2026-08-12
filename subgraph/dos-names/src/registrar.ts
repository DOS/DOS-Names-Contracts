/**
 * DOSRegistrar event handlers.
 *
 * Actual event signatures:
 *   NameRegistered(indexed uint256 tokenId, string label, address owner, address subregistry,
 *                  address resolver, uint64 duration, address paymentToken, indexed bytes32 referrer,
 *                  uint256 base, uint256 premium)
 *   NameRenewed(indexed uint256 tokenId, string label, uint64 duration, uint64 newExpiry,
 *              address paymentToken, indexed bytes32 referrer, uint256 amount)
 */
import { BigInt } from "@graphprotocol/graph-ts";

import {
  NameRegistered as RegistrarNameRegisteredEvent,
  NameRenewed as RegistrarNameRenewedEvent,
} from "./types/DOSRegistrar/DOSRegistrar";

import {
  Domain,
  NameRegistered,
  NameRenewed,
  Registration,
  TokenToDomain,
} from "./types/schema";

import {
  checkValidLabel,
  createEventID,
  createOrLoadAccount,
  tokenIdToHex,
} from "./utils";

function resolveDomainNode(tokenId: BigInt): string | null {
  let mapping = TokenToDomain.load(tokenIdToHex(tokenId));
  return mapping === null ? null : mapping.domain;
}

/**
 * NameRegistered - emitted by DOSRegistrar after commit-reveal registration.
 * Provides cost info and name preimage.
 * The registry's LabelRegistered already created the Domain + Registration entities.
 */
export function handleNameRegisteredByRegistrar(
  event: RegistrarNameRegisteredEvent
): void {
  let label = event.params.label;
  let tokenId = event.params.tokenId;
  let owner = event.params.owner;
  let base = event.params.base;
  let premium = event.params.premium;

  if (!checkValidLabel(label)) {
    return;
  }

  let node = resolveDomainNode(tokenId);
  if (node === null) {
    return;
  }

  let cost = base.plus(premium);

  // Update domain name preimage
  let domain = Domain.load(node);
  if (domain !== null) {
    if (domain.labelName !== label) {
      domain.labelName = label;
      domain.name = label + ".dos";
      domain.save();
    }

    // Update registration with cost
    if (domain.labelhash !== null) {
      let registration = Registration.load(domain.labelhash!.toHexString());
      if (registration !== null) {
        registration.labelName = label;
        registration.cost = cost;
        registration.save();
      }
    }

    // Create NameRegistered registration event
    let account = createOrLoadAccount(owner.toHexString());
    let registrationEvent = new NameRegistered(createEventID(event));
    registrationEvent.registration =
      domain.labelhash !== null ? domain.labelhash!.toHexString() : node;
    registrationEvent.blockNumber = event.block.number.toI32();
    registrationEvent.transactionID = event.transaction.hash;
    registrationEvent.registrant = account.id;
    registrationEvent.expiryDate =
      domain.expiryDate !== null ? domain.expiryDate! : BigInt.fromI32(0);
    registrationEvent.save();
  }
}

/**
 * NameRenewed - emitted by DOSRegistrar when a name is renewed.
 */
export function handleNameRenewedByRegistrar(
  event: RegistrarNameRenewedEvent
): void {
  let label = event.params.label;
  let tokenId = event.params.tokenId;
  let newExpiry = event.params.newExpiry;
  let amount = event.params.amount;

  if (!checkValidLabel(label)) {
    return;
  }

  let node = resolveDomainNode(tokenId);
  if (node === null) {
    return;
  }

  // Update domain expiry
  let domain = Domain.load(node);
  if (domain !== null) {
    domain.expiryDate = newExpiry;
    domain.save();

    // Update registration
    if (domain.labelhash !== null) {
      let registration = Registration.load(domain.labelhash!.toHexString());
      if (registration !== null) {
        registration.expiryDate = newExpiry;
        registration.cost = amount;
        registration.labelName = label;
        registration.save();
      }
    }

    // Create NameRenewed event
    let renewedEvent = new NameRenewed(createEventID(event));
    renewedEvent.registration =
      domain.labelhash !== null ? domain.labelhash!.toHexString() : node;
    renewedEvent.blockNumber = event.block.number.toI32();
    renewedEvent.transactionID = event.transaction.hash;
    renewedEvent.expiryDate = newExpiry;
    renewedEvent.save();
  }
}
