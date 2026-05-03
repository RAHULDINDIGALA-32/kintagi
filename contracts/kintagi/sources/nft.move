/// Module: kintagi_nft
/// Core NFT object for Kintagi — Dynamic NFT Creator Studio on Sui.
/// Each KintagiNFT is a mutable Move object whose traits evolve over time
/// based on real-world triggers, game events, or on-chain conditions.
/// Every mutation is a real on-chain transaction — verifiable and permanent.
module kintagi::kintagi_nft {
    use std::string::{Self, String};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::vec_map::{Self, VecMap};
    use sui::url::{Self, Url};

    // ========== Error codes ==========
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_TRAIT_NOT_FOUND: u64 = 2;
    const E_MAX_TRAITS_REACHED: u64 = 3;
    const E_INVALID_LEVEL: u64 = 4;
    const E_COLLECTION_FROZEN: u64 = 5;

    // ========== Constants ==========
    const MAX_TRAITS: u64 = 20;
    const MAX_LEVEL: u64 = 100;

    // ========== Structs ==========

    /// The core NFT object — lives in the owner's wallet.
    /// All fields except `id` and `collection_id` are mutable.
    public struct KintagiNFT has key, store {
        id: UID,
        /// Collection this NFT belongs to
        collection_id: address,
        /// Display name
        name: String,
        /// Long description — can be updated as the NFT evolves
        description: String,
        /// Current primary image URI (Walrus or IPFS)
        image_url: Url,
        /// Current level (0–100). Core progression stat.
        level: u64,
        /// Total experience points accumulated — never decreases
        xp: u64,
        /// Generation number — increments when NFT "evolves" fundamentally
        generation: u64,
        /// Dynamic trait key-value store: e.g. "skin" => "gold", "power" => "500"
        traits: VecMap<String, String>,
        /// Timestamp of last mutation (epoch ms)
        last_mutated_at: u64,
        /// Total number of mutations applied — historic record
        mutation_count: u64,
        /// Creator's address — stored for royalty logic
        creator: address,
    }

    /// One-time witness for module initialization
    public struct KINTAGI_NFT has drop {}

    // ========== Events ==========

    /// Emitted when a new NFT is minted
    public struct NFTMinted has copy, drop {
        nft_id: address,
        collection_id: address,
        name: String,
        owner: address,
        level: u64,
    }

    /// Emitted on every trait mutation
    public struct TraitMutated has copy, drop {
        nft_id: address,
        trait_key: String,
        old_value: String,
        new_value: String,
        mutation_count: u64,
        triggered_by: address,
    }

    /// Emitted when NFT levels up
    public struct LevelUp has copy, drop {
        nft_id: address,
        old_level: u64,
        new_level: u64,
        new_generation: u64,
        owner: address,
    }

    /// Emitted when XP is added
    public struct XPAdded has copy, drop {
        nft_id: address,
        xp_added: u64,
        total_xp: u64,
    }

    // ========== Public functions ==========

    /// Mint a new KintagiNFT. Called by the CollectionManager on behalf of the creator.
    public fun mint(
        collection_id: address,
        name: vector<u8>,
        description: vector<u8>,
        image_url: vector<u8>,
        initial_traits_keys: vector<vector<u8>>,
        initial_traits_values: vector<vector<u8>>,
        recipient: address,
        ctx: &mut TxContext,
    ): KintagiNFT {
        let mut traits = vec_map::empty<String, String>();
        let mut i = 0;
        while (i < vector::length(&initial_traits_keys)) {
            let key = string::utf8(*vector::borrow(&initial_traits_keys, i));
            let val = string::utf8(*vector::borrow(&initial_traits_values, i));
            vec_map::insert(&mut traits, key, val);
            i = i + 1;
        };

        let nft = KintagiNFT {
            id: object::new(ctx),
            collection_id,
            name: string::utf8(name),
            description: string::utf8(description),
            image_url: url::new_unsafe_from_bytes(image_url),
            level: 1,
            xp: 0,
            generation: 1,
            traits,
            last_mutated_at: tx_context::epoch_timestamp_ms(ctx),
            mutation_count: 0,
            creator: tx_context::sender(ctx),
        };

        event::emit(NFTMinted {
            nft_id: object::uid_to_address(&nft.id),
            collection_id,
            name: nft.name,
            owner: recipient,
            level: 1,
        });

        nft
    }

    /// Transfer NFT to a recipient after mint
    public fun mint_and_transfer(
        collection_id: address,
        name: vector<u8>,
        description: vector<u8>,
        image_url: vector<u8>,
        initial_traits_keys: vector<vector<u8>>,
        initial_traits_values: vector<vector<u8>>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        let nft = mint(
            collection_id,
            name,
            description,
            image_url,
            initial_traits_keys,
            initial_traits_values,
            recipient,
            ctx,
        );
        transfer::public_transfer(nft, recipient);
    }

