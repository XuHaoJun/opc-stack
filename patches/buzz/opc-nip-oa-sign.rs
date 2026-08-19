//! OPC NIP-OA owner attestation signer (network-isolated).
//!
//! Reads one owner secret (64-hex or nsec) from stdin and emits a NIP-OA
//! `auth` tag authorizing the agent pubkey given in argv under empty
//! conditions. The owner secret never enters argv, environment, mounts, or
//! logs: the helper is meant to run as
//! `docker run --rm -i --network none --entrypoint /usr/local/bin/opc-nip-oa-sign …`
//! with the secret piped to stdin.
//!
//! Usage: opc-nip-oa-sign <agent-pubkey-hex> <expected-owner-pubkey-hex>
//!
//! Exit codes: `0` success (tag on stdout), `2` malformed input, `3` derived
//! owner pubkey does not match the expected owner pubkey. stderr never
//! contains the secret.

use std::io::{self, Read};

use buzz_sdk::nip_oa;
use nostr::{Keys, PublicKey};

fn run(agent_hex: &str, expected_owner_hex: &str, secret: &str) -> Result<String, (i32, String)> {
    let owner = Keys::parse(secret.trim()).map_err(|_| (2, "invalid owner key".into()))?;
    let expected = PublicKey::from_hex(expected_owner_hex)
        .map_err(|_| (2, "invalid expected owner pubkey".into()))?;
    if owner.public_key() != expected {
        return Err((3, "owner key does not match resolved Buzz identity".into()));
    }
    let agent = PublicKey::from_hex(agent_hex)
        .map_err(|_| (2, "invalid agent pubkey".into()))?;
    nip_oa::compute_auth_tag(&owner, &agent, "")
        .map_err(|error| (2, format!("cannot sign owner attestation: {error}")))
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        eprintln!("usage: opc-nip-oa-sign <agent-pubkey-hex> <expected-owner-pubkey-hex>");
        std::process::exit(2);
    }
    // At most 512 bytes of stdin — plenty for a 64-hex or nsec secret.
    let mut secret = String::new();
    if io::stdin().take(512).read_to_string(&mut secret).is_err() {
        eprintln!("cannot read owner secret from stdin");
        std::process::exit(2);
    }
    match run(&args[0], &args[1], &secret) {
        Ok(tag) => println!("{tag}"),
        Err((code, message)) => {
            eprintln!("{message}");
            std::process::exit(code);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Deterministic secp256k1 fixtures (secret n → x-only pubkey of n·G).
    const OWNER_SECRET: &str = "0000000000000000000000000000000000000000000000000000000000000001";
    const OWNER_PUBKEY: &str = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    const AGENT_PUBKEY: &str = "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";
    const OTHER_PUBKEY: &str = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9";

    #[test]
    fn produced_tag_verifies_and_recovers_owner() {
        let tag = run(AGENT_PUBKEY, OWNER_PUBKEY, OWNER_SECRET).expect("signing must succeed");
        let agent = PublicKey::from_hex(AGENT_PUBKEY).expect("fixture agent pubkey");
        let recovered = nip_oa::verify_auth_tag(&tag, &agent).expect("tag must verify");
        assert_eq!(recovered.to_hex(), OWNER_PUBKEY);
    }

    #[test]
    fn mismatched_owner_returns_code_3() {
        let err = run(AGENT_PUBKEY, OTHER_PUBKEY, OWNER_SECRET).expect_err("must fail");
        assert_eq!(err.0, 3);
    }

    #[test]
    fn malformed_input_returns_code_2() {
        let err = run("not-a-pubkey", OWNER_PUBKEY, OWNER_SECRET).expect_err("must fail");
        assert_eq!(err.0, 2);
    }
}
