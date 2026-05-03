/// Module: collection_manager
/// Manages NFT collections on Kintagi. A Collection is a shared object
/// that stores mint configuration, royalty settings, and mutation rules.
/// Creators own a CreatorCap — the key to manage their collection.
module kintagi::collection_manager {

    use std::string::{Self, String};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::vec_map::{Self, VecMap};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use kintagi::kintagi_nft::{Self, KintagiNFT};

    // ========== Error codes ==========
    const E_NOT_CREATOR: u64 = 100;
    const E_COLLECTION_FROZEN: u64 = 101;
    const E_SUPPLY_EXHAUSTED: u64 = 102;
    const E_INSUFFICIENT_PAYMENT: u64 = 103;
    const E_MINTING_PAUSED: u64 = 104;
    const E_MAX_PER_WALLET_REACHED: u64 = 105;

    // ========== Structs ==========

    /// Shared object — one per NFT collection. Anyone can read it.
    public struct Collection has key {
        id: UID,
        /// Human-readable name
        name: String,
        /// Collection description
        description: String,
        /// Collection cover image URL
        cover_url: String,
        /// Creator's address
        creator: address,
        /// Max supply (0 = unlimited)
        max_supply: u64,
        /// Minted so far
        minted: u64,
        /// Mint price in MIST (1 SUI = 1_000_000_000 MIST). 0 = free mint.
        mint_price: u64,
        /// Royalty basis points (500 = 5%)
        royalty_bps: u64,
        /// Whether minting is paused by creator
        minting_paused: bool,
        /// Whether collection is permanently frozen (no more mutations)
        frozen: bool,
        /// Accumulated royalty balance
        royalty_balance: Balance<SUI>,
        /// Trait rule definitions: trait_key => allowed_values (comma-separated)
        trait_rules: VecMap<String, String>,
        /// Per-wallet mint count tracker
        mints_per_wallet: VecMap<address, u64>,
        /// Max mints per wallet (0 = unlimited)
        max_per_wallet: u64,
    }

    /// Capability object owned by the creator — required to manage the collection.
    /// Transferable, so studios can hold it on behalf of creators.
    public struct CreatorCap has key, store {
        id: UID,
        collection_id: ID,
        creator: address,
    }

    /// Capability granted to authorized mutators (game servers, oracle relayers).
    /// Scoped to a specific collection.
    public struct MutatorCap has key, store {
        id: UID,
        collection_id: ID,
        label: String,    // e.g. "game-server-prod", "oracle-relay"
        granted_by: address,
    }

    // ========== Events ==========

    public struct CollectionCreated has copy, drop {
        collection_id: address,
        creator: address,
        name: String,
        max_supply: u64,
        mint_price: u64,
    }

    public struct NFTMintedFromCollection has copy, drop {
        collection_id: address,
        nft_id: address,
        minted: u64,
        remaining: u64,
        minter: address,
    }

    public struct MutatorGranted has copy, drop {
        collection_id: address,
        mutator_cap_id: address,
        label: String,
        granted_to: address,
    }

    public struct RoyaltyWithdrawn has copy, drop {
        collection_id: address,
        amount: u64,
        recipient: address,
    }

    // ========== Collection lifecycle ==========