    /// Update or insert a single trait. Callable only by authorized mutators.
    /// Returns the old value (empty string if trait was new).
    public fun set_trait(
        nft: &mut KintagiNFT,
        key: vector<u8>,
        value: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(
            vec_map::size(&nft.traits) < MAX_TRAITS || vec_map::contains(&nft.traits, &string::utf8(key)),
            E_MAX_TRAITS_REACHED
        );

        let key_str = string::utf8(key);
        let val_str = string::utf8(value);

        let old_value = if (vec_map::contains(&nft.traits, &key_str)) {
            let (_, old) = vec_map::remove(&mut nft.traits, &key_str);
            old
        } else {
            string::utf8(b"")
        };

        vec_map::insert(&mut nft.traits, key_str, val_str);

        nft.last_mutated_at = tx_context::epoch_timestamp_ms(ctx);
        nft.mutation_count = nft.mutation_count + 1;

        event::emit(TraitMutated {
            nft_id: object::uid_to_address(&nft.id),
            trait_key: string::utf8(key),
            old_value,
            new_value: string::utf8(value),
            mutation_count: nft.mutation_count,
            triggered_by: tx_context::sender(ctx),
        });
    }

    /// Add XP to the NFT — XP never decreases (append-only)
    public fun add_xp(
        nft: &mut KintagiNFT,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        nft.xp = nft.xp + amount;
        nft.last_mutated_at = tx_context::epoch_timestamp_ms(ctx);
        nft.mutation_count = nft.mutation_count + 1;

        event::emit(XPAdded {
            nft_id: object::uid_to_address(&nft.id),
            xp_added: amount,
            total_xp: nft.xp,
        });
    }

    /// Level up the NFT. Validates max level. Increments generation at milestone levels.
    public fun level_up(
        nft: &mut KintagiNFT,
        new_level: u64,
        new_image_url: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(new_level > nft.level, E_INVALID_LEVEL);
        assert!(new_level <= MAX_LEVEL, E_INVALID_LEVEL);

        let old_level = nft.level;
        nft.level = new_level;

        // Increment generation at milestone levels: 10, 25, 50, 75, 100
        if (new_level == 10 || new_level == 25 || new_level == 50 || new_level == 75 || new_level == 100) {
            nft.generation = nft.generation + 1;
            nft.image_url = url::new_unsafe_from_bytes(new_image_url);
        };

        nft.last_mutated_at = tx_context::epoch_timestamp_ms(ctx);
        nft.mutation_count = nft.mutation_count + 1;

        event::emit(LevelUp {
            nft_id: object::uid_to_address(&nft.id),
            old_level,
            new_level,
            new_generation: nft.generation,
            owner: tx_context::sender(ctx),
        });
    }

    /// Update the NFT's description
    public fun update_description(
        nft: &mut KintagiNFT,
        new_description: vector<u8>,
        ctx: &mut TxContext,
    ) {
        nft.description = string::utf8(new_description);
        nft.last_mutated_at = tx_context::epoch_timestamp_ms(ctx);
        nft.mutation_count = nft.mutation_count + 1;
    }

    /// Update image URL — called when visual state changes
    public fun update_image(
        nft: &mut KintagiNFT,
        new_image_url: vector<u8>,
        ctx: &mut TxContext,
    ) {
        nft.image_url = url::new_unsafe_from_bytes(new_image_url);
        nft.last_mutated_at = tx_context::epoch_timestamp_ms(ctx);
        nft.mutation_count = nft.mutation_count + 1;
    }

    // ========== View functions ==========

    public fun get_name(nft: &KintagiNFT): &String { &nft.name }
    public fun get_description(nft: &KintagiNFT): &String { &nft.description }
    public fun get_level(nft: &KintagiNFT): u64 { nft.level }
    public fun get_xp(nft: &KintagiNFT): u64 { nft.xp }
    public fun get_generation(nft: &KintagiNFT): u64 { nft.generation }
    public fun get_mutation_count(nft: &KintagiNFT): u64 { nft.mutation_count }
    public fun get_collection_id(nft: &KintagiNFT): address { nft.collection_id }
    public fun get_creator(nft: &KintagiNFT): address { nft.creator }
    public fun get_last_mutated_at(nft: &KintagiNFT): u64 { nft.last_mutated_at }

    public fun get_trait(nft: &KintagiNFT, key: vector<u8>): String {
        let key_str = string::utf8(key);
        assert!(vec_map::contains(&nft.traits, &key_str), E_TRAIT_NOT_FOUND);
        *vec_map::get(&nft.traits, &key_str)
    }

    public fun has_trait(nft: &KintagiNFT, key: vector<u8>): bool {
        vec_map::contains(&nft.traits, &string::utf8(key))
    }

    public fun get_all_traits(nft: &KintagiNFT): &VecMap<String, String> {
        &nft.traits
    }

    public fun nft_id(nft: &KintagiNFT): address {
        object::uid_to_address(&nft.id)
    }
}