    /// Create a new collection. Returns a CreatorCap to the caller.
    public fun create_collection(
        name: vector<u8>,
        description: vector<u8>,
        cover_url: vector<u8>,
        max_supply: u64,
        mint_price: u64,
        royalty_bps: u64,
        max_per_wallet: u64,
        ctx: &mut TxContext,
    ) {
        let collection = Collection {
            id: object::new(ctx),
            name: string::utf8(name),
            description: string::utf8(description),
            cover_url: string::utf8(cover_url),
            creator: tx_context::sender(ctx),
            max_supply,
            minted: 0,
            mint_price,
            royalty_bps,
            minting_paused: false,
            frozen: false,
            royalty_balance: balance::zero<SUI>(),
            trait_rules: vec_map::empty<String, String>(),
            mints_per_wallet: vec_map::empty<address, u64>(),
            max_per_wallet,
        };

        let collection_id = object::uid_to_address(&collection.id);

        let cap = CreatorCap {
            id: object::new(ctx),
            collection_id: object::id(&collection),
            creator: tx_context::sender(ctx),
        };

        event::emit(CollectionCreated {
            collection_id,
            creator: tx_context::sender(ctx),
            name: collection.name,
            max_supply,
            mint_price,
        });

        transfer::share_object(collection);
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    /// Mint an NFT from this collection. Validates supply, payment, and wallet limits.
    public fun mint_nft(
        collection: &mut Collection,
        name: vector<u8>,
        description: vector<u8>,
        image_url: vector<u8>,
        trait_keys: vector<vector<u8>>,
        trait_values: vector<vector<u8>>,
        mut payment: Coin<SUI>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(!collection.minting_paused, E_MINTING_PAUSED);
        assert!(!collection.frozen, E_COLLECTION_FROZEN);

        // Supply check
        if (collection.max_supply > 0) {
            assert!(collection.minted < collection.max_supply, E_SUPPLY_EXHAUSTED);
        };

        // Payment check
        assert!(coin::value(&payment) >= collection.mint_price, E_INSUFFICIENT_PAYMENT);

        // Per-wallet limit check
        let minter = tx_context::sender(ctx);
        if (collection.max_per_wallet > 0) {
            let count = if (vec_map::contains(&collection.mints_per_wallet, &minter)) {
                *vec_map::get(&collection.mints_per_wallet, &minter)
            } else { 0 };
            assert!(count < collection.max_per_wallet, E_MAX_PER_WALLET_REACHED);
        };

        // Collect payment into royalty balance
        if (collection.mint_price > 0) {
            let paid = coin::split(&mut payment, collection.mint_price, ctx);
            balance::join(&mut collection.royalty_balance, coin::into_balance(paid));
        };

        // Return change
        if (coin::value(&payment) > 0) {
            transfer::public_transfer(payment, minter);
        } else {
            coin::destroy_zero(payment);
        };

        // Track per-wallet mints
        if (vec_map::contains(&collection.mints_per_wallet, &minter)) {
            let count = vec_map::get_mut(&mut collection.mints_per_wallet, &minter);
            *count = *count + 1;
        } else {
            vec_map::insert(&mut collection.mints_per_wallet, minter, 1);
        };

        collection.minted = collection.minted + 1;

        let remaining = if (collection.max_supply > 0) {
            collection.max_supply - collection.minted
        } else { 0 };

        // Mint the NFT
        let nft = kintagi_nft::mint(
            object::uid_to_address(&collection.id),
            name,
            description,
            image_url,
            trait_keys,
            trait_values,
            recipient,
            ctx,
        );

        let nft_id = kintagi_nft::nft_id(&nft);

        event::emit(NFTMintedFromCollection {
            collection_id: object::uid_to_address(&collection.id),
            nft_id,
            minted: collection.minted,
            remaining,
            minter,
        });

        transfer::public_transfer(nft, recipient);
    }

    // ========== Creator-gated actions (require CreatorCap) ==========

    /// Grant mutation rights to a third party (game server, oracle, API backend)
    public fun grant_mutator(
        cap: &CreatorCap,
        collection: &Collection,
        label: vector<u8>,
        grantee: address,
        ctx: &mut TxContext,
    ) {
        assert!(object::id(collection) == cap.collection_id, E_NOT_CREATOR);

        let mutator_cap = MutatorCap {
            id: object::new(ctx),
            collection_id: cap.collection_id,
            label: string::utf8(label),
            granted_by: tx_context::sender(ctx),
        };

        let cap_id = object::uid_to_address(&mutator_cap.id);

        event::emit(MutatorGranted {
            collection_id: object::uid_to_address(&collection.id),
            mutator_cap_id: cap_id,
            label: string::utf8(label),
            granted_to: grantee,
        });

        transfer::public_transfer(mutator_cap, grantee);
    }

    /// Pause or resume minting
    public fun set_minting_paused(
        cap: &CreatorCap,
        collection: &mut Collection,
        paused: bool,
    ) {
        assert!(object::id(collection) == cap.collection_id, E_NOT_CREATOR);
        collection.minting_paused = paused;
    }

    /// Add a trait rule to the collection schema
    public fun add_trait_rule(
        cap: &CreatorCap,
        collection: &mut Collection,
        trait_key: vector<u8>,
        allowed_values: vector<u8>,
    ) {
        assert!(object::id(collection) == cap.collection_id, E_NOT_CREATOR);
        let key = string::utf8(trait_key);
        if (vec_map::contains(&collection.trait_rules, &key)) {
            let val = vec_map::get_mut(&mut collection.trait_rules, &key);
            *val = string::utf8(allowed_values);
        } else {
            vec_map::insert(&mut collection.trait_rules, key, string::utf8(allowed_values));
        };
    }

    /// Withdraw accumulated royalties to creator wallet
    public fun withdraw_royalties(
        cap: &CreatorCap,
        collection: &mut Collection,
        ctx: &mut TxContext,
    ) {
        assert!(object::id(collection) == cap.collection_id, E_NOT_CREATOR);
        let amount = balance::value(&collection.royalty_balance);
        let withdrawn = coin::from_balance(
            balance::split(&mut collection.royalty_balance, amount),
            ctx,
        );
        let creator = tx_context::sender(ctx);

        event::emit(RoyaltyWithdrawn {
            collection_id: object::uid_to_address(&collection.id),
            amount,
            recipient: creator,
        });

        transfer::public_transfer(withdrawn, creator);
    }

    // ========== Mutator-gated actions (require MutatorCap) ==========

    /// Authorized mutator updates a single trait on an NFT
    public fun mutate_trait(
        _cap: &MutatorCap,
        nft: &mut KintagiNFT,
        trait_key: vector<u8>,
        trait_value: vector<u8>,
        ctx: &mut TxContext,
    ) {
        kintagi_nft::set_trait(nft, trait_key, trait_value, ctx);
    }

    /// Authorized mutator adds XP to an NFT
    public fun add_xp_authorized(
        _cap: &MutatorCap,
        nft: &mut KintagiNFT,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        kintagi_nft::add_xp(nft, amount, ctx);
    }

    /// Authorized mutator levels up an NFT
    public fun level_up_authorized(
        _cap: &MutatorCap,
        nft: &mut KintagiNFT,
        new_level: u64,
        new_image_url: vector<u8>,
        ctx: &mut TxContext,
    ) {
        kintagi_nft::level_up(nft, new_level, new_image_url, ctx);
    }

    // ========== View functions ==========

    public fun get_collection_name(c: &Collection): &String { &c.name }
    public fun get_minted(c: &Collection): u64 { c.minted }
    public fun get_max_supply(c: &Collection): u64 { c.max_supply }
    public fun get_mint_price(c: &Collection): u64 { c.mint_price }
    public fun get_royalty_bps(c: &Collection): u64 { c.royalty_bps }
    public fun is_frozen(c: &Collection): bool { c.frozen }
    public fun is_minting_paused(c: &Collection): bool { c.minting_paused }
    public fun get_royalty_balance(c: &Collection): u64 { balance::value(&c.royalty_balance) }
}
